-- | Policy responsibilities; internal implementation behind Nagare.Inventory.Application.
module Nagare.Inventory.Application.Policy
  ( ServiceAction (..)
  , compileServiceActionScope
  , configDigestOf
  , recordReviewedStandaloneOverrides
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.App.Deploy (RolloutEnv)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory
  ( Contribution (RegisterBackend)
  , Declaration (Managed)
  , DesiredSpec (KnativeService)
  , ManagedResource
  , ResourceBundle (contributions, declarations)
  , ScopeDeclaration
  , mkScopeDeclaration
  , scopeBundles
  , scopeConfigDigest
  , scopeId
  , scopeOverrides
  , withScopeConfigDigest
  , withScopeOverrides
  )
import Nagare.Resource.Types
  ( ContentDigest
  , InventoryError
  , ProviderAddress (Kubernetes)
  , ResourceId
  , ScopeKind (Standalone)
  , inventoryError
  , nameText
  , resourceIdText
  , scopeKind
  )
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire (canonicalValue)

-- Hash the validated config value, rather than its source file bytes. Imported
-- Haskell modules and formatting can then change without losing the exact
-- effective input that produced this accepted scope.
configDigestOf :: LBS.ByteString -> Either T.Text ContentDigest
configDigestOf bytes = do
  value <- first T.pack (eitherDecodeStrict (LBS.toStrict bytes) :: Either String Value)
  contentDigest <$> canonicalValue value

-- | Change the accepted Knative Service intent for a stop or restart. The
-- complete accepted scope and its private native members are carried forward;
-- no source checkout or live Service is used to reconstruct the other members.
data ServiceAction = StopService | RestartService !T.Text
  deriving stock (Eq, Show)

compileServiceActionScope ::
  T.Text ->
  T.Text ->
  ServiceAction ->
  ScopeDeclaration ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileServiceActionScope serviceName namespaceName action accepted native = do
  let invalid message =
        inventoryError "invalid-service-action" message
          & #scopes
          .~ [scopeId accepted]
          & (:| [])
      matches resource = case resource ^. #address of
        Kubernetes _ "serving.knative.dev" kind (Just ns) name ->
          nameText kind == "service"
            && nameText ns == namespaceName
            && nameText name == serviceName
        _ -> False
      selected =
        [ resource
        | bundle <- scopeBundles accepted
        , Managed resource <- declarations bundle
        , matches resource
        ]
  resource <- case selected of
    [single] -> Right single
    _ -> Left (invalid "accepted scope has no unique Knative Service at the selected address")
  unless
    (scopeKind (scopeId accepted) `elem` [Resource.Application, Standalone])
    (Left (invalid "service action requires an application or standalone Service scope"))
  (bound, bytes) <-
    maybe
      (Left (invalid "accepted Service lacks private native evidence"))
      Right
      (Map.lookup (resource ^. #identity) native)
  unless
    (bound == resource)
    (Left (invalid "accepted Service differs from its private native evidence"))
  value <-
    first
      (invalid . T.pack . show)
      (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
  canonical <- first invalid (canonicalValue value)
  unless
    (resource ^. #spec == KnativeService (contentDigest canonical))
    (Left (invalid "accepted Service native digest differs from its declaration"))
  let upstream = "http://" <> serviceName <> "." <> namespaceName <> ".svc.cluster.local"
      protected =
        any
          ( \case
              RegisterBackend _ _ _ target _ _ -> target == upstream
              _ -> False
          )
          [request | bundle <- scopeBundles accepted, request <- contributions bundle]
  changed <- first invalid (applyServiceAction protected action value)
  changedBytes <- first invalid (canonicalValue changed)
  let updated = resource & #spec .~ KnativeService (contentDigest changedBytes)
      replace :: ResourceBundle -> ResourceBundle
      replace bundle =
        bundle
          & #declarations
          %~ map
            ( \case
                Managed member | member ^. #identity == resource ^. #identity -> Managed updated
                declaration -> declaration
            )
      overrides = case action of
        StopService ->
          Map.insert
            "operational.visibility"
            "cluster-local"
            (Map.delete "operational.restart" (scopeOverrides accepted))
        RestartService stamp ->
          Map.insert
            "operational.restart"
            stamp
            (Map.delete "operational.visibility" (scopeOverrides accepted))
  base <- mkScopeDeclaration (scopeId accepted) (map replace (scopeBundles accepted))
  let revised = withScopeOverrides overrides $ case scopeConfigDigest accepted of
        Nothing -> base
        Just digest -> withScopeConfigDigest digest base
  pure (revised, Map.insert (resource ^. #identity) (updated, changedBytes) native)

applyServiceAction :: Bool -> ServiceAction -> Value -> Either T.Text Value
applyServiceAction protected action (Object root) = do
  metadata <- objectAt "metadata" root
  labels <- objectAt "labels" metadata
  spec <- objectAt "spec" root
  let visibility = K.fromText "networking.knative.dev/visibility"
      changedLabels = case action of
        StopService -> KM.insert visibility (String "cluster-local") labels
        RestartService _ | protected -> KM.insert visibility (String "cluster-local") labels
        RestartService _ -> KM.delete visibility labels
      changedMetadata = KM.insert "labels" (Object changedLabels) metadata
  changedSpec <- case action of
    StopService -> Right spec
    RestartService stamp -> do
      unless
        (not (T.null stamp) && T.all (\c -> c >= ' ' && c /= '"') stamp)
        (Left "restart stamp is invalid")
      template <- objectAt "template" spec
      templateMetadata <- objectAt "metadata" template
      annotations <- case KM.lookup "annotations" templateMetadata of
        Nothing -> Right KM.empty
        Just (Object fields) -> Right fields
        _ -> Left "Service template annotations are not an object"
      let stamped = KM.insert "nagare.dev/restartedAt" (String stamp) annotations
      pure
        ( KM.insert
            "template"
            ( Object
                ( KM.insert
                    "metadata"
                    (Object (KM.insert "annotations" (Object stamped) templateMetadata))
                    template
                )
            )
            spec
        )
  pure
    ( Object
        ( KM.insert
            "spec"
            (Object changedSpec)
            (KM.insert "metadata" (Object changedMetadata) root)
        )
    )
  where
    objectAt key fields = case KM.lookup key fields of
      Just (Object value) -> Right value
      _ -> Left ("Service has no object " <> K.toText key)
applyServiceAction _ _ _ = Left "Service native evidence is not an object"

-- | Bind public command inputs to the standalone scope only after checking
-- that they agree with the rollout and accepted image used by its compiler.
recordReviewedStandaloneOverrides ::
  RolloutEnv ->
  ResourceId ->
  Map T.Text T.Text ->
  ScopeDeclaration ->
  Either (NonEmpty InventoryError) ScopeDeclaration
recordReviewedStandaloneOverrides rollout imageId overrides scope = do
  unless
    ( scopeKind (scopeId scope) == Standalone
        && isJust (scopeConfigDigest scope)
        && Map.keysSet overrides
          `Set.isSubsetOf` Set.fromList ["tag", "baseDomain", "imageResource"]
        && Map.lookup "tag" overrides == Just (rollout ^. #imageTag)
        && Map.lookup "imageResource" overrides == Just (resourceIdText imageId)
        && maybe True (== rollout ^. #baseDomain) (Map.lookup "baseDomain" overrides)
    )
    ( Left
        ( inventoryError
            "invalid-standalone-overrides"
            "standalone command overrides differ from reviewed rollout inputs"
            :| []
        )
    )
  pure (withScopeOverrides overrides scope)
