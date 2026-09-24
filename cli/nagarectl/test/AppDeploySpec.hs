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
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.App.Deploy
import Nagare.Inventory.Application (ApplicationScopeInput (..), compileApplicationScope, compileApplicationService, compileStandaloneService, compileApplicationTasks, compileApplicationWorkers)
import Nagare.Resource.Application (applicationScopeId, volumeResourceId)
import Nagare.Resource.Database (databaseResourceId)
import Nagare.Resource.Inventory (ResourceBundle (..), Declaration (..), ManagedResource (..), DesiredSpec (KnativeService), Contribution (RegisterNamespace), ContributionGrant (NamespaceGrant), ScopeChange (ReplaceScope), candidateGenerations, candidateInventory, composeInventory, contributionResourceId, inventoryDeclarations, inventoryScopes, mkScopeDeclaration, mkScopeSnapshot, scopeBundles, scopeId)
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types qualified as Resource
import Nagare.Dsl.Load (loadApplication)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (AccessMode (ReadWriteOnce), DomainTls (SuppliedTlsSecret), EnvVar (EnvSecretRef), RetentionPolicy (Retain), Volume (..), mkDomains, mkEnvName, mkImageRef, mkMountPath, mkNamespace, mkQuantity, mkSecretName, mkServiceName, mkVolumeName, runtimeScoped, serviceNameText)
import Nagare.Dsl.Worker (Worker (..))
import Nagare.Dsl.Presets (attachVolume)
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
        (compileApplicationService app testEnv cluster namespaceId publication Map.empty source)
      owner <- either (fail . show) pure (applicationScopeId app)
      case declarations bundle of
        [Managed service] -> do
          service ^. #owner @?= owner
          case service ^. #spec of
            KnativeService _ -> pure ()
            other -> assertFailure ("service lacks Knative reservation: " <> show other)
          Map.keys native @?= [service ^. #identity]
        other -> assertFailure ("unexpected service declarations: " <> show other)
      let withVolume = app & #service %~ fmap (unsafe . attachVolume "data" "1Gi" "/data")
      case compileApplicationService withVolume testEnv cluster namespaceId publication Map.empty source of
        Left _ -> pure ()
        Right _ -> assertFailure "retained service volume without recovery was accepted"
      let volumeName = unsafe (mkVolumeName "data")
          recovery = RecoveryIntent (unsafe (Resource.mkName "backup"))
            (mkSecretRef (unsafe (Resource.mkName "volume-key"))
              (unsafe (Resource.mkName "v1")) :| [])
      (volumeBundle, volumeNative) <- either (fail . show) pure
        (compileApplicationService withVolume testEnv cluster namespaceId publication
          (Map.singleton volumeName recovery) source)
      length (declarations volumeBundle) @?= 2
      Map.size volumeNative @?= 2
      let withDomain = app & #service %~ fmap
            (#domains .~ unsafe (mkDomains [("app.example.com", True)]))
      (domainBundle, domainNative) <- either (fail . show) pure
        (compileApplicationService withDomain testEnv cluster namespaceId publication Map.empty source)
      length (declarations domainBundle) @?= 2
      Map.size domainNative @?= 2
      assertBool "domain hostname claim omitted"
        (any (elem (Resource.Hostname (unsafe (Resource.mkName "app.example.com"))) . (^. #aliases))
          [member | Managed member <- declarations domainBundle])
      let supplied = withDomain & #service %~ fmap
            (#domains . traverse . #tls .~ SuppliedTlsSecret (unsafe (mkSecretName "custom-tls")))
      case compileApplicationService supplied testEnv cluster namespaceId publication Map.empty source of
        Left _ -> pure ()
        Right _ -> assertFailure "supplied TLS domain lacked a typed secret dependency"
  , testCase "standalone Service binds the same rendered object under its own scope" $ do
      loaded <- loadApplication fixturePath
      app <- either (fail . show) pure loaded
      service <- maybe (assertFailure "fixture has no service" >> fail "missing service") pure
        (app ^. #service)
      let owner = unsafe (Resource.mkScopeId Resource.Standalone "kizashi-service")
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
        (compileStandaloneService owner independent rollout cluster namespaceId publication Map.empty source)
      let members = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]
      case members of
        [member] -> do
          member ^. #owner @?= owner
          Map.keys native @?= [member ^. #identity]
        other -> assertFailure ("unexpected standalone service members: " <> show other)
      case app ^. #databases of
        database : _ ->
          case compileStandaloneService owner (independent & #databases .~ [database ^. #name])
              rollout cluster namespaceId publication Map.empty source of
            Left _ -> pure ()
            Right _ -> assertFailure "standalone Service accepted an unbound database"
        [] -> assertFailure "fixture has no database for the dependency refusal check"
      case compileStandaloneService foundation independent rollout cluster namespaceId publication Map.empty source of
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
        (compileApplicationWorkers app testEnv cluster namespaceId publication Map.empty source)
      length bundles @?= 3
      Map.size native @?= 3
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
      case compileApplicationWorkers withVolume testEnv cluster namespaceId publication Map.empty source of
        Left _ -> pure ()
        Right _ -> assertFailure "retained worker volume without recovery was accepted"
      (volumeBundles, volumeNative) <- either (fail . show) pure
        (compileApplicationWorkers withVolume testEnv cluster namespaceId publication
          (Map.singleton volumeId recovery) source)
      length volumeBundles @?= 1
      Map.size volumeNative @?= 2
      assertBool "worker volume has an owner declaration"
        (any ((== volumeId) . (^. #identity))
          [member | bundle <- volumeBundles, Managed member <- declarations bundle])
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
        (compileApplicationTasks app testEnv cluster namespaceId publication source)
      owner <- either (fail . show) pure (applicationScopeId app)
      case declarations bundle of
        [Managed task] -> do
          task ^. #owner @?= owner
          task ^. #dependencies @?= [OrderedAfter namespaceId, OrderedAfter publication]
          case task ^. #address of
            Resource.Kubernetes _ "batch" kind _ name -> do
              kind @?= unsafe (Resource.mkName "cronjob")
              name @?= unsafe (Resource.mkName "nagare-task-kizashi-migrate")
            other -> assertFailure ("unexpected task address: " <> show other)
          Map.keys native @?= [task ^. #identity]
        other -> assertFailure ("unexpected task declarations: " <> show other)
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
            , scopeDatabaseRecovery = Map.fromList
                [(database ^. #name, recovery) | database <- app ^. #databases]
            , scopeServiceVolumeRecovery = Map.empty
            , scopeWorkerVolumeRecovery = Map.empty
            , scopeBackupBackend = GcsBackend "project" "bucket"
            , scopeSource = Resource.SourceLocation "test" "application"
            }
      (scope, native) <- either (fail . show) pure (compileApplicationScope input)
      length (scopeBundles scope) @?= 6
      Map.size native @?= 10
      length [() | bundle <- scopeBundles scope, Managed _ <- declarations bundle] @?= 10
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
