-- | Worker responsibilities; internal implementation behind Nagare.Inventory.Application.
module Nagare.Inventory.Application.Worker
  ( compileApplicationWorkers
  , compileStandaloneWorker
  , compileStandaloneWorkerWithDependencies
  , compileStandaloneWorkerWithDependenciesAndBuild
  )
where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.App.Deploy (RolloutEnv, renderWorkerObjects)
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Application qualified as DslApp
import Nagare.Dsl.Broker (BrokerName, TopicName)
import Nagare.Dsl.Config (encodeWorker)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (pvcName)
import Nagare.Dsl.Types
  ( DatabaseName
  , SecretName
  , namespaceText
  , serviceNameText
  , volumeNameText
  )
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (Worker (..))
import Nagare.Env.Generated (mergeGenerated)
import Nagare.Inventory.Application.Environment
  ( databaseDependencies
  , runtimeSecretNames
  , runtimeSecretNamesWithBuild
  , secretDependency
  , standaloneBrokerEnvironment
  , standaloneDatabaseEnvironment
  , stripBuildSecretEnv
  )
import Nagare.Inventory.Application.Policy (configDigestOf)
import Nagare.Inventory.Application.Types (DatabaseBinding (..))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Application
  ( applicationScopeId
  , volumeResourceId
  , workerResourceId
  )
import Nagare.Resource.Inventory
  ( Declaration (Managed)
  , ManagedResource (dependencies)
  , ResourceBundle (ResourceBundle)
  , ScopeDeclaration
  , mkScopeDeclaration
  , withScopeConfigDigest
  )
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
  ( DataPolicy (Durable, Stateless)
  , LifecyclePolicy (DeleteWhenUnreferenced, Retain)
  , RecoveryIntent
  , Sensitivity (Private)
  )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
  ( InventoryError
  , ProviderAddress (Kubernetes)
  , ResourceId
  , ScopeId
  , ScopeKind (Standalone)
  , SourceLocation (path)
  , inventoryError
  , kubernetesAddress
  , logicalKeyText
  , mkLogicalKey
  , mkName
  , nameText
  , scopeKind
  )
import Nagare.Resource.Wire (canonicalValue)

-- | Compile each application worker's PVCs and Deployment from one render.
-- Recovery is keyed by the generated volume ResourceId so an unrelated
-- worker with the same volume display name cannot borrow its authority.
compileApplicationWorkers ::
  Application ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map ResourceId RecoveryIntent ->
  Map SecretName Declaration ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    ([ResourceBundle], Map ResourceId (ManagedResource, ByteString))
compileApplicationWorkers app rollout cluster namespaceId imageId recoveryById envSecrets source = do
  _ <- first invalid (mkApplication app)
  owner <- first invalid (applicationScopeId app)
  compileWorkersWithOwner owner app rollout cluster namespaceId imageId recoveryById envSecrets source
  where
    invalid message =
      inventoryError "invalid-application-worker" message
        & #sources
        .~ [source]
        & (:| [])

-- | A single worker uses its own scope while retaining the same native
-- Deployment/PVC binder and recovery rules as an application worker.
compileStandaloneWorker ::
  ScopeId ->
  Worker ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map ResourceId RecoveryIntent ->
  Map SecretName Declaration ->
  Map BrokerName Declaration ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneWorker owner worker rollout cluster namespaceId imageId recovery envSecrets brokerServices =
  compileStandaloneWorkerWithDependencies
    owner
    worker
    rollout
    cluster
    namespaceId
    imageId
    recovery
    envSecrets
    brokerServices
    Map.empty
    Map.empty

