-- | Compile application-owned databases from the full typed Application.
-- Every direct object, credential template, and retained backup joins the
-- application's scope; the caller later adds workload and contribution bundles.
module Nagare.Inventory.Application
  ( compileApplicationDatabases
  , compileApplicationService
  , compileApplicationWorkers
  ) where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.App.Deploy (RolloutEnv, renderServiceObjects, renderWorkerObjects)
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Database (Database (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (pvcName)
import Nagare.Dsl.Types (DatabaseName, DomainSpec (..), DomainTls (AutomaticTls), Volume (..), VolumeName, databaseNameText, domainText, serviceNameText, volumeNameText)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (Worker (..))
import Nagare.Inventory.Database (compileDatabaseForBackend)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Application (applicationScopeId, deploymentResourceId, domainMappingResourceId, volumeResourceId, workerResourceId)
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (..), LifecyclePolicy (..), Sensitivity (Private))
import Nagare.Resource.Policy (RecoveryIntent)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | Compile each application worker's PVCs and Deployment from one render.
-- Recovery is keyed by the generated volume ResourceId so an unrelated
-- worker with the same volume display name cannot borrow its authority.
compileApplicationWorkers
  :: Application -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map ResourceId RecoveryIntent
  -> SourceLocation
  -> Either (NonEmpty InventoryError)
       ([ResourceBundle], Map ResourceId (ManagedResource, ByteString))
compileApplicationWorkers app rollout cluster namespaceId imageId recoveryById source = do
  owner <- first invalid (applicationScopeId app)
  compiled <- traverse (compileWorker owner) (app ^. #workers)
  let bundles = map fst compiled
      native = Map.unions (map snd compiled)
  _ <- mkScopeDeclaration owner bundles
  unless (Map.size native == sum (map (Map.size . snd) compiled))
    (Left (invalid "worker native members share an identity"))
  pure (bundles, native)
  where
    invalid message = single (inventoryError "invalid-application-worker" message
      & #sources .~ [source])
    single errorValue = errorValue :| []
    compileWorker owner worker = do
      workerKey <- maybe (first invalid (mkLogicalKey (serviceNameText (worker ^. #name)))) Right
        (worker ^. #logicalKey)
      volumeRole <- first invalid (mkName ("worker-" <> logicalKeyText workerKey <> "-pvc"))
      workerId <- first invalid (workerResourceId owner (known "worker") worker)
      rendered <- first invalid (renderWorkerObjects rollout worker)
      let volumes = worker ^. #volumes
          (volumeRendered, workerRendered) = splitAt (length volumes) rendered
      workerBytes <- case workerRendered of
        [("worker", manifest)] -> Right manifest
        _ -> Left (invalid "worker renderer produced unexpected members")
      unless (length volumeRendered == length volumes && all ((== "worker") . fst) volumeRendered)
        (Left (invalid "worker PVC renderer produced unexpected members"))
      volumeMembers <- traverse (compileVolume owner worker volumeRole)
        (zip volumes (map snd volumeRendered))
      let volumeIds = map ((^. #identity) . fst) volumeMembers
          workerSource = source {path = path source <> "/worker/" <> serviceNameText (worker ^. #name)}
      workerMember@(declaration, _) <- bindOne owner workerId DeleteWhenUnreferenced Stateless
        (map OrderedAfter (namespaceId : imageId : volumeIds)) workerSource workerBytes
      expected <- first invalid (kubernetesAddress cluster "apps/v1" "Deployment"
        (Just (rollout ^. #namespace)) (serviceNameText (worker ^. #name)))
      unless (declaration ^. #address == expected)
        (Left (invalid "worker render has an unexpected Deployment address"))
      let members = volumeMembers <> [workerMember]
          bundle = ResourceBundle [Managed member | (member, _) <- members] [] [] [] [] []
          native = Map.fromList [(member ^. #identity, pair) | pair@(member, _) <- members]
      _ <- mkScopeDeclaration owner [bundle]
      unless (Map.size native == length members)
        (Left (invalid "worker PVC members share an identity"))
      pure (bundle, native)
    compileVolume owner worker role (volume, bytes) = do
      volumeId <- first invalid (volumeResourceId owner role volume)
      recovery <- case volume ^. #retention of
        Dsl.Retain -> Just <$> maybe (Left (invalid "retained worker volume has no recovery intent")) Right
          (Map.lookup volumeId recoveryById)
        Dsl.Delete -> Right Nothing
      let volumeSource = source
            {path = path source <> "/worker/" <> serviceNameText (worker ^. #name)
              <> "/volume/" <> volumeNameText (volume ^. #name)}
          lifecycle = if volume ^. #retention == Dsl.Retain then Retain else DeleteWhenUnreferenced
      member@(declaration, _) <- bindOne owner volumeId lifecycle
        (maybe Stateless Durable recovery) [OrderedAfter namespaceId] volumeSource bytes
      expected <- first invalid (kubernetesAddress cluster "v1" "PersistentVolumeClaim"
        (Just (rollout ^. #namespace))
        (pvcName (serviceNameText (worker ^. #name)) (volumeNameText (volume ^. #name))))
      unless (declaration ^. #address == expected)
        (Left (invalid "worker volume render has an unexpected PVC address"))
      pure member
    known = either (error . T.unpack) id . mkName
    bindOne owner resource lifecycle dataPolicy dependencies location bytes = do
      value <- first (invalid . T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      canonical <- first invalid (canonicalValue value)
      (declaration, native) <- first single (bindKubernetesObject KubernetesInput
        { resourceId = resource
        , ownerScope = owner
        , clusterId = cluster
        , inputObject = value
        , objectDigest = contentDigest canonical
        , lifecyclePolicy = lifecycle
        , inputDataPolicy = dataPolicy
        , inputSensitivity = Private
        , sourceLocation = location
        })
      pure (declaration {dependencies = dependencies}, native)

-- | The service, its volume claims, and automatic-TLS domain mappings, all
-- bound to the same render used by preview. Supplied TLS needs an explicit
-- capability dependency and refuses until that witness is available.
compileApplicationService
  :: Application -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map VolumeName RecoveryIntent
  -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileApplicationService app rollout cluster namespaceId imageId recoveryByVolume source = do
  owner <- first invalid (applicationScopeId app)
  service <- maybe (Left (invalid "application has no web service")) Right (app ^. #service)
  unless (all ((== AutomaticTls) . (^. #tls)) (service ^. #domains))
    (Left (invalid "supplied TLS domain requires a typed secret dependency"))
  resource <- first invalid (deploymentResourceId owner (known "service") service)
  rendered <- first invalid (renderServiceObjects rollout service)
  let volumes = service ^. #volumes
      (volumeRendered, serviceRendered) = splitAt (length volumes) rendered
  serviceBytes <- case serviceRendered of
    ("service", manifest) : _ -> Right manifest
    _ -> Left (invalid "application service renderer produced unexpected members")
  let domainRendered = drop 1 serviceRendered
      domains = service ^. #domains
  unless (length domainRendered == length domains && all ((== "service") . fst) domainRendered)
    (Left (invalid "application domain renderer produced unexpected members"))
  unless (length volumeRendered == length volumes && all ((== "service") . fst) volumeRendered)
    (Left (invalid "application volume renderer produced unexpected members"))
  volumeMembers <- traverse (compileVolume owner service) (zip volumes (map snd volumeRendered))
  let volumeIds = map ((^. #identity) . fst) volumeMembers
  serviceMember <- bindOne owner resource DeleteWhenUnreferenced Stateless
    (map OrderedAfter (namespaceId : imageId : volumeIds)) source serviceBytes
  domainMembers <- traverse (compileDomain owner resource) (zip domains (map snd domainRendered))
  let members = volumeMembers <> [serviceMember] <> domainMembers
      declarations = [Managed declaration | (declaration, _) <- members]
      native = Map.fromList [(declaration ^. #identity, member) | member@(declaration, _) <- members]
      bundle = ResourceBundle declarations [] [] [] [] []
  _ <- mkScopeDeclaration owner [bundle]
  unless (Map.size native == length members)
    (Left (invalid "application service members share an identity"))
  pure (bundle, native)
  where
    known = either (error . T.unpack) id . mkName
    invalid message = single (inventoryError "invalid-application-service" message
      & #sources .~ [source])
    single errorValue = errorValue :| []
    compileVolume owner service (volume, bytes) = do
      recovery <- case volume ^. #retention of
        Dsl.Retain -> Just <$> maybe (Left (invalid "retained service volume has no recovery intent")) Right
          (Map.lookup (volume ^. #name) recoveryByVolume)
        Dsl.Delete -> Right Nothing
      volumeId <- first invalid (volumeResourceId owner (known "service-pvc") volume)
      let volumeSource = source
            {path = path source <> "/volume/" <> volumeNameText (volume ^. #name)}
          lifecycle = if volume ^. #retention == Dsl.Retain then Retain else DeleteWhenUnreferenced
          dataPolicy = maybe Stateless Durable recovery
      member@(declaration, _) <- bindOne owner volumeId lifecycle dataPolicy
        [OrderedAfter namespaceId] volumeSource bytes
      expected <- first invalid (kubernetesAddress cluster "v1" "PersistentVolumeClaim"
        (Just (rollout ^. #namespace))
        (pvcName (serviceNameText (service ^. #name)) (volumeNameText (volume ^. #name))))
      unless (declaration ^. #address == expected)
        (Left (invalid "service volume render has an unexpected PVC address"))
      pure member
    compileDomain owner serviceId (domain, bytes) = do
      domainId <- first invalid (domainMappingResourceId owner domain)
      host <- first invalid (mkName (domainText (domain ^. #domain)))
      let domainSource = source
            {path = path source <> "/domain/" <> domainText (domain ^. #domain)}
      (declaration, native) <- bindOne owner domainId DeleteWhenUnreferenced Stateless
        [OrderedAfter namespaceId, OrderedAfter serviceId] domainSource bytes
      expected <- first invalid (kubernetesAddress cluster "serving.knative.dev/v1beta1"
        "DomainMapping" (Just (rollout ^. #namespace)) (domainText (domain ^. #domain)))
      unless (declaration ^. #address == expected)
        (Left (invalid "application domain render has an unexpected address"))
      pure (declaration {aliases = [Hostname host]}, native)
    bindOne owner resource lifecycle dataPolicy dependencies location bytes = do
      value <- first (invalid . T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      canonical <- first invalid (canonicalValue value)
      (declaration, native) <- first single (bindKubernetesObject KubernetesInput
        { resourceId = resource
        , ownerScope = owner
        , clusterId = cluster
        , inputObject = value
        , objectDigest = contentDigest canonical
        , lifecyclePolicy = lifecycle
        , inputDataPolicy = dataPolicy
        , inputSensitivity = Private
        , sourceLocation = location
        })
      pure (declaration {dependencies = dependencies}, native)

compileApplicationDatabases
  :: Application
  -> ResourceId
  -> Maybe ResourceId
  -> Map DatabaseName RecoveryIntent
  -> StoreBackend
  -> SourceLocation
  -> Either (NonEmpty InventoryError)
       ([ResourceBundle], Map ResourceId (ManagedResource, ByteString))
compileApplicationDatabases app cluster namespaceId recoveryByDatabase backend source = do
  _ <- first invalidApp (mkApplication app)
  owner <- first invalidApp (applicationScopeId app)
  compiled <- traverse (compileOne owner) (app ^. #databases)
  let bundles = map fst compiled
      native = Map.unions (map snd compiled)
  -- Validate the combined member set, including duplicate logical keys that
  -- individual database builders cannot see across separate databases.
  _ <- mkScopeDeclaration owner bundles
  unless (Map.size native == sum (map (Map.size . snd) compiled))
    (Left (single (inventoryError "duplicate-app-database" "database native members share an identity"
      & #scopes .~ [owner] & #sources .~ [source])))
  pure (bundles, native)
  where
    invalidApp message = single (inventoryError "invalid-application" message
      & #sources .~ [source])
    single errorValue = errorValue :| []
    compileOne owner database = do
      recovery <- maybe
        (Left (single (inventoryError "missing-database-recovery" "application database has no recovery intent"
          & #scopes .~ [owner]
          & #sources .~ [source])))
        Right (Map.lookup (database ^. #name) recoveryByDatabase)
      let databaseSource = source
            {path = path source <> "/database/" <> databaseNameText (database ^. #name)}
          input = DatabaseDirectInput database owner cluster namespaceId recovery databaseSource
      compileDatabaseForBackend input backend
