-- | Compile responsibilities; internal implementation behind Nagare.Inventory.Application.
module Nagare.Inventory.Application.Compile
  ( compileApplicationDeployment
  , compileApplicationScope
  , hookTriggerOverrides
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.App.Deploy (rolloutDigestReference)
import Nagare.Broker.Connection
  ( BrokerConn (..)
  , brokerConnectionEnv
  , mergeBrokerConnectionEnvs
  )
import Nagare.Cdn.Provision
  ( CdnTarget (CdnTarget)
  , GcpStackRefs (globalIp)
  , planCdn
  )
import Nagare.Dsl.Application (Application, mkApplication)
import Nagare.Dsl.Broker
  ( BrokerProvider (Redpanda)
  , brokerNameText
  )
import Nagare.Dsl.Cdn.Types
  ( CdnProvider (CloudflareCdn, GcpCloudCdn)
  )
import Nagare.Dsl.Config (encodeApplication)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Task (isReleaseOnly)
import Nagare.Dsl.Types
  ( domainText
  , mkSecretName
  , namespaceText
  , serviceNameText
  )
import Nagare.Env.Generated (mergeGenerated)
import Nagare.Inventory.Application.Bindings (brokerEvidenceIds, bucketBindingKey, keySetBindingKey)
import Nagare.Inventory.Application.ContentRoute (compileWorkerRoutes)
import Nagare.Inventory.Application.Database
  ( compileApplicationDatabases
  )
import Nagare.Inventory.Application.Environment
  ( cloudBucketIdentity
  , declaredConnectionEnv
  , reviewedTaskImages
  , runtimeSecretNamesWithBuild
  , secretDependency
  , standaloneDatabaseEnvironment
  , stripBuildSecretRefs
  , stripBuildSecretRollout
  , workloadDatabaseNames
  )
import Nagare.Inventory.Application.Policy (configDigestOf)
import Nagare.Inventory.Application.Release
  ( compileApplicationRelease
  , releaseResourceId
  )
import Nagare.Inventory.Application.Service
  ( compileApplicationServiceWithAccess
  )
import Nagare.Inventory.Application.Tasks
  ( compileApplicationHooks
  , compileApplicationTasks
  , compileTaskMembers
  )
import Nagare.Inventory.Application.Types
  ( ApplicationScopeInput (..)
  , CloudBucketBound (..)
  , CloudflareCdnBinding (..)
  , DatabaseBinding (CloudBucketBinding, KeySetBinding)
  , GoogleCdnBinding (..)
  , KeySetBound (..)
  , ReviewedCdnBinding (..)
  )
import Nagare.Inventory.Application.VolumeBackup (compileVolumeBackups)
import Nagare.Inventory.Application.Worker
  ( compileApplicationWorkers
  )
import Nagare.Inventory.TunnelRoute (checkTunnelRoutes)
import Nagare.Resource.Application
  ( applicationScopeId
  , domainMappingResourceId
  )
import Nagare.Resource.Cdn
  ( compileCloudflareCacheContribution
  , compileCloudflareDnsRecord
  , compileGoogleDnsRecord
  )
import Nagare.Resource.Inventory
  ( Contribution (RegisterNamespace)
  , Declaration (Managed)
  , DesiredSpec (NativeObject)
  , Executor (PulumiExecutor)
  , ManagedResource
  , ResourceBundle (ResourceBundle, declarations)
  , ScopeDeclaration
  , claimsOf
  , cloudflareRulesResourceId
  , contributionResourceId
  , declarationId
  , mkScopeDeclaration
  , scopeBundles
  , scopeId
  , validDnsIpv4
  , withScopeConfigDigest
  , withScopeOverrides
  )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
  ( InventoryError
  , ProviderAddress
    ( CloudflareDnsRecord
    , DnsRecord
    , Hostname
    , Kubernetes
    , PulumiUrn
    )
  , ResourceId
  , ScopeKind (Platform)
  , canonicalClaim
  , inventoryError
  , mkLogicalKey
  , mkName
  , nameText
  , resourceIdText
  , scopeKind
  )
import Nagare.Target.Kinds (hostShapeFor)

-- | Compose the currently supported application members once, checking
-- duplicate IDs and provider claims across component boundaries. Unsupported
-- fields refuse rather than silently disappearing from desired state.
compileApplicationScope ::
  ApplicationScopeInput ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileApplicationScope input = do
  let app = scopeApplication input
      source = scopeSource input
      invalid message =
        inventoryError "unsupported-application-intent" message
          & #sources
          .~ [source]
          & (:| [])
  _ <- first invalid (mkApplication app)
  -- The service and the workers bind app databases through their accepted
  -- bindings, as a standalone workload does; pre-deploy hooks bind their own
  -- (EP-259). A service's scheduled task inherits the service's environment.
  unless
    (all (null . (^. #appDatabases)) (maybe [] (^. #tasks) (app ^. #service)))
    ( Left
        ( ( inventoryError "app-database-not-bindable-from-application" "a task of an application's service inherits the service's environment; bind the app database on the service"
              & #sources
              .~ [source]
          )
            :| []
        )
    )
  unless
    (null (app ^. #tasks) && Map.null (scopeHookEffects input) && Map.null (scopeTaskDatabaseBindings input))
    (Left (invalid "application hooks need independent reviewed per-release Job scopes"))
  unless
    ( scopeRollout input ^. #appName == serviceNameText (app ^. #name)
        && scopeRollout input ^. #namespace == namespaceText (app ^. #namespace)
    )
    (Left (invalid "rollout identity differs from the application name or namespace"))
  let overrides = scopeInputOverrides input
      rollout = scopeRollout input
  unless
    ( Map.keysSet overrides
        `Set.isSubsetOf` Set.fromList ["tag", "baseDomain", "imageResource", "imageReference", "requestNamespace", "cdnBackendResource", "cdnTarget", "cdnZone", "cdnOriginIp"]
        && Map.lookup "tag" overrides == Just (rollout ^. #imageTag)
        && Map.lookup "imageResource" overrides == Just (resourceIdText (scopeImage input))
        && Map.lookup "imageReference" overrides == rolloutDigestReference rollout
        && maybe True (== rollout ^. #baseDomain) (Map.lookup "baseDomain" overrides)
        && Map.lookup "requestNamespace" overrides
          == (if isJust (scopeNamespaceContributionOwner input) then Just "true" else Nothing)
        && Map.lookup "cdnBackendResource" overrides
          == ( resourceIdText . (^. #identity)
                 <$> ( scopeCdnBinding input >>= \case
                         GoogleCdnBindingFor binding -> case googleCdnBackend binding of
                           Managed resource -> Just resource
                           _ -> Nothing
                         _ -> Nothing
                     )
             )
        && Map.lookup "cdnTarget" overrides
          == ( globalIp . googleCdnRefs
                 <$> ( scopeCdnBinding input >>= \case
                         GoogleCdnBindingFor binding -> Just binding
                         _ -> Nothing
                     )
             )
        && Map.lookup "cdnZone" overrides
          == ( nameText . cloudflareCdnZone
                 <$> ( scopeCdnBinding input >>= \case
                         CloudflareCdnBindingFor binding -> Just binding
                         _ -> Nothing
                     )
             )
        && Map.lookup "cdnOriginIp" overrides
          == ( cloudflareCdnOriginIp
                 <$> ( scopeCdnBinding input >>= \case
                         CloudflareCdnBindingFor binding -> Just binding
                         _ -> Nothing
                     )
             )
    )
    (Left (invalid "application command overrides differ from reviewed rollout inputs"))
  let brokerEnvFor bindings = do
        envs <-
          traverse
            ( \binding -> do
                _ <-
                  brokerEvidenceIds
                    (scopeCluster input)
                    (namespaceText (app ^. #namespace))
                    binding
                    (scopeBrokerServices input)
                    (scopeBrokerTopics input)
                brokerConnectionEnv
                  binding
                  BrokerConn
                    { provider = Redpanda
                    , bootstrapServers =
                        brokerNameText (binding ^. #name)
                          <> "."
                          <> namespaceText (app ^. #namespace)
                          <> ".svc.cluster.local:9092"
                    , topics = binding ^. #topics
                    }
            )
            bindings
        mergeBrokerConnectionEnvs envs
  brokerEnv <- first invalid (brokerEnvFor (app ^. #brokers))
  _ <-
    traverse
      (first invalid . brokerEnvFor)
      ( maybe [] (pure . (^. #brokers)) (app ^. #service)
          <> map (^. #brokers) (app ^. #workers)
      )
  let allBrokerBindings =
        app ^. #brokers
          <> maybe [] (^. #brokers) (app ^. #service)
          <> concatMap (^. #brokers) (app ^. #workers)
  unless
    ( Map.keysSet (scopeBrokerServices input)
        == Set.fromList (map (^. #name) allBrokerBindings)
    )
    (Left (invalid "broker dependencies must cover exactly the application bindings"))
  unless
    (Map.keysSet (scopeBrokerTopics input) `Set.isSubsetOf` Map.keysSet (scopeBrokerServices input))
    (Left (invalid "topic evidence names an undeclared broker"))
  typedBrokerDeps <-
    traverse
      ( \binding -> do
          ids <-
            first
              invalid
              ( brokerEvidenceIds
                  (scopeCluster input)
                  (namespaceText (app ^. #namespace))
                  binding
                  (scopeBrokerServices input)
                  (scopeBrokerTopics input)
              )
          pure ((binding ^. #name, binding ^. #topics), ids)
      )
      allBrokerBindings
  unless
    (scopeRollout input ^. #appEnv == mergeGenerated brokerEnv (app ^. #env))
    (Left (invalid "rollout environment differs from the declared application channels"))
  first
    invalid
    ( reviewedTaskImages
        ( app ^. #tasks
            <> maybe [] (^. #tasks) (app ^. #service)
        )
        (scopeRollout input ^. #taggedAppImage)
        (scopeRollout input ^. #effectiveTag)
    )
  effectiveAccess <- case (app ^. #access, app ^. #service) of
    (Just _, Nothing) -> Left (invalid "application access requires a web Service")
    (Just appPolicy, Just service)
      | Just servicePolicy <- service ^. #access
      , servicePolicy /= appPolicy ->
          Left (invalid "application and Service access policies disagree")
    (policy, maybeService) -> Right (policy <|> (maybeService >>= (^. #access)))
  unless
    (isJust effectiveAccess == isJust (scopeAccessBinding input))
    (Left (invalid "access intent requires exactly its accepted auth binding"))
  let envValues =
        Map.elems (app ^. #env)
          <> maybe [] (Map.elems . (^. #env)) (app ^. #service)
          <> concatMap (Map.elems . (^. #env)) (app ^. #workers)
          <> concatMap (Map.elems . (^. #env)) (app ^. #tasks)
          <> maybe [] (concatMap (Map.elems . (^. #env)) . (^. #tasks)) (app ^. #service)
  requiredEnvSecrets <-
    first
      invalid
      (runtimeSecretNamesWithBuild (scopeBuildSecrets input) envValues)
  first
    invalid
    ( checkTunnelRoutes
        (hostShapeFor (scopeRollout input ^. #targetProfile . #ingress))
        (scopeRollout input ^. #baseDomain)
        (isJust (app ^. #service >>= (^. #cdn)))
        []
    )
  case (app ^. #service >>= (^. #cdn), scopeCdnBinding input) of
    (Nothing, Nothing) -> pure ()
    (Just cdn, Just (GoogleCdnBindingFor binding)) -> do
      unless
        (cdn ^. #provider == GcpCloudCdn)
        (Left (invalid "Google CDN intent requires a Google backend binding"))
      let refs = googleCdnRefs binding
          hosts = maybe [] (map (domainText . (^. #domain)) . (^. #domains)) (app ^. #service)
          target =
            CdnTarget
              hosts
              ""
              (namespaceText (app ^. #namespace))
              (serviceNameText (app ^. #name))
              (scopeRollout input ^. #baseDomain)
      _ <- first invalid (planCdn cdn target refs)
      unless
        ( all
            ((/= scopeRollout input ^. #baseDomain) . domainText . (^. #domain))
            (maybe [] (^. #domains) (app ^. #service))
        )
        (Left (invalid "platform-owned apex CDN DNS must remain a reference"))
      case googleCdnBackend binding of
        Managed backend ->
          unless
            ( backend ^. #executor == PulumiExecutor
                && scopeKind (backend ^. #owner) == Platform
                && (case backend ^. #spec of NativeObject {} -> True; _ -> False)
                && any
                  (T.isInfixOf "gcp:compute/backendService:BackendService")
                  [urn | PulumiUrn urn <- backend ^. #address : backend ^. #aliases]
            )
            (Left (invalid "CDN backend is not an accepted platform Pulumi BackendService"))
        _ -> Left (invalid "CDN backend is not an accepted managed platform resource")
    (Just cdn, Just (CloudflareCdnBindingFor binding)) -> do
      unless
        (cdn ^. #provider == CloudflareCdn)
        (Left (invalid "Cloudflare CDN intent requires a Cloudflare zone binding"))
      unless
        ( scopeKind (cloudflareCdnOwner binding) == Platform
            && validDnsIpv4 (cloudflareCdnOriginIp binding)
            && maybe False (not . null . (^. #domains)) (app ^. #service)
        )
        (Left (invalid "Cloudflare CDN requires a platform zone owner, origin IPv4, and hostnames"))
    _ -> Left (invalid "service CDN requires exactly one matching typed binding")
  owner <- first invalid (applicationScopeId app)
  namespaceContribution <- case scopeNamespaceContributionOwner input of
    Nothing -> Right Nothing
    Just namespaceOwner -> do
      namespaceName <- first invalid (mkName (namespaceText (app ^. #namespace)))
      namespaceKey <- first invalid (mkLogicalKey (namespaceText (app ^. #namespace)))
      let request = RegisterNamespace namespaceOwner (scopeCluster input) namespaceName namespaceKey
      unless
        (contributionResourceId request == scopeNamespace input)
        (Left (invalid "namespace contribution does not match the reviewed namespace identity"))
      pure (Just request)
  (databaseBundles, databaseNative) <-
    compileApplicationDatabases
      app
      (scopeCluster input)
      (Just (scopeNamespace input))
      (scopeDatabaseRecovery input)
      (scopeDatabaseBackup input)
      source
  ownSecrets <-
    traverse
      ( \declaration -> case declaration of
          Managed resource -> case resource ^. #address of
            Kubernetes _ "" kind (Just _) secretName | nameText kind == "secret" -> do
              key <- first invalid (mkSecretName (nameText secretName))
              pure (key, declaration)
            _ -> Left (invalid "database Secret has an unexpected native address")
          _ -> Left (invalid "database credential is not a managed Secret")
      )
      [ declaration
      | bundle <- databaseBundles
      , declaration@(Managed resource) <- declarations bundle
      , case resource ^. #address of
          Kubernetes _ "" kind _ _ -> nameText kind == "secret"
          _ -> False
      ]
  let ownSecretMap = Map.fromList ownSecrets
      requiredSet = Set.fromList requiredEnvSecrets
  unless
    (length ownSecrets == Map.size ownSecretMap)
    (Left (invalid "database credentials share a Secret name"))
  unless
    (Map.keysSet (scopeEnvSecrets input) == requiredSet `Set.difference` Map.keysSet ownSecretMap)
    (Left (invalid "runtime Secret environment requires exactly its external typed dependencies"))
  -- EP-283: the service's and each worker's accepted bucket bindings, as
  -- variables and the workload's own credential Secret. The buckets are
  -- applied by their own review before this one, so the Secret dependency is
  -- the only edge an application workload needs.
  -- EP-286: a key set binding shares the map as keyset-<name> and adds an
  -- edge to the key set's first-run Job (keySetDependencies).
  let bucketWorkloads = maybe [] (\service -> [(service ^. #name, (service ^. #env, service ^. #appDatabases, service ^. #buckets, service ^. #keySets))]) (app ^. #service) <> [(worker ^. #name, (worker ^. #env, worker ^. #appDatabases, worker ^. #buckets, worker ^. #keySets)) | worker <- app ^. #workers]
  unless
    (Map.keysSet (Map.filter (not . Map.null) (scopeBucketBindings input)) `Set.isSubsetOf` Set.fromList [workloadName | (workloadName, (_, apps, buckets, keySets)) <- bucketWorkloads, not (null apps && null buckets && null keySets)])
    (Left (invalid "bucket or key set dependencies name a workload that binds neither"))
  bucketEnvironments <-
    Map.fromList
      <$> traverse
        ( \(workloadName, (env, apps, buckets, keySets)) -> do
            names <- first invalid (workloadDatabaseNames env [] apps [] buckets keySets)
            (generated, ids, secrets) <- standaloneDatabaseEnvironment (scopeCluster input) (app ^. #namespace) names apps (Map.findWithDefault Map.empty workloadName (scopeBucketBindings input)) invalid
            pure (workloadName, (generated, secrets, [resource | not (null apps), resource <- ids]))
        )
        bucketWorkloads
  -- EP-284: a workload with a cloud bucket binding runs as its grant's account with the identity mount.
  identities <-
    Map.fromList . catMaybes
      <$> traverse
        ( \(workloadName, own) ->
            fmap (workloadName,) <$> first invalid (cloudBucketIdentity own (Map.findWithDefault Map.empty workloadName (scopeBucketBindings input)))
        )
        (maybe [] (\service -> [(service ^. #name, service ^. #serviceAccount)]) (app ^. #service) <> [(worker ^. #name, worker ^. #serviceAccount) | worker <- app ^. #workers])
  let identityFor workloadName = fst <$> Map.lookup workloadName identities
      withIdentityMounts rollout' = rollout' & #platformMounts %~ Map.unionWith (<>) (Map.fromList [(serviceNameText workloadName, [mount]) | (workloadName, (_, mount)) <- Map.toList identities])
  let bucketEnvFor workloadName = maybe Map.empty (\(generated, _, _) -> generated) (Map.lookup workloadName bucketEnvironments)
      envSecrets = Map.unions [ownSecretMap, scopeEnvSecrets input, Map.unions [secrets | (_, secrets, _) <- Map.elems bucketEnvironments]]
  _ <-
    traverse
      ( first invalid
          . secretDependency
            (scopeCluster input)
            (namespaceText (app ^. #namespace))
            envSecrets
      )
      requiredEnvSecrets
  let runtimeApp = stripBuildSecretRefs app
      runtimeRollout = withIdentityMounts (stripBuildSecretRollout (scopeRollout input))
  serviceWithConnection <-
    traverse
      ( \service -> do
          generated <- first invalid (declaredConnectionEnv app (service ^. #databases))
          localBrokerEnv <- first invalid (brokerEnvFor (service ^. #brokers))
          _ <- first invalid (mergeBrokerConnectionEnvs [brokerEnv, localBrokerEnv])
          pure
            ( service
                & #serviceAccount
                %~ maybe id (const . Just) (identityFor (service ^. #name))
                & #env
                %~ mergeGenerated (bucketEnvFor (service ^. #name))
                . mergeGenerated (mergeGenerated localBrokerEnv generated)
                & #brokers
                .~ []
                & #access
                .~ effectiveAccess
                & #cdn
                .~ Nothing
            )
      )
      (runtimeApp ^. #service)
  workersWithConnection <-
    traverse
      ( \worker -> do
          generated <- first invalid (declaredConnectionEnv app (worker ^. #databases))
          localBrokerEnv <- first invalid (brokerEnvFor (worker ^. #brokers))
          _ <- first invalid (mergeBrokerConnectionEnvs [brokerEnv, localBrokerEnv])
          pure
            ( worker
                & #serviceAccount
                %~ maybe id (const . Just) (identityFor (worker ^. #name))
                & #env
                %~ mergeGenerated (bucketEnvFor (worker ^. #name))
                . mergeGenerated (mergeGenerated localBrokerEnv generated)
                & #brokers
                .~ []
            )
      )
      (runtimeApp ^. #workers)
  let scopedApp =
        runtimeApp
          & #service
          .~ serviceWithConnection
          & #workers
          .~ workersWithConnection
  serviceResult <- case scopedApp ^. #service of
    Nothing -> Right Nothing
    Just _ ->
      Just
        <$> compileApplicationServiceWithAccess
          (scopeAccessBinding input)
          scopedApp
          runtimeRollout
          (scopeCluster input)
          (scopeNamespace input)
          (scopeImage input)
          (scopeServiceVolumeRecovery input)
          (scopeTlsSecrets input)
          envSecrets
          source
  cdnBundles <- case (app ^. #service >>= (^. #cdn), scopeCdnBinding input) of
    (Nothing, Nothing) -> Right []
    (Just _, Just (GoogleCdnBindingFor binding)) -> do
      let refs = googleCdnRefs binding
          backendId = declarationId (googleCdnBackend binding)
          domains = maybe [] (^. #domains) (app ^. #service)
      traverse
        ( \domain -> do
            domainId <- first invalid (domainMappingResourceId owner domain)
            key <-
              first
                invalid
                ( maybe
                    (mkLogicalKey (domainText (domain ^. #domain)))
                    Right
                    (domain ^. #logicalKey)
                )
            project <- first invalid (mkName (refs ^. #project))
            zone <- first invalid (mkName (refs ^. #dnsZone))
            host <- first invalid (mkName (domainText (domain ^. #domain)))
            compileGoogleDnsRecord
              owner
              key
              project
              zone
              host
              (refs ^. #globalIp)
              domainId
              backendId
              source
        )
        domains
    (Just cdn, Just (CloudflareCdnBindingFor binding)) -> do
      let zone = cloudflareCdnZone binding
          ruleset = cloudflareRulesResourceId (cloudflareCdnOwner binding) zone
          domains = maybe [] (^. #domains) (app ^. #service)
      fmap concat $
        traverse
          ( \domain -> do
              domainId <- first invalid (domainMappingResourceId owner domain)
              key <-
                first
                  invalid
                  ( maybe
                      (mkLogicalKey (domainText (domain ^. #domain)))
                      Right
                      (domain ^. #logicalKey)
                  )
              host <- first invalid (mkName (domainText (domain ^. #domain)))
              cache <-
                compileCloudflareCacheContribution
                  owner
                  (cloudflareCdnOwner binding)
                  zone
                  host
                  cdn
                  domainId
                  source
              dns <-
                compileCloudflareDnsRecord
                  owner
                  key
                  zone
                  host
                  (cloudflareCdnOriginIp binding)
                  domainId
                  ruleset
                  source
              pure [cache, dns]
          )
          domains
    _ -> Left (invalid "CDN input is incomplete")
  (workerBundles, workerNative) <-
    compileApplicationWorkers
      scopedApp
      runtimeRollout
      (scopeCluster input)
      (scopeNamespace input)
      (scopeImage input)
      (scopeWorkerVolumeRecovery input)
      envSecrets
      source
  -- EP-285: each worker's port as a Service, and its content route.
  (routeBundles, routeNative) <- compileWorkerRoutes scopedApp runtimeRollout owner (scopeCluster input) (scopeNamespace input) source
  (taskBundle, taskNative) <-
    compileApplicationTasks
      runtimeApp
      runtimeRollout
      (scopeCluster input)
      (scopeNamespace input)
      (scopeImage input)
      envSecrets
      source
  let namespaceBundles = maybe [] (\request -> [ResourceBundle [] [] [] [request] [] []]) namespaceContribution
      brokerIdsFor bindings =
        Set.toList
          ( Set.fromList
              [ resourceId
              | binding <- bindings
              , ((brokerName, topicNames), ids) <- typedBrokerDeps
              , brokerName == binding ^. #name
              , topicNames == binding ^. #topics
              , resourceId <- ids
              ]
          )
      appBrokerIds = brokerIdsFor (app ^. #brokers)
      keySetDependencies workloadName =
        maybe [] (\(_, _, ids) -> ids) (Map.lookup workloadName bucketEnvironments)
          <> concat
            [ case binding of
                KeySetBinding bound -> [keySetFirstRun bound]
                -- EP-284: the credential configuration and the account the workload runs as.
                CloudBucketBinding bound -> [cloudBucketCredentials bound ^. #identity, cloudBucketAccount bound ^. #identity]
                _ -> []
            | binding <- Map.elems (Map.findWithDefault Map.empty workloadName (scopeBucketBindings input))
            ]
      addBrokerResource resource
        | brokerConsumer (resource ^. #address) =
            resource & #dependencies %~ (<> map OrderedAfter (brokerDependencies resource))
        | otherwise = resource
      brokerDependencies resource =
        Set.toList
          ( Set.fromList
              ( case resource ^. #address of
                  Kubernetes _ "serving.knative.dev" kind _ _
                    | nameText kind == "service" ->
                        appBrokerIds
                          <> maybe [] (brokerIdsFor . (^. #brokers)) (app ^. #service)
                          <> maybe [] (keySetDependencies . (^. #name)) (app ^. #service)
                  Kubernetes _ "apps" kind _ name
                    | nameText kind == "deployment" ->
                        appBrokerIds
                          <> maybe
                            []
                            (\worker -> brokerIdsFor (worker ^. #brokers) <> keySetDependencies (worker ^. #name))
                            (find ((== nameText name) . serviceNameText . (^. #name)) (app ^. #workers))
                  Kubernetes _ "batch" kind _ _ | nameText kind == "cronjob" -> appBrokerIds
                  _ -> []
              )
          )
      addBrokerEdges bundle =
        bundle
          & #declarations
          %~ map
            ( \case
                Managed resource -> Managed (addBrokerResource resource)
                declaration -> declaration
            )
      brokerConsumer = \case
        Kubernetes _ "serving.knative.dev" kind _ _ -> nameText kind == "service"
        Kubernetes _ "apps" kind _ _ -> nameText kind == "deployment"
        Kubernetes _ "batch" kind _ _ -> nameText kind == "cronjob"
        _ -> False
      workloadBundles =
        namespaceBundles
          <> databaseBundles
          <> cdnBundles
          <> routeBundles
          <> map addBrokerEdges (maybe [] (pure . fst) serviceResult <> workerBundles <> [taskBundle])
      workloadNativeMaps =
        [databaseNative, routeNative]
          <> maybe [] (pure . snd) serviceResult
          <> [workerNative, taskNative]
      workloadNative =
        Map.unions
          [ databaseNative
          , routeNative
          , Map.map
              (\(resource, bytes) -> (addBrokerResource resource, bytes))
              (Map.unions (maybe [] (pure . snd) serviceResult <> [workerNative, taskNative]))
          ]
  let (prior, release) = scopeRelease input
  releaseResult <-
    compileApplicationRelease
      app
      (scopeRollout input)
      owner
      (scopeCluster input)
      (scopeNamespace input)
      (scopeImage input)
      workloadBundles
      prior
      release
      source
  -- EP-183 M3: each backup-included volume of the service and workers gets
  -- its scheduled producer, ordered after its claim.
  backupResults <-
    compileVolumeBackups
      (scopeDatabaseBackup input)
      (scopeNamespace input)
      source
      (Map.unions (maybe [] (pure . snd) serviceResult <> [workerNative]))
  let bundles = workloadBundles <> [fst releaseResult] <> map fst backupResults
      nativeMaps = workloadNativeMaps <> [snd releaseResult] <> map snd backupResults
      native = Map.unions (workloadNative : snd releaseResult : map snd backupResults)
      claims =
        [ claim
        | bundle <- bundles
        , declaration <- declarations bundle
        , (_, claim) <- NE.toList (claimsOf declaration)
        , not
            ( case declaration of
                Managed resource -> case resource ^. #address of
                  DnsRecord _ _ host -> claim == canonicalClaim (Hostname host)
                  CloudflareDnsRecord _ host -> claim == canonicalClaim (Hostname host)
                  _ -> False
                _ -> False
            )
        ]
  configDigest <- first invalid (configDigestOf (encodeApplication app))
  scope <-
    withScopeOverrides (scopeInputOverrides input)
      . withScopeConfigDigest configDigest
      <$> mkScopeDeclaration owner bundles
  unless
    (Map.size native == sum (map Map.size nativeMaps))
    (Left (invalid "application native members share an identity"))
  unless
    (length claims == Set.size (Set.fromList claims))
    (Left (invalid "application members claim the same provider address"))
  pure (scope, native)

-- | The reviewed override that records each release-only pre-deploy hook on
-- the application scope (EP-269): @hookTrigger/TASK = release-only@. The deploy
-- preview and saved review show it; the hook scope itself is unchanged.
hookTriggerOverrides :: Application -> Map Text Text
hookTriggerOverrides app =
  Map.fromList
    [ (hookTriggerPrefix <> serviceNameText (task ^. #name), "release-only")
    | task <- app ^. #tasks
    , isReleaseOnly task
    ]

hookTriggerPrefix :: Text
hookTriggerPrefix = "hookTrigger/"

-- | Compose the application and its per-release hook scopes together. Keeping
-- Jobs outside the application scope lets a later tag add new executions
-- without retiring the completed Jobs from previous releases.
compileApplicationDeployment ::
  ApplicationScopeInput ->
  Either
    (NonEmpty InventoryError)
    ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString))
compileApplicationDeployment input = do
  let app = scopeApplication input
      hooks = app ^. #tasks
      effects = scopeHookEffects input
      overrides = scopeInputOverrides input
      invalid message =
        inventoryError "invalid-application-hook" message
          & #sources
          .~ [scopeSource input]
          & (:| [])
      hookKeys = Set.fromList ["hook/" <> name | name <- Map.keys effects]
      suppliedHookKeys =
        Set.fromList
          [key | key <- Map.keys overrides, "hook/" `T.isPrefixOf` key]
  unless
    ( Map.keysSet effects
        == Set.fromList (map (serviceNameText . (^. #name)) hooks)
        && suppliedHookKeys == hookKeys
        && all
          ( \(name, affected) ->
              Map.lookup ("hook/" <> name) overrides
                == Just (T.intercalate "," (map resourceIdText affected))
          )
          (Map.toList effects)
    )
    (Left (invalid "every hook needs an exact reviewed affected-resource set or no-data-effects assertion"))
  unless
    (Map.filterWithKey (\key _ -> hookTriggerPrefix `T.isPrefixOf` key) overrides == hookTriggerOverrides app)
    (Left (invalid "every release-only hook needs exactly its reviewed hookTrigger override"))
  let baseApp = app & #tasks .~ []
      baseEnvValues =
        Map.elems (baseApp ^. #env)
          <> maybe [] (Map.elems . (^. #env)) (baseApp ^. #service)
          <> concatMap (Map.elems . (^. #env)) (baseApp ^. #workers)
          <> maybe
            []
            (concatMap (Map.elems . (^. #env)) . (^. #tasks))
            (baseApp ^. #service)
  baseSecretNames <-
    first
      invalid
      (runtimeSecretNamesWithBuild (scopeBuildSecrets input) baseEnvValues)
  allSecretNames <-
    first
      invalid
      ( runtimeSecretNamesWithBuild
          (scopeBuildSecrets input)
          (baseEnvValues <> concatMap (Map.elems . (^. #env)) hooks)
      )
  let baseSecrets =
        Map.restrictKeys
          (scopeEnvSecrets input)
          (Set.fromList baseSecretNames)
      baseInput =
        input
          { scopeApplication = baseApp
          , scopeHookEffects = Map.empty
          , scopeTaskDatabaseBindings = Map.empty
          , scopeEnvSecrets = baseSecrets
          , scopeInputOverrides =
              Map.filterWithKey
                (\key _ -> not ("hook/" `T.isPrefixOf` key || hookTriggerPrefix `T.isPrefixOf` key))
                overrides
          }
  (baseScope, baseNative) <- compileApplicationScope baseInput
  if null hooks
    then pure ([baseScope], baseNative)
    else do
      let owner = scopeId baseScope
          source = scopeSource input
          cluster = scopeCluster input
          namespaceName = namespaceText (app ^. #namespace)
          ownedSecrets =
            [ Managed resource
            | bundle <- scopeBundles baseScope
            , Managed resource <- declarations bundle
            , case resource ^. #address of
                Kubernetes _ "" kind _ _ -> nameText kind == "secret"
                _ -> False
            ]
      ownSecretPairs <-
        traverse
          ( \declaration -> case declaration of
              Managed resource -> case resource ^. #address of
                Kubernetes _ "" _ _ name -> do
                  secret <- first invalid (mkSecretName (nameText name))
                  pure (secret, declaration)
                _ -> Left (invalid "owned credential is not a Kubernetes Secret")
              _ -> Left (invalid "owned credential is not managed")
          )
          ownedSecrets
      let ownSecretMap = Map.fromList ownSecretPairs
          envSecrets = Map.union ownSecretMap (scopeEnvSecrets input)
      unless
        ( Map.keysSet (scopeEnvSecrets input)
            == Set.fromList allSecretNames `Set.difference` Map.keysSet ownSecretMap
        )
        (Left (invalid "runtime Secret environment requires exactly its application and hook dependencies"))
      (hookTaskBundle, hookTaskNative) <-
        compileTaskMembers
          owner
          (stripBuildSecretRefs app ^. #tasks)
          (scopeTaskDatabaseBindings input)
          (stripBuildSecretRollout (scopeRollout input))
          cluster
          (scopeNamespace input)
          (scopeImage input)
          envSecrets
          source
      brokerDependencies <-
        concat
          <$> traverse
            ( \binding ->
                first
                  invalid
                  ( brokerEvidenceIds
                      cluster
                      namespaceName
                      binding
                      (scopeBrokerServices input)
                      (scopeBrokerTopics input)
                  )
            )
            (app ^. #brokers)
      let hookCronIds = Set.fromList (Map.keys hookTaskNative)
          withBrokers resource =
            resource
              & #dependencies
              %~ (<> map OrderedAfter (Set.toAscList (Set.fromList brokerDependencies)))
          boundTaskBundle =
            hookTaskBundle
              & #declarations
              %~ map
                ( \case
                    Managed resource -> Managed (withBrokers resource)
                    declaration -> declaration
                )
          boundTaskNative =
            Map.map
              (\(resource, bytes) -> (withBrokers resource, bytes))
              hookTaskNative
      (hookScopes, hookNative, hookProofs) <-
        compileApplicationHooks
          app
          owner
          (scopeRollout input)
          (scopeTaskDatabaseBindings input)
          cluster
          boundTaskNative
          effects
          source
      releaseId <- first invalid (releaseResourceId owner app)
      let addHookEdges resource
            | hookConsumer resource || resource ^. #identity == releaseId =
                resource & #dependencies %~ (<> map OrderedAfter hookProofs)
            | otherwise = resource
          hookConsumer resource = case resource ^. #address of
            Kubernetes _ "serving.knative.dev" kind _ _ -> nameText kind == "service"
            Kubernetes _ "apps" kind _ _ -> nameText kind == "deployment"
            Kubernetes _ "batch" kind _ _ ->
              nameText kind == "cronjob"
                && Set.notMember (resource ^. #identity) hookCronIds
            _ -> False
          appBundles =
            map
              ( \bundle ->
                  bundle
                    & #declarations
                    %~ map
                      ( \case
                          Managed resource -> Managed (addHookEdges resource)
                          declaration -> declaration
                      )
              )
              (scopeBundles baseScope)
              <> [boundTaskBundle]
          appNative =
            Map.union
              boundTaskNative
              (Map.map (\(resource, bytes) -> (addHookEdges resource, bytes)) baseNative)
      configDigest <- first invalid (configDigestOf (encodeApplication app))
      appScope <-
        withScopeOverrides overrides . withScopeConfigDigest configDigest
          <$> mkScopeDeclaration owner appBundles
      let native = Map.union hookNative appNative
      unless
        (Map.size native == Map.size hookNative + Map.size appNative)
        (Left (invalid "hook and application scopes share a native identity"))
      pure (appScope : hookScopes, native)