compileStandaloneWorkerWithDependencies ::
  ScopeId ->
  Worker ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map ResourceId RecoveryIntent ->
  Map SecretName Declaration ->
  Map BrokerName Declaration ->
  Map BrokerName (Map TopicName Declaration) ->
  Map DatabaseName DatabaseBinding ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneWorkerWithDependencies owner worker rollout cluster namespaceId imageId recovery envSecrets brokerServices brokerTopics databaseBindings source = do
  unless
    (scopeKind owner == Standalone)
    (Left (invalid "worker requires a standalone owner"))
  unless
    ( rollout ^. #appName == serviceNameText (worker ^. #name)
        && rollout ^. #namespace == namespaceText (worker ^. #namespace)
        && Map.null (rollout ^. #appEnv)
    )
    (Left (invalid "standalone worker rollout differs from its declared identity or environment"))
  (databaseEnv, databaseIds, databaseSecrets) <-
    standaloneDatabaseEnvironment
      cluster
      (worker ^. #namespace)
      (worker ^. #databases)
      databaseBindings
      invalid
  (brokerEnv, brokerIds) <-
    standaloneBrokerEnvironment
      cluster
      (namespaceText (worker ^. #namespace))
      (worker ^. #brokers)
      brokerServices
      brokerTopics
      invalid
  let worker' =
        worker
          & #env
          %~ mergeGenerated (mergeGenerated brokerEnv databaseEnv)
          & #brokers
          .~ []
          & #databases
          .~ []
  requiredSecrets <-
    first
      invalid
      ( runtimeSecretNames
          (Map.elems (worker' ^. #env))
      )
  unless
    ( Map.keysSet envSecrets
        == Set.fromList requiredSecrets
          `Set.difference` Map.keysSet databaseSecrets
    )
    (Left (invalid "standalone runtime Secret dependencies differ from declared external references"))
  let allSecrets = Map.union databaseSecrets envSecrets
  let app =
        DslApp.Application
          { name = worker ^. #name
          , logicalKey = Nothing
          , namespace = worker ^. #namespace
          , image = worker ^. #image
          , env = Map.empty
          , databases = []
          , brokers = []
          , access = Nothing
          , service = Nothing
          , workers = [worker']
          , tasks = []
          }
  _ <- first invalid (mkApplication app)
  (bundles, native) <-
    compileWorkersWithOwner
      owner
      app
      rollout
      cluster
      namespaceId
      imageId
      recovery
      allSecrets
      source
  let addBrokerEdges resource = case resource ^. #address of
        Kubernetes _ "apps" kind _ _
          | nameText kind == "deployment" ->
              resource & #dependencies %~ (<> map OrderedAfter (brokerIds <> databaseIds))
        _ -> resource
      addDeclaration = \case
        Managed resource -> Managed (addBrokerEdges resource)
        declaration -> declaration
      updatedBundles = map (\bundle -> bundle & #declarations %~ map addDeclaration) bundles
      updatedNative = Map.map (\(resource, bytes) -> (addBrokerEdges resource, bytes)) native
  configDigest <- first invalid (configDigestOf (encodeWorker worker))
  scope <- withScopeConfigDigest configDigest <$> mkScopeDeclaration owner updatedBundles
  pure (scope, updatedNative)
  where
    invalid message =
      inventoryError "invalid-standalone-worker" message
        & #sources
        .~ [source]
        & (:| [])

compileStandaloneWorkerWithDependenciesAndBuild ::
  Set.Set SecretName ->
  ScopeId ->
  Worker ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map ResourceId RecoveryIntent ->
  Map SecretName Declaration ->
  Map BrokerName Declaration ->
  Map BrokerName (Map TopicName Declaration) ->
  Map DatabaseName DatabaseBinding ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneWorkerWithDependenciesAndBuild buildSecrets owner worker rollout cluster namespaceId imageId recovery envSecrets brokerServices brokerTopics databaseBindings source = do
  _ <-
    first
      invalid
      ( runtimeSecretNamesWithBuild
          buildSecrets
          (Map.elems (worker ^. #env))
      )
  let runtimeWorker = worker & #env %~ stripBuildSecretEnv
  (scope, native) <-
    compileStandaloneWorkerWithDependencies
      owner
      runtimeWorker
      rollout
      cluster
      namespaceId
      imageId
      recovery
      envSecrets
      brokerServices
      brokerTopics
      databaseBindings
      source
  digest <- first invalid (configDigestOf (encodeWorker worker))
  pure (withScopeConfigDigest digest scope, native)
  where
    invalid message =
      inventoryError "invalid-standalone-worker" message
        & #sources
        .~ [source]
        & (:| [])

compileWorkersWithOwner ::
  ScopeId ->
  Application ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map ResourceId RecoveryIntent ->
  Map SecretName Declaration ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    ([ResourceBundle], Map ResourceId (ManagedResource, ByteString))
compileWorkersWithOwner scopeOwner app rollout cluster namespaceId imageId recoveryById envSecrets source = do
  compiled <- traverse (compileWorker scopeOwner) (app ^. #workers)
  let bundles = map fst compiled
      native = Map.unions (map snd compiled)
  _ <- mkScopeDeclaration scopeOwner bundles
  unless
    (Map.size native == sum (map (Map.size . snd) compiled))
    (Left (invalid "worker native members share an identity"))
  pure (bundles, native)
  where
    invalid message =
      single
        ( inventoryError "invalid-application-worker" message
            & #sources
            .~ [source]
        )
    single errorValue = errorValue :| []
    compileWorker owner worker = do
      unless
        (null (worker ^. #brokers))
        (Left (invalid "worker broker bindings require typed broker dependencies"))
      databasePrerequisites <- databaseDependencies app owner (worker ^. #databases) invalid
      secretNames <-
        first
          invalid
          ( runtimeSecretNames
              (Map.elems (rollout ^. #appEnv) <> Map.elems (worker ^. #env))
          )
      secretIds <-
        traverse
          ( first invalid
              . secretDependency
                cluster
                (rollout ^. #namespace)
                envSecrets
          )
          secretNames
      workerKey <-
        maybe
          (first invalid (mkLogicalKey (serviceNameText (worker ^. #name))))
          Right
          (worker ^. #logicalKey)
      volumeRole <- first invalid (mkName ("worker-" <> logicalKeyText workerKey <> "-pvc"))
      workerId <- first invalid (workerResourceId owner (known "worker") worker)
      rendered <- first invalid (renderWorkerObjects rollout worker)
      let volumes = worker ^. #volumes
          (volumeRendered, workerRendered) = splitAt (length volumes) rendered
      workerBytes <- case workerRendered of
        [("worker", manifest)] -> Right manifest
        _ -> Left (invalid "worker renderer produced unexpected members")
      unless
        (length volumeRendered == length volumes && all ((== "worker") . fst) volumeRendered)
        (Left (invalid "worker PVC renderer produced unexpected members"))
      volumeMembers <-
        traverse
          (compileVolume owner worker volumeRole)
          (zip volumes (map snd volumeRendered))
      let volumeIds = map ((^. #identity) . fst) volumeMembers
          workerSource = source {path = path source <> "/worker/" <> serviceNameText (worker ^. #name)}
      workerMember@(declaration, _) <-
        bindOne
          owner
          workerId
          DeleteWhenUnreferenced
          Stateless
          (map OrderedAfter (namespaceId : imageId : volumeIds <> databasePrerequisites <> secretIds))
          workerSource
          workerBytes
      expected <-
        first
          invalid
          ( kubernetesAddress
              cluster
              "apps/v1"
              "Deployment"
              (Just (rollout ^. #namespace))
              (serviceNameText (worker ^. #name))
          )
      unless
        (declaration ^. #address == expected)
        (Left (invalid "worker render has an unexpected Deployment address"))
      let members = volumeMembers <> [workerMember]
          bundle = ResourceBundle [Managed member | (member, _) <- members] [] [] [] [] []
          native = Map.fromList [(member ^. #identity, pair) | pair@(member, _) <- members]
      _ <- mkScopeDeclaration owner [bundle]
      unless
        (Map.size native == length members)
        (Left (invalid "worker PVC members share an identity"))
      pure (bundle, native)
    compileVolume owner worker role (volume, bytes) = do
      volumeId <- first invalid (volumeResourceId owner role volume)
      recovery <- case volume ^. #retention of
        Dsl.Retain ->
          Just
            <$> maybe
              (Left (invalid "retained worker volume has no recovery intent"))
              Right
              (Map.lookup volumeId recoveryById)
        Dsl.Delete -> Right Nothing
      let volumeSource =
            source
              { path =
                  path source
                    <> "/worker/"
                    <> serviceNameText (worker ^. #name)
                    <> "/volume/"
                    <> volumeNameText (volume ^. #name)
              }
          lifecycle = if volume ^. #retention == Dsl.Retain then Retain else DeleteWhenUnreferenced
      member@(declaration, _) <-
        bindOne
          owner
          volumeId
          lifecycle
          (maybe Stateless Durable recovery)
          [OrderedAfter namespaceId]
          volumeSource
          bytes
      expected <-
        first
          invalid
          ( kubernetesAddress
              cluster
              "v1"
              "PersistentVolumeClaim"
              (Just (rollout ^. #namespace))
              (pvcName (serviceNameText (worker ^. #name)) (volumeNameText (volume ^. #name)))
          )
      unless
        (declaration ^. #address == expected)
        (Left (invalid "worker volume render has an unexpected PVC address"))
      pure member
    known = either (error . T.unpack) id . mkName
    bindOne owner resource lifecycle dataPolicy dependencies location bytes = do
      value <- first (invalid . T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      canonical <- first invalid (canonicalValue value)
      (declaration, native) <-
        first
          single
          ( bindKubernetesObject
              KubernetesInput
                { resourceId = resource
                , ownerScope = owner
                , clusterId = cluster
                , inputObject = value
                , objectDigest = contentDigest canonical
                , lifecyclePolicy = lifecycle
                , inputDataPolicy = dataPolicy
                , inputSensitivity = Private
                , sourceLocation = location
                }
          )
      pure (declaration {dependencies = dependencies}, native)
