-- | Release-history cleanup compiles exact accepted members into ordinary
-- conditional Kubernetes updates. Provider enumeration is never ownership.
module Nagare.Inventory.Cleanup
  ( releaseHistoryMembers
  , compileReleaseHistoryPrune
  , validateReleaseCleanupOperation
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict', toJSON)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (OperationAction (UpdateResource, VerifyResource), PlannedOperation (..))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Ops.Cleanup (pruneReleases)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (Stateless))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Static.Release (StaticRelease (..), StaticReleaseLog (..), extractReleaseLog)

-- Cleanup never acquires authority to repair other drift in the same scope.
validateReleaseCleanupOperation :: Set.Set ResourceId -> PlannedOperation -> Either Text ()
validateReleaseCleanupOperation selected operation =
  unless
    ( plannedAction operation == VerifyResource
        || ( plannedAction operation == UpdateResource
               && plannedExecutor operation == KubernetesExecutor
               && Set.fromList (NE.toList (plannedResources operation)) `Set.isSubsetOf` selected
           )
    )
    (Left "release cleanup cannot create or repair other resources; reconcile that drift in a separate review")

-- Only accepted ConfigMaps with the existing application/site release-log shape
-- belong to this legacy cleanup family. Other ConfigMaps remain untouched.
releaseHistoryMembers :: Text -> ScopeSnapshot -> Map.Map ResourceId ManagedResource
releaseHistoryMembers namespace snapshot =
  Map.fromList
    [ (resource ^. #identity, resource)
    | (_, scope) <- Map.elems (snapshotScopes snapshot)
    , bundle <- scopeBundles scope
    , Managed resource <- declarations bundle
    , Just (_, _, ns) <- [releaseAddress resource]
    , ns == namespace
    ]

releaseAddress :: ManagedResource -> Maybe (Text, Text, Text)
releaseAddress resource = case resource ^. #address of
  Kubernetes _ "" kind (Just namespace) name
    | nameText kind == "configmap"
    , resource ^. #executor == KubernetesExecutor
    , resource ^. #dataPolicy == Stateless
    , Just (prefix, subject) <- firstMatch (nameText name)
    , not (T.null subject) ->
        Just (prefix, subject, nameText namespace)
  _ -> Nothing
  where
    firstMatch name =
      listToMaybe
        [(prefix, subject) | prefix <- ["nagare-static-releases-", "nagare-app-deployments-"], Just subject <- [T.stripPrefix prefix name]]

compileReleaseHistoryPrune ::
  Int ->
  ManagedResource ->
  ScopeDeclaration ->
  Map.Map ResourceId (ManagedResource, ByteString) ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compileReleaseHistoryPrune keep selected scope native = do
  unless (keep >= 1) (Left (invalid "release cleanup must retain at least one recent release plus the current release"))
  (prefix, subject, namespace) <- maybe (Left (invalid "cleanup requires an accepted application or site release-history ConfigMap")) Right (releaseAddress selected)
  let members =
        [ resource
        | bundle <- scopeBundles scope
        , Managed resource <- declarations bundle
        , resource ^. #identity == selected ^. #identity
        ]
  unless
    (members == [selected] && selected ^. #owner == scopeId scope)
    (Left (invalid "release history differs from the exact accepted scope member"))
  (bound, bytes) <-
    maybe
      (Left (invalid "release cleanup lacks accepted private native evidence"))
      Right
      (Map.lookup (selected ^. #identity) native)
  unless (bound == selected) (Left (invalid "release history private binding changed"))
  value <- first (invalid . T.pack) (eitherDecodeStrict' bytes)
  canonical <- first invalid (canonicalValue value)
  unless
    (selected ^. #spec == NativeObject (contentDigest canonical))
    (Left (invalid "release history bytes differ from the accepted digest"))
  logValue <- first invalid (extractReleaseLog bytes)
  let entries = logValue ^. #releases
      ids = map (^. #releaseId) entries
  unless
    ( length ids == Set.size (Set.fromList ids)
        && all (\entry -> entry ^. #siteName == subject && entry ^. #namespace == namespace) entries
        && maybe (null entries) (`elem` ids) (logValue ^. #current)
    )
    (Left (invalid "release history contains inconsistent subjects, IDs or current release"))
  let (trimmed, _) = pruneReleases keep logValue
  encodedLog <- first invalid (canonicalValue (toJSON trimmed))
  changed <- case value of
    Object root
      | KM.lookup "apiVersion" root == Just (String "v1")
      , KM.lookup "kind" root == Just (String "ConfigMap")
      , Just (Object metadata) <- KM.lookup "metadata" root
      , KM.lookup "name" metadata == Just (String (prefix <> subject))
      , KM.lookup "namespace" metadata == Just (String namespace)
      , Just (Object fields) <- KM.lookup "data" root ->
          Right (Object (KM.insert "data" (Object (KM.insert "releases.json" (String (TE.decodeUtf8 encodedLog)) fields)) root))
    _ -> Left (invalid "release history native kind or address differs from accepted ownership")
  changedBytes <- first invalid (canonicalValue changed)
  let updated = selected & #spec .~ NativeObject (contentDigest changedBytes)
      replace bundle =
        bundle
          & #declarations
          %~ map
            ( \case
                Managed resource | resource ^. #identity == selected ^. #identity -> Managed updated
                other -> other
            )
  rebuilt <- mkScopeDeclaration (scopeId scope) (map replace (scopeBundles scope))
  let revised = withScopeOverrides (scopeOverrides scope) $ case scopeConfigDigest scope of
        Nothing -> rebuilt
        Just digest -> withScopeConfigDigest digest rebuilt
  pure (revised, Map.insert (selected ^. #identity) (updated, changedBytes) native)
  where
    invalid message =
      (inventoryError "invalid-release-cleanup" message)
        { resources = [selected ^. #identity]
        }
        :| []
