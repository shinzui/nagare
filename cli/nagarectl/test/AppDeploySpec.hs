-- | Tests for @nagarectl app deploy@ orchestration (MasterPlan 14, EP-2).
--
-- M1: rendering an 'Application' fans it out into the right objects, in rollout
-- order, each stamped with the shared @nagare.dev/app@ label. M2: the rollout
-- phase plan is in the fixed order, and a failed pre-deploy hook aborts before any
-- later phase runs. These are offline (the load test spawns @runghc@, exactly as
-- the nagare-dsl loader tests do).
module AppDeploySpec (appDeployTests) where

import Control.Monad (forM_)
import Control.Exception (finally)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Cdn.Provision (GcpStackRefs (..))
import Nagare.App.Deployments (appDeploymentsPrefix)
import Nagare.App.Deploy
import Nagare.Inventory.Application (ApplicationScopeInput (..), GoogleCdnBinding (..), CloudflareCdnBinding (..), ReviewedCdnBinding (..), ServiceAction (..), acceptedAccessBinding, acceptedApplicationReleaseLog, acceptedBrokerBindings, acceptedDatabaseBindings, acceptedSecretBindings, acceptedStandaloneReleaseLog, applicationNativeOwned, applicationRetirementScope, applicationVolumeRecoveryBindings, standaloneWorkerVolumeRecoveryBindings, nativeWorkloadOwned, hostnameClaimOwned, compileApplicationDeployment, compileApplicationScope, compileApplicationService, compileServiceActionScope, compileStandaloneService, compileStandaloneServiceWithBrokers, compileStandaloneServiceWithDependencies, compileStandaloneServiceWithRelease, compileStandaloneWorker, compileStandaloneWorkerWithDependencies, compileApplicationTasks, compileApplicationWorkers, databaseRecoveryBindings, legacyApplicationReleaseImport, recordReviewedStandaloneOverrides, workerRetirementScope)
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Cdn (DnsAdapterOps (..), DnsObservation (..), dnsSpecsFromDeclarations, mkDnsAdapter)
import Nagare.Inventory.Adapters.Kubernetes (KubernetesAdapterOps (..), KubernetesMutation (..), KubernetesState (..), mkKubernetesAdapter)
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..), mkKubernetesRuntimeOps)
import Nagare.Inventory.Command (convergeInventoryCandidateWith, loadTargetSnapshot, openTargetStore)
import Nagare.Inventory.DataService (compileStandaloneBroker, compileStandaloneDatabase)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Environment (compilePreviewEnvChannel, compilePreviewSecretChannel, compileRuntimeSecretChannel)
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed, resumeTransaction)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Dsl.Broker (BrokerBinding (..), mkTopicName)
import Nagare.Dsl.Cdn.Types (gcpCloudCdn, cloudflareCdn)
import Nagare.Dsl.Access (authPortal, requireLogin)
import Nagare.Resource.Application (applicationScopeId, taskResourceId, volumeResourceId)
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Inventory (ResourceBundle (..), Declaration (..), ManagedResource (..), DesiredSpec (KnativeService, NativeObject, DnsARecord, CloudflareProxiedARecord), Executor (KubernetesExecutor, PulumiExecutor, CdnExecutor), OperationKind (PreDeployHook), Contribution (RegisterBackend, RegisterNamespace, RegisterCloudflareCache), ContributionGrant (BackendMapGrant, NamespaceGrant, ShomeiSettingsGrant), ScopeChange (ReplaceScope), backendMapResourceId, candidateGenerations, candidateInventory, composeInventory, contributionResourceId, declarationId, inventoryDeclarations, inventoryScopes, mkScopeDeclaration, mkScopeSnapshot, scopeBundles, scopeConfigDigest, scopeId, scopeOverrides, shomeiSettingsResourceId, snapshotScopes)
import Nagare.Resource.Wire (canonicalValue, decodeScope, encodeCanonicalScope)
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), RecoveryClass (VerifyBeforeRetry), RecoveryIntent (..), Sensitivity (Private), mkSecretRef)
import Nagare.Resource.Policy qualified as ResourcePolicy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types qualified as Resource
import Nagare.Dsl.Load (loadApplication, loadBroker)
import Nagare.Dsl.Database (dbSecretName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (AccessMode (ReadWriteOnce), DomainTls (SuppliedTlsSecret), EnvScope (Build), EnvVar (EnvSecretRef), RetentionPolicy (Retain), Volume (..), databaseNameText, imageRefText, mkDomains, mkEnvName, mkImageRef, mkMountPath, mkNamespace, mkQuantity, mkSecretName, mkServiceName, mkVolumeName, runtimeScoped, scopedEnv, serviceNameText)
import Nagare.Dsl.Worker (Worker (..), mkReplicas)
import Nagare.Deploy (serviceUrl)
import Nagare.Static.Release (StaticRelease (..), StaticReleaseLog (..), addRelease, emptyReleaseLog, renderReleaseConfigMapWith)
import Nagare.Dsl.Presets (attachVolume)
import Nagare.Env.Generated (mergeGenerated)
import Nagare.Target (ActiveTarget (..), InventoryStoreKind (..), Mode (..), PulumiBackendKind (..), TargetProfile (..), mkContextName)
import System.Exit (ExitCode (..))
import System.Directory (doesFileExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

appDeployTests :: TestTree
appDeployTests =
  testGroup
    "Nagare.App.Deploy (EP-2)"
    [ testGroup "render + shared label (M1)" renderTests
    , testCase "disposable application review resumes from saved native members" nativeApplicationReview
    , testCase "reviewed command publishes and applies its immutable review" commandReview
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

-- Run separately with NAGARE_EP148_TEST_COMMAND=1: XDG_STATE_HOME is process
-- global, so the temporary command store must not race the parallel suite.
commandReview :: IO ()
commandReview = do
  enabled <- lookupEnv "NAGARE_EP148_TEST_COMMAND"
  case enabled of
    Nothing -> pure ()
    Just _ -> withSystemTempDirectory "ep148-command" $ \directory -> do
      previous <- lookupEnv "XDG_STATE_HOME"
      setEnv "XDG_STATE_HOME" directory
      let restore = case previous of
            Nothing -> unsetEnv "XDG_STATE_HOME"
            Just previousDirectory -> setEnv "XDG_STATE_HOME" previousDirectory
      run `finally` restore
  where
    checked :: Show e => Either e a -> a
    checked = either (error . show) id
    owner = checked (Resource.mkScopeId Resource.Application "command-fixture")
    foundation = checked (Resource.mkScopeId Resource.Platform "foundation")
    cloudOwner = checked (Resource.mkScopeId Resource.Platform "unrelated-cloud")
    otherOwner = checked (Resource.mkScopeId Resource.Application "other-app")
    cluster = Resource.mintResourceId foundation
      (checked (Resource.mkLogicalKey "cluster")) (checked (Resource.mkName "resource"))
    resource = Resource.mintResourceId owner
      (checked (Resource.mkLogicalKey "config")) (checked (Resource.mkName "configmap"))
    context = checked (Resource.mkContextId "ep148-command")
    binding = Resource.ContextBinding context (checked (Resource.mkName "project"))
    target = ActiveTarget (checked (mkContextName "ep148-command"))
      (testProfile & #project .~ "project" & #mode .~ Local)
    source = Resource.SourceLocation "absent-source/Config.hs" "command"
    value = Aeson.object
      [ "apiVersion" Aeson..= ("v1" :: Text)
      , "kind" Aeson..= ("ConfigMap" :: Text)
      , "metadata" Aeson..= Aeson.object
          ["name" Aeson..= ("ep148-command" :: Text)
          , "namespace" Aeson..= ("default" :: Text)]
      , "data" Aeson..= Aeson.object ["key" Aeson..= ("value" :: Text)]
      ]
    bytes = checked (canonicalValue value)
    (member, native) = checked (bindKubernetesObject
      (KubernetesInput resource owner cluster value (contentDigest bytes)
        DeleteWhenUnreferenced Stateless Private source))
    scope = checked (mkScopeDeclaration owner
      [ResourceBundle [Managed member] [] [] [] [] []])
    cloudId = Resource.mintResourceId cloudOwner
      (checked (Resource.mkLogicalKey "unrelated")) (checked (Resource.mkName "bucket"))
    cloud = member
      { identity = cloudId
      , owner = cloudOwner
      , executor = PulumiExecutor
      , address = Resource.GlobalBucket (checked (Resource.mkName "unrelated-bucket"))
      }
    cloudScope = checked (mkScopeDeclaration cloudOwner
      [ResourceBundle [Managed cloud] [] [] [] [] []])
    otherId = Resource.mintResourceId otherOwner
      (checked (Resource.mkLogicalKey "other")) (checked (Resource.mkName "configmap"))
    other = member
      { identity = otherId
      , owner = otherOwner
      , address = Resource.Kubernetes cluster "" (checked (Resource.mkName "configmap"))
          (Just (checked (Resource.mkName "default"))) (checked (Resource.mkName "other-app"))
      }
    otherScope = checked (mkScopeDeclaration otherOwner
      [ResourceBundle [Managed other] [] [] [] [] []])
    run = do
      observed <- newIORef Map.empty
      writes <- newIORef (0 :: Int)
      let operations = KubernetesAdapterOps
            { kubernetesContext = context
            , kubernetesObserve = \identity -> do
                states <- readIORef observed
                pure (Map.findWithDefault (KubernetesAbsent (contentDigest "absent"))
                  identity states)
            , kubernetesMutateConditional = \mutation -> do
                let identity = mutationResource mutation
                    physical = checked (Resource.mkPhysicalIdentity "uid-ep148-command")
                modifyIORef' observed (Map.insert identity
                  (KubernetesPresent physical "1" (Just identity) (mutationNativeDigest mutation)))
                modifyIORef' writes (+ 1)
                pure AdapterEffectCompleted
            }
          registryFor specs = checked (mkAdapterRegistry [mkKubernetesAdapter specs operations])
          planRegistry _ _ = pure (registryFor (Map.singleton resource (member, native)))
          applyRegistry reviewBundle = pure
            (registryFor (checked (kubernetesSpecsFromReview reviewBundle)))
      doesFileExist "absent-source/Config.hs" >>= (@?= False)
      store <- openTargetStore target
      _ <- initializeStore store binding "scope-isolation-command" >>= either (fail . show) pure
      let empty = checked (mkScopeSnapshot binding Map.empty Map.empty)
          seeded = checked (composeInventory empty
            (ReplaceScope cloudScope :| [ReplaceScope otherScope]))
      _ <- seedInventoryHistory store seeded >>= either (fail . show) pure
      before <- loadTargetSnapshot target
      let candidate = checked (composeInventory before (ReplaceScope scope :| []))
      convergeInventoryCandidateWith planRegistry applyRegistry target candidate
      readIORef writes >>= (@?= 1)
      snapshot <- loadTargetSnapshot target
      assertBool "single-invocation review did not accept the scope"
        (Map.member owner (snapshotScopes snapshot))
      forM_ [cloudOwner, otherOwner] $ \unchanged ->
        Map.lookup unchanged (snapshotScopes snapshot) @?= Map.lookup unchanged (snapshotScopes before)

nativeApplicationReview :: IO ()
nativeApplicationReview = do
  selected <- lookupEnv "NAGARE_EP148_TEST_CONTEXT"
  case selected of
    Nothing -> pure ()
    Just selectedContext -> do
      assertBool "refusing a non-disposable Kubernetes context"
        ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
      loaded <- loadApplication fixturePath
      original <- either (fail . show) pure loaded
      let checked :: Show e => Either e a -> a
          checked = either (error . show) id
          defaultNs = checked (mkNamespace "default")
          workers = take 2
            [worker & #namespace .~ defaultNs & #databases .~ []
                & #replicas .~ checked (mkReplicas 0)
            | worker <- original ^. #workers]
          app = original & #namespace .~ defaultNs & #service .~ Nothing
            & #databases .~ [] & #tasks .~ [] & #workers .~ workers
          rollout = testEnv & #namespace .~ "default" & #appEnv .~ app ^. #env
          foundation = checked (Resource.mkScopeId Resource.Platform "foundation")
          cluster = Resource.mintResourceId foundation
            (checked (Resource.mkLogicalKey "cluster")) (checked (Resource.mkName "resource"))
          namespaceId = Resource.mintResourceId foundation
            (checked (Resource.mkLogicalKey "foundation")) (checked (Resource.mkName "namespace-default"))
          publication = Resource.mintResourceId foundation
            (checked (Resource.mkLogicalKey "image")) (checked (Resource.mkName "publication"))
          foundationSource = Resource.SourceLocation "fixture" "foundation"
          foundationScope = checked (mkScopeDeclaration foundation [ResourceBundle
            [ External cluster (Resource.CloudInstance
                (checked (Resource.mkName "project")) (checked (Resource.mkName "zone"))
                (checked (Resource.mkName "cluster"))) [] foundationSource
            , External namespaceId (Resource.Kubernetes cluster ""
                (checked (Resource.mkName "namespace")) Nothing
                (checked (Resource.mkName "default"))) [] foundationSource
            , External publication (Resource.Artifact (checked (Resource.mkName "image"))
                (checked (Resource.mkContentDigest (T.replicate 64 "0")))) [] foundationSource
            ] [] [] [] [] []])
          cloudOwner = checked (Resource.mkScopeId Resource.Platform "unrelated-cloud")
          otherOwner = checked (Resource.mkScopeId Resource.Application "other-native-app")
          foreignMember ownerKey key executor address = ManagedResource
            { identity = Resource.mintResourceId ownerKey (checked (Resource.mkLogicalKey key))
                (checked (Resource.mkName "resource"))
            , owner = ownerKey
            , executor = executor
            , address = address
            , aliases = []
            , spec = NativeObject (contentDigest (TE.encodeUtf8 key))
            , lifecycle = ResourcePolicy.Retain
            , dataPolicy = Stateless
            , sensitivity = Private
            , dependencies = []
            , delegations = []
            , source = foundationSource
            }
          cloudScope = checked (mkScopeDeclaration cloudOwner [ResourceBundle
            [Managed (foreignMember cloudOwner "bucket" PulumiExecutor
              (Resource.GlobalBucket (checked (Resource.mkName "unrelated-bucket"))))]
            [] [] [] [] []])
          otherScope = checked (mkScopeDeclaration otherOwner [ResourceBundle
            [Managed (foreignMember otherOwner "configmap" KubernetesExecutor
              (Resource.Kubernetes cluster "" (checked (Resource.mkName "configmap"))
                (Just (checked (Resource.mkName "default")))
                (checked (Resource.mkName "other-native-app"))))]
            [] [] [] [] []])
          tag = rollout ^. #effectiveTag
          release = StaticRelease tag "kizashi" "default"
            (imageRefText (rollout ^. #qualifiedImage)) tag ""
            (Just "fixture") (UTCTime (fromGregorian 2026 6 19) 0)
          input = ApplicationScopeInput
            { scopeApplication = app
            , scopeRollout = rollout
            , scopeCluster = cluster
            , scopeNamespace = namespaceId
            , scopeNamespaceContributionOwner = Nothing
            , scopeImage = publication
            , scopeBrokerServices = Map.empty
            , scopeBrokerTopics = Map.empty
            , scopeAccessBinding = Nothing
            , scopeCdnBinding = Nothing
            , scopeDatabaseRecovery = Map.empty
            , scopeServiceVolumeRecovery = Map.empty
            , scopeTlsSecrets = Map.empty
            , scopeEnvSecrets = Map.empty
            , scopeWorkerVolumeRecovery = Map.empty
            , scopeBackupBackend = GcsBackend "project" "bucket"
            , scopeRelease = (emptyReleaseLog, release)
            , scopeHookEffects = Map.empty
            , scopeInputOverrides = Map.fromList
                [("tag", rollout ^. #imageTag)
                , ("imageResource", Resource.resourceIdText publication)]
            , scopeSource = Resource.SourceLocation "absent-source/Config.hs" "application"
            }
          (scope, native) = checked (compileApplicationScope input)
          binding = Resource.ContextBinding
            (checked (Resource.mkContextId "ep148-native")) (checked (Resource.mkName "project"))
          accepted = checked (mkScopeSnapshot binding
            (Map.fromList
              [(foundation, (checked (Resource.mkScopeGeneration 1), foundationScope))
              , (cloudOwner, (checked (Resource.mkScopeGeneration 1), cloudScope))
              , (otherOwner, (checked (Resource.mkScopeGeneration 1), otherScope))])
            Map.empty)
          candidate = checked (composeInventory accepted (ReplaceScope scope :| []))
          config = KubernetesRuntimeConfig (checked (Resource.mkContextId "ep148-native"))
            (T.pack selectedContext) (pure (Right ()))
          cleanup = forM_ [(Resource.nameText kind, Resource.nameText name)
              | (member, _) <- Map.elems native
              , Resource.Kubernetes _ _ kind _ name <- [member ^. #address]] $ \(kind, name) -> do
                _ <- readProcessWithExitCode "kubectl"
                  ["--context", selectedContext, "--namespace", "default", "delete", T.unpack kind,
                    T.unpack name, "--ignore-not-found", "--wait=false"] ""
                pure ()
      Map.size native @?= 3
      cleanup
      (do
        calls <- newIORef Map.empty
        interrupted <- newIORef False
        firstResource <- newIORef Nothing
        let makeRegistry retained =
              let nativeOps = mkKubernetesRuntimeOps config retained
                  guardedOps = nativeOps
                    { kubernetesMutateConditional = \mutation -> do
                        modifyIORef' calls (Map.insertWith (+) (mutationResource mutation) (1 :: Int))
                        effect <- kubernetesMutateConditional nativeOps mutation
                        alreadyInterrupted <- readIORef interrupted
                        if effect == AdapterEffectCompleted && not alreadyInterrupted
                          then do
                            writeIORef interrupted True
                            writeIORef firstResource (Just (mutationResource mutation))
                            pure (AdapterEffectAmbiguous "simulated lost acknowledgement")
                          else pure effect
                    }
               in checked (mkAdapterRegistry [mkKubernetesAdapter retained guardedOps])
        store <- newMemoryStore
        _ <- initializeStore store binding "ep148-test" >>= either (fail . show) pure
        _ <- seedInventoryHistory store candidate >>= either (fail . show) pure
        history <- loadInventoryHistory store >>= either (fail . show) pure
        let registry = makeRegistry native
            requirements = observationRequirements candidate history
        observed <- observeWithRegistry registry (requirementsByExecutor requirements)
          >>= either (fail . show) pure
        let proposal = checked (planChanges candidate noLifecycleDecisions history observed)
        snapshotBefore <- readStoreSnapshot store >>= either (fail . show) pure
        reviewBundle <- prepareReview registry snapshotBefore proposal >>= either (fail . show) pure
        kubernetesSpecsFromReview reviewBundle @?= Right native
        doesFileExist "absent-source/Config.hs" >>= (@?= False)
        _ <- publishReview store reviewBundle >>= either (fail . show) pure
        snapshotAfter <- readStoreSnapshot store >>= either (fail . show) pure
        reviewed <- either (fail . show) pure (verifyReview snapshotAfter reviewBundle)
        let registryFromReview = makeRegistry (checked (kubernetesSpecsFromReview reviewBundle))
        result <- applyReviewed store registryFromReview reviewed >>= either (fail . show) pure
        transaction <- case result of
          StoppedAmbiguous token _ -> pure token
          other -> assertFailure ("application did not pause after lost acknowledgement: " <> show other)
            >> fail "expected interrupted application"
        resumed <- resumeTransaction store registryFromReview transaction >>= either (fail . show) pure
        resumed @?= Converged transaction
        historyAfter <- loadInventoryHistory store >>= either (fail . show) pure
        forM_ [cloudOwner, otherOwner] $ \unchanged ->
          Map.lookup unchanged (historyAccepted historyAfter)
            @?= Map.lookup unchanged (historyAccepted history)
        (listingExit, listingBytes, _) <- readProcessWithExitCode "kubectl"
          ["--context", selectedContext, "--namespace", "default", "get",
            "deployment,configmap", "-o", "json"] ""
        listingExit @?= ExitSuccess
        let listed = case Aeson.eitherDecodeStrict (BC.pack listingBytes) of
              Right (Aeson.Object root) -> case KeyMap.lookup "items" root of
                Just (Aeson.Array items) ->
                  sort [(T.toLower kind, name)
                    | Aeson.Object item <- toList items
                    , Just (Aeson.String kind) <- [KeyMap.lookup "kind" item]
                    , Just (Aeson.Object metadata) <- [KeyMap.lookup "metadata" item]
                    , Just (Aeson.String name) <- [KeyMap.lookup "name" metadata]
                    , "kizashi" `T.isPrefixOf` name
                        || name == "nagare-app-deployments-kizashi"]
                _ -> []
              _ -> []
            expected = sort [(Resource.nameText kind, Resource.nameText name)
              | (member, _) <- Map.elems native
              , Resource.Kubernetes _ _ kind _ name <- [member ^. #address]]
        listed @?= expected
        firstMutated <- readIORef firstResource
        counts <- readIORef calls
        case firstMutated of
          Nothing -> assertFailure "application did not issue a native mutation"
          Just resource -> Map.lookup resource counts @?= Just 1
        ) `finally` cleanup

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
          let claimed = service & #aliases .~ [Resource.Hostname (unsafe (Resource.mkName "kizashi.example.com"))]
          assertBool "direct CDN mutation must detect a globally claimed hostname"
            (hostnameClaimOwned "kizashi.example.com" [Managed claimed])
          assertBool "a different hostname remains unclaimed"
            (not (hostnameClaimOwned "other.example.com" [Managed claimed]))
          assertBool "direct CDN mutation must also respect a platform external hostname"
            (hostnameClaimOwned "platform.example.com"
              [External publication (Resource.Hostname (unsafe (Resource.mkName "platform.example.com"))) [] source])
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
  , testCase "reviewed stop survives convergence and restart clears its visibility override" $ do
      loaded <- loadApplication fixturePath
      app <- either (fail . show) pure loaded
      let foundation = unsafe (Resource.mkScopeId Resource.Platform "foundation")
          cluster = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "cluster")) (unsafe (Resource.mkName "resource"))
          namespaceId = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "foundation")) (unsafe (Resource.mkName "namespace-personal"))
          publication = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "image")) (unsafe (Resource.mkName "publication"))
          source = Resource.SourceLocation "test" "service-action"
          withDomain = app & #service %~ fmap
            (#domains .~ unsafe (mkDomains [("app.example.com", True)]))
      (bundle, native) <- either (fail . show) pure
        (compileApplicationService withDomain testEnv cluster namespaceId publication
          Map.empty Map.empty Map.empty source)
      owner <- either (fail . T.unpack) pure (applicationScopeId withDomain)
      base <- either (fail . show) pure (mkScopeDeclaration owner [bundle])
      (stopped, stoppedNative) <- either (fail . show) pure
        (compileServiceActionScope "kizashi-serve" "personal" StopService base native)
      Map.lookup "operational.visibility" (scopeOverrides stopped) @?= Just "cluster-local"
      let changed = [rid | (rid, value) <- Map.toList native,
            Map.lookup rid stoppedNative /= Just value]
      length changed @?= 1
      serviceId <- case changed of
        [single] -> pure single
        _ -> assertFailure "stop changed unexpected native members" >> fail "missing Service"
      let stoppedBytes = snd (stoppedNative Map.! serviceId)
      assertBool "stop did not persist the cluster-local label in reviewed native bytes"
        (BC.isInfixOf "\"networking.knative.dev/visibility\":\"cluster-local\"" stoppedBytes)
      compileServiceActionScope "kizashi-serve" "personal" StopService stopped stoppedNative
        @?= Right (stopped, stoppedNative)
      (restarted, restartedNative) <- either (fail . show) pure
        (compileServiceActionScope "kizashi-serve" "personal" (RestartService "r2")
          stopped stoppedNative)
      Map.lookup "operational.visibility" (scopeOverrides restarted) @?= Nothing
      Map.lookup "operational.restart" (scopeOverrides restarted) @?= Just "r2"
      let restartedBytes = snd (restartedNative Map.! serviceId)
      assertBool "restart kept the stopped label"
        (not (BC.isInfixOf "networking.knative.dev/visibility" restartedBytes))
      assertBool "restart did not bind a new revision stamp"
        (BC.isInfixOf "\"nagare.dev/restartedAt\":\"r2\"" restartedBytes)
      assertBool "reviewed Service action changed its sibling DomainMapping"
        (all (\rid -> Map.lookup rid restartedNative == Map.lookup rid native)
          [rid | rid <- Map.keys native, rid /= serviceId])
      case compileServiceActionScope "other" "personal" StopService stopped stoppedNative of
        Left _ -> pure ()
        Right _ -> assertFailure "service action selected a different Service"
  , testCase "interrupted reviewed stop resumes once and ordinary convergence preserves it" $ do
      let checked :: Show e => Either e a -> a
          checked = either (error . show) id
          owner = checked (Resource.mkScopeId Resource.Standalone "service-action")
          cluster = Resource.mintResourceId owner
            (checked (Resource.mkLogicalKey "cluster")) (checked (Resource.mkName "cluster"))
          serviceId = Resource.mintResourceId owner
            (checked (Resource.mkLogicalKey "demo")) (checked (Resource.mkName "service"))
          source = Resource.SourceLocation "fixture" "service-action"
          value = Aeson.object
            ["apiVersion" Aeson..= ("serving.knative.dev/v1" :: Text)
            , "kind" Aeson..= ("Service" :: Text)
            , "metadata" Aeson..= Aeson.object
                ["name" Aeson..= ("demo" :: Text), "namespace" Aeson..= ("default" :: Text)
                , "labels" Aeson..= Aeson.object
                    ["nagare.dev/managed-by" Aeson..= ("nagarectl" :: Text)]]
            , "spec" Aeson..= Aeson.object ["template" Aeson..= Aeson.object
                ["metadata" Aeson..= Aeson.object ["annotations" Aeson..= Aeson.object []]
                , "spec" Aeson..= Aeson.object ["containers" Aeson..=
                    [Aeson.object ["image" Aeson..= ("example.test/demo:v1" :: Text)]]]]]]
          bytes = checked (canonicalValue value)
          (service, nativeBytes) = checked (bindKubernetesObject
            (KubernetesInput serviceId owner cluster value (contentDigest bytes)
              DeleteWhenUnreferenced Stateless Private source))
          base = checked (mkScopeDeclaration owner
            [ResourceBundle [Managed service] [] [] [] [] []])
          binding = Resource.ContextBinding
            (checked (Resource.mkContextId "ep148-stop")) (checked (Resource.mkName "project"))
          snapshot accepted = checked (mkScopeSnapshot binding
            (Map.map (\(revision, scope) -> (revisionGeneration revision, scope)) accepted)
            Map.empty)
      observed <- newIORef Map.empty
      writes <- newIORef (0 :: Int)
      interruptNext <- newIORef False
      let operations = KubernetesAdapterOps
            { kubernetesContext = checked (Resource.mkContextId "ep148-stop")
            , kubernetesObserve = \identity -> do
                states <- readIORef observed
                pure (Map.findWithDefault (KubernetesAbsent (contentDigest "absent"))
                  identity states)
            , kubernetesMutateConditional = \mutation -> do
                modifyIORef' writes (+ 1)
                count <- readIORef writes
                let physical = checked (Resource.mkPhysicalIdentity "uid-ep148-stop")
                modifyIORef' observed (Map.insert (mutationResource mutation)
                  (KubernetesPresent physical (T.pack (show count))
                    (Just (mutationResource mutation)) (mutationNativeDigest mutation)))
                interrupted <- readIORef interruptNext
                if interrupted
                  then writeIORef interruptNext False
                    >> pure (AdapterEffectAmbiguous "lost stop acknowledgement")
                  else pure AdapterEffectCompleted
            }
          registry native = checked (mkAdapterRegistry [mkKubernetesAdapter native operations])
          reviewCandidate store candidate native = do
            history <- loadInventoryHistory store >>= either (fail . show) pure
            let selected = registry native
            facts <- observeWithRegistry selected
              (requirementsByExecutor (observationRequirements candidate history))
              >>= either (fail . show) pure
            proposal <- either (fail . show) pure
              (planChanges candidate noLifecycleDecisions history facts)
            state <- readStoreSnapshot store >>= either (fail . show) pure
            bundle <- prepareReview selected state proposal >>= either (fail . show) pure
            _ <- publishReview store bundle >>= either (fail . show) pure
            published <- readStoreSnapshot store >>= either (fail . show) pure
            reviewed <- either (fail . show) pure (verifyReview published bundle)
            pure (bundle, reviewed)
      store <- newMemoryStore
      _ <- initializeStore store binding "ep148-stop" >>= either (fail . show) pure
      let initial = checked (composeInventory (snapshot Map.empty) (ReplaceScope base :| []))
          initialNative = Map.singleton serviceId (service, nativeBytes)
      _ <- seedInventoryHistory store initial >>= either (fail . show) pure
      (_, created) <- reviewCandidate store initial initialNative
      _ <- applyReviewed store (registry initialNative) created >>= either (fail . show) pure
      history <- loadInventoryHistory store >>= either (fail . show) pure
      (stopped, stoppedNative) <- either (fail . show) pure
        (compileServiceActionScope "demo" "default" StopService base initialNative)
      let stopCandidate = checked (composeInventory (snapshot (historyAccepted history))
            (ReplaceScope stopped :| []))
      (savedStop, reviewedStop) <- reviewCandidate store stopCandidate stoppedNative
      length (reviewOperations (reviewBundleDocument savedStop)) @?= 1
      writeIORef interruptNext True
      paused <- applyReviewed store (registry (checked (kubernetesSpecsFromReview savedStop)))
        reviewedStop >>= either (fail . show) pure
      transaction <- case paused of
        StoppedAmbiguous token _ -> pure token
        other -> assertFailure ("stop did not pause after lost acknowledgement: " <> show other)
          >> fail "expected interrupted stop"
      resumed <- resumeTransaction store
        (registry (checked (kubernetesSpecsFromReview savedStop))) transaction
        >>= either (fail . show) pure
      resumed @?= Converged transaction
      readIORef writes >>= (@?= 2)
      accepted <- loadInventoryHistory store >>= either (fail . show) pure
      let repeatedCandidate = checked (composeInventory (snapshot (historyAccepted accepted))
            (ReplaceScope stopped :| []))
      (sameStop, _) <- reviewCandidate store repeatedCandidate stoppedNative
      reviewOperations (reviewBundleDocument sameStop) @?= []
      let explicitDeploy = checked (composeInventory (snapshot (historyAccepted accepted))
            (ReplaceScope base :| []))
      (deployReview, _) <- reviewCandidate store explicitDeploy initialNative
      length (reviewOperations (reviewBundleDocument deployReview)) @?= 1
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
      appWithHooks <- either (fail . show) pure loaded
      let app = appWithHooks & #tasks .~ []
      serviceForRelease <- maybe (assertFailure "fixture has no web Service" >> fail "missing Service")
        pure (app ^. #service)
      let checked :: Show e => Either e a -> a
          checked = either (error . show) id
          foundation = unsafe (Resource.mkScopeId Resource.Platform "foundation")
          cluster = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "cluster")) (unsafe (Resource.mkName "resource"))
          namespaceId = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "foundation")) (unsafe (Resource.mkName "namespace-personal"))
          publication = Resource.mintResourceId foundation
            (unsafe (Resource.mkLogicalKey "image")) (unsafe (Resource.mkName "publication"))
          recovery = RecoveryIntent (unsafe (Resource.mkName "backup"))
            (mkSecretRef (unsafe (Resource.mkName "database-key"))
              (unsafe (Resource.mkName "v1")) :| [])
          tag = testEnv ^. #effectiveTag
          release = StaticRelease tag (serviceNameText (serviceForRelease ^. #name)) "personal"
            (imageRefText (testEnv ^. #qualifiedImage)) tag
            (serviceUrl serviceForRelease (testEnv ^. #baseDomain))
            (Just "fixture") (UTCTime (fromGregorian 2026 6 19) 0)
          input = ApplicationScopeInput
            { scopeApplication = app
            , scopeRollout = testEnv & #appEnv .~ app ^. #env
            , scopeCluster = cluster
            , scopeNamespace = namespaceId
            , scopeNamespaceContributionOwner = Nothing
            , scopeImage = publication
            , scopeBrokerServices = Map.empty
            , scopeBrokerTopics = Map.empty
            , scopeAccessBinding = Nothing
            , scopeCdnBinding = Nothing
            , scopeDatabaseRecovery = Map.fromList
                [(database ^. #name, recovery) | database <- app ^. #databases]
            , scopeServiceVolumeRecovery = Map.empty
            , scopeTlsSecrets = Map.empty
            , scopeEnvSecrets = Map.empty
            , scopeWorkerVolumeRecovery = Map.empty
            , scopeBackupBackend = GcsBackend "project" "bucket"
            , scopeRelease = (emptyReleaseLog, release)
            , scopeHookEffects = Map.empty
            , scopeInputOverrides = Map.fromList
                [("tag", testEnv ^. #imageTag)
                , ("baseDomain", testEnv ^. #baseDomain)
                , ("imageResource", Resource.resourceIdText publication)]
            , scopeSource = Resource.SourceLocation "test" "application"
            }
      (scope, native) <- either (fail . ("base: " <>) . show) pure
        (compileApplicationScope input)
      case scopeConfigDigest scope of
        Nothing -> assertFailure "reviewed application revision has no config digest"
        Just _ -> pure ()
      fmap scopeConfigDigest (decodeScope (encodeCanonicalScope scope))
        @?= Right (scopeConfigDigest scope)
      scopeOverrides scope @?= scopeInputOverrides input
      fmap scopeOverrides (decodeScope (encodeCanonicalScope scope))
        @?= Right (scopeInputOverrides input)
      let cdnOwner = checked (Resource.mkScopeId Resource.Platform "cdn")
          cdnBackendId = Resource.mintResourceId cdnOwner
            (checked (Resource.mkLogicalKey "backend")) (checked (Resource.mkName "backend"))
          cdnBackend = ManagedResource cdnBackendId cdnOwner PulumiExecutor
            (Resource.PulumiUrn "urn:pulumi:stack::project::gcp:compute/backendService:BackendService::backend")
            [] (NativeObject (contentDigest "backend")) ResourcePolicy.Retain Stateless Private [] []
            (Resource.SourceLocation "test" "cdn/backend")
          cdnRefs = GcpStackRefs "203.0.113.4" "backend" "urlmap" "zone" "tan-nb-exp"
          cdnApp = app & #service .~ Just (serviceForRelease
            & #domains .~ checked (mkDomains [("foo.apps.example.com", True)])
            & #cdn .~ Just gcpCloudCdn)
          cdnInput = input
            { scopeApplication = cdnApp
            , scopeCdnBinding = Just (GoogleCdnBindingFor (GoogleCdnBinding cdnRefs (Managed cdnBackend)))
            , scopeRelease = (emptyReleaseLog, release
                {url = serviceUrl (case cdnApp ^. #service of Just selected -> selected; Nothing -> error "missing service")
                  (testEnv ^. #baseDomain)})
            , scopeInputOverrides = Map.insert "cdnTarget" "203.0.113.4"
                (Map.insert "cdnBackendResource" (Resource.resourceIdText cdnBackendId)
                  (scopeInputOverrides input))
            }
      (cdnScope, cdnNative) <- either (fail . ("cdn: " <>) . show) pure
        (compileApplicationScope cdnInput)
      let dnsMembers = [resource | bundle <- scopeBundles cdnScope,
            Managed resource <- declarations bundle, resource ^. #executor == CdnExecutor]
      case dnsMembers of
        [dns] -> do
          dns ^. #spec @?= DnsARecord "203.0.113.4" 300
          dns ^. #address @?= Resource.DnsRecord (checked (Resource.mkName "tan-nb-exp"))
            (checked (Resource.mkName "zone")) (checked (Resource.mkName "foo.apps.example.com"))
          assertBool "DNS operation must not impersonate a Kubernetes native member"
            (Map.notMember (dns ^. #identity) cdnNative)
        _ -> assertFailure "reviewed application did not bind one Google DNS record"
      Map.size cdnNative @?= Map.size native + 1
      assertBool "CDN cannot disappear without a typed backend"
        (isLeft (compileApplicationScope (cdnInput {scopeCdnBinding = Nothing})))
      let cloudflareApp = cdnApp & #service %~ fmap (#cdn .~ Just cloudflareCdn)
          cloudflareBinding = CloudflareCdnBinding
            (checked (Resource.mkName "zone-id")) cdnOwner "203.0.113.5"
          cloudflareInput = cdnInput
            { scopeApplication = cloudflareApp
            , scopeCdnBinding = Just (CloudflareCdnBindingFor cloudflareBinding)
            , scopeInputOverrides = Map.insert "cdnZone" "zone-id"
                (Map.insert "cdnOriginIp" "203.0.113.5"
                  (Map.delete "cdnTarget" (Map.delete "cdnBackendResource"
                    (scopeInputOverrides cdnInput))))
            }
      (cloudflareScope, _) <- either (fail . ("cloudflare: " <>) . show) pure
        (compileApplicationScope cloudflareInput)
      let cloudflareDns = [member | bundle <- scopeBundles cloudflareScope,
            Managed member <- declarations bundle,
            member ^. #spec == CloudflareProxiedARecord "203.0.113.5"]
          cacheRequests = [request | bundle <- scopeBundles cloudflareScope,
            request@RegisterCloudflareCache {} <- contributions bundle]
      length cloudflareDns @?= 1
      length cacheRequests @?= 1
      assertBool "Cloudflare intent accepted a Google backend binding"
        (isLeft (compileApplicationScope (cloudflareInput
          {scopeCdnBinding = scopeCdnBinding cdnInput})))
      assertBool "Cloudflare intent accepted a wrong origin override"
        (isLeft (compileApplicationScope (cloudflareInput
          {scopeInputOverrides = Map.insert "cdnOriginIp" "203.0.113.7"
            (scopeInputOverrides cloudflareInput)})))
      assertBool "reviewed app accepted a false command tag"
        (isLeft (compileApplicationScope (input {scopeInputOverrides =
          Map.insert "tag" "different" (scopeInputOverrides input)})))
      assertBool "reviewed app accepted an undeclared command override"
        (isLeft (compileApplicationScope (input {scopeInputOverrides =
          Map.insert "unreviewed" "value" (scopeInputOverrides input)})))
      assertBool "reviewed app deployment silently skipped a pre-deploy hook"
        (isLeft (compileApplicationScope (input {scopeApplication = appWithHooks})))
      case (appWithHooks ^. #tasks, appWithHooks ^. #databases) of
        ([hook], database : _) -> do
          appOwner <- either (fail . T.unpack) pure (applicationScopeId appWithHooks)
          statefulRole <- either (fail . T.unpack) pure (Resource.mkName "statefulset")
          cronRole <- either (fail . T.unpack) pure (Resource.mkName "cronjob")
          databaseId <- either (fail . T.unpack) pure
            (databaseResourceId appOwner statefulRole database)
          cronId <- either (fail . T.unpack) pure
            (taskResourceId appOwner cronRole hook)
          let hookName = serviceNameText (hook ^. #name)
              hookInput = input
                { scopeApplication = appWithHooks
                , scopeHookEffects = Map.singleton hookName [databaseId]
                , scopeInputOverrides = Map.insert ("hook/" <> hookName)
                    (Resource.resourceIdText databaseId) (scopeInputOverrides input)
                }
          (hookScopes, hookNative) <- either (fail . show) pure
            (compileApplicationDeployment hookInput)
          length hookScopes @?= 2
          let noDataInput = hookInput
                { scopeHookEffects = Map.singleton hookName []
                , scopeInputOverrides = Map.insert ("hook/" <> hookName) ""
                    (scopeInputOverrides input)
                }
          (noDataScopes, _) <- either (fail . show) pure
            (compileApplicationDeployment noDataInput)
          case [operation | compiled <- noDataScopes,
              bundle <- scopeBundles compiled, operation <- operations bundle] of
            [operation] -> length (toList (operation ^. #affects)) @?= 1
            _ -> assertFailure "explicit no-data hook lacks a completion proof"
          let nextTag = "20260620-120000"
              nextRollout = scopeRollout hookInput
                & #imageTag .~ nextTag
                & #effectiveTag .~ nextTag
                & #taggedAppImage .~
                    (imageRefText (testEnv ^. #qualifiedImage) <> ":" <> nextTag)
              nextRelease = release {releaseId = nextTag, imageTag = nextTag}
              nextInput = hookInput
                { scopeRollout = nextRollout
                , scopeRelease = (addRelease release emptyReleaseLog, nextRelease)
                , scopeInputOverrides = Map.insert "tag" nextTag
                    (scopeInputOverrides hookInput)
                }
          (nextScopes, _) <- either (fail . show) pure
            (compileApplicationDeployment nextInput)
          case (hookScopes, nextScopes) of
            ([oldApp, oldHook], [newApp, newHook]) -> do
              scopeId oldApp @?= scopeId newApp
              assertBool "next tag would replace the old hook scope"
                (scopeId oldHook /= scopeId newHook)
              let foundationOwner = unsafe (Resource.mkScopeId Resource.Platform "foundation")
                  foundationSource = Resource.SourceLocation "test" "foundation"
                  foundationScope = checked (mkScopeDeclaration foundationOwner
                    [ResourceBundle
                      [ External cluster (Resource.CloudInstance
                          (unsafe (Resource.mkName "project"))
                          (unsafe (Resource.mkName "zone"))
                          (unsafe (Resource.mkName "cluster"))) [] foundationSource
                      , External namespaceId (Resource.Kubernetes cluster ""
                          (unsafe (Resource.mkName "namespace")) Nothing
                          (unsafe (Resource.mkName "personal"))) [] foundationSource
                      , External publication (Resource.Artifact
                          (unsafe (Resource.mkName "image"))
                          (unsafe (Resource.mkContentDigest (T.replicate 64 "0"))))
                          [] foundationSource
                      ] [] [] [] [] []])
                  generation = unsafe (Resource.mkScopeGeneration 1)
                  binding = Resource.ContextBinding
                    (unsafe (Resource.mkContextId "hook-rollover"))
                    (unsafe (Resource.mkName "project"))
              accepted <- either (fail . show) pure (mkScopeSnapshot binding
                (Map.fromList
                  [(scopeId foundationScope, (generation, foundationScope))
                  , (scopeId oldApp, (generation, oldApp))
                  , (scopeId oldHook, (generation, oldHook))]) Map.empty)
              nextCandidate <- either (fail . show) pure
                (composeInventory accepted
                  (ReplaceScope newApp :| [ReplaceScope newHook]))
              assertBool "new tag discarded accepted old hook scope"
                (Map.member (scopeId oldHook)
                  (inventoryScopes (candidateInventory nextCandidate)))
            _ -> assertFailure "each release needs one independent hook scope"
          let jobs = [member | compiled <- hookScopes,
                bundle <- scopeBundles compiled,
                Managed member <- declarations bundle,
                case member ^. #address of
                  Resource.Kubernetes _ "batch" kind _ _ -> kind == unsafe (Resource.mkName "job")
                  _ -> False]
              proofs = [operation | compiled <- hookScopes,
                bundle <- scopeBundles compiled,
                operation <- operations bundle]
              services = [member | compiled <- hookScopes,
                bundle <- scopeBundles compiled,
                Managed member <- declarations bundle,
                case member ^. #address of
                  Resource.Kubernetes _ "serving.knative.dev" kind _ _ ->
                    kind == unsafe (Resource.mkName "service")
                  _ -> False]
          case (jobs, proofs, services) of
            ([job], [proof], [service]) -> do
              assertBool "hook Job still belongs to the application scope"
                (job ^. #owner /= appOwner)
              proof ^. #operationKind @?= PreDeployHook
              toList (proof ^. #affects) @?= [job ^. #identity, databaseId]
              assertBool "hook Job does not wait for its CronJob"
                (OrderedAfter cronId `elem` job ^. #dependencies)
              assertBool "hook Job can start before its affected database is ready"
                (OrderedAfter databaseId `elem` job ^. #dependencies)
              assertBool "Service may start before hook completion"
                (OrderedAfter (proof ^. #identity) `elem` service ^. #dependencies)
              assertBool "hook Job lacks reviewed native bytes"
                (Map.member (job ^. #identity) hookNative)
            _ -> assertFailure "reviewed hook needs one Job, proof, and Service"
          let hookSecret = unsafe (mkSecretName "hook-token")
              hookSecretId = Resource.mintResourceId foundation
                (unsafe (Resource.mkLogicalKey "hook-token"))
                (unsafe (Resource.mkName "secret"))
              hookSecretBinding = External hookSecretId
                (Resource.Kubernetes cluster "" (unsafe (Resource.mkName "secret"))
                  (Just (unsafe (Resource.mkName "personal")))
                  (unsafe (Resource.mkName "hook-token"))) [] (scopeSource input)
              secretHook = hook & #env .~ Map.singleton
                (unsafe (mkEnvName "HOOK_TOKEN"))
                (runtimeScoped (EnvSecretRef hookSecret))
              secretHookInput = hookInput
                { scopeApplication = appWithHooks & #tasks .~ [secretHook]
                , scopeEnvSecrets = Map.singleton hookSecret hookSecretBinding
                }
          (secretHookScopes, _) <- either (fail . show) pure
            (compileApplicationDeployment secretHookInput)
          assertBool "hook-only Secret was dropped from the CronJob dependency"
            (any (\member -> OrderedAfter hookSecretId `elem` member ^. #dependencies)
              [member | compiled <- secretHookScopes,
                bundle <- scopeBundles compiled, Managed member <- declarations bundle,
                case member ^. #address of
                  Resource.Kubernetes _ "batch" kind _ _ ->
                    kind == unsafe (Resource.mkName "cronjob")
                  _ -> False])
        _ -> assertFailure "fixture needs one hook and an application database"
      let oldRelease = release {releaseId = "previous", imageTag = "previous"
            , createdAt = UTCTime (fromGregorian 2026 6 18) 0}
          releaseInput = input {scopeRelease = (addRelease oldRelease emptyReleaseLog, release)}
      (releasedScope, releasedNative) <- either (fail . ("prior history: " <>) . show) pure
        (compileApplicationScope releaseInput)
      let releaseMembers = [member | bundle <- scopeBundles releasedScope,
            Managed member <- declarations bundle,
            case member ^. #address of
              Resource.Kubernetes _ "" kind _ name ->
                kind == unsafe (Resource.mkName "configmap")
                  && name == unsafe (Resource.mkName "nagare-app-deployments-kizashi-serve")
              _ -> False]
      releaseMember <- case releaseMembers of
        [member] -> pure member
        _ -> assertFailure "reviewed application has no unique release metadata" >> fail "missing release"
      (_, legacyBytes) <- maybe (assertFailure "release has no private native bytes" >> fail "missing native")
        pure (Map.lookup (releaseMember ^. #identity) releasedNative)
      (importedLog, importedRelease) <- either (fail . T.unpack) pure
        (legacyApplicationReleaseImport app tag (release ^. #image) legacyBytes)
      (_, importedNative) <- either (fail . show) pure
        (compileApplicationScope (input {scopeRelease = (importedLog, importedRelease)}))
      Map.lookup (releaseMember ^. #identity) importedNative @?=
        Map.lookup (releaseMember ^. #identity) releasedNative
      assertBool "legacy release import accepted a different Service name"
        (isLeft (legacyApplicationReleaseImport
          (app & #service %~ fmap (#name .~ unsafe (mkServiceName "other")))
          tag (release ^. #image) legacyBytes))
      assertBool "legacy release import accepted a different rollout tag"
        (isLeft (legacyApplicationReleaseImport app "other-tag"
          (release ^. #image) legacyBytes))
      assertBool "legacy release import accepted a different rollout image"
        (isLeft (legacyApplicationReleaseImport app tag "other-image" legacyBytes))
      assertBool "legacy release import would reorder old entries"
        (isLeft (legacyApplicationReleaseImport app tag (release ^. #image)
          (renderReleaseConfigMapWith appDeploymentsPrefix "kizashi-serve" "personal"
            (importedLog & #releases %~ reverse))))
      let workloadIds = [member ^. #identity | bundle <- scopeBundles scope,
            Managed member <- declarations bundle,
            member ^. #identity /= releaseMember ^. #identity]
      assertBool "direct app deploy can overwrite accepted release history"
        (applicationNativeOwned app [releaseMember])
      assertBool "release metadata can precede a reviewed workload"
        (all (\resourceId -> OrderedAfter resourceId `elem` releaseMember ^. #dependencies) workloadIds)
      releaseSnapshot <- either (fail . show) pure (mkScopeSnapshot
        (Resource.ContextBinding (unsafe (Resource.mkContextId "release-fixture"))
          (unsafe (Resource.mkName "project")))
        (Map.singleton (scopeId releasedScope)
          (unsafe (Resource.mkScopeGeneration 1), releasedScope)) Map.empty)
      history <- either (fail . T.unpack) pure
        (acceptedApplicationReleaseLog releaseSnapshot releasedNative app cluster)
      history ^. #current @?= Just tag
      length (history ^. #releases) @?= 2
      assertBool "missing private release bytes were treated as an empty log"
        (isLeft (acceptedApplicationReleaseLog releaseSnapshot Map.empty app cluster))
      assertBool "malformed accepted release bytes were treated as an empty log"
        (isLeft (acceptedApplicationReleaseLog releaseSnapshot
          (Map.map (\(member, _) -> (member, "{\"data\":{}}")) releasedNative) app cluster))
      assertBool "release metadata accepted a forged route"
        (isLeft (compileApplicationScope
          (input {scopeRelease = (emptyReleaseLog, release {url = "https://wrong.example.test"})})))
      assertBool "standalone application Service compiler silently omitted app access"
        (isLeft (compileApplicationService (app & #access .~ Just requireLogin)
          testEnv cluster namespaceId publication Map.empty Map.empty Map.empty (scopeSource input)))
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
      length (scopeBundles scope) @?= 7
      Map.size native @?= 10
      length [() | bundle <- scopeBundles scope, Managed _ <- declarations bundle] @?= 10
      let customDomains = unsafe (mkDomains [("foo.apps.example.com", True)])
          expandedApp = app & #service %~ fmap (\service -> service
            & #tasks .~ (appWithHooks ^. #tasks) & #domains .~ customDomains
            & #cdn .~ Just gcpCloudCdn)
          expandedService = case expandedApp ^. #service of
            Just selected -> selected
            Nothing -> error "expanded application has no Service"
          expandedInput = input
            { scopeApplication = expandedApp
            , scopeCdnBinding = Just (GoogleCdnBindingFor (GoogleCdnBinding cdnRefs (Managed cdnBackend)))
            , scopeRelease = (emptyReleaseLog, release
                {url = serviceUrl expandedService (testEnv ^. #baseDomain)})
            , scopeInputOverrides = Map.insert "cdnTarget" "203.0.113.4"
                (Map.insert "cdnBackendResource" (Resource.resourceIdText cdnBackendId)
                  (scopeInputOverrides input))
            }
          (expandedScope, expandedNative) = checked (compileApplicationScope expandedInput)
      Map.size expandedNative @?= 12
      length [() | bundle <- scopeBundles expandedScope, Managed _ <- declarations bundle]
        @?= 13
      let nativeKinds = Set.fromList
            [(group, Resource.nameText kind) | (member, _) <- Map.elems expandedNative
            , Resource.Kubernetes _ group kind _ _ <- [member ^. #address]]
      forM_ [("serving.knative.dev", "service"), ("serving.knative.dev", "domainmapping")
        , ("apps", "deployment"), ("apps", "statefulset"), ("batch", "cronjob")
        , ("", "secret"), ("", "persistentvolumeclaim")] $ \kind ->
          assertBool ("expanded application omitted " <> show kind) (Set.member kind nativeKinds)
      fullBrokerLoaded <- loadBroker "../nagare-dsl/test/fixtures/broker/redpanda/nagare/Config.hs"
      fullBroker <- either (fail . show) pure fullBrokerLoaded
      let fullBrokerOwner = unsafe (Resource.mkScopeId Resource.Standalone "broker-full-app")
          fullBrokerRecovery = RecoveryIntent (unsafe (Resource.mkName "backup"))
            (mkSecretRef (unsafe (Resource.mkName "broker-key"))
              (unsafe (Resource.mkName "v1")) :| [])
          fullBrokerBinding = BrokerBinding (fullBroker ^. #name)
            [unsafe (mkTopicName "jobs")]
      (fullBrokerScope, _) <- either (fail . show) pure (compileStandaloneBroker
        fullBroker fullBrokerOwner cluster namespaceId fullBrokerRecovery
        (Resource.SourceLocation "test" "full-broker"))
      let runtimeSecretName = unsafe (mkSecretName "nagare-secret-kizashi-runtime")
      (runtimeSecretScope, _) <- either (fail . show) pure
        (compileRuntimeSecretChannel "kizashi" "personal" cluster namespaceId
          (unsafe (Resource.mkName "v1")) (Map.singleton "API_TOKEN" "private-canary")
          (Resource.SourceLocation "test" "runtime-secret"))
      (previewEnvScope, _) <- either (fail . show) pure
        (compilePreviewEnvChannel "kizashi" "personal" cluster namespaceId
          (Map.singleton "PREVIEW_MODE" "true")
          (Resource.SourceLocation "test" "preview-env"))
      (previewSecretScope, _) <- either (fail . show) pure
        (compilePreviewSecretChannel "kizashi" "personal" cluster namespaceId
          (unsafe (Resource.mkName "v1")) (Map.singleton "PREVIEW_TOKEN" "preview-canary")
          (Resource.SourceLocation "test" "preview-secret"))
      runtimeSecret <- case [secret | bundle <- scopeBundles runtimeSecretScope,
          secret@(Managed _) <- declarations bundle] of
        [secret] -> pure secret
        _ -> assertFailure "runtime Secret channel has unexpected membership" >> fail "missing Secret"
      let reviewContext = unsafe (Resource.mkContextId "ep148-complete-app")
          reviewBinding = Resource.ContextBinding reviewContext (unsafe (Resource.mkName "tan-nb-exp"))
          foundationSource = Resource.SourceLocation "fixture" "foundation"
          reviewFoundationScope = checked (mkScopeDeclaration foundation [ResourceBundle
            [ External cluster (Resource.CloudInstance
                (unsafe (Resource.mkName "tan-nb-exp")) (unsafe (Resource.mkName "zone"))
                (unsafe (Resource.mkName "cluster"))) [] foundationSource
            , External namespaceId (Resource.Kubernetes cluster ""
                (unsafe (Resource.mkName "namespace")) Nothing
                (unsafe (Resource.mkName "personal"))) [] foundationSource
            , External publication (Resource.Artifact (unsafe (Resource.mkName "image"))
                (unsafe (Resource.mkContentDigest (T.replicate 64 "0")))) [] foundationSource
            ] [] [] [] [] []])
          reviewCdnScope = checked (mkScopeDeclaration cdnOwner
            [ResourceBundle [Managed cdnBackend] [] [] [] [] []])
          acceptedForReview = checked (mkScopeSnapshot reviewBinding
            (Map.fromList
              [(foundation, (unsafe (Resource.mkScopeGeneration 1), reviewFoundationScope))
              ,(cdnOwner, (unsafe (Resource.mkScopeGeneration 1), reviewCdnScope))
              ,(fullBrokerOwner, (unsafe (Resource.mkScopeGeneration 1), fullBrokerScope))
              ,(scopeId runtimeSecretScope,
                  (unsafe (Resource.mkScopeGeneration 1), runtimeSecretScope))
              ,(scopeId previewEnvScope,
                  (unsafe (Resource.mkScopeGeneration 1), previewEnvScope))
              ,(scopeId previewSecretScope,
                  (unsafe (Resource.mkScopeGeneration 1), previewSecretScope))])
            Map.empty)
          candidateForReview = checked (composeInventory acceptedForReview
            (ReplaceScope expandedScope :| []))
      (fullBrokerServices, fullBrokerTopics, fullBrokerEnv) <- either (fail . T.unpack) pure
        (acceptedBrokerBindings acceptedForReview cluster "personal" [fullBrokerBinding])
      let fullApp = expandedApp
            & #brokers .~ [fullBrokerBinding]
            & #service %~ fmap (\service -> service & #env %~ Map.insert
                (unsafe (mkEnvName "API_TOKEN"))
                (runtimeScoped (EnvSecretRef runtimeSecretName)))
          fullInput = expandedInput
            { scopeApplication = fullApp
            , scopeRollout = scopeRollout expandedInput
                & #appEnv .~ mergeGenerated fullBrokerEnv (fullApp ^. #env)
            , scopeBrokerServices = fullBrokerServices
            , scopeBrokerTopics = fullBrokerTopics
            , scopeEnvSecrets = Map.singleton runtimeSecretName runtimeSecret
            }
      (fullScope, _) <- either (fail . show) pure (compileApplicationScope fullInput)
      _ <- either (fail . show) pure (composeInventory acceptedForReview
        (ReplaceScope fullScope :| []))
      assertBool "full application scope leaked accepted private Secret bytes"
        (not (BS.isInfixOf "private-canary" (encodeCanonicalScope fullScope)))
      let fullMembers = [member | bundle <- scopeBundles fullScope,
            Managed member <- declarations bundle]
          fullService = [member | member <- fullMembers,
            case member ^. #address of
              Resource.Kubernetes _ "serving.knative.dev" kind _ _ ->
                kind == unsafe (Resource.mkName "service")
              _ -> False]
          topicIds = map declarationId (concatMap Map.elems (Map.elems fullBrokerTopics))
      assertBool "full application omitted accepted broker topic dependency"
        (any (\member -> all (\topic -> OrderedAfter topic `elem` member ^. #dependencies)
          topicIds) fullService)
      assertBool "full application omitted accepted runtime Secret dependency"
        (any (\member -> OrderedAfter (declarationId runtimeSecret)
          `elem` member ^. #dependencies) fullService)
      observedStates <- newIORef Map.empty
      dnsState <- newIORef DnsMissing
      executedIds <- newIORef []
      let dnsSpecs = checked (dnsSpecsFromDeclarations
            (inventoryDeclarations (candidateInventory candidateForReview)))
          dnsMember = case [member | bundle <- scopeBundles expandedScope,
              Managed member <- declarations bundle, member ^. #executor == CdnExecutor] of
            [member] -> member
            _ -> error "expanded application has no single DNS member"
          dnsOps = DnsAdapterOps
            { dnsInspect = \_ -> readIORef dnsState
            , dnsCreate = \_ -> do
                writeIORef dnsState (DnsPresent
                  (unsafe (Resource.mkPhysicalIdentity "recorded:dns")) "203.0.113.4" 300)
                modifyIORef' executedIds (dnsMember ^. #identity :)
                pure AdapterEffectCompleted
            , dnsReplace = \_ -> pure (AdapterEffectFailed
                (KnownNoEffect "unexpected DNS replacement"))
            }
          operations = KubernetesAdapterOps
            { kubernetesContext = reviewContext
            , kubernetesObserve = \resource -> do
                states <- readIORef observedStates
                pure (Map.findWithDefault
                  (KubernetesAbsent (contentDigest (TE.encodeUtf8 (Resource.resourceIdText resource))))
                  resource states)
            , kubernetesMutateConditional = \mutation -> do
                let resource = mutationResource mutation
                    physical = unsafe (Resource.mkPhysicalIdentity
                      ("recorded:" <> Resource.resourceIdText resource))
                modifyIORef' observedStates (Map.insert resource
                  (KubernetesPresent physical "1" (Just resource) (mutationNativeDigest mutation)))
                modifyIORef' executedIds (resource :)
                pure AdapterEffectCompleted
            }
          registryFor specs = checked (mkAdapterRegistry
            [mkKubernetesAdapter specs operations, mkDnsAdapter Map.empty dnsSpecs dnsOps])
      reviewStore <- newMemoryStore
      _ <- initializeStore reviewStore reviewBinding "ep148-full-fixture"
        >>= either (fail . show) pure
      _ <- seedInventoryHistory reviewStore candidateForReview
        >>= either (fail . show) pure
      reviewHistory <- loadInventoryHistory reviewStore >>= either (fail . show) pure
      let reviewRegistry = registryFor expandedNative
          requirements = observationRequirements candidateForReview reviewHistory
      observations <- observeWithRegistry reviewRegistry (requirementsByExecutor requirements)
        >>= either (fail . show) pure
      let proposal = checked (planChanges candidateForReview noLifecycleDecisions
            reviewHistory observations)
      case [operation | operation <- proposalOperations proposal,
          plannedExecutor operation == CdnExecutor] of
        [operation] -> do
          plannedAction operation @?= CreateResource
          plannedRecovery operation @?= VerifyBeforeRetry
        _ -> assertFailure "reviewed application omitted its guarded DNS create"
      reviewSnapshot <- readStoreSnapshot reviewStore >>= either (fail . show) pure
      savedReview <- prepareReview reviewRegistry reviewSnapshot proposal
        >>= either (fail . show) pure
      publishedDigest <- publishReview reviewStore savedReview >>= either (fail . show) pure
      publishedReview <- loadPublishedReview reviewStore publishedDigest
        >>= either (fail . show) pure
      reviewedNative <- either (fail . T.unpack) pure (kubernetesSpecsFromReview publishedReview)
      Map.keysSet reviewedNative @?= Map.keysSet expandedNative
      Map.map snd reviewedNative @?= Map.map snd expandedNative
      publishedSnapshot <- readStoreSnapshot reviewStore >>= either (fail . show) pure
      reviewed <- either (fail . show) pure (verifyReview publishedSnapshot publishedReview)
      result <- applyReviewed reviewStore
        (registryFor reviewedNative) reviewed
        >>= either (fail . show) pure
      case result of
        Converged _ -> pure ()
        other -> assertFailure ("complete application review did not converge: " <> show other)
      afterReview <- loadInventoryHistory reviewStore >>= either (fail . show) pure
      forM_ [foundation, cdnOwner, fullBrokerOwner, scopeId runtimeSecretScope,
          scopeId previewEnvScope, scopeId previewSecretScope] $ \owner ->
        Map.lookup owner (historyAccepted afterReview)
          @?= Map.lookup owner (historyAccepted reviewHistory)
      writes <- readIORef executedIds
      length writes @?= Map.size expandedNative + 1
      Set.fromList writes @?= Set.insert (dnsMember ^. #identity) (Map.keysSet expandedNative)
      let executionOrder = Map.fromList (zip (reverse writes) [0 :: Int ..])
      forM_ (Map.elems expandedNative) $ \(member, _) ->
        forM_ [dependency | OrderedAfter dependency <- member ^. #dependencies
          , Map.member dependency expandedNative] $ \dependency ->
            case (Map.lookup dependency executionOrder,
                  Map.lookup (member ^. #identity) executionOrder) of
              (Just dependencyOrdinal, Just memberOrdinal) -> assertBool
                ("review executed " <> show (member ^. #identity)
                  <> " before " <> show dependency) (dependencyOrdinal < memberOrdinal)
              _ -> assertFailure "review execution omitted a declared dependency"
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
      (brokerServices, brokerTopics, brokerEnv) <- either (fail . T.unpack) pure
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
      let workerOverrides = Map.fromList
            [("tag", workerRollout ^. #imageTag)
            , ("imageResource", Resource.resourceIdText publication)]
      reviewedWorker <- either (fail . show) pure
        (recordReviewedStandaloneOverrides workerRollout publication workerOverrides standaloneBrokerScope)
      fmap scopeOverrides (decodeScope (encodeCanonicalScope reviewedWorker))
        @?= Right workerOverrides
      assertBool "standalone worker accepted a false image override"
        (isLeft (recordReviewedStandaloneOverrides workerRollout publication
          (Map.insert "imageResource" "other" workerOverrides) standaloneBrokerScope))
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
      (standaloneReleasedScope, standaloneReleasedNative) <- either (fail . show) pure
        (compileStandaloneServiceWithRelease serviceOwner independentService serviceRollout
          cluster namespaceId publication Map.empty Map.empty Map.empty brokerServices Map.empty
          Map.empty Nothing emptyReleaseLog release (scopeSource input))
      let serviceOverrides = Map.fromList
            [("tag", serviceRollout ^. #imageTag)
            , ("baseDomain", serviceRollout ^. #baseDomain)
            , ("imageResource", Resource.resourceIdText publication)]
      reviewedService <- either (fail . show) pure
        (recordReviewedStandaloneOverrides serviceRollout publication serviceOverrides standaloneReleasedScope)
      fmap scopeOverrides (decodeScope (encodeCanonicalScope reviewedService))
        @?= Right serviceOverrides
      assertBool "standalone Service accepted a false domain override"
        (isLeft (recordReviewedStandaloneOverrides serviceRollout publication
          (Map.insert "baseDomain" "other.example" serviceOverrides) standaloneReleasedScope))
      let standaloneReleaseMembers = [member | bundle <- scopeBundles standaloneReleasedScope,
            Managed member <- declarations bundle,
            case member ^. #address of
              Resource.Kubernetes _ "" kind _ name ->
                kind == unsafe (Resource.mkName "configmap")
                  && name == unsafe (Resource.mkName "nagare-app-deployments-kizashi-serve")
              _ -> False]
      standaloneReleaseMember <- case standaloneReleaseMembers of
        [member] -> pure member
        _ -> assertFailure "reviewed standalone Service omitted its release history" >> fail "missing release"
      assertBool "standalone release history can precede its Service"
        (any (\member -> OrderedAfter (member ^. #identity)
          `elem` standaloneReleaseMember ^. #dependencies)
          [member | bundle <- scopeBundles standaloneServiceScope,
            Managed member <- declarations bundle,
            case member ^. #address of
              Resource.Kubernetes _ "serving.knative.dev" kind _ _ ->
                kind == unsafe (Resource.mkName "service")
              _ -> False])
      standaloneReleaseSnapshot <- either (fail . show) pure (mkScopeSnapshot
        historyBinding (Map.singleton serviceOwner
          (unsafe (Resource.mkScopeGeneration 1), standaloneReleasedScope)) Map.empty)
      standaloneHistory <- either (fail . T.unpack) pure
        (acceptedStandaloneReleaseLog standaloneReleaseSnapshot standaloneReleasedNative
          serviceOwner independentService cluster)
      standaloneHistory ^. #current @?= Just tag
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
      boundDatabase <- case app ^. #databases of
        [onlyDatabase] -> pure onlyDatabase
        _ -> assertFailure "fixture does not have one database" >> fail "missing database"
      let databaseOwner = unsafe (Resource.mkScopeId Resource.Standalone "database-kizashi-db")
          databaseInput = DatabaseDirectInput
            { directDatabase = boundDatabase
            , directOwnerScope = databaseOwner
            , directClusterId = cluster
            , directNamespaceId = Just namespaceId
            , directRecoveryIntent = recovery
            , directSourceLocation = scopeSource input
            }
      (databaseScope, databaseNative) <- either (fail . show) pure
        (compileStandaloneDatabase databaseInput (scopeBackupBackend input))
      standaloneDatabaseSnapshot <- either (fail . show) pure (mkScopeSnapshot historyBinding
        (Map.singleton databaseOwner (unsafe (Resource.mkScopeGeneration 1), databaseScope)) Map.empty)
      databaseBindings <- either (fail . T.unpack) pure (acceptedDatabaseBindings
        standaloneDatabaseSnapshot databaseNative cluster "personal" [boundDatabase ^. #name])
      assertBool "database binding survived without its accepted private credential"
        (isLeft (acceptedDatabaseBindings standaloneDatabaseSnapshot Map.empty cluster
          "personal" [boundDatabase ^. #name]))
      assertBool "database binding crossed a namespace"
        (isLeft (acceptedDatabaseBindings standaloneDatabaseSnapshot databaseNative cluster
          "other" [boundDatabase ^. #name]))
      assertBool "database binding duplicated one database"
        (isLeft (acceptedDatabaseBindings standaloneDatabaseSnapshot databaseNative cluster
          "personal" [boundDatabase ^. #name, boundDatabase ^. #name]))
      let workerWithDatabase = worker & #brokers .~ []
          serviceWithDatabase = webService & #brokers .~ []
            & #databases .~ [boundDatabase ^. #name]
          databaseId = unsafe (databaseResourceId databaseOwner
            (unsafe (Resource.mkName "statefulset")) boundDatabase)
      assertBool "database binding survived without the accepted StatefulSet bytes"
        (isLeft (acceptedDatabaseBindings standaloneDatabaseSnapshot
          (Map.delete databaseId databaseNative) cluster "personal" [boundDatabase ^. #name]))
      (databaseWorkerScope, databaseWorkerNative) <- either (fail . show) pure
        (compileStandaloneWorkerWithDependencies standaloneOwner workerWithDatabase workerRollout
          cluster namespaceId publication Map.empty Map.empty Map.empty Map.empty databaseBindings (scopeSource input))
      let databaseWorkers =
            [member | bundle <- scopeBundles databaseWorkerScope, Managed member <- declarations bundle]
      assertBool "standalone worker lacks its accepted database dependency"
        (all (elem (OrderedAfter databaseId) . (^. #dependencies)) databaseWorkers)
      assertBool "standalone worker lost generated database connection or Secret reference"
        (any (\(_, bytes) -> BS.isInfixOf "POSTGRES_HOST" bytes
          && BS.isInfixOf "POSTGRES_PASSWORD" bytes) (Map.elems databaseWorkerNative))
      (databaseServiceScope, databaseServiceNative) <- either (fail . show) pure
        (compileStandaloneServiceWithDependencies serviceOwner serviceWithDatabase serviceRollout
          cluster namespaceId publication Map.empty Map.empty Map.empty Map.empty Map.empty databaseBindings Nothing (scopeSource input))
      let databaseServices =
            [member | bundle <- scopeBundles databaseServiceScope, Managed member <- declarations bundle
            , case member ^. #address of
                Resource.Kubernetes _ "serving.knative.dev" kind _ _ ->
                  kind == unsafe (Resource.mkName "service")
                _ -> False]
      assertBool "standalone Service lacks its accepted database dependency"
        (all (elem (OrderedAfter databaseId) . (^. #dependencies)) databaseServices)
      assertBool "standalone Service lost generated database connection or Secret reference"
        (any (\(_, bytes) -> BS.isInfixOf "POSTGRES_HOST" bytes
          && BS.isInfixOf "POSTGRES_PASSWORD" bytes) (Map.elems databaseServiceNative))
      let databaseGeneration = unsafe (Resource.mkScopeGeneration 1)
          bindingImageDigest = unsafe (Resource.mkContentDigest (T.replicate 64 "0"))
          prerequisiteBundle = ResourceBundle
            [ External namespaceId (Resource.Kubernetes cluster ""
                (unsafe (Resource.mkName "namespace")) Nothing
                (unsafe (Resource.mkName "personal"))) [] (scopeSource input)
            , External publication (Resource.Artifact
                (unsafe (Resource.mkName "image")) bindingImageDigest) [] (scopeSource input)
            ] [] [] [] [] []
      prerequisiteScope <- either (fail . show) pure
        (mkScopeDeclaration foundation [prerequisiteBundle])
      authService <- case [member | bundle <- scopeBundles scope,
          Managed member <- declarations bundle,
          case member ^. #address of
            Resource.Kubernetes _ "serving.knative.dev" kind _ _ ->
              kind == unsafe (Resource.mkName "service")
            _ -> False] of
        [member] -> pure member
        _ -> assertFailure "application fixture has no unique web Service" >> fail "missing Service"
      let authOwner = unsafe (Resource.mkScopeId Resource.Platform "auth")
          enforcerId = Resource.mintResourceId authOwner
            (unsafe (Resource.mkLogicalKey "auth")) (unsafe (Resource.mkName "enforcer"))
          enforcer = authService
            { identity = enforcerId
            , owner = authOwner
            , address = Resource.Kubernetes cluster "serving.knative.dev"
                (unsafe (Resource.mkName "service")) (Just (unsafe (Resource.mkName "nagare-system")))
                (unsafe (Resource.mkName "nagare-access"))
            , dependencies = []
            }
      authScope <- either (fail . show) pure (mkScopeDeclaration authOwner
        [ResourceBundle [Managed enforcer] [] [] [] []
          [BackendMapGrant cluster, ShomeiSettingsGrant cluster
            (unsafe (Resource.mkName "apps.example.com"))]])
      authSnapshot <- either (fail . show) pure (mkScopeSnapshot historyBinding
        (Map.fromList [(foundation, (databaseGeneration, prerequisiteScope))
          , (authOwner, (databaseGeneration, authScope))]) Map.empty)
      accessBinding <- either (fail . T.unpack) pure (acceptedAccessBinding authSnapshot cluster)
      let accessApp = app & #access .~ Just requireLogin
          accessInput = input
            { scopeApplication = accessApp
            , scopeAccessBinding = Just accessBinding
            }
      (accessScope, accessNative) <- either (fail . ("access: " <>) . show) pure
        (compileApplicationScope accessInput)
      let accessRoutes = [member | bundle <- scopeBundles accessScope,
            Managed member <- declarations bundle,
            case member ^. #address of
              Resource.Kubernetes _ "serving.knative.dev" kind (Just ns) _ ->
                kind == unsafe (Resource.mkName "domainmapping")
                  && ns == unsafe (Resource.mkName "nagare-system")
              _ -> False]
          accessRequests = [request | bundle <- scopeBundles accessScope,
            request@RegisterBackend {} <- contributions bundle]
      assertBool "reviewed app access lacks a shared backend contribution"
        (not (null accessRequests))
      assertBool "reviewed app access route lacks enforcer and backend dependencies"
        (not (null accessRoutes) && all (\route ->
          all (`elem` route ^. #dependencies)
            [OrderedAfter enforcerId, OrderedAfter (backendMapResourceId authOwner)]) accessRoutes)
      assertBool "reviewed app route does not target the accepted enforcer"
        (any (BS.isInfixOf "nagare-access" . snd) (Map.elems accessNative))
      accessCandidate <- either (fail . show) pure (composeInventory authSnapshot
        (ReplaceScope accessScope :| []))
      Map.lookup authOwner (candidateGenerations accessCandidate) @?= Just databaseGeneration
      (portalScope, _) <- either (fail . ("portal: " <>) . show) pure (compileApplicationScope
        (accessInput {scopeApplication = app & #access .~ Just authPortal}))
      let portalRoutes = [member | bundle <- scopeBundles portalScope,
            Managed member <- declarations bundle,
            case member ^. #address of
              Resource.Kubernetes _ "serving.knative.dev" kind (Just ns) _ ->
                kind == unsafe (Resource.mkName "domainmapping")
                  && ns == unsafe (Resource.mkName "nagare-system")
              _ -> False]
      assertBool "auth portal route does not wait for shared Shomei settings"
        (all (elem (OrderedAfter (shomeiSettingsResourceId authOwner)) . (^. #dependencies)) portalRoutes)
      _ <- either (fail . show) pure (composeInventory authSnapshot
        (ReplaceScope portalScope :| []))
      let accessService = independentService & #brokers .~ []
            & #domains .~ [] & #access .~ Just requireLogin
      (standaloneAccessScope, _) <- either (fail . show) pure
        (compileStandaloneServiceWithDependencies serviceOwner accessService serviceRollout
          cluster namespaceId publication Map.empty Map.empty Map.empty Map.empty Map.empty
          Map.empty (Just accessBinding) (scopeSource input))
      let defaultRoutes = [member | bundle <- scopeBundles standaloneAccessScope,
            Managed member <- declarations bundle,
            case member ^. #address of
              Resource.Kubernetes _ "serving.knative.dev" kind (Just ns) host ->
                kind == unsafe (Resource.mkName "domainmapping")
                  && ns == unsafe (Resource.mkName "nagare-system")
                  && host == unsafe (Resource.mkName "kizashi-serve.personal.apps.example.com")
              _ -> False]
      length defaultRoutes @?= 1
      _ <- either (fail . show) pure (composeInventory authSnapshot
        (ReplaceScope standaloneAccessScope :| []))
      assertBool "access intent accepted without auth evidence"
        (isLeft (compileApplicationScope (accessInput {scopeAccessBinding = Nothing})))
      readySnapshot <- either (fail . show) pure (mkScopeSnapshot historyBinding
        (Map.fromList [(foundation, (databaseGeneration, prerequisiteScope))
          , (databaseOwner, (databaseGeneration, databaseScope))]) Map.empty)
      assertBool "missing auth scope supplied access authority"
        (isLeft (acceptedAccessBinding readySnapshot cluster))
      serviceCandidate <- either (fail . show) pure (composeInventory readySnapshot
        (ReplaceScope databaseServiceScope :| []))
      Map.lookup databaseOwner (candidateGenerations serviceCandidate) @?= Just databaseGeneration
      workerCandidate <- either (fail . show) pure (composeInventory readySnapshot
        (ReplaceScope databaseWorkerScope :| []))
      Map.lookup databaseOwner (candidateGenerations workerCandidate) @?= Just databaseGeneration
      assertBool "standalone worker accepted an unbound database"
        (isLeft (compileStandaloneWorkerWithDependencies standaloneOwner workerWithDatabase workerRollout
          cluster namespaceId publication Map.empty Map.empty Map.empty Map.empty Map.empty (scopeSource input)))
      let brokerInput = input
            { scopeApplication = brokerApp
            , scopeRollout = scopeRollout input & #appEnv .~ mergeGenerated brokerEnv (app ^. #env)
            , scopeBrokerServices = brokerServices
            , scopeBrokerTopics = brokerTopics
            }
      (brokerAppScope, brokerNative) <- either (fail . ("broker: " <>) . show) pure
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
            , scopeBrokerTopics = brokerTopics
            }
      (_, localNative) <- either (fail . ("local broker: " <>) . show) pure
        (compileApplicationScope localInput)
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
      (topicBrokerScope, _) <- either (fail . show) pure (compileStandaloneBroker
        broker brokerOwner cluster namespaceId brokerRecovery
        (Resource.SourceLocation "test" "broker"))
      topicSnapshot <- either (fail . show) pure (mkScopeSnapshot historyBinding
        (Map.singleton brokerOwner (unsafe (Resource.mkScopeGeneration 1), topicBrokerScope)) Map.empty)
      let topicBinding = brokerBinding & #topics .~ [unsafe (mkTopicName "jobs")]
      (topicServices, topicEvidence, topicEnv) <- either (fail . T.unpack) pure
        (acceptedBrokerBindings topicSnapshot cluster "personal" [topicBinding])
      topicId <- case Map.lookup (broker ^. #name) topicEvidence >>= Map.lookup (unsafe (mkTopicName "jobs")) of
        Just declaration -> pure (declarationId declaration)
        Nothing -> assertFailure "accepted topic lost its logical resource" >> fail "missing topic"
      let topicWorker = standaloneWorker & #brokers .~ [topicBinding]
          topicService = independentService & #brokers .~ [topicBinding]
          topicApp = app & #brokers .~ [topicBinding]
          topicInput = input
            { scopeApplication = topicApp
            , scopeRollout = scopeRollout input & #appEnv .~ mergeGenerated topicEnv (app ^. #env)
            , scopeBrokerServices = topicServices
            , scopeBrokerTopics = topicEvidence
            }
      (topicWorkerScope, topicWorkerNative) <- either (fail . show) pure
        (compileStandaloneWorkerWithDependencies standaloneOwner topicWorker workerRollout
          cluster namespaceId publication Map.empty Map.empty topicServices topicEvidence Map.empty (scopeSource input))
      let topicWorkerMembers = [member | bundle <- scopeBundles topicWorkerScope,
            Managed member <- declarations bundle]
      assertBool "reviewed worker lost accepted topic ordering or generated env"
        (all (elem (OrderedAfter topicId) . (^. #dependencies)) topicWorkerMembers
          && any (BS.isInfixOf "NAGARE_TOPIC_JOBS" . snd) (Map.elems topicWorkerNative))
      (topicServiceScope, topicServiceNative) <- either (fail . show) pure
        (compileStandaloneServiceWithDependencies serviceOwner topicService serviceRollout
          cluster namespaceId publication Map.empty Map.empty Map.empty topicServices topicEvidence Map.empty Nothing (scopeSource input))
      let topicServiceMembers = [member | bundle <- scopeBundles topicServiceScope,
            Managed member <- declarations bundle,
            case member ^. #address of
              Resource.Kubernetes _ "serving.knative.dev" kind _ _ -> kind == unsafe (Resource.mkName "service")
              _ -> False]
      assertBool "reviewed Service lost accepted topic ordering or generated env"
        (all (elem (OrderedAfter topicId) . (^. #dependencies)) topicServiceMembers
          && any (BS.isInfixOf "NAGARE_TOPIC_JOBS" . snd) (Map.elems topicServiceNative))
      (topicAppScope, topicAppNative) <- either (fail . ("topic: " <>) . show) pure
        (compileApplicationScope topicInput)
      let topicAppWorkloads = [member | bundle <- scopeBundles topicAppScope,
            Managed member <- declarations bundle,
            case member ^. #address of
              Resource.Kubernetes _ "serving.knative.dev" kind _ _ -> kind == unsafe (Resource.mkName "service")
              Resource.Kubernetes _ "apps" kind _ _ -> kind == unsafe (Resource.mkName "deployment")
              _ -> False]
      assertBool "reviewed application lost accepted topic ordering or generated env"
        (all (elem (OrderedAfter topicId) . (^. #dependencies)) topicAppWorkloads
          && any (BS.isInfixOf "NAGARE_TOPIC_JOBS" . snd) (Map.elems topicAppNative))
      assertBool "topic-bearing worker accepted a missing topic declaration"
        (isLeft (compileStandaloneWorkerWithDependencies standaloneOwner topicWorker workerRollout
          cluster namespaceId publication Map.empty Map.empty topicServices Map.empty Map.empty (scopeSource input)))
      topicReadySnapshot <- either (fail . show) pure (mkScopeSnapshot historyBinding
        (Map.fromList [(foundation, (databaseGeneration, prerequisiteScope))
          , (brokerOwner, (databaseGeneration, topicBrokerScope))]) Map.empty)
      topicCandidate <- either (fail . show) pure (composeInventory topicReadySnapshot
        (ReplaceScope topicWorkerScope :| []))
      Map.lookup brokerOwner (candidateGenerations topicCandidate) @?= Just databaseGeneration
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
            , scopeInputOverrides = Map.insert "requestNamespace" "true" (scopeInputOverrides input)
            , scopeRelease = (emptyReleaseLog, release
                & #namespace .~ "sandbox"
                & #url .~ maybe "" (\service -> serviceUrl service
                    (testEnv ^. #baseDomain)) (sandboxApp ^. #service))
            }
      (sandboxScope, _) <- either (fail . ("sandbox: " <>) . show) pure
        (compileApplicationScope sandboxInput)
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
            , scopeRelease = (emptyReleaseLog, release
                { siteName = name
                , url = maybe "" (\service -> serviceUrl service
                    (testEnv ^. #baseDomain)) (namedApplication name ^. #service)
                })
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
      (alphaScope, _) <- either (fail . ("alpha: " <>) . show) pure
        (compileApplicationScope (namedInput "alpha"))
      (betaScope, _) <- either (fail . ("beta: " <>) . show) pure
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
      (conflictingScope, _) <- either (fail . ("conflicting: " <>) . show) pure
        (compileApplicationScope ((namedInput "alpha")
          { scopeApplication = conflicting
          , scopeRelease = (emptyReleaseLog, release
              { siteName = "beta"
              , url = maybe "" (\service -> serviceUrl service
                  (testEnv ^. #baseDomain)) (conflicting ^. #service)
              })
          }))
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
      (secretScope, _) <- either (fail . ("secret: " <>) . show) pure
        (compileApplicationScope secretInput)
      length [() | bundle <- scopeBundles secretScope, Managed member <- declarations bundle,
        OrderedAfter secretId `elem` member ^. #dependencies] @?= 4
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
          (ownScope, _) <- either (fail . ("own secret: " <>) . show) pure
            (compileApplicationScope ownSecretInput)
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
              length workloads @?= 4
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
