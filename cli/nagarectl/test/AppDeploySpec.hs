-- | Tests for @nagarectl app deploy@ orchestration (MasterPlan 14, EP-2).
--
-- M1: rendering an 'Application' fans it out into the right objects, in rollout
-- order, each stamped with the shared @nagare.dev/app@ label. M2: the rollout
-- phase plan is in the fixed order, and a failed pre-deploy hook aborts before any
-- later phase runs. These are offline (the load test spawns @runghc@, exactly as
-- the nagare-dsl loader tests do).
module AppDeploySpec (appDeployTests) where

import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.App.Deploy
import Nagare.Inventory.Application (ApplicationScopeInput (..), acceptedBrokerBindings, acceptedSecretBindings, applicationNativeOwned, applicationRetirementScope, applicationVolumeRecoveryBindings, standaloneWorkerVolumeRecoveryBindings, nativeWorkloadOwned, compileApplicationScope, compileApplicationService, compileStandaloneService, compileStandaloneServiceWithBrokers, compileStandaloneWorker, compileApplicationTasks, compileApplicationWorkers, databaseRecoveryBindings, workerRetirementScope)
import Nagare.Inventory.DataService (compileStandaloneBroker)
import Nagare.Dsl.Broker (BrokerBinding (..), mkTopicName)
import Nagare.Resource.Application (applicationScopeId, volumeResourceId)
import Nagare.Resource.Database (databaseResourceId)
import Nagare.Resource.Inventory (ResourceBundle (..), Declaration (..), ManagedResource (..), DesiredSpec (KnativeService), Contribution (RegisterNamespace), ContributionGrant (NamespaceGrant), ScopeChange (ReplaceScope), candidateGenerations, candidateInventory, composeInventory, contributionResourceId, declarationId, inventoryDeclarations, inventoryScopes, mkScopeDeclaration, mkScopeSnapshot, scopeBundles, scopeId)
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types qualified as Resource
import Nagare.Dsl.Load (loadApplication, loadBroker)
import Nagare.Dsl.Database (dbSecretName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (AccessMode (ReadWriteOnce), DomainTls (SuppliedTlsSecret), EnvScope (Build), EnvVar (EnvSecretRef), RetentionPolicy (Retain), Volume (..), databaseNameText, mkDomains, mkEnvName, mkImageRef, mkMountPath, mkNamespace, mkQuantity, mkSecretName, mkServiceName, mkVolumeName, runtimeScoped, scopedEnv, serviceNameText)
import Nagare.Dsl.Worker (Worker (..))
import Nagare.Dsl.Presets (attachVolume)
import Nagare.Env.Generated (mergeGenerated)
import Nagare.Target (InventoryStoreKind (..), Mode (..), PulumiBackendKind (..), TargetProfile (..))
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

appDeployTests :: TestTree
appDeployTests =
  testGroup
    "Nagare.App.Deploy (EP-2)"
    [ testGroup "render + shared label (M1)" renderTests
    , testGroup "rollout phases (M2)" phaseTests
    , testGroup "machine-readable plan (M3)" planTests
    , testGroup "remediation guardrails (EP-6)" remediationTests
    ]

fixturePath :: FilePath
fixturePath = "test/fixtures/app/kizashi/Config.hs"

-- | A deterministic rollout context (fixed tag, unqualified shared image) so the
-- rendered bytes are stable.
testEnv :: RolloutEnv
testEnv =
  RolloutEnv
    { appName = "kizashi"
    , qualifiedImage = unsafe (mkImageRef "gcr.io/knative-samples/helloworld-go")
    , imageTag = "20260619-120000"
    , effectiveTag = "20260619-120000"
    , taggedAppImage = "gcr.io/knative-samples/helloworld-go:20260619-120000"
    , appEnv = Map.empty
    , namespace = "personal"
    , baseDomain = "apps.example.com"
    , targetProfile = testProfile
    }

testProfile :: TargetProfile
testProfile =
  TargetProfile
    { project = "tan-nb-exp"
    , region = "us-west1"
    , zone = "us-west1-a"
    , registryHost = "us-west1-docker.pkg.dev"
    , artifactRegistryId = "nagare"
    , imageBucket = "tan-nb-exp-nagare-images"
    , backupBucket = "tan-nb-exp-nagare-backups"
    , nixCacheEnabled = False
    , nixCacheBucket = "tan-nb-exp-nagare-nix-cache"
    , baseDomain = "apps.example.com"
    , externalDomainTlsEnabled = False
    , instanceName = "nagare-01"
    , machineType = "e2-standard-2"
    , bootDiskType = "pd-balanced"
    , bootDiskSizeGb = "100"
    , dataDiskSizeGb = "100"
    , targetPlatform = "linux/amd64"
    , mode = Cloud
    , localObjectStore = ""
    , pulumiBackend = PulumiBackendLocal
    , pulumiBackendUrl = ""
    , inventoryStore = InventoryStoreLocal
    , inventoryStoreUrl = ""
    , acmeEmail = "ops@example.com"
    , acmeDirectory = "production"
    , platformVersion = Nothing
    }

renderTests :: [TestTree]
renderTests =
  [ testCase "renders hook, databases, service, and workers in rollout order" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          objects <- unwrapRender (renderAppObjects testEnv app)
          map fst objects
            @?= ["namespace", "hook", "database", "database", "database", "database", "database", "service", "worker", "worker", "worker"]
  , testCase "typed service member binds the rendered Knative object" $ do
      loaded <- loadApplication fixturePath
      app <- either (fail . show) pure loaded
      let foundation = unsafe (Resource.mkScopeId Resource.Platform "foundation")
          cluster = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "cluster")) (unsafe (Resource.mkName "resource"))
          namespaceId = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "foundation")) (unsafe (Resource.mkName "namespace-personal"))
          publication = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "image")) (unsafe (Resource.mkName "publication"))
          source = Resource.SourceLocation "test" "service"
      (bundle, native) <- either (fail . show) pure
        (compileApplicationService app testEnv cluster namespaceId publication Map.empty Map.empty Map.empty source)
      owner <- either (fail . show) pure (applicationScopeId app)
      case declarations bundle of
        [Managed service] -> do
          service ^. #owner @?= owner
          assertBool "direct app deploy must detect an owned native Service"
            (applicationNativeOwned app [service])
          assertBool "direct app stop/restart/delete must detect an owned native Service"
            (nativeWorkloadOwned "serving.knative.dev" "service" "kizashi-serve" "personal" [service])
          assertBool "different native Service must remain separate"
            (not (nativeWorkloadOwned "serving.knative.dev" "service" "other" "personal" [service]))
          assertBool "another namespace must not claim the app workload"
            (not (applicationNativeOwned (app & #namespace .~ unsafe (mkNamespace "other")) [service]))
          let accepted kind name = service & #address .~ Resource.Kubernetes cluster "" (unsafe (Resource.mkName kind))
                (Just (unsafe (Resource.mkName "personal"))) (unsafe (Resource.mkName name))
              withVolume = app & #service %~ fmap (unsafe . attachVolume "data" "1Gi" "/data")
          assertBool "direct app deploy must detect an owned service PVC"
            (applicationNativeOwned withVolume [accepted "persistentvolumeclaim" "nagare-vol-kizashi-serve-data"])
          assertBool "direct app deploy must detect an owned database credential"
            (applicationNativeOwned app [accepted "secret" "nagare-db-kizashi-db"])
          assertBool "a different PVC address must not claim the application"
            (not (applicationNativeOwned app [accepted "persistentvolumeclaim" "nagare-vol-unrelated-data"]))
          case service ^. #spec of
            KnativeService _ -> pure ()
            other -> assertFailure ("service lacks Knative reservation: " <> show other)
          Map.keys native @?= [service ^. #identity]
        other -> assertFailure ("unexpected service declarations: " <> show other)
      let withVolume = app & #service %~ fmap (unsafe . attachVolume "data" "1Gi" "/data")
      case compileApplicationService withVolume testEnv cluster namespaceId publication Map.empty Map.empty Map.empty source of
        Left _ -> pure ()
        Right _ -> assertFailure "retained service volume without recovery was accepted"
      let volumeName = unsafe (mkVolumeName "data")
          recovery = RecoveryIntent (unsafe (Resource.mkName "backup"))
            (mkSecretRef (unsafe (Resource.mkName "volume-key"))
              (unsafe (Resource.mkName "v1")) :| [])
      (serviceRecovery, _) <- either (fail . T.unpack) pure
        (applicationVolumeRecoveryBindings withVolume ["data=backup:volume-key:v1"] [])
      Map.lookup volumeName serviceRecovery @?= Just recovery
      assertBool "retained Service volume without recovery was accepted"
        (isLeft (applicationVolumeRecoveryBindings withVolume [] []))
      (volumeBundle, volumeNative) <- either (fail . show) pure
        (compileApplicationService withVolume testEnv cluster namespaceId publication
          (Map.singleton volumeName recovery) Map.empty Map.empty source)
      length (declarations volumeBundle) @?= 2
      Map.size volumeNative @?= 2
      let withDomain = app & #service %~ fmap
            (#domains .~ unsafe (mkDomains [("app.example.com", True)]))
      (domainBundle, domainNative) <- either (fail . show) pure
        (compileApplicationService withDomain testEnv cluster namespaceId publication Map.empty Map.empty Map.empty source)
      length (declarations domainBundle) @?= 2
      Map.size domainNative @?= 2
      assertBool "domain hostname claim omitted"
        (any (elem (Resource.Hostname (unsafe (Resource.mkName "app.example.com"))) . (^. #aliases))
          [member | Managed member <- declarations domainBundle])
      let supplied = withDomain & #service %~ fmap
            (#domains . traverse . #tls .~ SuppliedTlsSecret (unsafe (mkSecretName "custom-tls")))
      case compileApplicationService supplied testEnv cluster namespaceId publication Map.empty Map.empty Map.empty source of
        Left _ -> pure ()
        Right _ -> assertFailure "supplied TLS domain lacked a typed secret dependency"
      let secretName = unsafe (mkSecretName "custom-tls")
          secretId = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "custom-tls")) (unsafe (Resource.mkName "secret"))
          secretAddress = Resource.Kubernetes cluster "" (unsafe (Resource.mkName "secret"))
            (Just (unsafe (Resource.mkName "personal"))) (unsafe (Resource.mkName "custom-tls"))
          secret = External secretId secretAddress [] source
      (suppliedBundle, _) <- either (fail . show) pure
        (compileApplicationService supplied testEnv cluster namespaceId publication Map.empty
          (Map.singleton secretName secret) Map.empty source)
      assertBool "supplied TLS DomainMapping lacks Secret dependency"
        (any (elem (OrderedAfter secretId) . (^. #dependencies))
          [member | Managed member <- declarations suppliedBundle])
      let wrongSecret = External secretId
            (Resource.Kubernetes cluster "" (unsafe (Resource.mkName "secret"))
              (Just (unsafe (Resource.mkName "other"))) (unsafe (Resource.mkName "custom-tls"))) [] source
      case compileApplicationService supplied testEnv cluster namespaceId publication Map.empty
          (Map.singleton secretName wrongSecret) Map.empty source of
        Left _ -> pure ()
        Right _ -> assertFailure "supplied TLS accepted a Secret in another namespace"
  , testCase "standalone Service binds the same rendered object under its own scope" $ do
      loaded <- loadApplication fixturePath
      app <- either (fail . show) pure loaded
      service <- maybe (assertFailure "fixture has no service" >> fail "missing service") pure
        (app ^. #service)
      let owner = unsafe (Resource.mkScopeId Resource.Standalone "service-kizashi-service")
          foundation = unsafe (Resource.mkScopeId Resource.Platform "foundation")
          cluster = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "cluster")) (unsafe (Resource.mkName "resource"))
          namespaceId = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "foundation")) (unsafe (Resource.mkName "namespace-personal"))
          publication = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "image")) (unsafe (Resource.mkName "publication"))
          independent = service & #databases .~ []
          rollout = testEnv & #appName .~ serviceNameText (service ^. #name)
          source = Resource.SourceLocation "test" "standalone-service"
      (scope, native) <- either (fail . show) pure
        (compileStandaloneService owner independent rollout cluster namespaceId publication Map.empty Map.empty Map.empty source)
      let acceptedBinding = Resource.ContextBinding
            (unsafe (Resource.mkContextId "standalone-fixture")) (unsafe (Resource.mkName "project"))
      acceptedScope <- either (fail . show) pure (mkScopeSnapshot acceptedBinding
        (Map.singleton owner (unsafe (Resource.mkScopeGeneration 1), scope)) Map.empty)
      applicationRetirementScope (serviceNameText (service ^. #name)) "personal" Nothing acceptedScope
        @?= Right owner
      applicationRetirementScope (serviceNameText (service ^. #name)) "personal"
        (Just "kizashi-service") acceptedScope @?= Right owner
      let members = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]
      case members of
        [member] -> do
          member ^. #owner @?= owner
          Map.keys native @?= [member ^. #identity]
        other -> assertFailure ("unexpected standalone service members: " <> show other)
      case app ^. #tasks of
        [task] -> do
          let ownTask = task & #app .~ Just (service ^. #name)
              withTask = independent & #tasks .~ [ownTask]
          (taskScope, taskNative) <- either (fail . show) pure
            (compileStandaloneService owner withTask rollout cluster namespaceId
              publication Map.empty Map.empty Map.empty source)
          Map.size taskNative @?= 2
          assertBool "standalone scope includes its scheduled CronJob"
            (any (nativeWorkloadOwned "batch" "cronjob"
              "nagare-task-kizashi-migrate" "personal" . pure)
              [member | bundle <- scopeBundles taskScope, Managed member <- declarations bundle])
          case compileStandaloneService owner (independent & #tasks .~ [task])
              rollout cluster namespaceId publication Map.empty Map.empty Map.empty source of
            Left _ -> pure ()
            Right _ -> assertFailure "standalone task referenced a different application"
        _ -> assertFailure "fixture did not contain one scheduled task"
      case app ^. #databases of
        database : _ ->
          case compileStandaloneService owner (independent & #databases .~ [database ^. #name])
              rollout cluster namespaceId publication Map.empty Map.empty Map.empty source of
            Left _ -> pure ()
            Right _ -> assertFailure "standalone Service accepted an unbound database"
        [] -> assertFailure "fixture has no database for the dependency refusal check"
      case compileStandaloneService foundation independent rollout cluster namespaceId publication Map.empty Map.empty Map.empty source of
        Left _ -> pure ()
        Right _ -> assertFailure "standalone Service accepted a platform owner"
  , testCase "worker deployments and retained PVCs join the application scope" $ do
      loaded <- loadApplication fixturePath
      app <- either (fail . show) pure loaded
      let foundation = unsafe (Resource.mkScopeId Resource.Platform "foundation")
          cluster = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "cluster")) (unsafe (Resource.mkName "resource"))
          namespaceId = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "foundation")) (unsafe (Resource.mkName "namespace-personal"))
          publication = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "image")) (unsafe (Resource.mkName "publication"))
          source = Resource.SourceLocation "test" "workers"
      (bundles, native) <- either (fail . show) pure
        (compileApplicationWorkers app testEnv cluster namespaceId publication Map.empty Map.empty source)
      length bundles @?= 3
      Map.size native @?= 3
      assertBool "direct worker deploy must detect an owned Deployment"
        (nativeWorkloadOwned "apps" "deployment" "kizashi-worker" "personal"
          [member | bundle <- bundles, Managed member <- declarations bundle])
      owner <- either (fail . show) pure (applicationScopeId app)
      database <- case app ^. #databases of
        firstDatabase : _ -> pure firstDatabase
        [] -> assertFailure "fixture has no database" >> fail "missing database"
      databaseId <- either (fail . T.unpack) pure
        (databaseResourceId owner (unsafe (Resource.mkName "statefulset")) database)
      assertBool "workers wait for their declared database"
        (all (elem (OrderedAfter databaseId) . (^. #dependencies))
          [member | bundle <- bundles, Managed member <- declarations bundle])
      worker <- case app ^. #workers of
        firstWorker : _ -> pure firstWorker
        [] -> assertFailure "fixture has no worker" >> fail "missing worker"
      let volume = Volume
            { name = unsafe (mkVolumeName "scratch")
            , logicalKey = Nothing
            , size = unsafe (mkQuantity "1Gi")
            , mountPath = unsafe (mkMountPath "/scratch")
            , accessMode = ReadWriteOnce
            , readOnly = False
            , retention = Retain
            }
          withVolume = app & #workers .~ [worker & #volumes .~ [volume]]
          role = unsafe (Resource.mkName ("worker-" <> serviceNameText (worker ^. #name) <> "-pvc"))
          volumeId = unsafe (volumeResourceId owner role volume)
          recovery = RecoveryIntent (unsafe (Resource.mkName "backup"))
            (mkSecretRef (unsafe (Resource.mkName "volume-key"))
              (unsafe (Resource.mkName "v1")) :| [])
      (_, workerRecovery) <- either (fail . T.unpack) pure
        (applicationVolumeRecoveryBindings withVolume []
          [serviceNameText (worker ^. #name) <> "/scratch=backup:volume-key:v1"])
      Map.lookup volumeId workerRecovery @?= Just recovery
      assertBool "retained worker volume without recovery was accepted"
        (isLeft (applicationVolumeRecoveryBindings withVolume [] []))
      case compileApplicationWorkers withVolume testEnv cluster namespaceId publication Map.empty Map.empty source of
        Left _ -> pure ()
        Right _ -> assertFailure "retained worker volume without recovery was accepted"
      (volumeBundles, volumeNative) <- either (fail . show) pure
        (compileApplicationWorkers withVolume testEnv cluster namespaceId publication
          (Map.singleton volumeId recovery) Map.empty source)
      length volumeBundles @?= 1
      Map.size volumeNative @?= 2
      assertBool "worker volume has an owner declaration"
        (any ((== volumeId) . (^. #identity))
          [member | bundle <- volumeBundles, Managed member <- declarations bundle])
      let standaloneOwner = unsafe (Resource.mkScopeId Resource.Standalone "worker-kizashi-worker")
          independentWorker = worker & #databases .~ [] & #volumes .~ [volume]
          standaloneRollout = testEnv & #appName .~ serviceNameText (worker ^. #name)
            & #appEnv .~ Map.empty
      standaloneRecovery <- either (fail . T.unpack) pure
        (standaloneWorkerVolumeRecoveryBindings standaloneOwner independentWorker
          ["scratch=backup:volume-key:v1"])
      (standaloneScope, standaloneNative) <- either (fail . show) pure
        (compileStandaloneWorker standaloneOwner independentWorker standaloneRollout cluster
          namespaceId publication standaloneRecovery Map.empty Map.empty source)
      scopeId standaloneScope @?= standaloneOwner
      Map.size standaloneNative @?= 2
      let binding = Resource.ContextBinding
            (unsafe (Resource.mkContextId "standalone-worker-fixture"))
            (unsafe (Resource.mkName "project"))
      acceptedWorker <- either (fail . show) pure (mkScopeSnapshot binding
        (Map.singleton standaloneOwner (unsafe (Resource.mkScopeGeneration 1), standaloneScope)) Map.empty)
      workerRetirementScope (serviceNameText (worker ^. #name)) "personal" Nothing acceptedWorker
        @?= Right standaloneOwner
      workerRetirementScope (serviceNameText (worker ^. #name)) "personal"
        (Just "kizashi-worker") acceptedWorker @?= Right standaloneOwner
      assertBool "worker retirement selected a different namespace"
        (isLeft (workerRetirementScope (serviceNameText (worker ^. #name)) "other" Nothing acceptedWorker))
      assertBool "worker retirement selected a different scope key"
        (isLeft (workerRetirementScope (serviceNameText (worker ^. #name)) "personal"
          (Just "other") acceptedWorker))
      assertBool "standalone worker retained volume lacked recovery validation"
        (isLeft (standaloneWorkerVolumeRecoveryBindings standaloneOwner independentWorker []))
  , testCase "application scheduled task binds its reviewed CronJob bytes" $ do
      loaded <- loadApplication fixturePath
      app <- either (fail . show) pure loaded
      let foundation = unsafe (Resource.mkScopeId Resource.Platform "foundation")
          cluster = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "cluster")) (unsafe (Resource.mkName "resource"))
          namespaceId = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "foundation")) (unsafe (Resource.mkName "namespace-personal"))
          publication = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "image")) (unsafe (Resource.mkName "publication"))
          source = Resource.SourceLocation "test" "tasks"
      (bundle, native) <- either (fail . show) pure
        (compileApplicationTasks app testEnv cluster namespaceId publication Map.empty source)
      owner <- either (fail . show) pure (applicationScopeId app)
      case declarations bundle of
        [Managed task] -> do
          task ^. #owner @?= owner
          assertBool "direct task run/delete must detect an owned CronJob"
            (nativeWorkloadOwned "batch" "cronjob" "nagare-task-kizashi-migrate" "personal" [task])
          task ^. #dependencies @?= [OrderedAfter namespaceId, OrderedAfter publication]
          case task ^. #address of
            Resource.Kubernetes _ "batch" kind _ name -> do
              kind @?= unsafe (Resource.mkName "cronjob")
              name @?= unsafe (Resource.mkName "nagare-task-kizashi-migrate")
            other -> assertFailure ("unexpected task address: " <> show other)
          Map.keys native @?= [task ^. #identity]
        other -> assertFailure ("unexpected task declarations: " <> show other)
      case (app ^. #service, app ^. #tasks) of
        (Just service, [task]) -> do
          let serviceLocal = app & #tasks .~ []
                & #service .~ Just (service & #tasks .~ [task])
          (localBundle, localNative) <- either (fail . show) pure
            (compileApplicationTasks serviceLocal testEnv cluster namespaceId publication Map.empty source)
          declarations localBundle @?= declarations bundle
          Map.keys localNative @?= Map.keys native
        _ -> assertFailure "fixture lacks a Service and one scheduled task"
  , testCase "composed application scope contains every supported member" $ do
      loaded <- loadApplication fixturePath
      app <- either (fail . show) pure loaded
      let foundation = unsafe (Resource.mkScopeId Resource.Platform "foundation")
          cluster = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "cluster")) (unsafe (Resource.mkName "resource"))
          namespaceId = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "foundation")) (unsafe (Resource.mkName "namespace-personal"))
          publication = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "image")) (unsafe (Resource.mkName "publication"))
          recovery = RecoveryIntent (unsafe (Resource.mkName "backup"))
            (mkSecretRef (unsafe (Resource.mkName "database-key"))
              (unsafe (Resource.mkName "v1")) :| [])
          input = ApplicationScopeInput
            { scopeApplication = app
            , scopeRollout = testEnv & #appEnv .~ app ^. #env
            , scopeCluster = cluster
            , scopeNamespace = namespaceId
            , scopeNamespaceContributionOwner = Nothing
            , scopeImage = publication
            , scopeBrokerServices = Map.empty
            , scopeDatabaseRecovery = Map.fromList
                [(database ^. #name, recovery) | database <- app ^. #databases]
            , scopeServiceVolumeRecovery = Map.empty
            , scopeTlsSecrets = Map.empty
            , scopeEnvSecrets = Map.empty
            , scopeWorkerVolumeRecovery = Map.empty
            , scopeBackupBackend = GcsBackend "project" "bucket"
            , scopeSource = Resource.SourceLocation "test" "application"
            }
      (scope, native) <- either (fail . show) pure (compileApplicationScope input)
      let secretIds =
            [member ^. #identity
            | bundle <- scopeBundles scope, Managed member <- declarations bundle
            , case member ^. #address of
                Resource.Kubernetes _ "" kind _ _ -> kind == unsafe (Resource.mkName "secret")
                _ -> False]
          historyBinding = Resource.ContextBinding
            (unsafe (Resource.mkContextId "secret-fixture")) (unsafe (Resource.mkName "project"))
      secretSnapshot <- either (fail . show) pure
        (mkScopeSnapshot historyBinding (Map.singleton (scopeId scope)
          (unsafe (Resource.mkScopeGeneration 1), scope)) Map.empty)
      applicationRetirementScope "kizashi-serve" "personal" (Just "kizashi") secretSnapshot
        @?= Right (scopeId scope)
      applicationRetirementScope "kizashi-serve" "personal" Nothing secretSnapshot
        @?= Right (scopeId scope)
      assertBool "retirement accepted another namespace"
        (isLeft (applicationRetirementScope "kizashi-serve" "other" (Just "kizashi") secretSnapshot))
      assertBool "retirement accepted another Service"
        (isLeft (applicationRetirementScope "other" "personal" (Just "kizashi") secretSnapshot))
      assertBool "retirement selected an absent pinned key"
        (isLeft (applicationRetirementScope "kizashi-serve" "personal" (Just "other") secretSnapshot))
      Map.size <$> acceptedSecretBindings secretSnapshot secretIds @?= Right 1
      assertBool "duplicate accepted Secret binding was accepted"
        (isLeft (acceptedSecretBindings secretSnapshot (secretIds <> secretIds)))
      assertBool "non-Secret image identity was accepted as a Secret"
        (isLeft (acceptedSecretBindings secretSnapshot [publication]))
      bindings <- either (fail . T.unpack) pure
        (databaseRecoveryBindings app ["kizashi-db=backup:v1"])
      Map.keys bindings @?= map (^. #name) (app ^. #databases)
      assertBool "missing database recovery was accepted"
        (isLeft (databaseRecoveryBindings app []))
      assertBool "duplicate database recovery was accepted"
        (isLeft (databaseRecoveryBindings app
          ["kizashi-db=backup:v1", "kizashi-db=backup:v1"]))
      assertBool "unknown database recovery was accepted"
        (isLeft (databaseRecoveryBindings app ["other=backup:v1"]))
      length (scopeBundles scope) @?= 6
      Map.size native @?= 10
      length [() | bundle <- scopeBundles scope, Managed _ <- declarations bundle] @?= 10
      let workloadBytes =
            [bytes | (member, bytes) <- Map.elems native
            , case member ^. #address of
                Resource.Kubernetes _ "apps" kind _ _ ->
                  kind == unsafe (Resource.mkName "deployment")
                _ -> False]
      length workloadBytes @?= 3
      assertBool "reviewed workloads omit generated database connection fields"
        (all (BS.isInfixOf "POSTGRES_HOST") workloadBytes)
      assertBool "reviewed workloads omit credential Secret references"
        (all (BS.isInfixOf "POSTGRES_PASSWORD") workloadBytes
          && all (BS.isInfixOf "secretKeyRef") workloadBytes)
      loadedBroker <- loadBroker "../nagare-dsl/test/fixtures/broker/redpanda/nagare/Config.hs"
      broker <- either (fail . show) pure loadedBroker
      let brokerOwner = unsafe (Resource.mkScopeId Resource.Standalone "broker-events")
          brokerRecovery = RecoveryIntent (unsafe (Resource.mkName "backup"))
            (mkSecretRef (unsafe (Resource.mkName "broker-key"))
              (unsafe (Resource.mkName "v1")) :| [])
          brokerBinding = BrokerBinding (broker ^. #name) []
          brokerApp = app & #brokers .~ [brokerBinding]
      (brokerScope, _) <- either (fail . show) pure (compileStandaloneBroker
        (broker & #topics .~ []) brokerOwner cluster namespaceId brokerRecovery
        (Resource.SourceLocation "test" "broker"))
      brokerSnapshot <- either (fail . show) pure (mkScopeSnapshot historyBinding
        (Map.singleton brokerOwner (unsafe (Resource.mkScopeGeneration 1), brokerScope)) Map.empty)
      (brokerServices, brokerEnv) <- either (fail . T.unpack) pure
        (acceptedBrokerBindings brokerSnapshot cluster "personal" [brokerBinding])
      worker <- case app ^. #workers of
        firstWorker : _ -> pure firstWorker
        [] -> assertFailure "fixture has no worker" >> fail "missing worker"
      let standaloneOwner = unsafe (Resource.mkScopeId Resource.Standalone "worker-kizashi-worker")
          standaloneWorker = worker & #databases .~ [] & #brokers .~ [brokerBinding]
          workerRollout = testEnv & #appName .~ serviceNameText (worker ^. #name)
            & #appEnv .~ Map.empty
      (standaloneBrokerScope, standaloneBrokerNative) <- either (fail . show) pure
        (compileStandaloneWorker standaloneOwner standaloneWorker workerRollout cluster
          namespaceId publication Map.empty Map.empty brokerServices (scopeSource input))
      let standaloneMembers =
            [member | bundle <- scopeBundles standaloneBrokerScope
            , Managed member <- declarations bundle]
      assertBool "standalone worker lost accepted broker dependency"
        (all (\member -> all (\resource -> OrderedAfter resource `elem` member ^. #dependencies)
          (map declarationId (Map.elems brokerServices))) standaloneMembers)
      assertBool "standalone worker native bytes omit broker connection"
        (any (BS.isInfixOf "KAFKA_BOOTSTRAP_SERVERS" . snd) (Map.elems standaloneBrokerNative))
      assertBool "standalone worker private native declaration lost broker dependency"
        (all (\member -> maybe False ((== member) . fst)
          (Map.lookup (member ^. #identity) standaloneBrokerNative)) standaloneMembers)
      assertBool "standalone worker accepted an unbound broker"
        (isLeft (compileStandaloneWorker standaloneOwner standaloneWorker workerRollout cluster
          namespaceId publication Map.empty Map.empty Map.empty (scopeSource input)))
      webService <- maybe (assertFailure "fixture has no service" >> fail "missing service") pure
        (app ^. #service)
      let serviceOwner = unsafe (Resource.mkScopeId Resource.Standalone "service-kizashi-service")
          independentService = webService & #databases .~ [] & #brokers .~ [brokerBinding]
          serviceRollout = testEnv & #appName .~ serviceNameText (webService ^. #name)
            & #appEnv .~ Map.empty
      (standaloneServiceScope, standaloneServiceNative) <- either (fail . show) pure
        (compileStandaloneServiceWithBrokers serviceOwner independentService serviceRollout
          cluster namespaceId publication Map.empty Map.empty Map.empty brokerServices (scopeSource input))
      let serviceMembers =
            [member | bundle <- scopeBundles standaloneServiceScope
            , Managed member <- declarations bundle
            , case member ^. #address of
                Resource.Kubernetes _ "serving.knative.dev" kind _ _ ->
                  kind == unsafe (Resource.mkName "service")
                _ -> False]
      length serviceMembers @?= 1
      assertBool "standalone Service lost accepted broker dependency"
        (all (\member -> all (\resource -> OrderedAfter resource `elem` member ^. #dependencies)
          (map declarationId (Map.elems brokerServices))) serviceMembers)
      assertBool "standalone Service native bytes omit broker connection"
        (any (BS.isInfixOf "KAFKA_BOOTSTRAP_SERVERS" . snd) (Map.elems standaloneServiceNative))
      assertBool "standalone Service private native declaration lost broker dependency"
        (all (\member -> maybe False ((== member) . fst)
          (Map.lookup (member ^. #identity) standaloneServiceNative)) serviceMembers)
      assertBool "standalone Service accepted an unbound broker"
        (isLeft (compileStandaloneServiceWithBrokers serviceOwner independentService serviceRollout
          cluster namespaceId publication Map.empty Map.empty Map.empty Map.empty (scopeSource input)))
      let brokerInput = input
            { scopeApplication = brokerApp
            , scopeRollout = scopeRollout input & #appEnv .~ mergeGenerated brokerEnv (app ^. #env)
            , scopeBrokerServices = brokerServices
            }
      (brokerAppScope, brokerNative) <- either (fail . show) pure
        (compileApplicationScope brokerInput)
      let brokerServiceIds = map declarationId (Map.elems brokerServices)
          brokerWorkloads =
            [member | bundle <- scopeBundles brokerAppScope, Managed member <- declarations bundle
            , case member ^. #address of
                Resource.Kubernetes _ "apps" kind _ _ -> kind == unsafe (Resource.mkName "deployment")
                Resource.Kubernetes _ "serving.knative.dev" kind _ _ -> kind == unsafe (Resource.mkName "service")
                _ -> False]
      assertBool "reviewed workloads omit the accepted broker dependency"
        (all (\member -> all (\resource -> OrderedAfter resource `elem` member ^. #dependencies)
          brokerServiceIds) brokerWorkloads)
      assertBool "reviewed workload bytes omit the broker connection"
        (any (BS.isInfixOf "KAFKA_BOOTSTRAP_SERVERS" . snd) (Map.elems brokerNative))
      assertBool "private native members lost their reviewed broker dependency"
        (all (\member -> maybe False ((== member) . fst)
          (Map.lookup (member ^. #identity) brokerNative)) brokerWorkloads)
      let localApp = app
            & #service %~ fmap (#brokers .~ [brokerBinding])
            & #workers %~ (\case
                [] -> []
                firstWorker : rest -> (firstWorker & #brokers .~ [brokerBinding]) : rest)
          localInput = input
            { scopeApplication = localApp
            , scopeBrokerServices = brokerServices
            }
      (_, localNative) <- either (fail . show) pure (compileApplicationScope localInput)
      brokerId <- case brokerServiceIds of
        [resource] -> pure resource
        _ -> assertFailure "expected one accepted broker Service"
      let localWorkloads =
            [(member, bytes) | (member, bytes) <- Map.elems localNative
            , case member ^. #address of
                Resource.Kubernetes _ "apps" kind _ _ -> kind == unsafe (Resource.mkName "deployment")
                Resource.Kubernetes _ "serving.knative.dev" kind _ _ -> kind == unsafe (Resource.mkName "service")
                _ -> False]
          consumers = [(member, bytes) | (member, bytes) <- localWorkloads
            , OrderedAfter brokerId `elem` member ^. #dependencies]
      length consumers @?= 2
      assertBool "local broker connection missing from its workload bytes"
        (all (BS.isInfixOf "KAFKA_BOOTSTRAP_SERVERS" . snd) consumers)
      assertBool "unbound workers acquired the broker connection"
        (all (not . BS.isInfixOf "KAFKA_BOOTSTRAP_SERVERS" . snd)
          [(member, bytes) | (member, bytes) <- localWorkloads
          , OrderedAfter brokerId `notElem` member ^. #dependencies])
      assertBool "unaccepted broker reference was accepted"
        (isLeft (acceptedBrokerBindings secretSnapshot cluster "personal" [brokerBinding]))
      assertBool "unreviewed broker topic was accepted"
        (isLeft (acceptedBrokerBindings brokerSnapshot cluster "personal"
          [brokerBinding & #topics .~ [unsafe (mkTopicName "orders")]]))
      assertBool "duplicate broker reference was accepted"
        (isLeft (acceptedBrokerBindings brokerSnapshot cluster "personal"
          [brokerBinding, brokerBinding]))
      case compileApplicationScope (input {scopeNamespaceContributionOwner = Just foundation}) of
        Left _ -> pure ()
        Right _ -> assertFailure "namespace contribution used an unrelated namespace identity"
      let sandbox = unsafe (mkNamespace "sandbox")
          sandboxId = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "sandbox")) (unsafe (Resource.mkName "namespace"))
          sandboxApp = app
            & #namespace .~ sandbox
            & #databases .~ []
            & #workers .~ []
            & #tasks .~ []
            & #service %~ fmap (\service -> service
                & #namespace .~ sandbox
                & #databases .~ [])
          sandboxInput = input
            { scopeApplication = sandboxApp
            , scopeRollout = scopeRollout input & #namespace .~ "sandbox"
            , scopeNamespace = sandboxId
            , scopeNamespaceContributionOwner = Just foundation
            }
      (sandboxScope, _) <- either (fail . show) pure (compileApplicationScope sandboxInput)
      case [request | bundle <- scopeBundles sandboxScope, request <- contributions bundle] of
        [request@RegisterNamespace {}] -> contributionResourceId request @?= sandboxId
        other -> assertFailure ("expected one typed namespace contribution: " <> show other)
      let externalSource = Resource.SourceLocation "test" "foundation"
          imageDigest = unsafe (Resource.mkContentDigest (T.replicate 64 "0"))
          foundationBundle = ResourceBundle
            [ External cluster (Resource.CloudInstance
                (unsafe (Resource.mkName "project"))
                (unsafe (Resource.mkName "zone"))
                (unsafe (Resource.mkName "cluster"))) [] externalSource
            , External publication (Resource.Artifact
                (unsafe (Resource.mkName "image")) imageDigest) [] externalSource
            ] [] [] [] [] [NamespaceGrant (scopeId sandboxScope) cluster]
          binding = Resource.ContextBinding
            (unsafe (Resource.mkContextId "fixture")) (unsafe (Resource.mkName "project"))
      foundationScope <- either (fail . show) pure
        (mkScopeDeclaration foundation [foundationBundle])
      accepted <- either (fail . show) pure
        (mkScopeSnapshot binding (Map.singleton foundation
          (unsafe (Resource.mkScopeGeneration 1), foundationScope)) Map.empty)
      candidate <- either (fail . show) pure
        (composeInventory accepted (ReplaceScope sandboxScope :| []))
      Map.lookup foundation (inventoryScopes (candidateInventory candidate)) @?= Just foundationScope
      Map.lookup foundation (candidateGenerations candidate) @?= Just (unsafe (Resource.mkScopeGeneration 1))
      case [member | Managed member <- inventoryDeclarations (candidateInventory candidate)
            , member ^. #identity == sandboxId] of
        [member] -> member ^. #owner @?= foundation
        other -> assertFailure ("expected one owner-composed namespace: " <> show other)
      let ungranted = foundationBundle {grants = []}
      ungrantedScope <- either (fail . show) pure
        (mkScopeDeclaration foundation [ungranted])
      ungrantedSnapshot <- either (fail . show) pure
        (mkScopeSnapshot binding (Map.singleton foundation
          (unsafe (Resource.mkScopeGeneration 1), ungrantedScope)) Map.empty)
      case composeInventory ungrantedSnapshot (ReplaceScope sandboxScope :| []) of
        Left _ -> pure ()
        Right _ -> assertFailure "ungranted application namespace contribution was accepted"
      let namedApplication name = app
            & #name .~ unsafe (mkServiceName name)
            & #databases .~ []
            & #workers .~ []
            & #tasks .~ []
            & #service %~ fmap (\service -> service
                & #name .~ unsafe (mkServiceName name)
                & #databases .~ []
                & #domains .~ [])
          namedInput name = input
            { scopeApplication = namedApplication name
            , scopeRollout = scopeRollout input & #appName .~ name
            , scopeDatabaseRecovery = Map.empty
            }
          foundationWithNamespace = foundationBundle
            { declarations = declarations foundationBundle
                <> [External namespaceId (Resource.Kubernetes cluster ""
                    (unsafe (Resource.mkName "namespace")) Nothing
                    (unsafe (Resource.mkName "personal"))) [] externalSource]
            , grants = []
            }
      platformScope <- either (fail . show) pure
        (mkScopeDeclaration foundation [foundationWithNamespace])
      (alphaScope, _) <- either (fail . show) pure
        (compileApplicationScope (namedInput "alpha"))
      (betaScope, _) <- either (fail . show) pure
        (compileApplicationScope (namedInput "beta"))
      isolationSnapshot <- either (fail . show) pure
        (mkScopeSnapshot binding (Map.fromList
          [ (foundation, (unsafe (Resource.mkScopeGeneration 1), platformScope))
          , (scopeId betaScope, (unsafe (Resource.mkScopeGeneration 1), betaScope))
          ]) Map.empty)
      isolated <- either (fail . show) pure
        (composeInventory isolationSnapshot (ReplaceScope alphaScope :| []))
      Map.lookup foundation (inventoryScopes (candidateInventory isolated)) @?= Just platformScope
      Map.lookup (scopeId betaScope) (inventoryScopes (candidateInventory isolated)) @?= Just betaScope
      Map.lookup foundation (candidateGenerations isolated) @?= Just (unsafe (Resource.mkScopeGeneration 1))
      Map.lookup (scopeId betaScope) (candidateGenerations isolated) @?= Just (unsafe (Resource.mkScopeGeneration 1))
      let conflicting = (namedApplication "alpha")
            & #service %~ fmap (#name .~ unsafe (mkServiceName "beta"))
      (conflictingScope, _) <- either (fail . show) pure
        (compileApplicationScope ((namedInput "alpha") {scopeApplication = conflicting}))
      case composeInventory isolationSnapshot (ReplaceScope conflictingScope :| []) of
        Left _ -> pure ()
        Right _ -> assertFailure "two application scopes claimed the same Knative Service"
      case app ^. #databases of
        [database] -> do
          let nativeDatabase = unsafe (Resource.mkName (databaseNameText (database ^. #name)))
              externalId = Resource.mintResourceId foundation
                (unsafe (Resource.mkLogicalKey "platform-database"))
                (unsafe (Resource.mkName "statefulset"))
              withPlatformDatabase = foundationWithNamespace
                { declarations = declarations foundationWithNamespace
                    <> [External externalId (Resource.Kubernetes cluster "apps"
                      (unsafe (Resource.mkName "statefulset"))
                      (Just (unsafe (Resource.mkName "personal"))) nativeDatabase)
                      [] externalSource]
                }
          databasePlatform <- either (fail . show) pure
            (mkScopeDeclaration foundation [withPlatformDatabase])
          databaseSnapshot <- either (fail . show) pure
            (mkScopeSnapshot binding (Map.singleton foundation
              (unsafe (Resource.mkScopeGeneration 1), databasePlatform)) Map.empty)
          case composeInventory databaseSnapshot (ReplaceScope scope :| []) of
            Left _ -> pure ()
            Right _ -> assertFailure "application scope claimed the platform database StatefulSet"
        _ -> assertFailure "multi-workload fixture has no unique database"
      case compileApplicationScope (input {scopeRollout = testEnv & #namespace .~ "other"}) of
        Left _ -> pure ()
        Right _ -> assertFailure "mismatched rollout namespace was accepted"
      case compileApplicationScope (input {scopeRollout = testEnv}) of
        Left _ -> pure ()
        Right _ -> assertFailure "undeclared rollout environment was accepted"
      let secretApp = app & #env .~ Map.singleton
            (unsafe (mkEnvName "PRIVATE_TOKEN"))
            (runtimeScoped (EnvSecretRef (unsafe (mkSecretName "external-token"))))
      case compileApplicationScope (input
          { scopeApplication = secretApp
          , scopeRollout = scopeRollout input & #appEnv .~ secretApp ^. #env
          }) of
        Left _ -> pure ()
        Right _ -> assertFailure "unowned environment Secret was accepted"
      let secretName = unsafe (mkSecretName "external-token")
          secretId = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "external-token")) (unsafe (Resource.mkName "secret"))
          secretAddress = Resource.Kubernetes cluster "" (unsafe (Resource.mkName "secret"))
            (Just (unsafe (Resource.mkName "personal"))) (unsafe (Resource.mkName "external-token"))
          secretBinding = External secretId secretAddress [] (scopeSource input)
          secretInput = input
            { scopeApplication = secretApp
            , scopeRollout = scopeRollout input & #appEnv .~ secretApp ^. #env
            , scopeEnvSecrets = Map.singleton secretName secretBinding
            }
      (secretScope, _) <- either (fail . show) pure (compileApplicationScope secretInput)
      length [() | bundle <- scopeBundles secretScope, Managed member <- declarations bundle,
        OrderedAfter secretId `elem` member ^. #dependencies] @?= 5
      let wrongSecret = External secretId
            (Resource.Kubernetes cluster "" (unsafe (Resource.mkName "secret"))
              (Just (unsafe (Resource.mkName "other"))) (unsafe (Resource.mkName "external-token")))
            [] (scopeSource input)
      case compileApplicationScope (secretInput {scopeEnvSecrets = Map.singleton secretName wrongSecret}) of
        Left _ -> pure ()
        Right _ -> assertFailure "runtime Secret in another namespace was accepted"
      case app ^. #databases of
        database : _ -> do
          let credentialName = unsafe (mkSecretName (dbSecretName (databaseNameText (database ^. #name))))
              ownSecretApp = app & #env .~ Map.singleton (unsafe (mkEnvName "DB_PASSWORD"))
                (runtimeScoped (EnvSecretRef credentialName))
              ownSecretInput = input
                { scopeApplication = ownSecretApp
                , scopeRollout = scopeRollout input & #appEnv .~ ownSecretApp ^. #env
                }
          (ownScope, _) <- either (fail . show) pure (compileApplicationScope ownSecretInput)
          let credentials = [member ^. #identity | bundle <- scopeBundles ownScope,
                Managed member <- declarations bundle,
                Resource.Kubernetes _ "" kind _ name <- [member ^. #address],
                Resource.nameText kind == "secret", Resource.nameText name == dbSecretName (databaseNameText (database ^. #name))]
              workloads = [member | bundle <- scopeBundles ownScope, Managed member <- declarations bundle,
                Resource.Kubernetes _ group kind _ name <- [member ^. #address],
                (group == "serving.knative.dev" && Resource.nameText kind == "service")
                  || (group == "apps" && Resource.nameText kind == "deployment")
                  || (group == "batch" && Resource.nameText kind == "cronjob"
                    && not ("nagare-dbbackup-" `T.isPrefixOf` Resource.nameText name))]
          case credentials of
            [credentialId] -> do
              length workloads @?= 5
              assertBool "application workloads lack their own credential dependency"
                (all (elem (OrderedAfter credentialId) . (^. #dependencies)) workloads)
            _ -> assertFailure "application database has no unique credential Secret"
        _ -> assertFailure "fixture needs an application database"
      let buildSecret = secretApp & #env .~ Map.singleton (unsafe (mkEnvName "PRIVATE_TOKEN"))
            (unsafe (scopedEnv (Set.singleton Build) (EnvSecretRef secretName)))
      case compileApplicationScope (secretInput
          { scopeApplication = buildSecret
          , scopeRollout = scopeRollout input & #appEnv .~ buildSecret ^. #env
          }) of
        Left _ -> pure ()
        Right _ -> assertFailure "build-scoped Secret entered the runtime dependency channel"
      case app ^. #workers of
        firstWorker : secondWorker : rest -> do
          let key = unsafe (Resource.mkLogicalKey "shared-worker")
              colliding = app & #workers .~
                ((firstWorker & #logicalKey .~ Just key)
                  : (secondWorker & #logicalKey .~ Just key) : rest)
          case compileApplicationScope (input {scopeApplication = colliding}) of
            Left _ -> pure ()
            Right _ -> assertFailure "duplicate worker logical key was accepted"
        _ -> assertFailure "fixture needs two workers"
  , testCase "the rollout begins with the public-certificate namespace opt-in" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          objects <- unwrapRender (renderAppObjects testEnv app)
          case objects of
            (("namespace", manifest) : _) -> do
              assertBool "is a Namespace" (BS.isInfixOf "\"kind\":\"Namespace\"" manifest)
              assertBool "opts into wildcard TLS" (BS.isInfixOf "\"nagare.dev/app-namespace\":\"true\"" manifest)
            _ -> assertFailure "namespace action was not first"
  , testCase "every rendered workload object carries the shared nagare.dev/app label" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          objects <- unwrapRender (renderAppObjects testEnv app)
          forM_ (filter ((/= "namespace") . fst) objects) $ \(ph, bs) ->
            assertBool
              ("object in phase '" <> T.unpack ph <> "' is missing nagare.dev/app: kizashi")
              (BS.isInfixOf "nagare.dev/app: kizashi" bs)
  , testCase "the rendered service is the kizashi-serve Knative Service" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          objects <- unwrapRender (renderAppObjects testEnv app)
          let svcBytes = [bs | (ph, bs) <- objects, ph == "service"]
          assertBool "one service object" (length svcBytes == 1)
          forM_ svcBytes $ \bs -> do
            assertBool "is a Knative Service" (BS.isInfixOf "kind: Service" bs)
            assertBool "named kizashi-serve" (BS.isInfixOf "name: kizashi-serve" bs)
  ]

phaseTests :: [TestTree]
phaseTests =
  [ testCase "planPhases is hooks, databases, service, workers" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app ->
          map phaseTag (planPhases app) @?= ["hook", "database", "service", "worker"]
  , testCase "a failed hook aborts before any later phase runs" $ do
      ran <- newIORef ([] :: [Text])
      let phases =
            [ PhaseHooks []
            , PhaseDatabases []
            , PhaseWorkers []
            ]
          exec p = do
            modifyIORef' ran (<> [phaseTag p])
            pure $ case p of
              PhaseHooks _ -> PhaseFailed "migration failed"
              _ -> PhaseOk
      result <- runPhases exec phases
      order <- readIORef ran
      result @?= PhaseFailed "migration failed"
      -- only the hook phase ran; databases/workers were never invoked.
      order @?= ["hook"]
  , testCase "all phases run in order when each succeeds" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          ran <- newIORef ([] :: [Text])
          let exec p = modifyIORef' ran (<> [phaseTag p]) >> pure PhaseOk
          r <- runPhases exec (planPhases app)
          order <- readIORef ran
          r @?= PhaseOk
          order @?= ["hook", "database", "service", "worker"]
  ]

planTests :: [TestTree]
planTests =
  [ testCase "renderPlan lists every object in rollout order with the app identity" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          plan <- unwrapRender (renderPlan testEnv app)
          plan ^. #app @?= "kizashi"
          plan ^. #image @?= "gcr.io/knative-samples/helloworld-go:20260619-120000"
          map (^. #phase) (plan ^. #objects)
            @?= ["namespace", "hook", "database", "database", "database", "database", "database", "service", "worker", "worker", "worker"]
          let databaseKinds = [o ^. #kind | o <- plan ^. #objects, o ^. #phase == "database"]
          assertBool "credential template omitted" ("Secret" `elem` databaseKinds)
          assertBool "backup CronJob omitted" ("CronJob" `elem` databaseKinds)
          let credentialManifests = [o ^. #manifest | o <- plan ^. #objects, o ^. #kind == "Secret"]
          case credentialManifests of
            [manifest] -> case Yaml.decodeEither' (TE.encodeUtf8 manifest) of
              Right (Aeson.Object secret) -> KeyMap.lookup "data" secret @?= Nothing
              other -> assertFailure ("credential template did not decode: " <> show other)
            _ -> assertFailure "expected one database credential template"
  , testCase "every plan object's labels carry nagare.dev/app = the app" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          plan <- unwrapRender (renderPlan testEnv app)
          forM_ (filter ((/= "namespace") . (^. #phase)) (plan ^. #objects)) $ \o ->
            Map.lookup "nagare.dev/app" (o ^. #labels) @?= Just "kizashi"
  , testCase "the plan encodes to a single parseable JSON document" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          plan <- unwrapRender (renderPlan testEnv app)
          let bytes = LBS.toStrict (Aeson.encode plan)
          case Aeson.eitherDecodeStrict bytes :: Either String Aeson.Value of
            Left e -> assertFailure ("plan JSON did not parse: " <> e)
            Right _ -> pure ()
          assertBool "JSON names the app" (BS.isInfixOf "\"app\":\"kizashi\"" bytes)
  ]

remediationTests :: [TestTree]
remediationTests =
  [ testCase "waitResult converts readiness failures to PhaseFailed" $ do
      waitResult "service 'kizashi-serve'" ExitSuccess @?= PhaseOk
      case waitResult "service 'kizashi-serve'" (ExitFailure 1) of
        PhaseFailed message ->
          assertBool "failure names the readiness problem" ("did not become Ready" `T.isInfixOf` message)
        PhaseOk -> assertFailure "non-zero readiness wait unexpectedly succeeded"
  , testCase "stampAppLabel fails loudly when the managed-by anchor is absent" $ do
      let unstamped = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n"
          result = stampAppLabel "kizashi" unstamped
      assertBool "anchor-less manifest is rejected" (isLeft result)
      case result of
        Left message ->
          assertBool "error identifies the missing anchor" ("nagare.dev/managed-by" `T.isInfixOf` message)
        Right _ -> assertFailure "anchor-less manifest unexpectedly stamped"
  , testCase "stampAppLabel verifies the top-level metadata label structurally" $ do
      let unstamped =
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n  labels:\n    nagare.dev/managed-by: nagarectl\n"
      stamped <- unwrapRender (stampAppLabel "kizashi" unstamped)
      topLevelAppLabel stamped @?= Just "kizashi"
  , testCase "stampAppLabel is byte-identical when already stamped" $ do
      let stamped =
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n  labels:\n    nagare.dev/managed-by: nagarectl\n    nagare.dev/app: kizashi\n"
      stampAppLabel "kizashi" stamped @?= Right stamped
  ]

unwrapRender :: Either Text a -> IO a
unwrapRender (Right value) = pure value
unwrapRender (Left message) = do
  _ <- assertFailure (T.unpack message)
  pure (error "unreachable after assertFailure")

topLevelAppLabel :: BS.ByteString -> Maybe Text
topLevelAppLabel bytes = do
  Aeson.Object top <- either (const Nothing) Just (Yaml.decodeEither' bytes)
  Aeson.Object metadata <- KeyMap.lookup "metadata" top
  Aeson.Object labels <- KeyMap.lookup "labels" metadata
  Aeson.String value <- KeyMap.lookup "nagare.dev/app" labels
  pure value

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> T.unpack e)
