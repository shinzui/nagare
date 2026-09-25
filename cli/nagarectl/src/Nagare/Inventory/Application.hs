-- | Compile application-owned databases from the full typed Application.
-- Every direct object, credential template, and retained backup joins the
-- application's scope; the caller later adds workload and contribution bundles.
module Nagare.Inventory.Application
  ( ApplicationScopeInput (..)
  , compileApplicationScope
  , compileApplicationDeployment
  , compileApplicationDatabases
  , compileApplicationService
  , compileStandaloneService
  , compileStandaloneServiceWithBrokers
  , compileStandaloneServiceWithDependencies
  , compileStandaloneServiceWithRelease
  , compileApplicationWorkers
  , compileStandaloneWorker
  , compileStandaloneWorkerWithDependencies
  , recordReviewedStandaloneOverrides
  , compileApplicationTasks
  , applicationNativeOwned
  , nativeWorkloadOwned
  , hostnameClaimOwned
  , acceptedApplicationImage
  , reviewedTaskImages
  , databaseRecoveryBindings
  , acceptedSecretBindings
  , acceptedBrokerBindings
  , AccessBinding (..)
  , GoogleCdnBinding (..)
  , acceptedAccessBinding
  , acceptedApplicationReleaseLog
  , acceptedStandaloneReleaseLog
  , legacyApplicationReleaseImport
  , legacyStandaloneReleaseImport
  , DatabaseBinding
  , acceptedDatabaseBindings
  , applicationVolumeRecoveryBindings
  , standaloneWorkerVolumeRecoveryBindings
  , applicationRetirementScope
  , workerRetirementScope
  ) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.Cdn.Provision (CdnTarget (..), GcpStackRefs (..), planCdn, googleCdnHostname)
import Nagare.App.Deployments (appConfigMapName, appDeploymentsPrefix)
import Nagare.App.Deploy (RolloutEnv, renderServiceObjects, renderTaskObjects, renderWorkerObjects)
import Nagare.Access.Resolve (RouteTarget (..), backendConfigMapNamespace, isUnderBaseDomain, mkBaseDomain, mkPublicHost, renderAccessDomainMapping, upstreamFor)
import Nagare.Broker.Connection (BrokerConn (..), brokerConnectionEnv, mergeBrokerConnectionEnvs)
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Application qualified as DslApp
import Nagare.Dsl.Config (encodeApplication, encodeDeployment, encodeWorker)
import Nagare.Dsl.Cdn.Types (Cdn (..), CdnProvider (GcpCloudCdn))
import Nagare.Dsl.Access (AccessRole (..))
import Nagare.Dsl.Broker (BrokerBinding (..), BrokerName, BrokerProvider (Redpanda), TopicName, brokerNameText, topicNameText)
import Nagare.Database.Connection (ConnIdentity (..), connectionEnv, mergeConnectionEnvs)
import Nagare.Deploy (serviceUrl)
import Nagare.Dsl.Database (Database (..), Engine (..), dbSecretName, engineToken)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (pvcName)
import Nagare.Dsl.Database.Render (dbConfigMapName, dbPvcName)
import Nagare.Dsl.Types (DatabaseName, Deployment (..), DomainSpec (..), DomainTls (..), EnvScope (Runtime), EnvVar (..), Namespace, ScopedEnvVar (..), SecretName, Volume (..), VolumeName, databaseNameText, domainText, imageRefText, mkDomain, mkEnvName, mkSecretName, namespaceText, runtimeScoped, secretNameText, serviceNameText, volumeNameText)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (Worker (..))
import Nagare.Dsl.Task (Task (..), mkTask, taskResourceName)
import Nagare.Task.Resolve (resolveTaskImage)
import Nagare.Inventory.Database (compileDatabaseForBackend)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Env.Generated (mergeGenerated)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.TaskRun (jobFromCronJob)
import Nagare.Inventory.Adapters.KubernetesRuntime (databaseCredentialKind)
import Nagare.Static.Release (StaticRelease (..), StaticReleaseLog (..), addRelease, emptyReleaseLog, extractReleaseLog, findRelease, renderReleaseConfigMapWith)
import Nagare.Resource.Application (applicationScopeId, deploymentResourceId, domainMappingResourceId, taskResourceId, volumeResourceId, workerResourceId)
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Cdn (compileGoogleDnsRecord)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (..), LifecyclePolicy (..), RecoveryClass (VerifyBeforeRetry), Sensitivity (Private))
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire (canonicalValue)

-- Hash the validated config value, rather than its source file bytes. Imported
-- Haskell modules and formatting can then change without losing the exact
-- effective input that produced this accepted scope.
configDigestOf :: LBS.ByteString -> Either T.Text ContentDigest
configDigestOf bytes = do
  value <- first T.pack (eitherDecodeStrict (LBS.toStrict bytes) :: Either String Value)
  contentDigest <$> canonicalValue value

-- | Bind public command inputs to the standalone scope only after checking
-- that they agree with the rollout and accepted image used by its compiler.
recordReviewedStandaloneOverrides
  :: RolloutEnv -> ResourceId -> Map T.Text T.Text -> ScopeDeclaration
  -> Either (NonEmpty InventoryError) ScopeDeclaration
