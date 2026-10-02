-- | Release responsibilities; internal implementation behind Nagare.Inventory.Application.
module Nagare.Inventory.Application.Release
  ( acceptedApplicationReleaseLog
  , acceptedStandaloneReleaseLog
  , compileApplicationRelease
  , legacyApplicationReleaseImport
  , legacyStandaloneReleaseImport
  , releaseResourceId
  , releaseSubject
  , standaloneReleaseApplication
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.App.Deploy (RolloutEnv)
import Nagare.App.Deployments
  ( appConfigMapName
  , appDeploymentsPrefix
  )
import Nagare.Deploy (serviceUrl)
import Nagare.Dsl.Application
  ( Application
      ( access
      , brokers
      , databases
      , env
      , image
      , logicalKey
      , name
      , namespace
      , service
      , tasks
      , workers
      )
  )
import Nagare.Dsl.Application qualified as DslApp
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( Deployment
  , imageRefText
  , namespaceText
  , serviceNameText
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Application (applicationScopeId)
import Nagare.Resource.Inventory
  ( Declaration (Managed)
  , ManagedResource (dependencies)
  , ResourceBundle (ResourceBundle, declarations)
  , ScopeSnapshot
  , scopeBundles
  , snapshotScopes
  )
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
  ( DataPolicy (Stateless)
  , LifecyclePolicy (DeleteWhenUnreferenced)
  , Sensitivity (Private)
  )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
  ( InventoryError
  , ResourceId
  , ScopeId
  , SourceLocation (path)
  , inventoryError
  , kubernetesAddress
  , mintResourceId
  , mkLogicalKey
  , mkName
  )
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Static.Release
  ( StaticRelease (..)
  , StaticReleaseLog (..)
  , addRelease
  , emptyReleaseLog
  , extractReleaseLog
  , findRelease
  , renderReleaseConfigMapWith
  )

releaseResourceId :: ScopeId -> Application -> Either T.Text ResourceId
releaseResourceId owner app = do
  key <-
    maybe
      (mkLogicalKey (serviceNameText (app ^. #name)))
      Right
      (app ^. #logicalKey)
  role <- mkName "release-history"
  pure (mintResourceId owner key role)

releaseSubject :: Application -> T.Text
releaseSubject app =
  maybe
    (serviceNameText (app ^. #name))
    (serviceNameText . (^. #name))
    (app ^. #service)

-- | Read only the accepted application's immutable private release member.
-- A live ConfigMap is never an input channel: an old direct log must be
-- explicitly adopted before a reviewed rollout can take ownership of it.
acceptedApplicationReleaseLog ::
  ScopeSnapshot ->
  Map ResourceId (ManagedResource, ByteString) ->
  Application ->
  ResourceId ->
  Either T.Text StaticReleaseLog
acceptedApplicationReleaseLog snapshot native app cluster = do
  owner <- applicationScopeId app
  acceptedReleaseLog snapshot native owner app cluster

acceptedStandaloneReleaseLog ::
  ScopeSnapshot ->
  Map ResourceId (ManagedResource, ByteString) ->
  ScopeId ->
  Deployment ->
  ResourceId ->
  Either T.Text StaticReleaseLog
acceptedStandaloneReleaseLog snapshot native owner service cluster =
  acceptedReleaseLog snapshot native owner (standaloneReleaseApplication service) cluster

-- | Import the exact legacy ConfigMap shape before asking the lifecycle
-- planner to adopt its live incarnation. Importing the current record through
-- addRelease must preserve the log; native digest proof checks the live object.
legacyApplicationReleaseImport ::
  Application ->
  T.Text ->
  T.Text ->
  ByteString ->
  Either T.Text (StaticReleaseLog, StaticRelease)
legacyApplicationReleaseImport app expectedTag expectedImage bytes = do
  value <-
    first
      ("could not decode legacy release ConfigMap: " <>)
      (first T.pack (eitherDecodeStrict bytes))
  let subject = releaseSubject app
      expectedName = appConfigMapName subject
      expectedNamespace = namespaceText (app ^. #namespace)
  metadata <- case value of
    Object fields
      | KM.lookup "apiVersion" fields == Just (String "v1")
      , KM.lookup "kind" fields == Just (String "ConfigMap")
      , Just (Object meta) <- KM.lookup "metadata" fields ->
          Right meta
    _ -> Left "legacy release import is not a v1 ConfigMap"
  unless
    ( KM.lookup "name" metadata == Just (String expectedName)
        && KM.lookup "namespace" metadata == Just (String expectedNamespace)
    )
    (Left "legacy release import has a different name or namespace")
  logv <- extractReleaseLog bytes
  validateReleaseLog app logv
  currentId <-
    maybe
      (Left "legacy release import has no current release")
      Right
      (logv ^. #current)
  currentRelease <-
    maybe
      (Left "legacy release import has no current record")
      Right
      (findRelease currentId logv)
  unless
    ( currentRelease ^. #releaseId == expectedTag
        && currentRelease ^. #imageTag == expectedTag
        && currentRelease ^. #image == expectedImage
    )
    (Left "legacy current release does not match the selected rollout image and tag")
  unless
    (addRelease currentRelease logv == logv)
    (Left "legacy release history would change during import")
  pure (logv, currentRelease)

legacyStandaloneReleaseImport ::
  Deployment ->
  T.Text ->
  T.Text ->
  ByteString ->
  Either T.Text (StaticReleaseLog, StaticRelease)
legacyStandaloneReleaseImport service =
  legacyApplicationReleaseImport (standaloneReleaseApplication service)

acceptedReleaseLog ::
  ScopeSnapshot ->
  Map ResourceId (ManagedResource, ByteString) ->
  ScopeId ->
  Application ->
  ResourceId ->
  Either T.Text StaticReleaseLog
acceptedReleaseLog snapshot native owner app cluster = do
  releaseId <- releaseResourceId owner app
  expected <-
    kubernetesAddress
      cluster
      "v1"
      "ConfigMap"
      (Just (namespaceText (app ^. #namespace)))
      (appConfigMapName (releaseSubject app))
  case Map.lookup owner (snapshotScopes snapshot) of
    Nothing -> Right emptyReleaseLog
    Just (_, accepted) -> case [ resource
                               | bundle <- scopeBundles accepted
                               , Managed resource <- declarations bundle
                               , resource ^. #identity == releaseId
                               ] of
      [] -> Right emptyReleaseLog
      [resource] -> do
        unless
          (resource ^. #address == expected)
          (Left "accepted release metadata has a different native address")
        (bound, bytes) <-
          maybe
            (Left "accepted release metadata lacks private native evidence")
            Right
            (Map.lookup releaseId native)
        unless
          (bound == resource)
          (Left "accepted release metadata differs from its private native binding")
        logv <- extractReleaseLog bytes
        validateReleaseLog app logv
        pure logv
      _ -> Left "accepted application has duplicate release metadata"

standaloneReleaseApplication :: Deployment -> Application
standaloneReleaseApplication service =
  DslApp.Application
    { name = service ^. #name
    , logicalKey = service ^. #logicalKey
    , namespace = service ^. #namespace
    , image = service ^. #image
    , env = Map.empty
    , databases = []
    , brokers = []
    , access = Nothing
    , service = Just service
    , workers = []
    , tasks = []
    }

validateReleaseLog :: Application -> StaticReleaseLog -> Either T.Text ()
validateReleaseLog app logv = do
  let records = logv ^. #releases
      ids = map (^. #releaseId) records
      appName = releaseSubject app
      namespaceName = namespaceText (app ^. #namespace)
  unless
    ( length ids == Set.size (Set.fromList ids)
        && all
          ( \entry ->
              entry ^. #siteName == appName
                && entry ^. #namespace == namespaceName
          )
          records
        && maybe (null records) (`elem` ids) (logv ^. #current)
    )
    (Left "accepted release metadata has inconsistent application history")

compileApplicationRelease ::
  Application ->
  RolloutEnv ->
  ScopeId ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  [ResourceBundle] ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileApplicationRelease app rollout owner cluster namespaceId imageId priorBundles prior release source = do
  first invalid (validateReleaseLog app prior)
  let appName = releaseSubject app
      ns = namespaceText (app ^. #namespace)
      tag = rollout ^. #effectiveTag
  unless
    ( release ^. #siteName == appName
        && release ^. #namespace == ns
        && release ^. #releaseId == tag
        && release ^. #imageTag == tag
        && release ^. #image == imageRefText (rollout ^. #qualifiedImage)
        && release ^. #url
          == maybe
            ""
            ( \service ->
                serviceUrl
                  service
                  (rollout ^. #baseDomain)
            )
            (app ^. #service)
    )
    (Left (invalid "release metadata differs from the reviewed application or image"))
  releaseId <- first invalid (releaseResourceId owner app)
  let recorded = case findRelease tag prior of
        Just accepted
          | prior ^. #current == Just tag
          , (accepted & #createdAt .~ (release ^. #createdAt)) == release ->
              accepted
        _ -> release
      bytes =
        renderReleaseConfigMapWith
          appDeploymentsPrefix
          appName
          ns
          (addRelease recorded prior)
  value <- first (invalid . T.pack) (eitherDecodeStrict bytes)
  canonical <- first invalid (canonicalValue value)
  (resource, native) <-
    first
      (:| [])
      ( bindKubernetesObject
          KubernetesInput
            { resourceId = releaseId
            , ownerScope = owner
            , clusterId = cluster
            , inputObject = value
            , objectDigest = contentDigest canonical
            , lifecyclePolicy = DeleteWhenUnreferenced
            , inputDataPolicy = Stateless
            , inputSensitivity = Private
            , sourceLocation = source {path = path source <> "/release-history"}
            }
      )
  expected <-
    first
      invalid
      ( kubernetesAddress
          cluster
          "v1"
          "ConfigMap"
          (Just ns)
          (appConfigMapName appName)
      )
  unless
    (resource ^. #address == expected)
    (Left (invalid "release metadata render has an unexpected native address"))
  let workloadIds =
        [ member ^. #identity
        | bundle <- priorBundles
        , Managed member <- declarations bundle
        ]
      dependencies =
        map
          OrderedAfter
          ( Set.toAscList
              ( Set.fromList
                  (namespaceId : imageId : workloadIds)
              )
          )
      bound = resource {dependencies = dependencies}
  pure
    ( ResourceBundle [Managed bound] [] [] [] [] []
    , Map.singleton releaseId (bound, native)
    )
  where
    invalid message =
      inventoryError "invalid-application-release" message
        & #scopes
        .~ [owner]
        & #sources
        .~ [source]
        & (:| [])
