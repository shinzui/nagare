-- | Compile application-owned databases from the full typed Application.
-- Every direct object, credential template, and retained backup joins the
-- application's scope; the caller later adds workload and contribution bundles.
module Nagare.Inventory.Application
  ( ApplicationScopeInput (..)
  , compileApplicationScope
  , compileApplicationDatabases
  , compileApplicationService
  , compileStandaloneService
  , compileApplicationWorkers
  , compileApplicationTasks
  , applicationNativeOwned
  , nativeWorkloadOwned
  , acceptedApplicationImage
  , databaseRecoveryBindings
  , acceptedSecretBindings
  , applicationVolumeRecoveryBindings
  ) where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.App.Deploy (RolloutEnv, renderServiceObjects, renderTaskObjects, renderWorkerObjects)
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Database.Connection (ConnIdentity (..), connectionEnv, mergeConnectionEnvs)
import Nagare.Dsl.Database (Database (..), Engine (..), dbSecretName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (pvcName)
import Nagare.Dsl.Database.Render (dbConfigMapName, dbPvcName)
import Nagare.Dsl.Types (DatabaseName, Deployment (..), DomainSpec (..), DomainTls (..), EnvScope (Runtime), EnvVar (..), ScopedEnvVar (..), SecretName, Volume (..), VolumeName, databaseNameText, domainText, mkEnvName, mkSecretName, namespaceText, runtimeScoped, secretNameText, serviceNameText, volumeNameText)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (Worker (..))
import Nagare.Dsl.Task (Task (..), mkTask, taskResourceName)
import Nagare.Inventory.Database (compileDatabaseForBackend)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Env.Generated (mergeGenerated)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Application (applicationScopeId, deploymentResourceId, domainMappingResourceId, taskResourceId, volumeResourceId, workerResourceId)
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (..), LifecyclePolicy (..), Sensitivity (Private))
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | Match every native object that the legacy aggregate deploy can write.
-- The check uses provider addresses so a renamed logical key cannot bypass
-- accepted or retained ownership. Cluster context is checked by the store.
applicationNativeOwned :: Application -> [ManagedResource] -> Bool
applicationNativeOwned app = any matches
  where
    namespaceName = namespaceText (app ^. #namespace)
    objects =
      [("serving.knative.dev", "service", serviceNameText (service ^. #name))
      | service <- maybe [] pure (app ^. #service)]
        <> [("", "persistentvolumeclaim", pvcName (serviceNameText (service ^. #name))
              (volumeNameText (volume ^. #name)))
           | service <- maybe [] pure (app ^. #service), volume <- service ^. #volumes]
        <> [("serving.knative.dev", "domainmapping", domainText (domain ^. #domain))
           | service <- maybe [] pure (app ^. #service), domain <- service ^. #domains]
        <> [("apps", "deployment", serviceNameText (worker ^. #name))
           | worker <- app ^. #workers]
        <> [("", "persistentvolumeclaim", pvcName (serviceNameText (worker ^. #name))
              (volumeNameText (volume ^. #name)))
           | worker <- app ^. #workers, volume <- worker ^. #volumes]
        <> [("apps", "statefulset", databaseNameText (database ^. #name))
           | database <- app ^. #databases]
        <> [("", "secret", dbSecretName (databaseNameText (database ^. #name)))
           | database <- app ^. #databases]
        <> [("", "persistentvolumeclaim", dbPvcName (databaseNameText (database ^. #name)))
           | database <- app ^. #databases]
        <> [("", "service", databaseNameText (database ^. #name))
           | database <- app ^. #databases]
        <> [("", "configmap", dbConfigMapName (databaseNameText (database ^. #name)))
           | database <- app ^. #databases, database ^. #engine == ClickHouse]
        <> [("batch", "cronjob", "nagare-dbbackup-" <> databaseNameText (database ^. #name))
           | database <- app ^. #databases, database ^. #retention /= Dsl.Delete]
        <> [("batch", "cronjob", taskResourceName (serviceNameText (task ^. #name)))
           | task <- app ^. #tasks]
    matches resource = case resource ^. #address of
      Kubernetes _ group kind (Just namespace) name ->
        nameText namespace == namespaceName
          && (group, nameText kind, nameText name) `elem` objects
      _ -> False

-- | A direct single-workload command's native identity, including resources
-- retained after their original scope retired.
nativeWorkloadOwned :: T.Text -> T.Text -> T.Text -> T.Text -> [ManagedResource] -> Bool
nativeWorkloadOwned group kind name namespaceName = any matches
  where
    matches resource = case resource ^. #address of
      Kubernetes _ nativeGroup nativeKind (Just nativeNamespace) nativeName ->
        nativeGroup == group
          && nameText nativeKind == kind
          && nameText nativeName == name
          && nameText nativeNamespace == namespaceName
      _ -> False

-- | A reviewed rollout may depend only on an already accepted OCI publication
-- whose destination is the exact tagged image embedded in its native manifests.
acceptedApplicationImage :: ScopeSnapshot -> ResourceId -> T.Text -> Either T.Text ()
acceptedApplicationImage snapshot imageId taggedImage =
  case [resource
       | (_, scope) <- Map.elems (snapshotScopes snapshot)
       , bundle <- scopeBundles scope
       , Managed resource <- declarations bundle
       , resource ^. #identity == imageId] of
    [resource] -> case (resource ^. #executor, resource ^. #address, resource ^. #spec) of
      (ArtifactExecutor, Artifact _ _, ArtifactPublication kind destination _ _)
        | nameText kind == "oci-image" && destination == taggedImage -> Right ()
      _ -> Left "accepted image resource is not the requested OCI publication"
    _ -> Left "image resource is absent or ambiguous in accepted inventory"

-- | Require one explicit recovery binding for every application-owned
-- database. The credential name is derived from the typed database identity;
-- the operator supplies only the backup identity and key version.
databaseRecoveryBindings :: Application -> [T.Text] -> Either T.Text (Map DatabaseName RecoveryIntent)
databaseRecoveryBindings app raw = do
  pairs <- traverse parseOne raw
  let bindings = Map.fromList pairs
      declared = Set.fromList (map (^. #name) (app ^. #databases))
  unless (length pairs == Map.size bindings)
    (Left "database recovery bindings repeat a database")
  unless (Map.keysSet bindings == declared)
    (Left "database recovery bindings must cover exactly the declared databases")
  pure bindings
  where
    parseOne value = case (T.splitOn "=" value) of
      [databaseText, recoveryText] -> case T.splitOn ":" recoveryText of
        [backupText, versionText] -> do
          database <- maybe (Left "database recovery names an undeclared database") Right
            (find ((== databaseText) . databaseNameText . (^. #name)) (app ^. #databases))
          backup <- mkName backupText
          version <- mkName versionText
          credential <- mkName (dbSecretName databaseText)
          pure (database ^. #name, RecoveryIntent backup (mkSecretRef credential version NE.:| []))
        _ -> Left "database recovery must be NAME=BACKUP:KEY_VERSION"
      _ -> Left "database recovery must be NAME=BACKUP:KEY_VERSION"

-- | Resolve operator-supplied Secret identities only from accepted history.
-- Consumers then check that the binding set and exact native address match
-- their declared TLS or runtime environment references.
acceptedSecretBindings
  :: ScopeSnapshot -> [ResourceId] -> Either T.Text (Map SecretName Declaration)
acceptedSecretBindings snapshot ids = do
  pairs <- traverse resolve ids
  let bindings = Map.fromList pairs
  unless (length pairs == Map.size bindings)
    (Left "accepted Secret bindings repeat a native name")
  pure bindings
  where
    resources =
      [ resource
      | (_, scope) <- Map.elems (snapshotScopes snapshot)
      , bundle <- scopeBundles scope
      , Managed resource <- declarations bundle
      ]
    resolve resourceId = case filter ((== resourceId) . (^. #identity)) resources of
      [resource] -> case resource ^. #address of
        Kubernetes _ "" kind (Just _) nativeName | nameText kind == "secret" -> do
          secretName <- mkSecretName (nameText nativeName)
          pure (secretName, Managed resource)
        _ -> Left "accepted resource is not a namespaced Kubernetes Secret"
      _ -> Left "Secret resource is absent or ambiguous in accepted inventory"

-- | Bind retained PVC recovery by typed Service volume name and by each
-- worker volume's stable ResourceId. Throwaway volumes cannot borrow a
-- recovery decision, and a missing retained volume refuses planning.
applicationVolumeRecoveryBindings
  :: Application -> [T.Text] -> [T.Text]
  -> Either T.Text (Map VolumeName RecoveryIntent, Map ResourceId RecoveryIntent)
applicationVolumeRecoveryBindings app serviceRaw workerRaw = do
  owner <- applicationScopeId app
  servicePairs <- traverse parseService serviceRaw
  workerPairs <- traverse (parseWorker owner) workerRaw
  let serviceBindings = Map.fromList servicePairs
      workerBindings = Map.fromList workerPairs
      serviceExpected = Set.fromList
        [volume ^. #name
        | service <- maybe [] pure (app ^. #service)
        , volume <- service ^. #volumes, volume ^. #retention == Dsl.Retain]
  workerExpected <- Set.fromList <$> traverse (workerVolumeId owner)
    [(worker, volume) | worker <- app ^. #workers
      , volume <- worker ^. #volumes, volume ^. #retention == Dsl.Retain]
  unless (length servicePairs == Map.size serviceBindings
      && Map.keysSet serviceBindings == serviceExpected)
    (Left "service volume recovery must cover exactly the retained volumes")
  unless (length workerPairs == Map.size workerBindings
      && Map.keysSet workerBindings == workerExpected)
    (Left "worker volume recovery must cover exactly the retained volumes")
  pure (serviceBindings, workerBindings)
  where
    parseRecovery value = case T.splitOn ":" value of
      [backupText, keyText, versionText] -> do
        backup <- mkName backupText
        key <- mkName keyText
        version <- mkName versionText
        pure (RecoveryIntent backup (mkSecretRef key version NE.:| []))
      _ -> Left "volume recovery must be BACKUP:KEY:VERSION"
    parseService value = case T.splitOn "=" value of
      [volumeText, recoveryText] -> do
        volume <- maybe (Left "service volume recovery names an undeclared volume") Right
          (find ((== volumeText) . volumeNameText . (^. #name))
            (maybe [] (^. #volumes) (app ^. #service)))
        recovery <- parseRecovery recoveryText
        pure (volume ^. #name, recovery)
      _ -> Left "service volume recovery must be VOLUME=BACKUP:KEY:VERSION"
    parseWorker owner value = case T.splitOn "=" value of
      [workloadText, recoveryText] -> case T.splitOn "/" workloadText of
        [workerText, volumeText] -> do
          worker <- maybe (Left "worker volume recovery names an undeclared worker") Right
            (find ((== workerText) . serviceNameText . (^. #name)) (app ^. #workers))
          volume <- maybe (Left "worker volume recovery names an undeclared volume") Right
            (find ((== volumeText) . volumeNameText . (^. #name)) (worker ^. #volumes))
          resourceId <- workerVolumeId owner (worker, volume)
          recovery <- parseRecovery recoveryText
          pure (resourceId, recovery)
        _ -> Left "worker volume recovery must be WORKER/VOLUME=BACKUP:KEY:VERSION"
      _ -> Left "worker volume recovery must be WORKER/VOLUME=BACKUP:KEY:VERSION"
    workerVolumeId owner (worker, volume) = do
      workerKey <- maybe (mkLogicalKey (serviceNameText (worker ^. #name))) Right
        (worker ^. #logicalKey)
      role <- mkName ("worker-" <> logicalKeyText workerKey <> "-pvc")
      volumeResourceId owner role volume

-- | The reviewed dependencies and recovery decisions supplied by the command
-- service. A caller must bind the namespace and image publication to accepted
-- identities before producing an application scope.
data ApplicationScopeInput = ApplicationScopeInput
  { scopeApplication :: !Application
  , scopeRollout :: !RolloutEnv
  , scopeCluster :: !ResourceId
  , scopeNamespace :: !ResourceId
  -- ^ Exact Namespace identity used by workload dependencies.
  , scopeNamespaceContributionOwner :: !(Maybe ScopeId)
  -- ^ When present, request this owner to compose the namespace. Composition
  -- still requires that owner's explicit grant to the application scope.
  , scopeImage :: !ResourceId
  , scopeDatabaseRecovery :: !(Map DatabaseName RecoveryIntent)
  , scopeServiceVolumeRecovery :: !(Map VolumeName RecoveryIntent)
  , scopeTlsSecrets :: !(Map SecretName Declaration)
  , scopeEnvSecrets :: !(Map SecretName Declaration)
  , scopeWorkerVolumeRecovery :: !(Map ResourceId RecoveryIntent)
  , scopeBackupBackend :: !StoreBackend
  , scopeSource :: !SourceLocation
  }

secretDependency :: ResourceId -> T.Text -> Map SecretName Declaration -> SecretName -> Either T.Text ResourceId
secretDependency cluster namespaceName bindings secretName = do
  secret <- maybe (Left "Secret reference has no typed declaration") Right
    (Map.lookup secretName bindings)
  secretAddress <- case secret of
    Managed managed -> Right (managed ^. #address)
    External _ address _ _ -> Right address
    ObservedChild _ _ _ _ _ -> Left "observed child cannot supply a Secret dependency"
  expected <- kubernetesAddress cluster "v1" "Secret"
    (Just namespaceName) (secretNameText secretName)
  unless (secretAddress == expected)
    (Left "Secret dependency has a different cluster, namespace, or name")
  pure (declarationId secret)

runtimeSecretNames :: [ScopedEnvVar] -> Either T.Text [SecretName]
runtimeSecretNames entries = Set.toList . Set.fromList . concat <$> traverse one entries
  where
    one entry = case entry ^. #value of
      EnvLiteral _ -> Right []
      EnvSecretRef secret
        | entry ^. #scopes == Set.singleton Runtime -> Right [secret]
        | otherwise -> Left "Secret-backed build or preview environment requires a separate reviewed input channel"

-- | A reviewed workload can derive non-secret connection fields from its typed
-- database and reference generated credential fields by Secret key. No live
-- Secret read or password value enters compilation or the public review.
declaredConnectionEnv :: Application -> [DatabaseName] -> Either T.Text (Map Dsl.EnvName ScopedEnvVar)
declaredConnectionEnv app names = do
  maps <- traverse one names
  mergeConnectionEnvs maps
  where
    one databaseName = do
      database <- maybe (Left "workload references an undeclared database") Right
        (find ((== databaseName) . (^. #name)) (app ^. #databases))
      let secretText = dbSecretName (databaseNameText databaseName)
          base = connectionEnv (database ^. #engine) databaseName
            (app ^. #namespace) (ConnIdentity Nothing Nothing)
          extra = case database ^. #engine of
            Postgres -> ["POSTGRES_USER", "POSTGRES_DB"]
            Redis -> []
            ClickHouse -> ["CLICKHOUSE_USER"]
      secret <- mkSecretName secretText
      fields <- traverse (\name -> do
        key <- mkEnvName name
        pure (key, runtimeScoped (EnvSecretRef secret))) extra
      pure (Map.union (Map.fromList fields) base)

-- | Compose the currently supported application members once, checking
-- duplicate IDs and provider claims across component boundaries. Unsupported
-- fields refuse rather than silently disappearing from desired state.
compileApplicationScope
  :: ApplicationScopeInput
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileApplicationScope input = do
  let app = scopeApplication input
      source = scopeSource input
      invalid message = inventoryError "unsupported-application-intent" message
        & #sources .~ [source]
        & (:| [])
  _ <- first invalid (mkApplication app)
  unless (scopeRollout input ^. #appName == serviceNameText (app ^. #name)
      && scopeRollout input ^. #namespace == namespaceText (app ^. #namespace))
    (Left (invalid "rollout identity differs from the application name or namespace"))
  unless (scopeRollout input ^. #appEnv == app ^. #env)
    (Left (invalid "rollout environment differs from the declared application channel"))
  unless (null (app ^. #brokers) && app ^. #access == Nothing)
    (Left (invalid "application brokers and access contributions need typed owners"))
  let envValues = Map.elems (app ^. #env)
        <> maybe [] (Map.elems . (^. #env)) (app ^. #service)
        <> concatMap (Map.elems . (^. #env)) (app ^. #workers)
        <> concatMap (Map.elems . (^. #env)) (app ^. #tasks)
  requiredEnvSecrets <- first invalid (runtimeSecretNames envValues)
  case app ^. #service of
    Nothing -> pure ()
    Just service -> unless (null (service ^. #tasks) && service ^. #access == Nothing
        && service ^. #cdn == Nothing)
      (Left (invalid "service tasks, access, and CDN need typed members"))
  owner <- first invalid (applicationScopeId app)
  namespaceContribution <- case scopeNamespaceContributionOwner input of
    Nothing -> Right Nothing
    Just namespaceOwner -> do
      namespaceName <- first invalid (mkName (namespaceText (app ^. #namespace)))
      namespaceKey <- first invalid (mkLogicalKey (namespaceText (app ^. #namespace)))
      let request = RegisterNamespace namespaceOwner (scopeCluster input) namespaceName namespaceKey
      unless (contributionResourceId request == scopeNamespace input)
        (Left (invalid "namespace contribution does not match the reviewed namespace identity"))
      pure (Just request)
  (databaseBundles, databaseNative) <- compileApplicationDatabases app
    (scopeCluster input) (Just (scopeNamespace input)) (scopeDatabaseRecovery input)
    (scopeBackupBackend input) source
  ownSecrets <- traverse (\declaration -> case declaration of
      Managed resource -> case resource ^. #address of
        Kubernetes _ "" kind (Just _) secretName | nameText kind == "secret" -> do
          key <- first invalid (mkSecretName (nameText secretName))
          pure (key, declaration)
        _ -> Left (invalid "database Secret has an unexpected native address")
      _ -> Left (invalid "database credential is not a managed Secret"))
    [declaration | bundle <- databaseBundles, declaration@(Managed resource) <- declarations bundle,
      case resource ^. #address of
        Kubernetes _ "" kind _ _ -> nameText kind == "secret"
        _ -> False]
  let ownSecretMap = Map.fromList ownSecrets
      requiredSet = Set.fromList requiredEnvSecrets
  unless (length ownSecrets == Map.size ownSecretMap)
    (Left (invalid "database credentials share a Secret name"))
  unless (Map.keysSet (scopeEnvSecrets input) == requiredSet `Set.difference` Map.keysSet ownSecretMap)
    (Left (invalid "runtime Secret environment requires exactly its external typed dependencies"))
  let envSecrets = Map.union ownSecretMap (scopeEnvSecrets input)
  _ <- traverse (first invalid . secretDependency (scopeCluster input)
    (namespaceText (app ^. #namespace)) envSecrets) requiredEnvSecrets
  serviceWithConnection <- traverse (\service -> do
    generated <- first invalid (declaredConnectionEnv app (service ^. #databases))
    pure (service & #env %~ mergeGenerated generated)) (app ^. #service)
  workersWithConnection <- traverse (\worker -> do
    generated <- first invalid (declaredConnectionEnv app (worker ^. #databases))
    pure (worker & #env %~ mergeGenerated generated)) (app ^. #workers)
  let scopedApp = app & #service .~ serviceWithConnection
        & #workers .~ workersWithConnection
  serviceResult <- case scopedApp ^. #service of
    Nothing -> Right Nothing
    Just _ -> Just <$> compileApplicationService scopedApp (scopeRollout input)
      (scopeCluster input) (scopeNamespace input) (scopeImage input)
      (scopeServiceVolumeRecovery input) (scopeTlsSecrets input) envSecrets source
  (workerBundles, workerNative) <- compileApplicationWorkers scopedApp (scopeRollout input)
    (scopeCluster input) (scopeNamespace input) (scopeImage input)
    (scopeWorkerVolumeRecovery input) envSecrets source
  (taskBundle, taskNative) <- compileApplicationTasks app (scopeRollout input)
    (scopeCluster input) (scopeNamespace input) (scopeImage input) envSecrets source
  let namespaceBundles = maybe [] (\request -> [ResourceBundle [] [] [] [request] [] []]) namespaceContribution
      bundles = namespaceBundles <> databaseBundles <> maybe [] (pure . fst) serviceResult
        <> workerBundles <> [taskBundle]
      nativeMaps = [databaseNative] <> maybe [] (pure . snd) serviceResult
        <> [workerNative, taskNative]
      native = Map.unions nativeMaps
      claims = [claim | bundle <- bundles, declaration <- declarations bundle
        , (_, claim) <- NE.toList (claimsOf declaration)]
  scope <- mkScopeDeclaration owner bundles
  unless (Map.size native == sum (map Map.size nativeMaps))
    (Left (invalid "application native members share an identity"))
  unless (length claims == Set.size (Set.fromList claims))
    (Left (invalid "application members claim the same provider address"))
  pure (scope, native)

-- | A workload may refer only to databases declared in this application.
-- Ordering it after the StatefulSet records the typed lifecycle edge, while
-- the database builder owns the lower-level credential and PVC prerequisites.
databaseDependencies
  :: Application -> ScopeId -> [DatabaseName]
  -> (T.Text -> NonEmpty InventoryError)
  -> Either (NonEmpty InventoryError) [ResourceId]
databaseDependencies app owner names invalid = traverse resolve names
  where
    resolve dbName = do
      database <- maybe (Left (invalid ("undeclared application database: " <> databaseNameText dbName))) Right
        (find ((== dbName) . (^. #name)) (app ^. #databases))
      role <- first invalid (mkName "statefulset")
      first invalid (databaseResourceId owner role database)

-- | Bind scheduled CronJobs from the same resolved image/env render shown by
-- preview. Executing a hook remains a separate operation with effect proof.
compileApplicationTasks
  :: Application -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map SecretName Declaration -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileApplicationTasks app rollout cluster namespaceId imageId envSecrets source = do
  _ <- first invalid (mkApplication app)
  owner <- first invalid (applicationScopeId app)
  members <- traverse (compileTask owner) (app ^. #tasks)
  let bundle = ResourceBundle (map (Managed . fst) members) [] [] [] [] []
      native = Map.fromList [(member ^. #identity, pair) | pair@(member, _) <- members]
  _ <- mkScopeDeclaration owner [bundle]
  unless (Map.size native == length members)
    (Left (invalid "scheduled tasks share an identity"))
  pure (bundle, native)
  where
    invalid message = inventoryError "invalid-application-task" message
      & #sources .~ [source]
      & (:| [])
    compileTask owner task = do
      _ <- first invalid (mkTask task)
      secretNames <- first invalid (runtimeSecretNames
        (Map.elems (rollout ^. #appEnv) <> Map.elems (task ^. #env)))
      secretIds <- traverse (first invalid . secretDependency cluster
        (rollout ^. #namespace) envSecrets) secretNames
      role <- first invalid (mkName "cronjob")
      resource <- first invalid (taskResourceId owner role task)
      rendered <- first invalid (renderTaskObjects rollout task)
      bytes <- case rendered of
        [("hook", manifest)] -> Right manifest
        _ -> Left (invalid "task renderer produced unexpected members")
      value <- first (invalid . T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      canonical <- first invalid (canonicalValue value)
      let taskSource = source {path = path source <> "/task/" <> serviceNameText (task ^. #name)}
      (declaration, native) <- first (:| []) (bindKubernetesObject KubernetesInput
        { resourceId = resource
        , ownerScope = owner
        , clusterId = cluster
        , inputObject = value
        , objectDigest = contentDigest canonical
        , lifecyclePolicy = DeleteWhenUnreferenced
        , inputDataPolicy = Stateless
        , inputSensitivity = Private
        , sourceLocation = taskSource
        })
      expected <- first invalid (kubernetesAddress cluster "batch/v1" "CronJob"
        (Just (rollout ^. #namespace))
        (taskResourceName (serviceNameText (task ^. #name))))
      unless (declaration ^. #address == expected)
        (Left (invalid "task render has an unexpected CronJob address"))
      pure (declaration {dependencies = map OrderedAfter ([namespaceId, imageId] <> secretIds)}, native)

-- | Compile each application worker's PVCs and Deployment from one render.
-- Recovery is keyed by the generated volume ResourceId so an unrelated
-- worker with the same volume display name cannot borrow its authority.
compileApplicationWorkers
  :: Application -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map ResourceId RecoveryIntent -> Map SecretName Declaration
  -> SourceLocation
  -> Either (NonEmpty InventoryError)
       ([ResourceBundle], Map ResourceId (ManagedResource, ByteString))
compileApplicationWorkers app rollout cluster namespaceId imageId recoveryById envSecrets source = do
  _ <- first invalid (mkApplication app)
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
      unless (null (worker ^. #brokers))
        (Left (invalid "worker broker bindings require typed broker dependencies"))
      databasePrerequisites <- databaseDependencies app owner (worker ^. #databases) invalid
      secretNames <- first invalid (runtimeSecretNames
        (Map.elems (rollout ^. #appEnv) <> Map.elems (worker ^. #env)))
      secretIds <- traverse (first invalid . secretDependency cluster
        (rollout ^. #namespace) envSecrets) secretNames
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
        (map OrderedAfter (namespaceId : imageId : volumeIds <> databasePrerequisites <> secretIds)) workerSource workerBytes
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
  -> Map VolumeName RecoveryIntent -> Map SecretName Declaration -> Map SecretName Declaration
  -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileApplicationService app rollout cluster namespaceId imageId recoveryByVolume tlsSecrets envSecrets source = do
  _ <- first invalid (mkApplication app)
  owner <- first invalid (applicationScopeId app)
  service <- maybe (Left (invalid "application has no web service")) Right (app ^. #service)
  databasePrerequisites <- databaseDependencies app owner (service ^. #databases) invalid
  compileServiceMembers owner service rollout cluster namespaceId imageId
    databasePrerequisites recoveryByVolume tlsSecrets envSecrets source
  where
    invalid message = inventoryError "invalid-application-service" message
      & #sources .~ [source]
      & (:| [])

-- | A separately owned web Service uses the same exact native binding as an
-- application service. It carries no application database or shared policy
-- authority; callers must supply the accepted namespace and image identities.
compileStandaloneService
  :: ScopeId -> Deployment -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map VolumeName RecoveryIntent -> Map SecretName Declaration -> Map SecretName Declaration -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneService owner service rollout cluster namespaceId imageId recovery tlsSecrets envSecrets source = do
  unless (scopeKind owner == Standalone)
    (Left (invalid "standalone service requires a standalone scope"))
  unless (rollout ^. #appName == serviceNameText (service ^. #name)
      && rollout ^. #namespace == namespaceText (service ^. #namespace)
      && Map.null (rollout ^. #appEnv))
    (Left (invalid "standalone rollout identity, namespace, or environment differs from its service"))
  unless (null (service ^. #databases))
    (Left (invalid "standalone database bindings require typed dependencies"))
  requiredEnvSecrets <- first invalid (runtimeSecretNames (Map.elems (service ^. #env)))
  unless (Map.keysSet envSecrets == Set.fromList requiredEnvSecrets)
    (Left (invalid "standalone runtime Secret environment requires exactly its typed dependencies"))
  (bundle, native) <- compileServiceMembers owner service rollout cluster namespaceId imageId
    [] recovery tlsSecrets envSecrets source
  scope <- mkScopeDeclaration owner [bundle]
  pure (scope, native)
  where
    invalid message = inventoryError "invalid-standalone-service" message
      & #scopes .~ [owner]
      & #sources .~ [source]
      & (:| [])

compileServiceMembers
  :: ScopeId -> Deployment -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> [ResourceId] -> Map VolumeName RecoveryIntent -> Map SecretName Declaration -> Map SecretName Declaration -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileServiceMembers owner service rollout cluster namespaceId imageId databasePrerequisites recoveryByVolume tlsSecrets envSecrets source = do
  unless (null (service ^. #brokers))
    (Left (invalid "service broker bindings require typed broker dependencies"))
  unless (null (service ^. #tasks) && service ^. #access == Nothing
      && service ^. #cdn == Nothing)
    (Left (invalid "service hooks, access, and CDN require typed operations or contributions"))
  let requiredTls = Set.fromList [secret | domain <- service ^. #domains,
        SuppliedTlsSecret secret <- [domain ^. #tls]]
  unless (Map.keysSet tlsSecrets == requiredTls)
    (Left (invalid "supplied TLS domains require exactly their typed Secret dependencies"))
  secretNames <- first invalid (runtimeSecretNames
    (Map.elems (rollout ^. #appEnv) <> Map.elems (service ^. #env)))
  secretIds <- traverse (first invalid . secretDependency cluster
    (rollout ^. #namespace) envSecrets) secretNames
  resource <- first invalid (deploymentResourceId owner (known "service") service)
  rendered <- first invalid (renderServiceObjects rollout service)
  let volumes = service ^. #volumes
      (volumeRendered, serviceRendered) = splitAt (length volumes) rendered
  serviceBytes <- case serviceRendered of
    ("service", manifest) : _ -> Right manifest
    _ -> Left (invalid "service renderer produced unexpected members")
  let domainRendered = drop 1 serviceRendered
      domains = service ^. #domains
  unless (length domainRendered == length domains && all ((== "service") . fst) domainRendered)
    (Left (invalid "service domain renderer produced unexpected members"))
  unless (length volumeRendered == length volumes && all ((== "service") . fst) volumeRendered)
    (Left (invalid "service volume renderer produced unexpected members"))
  volumeMembers <- traverse compileVolume (zip volumes (map snd volumeRendered))
  let volumeIds = map ((^. #identity) . fst) volumeMembers
  serviceMember <- bindOne resource DeleteWhenUnreferenced Stateless
    (map OrderedAfter (namespaceId : imageId : volumeIds <> databasePrerequisites <> secretIds)) source serviceBytes
  domainMembers <- traverse (compileDomain resource) (zip domains (map snd domainRendered))
  let members = volumeMembers <> [serviceMember] <> domainMembers
      declarations = [Managed declaration | (declaration, _) <- members]
      native = Map.fromList [(declaration ^. #identity, member) | member@(declaration, _) <- members]
      bundle = ResourceBundle declarations [] [] [] [] []
  _ <- mkScopeDeclaration owner [bundle]
  unless (Map.size native == length members)
    (Left (invalid "service members share an identity"))
  pure (bundle, native)
  where
    known = either (error . T.unpack) id . mkName
    invalid message = single (inventoryError "invalid-service-declaration" message
      & #sources .~ [source])
    single errorValue = errorValue :| []
    compileVolume (volume, bytes) = do
      recovery <- case volume ^. #retention of
        Dsl.Retain -> Just <$> maybe (Left (invalid "retained service volume has no recovery intent")) Right
          (Map.lookup (volume ^. #name) recoveryByVolume)
        Dsl.Delete -> Right Nothing
      volumeId <- first invalid (volumeResourceId owner (known "service-pvc") volume)
      let volumeSource = source
            {path = path source <> "/volume/" <> volumeNameText (volume ^. #name)}
          lifecycle = if volume ^. #retention == Dsl.Retain then Retain else DeleteWhenUnreferenced
          dataPolicy = maybe Stateless Durable recovery
      member@(declaration, _) <- bindOne volumeId lifecycle dataPolicy
        [OrderedAfter namespaceId] volumeSource bytes
      expected <- first invalid (kubernetesAddress cluster "v1" "PersistentVolumeClaim"
        (Just (rollout ^. #namespace))
        (pvcName (serviceNameText (service ^. #name)) (volumeNameText (volume ^. #name))))
      unless (declaration ^. #address == expected)
        (Left (invalid "service volume render has an unexpected PVC address"))
      pure member
    compileDomain serviceId (domain, bytes) = do
      domainId <- first invalid (domainMappingResourceId owner domain)
      host <- first invalid (mkName (domainText (domain ^. #domain)))
      let domainSource = source
            {path = path source <> "/domain/" <> domainText (domain ^. #domain)}
      tlsPrerequisites <- case domain ^. #tls of
        AutomaticTls -> Right []
        SuppliedTlsSecret secretName -> do
          secretId <- first invalid (secretDependency cluster
            (rollout ^. #namespace) tlsSecrets secretName)
          pure [secretId]
      (declaration, native) <- bindOne domainId DeleteWhenUnreferenced Stateless
        (map OrderedAfter (namespaceId : serviceId : tlsPrerequisites)) domainSource bytes
      expected <- first invalid (kubernetesAddress cluster "serving.knative.dev/v1beta1"
        "DomainMapping" (Just (rollout ^. #namespace)) (domainText (domain ^. #domain)))
      unless (declaration ^. #address == expected)
        (Left (invalid "service domain render has an unexpected address"))
      pure (declaration {aliases = [Hostname host]}, native)
    bindOne resource lifecycle dataPolicy dependencies location bytes = do
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