recordReviewedStandaloneOverrides rollout imageId overrides scope = do
  unless (scopeKind (scopeId scope) == Standalone && isJust (scopeConfigDigest scope)
      && Map.keysSet overrides `Set.isSubsetOf`
        Set.fromList ["tag", "baseDomain", "imageResource"]
      && Map.lookup "tag" overrides == Just (rollout ^. #imageTag)
      && Map.lookup "imageResource" overrides == Just (resourceIdText imageId)
      && maybe True (== rollout ^. #baseDomain) (Map.lookup "baseDomain" overrides))
    (Left (inventoryError "invalid-standalone-overrides"
      "standalone command overrides differ from reviewed rollout inputs" :| []))
  pure (withScopeOverrides overrides scope)

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
        <> [("", "configmap", appConfigMapName (releaseSubject app))]
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
           | task <- app ^. #tasks
             <> maybe [] (^. #tasks) (app ^. #service)]
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

-- | Direct DNS/CDN commands must respect all global hostname claims,
-- including external platform declarations and aliases on managed resources.
hostnameClaimOwned :: T.Text -> [Declaration] -> Bool
hostnameClaimOwned host declarations = case mkName host of
  Left _ -> False
  Right name ->
    let claim = canonicalClaim (Hostname name)
     in any (any ((== claim) . snd) . NE.toList . claimsOf) declarations

-- | Select retirement from accepted application or standalone web-Service
-- history and the exact native address. A display name or key alone carries
-- no authority.
applicationRetirementScope
  :: T.Text -> T.Text -> Maybe T.Text -> ScopeSnapshot -> Either T.Text ScopeId
applicationRetirementScope name namespaceName pinnedKey snapshot = do
  pinned <- traverse mkLogicalKey pinnedKey
  case [ owner
       | (owner, (_, scope)) <- Map.toList (snapshotScopes snapshot)
       , scopeKind owner `elem` [Resource.Application, Resource.Standalone]
       , case scopeKind owner of
           Resource.Application -> maybe True ((== nameText (scopeName owner)) . logicalKeyText) pinned
           Resource.Standalone -> maybe True
             ((== nameText (scopeName owner)) . ("service-" <>) . logicalKeyText) pinned
           _ -> False
       , bundle <- scopeBundles scope
       , Managed resource <- declarations bundle
       , case resource ^. #address of
           Kubernetes _ "serving.knative.dev" kind (Just namespace) serviceName ->
             nameText kind == "service"
               && nameText namespace == namespaceName
               && nameText serviceName == name
           _ -> False
       ] of
    [owner] -> Right owner
    _ -> Left "accepted application or standalone history has no unique Knative Service for that name, namespace, and scope key"

-- | Retire only the standalone scope that owns the exact accepted Deployment.
-- The retirement planner preserves its retained PVC declarations.
workerRetirementScope
  :: T.Text -> T.Text -> Maybe T.Text -> ScopeSnapshot -> Either T.Text ScopeId
workerRetirementScope name namespaceName pinnedKey snapshot = do
  pinned <- traverse mkLogicalKey pinnedKey
  case [ owner
       | (owner, (_, scope)) <- Map.toList (snapshotScopes snapshot)
       , scopeKind owner == Resource.Standalone
       , maybe True
           ((== nameText (scopeName owner)) . ("worker-" <>) . logicalKeyText) pinned
       , bundle <- scopeBundles scope
       , Managed resource <- declarations bundle
       , case resource ^. #address of
           Kubernetes _ "apps" kind (Just namespace) deploymentName ->
             nameText kind == "deployment"
               && nameText namespace == namespaceName
               && nameText deploymentName == name
           _ -> False
       ] of
    [owner] -> Right owner
    _ -> Left "accepted standalone history has no unique worker Deployment for that name, namespace, and scope key"

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

-- | A scheduled CronJob may join a reviewed application rollout only when
-- its resolved image is the publication already accepted for that rollout.
-- Explicit task images can otherwise bypass the image dependency in the
-- compiled declaration.
reviewedTaskImages :: [Task] -> T.Text -> T.Text -> Either T.Text ()
reviewedTaskImages tasks taggedImage effectiveTag =
  forM_ tasks $ \task ->
    unless (resolveTaskImage taggedImage effectiveTag task == taggedImage)
      (Left "scheduled task resolves to an image outside the accepted application publication")

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

-- | Resolve Service and topic references from one complete accepted
-- standalone broker scope. A live topic with the same name is not authority.
acceptedBrokerBindings
  :: ScopeSnapshot -> ResourceId -> T.Text -> [BrokerBinding]
  -> Either T.Text (Map BrokerName Declaration,
       Map BrokerName (Map TopicName Declaration), Map Dsl.EnvName ScopedEnvVar)
acceptedBrokerBindings snapshot cluster namespaceName bindings = do
  pairs <- traverse resolve bindings
  let services = Map.fromList (map fst pairs)
  unless (length pairs == Map.size services)
    (Left "application broker bindings repeat a broker")
  env <- mergeBrokerConnectionEnvs [fields | (_, fields) <- pairs]
  let topicBindings = Map.fromList
        [(name, topics) | ((name, (_, topics)), _) <- pairs]
  pure (Map.map fst services, topicBindings, env)
  where
    resolve binding = do
      let name = brokerNameText (binding ^. #name)
          expected (kind :: T.Text) = kubernetesAddress cluster
            (if kind == "statefulset" then "apps/v1" else "v1")
            (if kind == "statefulset" then "StatefulSet" else "Service")
            (Just namespaceName) name
      serviceAddress <- expected "service"
      statefulAddress <- expected "statefulset"
      let candidates =
            [ (service, statefulId, scope)
            | (owner, (_, scope)) <- Map.toList (snapshotScopes snapshot)
            , scopeKind owner == Standalone
            , bundle <- scopeBundles scope
            , service@(Managed serviceResource) <- declarations bundle
            , serviceResource ^. #address == serviceAddress
            , Just brokerKey <- [T.stripSuffix "/service" (resourceIdText (serviceResource ^. #identity))]
            , T.isSuffixOf "/broker/service" (path (serviceResource ^. #source))
            , Managed stateful <- concatMap declarations (scopeBundles scope)
            , stateful ^. #address == statefulAddress
            , resourceIdText (stateful ^. #identity) == brokerKey <> "/statefulset"
            , T.isSuffixOf "/broker/statefulset" (path (stateful ^. #source))
            , let statefulId = stateful ^. #identity
            ]
      (service, statefulId, acceptedScope) <- case candidates of
        [found] -> Right found
        _ -> Left "broker has no unique accepted Service and StatefulSet in one standalone scope"
      topicPairs <- traverse (\topic -> do
        topicName <- mkName (topicNameText topic)
        let matches =
              [declaration
              | bundle <- scopeBundles acceptedScope
              , declaration@(Managed resource) <- declarations bundle
              , resource ^. #address == BrokerTopic statefulId topicName
              , resource ^. #executor == BrokerExecutor
              , case resource ^. #spec of LogicalBrokerTopic {} -> True; _ -> False]
        case matches of
          [declaration] -> Right (topic, declaration)
          _ -> Left "broker topic is absent or ambiguous in accepted logical inventory")
        (binding ^. #topics)
      let topics = Map.fromList topicPairs
      unless (length topicPairs == Map.size topics)
        (Left "broker binding repeats a topic")
      env <- brokerConnectionEnv binding BrokerConn
        { provider = Redpanda
        , bootstrapServers = name <> "." <> namespaceName <> ".svc.cluster.local:9092"
        , topics = binding ^. #topics
        }
      pure ((binding ^. #name, (service, topics)), env)

data AccessBinding = AccessBinding
  { accessOwner :: !ScopeId
  , accessEnforcer :: !Declaration
  , accessBaseDomain :: !Name
  }
  deriving stock (Eq, Show)

-- | The shared backend owner and enforcer must already be accepted together.
-- A matching live Service or caller-supplied name does not grant access to the
-- shared routing ConfigMap or to the auth namespace.
acceptedAccessBinding :: ScopeSnapshot -> ResourceId -> Either T.Text AccessBinding
acceptedAccessBinding snapshot cluster = do
  authOwner <- mkScopeId Platform "auth"
  authScope <- maybe (Left "auth owner has no accepted inventory scope") (Right . snd)
    (Map.lookup authOwner (snapshotScopes snapshot))
  let grants = [() | bundle <- scopeBundles authScope,
        BackendMapGrant grantedCluster <- bundle ^. #grants, grantedCluster == cluster]
  unless (length grants == 1)
    (Left "auth owner has no unique accepted backend-map grant for this cluster")
  baseDomain <- case [base | bundle <- scopeBundles authScope,
      ShomeiSettingsGrant grantedCluster base <- bundle ^. #grants,
      grantedCluster == cluster] of
    [base] -> Right base
    _ -> Left "auth owner has no unique accepted Shomei settings grant for this cluster"
  expected <- kubernetesAddress cluster "serving.knative.dev/v1" "Service"
    (Just backendConfigMapNamespace) "nagare-access"
  let enforcers = [declaration | bundle <- scopeBundles authScope,
        declaration@(Managed resource) <- declarations bundle,
        resource ^. #address == expected]
  case enforcers of
    [enforcer] -> Right (AccessBinding authOwner enforcer baseDomain)
    _ -> Left "auth owner has no unique accepted enforcer Service"

brokerEvidenceIds
  :: ResourceId -> T.Text -> BrokerBinding
  -> Map BrokerName Declaration -> Map BrokerName (Map TopicName Declaration)
  -> Either T.Text [ResourceId]
brokerEvidenceIds cluster namespaceName binding services allTopics = do
  service <- maybe (Left "broker has no typed Service dependency") Right
    (Map.lookup (binding ^. #name) services)
  expected <- kubernetesAddress cluster "v1" "Service"
    (Just namespaceName) (brokerNameText (binding ^. #name))
  managed <- case service of
    Managed resource | resource ^. #address == expected
      && scopeKind (resource ^. #owner) == Standalone -> Right resource
    _ -> Left "broker dependency is not an accepted standalone Service at the declared address"
  brokerKey <- maybe (Left "broker Service identity has no stable role") Right
    (T.stripSuffix "/service" (resourceIdText (managed ^. #identity)))
  stateful <- mkResourceId (brokerKey <> "/statefulset")
  topics <- case Map.lookup (binding ^. #name) allTopics of
    Just evidence -> Right evidence
    Nothing | null (binding ^. #topics) -> Right Map.empty
    Nothing -> Left "broker has no typed topic evidence"
  selected <- traverse (\topic -> do
    declaration <- maybe (Left "broker topic lacks accepted inventory evidence") Right
      (Map.lookup topic topics)
    nativeName <- mkName (topicNameText topic)
    case declaration of
      Managed resource
        | resource ^. #address == BrokerTopic stateful nativeName
        , resource ^. #owner == managed ^. #owner
        , resource ^. #executor == BrokerExecutor
        , LogicalBrokerTopic {} <- resource ^. #spec -> Right (resource ^. #identity)
      _ -> Left "broker topic evidence differs from the accepted broker address")
    (binding ^. #topics)
  pure (managed ^. #identity : selected)

-- | A database connection is authorized by one accepted standalone scope and
-- its original private credential template. Keep this witness opaque so a
-- caller cannot substitute an engine or a Secret with the same display name.
data DatabaseBinding = DatabaseBinding
  { boundService :: !ManagedResource
  , boundStatefulSet :: !ManagedResource
  , boundCredential :: !ManagedResource
  , boundEngine :: !Engine
  }
  deriving stock (Eq, Show)

acceptedDatabaseBindings
  :: ScopeSnapshot -> Map ResourceId (ManagedResource, ByteString)
  -> ResourceId -> T.Text -> [DatabaseName]
  -> Either T.Text (Map DatabaseName DatabaseBinding)
acceptedDatabaseBindings snapshot native cluster namespaceName names = do
  pairs <- traverse resolve names
  let bindings = Map.fromList pairs
  unless (length pairs == Map.size bindings)
    (Left "database bindings repeat a database")
  pure bindings
  where
    resolve name = do
      let dbName = databaseNameText name
      serviceAddress <- kubernetesAddress cluster "v1" "Service" (Just namespaceName) dbName
      statefulAddress <- kubernetesAddress cluster "apps/v1" "StatefulSet" (Just namespaceName) dbName
      credentialAddress <- kubernetesAddress cluster "v1" "Secret"
        (Just namespaceName) (dbSecretName dbName)
      let candidates =
            [ (service, stateful, credential)
            | (owner, (_, scope)) <- Map.toList (snapshotScopes snapshot)
            , scopeKind owner == Standalone
            , "database-" `T.isPrefixOf` nameText (scopeName owner)
            , let resources = concatMap
                    (\bundle -> [resource | Managed resource <- declarations bundle])
                    (scopeBundles scope)
            , service <- resources, service ^. #address == serviceAddress
            , Just prefix <- [T.stripSuffix "/service" (resourceIdText (service ^. #identity))]
            , stateful <- resources
            , stateful ^. #address == statefulAddress
            , resourceIdText (stateful ^. #identity) == prefix <> "/statefulset"
            , credential <- resources
            , credential ^. #address == credentialAddress
            , resourceIdText (credential ^. #identity) == prefix <> "/credential"
            ]
      (service, stateful, credential) <- case candidates of
        [found] -> Right found
        _ -> Left "database has no unique accepted Service, StatefulSet, and credential in one standalone scope"
      (_, bytes) <- case Map.lookup (credential ^. #identity) native of
        Just pair@(member, _) | member == credential -> Right pair
        _ -> Left "accepted database credential has no matching private native template"
      value <- first (T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      engine <- databaseCredentialKind value >>= \case
        Just (templateName, templateNamespace, parsed)
          | templateName == dbName && templateNamespace == namespaceName -> Right parsed
        _ -> Left "accepted database credential template differs from the requested database"
      forM_ [service, stateful] (checkNativeLabels dbName engine)
      pure (name, DatabaseBinding service stateful credential engine)
    checkNativeLabels dbName engine member = do
      (_, bytes) <- case Map.lookup (member ^. #identity) native of
        Just pair@(accepted, _) | accepted == member -> Right pair
        _ -> Left "accepted database member has no matching private native object"
      value <- first (T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      case value of
        Object root -> case KM.lookup "metadata" root of
          Just (Object metadata) -> case KM.lookup "labels" metadata of
            Just (Object labels)
              | KM.lookup "nagare.dev/managed-by" labels == Just (String "nagarectl")
                && KM.lookup "nagare.dev/database" labels == Just (String dbName)
                && KM.lookup "nagare.dev/engine" labels == Just (String (engineToken engine)) -> Right ()
            _ -> Left "accepted database native labels differ from its credential engine"
          _ -> Left "accepted database native member has no metadata"
        _ -> Left "accepted database native member is not an object"

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

standaloneWorkerVolumeRecoveryBindings
  :: ScopeId -> Worker -> [T.Text] -> Either T.Text (Map ResourceId RecoveryIntent)
standaloneWorkerVolumeRecoveryBindings owner worker raw = do
  workerKey <- maybe (mkLogicalKey (serviceNameText (worker ^. #name))) Right
    (worker ^. #logicalKey)
  role <- mkName ("worker-" <> logicalKeyText workerKey <> "-pvc")
  pairs <- traverse (parseOne role) raw
  expected <- Set.fromList <$> traverse (volumeResourceId owner role)
    [volume | volume <- worker ^. #volumes, volume ^. #retention == Dsl.Retain]
  let bindings = Map.fromList pairs
  unless (length pairs == Map.size bindings && Map.keysSet bindings == expected)
    (Left "standalone worker recovery must cover exactly the retained volumes")
  pure bindings
  where
    parseOne role value = case T.splitOn "=" value of
      [volumeText, recoveryText] -> case T.splitOn ":" recoveryText of
        [backupText, keyText, versionText] -> do
          volume <- maybe (Left "worker recovery names an undeclared volume") Right
            (find ((== volumeText) . volumeNameText . (^. #name)) (worker ^. #volumes))
          unless (volume ^. #retention == Dsl.Retain)
            (Left "throwaway worker volume cannot have recovery intent")
          resourceId <- volumeResourceId owner role volume
          backup <- mkName backupText
          key <- mkName keyText
          version <- mkName versionText
          pure (resourceId, RecoveryIntent backup (mkSecretRef key version NE.:| []))
        _ -> Left "worker recovery must be VOLUME=BACKUP:KEY:VERSION"
      _ -> Left "worker recovery must be VOLUME=BACKUP:KEY:VERSION"

-- | The reviewed dependencies and recovery decisions supplied by the command
-- service. A caller must bind the namespace and image publication to accepted
-- identities before producing an application scope.
data GoogleCdnBinding = GoogleCdnBinding
  { googleCdnRefs :: !GcpStackRefs
  , googleCdnBackend :: !Declaration
  } deriving stock (Eq, Show)

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
  , scopeBrokerServices :: !(Map BrokerName Declaration)
  , scopeBrokerTopics :: !(Map BrokerName (Map TopicName Declaration))
  , scopeAccessBinding :: !(Maybe AccessBinding)
  , scopeCdnBinding :: !(Maybe GoogleCdnBinding)
  , scopeDatabaseRecovery :: !(Map DatabaseName RecoveryIntent)
  , scopeServiceVolumeRecovery :: !(Map VolumeName RecoveryIntent)
  , scopeTlsSecrets :: !(Map SecretName Declaration)
  , scopeEnvSecrets :: !(Map SecretName Declaration)
  , scopeWorkerVolumeRecovery :: !(Map ResourceId RecoveryIntent)
  , scopeBackupBackend :: !StoreBackend
  , scopeRelease :: !(StaticReleaseLog, StaticRelease)
  -- ^ Accepted prior log and the release this rollout records. The command
  -- service must source the prior log from immutable accepted native evidence.
  , scopeHookEffects :: !(Map T.Text [ResourceId])
  -- ^ An entry is required for every pre-deploy hook. An empty list is an
  -- explicit assertion that the hook has no data effects.
  , scopeInputOverrides :: !(Map T.Text T.Text)
  -- ^ Explicit public command choices retained with the config digest.
  , scopeSource :: !SourceLocation
  }

releaseResourceId :: ScopeId -> Application -> Either T.Text ResourceId
releaseResourceId owner app = do
  key <- maybe (mkLogicalKey (serviceNameText (app ^. #name))) Right
    (app ^. #logicalKey)
  role <- mkName "release-history"
  pure (mintResourceId owner key role)

releaseSubject :: Application -> T.Text
releaseSubject app = maybe (serviceNameText (app ^. #name))
  (serviceNameText . (^. #name)) (app ^. #service)

-- | Read only the accepted application's immutable private release member.
-- A live ConfigMap is never an input channel: an old direct log must be
-- explicitly adopted before a reviewed rollout can take ownership of it.
acceptedApplicationReleaseLog
  :: ScopeSnapshot -> Map ResourceId (ManagedResource, ByteString)
  -> Application -> ResourceId -> Either T.Text StaticReleaseLog
acceptedApplicationReleaseLog snapshot native app cluster = do
  owner <- applicationScopeId app
  acceptedReleaseLog snapshot native owner app cluster

acceptedStandaloneReleaseLog
  :: ScopeSnapshot -> Map ResourceId (ManagedResource, ByteString)
  -> ScopeId -> Deployment -> ResourceId -> Either T.Text StaticReleaseLog
acceptedStandaloneReleaseLog snapshot native owner service cluster =
  acceptedReleaseLog snapshot native owner (standaloneReleaseApplication service) cluster

-- | Import the exact legacy ConfigMap shape before asking the lifecycle
-- planner to adopt its live incarnation. Importing the current record through
-- addRelease must preserve the log; native digest proof checks the live object.
legacyApplicationReleaseImport
  :: Application -> T.Text -> T.Text -> ByteString
  -> Either T.Text (StaticReleaseLog, StaticRelease)
legacyApplicationReleaseImport app expectedTag expectedImage bytes = do
  value <- first ("could not decode legacy release ConfigMap: " <>)
    (first T.pack (eitherDecodeStrict bytes))
  let subject = releaseSubject app
      expectedName = appConfigMapName subject
      expectedNamespace = namespaceText (app ^. #namespace)
  metadata <- case value of
    Object fields
      | KM.lookup "apiVersion" fields == Just (String "v1")
      , KM.lookup "kind" fields == Just (String "ConfigMap")
      , Just (Object meta) <- KM.lookup "metadata" fields -> Right meta
    _ -> Left "legacy release import is not a v1 ConfigMap"
  unless (KM.lookup "name" metadata == Just (String expectedName)
      && KM.lookup "namespace" metadata == Just (String expectedNamespace))
    (Left "legacy release import has a different name or namespace")
  logv <- extractReleaseLog bytes
  validateReleaseLog app logv
  currentId <- maybe (Left "legacy release import has no current release") Right
    (logv ^. #current)
  currentRelease <- maybe (Left "legacy release import has no current record") Right
    (findRelease currentId logv)
  unless (currentRelease ^. #releaseId == expectedTag
      && currentRelease ^. #imageTag == expectedTag
      && currentRelease ^. #image == expectedImage)
    (Left "legacy current release does not match the selected rollout image and tag")
  unless (addRelease currentRelease logv == logv)
    (Left "legacy release history would change during import")
  pure (logv, currentRelease)

legacyStandaloneReleaseImport
  :: Deployment -> T.Text -> T.Text -> ByteString
  -> Either T.Text (StaticReleaseLog, StaticRelease)
legacyStandaloneReleaseImport service =
  legacyApplicationReleaseImport (standaloneReleaseApplication service)

acceptedReleaseLog
  :: ScopeSnapshot -> Map ResourceId (ManagedResource, ByteString)
  -> ScopeId -> Application -> ResourceId -> Either T.Text StaticReleaseLog
acceptedReleaseLog snapshot native owner app cluster = do
  releaseId <- releaseResourceId owner app
  expected <- kubernetesAddress cluster "v1" "ConfigMap"
    (Just (namespaceText (app ^. #namespace)))
    (appConfigMapName (releaseSubject app))
  case Map.lookup owner (snapshotScopes snapshot) of
    Nothing -> Right emptyReleaseLog
    Just (_, accepted) -> case
      [resource | bundle <- scopeBundles accepted,
        Managed resource <- declarations bundle,
        resource ^. #identity == releaseId] of
      [] -> Right emptyReleaseLog
      [resource] -> do
        unless (resource ^. #address == expected)
          (Left "accepted release metadata has a different native address")
        (bound, bytes) <- maybe (Left "accepted release metadata lacks private native evidence") Right
          (Map.lookup releaseId native)
        unless (bound == resource)
          (Left "accepted release metadata differs from its private native binding")
        logv <- extractReleaseLog bytes
        validateReleaseLog app logv
        pure logv
      _ -> Left "accepted application has duplicate release metadata"

standaloneReleaseApplication :: Deployment -> Application
standaloneReleaseApplication service = DslApp.Application
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
  unless (length ids == Set.size (Set.fromList ids)
      && all (\entry -> entry ^. #siteName == appName
        && entry ^. #namespace == namespaceName) records
      && maybe (null records) (`elem` ids) (logv ^. #current))
    (Left "accepted release metadata has inconsistent application history")

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
      databaseConnectionEnv (database ^. #engine) databaseName (app ^. #namespace)

databaseConnectionEnv :: Engine -> DatabaseName -> Namespace
  -> Either T.Text (Map Dsl.EnvName ScopedEnvVar)
databaseConnectionEnv engine databaseName namespace = do
  let secretText = dbSecretName (databaseNameText databaseName)
      base = connectionEnv engine databaseName namespace (ConnIdentity Nothing Nothing)
      extra = case engine of
        Postgres -> ["POSTGRES_USER", "POSTGRES_DB"]
        Redis -> []
        ClickHouse -> ["CLICKHOUSE_USER"]
  secret <- mkSecretName secretText
  fields <- traverse (\name -> do
    key <- mkEnvName name
    pure (key, runtimeScoped (EnvSecretRef secret))) extra
  pure (Map.union (Map.fromList fields) base)

-- | Supply generated connection fields and exact resource dependencies for
-- separately owned databases. The binding witness can only come from accepted
-- scope history and the original private native credential template.
standaloneDatabaseEnvironment
  :: ResourceId -> Namespace -> [DatabaseName] -> Map DatabaseName DatabaseBinding
  -> (T.Text -> NonEmpty InventoryError)
  -> Either (NonEmpty InventoryError)
       (Map Dsl.EnvName ScopedEnvVar, [ResourceId], Map SecretName Declaration)
standaloneDatabaseEnvironment cluster namespace names bindings invalid = do
  unless (length names == Map.size bindings
      && Map.keysSet bindings == Set.fromList names)
    (Left (invalid "database dependencies must cover exactly the workload bindings"))
  rows <- traverse one names
  env <- first invalid (mergeConnectionEnvs [fields | (fields, _, _) <- rows])
  pure (env, [resource | (_, resource, _) <- rows],
    Map.fromList [secret | (_, _, secret) <- rows])
  where
    namespaceName = namespaceText namespace
    one name = do
      binding <- maybe (Left (invalid "database has no accepted binding")) Right
        (Map.lookup name bindings)
      let service = boundService binding
          stateful = boundStatefulSet binding
          credential = boundCredential binding
          dbName = databaseNameText name
          owners = map (^. #owner) [service, stateful, credential]
      expectedService <- first invalid (kubernetesAddress cluster "v1" "Service"
        (Just namespaceName) dbName)
      expectedStateful <- first invalid (kubernetesAddress cluster "apps/v1" "StatefulSet"
        (Just namespaceName) dbName)
      expectedCredential <- first invalid (kubernetesAddress cluster "v1" "Secret"
        (Just namespaceName) (dbSecretName dbName))
      unless (map (^. #address) [service, stateful, credential]
          == [expectedService, expectedStateful, expectedCredential]
          && all (== service ^. #owner) owners
          && scopeKind (service ^. #owner) == Standalone)
        (Left (invalid "database binding has a different owner or native address"))
      secretName <- first invalid (mkSecretName (dbSecretName dbName))
      fields <- first invalid (databaseConnectionEnv (boundEngine binding) name namespace)
      pure (fields, stateful ^. #identity, (secretName, Managed credential))

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
  unless (null (app ^. #tasks) && Map.null (scopeHookEffects input))
    (Left (invalid "application hooks need independent reviewed per-release Job scopes"))
  unless (scopeRollout input ^. #appName == serviceNameText (app ^. #name)
      && scopeRollout input ^. #namespace == namespaceText (app ^. #namespace))
    (Left (invalid "rollout identity differs from the application name or namespace"))
  let overrides = scopeInputOverrides input
      rollout = scopeRollout input
  unless (Map.keysSet overrides `Set.isSubsetOf`
      Set.fromList ["tag", "baseDomain", "imageResource", "requestNamespace", "cdnBackendResource", "cdnTarget"]
      && Map.lookup "tag" overrides == Just (rollout ^. #imageTag)
      && Map.lookup "imageResource" overrides == Just (resourceIdText (scopeImage input))
      && maybe True (== rollout ^. #baseDomain) (Map.lookup "baseDomain" overrides)
      && Map.lookup "requestNamespace" overrides
        == (if isJust (scopeNamespaceContributionOwner input) then Just "true" else Nothing)
      && Map.lookup "cdnBackendResource" overrides
        == (resourceIdText . (^. #identity) <$> (scopeCdnBinding input >>= \binding ->
          case googleCdnBackend binding of Managed resource -> Just resource; _ -> Nothing))
      && Map.lookup "cdnTarget" overrides
        == (globalIp . googleCdnRefs <$> scopeCdnBinding input))
    (Left (invalid "application command overrides differ from reviewed rollout inputs"))
  let brokerEnvFor bindings = do
        envs <- traverse (\binding -> do
          _ <- brokerEvidenceIds (scopeCluster input) (namespaceText (app ^. #namespace))
            binding (scopeBrokerServices input) (scopeBrokerTopics input)
          brokerConnectionEnv binding BrokerConn
            { provider = Redpanda
            , bootstrapServers = brokerNameText (binding ^. #name) <> "."
                <> namespaceText (app ^. #namespace) <> ".svc.cluster.local:9092"
            , topics = binding ^. #topics
            }) bindings
        mergeBrokerConnectionEnvs envs
  brokerEnv <- first invalid (brokerEnvFor (app ^. #brokers))
  _ <- traverse (first invalid . brokerEnvFor)
    (maybe [] (pure . (^. #brokers)) (app ^. #service)
      <> map (^. #brokers) (app ^. #workers))
  let allBrokerBindings = app ^. #brokers
        <> maybe [] (^. #brokers) (app ^. #service)
        <> concatMap (^. #brokers) (app ^. #workers)
  unless (Map.keysSet (scopeBrokerServices input)
      == Set.fromList (map (^. #name) allBrokerBindings))
    (Left (invalid "broker dependencies must cover exactly the application bindings"))
  unless (Map.keysSet (scopeBrokerTopics input) `Set.isSubsetOf` Map.keysSet (scopeBrokerServices input))
    (Left (invalid "topic evidence names an undeclared broker"))
  typedBrokerDeps <- traverse (\binding -> do
    ids <- first invalid (brokerEvidenceIds (scopeCluster input)
      (namespaceText (app ^. #namespace)) binding
      (scopeBrokerServices input) (scopeBrokerTopics input))
    pure ((binding ^. #name, binding ^. #topics), ids)) allBrokerBindings
  unless (scopeRollout input ^. #appEnv == mergeGenerated brokerEnv (app ^. #env))
    (Left (invalid "rollout environment differs from the declared application channels"))
  first invalid (reviewedTaskImages (app ^. #tasks
      <> maybe [] (^. #tasks) (app ^. #service))
    (scopeRollout input ^. #taggedAppImage) (scopeRollout input ^. #effectiveTag))
  effectiveAccess <- case (app ^. #access, app ^. #service) of
    (Just _, Nothing) -> Left (invalid "application access requires a web Service")
    (Just appPolicy, Just service)
      | Just servicePolicy <- service ^. #access
      , servicePolicy /= appPolicy ->
          Left (invalid "application and Service access policies disagree")
    (policy, maybeService) -> Right (policy <|> (maybeService >>= (^. #access)))
  unless (isJust effectiveAccess == isJust (scopeAccessBinding input))
    (Left (invalid "access intent requires exactly its accepted auth binding"))
  let envValues = Map.elems (app ^. #env)
        <> maybe [] (Map.elems . (^. #env)) (app ^. #service)
        <> concatMap (Map.elems . (^. #env)) (app ^. #workers)
        <> concatMap (Map.elems . (^. #env)) (app ^. #tasks)
        <> maybe [] (concatMap (Map.elems . (^. #env)) . (^. #tasks)) (app ^. #service)
  requiredEnvSecrets <- first invalid (runtimeSecretNames envValues)
  case (app ^. #service >>= (^. #cdn), scopeCdnBinding input) of
    (Nothing, Nothing) -> pure ()
    (Just cdn, Just binding) -> do
      unless (cdn ^. #provider == GcpCloudCdn)
        (Left (invalid "reviewed Cloudflare CDN requires its own DNS and shared-rules owner"))
      let refs = googleCdnRefs binding
          hosts = maybe [] (map (domainText . (^. #domain)) . (^. #domains)) (app ^. #service)
          target = CdnTarget hosts "" (namespaceText (app ^. #namespace))
            (serviceNameText (app ^. #name)) (scopeRollout input ^. #baseDomain)
      _ <- first invalid (planCdn cdn target refs)
      unless (all ((/= scopeRollout input ^. #baseDomain) . domainText . (^. #domain))
          (maybe [] (^. #domains) (app ^. #service)))
        (Left (invalid "platform-owned apex CDN DNS must remain a reference"))
      case googleCdnBackend binding of
        Managed backend -> unless (backend ^. #executor == PulumiExecutor
            && scopeKind (backend ^. #owner) == Platform
            && (case backend ^. #spec of NativeObject {} -> True; _ -> False)
            && any (T.isInfixOf "gcp:compute/backendService:BackendService")
              [urn | PulumiUrn urn <- backend ^. #address : backend ^. #aliases])
          (Left (invalid "CDN backend is not an accepted platform Pulumi BackendService"))
        _ -> Left (invalid "CDN backend is not an accepted managed platform resource")
    _ -> Left (invalid "service CDN requires exactly one typed Google backend binding")
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
    localBrokerEnv <- first invalid (brokerEnvFor (service ^. #brokers))
    _ <- first invalid (mergeBrokerConnectionEnvs [brokerEnv, localBrokerEnv])
    pure (service & #env %~ mergeGenerated (mergeGenerated localBrokerEnv generated)
      & #brokers .~ [] & #access .~ effectiveAccess & #cdn .~ Nothing)) (app ^. #service)
  workersWithConnection <- traverse (\worker -> do
    generated <- first invalid (declaredConnectionEnv app (worker ^. #databases))
    localBrokerEnv <- first invalid (brokerEnvFor (worker ^. #brokers))
    _ <- first invalid (mergeBrokerConnectionEnvs [brokerEnv, localBrokerEnv])
    pure (worker & #env %~ mergeGenerated (mergeGenerated localBrokerEnv generated)
      & #brokers .~ [])) (app ^. #workers)
  let scopedApp = app & #service .~ serviceWithConnection
        & #workers .~ workersWithConnection
  serviceResult <- case scopedApp ^. #service of
    Nothing -> Right Nothing
    Just _ -> Just <$> compileApplicationServiceWithAccess (scopeAccessBinding input)
      scopedApp (scopeRollout input)
      (scopeCluster input) (scopeNamespace input) (scopeImage input)
      (scopeServiceVolumeRecovery input) (scopeTlsSecrets input) envSecrets source
  cdnBundles <- case (app ^. #service >>= (^. #cdn), scopeCdnBinding input) of
    (Nothing, Nothing) -> Right []
    (Just _, Just binding) -> do
      let refs = googleCdnRefs binding
          backendId = declarationId (googleCdnBackend binding)
          domains = maybe [] (^. #domains) (app ^. #service)
      traverse (\domain -> do
        domainId <- first invalid (domainMappingResourceId owner domain)
        key <- first invalid (maybe (mkLogicalKey (domainText (domain ^. #domain))) Right
          (domain ^. #logicalKey))
        project <- first invalid (mkName (refs ^. #project))
        zone <- first invalid (mkName (refs ^. #dnsZone))
        host <- first invalid (mkName (domainText (domain ^. #domain)))
        compileGoogleDnsRecord owner key project zone host (refs ^. #globalIp)
          domainId backendId source) domains
    _ -> Left (invalid "CDN input is incomplete")
  (workerBundles, workerNative) <- compileApplicationWorkers scopedApp (scopeRollout input)
    (scopeCluster input) (scopeNamespace input) (scopeImage input)
    (scopeWorkerVolumeRecovery input) envSecrets source
  (taskBundle, taskNative) <- compileApplicationTasks app (scopeRollout input)
    (scopeCluster input) (scopeNamespace input) (scopeImage input) envSecrets source
  let namespaceBundles = maybe [] (\request -> [ResourceBundle [] [] [] [request] [] []]) namespaceContribution
      brokerIdsFor bindings = Set.toList (Set.fromList
        [resourceId | binding <- bindings,
          ((brokerName, topicNames), ids) <- typedBrokerDeps,
          brokerName == binding ^. #name,
          topicNames == binding ^. #topics,
          resourceId <- ids])
      appBrokerIds = brokerIdsFor (app ^. #brokers)
      addBrokerResource resource
        | brokerConsumer (resource ^. #address) =
            resource & #dependencies %~ (<> map OrderedAfter (brokerDependencies resource))
        | otherwise = resource
      brokerDependencies resource = Set.toList (Set.fromList (case resource ^. #address of
        Kubernetes _ "serving.knative.dev" kind _ _
          | nameText kind == "service" -> appBrokerIds
              <> maybe [] (brokerIdsFor . (^. #brokers)) (app ^. #service)
        Kubernetes _ "apps" kind _ name
          | nameText kind == "deployment" -> appBrokerIds
              <> maybe [] (brokerIdsFor . (^. #brokers))
                (find ((== nameText name) . serviceNameText . (^. #name)) (app ^. #workers))
        Kubernetes _ "batch" kind _ _ | nameText kind == "cronjob" -> appBrokerIds
        _ -> []))
      addBrokerEdges bundle = bundle & #declarations %~ map (\case
        Managed resource -> Managed (addBrokerResource resource)
        declaration -> declaration)
      brokerConsumer = \case
        Kubernetes _ "serving.knative.dev" kind _ _ -> nameText kind == "service"
        Kubernetes _ "apps" kind _ _ -> nameText kind == "deployment"
        Kubernetes _ "batch" kind _ _ -> nameText kind == "cronjob"
        _ -> False
      workloadBundles = namespaceBundles <> databaseBundles <> cdnBundles
        <> map addBrokerEdges (maybe [] (pure . fst) serviceResult <> workerBundles <> [taskBundle])
      workloadNativeMaps = [databaseNative] <> maybe [] (pure . snd) serviceResult
        <> [workerNative, taskNative]
      workloadNative = Map.union databaseNative
        (Map.map (\(resource, bytes) -> (addBrokerResource resource, bytes))
          (Map.unions (maybe [] (pure . snd) serviceResult <> [workerNative, taskNative])))
  let (prior, release) = scopeRelease input
  releaseResult <- compileApplicationRelease app (scopeRollout input) owner
    (scopeCluster input) (scopeNamespace input)
    (scopeImage input) workloadBundles prior release source
  let bundles = workloadBundles <> [fst releaseResult]
      nativeMaps = workloadNativeMaps <> [snd releaseResult]
      native = Map.union workloadNative (snd releaseResult)
      claims = [claim | bundle <- bundles, declaration <- declarations bundle
        , (_, claim) <- NE.toList (claimsOf declaration)
        , not (case declaration of
            Managed resource | DnsRecord _ _ host <- resource ^. #address ->
              claim == canonicalClaim (Hostname host)
            _ -> False)]
  configDigest <- first invalid (configDigestOf (encodeApplication app))
  scope <- withScopeOverrides (scopeInputOverrides input)
    . withScopeConfigDigest configDigest <$> mkScopeDeclaration owner bundles
  unless (Map.size native == sum (map Map.size nativeMaps))
    (Left (invalid "application native members share an identity"))
  unless (length claims == Set.size (Set.fromList claims))
    (Left (invalid "application members claim the same provider address"))
  pure (scope, native)

-- | Compose the application and its per-release hook scopes together. Keeping
-- Jobs outside the application scope lets a later tag add new executions
-- without retiring the completed Jobs from previous releases.
compileApplicationDeployment
  :: ApplicationScopeInput
  -> Either (NonEmpty InventoryError)
       ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString))
compileApplicationDeployment input = do
  let app = scopeApplication input
      hooks = app ^. #tasks
      effects = scopeHookEffects input
      overrides = scopeInputOverrides input
      invalid message = inventoryError "invalid-application-hook" message
        & #sources .~ [scopeSource input] & (:| [])
      hookKeys = Set.fromList ["hook/" <> name | name <- Map.keys effects]
      suppliedHookKeys = Set.fromList
        [key | key <- Map.keys overrides, "hook/" `T.isPrefixOf` key]
  unless (Map.keysSet effects
      == Set.fromList (map (serviceNameText . (^. #name)) hooks)
      && suppliedHookKeys == hookKeys
      && all (\(name, affected) -> Map.lookup ("hook/" <> name) overrides
        == Just (T.intercalate "," (map resourceIdText affected)))
        (Map.toList effects))
    (Left (invalid "every hook needs an exact reviewed affected-resource set or no-data-effects assertion"))
  let baseApp = app & #tasks .~ []
      baseEnvValues = Map.elems (baseApp ^. #env)
        <> maybe [] (Map.elems . (^. #env)) (baseApp ^. #service)
        <> concatMap (Map.elems . (^. #env)) (baseApp ^. #workers)
        <> maybe [] (concatMap (Map.elems . (^. #env)) . (^. #tasks))
          (baseApp ^. #service)
  baseSecretNames <- first invalid (runtimeSecretNames baseEnvValues)
  allSecretNames <- first invalid (runtimeSecretNames
    (baseEnvValues <> concatMap (Map.elems . (^. #env)) hooks))
  let baseSecrets = Map.restrictKeys (scopeEnvSecrets input)
        (Set.fromList baseSecretNames)
      baseInput = input
        { scopeApplication = baseApp
        , scopeHookEffects = Map.empty
        , scopeEnvSecrets = baseSecrets
        , scopeInputOverrides = Map.filterWithKey
            (\key _ -> not ("hook/" `T.isPrefixOf` key)) overrides
        }
  (baseScope, baseNative) <- compileApplicationScope baseInput
  if null hooks then pure ([baseScope], baseNative) else do
    let owner = scopeId baseScope
        source = scopeSource input
        cluster = scopeCluster input
        namespaceName = namespaceText (app ^. #namespace)
        ownedSecrets = [Managed resource | bundle <- scopeBundles baseScope,
          Managed resource <- declarations bundle,
          case resource ^. #address of
            Kubernetes _ "" kind _ _ -> nameText kind == "secret"
            _ -> False]
    ownSecretPairs <- traverse (\declaration -> case declaration of
      Managed resource -> case resource ^. #address of
        Kubernetes _ "" _ _ name -> do
          secret <- first invalid (mkSecretName (nameText name))
          pure (secret, declaration)
        _ -> Left (invalid "owned credential is not a Kubernetes Secret")
      _ -> Left (invalid "owned credential is not managed")) ownedSecrets
    let ownSecretMap = Map.fromList ownSecretPairs
        envSecrets = Map.union ownSecretMap (scopeEnvSecrets input)
    unless (Map.keysSet (scopeEnvSecrets input)
        == Set.fromList allSecretNames `Set.difference` Map.keysSet ownSecretMap)
      (Left (invalid "runtime Secret environment requires exactly its application and hook dependencies"))
    (hookTaskBundle, hookTaskNative) <- compileTaskMembers owner hooks
      (scopeRollout input) cluster (scopeNamespace input) (scopeImage input)
      envSecrets source
    brokerDependencies <- concat <$> traverse (\binding -> first invalid
      (brokerEvidenceIds cluster namespaceName binding
        (scopeBrokerServices input) (scopeBrokerTopics input))) (app ^. #brokers)
    let hookCronIds = Set.fromList (Map.keys hookTaskNative)
        withBrokers resource = resource & #dependencies %~
          (<> map OrderedAfter (Set.toAscList (Set.fromList brokerDependencies)))
        boundTaskBundle = hookTaskBundle & #declarations %~ map (\case
          Managed resource -> Managed (withBrokers resource)
          declaration -> declaration)
        boundTaskNative = Map.map (\(resource, bytes) -> (withBrokers resource, bytes))
          hookTaskNative
    (hookScopes, hookNative, hookProofs) <- compileApplicationHooks
      app owner (scopeRollout input) cluster boundTaskNative effects source
    releaseId <- first invalid (releaseResourceId owner app)
    let addHookEdges resource
          | hookConsumer resource || resource ^. #identity == releaseId =
              resource & #dependencies %~ (<> map OrderedAfter hookProofs)
          | otherwise = resource
        hookConsumer resource = case resource ^. #address of
          Kubernetes _ "serving.knative.dev" kind _ _ -> nameText kind == "service"
          Kubernetes _ "apps" kind _ _ -> nameText kind == "deployment"
          Kubernetes _ "batch" kind _ _ -> nameText kind == "cronjob"
            && Set.notMember (resource ^. #identity) hookCronIds
          _ -> False
        appBundles = map (\bundle -> bundle & #declarations %~ map (\case
          Managed resource -> Managed (addHookEdges resource)
          declaration -> declaration)) (scopeBundles baseScope)
          <> [boundTaskBundle]
        appNative = Map.union boundTaskNative
          (Map.map (\(resource, bytes) -> (addHookEdges resource, bytes)) baseNative)
    configDigest <- first invalid (configDigestOf (encodeApplication app))
    appScope <- withScopeOverrides overrides . withScopeConfigDigest configDigest
      <$> mkScopeDeclaration owner appBundles
    let native = Map.union hookNative appNative
    unless (Map.size native == Map.size hookNative + Map.size appNative)
      (Left (invalid "hook and application scopes share a native identity"))
    pure (appScope : hookScopes, native)

compileApplicationRelease
  :: Application -> RolloutEnv -> ScopeId -> ResourceId -> ResourceId -> ResourceId
  -> [ResourceBundle] -> StaticReleaseLog -> StaticRelease -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileApplicationRelease app rollout owner cluster namespaceId imageId priorBundles prior release source = do
  first invalid (validateReleaseLog app prior)
  let appName = releaseSubject app
      ns = namespaceText (app ^. #namespace)
      tag = rollout ^. #effectiveTag
  unless (release ^. #siteName == appName
      && release ^. #namespace == ns
      && release ^. #releaseId == tag
      && release ^. #imageTag == tag
      && release ^. #image == imageRefText (rollout ^. #qualifiedImage)
      && release ^. #url == maybe "" (\service -> serviceUrl service
        (rollout ^. #baseDomain)) (app ^. #service))
    (Left (invalid "release metadata differs from the reviewed application or image"))
  releaseId <- first invalid (releaseResourceId owner app)
  let bytes = renderReleaseConfigMapWith appDeploymentsPrefix appName ns
        (addRelease release prior)
  value <- first (invalid . T.pack) (eitherDecodeStrict bytes)
  canonical <- first invalid (canonicalValue value)
  (resource, native) <- first (:| []) (bindKubernetesObject KubernetesInput
    { resourceId = releaseId
    , ownerScope = owner
    , clusterId = cluster
    , inputObject = value
    , objectDigest = contentDigest canonical
    , lifecyclePolicy = Retain
    , inputDataPolicy = Stateless
    , inputSensitivity = Private
    , sourceLocation = source {path = path source <> "/release-history"}
    })
  expected <- first invalid (kubernetesAddress cluster "v1" "ConfigMap"
    (Just ns) (appConfigMapName appName))
  unless (resource ^. #address == expected)
    (Left (invalid "release metadata render has an unexpected native address"))
  let workloadIds = [member ^. #identity | bundle <- priorBundles,
        Managed member <- declarations bundle]
      dependencies = map OrderedAfter (Set.toAscList (Set.fromList
        (namespaceId : imageId : workloadIds)))
      bound = resource {dependencies = dependencies}
  pure (ResourceBundle [Managed bound] [] [] [] [] [],
    Map.singleton releaseId (bound, native))
  where
    invalid message = inventoryError "invalid-application-release" message
      & #scopes .~ [owner]
      & #sources .~ [source]
      & (:| [])

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
  compileTaskMembers owner (app ^. #tasks
    <> maybe [] (^. #tasks) (app ^. #service)) rollout cluster namespaceId imageId envSecrets source
  where
    invalid message = inventoryError "invalid-application-task" message
      & #sources .~ [source]
      & (:| [])

-- | Bind each pre-deploy hook to a stable, independent per-tag scope. A new
-- tag leaves prior Jobs and completion proofs in accepted history.
compileApplicationHooks
  :: Application -> ScopeId -> RolloutEnv -> ResourceId
  -> Map ResourceId (ManagedResource, ByteString)
  -> Map T.Text [ResourceId] -> SourceLocation
  -> Either (NonEmpty InventoryError)
       ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString), [ResourceId])
compileApplicationHooks app appOwner rollout cluster taskNative effects source =
  go Nothing (app ^. #tasks)
  where
    invalid message = inventoryError "invalid-application-hook" message
      & #scopes .~ [appOwner] & #sources .~ [source] & (:| [])
    tagSuffix = T.take 12 (digestText (contentDigest
      (TE.encodeUtf8 (rollout ^. #effectiveTag))))
    go _ [] = Right ([], Map.empty, [])
    go previous (task : rest) = do
      cronRole <- first invalid (mkName "cronjob")
      cronId <- first invalid (taskResourceId appOwner cronRole task)
      (_, cronBytes) <- maybe (Left (invalid "pre-deploy hook has no reviewed CronJob")) Right
        (Map.lookup cronId taskNative)
      cronValue <- first (invalid . T.pack . show)
        (Yaml.decodeEither' cronBytes :: Either Yaml.ParseException Value)
      let taskName = serviceNameText (task ^. #name)
          cronName = taskResourceName taskName
          jobName = T.dropWhileEnd (== '-') (T.take 45 cronName)
            <> "-hook-" <> tagSuffix
          scopeSuffix = T.take 40 (digestText (contentDigest
            (TE.encodeUtf8 (resourceIdText cronId <> ":" <> rollout ^. #effectiveTag))))
      owner <- first invalid (mkScopeId Standalone ("app-hook-" <> scopeSuffix))
      key <- first invalid (mkLogicalKey "run")
      jobValue <- first invalid (jobFromCronJob (Just (rollout ^. #appName))
        cronName (rollout ^. #namespace) jobName cronValue)
      canonical <- first invalid (canonicalValue jobValue)
      jobRole <- first invalid (mkName "job")
      proofRole <- first invalid (mkName "completion")
      let jobId = mintResourceId owner key jobRole
          proofId = mintResourceId owner key proofRole
      let hookSource = source {path = path source <> "/hook/" <> taskName}
      (bound, native) <- first (:| []) (bindKubernetesObject KubernetesInput
        { resourceId = jobId, ownerScope = owner, clusterId = cluster
        , inputObject = jobValue, objectDigest = contentDigest canonical
        , lifecyclePolicy = DeleteWhenUnreferenced, inputDataPolicy = Stateless
        , inputSensitivity = Private, sourceLocation = hookSource })
      expected <- first invalid (kubernetesAddress cluster "batch/v1" "Job"
        (Just (rollout ^. #namespace)) jobName)
      unless (bound ^. #address == expected)
        (Left (invalid "pre-deploy Job has an unexpected native address"))
      affected <- maybe (Left (invalid "pre-deploy hook lacks effect declaration")) Right
        (Map.lookup taskName effects)
      unless (length affected == Set.size (Set.fromList affected)
          && jobId `notElem` affected)
        (Left (invalid "pre-deploy hook repeats an affected resource"))
      let member = bound {dependencies = map OrderedAfter
            (cronId : affected <> maybe [] pure previous)}
          proof = DeclaredOperation proofId (jobId :| affected)
            [ContentInput (contentDigest native)] VerifyBeforeRetry PreDeployHook
          bundle = ResourceBundle [Managed member] [] [] [] [proof] []
      scope <- withScopeOverrides (Map.fromList
        [("tag", rollout ^. #effectiveTag), ("task", taskName),
          ("affects", T.intercalate "," (map resourceIdText affected))])
        . withScopeConfigDigest (contentDigest canonical)
        <$> mkScopeDeclaration owner [bundle]
      (laterScopes, laterNative, laterProofs) <- go (Just proofId) rest
      unless (Map.notMember jobId laterNative)
        (Left (invalid "pre-deploy hooks share a Job identity"))
      pure (scope : laterScopes, Map.insert jobId (member, native) laterNative,
        proofId : laterProofs)

compileTaskMembers
  :: ScopeId -> [Task] -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map SecretName Declaration -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileTaskMembers owner tasks rollout cluster namespaceId imageId envSecrets source = do
  unless (all ((== rollout ^. #namespace) . namespaceText . (^. #namespace)) tasks)
    (Left (invalid "scheduled task namespace differs from rollout"))
  unless (all (maybe True ((== rollout ^. #appName) . serviceNameText) . (^. #app)) tasks)
    (Left (invalid "scheduled task references a different application"))
  first invalid (reviewedTaskImages tasks (rollout ^. #taggedAppImage)
    (rollout ^. #effectiveTag))
  members <- traverse compileTask tasks
  let bundle = ResourceBundle (map (Managed . fst) members) [] [] [] [] []
      native = Map.fromList [(member ^. #identity, pair) | pair@(member, _) <- members]
  _ <- mkScopeDeclaration owner [bundle]
  unless (Map.size native == length members)
    (Left (invalid "scheduled tasks share an identity"))
  pure (bundle, native)
  where
    invalid message = inventoryError "invalid-scheduled-task" message
      & #sources .~ [source]
      & (:| [])
    compileTask task = do
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
  compileWorkersWithOwner owner app rollout cluster namespaceId imageId recoveryById envSecrets source
  where
    invalid message = inventoryError "invalid-application-worker" message
      & #sources .~ [source]
      & (:| [])

-- | A single worker uses its own scope while retaining the same native
-- Deployment/PVC binder and recovery rules as an application worker.
compileStandaloneWorker
  :: ScopeId -> Worker -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map ResourceId RecoveryIntent -> Map SecretName Declaration
  -> Map BrokerName Declaration -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneWorker owner worker rollout cluster namespaceId imageId recovery envSecrets brokerServices =
  compileStandaloneWorkerWithDependencies owner worker rollout cluster namespaceId imageId
    recovery envSecrets brokerServices Map.empty Map.empty

compileStandaloneWorkerWithDependencies
  :: ScopeId -> Worker -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map ResourceId RecoveryIntent -> Map SecretName Declaration
  -> Map BrokerName Declaration -> Map BrokerName (Map TopicName Declaration)
  -> Map DatabaseName DatabaseBinding -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneWorkerWithDependencies owner worker rollout cluster namespaceId imageId recovery envSecrets brokerServices brokerTopics databaseBindings source = do
  unless (scopeKind owner == Standalone)
    (Left (invalid "worker requires a standalone owner"))
  unless (rollout ^. #appName == serviceNameText (worker ^. #name)
      && rollout ^. #namespace == namespaceText (worker ^. #namespace)
      && Map.null (rollout ^. #appEnv))
    (Left (invalid "standalone worker rollout differs from its declared identity or environment"))
  (databaseEnv, databaseIds, databaseSecrets) <- standaloneDatabaseEnvironment cluster
    (worker ^. #namespace) (worker ^. #databases) databaseBindings invalid
  (brokerEnv, brokerIds) <- standaloneBrokerEnvironment cluster
    (namespaceText (worker ^. #namespace)) (worker ^. #brokers) brokerServices brokerTopics invalid
  let worker' = worker & #env %~ mergeGenerated (mergeGenerated brokerEnv databaseEnv)
        & #brokers .~ [] & #databases .~ []
  requiredSecrets <- first invalid (runtimeSecretNames
    (Map.elems (worker' ^. #env)))
  unless (Map.keysSet envSecrets == Set.fromList requiredSecrets
      `Set.difference` Map.keysSet databaseSecrets)
    (Left (invalid "standalone runtime Secret dependencies differ from declared external references"))
  let allSecrets = Map.union databaseSecrets envSecrets
  let app = DslApp.Application
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
  (bundles, native) <- compileWorkersWithOwner owner app rollout cluster namespaceId
    imageId recovery allSecrets source
  let addBrokerEdges resource = case resource ^. #address of
        Kubernetes _ "apps" kind _ _ | nameText kind == "deployment" ->
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
    invalid message = inventoryError "invalid-standalone-worker" message
      & #sources .~ [source]
      & (:| [])

standaloneBrokerEnvironment
  :: ResourceId -> T.Text -> [BrokerBinding] -> Map BrokerName Declaration
  -> Map BrokerName (Map TopicName Declaration)
  -> (T.Text -> NonEmpty InventoryError)
  -> Either (NonEmpty InventoryError) (Map Dsl.EnvName ScopedEnvVar, [ResourceId])
standaloneBrokerEnvironment cluster namespaceName bindings brokerServices brokerTopics invalid = do
  unless (Map.keysSet brokerServices == Set.fromList (map (^. #name) bindings)
      && length bindings == Map.size brokerServices
      && Map.keysSet brokerTopics `Set.isSubsetOf` Map.keysSet brokerServices)
    (Left (invalid "broker dependencies must cover exactly the workload bindings"))
  ids <- traverse (first invalid . (\binding -> brokerEvidenceIds cluster namespaceName
    binding brokerServices brokerTopics)) bindings
  brokerEnvs <- traverse (\binding -> do
    first invalid (brokerConnectionEnv binding BrokerConn
      { provider = Redpanda
      , bootstrapServers = brokerNameText (binding ^. #name) <> "."
          <> namespaceName <> ".svc.cluster.local:9092"
      , topics = binding ^. #topics
      })) bindings
  env <- first invalid (mergeBrokerConnectionEnvs brokerEnvs)
  pure (env, Set.toList (Set.fromList (concat ids)))

compileWorkersWithOwner
  :: ScopeId -> Application -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map ResourceId RecoveryIntent -> Map SecretName Declaration -> SourceLocation
  -> Either (NonEmpty InventoryError)
       ([ResourceBundle], Map ResourceId (ManagedResource, ByteString))
compileWorkersWithOwner scopeOwner app rollout cluster namespaceId imageId recoveryById envSecrets source = do
  compiled <- traverse (compileWorker scopeOwner) (app ^. #workers)
  let bundles = map fst compiled
      native = Map.unions (map snd compiled)
  _ <- mkScopeDeclaration scopeOwner bundles
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
  compileApplicationServiceWithAccess Nothing app rollout cluster namespaceId imageId
    recoveryByVolume tlsSecrets envSecrets source

compileApplicationServiceWithAccess
  :: Maybe AccessBinding -> Application -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map VolumeName RecoveryIntent -> Map SecretName Declaration -> Map SecretName Declaration
  -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileApplicationServiceWithAccess accessBinding app rollout cluster namespaceId imageId recoveryByVolume tlsSecrets envSecrets source = do
  _ <- first invalid (mkApplication app)
  owner <- first invalid (applicationScopeId app)
  original <- maybe (Left (invalid "application has no web service")) Right (app ^. #service)
  case (app ^. #access, original ^. #access) of
    (Just appPolicy, Just servicePolicy) | appPolicy /= servicePolicy ->
      Left (invalid "application and Service access policies disagree")
    _ -> pure ()
  let effectiveAccess = (app ^. #access) <|> (original ^. #access)
      service = original & #access .~ effectiveAccess
  unless (isJust effectiveAccess == isJust accessBinding)
    (Left (invalid "application access requires exactly its accepted auth binding"))
  databasePrerequisites <- databaseDependencies app owner (service ^. #databases) invalid
  compileServiceMembers owner service rollout cluster namespaceId imageId
    databasePrerequisites recoveryByVolume tlsSecrets envSecrets accessBinding source
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
compileStandaloneService owner service rollout cluster namespaceId imageId recovery tlsSecrets envSecrets source =
  compileStandaloneServiceWithBrokers owner service rollout cluster namespaceId imageId
    recovery tlsSecrets envSecrets Map.empty source

compileStandaloneServiceWithBrokers
  :: ScopeId -> Deployment -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map VolumeName RecoveryIntent -> Map SecretName Declaration -> Map SecretName Declaration
  -> Map BrokerName Declaration -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneServiceWithBrokers owner service rollout cluster namespaceId imageId recovery tlsSecrets envSecrets brokerServices =
  compileStandaloneServiceWithDependencies owner service rollout cluster namespaceId imageId
    recovery tlsSecrets envSecrets brokerServices Map.empty Map.empty Nothing

compileStandaloneServiceWithDependencies
  :: ScopeId -> Deployment -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map VolumeName RecoveryIntent -> Map SecretName Declaration -> Map SecretName Declaration
  -> Map BrokerName Declaration -> Map BrokerName (Map TopicName Declaration)
  -> Map DatabaseName DatabaseBinding -> Maybe AccessBinding -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneServiceWithDependencies owner service rollout cluster namespaceId imageId recovery tlsSecrets envSecrets brokerServices brokerTopics databaseBindings accessBinding source = do
  unless (scopeKind owner == Standalone)
    (Left (invalid "standalone service requires a standalone scope"))
  unless (rollout ^. #appName == serviceNameText (service ^. #name)
      && rollout ^. #namespace == namespaceText (service ^. #namespace)
      && Map.null (rollout ^. #appEnv))
    (Left (invalid "standalone rollout identity, namespace, or environment differs from its service"))
  (databaseEnv, databaseIds, databaseSecrets) <- standaloneDatabaseEnvironment cluster
    (service ^. #namespace) (service ^. #databases) databaseBindings invalid
  (brokerEnv, brokerIds) <- standaloneBrokerEnvironment cluster
    (namespaceText (service ^. #namespace)) (service ^. #brokers) brokerServices brokerTopics invalid
  let service' = service & #env %~ mergeGenerated (mergeGenerated brokerEnv databaseEnv)
        & #brokers .~ [] & #databases .~ []
  requiredEnvSecrets <- first invalid (runtimeSecretNames
    (Map.elems (service' ^. #env)
      <> concatMap (Map.elems . (^. #env)) (service ^. #tasks)))
  unless (Map.keysSet envSecrets == Set.fromList requiredEnvSecrets
      `Set.difference` Map.keysSet databaseSecrets)
    (Left (invalid "standalone runtime Secret environment requires exactly its typed dependencies"))
  let allSecrets = Map.union databaseSecrets envSecrets
  (bundle, native) <- compileServiceMembers owner service' rollout cluster namespaceId imageId
    databaseIds recovery tlsSecrets allSecrets accessBinding source
  (taskBundle, taskNative) <- compileTaskMembers owner (service ^. #tasks) rollout
    cluster namespaceId imageId allSecrets source
  let addBrokerEdges resource = case resource ^. #address of
        Kubernetes _ "serving.knative.dev" kind _ _ | nameText kind == "service" ->
          resource & #dependencies %~ (<> map OrderedAfter brokerIds)
        _ -> resource
      updatedBundle = bundle & #declarations %~ map (\case
        Managed resource -> Managed (addBrokerEdges resource)
        declaration -> declaration)
      updatedNative = Map.map (\(resource, bytes) -> (addBrokerEdges resource, bytes)) native
      allNative = Map.union updatedNative taskNative
  unless (Map.size allNative == Map.size native + Map.size taskNative)
    (Left (invalid "standalone Service and tasks share a resource identity"))
  configDigest <- first invalid (configDigestOf (encodeDeployment service))
  scope <- withScopeConfigDigest configDigest <$> mkScopeDeclaration owner [updatedBundle, taskBundle]
  pure (scope, allNative)
  where
    invalid message = inventoryError "invalid-standalone-service" message
      & #scopes .~ [owner]
      & #sources .~ [source]
      & (:| [])

-- | The public reviewed Service route also owns the legacy per-Service
-- release-history object. The lower-level member compiler remains available
-- for component tests and callers that compose a larger scope themselves.
compileStandaloneServiceWithRelease
  :: ScopeId -> Deployment -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> Map VolumeName RecoveryIntent -> Map SecretName Declaration -> Map SecretName Declaration
  -> Map BrokerName Declaration -> Map BrokerName (Map TopicName Declaration)
  -> Map DatabaseName DatabaseBinding -> Maybe AccessBinding
  -> StaticReleaseLog -> StaticRelease -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneServiceWithRelease owner service rollout cluster namespaceId imageId recovery tlsSecrets envSecrets brokerServices brokerTopics databaseBindings accessBinding prior release source = do
  (workloads, workloadNative) <- compileStandaloneServiceWithDependencies owner service rollout
    cluster namespaceId imageId recovery tlsSecrets envSecrets brokerServices brokerTopics
    databaseBindings accessBinding source
  (releaseBundle, releaseNative) <- compileApplicationRelease
    (standaloneReleaseApplication service) rollout owner cluster namespaceId imageId
    (scopeBundles workloads) prior release source
  let bundles = scopeBundles workloads <> [releaseBundle]
      claims = [claim | bundle <- bundles, declaration <- declarations bundle
        , (_, claim) <- NE.toList (claimsOf declaration)]
      native = Map.union workloadNative releaseNative
  unless (Map.size native == Map.size workloadNative + Map.size releaseNative)
    (Left (invalid "standalone Service release shares a resource identity"))
  unless (length claims == Set.size (Set.fromList claims))
    (Left (invalid "standalone Service release claims another native address"))
  configDigest <- first invalid (configDigestOf (encodeDeployment service))
  scope <- withScopeConfigDigest configDigest <$> mkScopeDeclaration owner bundles
  pure (scope, native)
  where
    invalid message = inventoryError "invalid-standalone-service-release" message
      & #scopes .~ [owner]
      & #sources .~ [source]
      & (:| [])

compileServiceMembers
  :: ScopeId -> Deployment -> RolloutEnv -> ResourceId -> ResourceId -> ResourceId
  -> [ResourceId] -> Map VolumeName RecoveryIntent -> Map SecretName Declaration -> Map SecretName Declaration
  -> Maybe AccessBinding -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileServiceMembers owner service rollout cluster namespaceId imageId databasePrerequisites recoveryByVolume tlsSecrets envSecrets accessBinding source = do
  unless (null (service ^. #brokers))
    (Left (invalid "service broker bindings require typed broker dependencies"))
  unless (service ^. #cdn == Nothing)
    (Left (invalid "service CDN requires a typed owner"))
  accessIds <- case (service ^. #access, accessBinding) of
    (Nothing, Nothing) -> Right []
    (Just policy, Just binding) -> do
      expected <- first invalid (kubernetesAddress cluster "serving.knative.dev/v1"
        "Service" (Just backendConfigMapNamespace) "nagare-access")
      case accessEnforcer binding of
        Managed enforcer
          | accessOwner binding == enforcer ^. #owner
          , scopeIdText (accessOwner binding) == "platform:auth"
          , enforcer ^. #address == expected
          , nameText (accessBaseDomain binding) == rollout ^. #baseDomain ->
              Right ([backendMapResourceId (accessOwner binding), enforcer ^. #identity]
                <> [shomeiSettingsResourceId (accessOwner binding) | policy ^. #role == AuthPortal])
        _ -> Left (invalid "access binding lacks the accepted auth enforcer")
    _ -> Left (invalid "access intent requires exactly its accepted auth binding")
  unless (null accessIds || all ((== AutomaticTls) . (^. #tls)) (service ^. #domains))
    (Left (invalid "central access routes require automatic TLS"))
  domains <- case (accessIds, service ^. #domains) of
    (_ : _, []) -> do
      host <- first invalid (mkDomain (serviceNameText (service ^. #name) <> "."
        <> namespaceText (service ^. #namespace) <> "." <> (rollout ^. #baseDomain)))
      Right [DomainSpec host Nothing True AutomaticTls]
    (_, existing) -> Right existing
  let renderedService = service & #domains .~ domains
  case service ^. #access of
    Just policy | policy ^. #role == AuthPortal -> do
      unless (length domains == 1)
        (Left (invalid "auth portal requires exactly one public hostname"))
      base <- first invalid (mkBaseDomain (rollout ^. #baseDomain))
      host <- case domains of
        [domain] -> first invalid (mkPublicHost (domainText (domain ^. #domain)))
        _ -> Left (invalid "auth portal requires exactly one public hostname")
      unless (isUnderBaseDomain base host)
        (Left (invalid "auth portal host must be under the rollout base domain"))
    _ -> pure ()
  let requiredTls = Set.fromList [secret | domain <- service ^. #domains,
        SuppliedTlsSecret secret <- [domain ^. #tls]]
  unless (Map.keysSet tlsSecrets == requiredTls)
    (Left (invalid "supplied TLS domains require exactly their typed Secret dependencies"))
  secretNames <- first invalid (runtimeSecretNames
    (Map.elems (rollout ^. #appEnv) <> Map.elems (service ^. #env)))
  secretIds <- traverse (first invalid . secretDependency cluster
    (rollout ^. #namespace) envSecrets) secretNames
  resource <- first invalid (deploymentResourceId owner (known "service") service)
  rendered <- first invalid (renderServiceObjects rollout renderedService)
  let volumes = service ^. #volumes
      (volumeRendered, serviceRendered) = splitAt (length volumes) rendered
  serviceBytes <- case serviceRendered of
    ("service", manifest) : _ -> Right manifest
    _ -> Left (invalid "service renderer produced unexpected members")
  let domainRendered = drop 1 serviceRendered
  unless (length domainRendered == length domains && all ((== "service") . fst) domainRendered)
    (Left (invalid "service domain renderer produced unexpected members"))
  unless (length volumeRendered == length volumes && all ((== "service") . fst) volumeRendered)
    (Left (invalid "service volume renderer produced unexpected members"))
  volumeMembers <- traverse compileVolume (zip volumes (map snd volumeRendered))
  let volumeIds = map ((^. #identity) . fst) volumeMembers
  serviceMember <- bindOne resource DeleteWhenUnreferenced Stateless
    (map OrderedAfter (namespaceId : imageId : volumeIds <> databasePrerequisites <> secretIds)) source serviceBytes
  domainMembers <- traverse (compileDomain accessIds resource) (zip domains (map snd domainRendered))
  contributions <- case (service ^. #access, accessBinding) of
    (Just policy, Just binding) -> traverse (\domain -> do
      host <- first invalid (mkName (domainText (domain ^. #domain)))
      key <- first invalid (mkLogicalKey (domainText (domain ^. #domain)))
      let role = if policy ^. #role == AuthPortal then PortalBackend else ProtectedBackend
      pure (RegisterBackend (accessOwner binding) cluster host
        (upstreamFor (service ^. #namespace) (service ^. #name)) role key)) domains
    _ -> Right []
  let members = volumeMembers <> [serviceMember] <> domainMembers
      declarations = [Managed declaration | (declaration, _) <- members]
      native = Map.fromList [(declaration ^. #identity, member) | member@(declaration, _) <- members]
      bundle = ResourceBundle declarations [] [] contributions [] []
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
    compileDomain accessIds serviceId (domain, bytes) = do
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
      let reviewedBytes = case accessIds of
            [] -> bytes
            _ -> renderAccessDomainMapping backendConfigMapNamespace
              (domainText (domain ^. #domain))
              (RouteTarget "serving.knative.dev/v1" "Service" "nagare-access" backendConfigMapNamespace)
          domainNamespace = if null accessIds then rollout ^. #namespace else backendConfigMapNamespace
          prerequisites = namespaceId : serviceId : tlsPrerequisites <> accessIds
      (declaration, native) <- bindOne domainId DeleteWhenUnreferenced Stateless
        (map OrderedAfter prerequisites) domainSource reviewedBytes
      expected <- first invalid (kubernetesAddress cluster "serving.knative.dev/v1beta1"
        "DomainMapping" (Just domainNamespace) (domainText (domain ^. #domain)))
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
