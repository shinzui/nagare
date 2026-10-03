module DataFenceSpec (dataFenceTests) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecode, eitherDecodeStrict', encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (elemIndex, find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import InventoryTransactionSpec
  ( fixtureBinding
  , preparedFixtureWithRegistry
  , recordingRegistryWith
  )
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (AdapterExecution (..), AdapterFence (..), OperationAction (..), PlannedOperation (..), RecoveryDecision (..), ResourceObservation (..), mkAdapterRegistry, observationSet, withAdapterFence)
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence
import Nagare.Inventory.DataFence.CompletedJob
import Nagare.Inventory.DataFence.DatabaseShutdown
import Nagare.Inventory.DataFence.DeploymentWriter qualified as Deployment
import Nagare.Inventory.DataFence.GuardAuthority
import Nagare.Inventory.DataFence.KubernetesAdapter
import Nagare.Inventory.DataFence.KubernetesCapture
import Nagare.Inventory.DataFence.KubernetesExclusion
import Nagare.Inventory.DataFence.KubernetesIntent
import Nagare.Inventory.DataFence.MountGuard
import Nagare.Inventory.DataFence.MountGuardRuntime
import Nagare.Inventory.DataFence.ScheduledWriter
import Nagare.Inventory.DataFence.ServiceState
import Nagare.Inventory.DataFence.StatefulWriter
import Nagare.Inventory.DataFence.VolumeState
import Nagare.Inventory.DataFence.WriterInventory
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute
  ( AdmissionError (..)
  , OperatorRecoveryInput (..)
  , RecoveryAction (..)
  , TransactionResult (..)
  , admit
  , applyReviewed
  , execute
  , recordOperatorRecovery
  , resumeTransaction
  )
import Nagare.Inventory.Journal (FailureClass (..), transactionIdText)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
  ( DataPolicy (Stateless)
  , LifecyclePolicy (Retain)
  , RecoveryClass (VerifyBeforeRetry)
  , Sensitivity (Public)
  )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

dataFenceTests :: TestTree
dataFenceTests =
  testGroup
    "data fence"
    [ testCase "native database exclusion drains a mounted PVC and Service" $ do
        selectedContext <- lookupEnv "NAGARE_EP160_EXCLUSION_CONTEXT"
        selectedNamespace <- lookupEnv "NAGARE_EP160_EXCLUSION_NAMESPACE"
        selectedEngine <- lookupEnv "NAGARE_EP160_EXCLUSION_ENGINE"
        selectedNode <- lookupEnv "NAGARE_EP160_EXCLUSION_NODE"
        selectedVolumePath <- lookupEnv "NAGARE_EP160_EXCLUSION_PV_PATH"
        selectedEvidenceRoot <- lookupEnv "NAGARE_EP160_EVIDENCE_ROOT"
        case ( selectedContext
             , selectedNamespace
             , selectedEngine
             , selectedNode
             , selectedVolumePath
             ) of
          (Nothing, Nothing, Nothing, Nothing, Nothing) -> pure ()
          ( Just contextName
            , Just namespaceName
            , Just engineName
            , Just nodeName
            , Just volumePath
            ) -> do
              evidenceRoot <-
                maybe
                  ( assertFailure "native evidence root is missing"
                      >> error "evidence root"
                  )
                  pure
                  selectedEvidenceRoot
              engine <- case engineName of
                "postgres" -> pure Postgres
                "redis" -> pure Redis
                "clickhouse" -> pure ClickHouse
                _ -> assertFailure "unknown native exclusion engine" >> error "unknown engine"
              let ContextBinding context _ = fixtureBinding
                  namespace = T.pack namespaceName
                  cluster =
                    mintResourceId
                      fenceOwner
                      (known (mkLogicalKey "cluster"))
                      (known (mkName "cluster"))
                  root =
                    mintResourceId
                      fenceOwner
                      (known (mkLogicalKey "database"))
                      (known (mkName "statefulset"))
                  route =
                    mintResourceId
                      fenceOwner
                      (known (mkLogicalKey "database-route"))
                      (known (mkName "service"))
                  client =
                    mintResourceId
                      fenceOwner
                      (known (mkLogicalKey "client"))
                      (known (mkName "deployment"))
                  schedule =
                    mintResourceId
                      fenceOwner
                      (known (mkLogicalKey "backup"))
                      (known (mkName "cronjob"))
                  member resource group kind name deps value =
                    let bytes = BL.toStrict (encode value)
                        spec =
                          if kind == "statefulset"
                            then StatefulSet 1 [] (contentDigest bytes)
                            else NativeObject (contentDigest bytes)
                     in ( resource
                        ,
                          ( ManagedResource
                              resource
                              fenceOwner
                              KubernetesExecutor
                              ( Kubernetes
                                  cluster
                                  group
                                  (known (mkName kind))
                                  (Just (known (mkName namespace)))
                                  (known (mkName name))
                              )
                              []
                              spec
                              Retain
                              Stateless
                              Public
                              deps
                              []
                              (SourceLocation "native-exclusion-fixture" kind)
                          , bytes
                          )
                        )
                  getJson :: String -> String -> IO Value
                  getJson kind name = do
                    (code, output, stderrOutput) <-
                      readProcessWithExitCode
                        "kubectl"
                        [ "--context"
                        , contextName
                        , "-n"
                        , namespaceName
                        , "get"
                        , kind
                        , name
                        , "-o"
                        , "json"
                        ]
                        ""
                    code @?= ExitSuccess
                    case eitherDecode (BL8.pack output) of
                      Left reason -> assertFailure (stderrOutput <> reason) >> error reason
                      Right value -> pure value
                  config =
                    KubernetesRuntimeConfig
                      context
                      (T.pack contextName)
                      (pure (Right ()))
              claim <- getJson "pvc" "data-pvc"
              stateful <- getJson "statefulset" "database"
              service <- getJson "service" "database"
              deployment <- getJson "deployment" "database-client"
              cronjob <- getJson "cronjob" "nagare-dbbackup-database"
              markerJob <- getJson "job" "ep160-marker"
              let markerUid = case markerJob of
                    Object fields -> case KM.lookup "metadata" fields of
                      Just (Object metadata) -> case KM.lookup "uid" metadata of
                        Just (String uid) -> uid
                        _ -> error "marker Job has no UID"
                      _ -> error "marker Job has no metadata"
                    _ -> error "marker Job is malformed"
                  captureRequest =
                    KubernetesCaptureRequest
                      fixtureBinding
                      Map.empty
                      "native-exclusion-session"
                      target
                      root
                      (Just engine)
                      (Just route)
                      False
                      "fixture://recovery"
                      (contentDigest "fixture-recovery")
                      "system:serviceaccount:kube-system:statefulset-controller"
                      (Just "system:serviceaccount:kube-system:replicaset-controller")
                      ( Just
                          ( "ep160-marker"
                          , markerUid
                          , "system:serviceaccount:kube-system:job-controller"
                          )
                      )
              let acceptedNative =
                    Map.fromList
                      [ member target "" "persistentvolumeclaim" "data-pvc" [] claim
                      , member root "apps" "statefulset" "database" [] stateful
                      , member route "" "service" "database" [] service
                      , member
                          client
                          "apps"
                          "deployment"
                          "database-client"
                          [OrderedAfter route]
                          deployment
                      , member
                          schedule
                          "batch"
                          "cronjob"
                          "nagare-dbbackup-database"
                          [OrderedAfter root]
                          cronjob
                      ]
                  declarations = [Managed resource | (resource, _) <- Map.elems acceptedNative]
              record <-
                captureKubernetesFence
                  (kubectlKubernetesCaptureTransport config)
                  declarations
                  acceptedNative
                  captureRequest
                  >>= right
              verifications <- newIORef (0 :: Int)
              let provider = kubectlKubernetesExclusion config Map.empty declarations acceptedNative
                  verify _ = do
                    modifyIORef' verifications (+ 1)
                    (code, output, _) <-
                      readProcessWithExitCode
                        "docker"
                        ["exec", nodeName, "cat", volumePath <> "/recovery-marker"]
                        ""
                    pure
                      ( Right
                          ( code == ExitSuccess
                              && output == "ep160-recovered-" <> engineName
                          )
                      )
                  controls = kubernetesDataFenceControls provider verify
              validateFenceInputs controls record >>= right
              let protectedGuard =
                    kubernetesMountGuard
                      (known (decodeKubernetesFenceIntent record))
                  defaultPrincipal = "system:serviceaccount:" <> namespace <> ":default"
                  authority = kubectlGuardAccessTransport config
                  runKube arguments input = do
                    (code, _, errorOutput) <-
                      readProcessWithExitCode
                        "kubectl"
                        (["--context", contextName] <> arguments)
                        input
                    assertEqual errorOutput ExitSuccess code
                  role =
                    object
                      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
                      , "kind" .= ("ClusterRole" :: Text)
                      , "metadata" .= object ["name" .= ("ep160-guard-editor" :: Text)]
                      , "rules"
                          .= [ object
                                 [ "apiGroups" .= (["admissionregistration.k8s.io"] :: [Text])
                                 , "resources" .= (["validatingadmissionpolicies"] :: [Text])
                                 , "resourceNames" .= [mountGuardName protectedGuard]
                                 , "verbs" .= (["patch"] :: [Text])
                                 ]
                             ]
                      ]
                  editorBinding =
                    object
                      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
                      , "kind" .= ("ClusterRoleBinding" :: Text)
                      , "metadata" .= object ["name" .= ("ep160-guard-editor" :: Text)]
                      , "roleRef"
                          .= object
                            [ "apiGroup" .= ("rbac.authorization.k8s.io" :: Text)
                            , "kind" .= ("ClusterRole" :: Text)
                            , "name" .= ("ep160-guard-editor" :: Text)
                            ]
                      , "subjects"
                          .= [ object
                                 [ "kind" .= ("ServiceAccount" :: Text)
                                 , "name" .= ("default" :: Text)
                                 , "namespace" .= namespace
                                 ]
                             ]
                      ]
                  collectionRole =
                    object
                      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
                      , "kind" .= ("ClusterRole" :: Text)
                      , "metadata" .= object ["name" .= ("ep160-guard-collection-editor" :: Text)]
                      , "rules"
                          .= [ object
                                 [ "apiGroups" .= (["admissionregistration.k8s.io"] :: [Text])
                                 , "resources" .= (["validatingadmissionpolicybindings"] :: [Text])
                                 , "verbs" .= (["deletecollection"] :: [Text])
                                 ]
                             ]
                      ]
                  collectionBinding =
                    object
                      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
                      , "kind" .= ("ClusterRoleBinding" :: Text)
                      , "metadata" .= object ["name" .= ("ep160-guard-collection-editor" :: Text)]
                      , "roleRef"
                          .= object
                            [ "apiGroup" .= ("rbac.authorization.k8s.io" :: Text)
                            , "kind" .= ("ClusterRole" :: Text)
                            , "name" .= ("ep160-guard-collection-editor" :: Text)
                            ]
                      , "subjects"
                          .= [ object
                                 [ "kind" .= ("ServiceAccount" :: Text)
                                 , "name" .= ("default" :: Text)
                                 , "namespace" .= namespace
                                 ]
                             ]
                      ]
                  pollAuthority _ 0 = assertFailure "guard RBAC result did not converge"
                  pollAuthority expected attempts = do
                    observed <-
                      observeGuardAuthority
                        authority
                        [defaultPrincipal]
                        protectedGuard
                        >>= right
                    if observed == expected
                      then pure ()
                      else do
                        threadDelay 200000
                        pollAuthority expected (attempts - 1)
              pollAuthority True (10 :: Int)
              runKube ["create", "-f", "-"] (BL8.unpack (encode role))
              runKube ["create", "-f", "-"] (BL8.unpack (encode editorBinding))
              pollAuthority False (10 :: Int)
              runKube ["delete", "clusterrolebinding", "ep160-guard-editor"] ""
              runKube ["delete", "clusterrole", "ep160-guard-editor"] ""
              pollAuthority True (10 :: Int)
              runKube ["create", "-f", "-"] (BL8.unpack (encode collectionRole))
              runKube ["create", "-f", "-"] (BL8.unpack (encode collectionBinding))
              pollAuthority False (10 :: Int)
              runKube ["delete", "clusterrolebinding", "ep160-guard-collection-editor"] ""
              runKube ["delete", "clusterrole", "ep160-guard-collection-editor"] ""
              pollAuthority True (10 :: Int)
              reviewOnly <- lookupEnv "NAGARE_EP160_REVIEW_ONLY"
              when (reviewOnly /= Just "1") $ withSystemTempDirectory "nagare-native-fence" $ \rootPath -> do
                store <- openFilesystemStore rootPath >>= right
                _ <- initializeStore store fixtureBinding "native-fixture" >>= right
                let interrupted =
                      controls
                        { stopFenceWriters = \_ -> pure (Left "fixture interrupted after reservation")
                        }
                firstAttempt <-
                  withProcessLock
                    store
                    ( \locked ->
                        acquireDataFence locked interrupted record
                    )
                    >>= right
                case firstAttempt of
                  Left reason -> reason @?= "fixture interrupted after reservation"
                  Right _ -> assertFailure "interrupted acquisition claimed exclusion"
                active <-
                  readHead store
                    >>= right
                    >>= maybe
                      (assertFailure "native fence reservation is missing" >> error "missing head")
                      pure
                assertBool
                  "interrupted native acquisition was not persisted"
                  ( maybe
                      False
                      ( \saved ->
                          fenceSession saved == fenceSession record
                            && fencePhase saved == FenceAcquiring
                      )
                      (headDataFence active)
                  )
                let scheduleUid =
                      maybe
                        (error "native fixture schedule UID is missing")
                        physicalIdentityText
                        (Map.lookup schedule (fencePhysical record))
                    activeJob =
                      object
                        [ "apiVersion" .= ("batch/v1" :: Text)
                        , "kind" .= ("Job" :: Text)
                        , "metadata"
                            .= object
                              [ "name" .= ("ep160-active-backup" :: Text)
                              , "namespace" .= namespace
                              , "ownerReferences"
                                  .= [ object
                                         [ "apiVersion" .= ("batch/v1" :: Text)
                                         , "kind" .= ("CronJob" :: Text)
                                         , "name" .= ("nagare-dbbackup-database" :: Text)
                                         , "uid" .= scheduleUid
                                         , "controller" .= True
                                         ]
                                     ]
                              ]
                        , "spec"
                            .= object
                              [ "template"
                                  .= object
                                    [ "spec"
                                        .= object
                                          [ "restartPolicy" .= ("Never" :: Text)
                                          , "containers"
                                              .= [ object
                                                     [ "name" .= ("backup" :: Text)
                                                     , "image" .= ("busybox:1.36" :: Text)
                                                     , "command"
                                                         .= ( [ "sh"
                                                              , "-c"
                                                              , "touch /mount/active-backup-marker && sleep 3600"
                                                              ] ::
                                                                [Text]
                                                            )
                                                     , "volumeMounts"
                                                         .= [ object
                                                                [ "name" .= ("data" :: Text)
                                                                , "mountPath" .= ("/mount" :: Text)
                                                                ]
                                                            ]
                                                     ]
                                                 ]
                                          , "volumes"
                                              .= [ object
                                                     [ "name" .= ("data" :: Text)
                                                     , "persistentVolumeClaim"
                                                         .= object
                                                           ["claimName" .= ("data-pvc" :: Text)]
                                                     ]
                                                 ]
                                          ]
                                    ]
                              ]
                        ]
                    waitActiveJob 0 = assertFailure "fixture backup Job never became active"
                    waitActiveJob attempts = do
                      observed <- getJson "job" "ep160-active-backup"
                      let activeCount = case observed of
                            Object fields -> case KM.lookup "status" fields of
                              Just (Object status) -> KM.lookup "active" status
                              _ -> Nothing
                            _ -> Nothing
                      if activeCount == Just (toJSON (1 :: Int))
                        then pure ()
                        else do
                          threadDelay 500000
                          waitActiveJob (attempts - 1)
                runKube ["create", "-f", "-"] (BL8.unpack (encode activeJob))
                waitActiveJob (30 :: Int)
                runKube
                  [ "-n"
                  , namespaceName
                  , "wait"
                  , "pod"
                  , "-l"
                  , "batch.kubernetes.io/job-name=ep160-active-backup"
                  , "--for=condition=Ready"
                  , "--timeout=60s"
                  ]
                  ""
                runKube
                  [ "-n"
                  , namespaceName
                  , "exec"
                  , "job/ep160-active-backup"
                  , "--"
                  , "test"
                  , "-f"
                  , "/mount/active-backup-marker"
                  ]
                  ""
                reopened <- openFilesystemStore rootPath >>= right
                token <-
                  withProcessLock
                    reopened
                    ( \locked ->
                        resumeDataFence locked (fenceSession record)
                    )
                    >>= right
                    >>= right
                let freshProvider =
                      kubectlKubernetesExclusion
                        config
                        Map.empty
                        declarations
                        acceptedNative
                    freshControls = kubernetesDataFenceControls freshProvider verify
                    proveActiveJob 0 =
                      assertFailure
                        "running backup Job did not hold the fence acquiring"
                    proveActiveJob attempts = do
                      waiting <-
                        withProcessLock
                          reopened
                          ( \locked ->
                              resumeDataFenceAcquisition locked freshControls token
                          )
                          >>= right
                      case waiting of
                        Left "managed database clients have not drained" -> pure ()
                        Left _ -> threadDelay 1000000 >> proveActiveJob (attempts - 1)
                        Right () ->
                          assertFailure
                            "native fence acquired while an owned backup Job was active"
                    pollAcquired 0 = assertFailure "persisted native fence never acquired exclusion"
                    pollAcquired attempts = do
                      current <-
                        readHead reopened
                          >>= right
                          >>= maybe
                            (assertFailure "native fence head disappeared" >> error "missing head")
                            pure
                      case fmap fencePhase (headDataFence current) of
                        Just FenceExcluded -> pure ()
                        Just FenceAcquiring -> do
                          _ <-
                            withProcessLock
                              reopened
                              ( \locked ->
                                  resumeDataFenceAcquisition locked freshControls token
                              )
                              >>= right
                          threadDelay 1000000
                          pollAcquired (attempts - 1)
                        _ -> assertFailure "native fence left its acquisition phase"
                proveActiveJob (4 :: Int)
                whileRunning <-
                  readHead reopened
                    >>= right
                    >>= maybe
                      ( assertFailure "native fence disappeared with an active Job"
                          >> error "missing head"
                      )
                      pure
                fmap fencePhase (headDataFence whileRunning) @?= Just FenceAcquiring
                runKube
                  [ "-n"
                  , namespaceName
                  , "delete"
                  , "job"
                  , "ep160-active-backup"
                  , "--cascade=foreground"
                  , "--wait=true"
                  ]
                  ""
                pollAcquired (120 :: Int)
                observeFencePhysical freshControls record
                  >>= right
                  >>= (@?= fencePhysical record)
                verifyRecoveredData freshControls record >>= right >>= (@?= False)
                _ <-
                  withProcessLock
                    reopened
                    ( \locked ->
                        beginDataChange locked freshControls token
                    )
                    >>= right
                    >>= right
                wrongMarker <-
                  withProcessLock
                    reopened
                    ( \locked ->
                        verifyDataChange locked freshControls token
                    )
                    >>= right
                wrongMarker @?= Left "restored data and health are not verified"
                refusedRelease <-
                  withProcessLock
                    reopened
                    ( \locked ->
                        releaseDataFence locked freshControls token
                    )
                    >>= right
                refusedRelease @?= Left "data fence requires verified recovery before writer release"
                runKube
                  [ "-n"
                  , namespaceName
                  , "patch"
                  , "job"
                  , "ep160-marker"
                  , "--type=merge"
                  , "-p"
                  , "{\"spec\":{\"suspend\":false}}"
                  ]
                  ""
                runKube
                  [ "-n"
                  , namespaceName
                  , "wait"
                  , "job/ep160-marker"
                  , "--for=condition=Complete"
                  , "--timeout=120s"
                  ]
                  ""
                runKube
                  [ "-n"
                  , namespaceName
                  , "delete"
                  , "job"
                  , "ep160-marker"
                  , "--cascade=foreground"
                  , "--wait=true"
                  ]
                  ""
                _ <-
                  withProcessLock
                    reopened
                    ( \locked ->
                        recoverDataFence locked freshControls token
                    )
                    >>= right
                    >>= right
                let interruptedRelease =
                      freshControls
                        { restoreFenceWriters = \_ -> pure (Left "fixture interrupted before release effect")
                        }
                firstRelease <-
                  withProcessLock
                    reopened
                    ( \locked ->
                        releaseDataFence locked interruptedRelease token
                    )
                    >>= right
                case firstRelease of
                  Left reason -> reason @?= "fixture interrupted before release effect"
                  Right () -> assertFailure "interrupted release cleared the native fence"
                releaseStore <- openFilesystemStore rootPath >>= right
                releaseToken <-
                  withProcessLock
                    releaseStore
                    ( \locked ->
                        resumeDataFence locked (fenceSession record)
                    )
                    >>= right
                    >>= right
                let releaseProvider =
                      kubectlKubernetesExclusion
                        config
                        Map.empty
                        declarations
                        acceptedNative
                    releaseControls = kubernetesDataFenceControls releaseProvider verify
                    pollReleased 0 = assertFailure "persisted native fence never released"
                    pollReleased attempts = do
                      current <-
                        readHead releaseStore
                          >>= right
                          >>= maybe
                            (assertFailure "native fence head disappeared" >> error "missing head")
                            pure
                      case headDataFence current of
                        Nothing -> pure ()
                        Just saved | fencePhase saved == FenceReleasing -> do
                          state <- observeWritersReleased releaseControls saved >>= right
                          _ <-
                            withProcessLock
                              releaseStore
                              ( \locked ->
                                  case state of
                                    WritersPartlyReleased ->
                                      forwardRecoverDataFenceRelease
                                        locked
                                        releaseControls
                                        releaseToken
                                    _ -> releaseDataFence locked releaseControls releaseToken
                              )
                              >>= right
                          threadDelay 1000000
                          pollReleased (attempts - 1)
                        Just _ -> assertFailure "native fence did not enter release"
                pollReleased (120 :: Int)
                readIORef verifications >>= \count ->
                  assertBool
                    "native fence released without recovered-data verification"
                    (count >= 2)
              reviewedJob <- getJson "job" "ep160-reviewed-marker"
              let reviewedJobUid = case reviewedJob of
                    Object fields -> case KM.lookup "metadata" fields of
                      Just (Object metadata) -> case KM.lookup "uid" metadata of
                        Just (String uid) -> uid
                        _ -> error "reviewed marker Job has no UID"
                      _ -> error "reviewed marker Job has no metadata"
                    _ -> error "reviewed marker Job is malformed"
                  reviewedRequest accepted =
                    captureRequest
                      { captureAccepted = accepted
                      , captureSession = "reviewed-native-session"
                      , captureRestoreJob =
                          Just
                            ( "ep160-reviewed-marker"
                            , reviewedJobUid
                            , "system:serviceaccount:kube-system:job-controller"
                            )
                      }
                  reviewedMarker = do
                    (code, output, _) <-
                      readProcessWithExitCode
                        "docker"
                        ["exec", nodeName, "cat", volumePath <> "/reviewed-marker"]
                        ""
                    pure (code == ExitSuccess && output == "ep160-reviewed-" <> engineName)
                  operationId =
                    mintResourceId
                      fenceOwner
                      (known (mkLogicalKey "reviewed-marker"))
                      (known (mkName "proof"))
                  markerOperation =
                    DeclaredOperation
                      operationId
                      (target :| [])
                      [ContentInput (contentDigest "ep160-reviewed-marker")]
                      VerifyBeforeRetry
                      RestoreData
                  baseBundle = ResourceBundle declarations [] [] [] [] []
                  reviewedBundle =
                    ResourceBundle
                      declarations
                      []
                      []
                      []
                      [markerOperation]
                      []
              baseScope <- right (mkScopeDeclaration fenceOwner [baseBundle])
              nextScope <- right (mkScopeDeclaration fenceOwner [reviewedBundle])
              snapshot <-
                right
                  ( mkScopeSnapshot
                      fixtureBinding
                      (Map.singleton fenceOwner (known (mkScopeGeneration 1), baseScope))
                      Map.empty
                  )
              seedScope <-
                right
                  ( mkScopeDeclaration
                      (known (mkScopeId Standalone "fixture-seed"))
                      []
                  )
              baseCandidate <-
                right
                  ( composeInventory
                      snapshot
                      (ReplaceScope seedScope :| [])
                  )
              candidate <- right (composeInventory snapshot (ReplaceScope nextScope :| []))
              let reviewRoot = evidenceRoot <> "/" <> engineName <> "-review-store"
              reviewStore <- openFilesystemStore reviewRoot >>= right
              _ <- initializeStore reviewStore fixtureBinding "reviewed-native-fixture" >>= right
              _ <- seedInventoryHistory reviewStore baseCandidate >>= right
              history <- loadInventoryHistory reviewStore >>= right
              let required = requiredResources (observationRequirements candidate history)
                  observed =
                    known
                      ( observationSet
                          [ ( resource
                            , ObservedPresent
                                ( Map.findWithDefault
                                    (known (mkPhysicalIdentity "fixture-observed"))
                                    resource
                                    (fencePhysical record)
                                )
                            )
                          | resource <- Set.toAscList required
                          ]
                      )
              proposal <- right (planChanges candidate noLifecycleDecisions history observed)
              candidateDesiredRevisions candidate @?= proposalDesired proposal
              captures <- newIORef (0 :: Int)
              effects <- newIORef (0 :: Int)
              let accepted = proposalDesired proposal
                  proof = contentDigest "ep160-reviewed-marker-proof"
                  isMarker operation =
                    plannedAction operation == RunDeclaredOperation
                      && target `elem` toList (plannedResources operation)
                  effect operation _
                    | isMarker operation = do
                        modifyIORef' effects (+ 1)
                        runKube
                          [ "-n"
                          , namespaceName
                          , "patch"
                          , "job"
                          , "ep160-reviewed-marker"
                          , "--type=merge"
                          , "-p"
                          , "{\"spec\":{\"suspend\":false}}"
                          ]
                          ""
                        runKube
                          [ "-n"
                          , namespaceName
                          , "wait"
                          , "job/ep160-reviewed-marker"
                          , "--for=condition=Complete"
                          , "--timeout=120s"
                          ]
                          ""
                        let podField path =
                              readProcessWithExitCode
                                "kubectl"
                                [ "--context"
                                , contextName
                                , "-n"
                                , namespaceName
                                , "get"
                                , "pod"
                                , "-l"
                                , "batch.kubernetes.io/job-name=ep160-reviewed-marker"
                                , "-o"
                                , "jsonpath=" <> path
                                ]
                                ""
                        (accountCode, account, accountError) <-
                          podField
                            "{.items[0].spec.serviceAccountName}"
                        assertEqual accountError ExitSuccess accountCode
                        account @?= "default"
                        (ownerCode, ownerUid, ownerError) <-
                          podField
                            "{.items[0].metadata.ownerReferences[0].uid}"
                        assertEqual ownerError ExitSuccess ownerCode
                        ownerUid @?= T.unpack reviewedJobUid
                        runKube
                          [ "-n"
                          , namespaceName
                          , "delete"
                          , "job"
                          , "ep160-reviewed-marker"
                          , "--cascade=foreground"
                          , "--wait=true"
                          ]
                          ""
                        pure (AdapterEffectAmbiguous "fixture lost marker write acknowledgement")
                    | otherwise =
                        pure
                          ( AdapterEffectFailed
                              (KnownNoEffect "unexpected reviewed operation")
                          )
                  recover operation _
                    | isMarker operation = do
                        good <- reviewedMarker
                        pure
                          ( if good
                              then RecoveryProvedComplete proof
                              else RecoveryUnresolved "reviewed marker is missing or wrong"
                          )
                    | otherwise = pure (RecoveryUnresolved "unexpected reviewed operation")
                  baseRegistry =
                    recordingRegistryWith
                      (\_ _ -> pure (Right ()))
                      effect
                      recover
                  replay saved operation _ = do
                    unless
                      ( isMarker operation
                          && fenceSession saved == "reviewed-native-session"
                          && fenceTargets saved == Set.singleton target
                          && fencePhysical saved == fencePhysical record
                      )
                      (Left "reviewed marker operation or target identity changed")
                  selectedFactory =
                    KubernetesFenceFactory
                      config
                      fixtureBinding
                      accepted
                      declarations
                      acceptedNative
                      ( \operation _ ->
                          if isMarker operation
                            then do
                              modifyIORef' captures (+ 1)
                              pure (Right (Just (reviewedRequest accepted)))
                            else pure (Right Nothing)
                      )
                      replay
                      (\_ -> Right <$> reviewedMarker)
                      Nothing
                      Nothing
                      Nothing
                  planningRegistry =
                    known
                      ( registerKubernetesDataFence
                          selectedFactory
                          baseRegistry
                      )
              beforeReview <- readStoreSnapshot reviewStore >>= right
              plannedReview <- prepareReview planningRegistry beforeReview proposal >>= right
              reviewId <- publishReview reviewStore plannedReview >>= right
              let publicPath = evidenceRoot <> "/" <> engineName <> "-public-review"
              _ <- writeReviewBundle publicPath plannedReview >>= right
              publicReview <- loadReviewBundle publicPath >>= right
              reviewBundleNative publicReview @?= Map.empty
              readIORef captures >>= (@?= 1)
              freshStore <- openFilesystemStore reviewRoot >>= right
              privateReview <- loadPublishedReview freshStore reviewId >>= right
              case [ selected
                   | selected <- reviewOperations (reviewBundleDocument privateReview)
                   , isMarker (reviewPlannedOperation selected)
                   ] of
                [selected] -> case reviewBundleFenceRecord privateReview selected of
                  Right (Just saved) -> do
                    fenceSession saved @?= "reviewed-native-session"
                    fencePhysical saved @?= fencePhysical record
                  _ -> assertFailure "private reviewed fence member is missing"
                _ -> assertFailure "saved review lacks one marker operation"
              readySnapshot <- readStoreSnapshot freshStore >>= right
              reviewed <- right (verifyReview readySnapshot privateReview)
              let replayFactory =
                    selectedFactory
                      { factorySelect = \_ _ ->
                          pure
                            ( Left
                                "planning capture must not run during apply"
                            )
                      }
                  replayRegistry =
                    known
                      ( registerKubernetesDataFence
                          replayFactory
                          baseRegistry
                      )
              missing <- applyReviewed freshStore baseRegistry reviewed
              case missing of
                Left errors ->
                  assertBool
                    "missing native capability admitted review"
                    (any ((== "data-fence-capability") . admissionErrorCode) errors)
                Right _ -> assertFailure "review applied without its native fence"
              wrongRevision <-
                applyReviewed
                  freshStore
                  ( known
                      ( registerKubernetesDataFence
                          (replayFactory {factoryAccepted = Map.empty})
                          baseRegistry
                      )
                  )
                  reviewed
              case wrongRevision of
                Left errors ->
                  assertBool
                    "changed accepted revision admitted review"
                    (any ((== "data-fence-capability") . admissionErrorCode) errors)
                Right _ -> assertFailure "review applied with changed revisions"
              wrongContext <-
                applyReviewed
                  freshStore
                  ( known
                      ( registerKubernetesDataFence
                          ( replayFactory
                              { factoryBinding =
                                  ContextBinding
                                    (known (mkContextId "foreign-fence"))
                                    (known (mkName "project"))
                              }
                          )
                          baseRegistry
                      )
                  )
                  reviewed
              case wrongContext of
                Left errors ->
                  assertBool
                    "changed context admitted review"
                    (any ((== "data-fence-capability") . admissionErrorCode) errors)
                Right _ -> assertFailure "review applied in another context"
              let wrongPhysical =
                    Map.insert
                      target
                      (known (mkPhysicalIdentity "foreign-pvc-uid"))
                      (fencePhysical record)
                  wrongTargetFactory =
                    replayFactory
                      { factoryReplay = \saved operation prepared -> do
                          replay saved operation prepared
                          unless
                            (fencePhysical saved == wrongPhysical)
                            (Left "reviewed target incarnation changed")
                      }
              wrongTarget <-
                applyReviewed
                  freshStore
                  (known (registerKubernetesDataFence wrongTargetFactory baseRegistry))
                  reviewed
              case wrongTarget of
                Left errors ->
                  assertBool
                    "changed target admitted review"
                    (any ((== "data-fence-capability") . admissionErrorCode) errors)
                Right _ -> assertFailure "review applied to another target"
              readIORef effects >>= (@?= 0)
              outcome <- applyReviewed freshStore replayRegistry reviewed >>= right
              (transaction, selectedOperation) <- case outcome of
                StoppedAmbiguous transaction operation -> pure (transaction, operation)
                _ ->
                  assertFailure "lost marker acknowledgement did not stop review"
                    >> error "transaction"
              recoveringStore <- openFilesystemStore reviewRoot >>= right
              let pollRecovered 0 = assertFailure "reviewed native fence did not recover"
                  pollRecovered attempts = do
                    current <-
                      readHead recoveringStore
                        >>= right
                        >>= maybe
                          (assertFailure "reviewed native head disappeared" >> error "head")
                          pure
                    case headDataFence current of
                      Nothing -> pure ()
                      Just active -> do
                        action <- case fencePhase active of
                          FenceAcquiring -> pure ContinueFencedOperation
                          FenceExcluded -> pure ContinueFencedOperation
                          FenceChanging -> pure VerifyFencedEffect
                          FenceUnresolved -> pure VerifyFencedEffect
                          FenceVerifying -> pure VerifyFencedEffect
                          FenceReleasing -> do
                            state <-
                              observeKubernetesRelease
                                ( kubectlKubernetesExclusion
                                    config
                                    accepted
                                    declarations
                                    acceptedNative
                                )
                                active
                                >>= right
                            pure
                              ( if state == WritersPartlyReleased
                                  then ForwardFencedRelease
                                  else VerifyFencedEffect
                              )
                        let decision =
                              OperatorRecoveryInput
                                transaction
                                selectedOperation
                                reviewId
                                action
                        attempt <-
                          recordOperatorRecovery
                            recoveringStore
                            replayRegistry
                            decision
                            False
                        case attempt of
                          Left errors ->
                            assertBool
                              "reviewed recovery refused unexpectedly"
                              ( all
                                  ( (`elem` ["data-fence", "adapter-recovery"])
                                      . admissionErrorCode
                                  )
                                  (toList errors)
                              )
                          Right () -> pure ()
                        threadDelay 1000000
                        pollRecovered (attempts - 1)
              pollRecovered (180 :: Int)
              resumeTransaction recoveringStore replayRegistry transaction >>= right >>= \case
                Converged _ -> pure ()
                _ -> assertFailure "reviewed native transaction did not converge"
              readIORef captures >>= (@?= 1)
              readIORef effects >>= (@?= 1)
              writeFile
                (evidenceRoot <> "/" <> engineName <> "-review.txt")
                ( "review="
                    <> show reviewId
                    <> "\ntransaction="
                    <> show transaction
                    <> "\noperation="
                    <> show selectedOperation
                    <> "\nstore="
                    <> reviewRoot
                    <> "\npublic="
                    <> publicPath
                    <> "\nclaimUid="
                    <> show (Map.lookup target (fencePhysical record))
                    <> "\nwriterUid="
                    <> show (Map.lookup root (fencePhysical record))
                    <> "\nrestoreJobUid="
                    <> T.unpack reviewedJobUid
                    <> "\n"
                )
          _ -> assertFailure "native exclusion context, namespace, and engine must be set together"
    , testCase "engine shutdown observes a clean exit on an explicitly selected native fixture" $ do
        selectedContext <- lookupEnv "NAGARE_EP160_SHUTDOWN_CONTEXT"
        selectedNamespace <- lookupEnv "NAGARE_EP160_SHUTDOWN_NAMESPACE"
        case (selectedContext, selectedNamespace) of
          (Nothing, Nothing) -> pure ()
          (Just contextName, Just namespaceName) -> do
            let ContextBinding context _ = fixtureBinding
                transport =
                  kubectlDatabaseShutdownTransport
                    ( KubernetesRuntimeConfig
                        context
                        (T.pack contextName)
                        (pure (Right ()))
                    )
            forM_
              [ ("postgres", Postgres, "postgres:18")
              , ("redis", Redis, "redis:8")
              , ("clickhouse", ClickHouse, "clickhouse/clickhouse-server:25.8")
              ]
              $ \(podName, engine, image) -> do
                (code, output, _) <-
                  readProcessWithExitCode
                    "kubectl"
                    [ "--context"
                    , contextName
                    , "-n"
                    , namespaceName
                    , "get"
                    , "pod"
                    , podName
                    , "-o"
                    , "jsonpath={.metadata.uid}"
                    ]
                    ""
                code @?= ExitSuccess
                let uid = T.pack output
                assertBool "native probe Pod UID is malformed" (validUid uid)
                wrongPod <-
                  sendDatabaseShutdown
                    transport
                    (T.pack namespaceName)
                    (T.pack podName)
                    "00000000-0000-0000-0000-000000000000"
                    engine
                    image
                case wrongPod of
                  Left _ -> pure ()
                  Right () -> assertFailure "shutdown accepted a substituted Pod UID"
                sendDatabaseShutdown
                  transport
                  (T.pack namespaceName)
                  (T.pack podName)
                  uid
                  engine
                  image
                  >>= right
          _ -> assertFailure "native shutdown context and namespace must be set together"
    , testCase "provider intent roundtrips and changes the reviewed digest" $ do
        let withProvider =
              request
                { fenceProviderIntent = Just (object ["version" .= (1 :: Int)])
                }
        eitherDecode (encode withProvider) @?= Right withProvider
        assertBool
          "provider intent must change the fence digest"
          (dataFenceIntentDigest withProvider /= dataFenceIntentDigest request)
    , testCase "accepted managed database image pins a supported engine" $ do
        let native container image =
              BL.toStrict
                ( encode
                    ( object
                        [ "kind" .= ("StatefulSet" :: Text)
                        , "metadata"
                            .= object
                              [ "labels"
                                  .= object
                                    ["nagare.dev/database" .= ("database" :: Text)]
                              ]
                        , "spec"
                            .= object
                              [ "template"
                                  .= object
                                    [ "spec"
                                        .= object
                                          [ "containers"
                                              .= [ object
                                                     ["name" .= (container :: Text), "image" .= (image :: Text)]
                                                 ]
                                          ]
                                    ]
                              ]
                        ]
                    )
                )
        mapM_
          ( \(container, image, engine) ->
              parseAcceptedDatabaseEngine (native container image)
                @?= Right (Just engine)
          )
          [ ("postgres", "postgres:18", Postgres)
          , ("redis", "redis:8", Redis)
          , ("clickhouse", "clickhouse/clickhouse-server:25.8", ClickHouse)
          ]
        validateReviewedDatabaseEngine
          (Just Postgres)
          (native "postgres" "postgres:18")
          @?= Right ()
        case validateReviewedDatabaseEngine
          (Just Redis)
          (native "postgres" "postgres:18") of
          Left _ -> pure ()
          Right _ -> assertFailure "reviewed engine substitution was accepted"
        case validateReviewedDatabaseEngine
          Nothing
          (native "postgres" "postgres:18") of
          Left _ -> pure ()
          Right _ -> assertFailure "managed database omitted its engine pin"
        case parseAcceptedDatabaseEngine (native "postgres" "redis:8") of
          Left _ -> pure ()
          Right _ -> assertFailure "mismatched server image was accepted"
        case parseAcceptedDatabaseEngine (native "postgres" "postgres:latest") of
          Left _ -> pure ()
          Right _ -> assertFailure "floating server image was accepted"
        parseAcceptedDatabaseEngine
          ( BL.toStrict
              ( encode
                  (object ["spec" .= object []])
              )
          )
          @?= Right Nothing
    , testCase "Kubernetes fence intent validates the complete durable native pin" $ do
        let pvcUid = "11111111-2222-3333-4444-555555555555"
            pvUid = "66666666-7777-8888-9999-000000000000"
            writerUid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            clusterId =
              mintResourceId
                fenceOwner
                (known (mkLogicalKey "cluster"))
                (known (mkName "cluster"))
            savedWriter =
              object
                [ "kind" .= ("StatefulSet" :: Text)
                , "namespace" .= ("restore-space" :: Text)
                , "name" .= ("database" :: Text)
                , "uid" .= (writerUid :: Text)
                , "replicas" .= (1 :: Int)
                , "specDigest" .= contentDigest "fixture-stateful-spec"
                , "mountsTarget" .= True
                ]
            provider =
              object
                [ "version" .= (3 :: Int)
                , "provider" .= ("kubernetes" :: Text)
                , "cluster" .= clusterId
                , "dependencyRoot" .= writer
                , "statefulControllerPrincipal"
                    .= ("system:serviceaccount:kube-system:statefulset-controller" :: Text)
                , "volume"
                    .= object
                      [ "resource" .= target
                      , "namespace" .= ("restore-space" :: Text)
                      , "claim" .= ("data-pvc" :: Text)
                      , "claimUid" .= (pvcUid :: Text)
                      , "pv" .= ("pv-data" :: Text)
                      , "pvUid" .= (pvUid :: Text)
                      , "backing"
                          .= object
                            [ "kind" .= ("local" :: Text)
                            , "path" .= ("/data/disk" :: Text)
                            , "node" .= ("node-a" :: Text)
                            ]
                      ]
                ]
            native =
              request
                { fencePhysical =
                    Map.fromList
                      [ (target, known (mkPhysicalIdentity pvcUid))
                      , (writer, known (mkPhysicalIdentity writerUid))
                      ]
                , fenceSavedWriters = Map.singleton writer savedWriter
                , fenceProviderIntent = Just provider
                }
        decoded <- right (decodeKubernetesFenceIntent native)
        kubernetesVolumeBacking decoded @?= LocalVolume "/data/disk" "node-a"
        map fst (kubernetesStatefulWriters decoded) @?= [writer]
        let (podPolicy, _) = mountGuardObjects (kubernetesMountGuard decoded)
            (releasePolicy, _) =
              mountGuardObjects
                (kubernetesReleaseMountGuard decoded)
        assertBool
          "acquisition guard must deny the saved writer controller"
          (not (writerUid `T.isInfixOf` T.pack (show podPolicy)))
        assertBool
          "release guard has a distinct admission address"
          ( mountGuardName (kubernetesMountGuard decoded)
              /= mountGuardName (kubernetesReleaseMountGuard decoded)
          )
        assertBool
          "release guard permits the exact saved writer owner"
          (writerUid `T.isInfixOf` T.pack (show releasePolicy))
        assertBool
          "release guard binds the authenticated controller"
          ( "system:serviceaccount:kube-system:statefulset-controller"
              `T.isInfixOf` T.pack (show releasePolicy)
          )
        statefulWriterGuardObjects (kubernetesReleaseMountGuard decoded) @?= []
        case statefulWriterGuardObjects (kubernetesMountGuard decoded) of
          [(writerPolicy, _), (scalePolicy, _)] -> do
            let rendered = T.pack (show writerPolicy)
                scaleRendered = T.pack (show scalePolicy)
            assertBool
              "writer guard covers the parent resource"
              ("\"statefulsets\"" `T.isInfixOf` rendered)
            assertBool
              "writer guard covers the scale subresource"
              ("statefulsets/scale" `T.isInfixOf` scaleRendered)
            assertBool
              "writer guard requires zero replicas"
              ("object.spec.replicas == 0" `T.isInfixOf` scaleRendered)
            assertBool
              "parent guard freezes a stopped writer spec"
              ("object.spec == oldObject.spec" `T.isInfixOf` rendered)
            assertBool
              "writer guard binds the saved UID"
              ( writerUid `T.isInfixOf` rendered
                  && writerUid `T.isInfixOf` scaleRendered
              )
          _ -> assertFailure "saved StatefulSet has no admission guard"
        let candidate =
              WriterCandidate
                writer
                StatefulSetWriter
                ( Kubernetes
                    clusterId
                    "apps"
                    (known (mkName "statefulset"))
                    (Just (known (mkName "restore-space")))
                    (known (mkName "database"))
                )
                True
                True
        _ <- right (validateKubernetesWriterInventory decoded [candidate])
        case validateKubernetesWriterInventory decoded [] of
          Left _ -> pure ()
          Right _ -> assertFailure "omitted accepted writer was accepted"
        case validateKubernetesWriterInventory
          decoded
          [candidate {candidateByMount = False}] of
          Left _ -> pure ()
          Right _ -> assertFailure "changed PVC mount was accepted"
        case validateKubernetesWriterInventory
          decoded
          [ candidate
              { candidateAddress =
                  Kubernetes
                    clusterId
                    "apps"
                    (known (mkName "statefulset"))
                    (Just (known (mkName "restore-space")))
                    (known (mkName "other"))
              }
          ] of
          Left _ -> pure ()
          Right _ -> assertFailure "changed writer address was accepted"
        let wrongPhysical =
              native
                { fencePhysical =
                    Map.insert
                      writer
                      (known (mkPhysicalIdentity "bbbbbbbb-2222-3333-4444-555555555555"))
                      (fencePhysical native)
                }
        case decodeKubernetesFenceIntent wrongPhysical of
          Left _ -> pure ()
          Right _ -> assertFailure "writer UID substitution was accepted"
        let unsupported =
              native
                { fenceSavedWriters =
                    Map.singleton
                      writer
                      ( case savedWriter of
                          Object fields -> Object (KM.insert "kind" (String "Deployment") fields)
                          other -> other
                      )
                }
        case decodeKubernetesFenceIntent unsupported of
          Left _ -> pure ()
          Right _ -> assertFailure "Deployment without a selector was accepted"
        let savedDeployment =
              object
                [ "kind" .= ("Deployment" :: Text)
                , "namespace" .= ("restore-space" :: Text)
                , "name" .= ("client" :: Text)
                , "uid" .= (writerUid :: Text)
                , "replicas" .= (1 :: Int)
                , "specDigest" .= contentDigest "fixture-deployment-spec"
                , "selector" .= Map.singleton ("app" :: Text) ("client" :: Text)
                , "mountsTarget" .= True
                , "replicaSet"
                    .= object
                      [ "name" .= ("client-abc123" :: Text)
                      , "uid" .= ("ffffffff-1111-2222-3333-444444444444" :: Text)
                      ]
                ]
            deploymentProvider = case provider of
              Object fields ->
                Object
                  ( KM.insert
                      "replicaSetControllerPrincipal"
                      (String "system:serviceaccount:kube-system:replicaset-controller")
                      fields
                  )
              other -> other
            deploymentNative =
              native
                { fenceSavedWriters = Map.singleton writer savedDeployment
                , fenceProviderIntent = Just deploymentProvider
                }
        deploymentIntent <- right (decodeKubernetesFenceIntent deploymentNative)
        map fst (kubernetesDeploymentWriters deploymentIntent) @?= [writer]
        let (deploymentReleasePolicy, _) =
              mountGuardObjects
                (kubernetesReleaseMountGuard deploymentIntent)
        assertBool
          "release guard lacks the exact ReplicaSet owner permit"
          ( "ffffffff-1111-2222-3333-444444444444"
              `T.isInfixOf` T.pack (show deploymentReleasePolicy)
          )
        assertBool
          "release guard lacks the authenticated ReplicaSet controller"
          ( "system:serviceaccount:kube-system:replicaset-controller"
              `T.isInfixOf` T.pack (show deploymentReleasePolicy)
          )
        let missingReplicaSet =
              deploymentNative
                { fenceSavedWriters =
                    Map.singleton
                      writer
                      ( case savedDeployment of
                          Object fields -> Object (KM.delete "replicaSet" fields)
                          other -> other
                      )
                }
        case decodeKubernetesFenceIntent missingReplicaSet of
          Left _ -> pure ()
          Right _ -> assertFailure "PVC-mounting Deployment omitted its ReplicaSet"
        let oldProvider =
              native
                { fenceProviderIntent =
                    Just
                      ( case provider of
                          Object fields -> Object (KM.insert "version" (toJSON (2 :: Int)) fields)
                          other -> other
                      )
                }
        case decodeKubernetesFenceIntent oldProvider of
          Left _ -> pure ()
          Right _ -> assertFailure "old Kubernetes fence intent bypassed release pinning"
        length
          ( deploymentWriterGuardObjects
              (kubernetesMountGuard deploymentIntent)
          )
          @?= 6
        let deploymentPin =
              known
                ( Deployment.mkDeploymentWriterPin
                    "restore-space"
                    "client"
                    writerUid
                    1
                    (contentDigest "fixture-deployment-spec")
                    (Map.singleton "app" "client")
                )
            deploymentTemplate =
              object
                [ "metadata"
                    .= object
                      [ "labels"
                          .= object
                            ["app" .= ("client" :: Text)]
                      ]
                , "spec"
                    .= object
                      [ "containers"
                          .= [ object
                                 [ "name" .= ("client" :: Text)
                                 , "image" .= ("busybox:1.36" :: Text)
                                 ]
                             ]
                      ]
                ]
            deploymentObject =
              object
                [ "spec"
                    .= object
                      ["template" .= deploymentTemplate]
                ]
            replicaTemplate image =
              object
                [ "metadata"
                    .= object
                      [ "labels"
                          .= object
                            [ "app" .= ("client" :: Text)
                            , "pod-template-hash" .= ("abc123" :: Text)
                            ]
                      ]
                , "spec"
                    .= object
                      [ "containers"
                          .= [ object
                                 ["name" .= ("client" :: Text), "image" .= (image :: Text)]
                             ]
                      ]
                ]
            replicaSet controlled name uid image =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= (name :: Text)
                      , "uid" .= (uid :: Text)
                      , "ownerReferences"
                          .= [ object
                                 [ "kind" .= ("Deployment" :: Text)
                                 , "name" .= ("client" :: Text)
                                 , "uid" .= (writerUid :: Text)
                                 , "controller" .= controlled
                                 ]
                             ]
                      ]
                , "spec"
                    .= object
                      [ "replicas" .= (1 :: Int)
                      , "template" .= replicaTemplate image
                      ]
                ]
            firstReplicaSet =
              replicaSet
                True
                "client-abc123"
                "ffffffff-1111-2222-3333-444444444444"
                "busybox:1.36"
            secondReplicaSet =
              replicaSet
                True
                "client-def456"
                "eeeeeeee-1111-2222-3333-444444444444"
                "busybox:1.36"
        Deployment.parseActiveDeploymentReplicaSet
          deploymentPin
          deploymentObject
          (object ["items" .= [firstReplicaSet]])
          @?= Right (Just ("client-abc123", "ffffffff-1111-2222-3333-444444444444"))
        case Deployment.parseActiveDeploymentReplicaSet
          deploymentPin
          deploymentObject
          (object ["items" .= [firstReplicaSet, secondReplicaSet]]) of
          Left _ -> pure ()
          Right _ -> assertFailure "two active ReplicaSets were captured as exact"
        case Deployment.parseActiveDeploymentReplicaSet
          deploymentPin
          deploymentObject
          ( object
              [ "items"
                  .= [ replicaSet
                         False
                         "client-abc123"
                         "ffffffff-1111-2222-3333-444444444444"
                         "busybox:1.36"
                     ]
              ]
          ) of
          Left _ -> pure ()
          Right _ -> assertFailure "non-controller ReplicaSet was captured"
        case Deployment.parseActiveDeploymentReplicaSet
          deploymentPin
          deploymentObject
          ( object
              [ "items"
                  .= [ replicaSet
                         True
                         "client-abc123"
                         "ffffffff-1111-2222-3333-444444444444"
                         "other:latest"
                     ]
              ]
          ) of
          Left _ -> pure ()
          Right _ -> assertFailure "changed ReplicaSet Pod template was permitted"
        let deploymentCandidate =
              candidate
                { candidateKind = DeploymentWriter
                , candidateAddress =
                    Kubernetes
                      clusterId
                      "apps"
                      (known (mkName "deployment"))
                      (Just (known (mkName "restore-space")))
                      (known (mkName "client"))
                }
        _ <-
          right
            ( validateKubernetesWriterInventory
                deploymentIntent
                [deploymentCandidate]
            )
        let extraField =
              native
                { fenceProviderIntent =
                    Just
                      ( case provider of
                          Object fields -> Object (KM.insert "unreviewed" (String "value") fields)
                          other -> other
                      )
                }
        case decodeKubernetesFenceIntent extraField of
          Left _ -> pure ()
          Right _ -> assertFailure "unknown native intent field was accepted"
        let missingReleasePrincipal =
              native
                { fenceProviderIntent =
                    Just
                      ( case provider of
                          Object fields -> Object (KM.delete "statefulControllerPrincipal" fields)
                          other -> other
                      )
                }
        case decodeKubernetesFenceIntent missingReleasePrincipal of
          Left _ -> pure ()
          Right _ -> assertFailure "unreviewed release controller was accepted"
    , testCase "service evidence counts unready and legacy endpoints" $ do
        servicePin <-
          right
            ( mkServicePin
                target
                "restore-space"
                "database"
                "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                "10.0.0.9"
                (Map.singleton "nagare.dev/database" "database")
            )
        let service =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("database" :: Text)
                      , "uid" .= ("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" :: Text)
                      ]
                , "spec"
                    .= object
                      [ "clusterIP" .= ("10.0.0.9" :: Text)
                      , "selector"
                          .= object
                            ["nagare.dev/database" .= ("database" :: Text)]
                      ]
                ]
            emptySlices = object ["items" .= ([] :: [Value])]
            endpointSlice =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("database-slice" :: Text)
                      , "uid" .= ("11111111-2222-3333-4444-555555555555" :: Text)
                      , "labels"
                          .= object
                            ["kubernetes.io/service-name" .= ("database" :: Text)]
                      ]
                , "endpoints"
                    .= [ object
                           [ "addresses" .= (["10.1.2.3"] :: [Text])
                           , "conditions" .= object ["ready" .= False]
                           ]
                       ]
                ]
            slice = object ["items" .= [endpointSlice]]
            legacy =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("database" :: Text)
                      ]
                , "subsets"
                    .= [ object
                           [ "notReadyAddresses"
                               .= [ object
                                      ["ip" .= ("10.1.2.4" :: Text)]
                                  ]
                           ]
                       ]
                ]
        empty <- right (parseServiceEvidence servicePin service emptySlices Nothing)
        serviceHasNoEndpoints empty @?= True
        let drainedSlice = case endpointSlice of
              Object fields -> Object (KM.delete "endpoints" fields)
              other -> other
        drained <-
          right
            ( parseServiceEvidence
                servicePin
                service
                (object ["items" .= [drainedSlice]])
                Nothing
            )
        serviceHasNoEndpoints drained @?= True
        let nullSlice = case endpointSlice of
              Object fields -> Object (KM.insert "endpoints" Null fields)
              other -> other
            unrelatedSlice =
              object
                [ "metadata"
                    .= object
                      ["namespace" .= ("restore-space" :: Text)]
                ]
        nullObserved <-
          right
            ( parseServiceEvidence
                servicePin
                service
                (object ["items" .= [nullSlice, unrelatedSlice]])
                Nothing
            )
        serviceHasNoEndpoints nullObserved @?= True
        observed <- right (parseServiceEvidence servicePin service slice (Just legacy))
        length (serviceSliceEndpoints observed) @?= 1
        length (serviceLegacyEndpoints observed) @?= 1
        serviceHasNoEndpoints observed @?= False
        let changed = case service of
              Object fields
                | Just (Object spec) <- KM.lookup "spec" fields ->
                    Object
                      ( KM.insert
                          "spec"
                          ( Object
                              ( KM.insert
                                  "selector"
                                  ( object
                                      ["nagare.dev/database" .= ("other" :: Text)]
                                  )
                                  spec
                              )
                          )
                          fields
                      )
              other -> other
        case parseServiceEvidence servicePin changed emptySlices Nothing of
          Left _ -> pure ()
          Right _ -> assertFailure "changed Service selector was accepted"
    , testCase "native Kubernetes exclusion guards before scaling and waits for drain" $ do
        let pvcUid = "11111111-2222-3333-4444-555555555555"
            pvUid = "66666666-7777-8888-9999-000000000000"
            writerUid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            serviceUid = "99999999-8888-7777-6666-555555555555"
            scheduleUid = "cccccccc-1111-2222-3333-444444444444"
            deploymentUid = "dddddddd-1111-2222-3333-444444444444"
            cluster =
              mintResourceId
                fenceOwner
                (known (mkLogicalKey "cluster"))
                (known (mkName "cluster"))
            serviceId =
              mintResourceId
                fenceOwner
                (known (mkLogicalKey "service"))
                (known (mkName "service"))
            scheduleId =
              mintResourceId
                fenceOwner
                (known (mkLogicalKey "backup-schedule"))
                (known (mkName "cronjob"))
            deploymentId =
              mintResourceId
                fenceOwner
                (known (mkLogicalKey "database-client"))
                (known (mkName "deployment"))
            provider =
              object
                [ "version" .= (3 :: Int)
                , "provider" .= ("kubernetes" :: Text)
                , "cluster" .= cluster
                , "dependencyRoot" .= writer
                , "networkExclusion" .= False
                , "databaseEngine" .= ("postgres" :: Text)
                , "statefulControllerPrincipal"
                    .= ("system:serviceaccount:kube-system:statefulset-controller" :: Text)
                , "volume"
                    .= object
                      [ "resource" .= target
                      , "namespace" .= ("restore-space" :: Text)
                      , "claim" .= ("data-pvc" :: Text)
                      , "claimUid" .= (pvcUid :: Text)
                      , "pv" .= ("pv-data" :: Text)
                      , "pvUid" .= (pvUid :: Text)
                      , "backing"
                          .= object
                            [ "kind" .= ("csi" :: Text)
                            , "driver" .= ("example.csi" :: Text)
                            , "handle" .= ("disk-123" :: Text)
                            ]
                      ]
                , "service"
                    .= object
                      [ "resource" .= serviceId
                      , "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("database" :: Text)
                      , "uid" .= (serviceUid :: Text)
                      , "clusterIP" .= ("10.0.0.9" :: Text)
                      , "selector"
                          .= object
                            ["nagare.dev/database" .= ("database" :: Text)]
                      ]
                ]
            savedWriter =
              object
                [ "kind" .= ("StatefulSet" :: Text)
                , "namespace" .= ("restore-space" :: Text)
                , "name" .= ("database" :: Text)
                , "uid" .= (writerUid :: Text)
                , "replicas" .= (1 :: Int)
                , "specDigest" .= known (digestStatefulWriterSpec nativeWriter)
                , "mountsTarget" .= True
                ]
            savedSchedule =
              object
                [ "kind" .= ("CronJob" :: Text)
                , "namespace" .= ("restore-space" :: Text)
                , "name" .= ("nagare-dbbackup-database" :: Text)
                , "uid" .= (scheduleUid :: Text)
                , "suspend" .= False
                , "specDigest" .= known (digestScheduledWriterSpec nativeSchedule)
                , "mountsTarget" .= False
                ]
            savedDeployment =
              object
                [ "kind" .= ("Deployment" :: Text)
                , "namespace" .= ("restore-space" :: Text)
                , "name" .= ("database-client" :: Text)
                , "uid" .= (deploymentUid :: Text)
                , "replicas" .= (1 :: Int)
                , "specDigest"
                    .= known
                      (Deployment.digestDeploymentWriterSpec nativeDeployment)
                , "selector"
                    .= Map.singleton
                      ("app" :: Text)
                      ("database-client" :: Text)
                , "mountsTarget" .= False
                ]
            nativeRecord =
              request
                { fencePhysical =
                    Map.fromList
                      [ (target, known (mkPhysicalIdentity pvcUid))
                      , (writer, known (mkPhysicalIdentity writerUid))
                      , (serviceId, known (mkPhysicalIdentity serviceUid))
                      , (scheduleId, known (mkPhysicalIdentity scheduleUid))
                      , (deploymentId, known (mkPhysicalIdentity deploymentUid))
                      ]
                , fenceAffected = Set.fromList [writer, scheduleId, deploymentId]
                , fenceSavedWriters =
                    Map.fromList
                      [ (writer, savedWriter)
                      , (scheduleId, savedSchedule)
                      , (deploymentId, savedDeployment)
                      ]
                , fenceProviderIntent = Just provider
                }
            pvc =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("data-pvc" :: Text)
                      , "uid" .= (pvcUid :: Text)
                      ]
                , "spec"
                    .= object
                      [ "volumeName" .= ("pv-data" :: Text)
                      , "accessModes" .= (["ReadWriteOnce"] :: [Text])
                      ]
                , "status" .= object ["phase" .= ("Bound" :: Text)]
                ]
            pv =
              object
                [ "metadata"
                    .= object
                      [ "name" .= ("pv-data" :: Text)
                      , "uid" .= (pvUid :: Text)
                      ]
                , "spec"
                    .= object
                      [ "accessModes" .= (["ReadWriteOnce"] :: [Text])
                      , "claimRef"
                          .= object
                            [ "namespace" .= ("restore-space" :: Text)
                            , "name" .= ("data-pvc" :: Text)
                            , "uid" .= (pvcUid :: Text)
                            ]
                      , "csi"
                          .= object
                            [ "driver" .= ("example.csi" :: Text)
                            , "volumeHandle" .= ("disk-123" :: Text)
                            ]
                      ]
                , "status" .= object ["phase" .= ("Bound" :: Text)]
                ]
            pod =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("database-0" :: Text)
                      , "uid" .= ("ffffffff-0000-1111-2222-333333333333" :: Text)
                      , "ownerReferences"
                          .= [ object
                                 [ "kind" .= ("StatefulSet" :: Text)
                                 , "name" .= ("database" :: Text)
                                 , "uid" .= (writerUid :: Text)
                                 , "controller" .= True
                                 ]
                             ]
                      ]
                , "spec"
                    .= object
                      [ "containers"
                          .= [ object
                                 [ "name" .= ("postgres" :: Text)
                                 , "image" .= ("postgres:18" :: Text)
                                 ]
                             ]
                      , "volumes"
                          .= [ object
                                 [ "persistentVolumeClaim"
                                     .= object
                                       ["claimName" .= ("data-pvc" :: Text)]
                                 ]
                             ]
                      ]
                , "status"
                    .= object
                      [ "phase" .= ("Running" :: Text)
                      , "containerStatuses"
                          .= [ object
                                 [ "name" .= ("postgres" :: Text)
                                 , "state" .= object ["running" .= object []]
                                 ]
                             ]
                      ]
                ]
            writerSpec replicas image account =
              object
                [ "replicas" .= (replicas :: Int)
                , "serviceName" .= ("database" :: Text)
                , "template"
                    .= object
                      [ "spec"
                          .= object
                            [ "serviceAccountName" .= (account :: Text)
                            , "containers"
                                .= [ object
                                       [ "name" .= ("postgres" :: Text)
                                       , "image" .= (image :: Text)
                                       ]
                                   ]
                            , "volumes"
                                .= [ object
                                       [ "persistentVolumeClaim"
                                           .= object
                                             ["claimName" .= ("data-pvc" :: Text)]
                                       ]
                                   ]
                            ]
                      ]
                ]
            nativeWriter =
              object
                [ "kind" .= ("StatefulSet" :: Text)
                , "metadata"
                    .= object
                      [ "labels"
                          .= object
                            ["nagare.dev/database" .= ("database" :: Text)]
                      ]
                , "spec" .= writerSpec (1 :: Int) "postgres:18" "database-account"
                ]
            deploymentSpec replicas =
              object
                [ "replicas" .= (replicas :: Int)
                , "selector"
                    .= object
                      [ "matchLabels"
                          .= object
                            ["app" .= ("database-client" :: Text)]
                      ]
                , "template"
                    .= object
                      [ "metadata"
                          .= object
                            [ "labels"
                                .= object
                                  ["app" .= ("database-client" :: Text)]
                            ]
                      , "spec"
                          .= object
                            [ "serviceAccountName" .= ("client-account" :: Text)
                            , "containers"
                                .= [ object
                                       [ "name" .= ("client" :: Text)
                                       , "image" .= ("busybox:1.36" :: Text)
                                       ]
                                   ]
                            ]
                      ]
                ]
            nativeDeployment = object ["spec" .= deploymentSpec (1 :: Int)]
            nativeService =
              object
                [ "spec"
                    .= object
                      [ "selector"
                          .= object
                            ["nagare.dev/database" .= ("database" :: Text)]
                      ]
                ]
            scheduleSpec suspended =
              object
                [ "suspend" .= suspended
                , "jobTemplate"
                    .= object
                      [ "spec"
                          .= object
                            [ "template"
                                .= object
                                  [ "spec"
                                      .= object
                                        [ "serviceAccountName" .= ("backup-account" :: Text)
                                        , "containers" .= ([] :: [Value])
                                        ]
                                  ]
                            ]
                      ]
                ]
            nativeSchedule = object ["spec" .= scheduleSpec False]
            observedService =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("database" :: Text)
                      , "uid" .= (serviceUid :: Text)
                      ]
                , "spec"
                    .= object
                      [ "clusterIP" .= ("10.0.0.9" :: Text)
                      , "selector"
                          .= object
                            ["nagare.dev/database" .= ("database" :: Text)]
                      ]
                ]
            endpointSlice =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("database-endpoints" :: Text)
                      , "uid" .= ("77777777-6666-5555-4444-333333333333" :: Text)
                      , "labels"
                          .= object
                            ["kubernetes.io/service-name" .= ("database" :: Text)]
                      ]
                , "endpoints"
                    .= [ object
                           ["addresses" .= (["10.1.2.3"] :: [Text])]
                       ]
                ]
            member resource kind name value =
              let bytes = BL.toStrict (encode value)
               in ( resource
                  ,
                    ( ManagedResource
                        resource
                        fenceOwner
                        KubernetesExecutor
                        ( Kubernetes
                            cluster
                            ( case kind of
                                "statefulset" -> "apps"
                                "deployment" -> "apps"
                                "cronjob" -> "batch"
                                _ -> ""
                            )
                            (known (mkName kind))
                            (Just (known (mkName "restore-space")))
                            (known (mkName name))
                        )
                        []
                        (NativeObject (contentDigest bytes))
                        Retain
                        Stateless
                        Public
                        []
                        []
                        (SourceLocation "fixture" kind)
                    , bytes
                    )
                  )
            scheduleMember = case member
              scheduleId
              "cronjob"
              "nagare-dbbackup-database"
              nativeSchedule of
              (resource, (nativeMember, bytes)) ->
                (resource, (nativeMember {dependencies = [OrderedAfter writer]}, bytes))
            deploymentMember = case member
              deploymentId
              "deployment"
              "database-client"
              nativeDeployment of
              (resource, (nativeMember, bytes)) ->
                (resource, (nativeMember {dependencies = [OrderedAfter serviceId]}, bytes))
            acceptedNative =
              Map.fromList
                [ member target "persistentvolumeclaim" "data-pvc" (object [])
                , member writer "statefulset" "database" nativeWriter
                , member serviceId "service" "database" nativeService
                , scheduleMember
                , deploymentMember
                ]
            declarations = [Managed resource | (resource, _) <- Map.elems acceptedNative]
            address (Object fields) = case (KM.lookup "kind" fields, KM.lookup "metadata" fields) of
              (Just (String kind), Just (Object metadata)) ->
                (,) kind <$> case KM.lookup "name" metadata of
                  Just (String name) -> Just name
                  _ -> Nothing
              _ -> Nothing
            address _ = Nothing
        nativeIntent <- right (decodeKubernetesFenceIntent nativeRecord)
        kubernetesDatabaseEngine nativeIntent @?= Just Postgres
        let releaseName = mountGuardName (kubernetesReleaseMountGuard nativeIntent)
        objects <- newIORef (Map.empty :: Map.Map (Text, Text) Value)
        guardDenied <- newIORef False
        writerDenied <- newIORef False
        serviceDenied <- newIORef False
        endpointDenied <- newIORef False
        legacyEndpointDenied <- newIORef False
        scheduleDenied <- newIORef False
        authorityAllowed <- newIORef False
        authorityChecks <- newIORef ([] :: [GuardAccessQuery])
        scheduleSuspended <- newIORef False
        scheduleJobsActive <- newIORef True
        schedulePodPhase <- newIORef ("Running" :: Text)
        schedulePatches <- newIORef (0 :: Int)
        replicas <- newIORef (1 :: Int)
        deploymentReplicas <- newIORef (1 :: Int)
        deploymentPatches <- newIORef (0 :: Int)
        drained <- newIORef False
        clientDrained <- newIORef False
        endpointsCleared <- newIORef False
        patches <- newIORef (0 :: Int)
        shutdownCalls <- newIORef (0 :: Int)
        shutdownDenied <- newIORef False
        liveWriterImage <- newIORef ("postgres:18" :: Text)
        liveWriterAccount <- newIORef ("database-account" :: Text)
        loseDeleteAck <- newIORef True
        loseReleaseDeleteAck <- newIORef False
        let guardTransport =
              MountGuardTransport
                { readGuardObject = \kind name ->
                    Right . Map.lookup (kind, name) <$> readIORef objects
                , createGuardObject = \value -> case address value of
                    Nothing -> pure (Left "guard address missing")
                    Just key -> case value of
                      Object fields -> case KM.lookup "metadata" fields of
                        Just (Object metadata) -> do
                          let stamped =
                                Object
                                  ( KM.insert
                                      "metadata"
                                      ( Object
                                          ( KM.insert
                                              "uid"
                                              (String "bbbbbbbb-2222-3333-4444-555555555555")
                                              (KM.insert "resourceVersion" (String "10") metadata)
                                          )
                                      )
                                      fields
                                  )
                          modifyIORef' objects (Map.insert key stamped)
                          pure (Right ())
                        _ -> pure (Left "guard metadata missing")
                      _ -> pure (Left "guard object missing")
                , deleteGuardObject = \kind name uid revision -> do
                    current <- Map.lookup (kind, name) <$> readIORef objects
                    let pinned = case current of
                          Just (Object fields) -> case KM.lookup "metadata" fields of
                            Just (Object metadata) ->
                              KM.lookup "uid" metadata == Just (String uid)
                                && KM.lookup "resourceVersion" metadata
                                  == Just (String revision)
                            _ -> False
                          _ -> False
                    if not pinned
                      then pure (Left "guard delete precondition failed")
                      else do
                        modifyIORef' objects (Map.delete (kind, name))
                        lost <- readIORef loseDeleteAck
                        lostRelease <- readIORef loseReleaseDeleteAck
                        if name == releaseName && lostRelease
                          then
                            writeIORef loseReleaseDeleteAck False
                              >> pure (Left "release guard delete acknowledgement lost")
                          else
                            if lost
                              then
                                writeIORef loseDeleteAck False
                                  >> pure (Left "guard delete acknowledgement lost")
                              else pure (Right ())
                , probeForeignMountDenied = \_ -> Right <$> readIORef guardDenied
                , probeWriterScaleDenied = \_ -> Right <$> readIORef writerDenied
                , probeServiceMutationDenied = \_ -> Right <$> readIORef serviceDenied
                , probeEndpointSliceDenied = \_ -> Right <$> readIORef endpointDenied
                , probeLegacyEndpointsDenied = \_ -> Right <$> readIORef legacyEndpointDenied
                , probeScheduleDenied = \_ -> Right <$> readIORef scheduleDenied
                }
            volumeTransport =
              VolumeTransport
                { readClaim = \_ _ -> pure (Right pvc)
                , readVolume = \_ -> pure (Right pv)
                , listNamespacePods = \_ -> do
                    empty <- readIORef drained
                    pure (Right (object ["items" .= if empty then [] else [pod]]))
                , listVolumeAttachments =
                    pure
                      ( Right
                          (object ["items" .= ([] :: [Value])])
                      )
                }
            writerTransport =
              StatefulWriterTransport
                { readStatefulWriter = \_ _ -> do
                    desired <- readIORef replicas
                    ready <- readIORef drained
                    image <- readIORef liveWriterImage
                    account <- readIORef liveWriterAccount
                    let current = if desired == 0 && ready then 0 else 1 :: Int
                    pure
                      ( Right
                          ( object
                              [ "kind" .= ("StatefulSet" :: Text)
                              , "metadata"
                                  .= object
                                    [ "namespace" .= ("restore-space" :: Text)
                                    , "name" .= ("database" :: Text)
                                    , "uid" .= (writerUid :: Text)
                                    , "resourceVersion" .= ("7" :: Text)
                                    , "generation" .= (if desired == 0 then 2 else 1 :: Int)
                                    , "labels"
                                        .= object
                                          ["nagare.dev/database" .= ("database" :: Text)]
                                    ]
                              , "spec" .= writerSpec desired image account
                              , "status"
                                  .= object
                                    [ "observedGeneration"
                                        .= (if desired == 0 && not ready then 1 else 2 :: Int)
                                    , "replicas" .= current
                                    , "readyReplicas" .= current
                                    ]
                              ]
                          )
                      )
                , patchStatefulWriter = \_ _ patch -> case patch of
                    Array operations
                      | Just (Object lastOperation) <-
                          listToMaybe (reverse (toList operations)) ->
                          case KM.lookup "value" lastOperation of
                            Just (Number count) -> do
                              modifyIORef' patches (+ 1)
                              writeIORef replicas (floor count)
                              pure (Right ())
                            _ -> pure (Left "replica patch lacks a value")
                    _ -> pure (Left "replica patch is malformed")
                }
            deploymentTransport =
              Deployment.DeploymentWriterTransport
                { Deployment.readDeploymentWriter = \_ _ -> do
                    desired <- readIORef deploymentReplicas
                    ready <- readIORef clientDrained
                    let current = if desired == 0 && ready then 0 else 1 :: Int
                        generation = if desired == 0 then 2 else 1 :: Int
                    pure
                      ( Right
                          ( object
                              [ "metadata"
                                  .= object
                                    [ "namespace" .= ("restore-space" :: Text)
                                    , "name" .= ("database-client" :: Text)
                                    , "uid" .= (deploymentUid :: Text)
                                    , "resourceVersion" .= ("9" :: Text)
                                    , "generation" .= generation
                                    ]
                              , "spec" .= deploymentSpec desired
                              , "status"
                                  .= object
                                    [ "observedGeneration"
                                        .= (if desired == 0 && not ready then 1 else generation)
                                    , "replicas" .= current
                                    , "readyReplicas" .= current
                                    ]
                              ]
                          )
                      )
                , Deployment.patchDeploymentWriter = \_ _ patch -> case patch of
                    Array operations
                      | Just (Object lastOperation) <-
                          listToMaybe (reverse (toList operations)) ->
                          case KM.lookup "value" lastOperation of
                            Just (Number count) -> do
                              modifyIORef' deploymentPatches (+ 1)
                              writeIORef deploymentReplicas (floor count)
                              pure (Right ())
                            _ -> pure (Left "Deployment replica patch lacks a value")
                    _ -> pure (Left "Deployment replica patch is malformed")
                , Deployment.listDeploymentReplicaSets = \_ -> do
                    desired <- readIORef deploymentReplicas
                    ready <- readIORef clientDrained
                    let current = if desired == 0 && ready then 0 else 1 :: Int
                    pure
                      ( Right
                          ( object
                              [ "items"
                                  .= [ object
                                         [ "metadata"
                                             .= object
                                               [ "namespace" .= ("restore-space" :: Text)
                                               , "name" .= ("database-client-abc" :: Text)
                                               , "uid" .= ("eeeeeeee-1111-2222-3333-444444444444" :: Text)
                                               , "ownerReferences"
                                                   .= [ object
                                                          [ "kind" .= ("Deployment" :: Text)
                                                          , "name" .= ("database-client" :: Text)
                                                          , "uid" .= (deploymentUid :: Text)
                                                          ]
                                                      ]
                                               ]
                                         , "spec" .= object ["replicas" .= desired]
                                         , "status" .= object ["replicas" .= current]
                                         ]
                                     ]
                              ]
                          )
                      )
                , Deployment.listDeploymentPods = \_ -> do
                    ready <- readIORef clientDrained
                    pure
                      ( Right
                          ( object
                              [ "items"
                                  .= if ready
                                    then ([] :: [Value])
                                    else
                                      [ object
                                          [ "metadata"
                                              .= object
                                                [ "namespace" .= ("restore-space" :: Text)
                                                , "labels"
                                                    .= object
                                                      ["app" .= ("database-client" :: Text)]
                                                ]
                                          , "status" .= object ["phase" .= ("Running" :: Text)]
                                          ]
                                      ]
                              ]
                          )
                      )
                }
            serviceTransport =
              ServiceTransport
                { readService = \_ _ -> pure (Right observedService)
                , listEndpointSlices = \_ -> do
                    empty <- readIORef endpointsCleared
                    pure
                      ( Right
                          ( object
                              [ "items"
                                  .= if empty
                                    then []
                                    else [endpointSlice]
                              ]
                          )
                      )
                , readLegacyEndpoints = \_ _ -> pure (Right Nothing)
                }
            scheduleTransport =
              ScheduledWriterTransport
                { readScheduledWriter = \_ _ -> do
                    suspended <- readIORef scheduleSuspended
                    active <- readIORef scheduleJobsActive
                    pure
                      ( Right
                          ( object
                              [ "metadata"
                                  .= object
                                    [ "namespace" .= ("restore-space" :: Text)
                                    , "name" .= ("nagare-dbbackup-database" :: Text)
                                    , "uid" .= (scheduleUid :: Text)
                                    , "resourceVersion" .= ("8" :: Text)
                                    ]
                              , "spec" .= scheduleSpec suspended
                              , "status"
                                  .= object
                                    [ "active"
                                        .= if active
                                          then [object ["uid" .= ("eeeeeeee-1111-2222-3333-444444444444" :: Text)]]
                                          else ([] :: [Value])
                                    ]
                              ]
                          )
                      )
                , patchScheduledWriter = \_ _ patch -> case patch of
                    Array operations
                      | Just (Object lastOperation) <-
                          listToMaybe (reverse (toList operations)) ->
                          case KM.lookup "value" lastOperation of
                            Just (Bool value) -> do
                              modifyIORef' schedulePatches (+ 1)
                              writeIORef scheduleSuspended value
                              pure (Right ())
                            _ -> pure (Left "schedule patch lacks suspend")
                    _ -> pure (Left "schedule patch is malformed")
                , listScheduledJobs = \_ -> do
                    active <- readIORef scheduleJobsActive
                    pure
                      ( Right
                          ( object
                              [ "items"
                                  .= [ object
                                         [ "metadata"
                                             .= object
                                               [ "namespace" .= ("restore-space" :: Text)
                                               , "name" .= ("nagare-dbbackup-database-12345678" :: Text)
                                               , "uid" .= ("eeeeeeee-1111-2222-3333-444444444444" :: Text)
                                               , "ownerReferences"
                                                   .= [ object
                                                          [ "kind" .= ("CronJob" :: Text)
                                                          , "name" .= ("nagare-dbbackup-database" :: Text)
                                                          , "uid" .= (scheduleUid :: Text)
                                                          , "controller" .= True
                                                          ]
                                                      ]
                                               ]
                                         , "status" .= object ["active" .= (if active then 1 else 0 :: Int)]
                                         ]
                                     ]
                              ]
                          )
                      )
                , listScheduledPods = \_ -> do
                    phase <- readIORef schedulePodPhase
                    pure
                      ( Right
                          ( object
                              [ "items"
                                  .= [ object
                                         [ "metadata"
                                             .= object
                                               [ "namespace" .= ("restore-space" :: Text)
                                               , "name" .= ("nagare-dbbackup-database-12345678-pod" :: Text)
                                               , "ownerReferences"
                                                   .= [ object
                                                          [ "kind" .= ("Job" :: Text)
                                                          , "name" .= ("nagare-dbbackup-database-12345678" :: Text)
                                                          , "uid" .= ("eeeeeeee-1111-2222-3333-444444444444" :: Text)
                                                          , "controller" .= True
                                                          ]
                                                      ]
                                               ]
                                         , "status" .= object ["phase" .= phase]
                                         ]
                                     ]
                              ]
                          )
                      )
                }
            native =
              mkKubernetesExclusion
                (binding ^. #identity)
                Map.empty
                declarations
                acceptedNative
                guardTransport
                authorityTransport
                volumeTransport
                writerTransport
                deploymentTransport
                serviceTransport
                scheduleTransport
                completedJobTransport
                shutdownTransport
            authorityTransport =
              GuardAccessTransport
                ( \query -> do
                    atomicModifyIORef' authorityChecks (\old -> (query : old, ()))
                    Right <$> readIORef authorityAllowed
                )
            controls =
              kubernetesDataFenceControls
                native
                (\_ -> pure (Right True))
            captureTransport =
              KubernetesCaptureTransport
                guardTransport
                authorityTransport
                volumeTransport
                writerTransport
                deploymentTransport
                scheduleTransport
                completedJobTransport
                serviceTransport
                shutdownTransport
            completedJobTransport =
              CompletedJobTransport
                (\_ _ -> pure (Left "test has no completed Job"))
                (\_ -> pure (Left "test has no completed Job Pods"))
            shutdownTransport = DatabaseShutdownTransport $ \_ podName podUid engine image -> do
              modifyIORef' shutdownCalls (+ 1)
              denied <- readIORef shutdownDenied
              pure $
                if denied
                  then Left "engine shutdown refused"
                  else
                    if podName == "database-0"
                      && podUid == "ffffffff-0000-1111-2222-333333333333"
                      && engine == Postgres
                      && image == "postgres:18"
                      then Right ()
                      else Left "wrong engine server Pod"
            captureRequest =
              KubernetesCaptureRequest
                binding
                Map.empty
                "restore-session"
                target
                writer
                (Just Postgres)
                (Just serviceId)
                False
                "gs://fixture/recovery"
                (contentDigest "recovery")
                "system:serviceaccount:kube-system:statefulset-controller"
                Nothing
                Nothing
        writeIORef liveWriterImage "redis:8"
        driftedEngine <-
          captureKubernetesFence
            captureTransport
            declarations
            acceptedNative
            captureRequest
        case driftedEngine of
          Left _ -> pure ()
          Right _ -> assertFailure "live server image drift was captured as accepted"
        writeIORef liveWriterImage "postgres:17"
        driftedVersion <-
          captureKubernetesFence
            captureTransport
            declarations
            acceptedNative
            captureRequest
        case driftedVersion of
          Left _ -> pure ()
          Right _ -> assertFailure "live server version drift was captured as accepted"
        writeIORef liveWriterImage "postgres:18"
        writeIORef liveWriterAccount "unreviewed-account"
        driftedAccount <-
          captureKubernetesFence
            captureTransport
            declarations
            acceptedNative
            captureRequest
        driftedAccount
          @?= Left "live writer service account differs from accepted native evidence"
        writeIORef liveWriterAccount "database-account"
        captured <-
          captureKubernetesFence
            captureTransport
            declarations
            acceptedNative
            captureRequest
            >>= right
        captured @?= nativeRecord
        wrongEngine <-
          captureKubernetesFence
            captureTransport
            declarations
            acceptedNative
            (captureRequest {captureExpectedDatabaseEngine = Just Redis})
        case wrongEngine of
          Left _ -> pure ()
          Right _ -> assertFailure "requested engine differed from accepted server image"
        firstClaimRead <- newIORef True
        let changedClaim =
              volumeTransport
                { readClaim = \_ _ -> do
                    firstRead <- atomicModifyIORef' firstClaimRead (\old -> (False, old))
                    pure
                      ( Right
                          ( if firstRead
                              then pvc
                              else
                                object
                                  [ "metadata"
                                      .= object
                                        [ "namespace" .= ("restore-space" :: Text)
                                        , "name" .= ("data-pvc" :: Text)
                                        , "uid" .= ("new-pvc-uid" :: Text)
                                        ]
                                  , "spec"
                                      .= object
                                        [ "volumeName" .= ("pv-data" :: Text)
                                        , "accessModes" .= (["ReadWriteOnce"] :: [Text])
                                        ]
                                  , "status" .= object ["phase" .= ("Bound" :: Text)]
                                  ]
                          )
                      )
                }
        stale <-
          captureKubernetesFence
            (captureTransport {captureVolumeTransport = changedClaim})
            declarations
            acceptedNative
            captureRequest
        case stale of
          Left _ -> pure ()
          Right _ -> assertFailure "PVC changed after capture but before validation"
        let changedService =
              serviceTransport
                { readService = \_ _ ->
                    pure
                      ( Right
                          ( object
                              [ "metadata"
                                  .= object
                                    [ "namespace" .= ("restore-space" :: Text)
                                    , "name" .= ("database" :: Text)
                                    , "uid" .= (serviceUid :: Text)
                                    ]
                              , "spec"
                                  .= object
                                    [ "clusterIP" .= ("10.0.0.9" :: Text)
                                    , "selector"
                                        .= object
                                          ["nagare.dev/database" .= ("other" :: Text)]
                                    ]
                              ]
                          )
                      )
                }
        changedRoute <-
          captureKubernetesFence
            (captureTransport {captureServiceTransport = changedService})
            declarations
            acceptedNative
            captureRequest
        case changedRoute of
          Left _ -> pure ()
          Right _ -> assertFailure "Service selector changed from accepted intent"
        let missingService =
              nativeRecord
                { fencePhysical = Map.delete serviceId (fencePhysical nativeRecord)
                , fenceProviderIntent =
                    Just
                      ( case provider of
                          Object fields -> Object (KM.delete "service" fields)
                          other -> other
                      )
                }
        omitted <- validateKubernetesExclusion native missingService
        case omitted of
          Left _ -> pure ()
          Right () -> assertFailure "StatefulSet fence omitted its Service route"
        let missingEngine =
              nativeRecord
                { fenceProviderIntent =
                    Just
                      ( case provider of
                          Object fields -> Object (KM.delete "databaseEngine" fields)
                          other -> other
                      )
                }
        unpinned <- validateKubernetesExclusion native missingEngine
        case unpinned of
          Left _ -> pure ()
          Right () -> assertFailure "managed database omitted its reviewed engine"
        validateFenceInputs controls nativeRecord >>= right
        refused <- stopKubernetesWriters native nativeRecord
        refused @?= Left "Kubernetes mount admission guard is not enforcing"
        readIORef objects >>= \installed -> Map.size installed @?= 34
        readIORef patches >>= (@?= 0)
        readIORef deploymentPatches >>= (@?= 0)
        writeIORef guardDenied True
        scaleRefused <- stopKubernetesWriters native nativeRecord
        scaleRefused @?= Left "Kubernetes mount admission guard is not enforcing"
        readIORef patches >>= (@?= 0)
        writeIORef writerDenied True
        routeRefused <- stopKubernetesWriters native nativeRecord
        routeRefused @?= Left "Kubernetes mount admission guard is not enforcing"
        readIORef patches >>= (@?= 0)
        writeIORef serviceDenied True
        endpointRefused <- stopKubernetesWriters native nativeRecord
        endpointRefused @?= Left "Kubernetes mount admission guard is not enforcing"
        readIORef patches >>= (@?= 0)
        writeIORef endpointDenied True
        legacyRefused <- stopKubernetesWriters native nativeRecord
        legacyRefused @?= Left "Kubernetes mount admission guard is not enforcing"
        readIORef patches >>= (@?= 0)
        writeIORef legacyEndpointDenied True
        scheduleRefused <- stopKubernetesWriters native nativeRecord
        scheduleRefused @?= Left "Kubernetes mount admission guard is not enforcing"
        readIORef patches >>= (@?= 0)
        writeIORef scheduleDenied True
        _ <- stopKubernetesWriters native nativeRecord
        checkedPrincipals <-
          Set.fromList . map accessPrincipal
            <$> readIORef authorityChecks
        assertBool
          "accepted workload service accounts were omitted from authority"
          ( Set.fromList
              [ "system:serviceaccount:restore-space:database-account"
              , "system:serviceaccount:restore-space:client-account"
              , "system:serviceaccount:restore-space:backup-account"
              ]
              `Set.isSubsetOf` checkedPrincipals
          )
        writeIORef authorityAllowed True
        editable <- stopKubernetesWriters native nativeRecord
        editable @?= Left "Kubernetes mount admission guard is not enforcing"
        readIORef patches >>= (@?= 0)
        writeIORef authorityAllowed False
        waitingClients <- stopKubernetesWriters native nativeRecord
        waitingClients @?= Left "managed database clients have not drained"
        readIORef patches >>= (@?= 0)
        readIORef shutdownCalls >>= (@?= 0)
        writeIORef clientDrained True
        waitingSchedule <- stopKubernetesWriters native nativeRecord
        waitingSchedule @?= Left "managed database clients have not drained"
        readIORef shutdownCalls >>= (@?= 0)
        writeIORef scheduleJobsActive False
        writeIORef schedulePodPhase "Succeeded"
        writeIORef shutdownDenied True
        shutdownRefused <- stopKubernetesWriters native nativeRecord
        shutdownRefused @?= Left "engine shutdown refused"
        readIORef patches >>= (@?= 0)
        writeIORef shutdownDenied False
        stopFenceWriters controls nativeRecord >>= right
        readIORef shutdownCalls >>= (@?= 2)
        readIORef schedulePatches >>= (@?= 1)
        readIORef patches >>= (@?= 1)
        readIORef deploymentPatches >>= (@?= 1)
        observeKubernetesExcluded native nativeRecord >>= right >>= (@?= False)
        writeIORef drained True
        observeKubernetesExcluded native nativeRecord >>= right >>= (@?= False)
        writeIORef endpointsCleared True
        observeWritersExcluded controls nativeRecord >>= right >>= (@?= True)
        writeIORef liveWriterImage "redis:8"
        driftedObservation <- observeKubernetesExcluded native nativeRecord
        case driftedObservation of
          Left _ -> pure ()
          Right _ -> assertFailure "drifted live server image retained exclusion proof"
        writeIORef liveWriterImage "postgres:18"
        observeKubernetesPhysical native nativeRecord
          >>= right
          >>= (@?= fencePhysical nativeRecord)
        observeKubernetesRelease native nativeRecord
          >>= right
          >>= (@?= WritersStillExcluded)
        writeIORef guardDenied False
        releaseKubernetesWriters native nativeRecord
          >>= ( @?=
                  Left "Kubernetes mount admission guard is not enforcing before release"
              )
        readIORef objects >>= \installed -> Map.size installed @?= 34
        readIORef patches >>= (@?= 1)
        writeIORef guardDenied True
        firstRelease <- releaseKubernetesWriters native nativeRecord
        firstRelease @?= Left "guard delete acknowledgement lost"
        readIORef patches >>= (@?= 1)
        observeMountGuard guardTransport (kubernetesReleaseMountGuard nativeIntent)
          >>= right
          >>= (@?= True)
        observeKubernetesRelease native nativeRecord
          >>= right
          >>= (@?= WritersPartlyReleased)
        writeIORef loseReleaseDeleteAck True
        releaseKubernetesWriters native nativeRecord
          >>= ( @?=
                  Left "release guard delete acknowledgement lost"
              )
        readIORef patches >>= (@?= 2)
        observeKubernetesRelease native nativeRecord
          >>= right
          >>= (@?= WritersPartlyReleased)
        releaseKubernetesWriters native nativeRecord >>= right
        observeKubernetesRelease native nativeRecord
          >>= right
          >>= (@?= WritersFullyReleased)
        releaseKubernetesWriters native nativeRecord >>= right
        readIORef patches >>= (@?= 2)
        readIORef deploymentPatches >>= (@?= 2)
        readIORef schedulePatches >>= (@?= 2)
    , testCase "reservation survives a new process and blocks planning until verified release" $
        withSystemTempDirectory "nagare-data-fence" $ \root -> do
          store <- openFilesystemStore root >>= right
          _ <- initializeStore store binding "operator-a" >>= right
          let scope = known (mkScopeDeclaration fenceOwner [])
              snapshot = known (mkScopeSnapshot binding Map.empty Map.empty)
              candidate = known (composeInventory snapshot (ReplaceScope scope :| []))
              registry = known (mkAdapterRegistry [])
          initialHistory <- loadInventoryHistory store >>= right
          proposal <-
            right
              ( planChanges
                  candidate
                  noLifecycleDecisions
                  initialHistory
                  (known (observationSet []))
              )
          storeSnapshot <- readStoreSnapshot store >>= right
          review <- prepareReview registry storeSnapshot proposal >>= right
          _ <- publishReview store review >>= right
          issued <- readStoreSnapshot store >>= right
          reviewed <- right (verifyReview issued review)
          released <- newIORef False
          restored <- newIORef (0 :: Int)
          let controls = fixtureControls released restored (pure (Right physical))
          token <-
            withProcessLock store (\locked -> acquireDataFence locked controls request)
              >>= right
              >>= right
          active <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
          fmap fencePhase (headDataFence active) @?= Just FenceExcluded
          eitherDecode (encode active) @?= Right active
          reopened <- openFilesystemStore root >>= right
          history <- loadInventoryHistory reopened >>= right
          case planChanges candidate noLifecycleDecisions history (known (observationSet [])) of
            Left failures ->
              assertBool
                "active fence must block planning"
                (any ((== "active-data-fence") . planErrorCode) failures)
            Right _ -> assertFailure "active fence admitted a competing review"
          admission <-
            withProcessLock
              reopened
              ( \locked ->
                  fmap (fmap (const ())) (admit locked registry reviewed)
              )
              >>= right
          case admission of
            Left errors ->
              assertBool
                "active fence must block saved review admission"
                (any ((== "active-data-fence") . admissionErrorCode) errors)
            Right _ -> assertFailure "active fence admitted a saved review"
          _ <-
            withProcessLock reopened (\locked -> beginDataChange locked controls token)
              >>= right
              >>= right
          _ <-
            withProcessLock reopened (\locked -> markDataFenceUnresolved locked token)
              >>= right
              >>= right
          resumed <-
            withProcessLock reopened (\locked -> resumeDataFence locked "restore-session")
              >>= right
              >>= right
          _ <-
            withProcessLock reopened (\locked -> recoverDataFence locked controls resumed)
              >>= right
              >>= right
          _ <-
            withProcessLock reopened (\locked -> releaseDataFence locked controls resumed)
              >>= right
              >>= right
          final <- readHead reopened >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
          headDataFence final @?= Nothing
          readIORef restored >>= (@?= 1)
          readIORef released >>= (@?= True)
    , testCase "unfinished acquisition resumes after process loss and native drain" $
        withSystemTempDirectory "nagare-acquiring-fence" $ \root -> do
          store <- openFilesystemStore root >>= right
          _ <- initializeStore store binding "operator-a" >>= right
          stopped <- newIORef False
          drained <- newIORef False
          stopEffects <- newIORef (0 :: Int)
          released <- newIORef False
          restored <- newIORef (0 :: Int)
          let original = fixtureControls released restored (pure (Right physical))
              controls =
                original
                  { stopFenceWriters = \_ -> do
                      alreadyStopped <- readIORef stopped
                      if alreadyStopped
                        then pure (Right ())
                        else do
                          writeIORef stopped True
                          modifyIORef' stopEffects (+ 1)
                          pure (Left "stop acknowledgement lost")
                  , observeWritersExcluded = \_ -> Right <$> readIORef drained
                  }
          firstAttempt <-
            withProcessLock
              store
              ( \locked ->
                  acquireDataFence locked controls request
              )
              >>= right
          case firstAttempt of
            Left reason -> reason @?= "stop acknowledgement lost"
            Right _ -> assertFailure "lost stop acknowledgement acquired fence"
          active <-
            readHead store
              >>= right
              >>= maybe
                (assertFailure "head missing" >> error "head")
                pure
          fmap fencePhase (headDataFence active) @?= Just FenceAcquiring
          reopened <- openFilesystemStore root >>= right
          token <-
            withProcessLock
              reopened
              ( \locked ->
                  resumeDataFence locked "restore-session"
              )
              >>= right
              >>= right
          pending <-
            withProcessLock
              reopened
              ( \locked ->
                  resumeDataFenceAcquisition locked controls token
              )
              >>= right
          pending @?= Left "data fence writer exclusion is not proved"
          writeIORef drained True
          _ <-
            withProcessLock
              reopened
              ( \locked ->
                  resumeDataFenceAcquisition locked controls token
              )
              >>= right
              >>= right
          readIORef stopEffects >>= (@?= 1)
          final <-
            readHead reopened
              >>= right
              >>= maybe
                (assertFailure "head missing" >> error "head")
                pure
          fmap fencePhase (headDataFence final) @?= Just FenceExcluded
    , testCase "lost writer exclusion after a data effect remains unresolved" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        excluded <- newIORef True
        verifications <- newIORef (0 :: Int)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let original = fixtureControls released restored (pure (Right physical))
            controls =
              original
                { observeWritersExcluded = \_ -> Right <$> readIORef excluded
                , verifyRecoveredData = \_ -> do
                    modifyIORef' verifications (+ 1)
                    pure (Right True)
                }
        token <-
          withProcessLock
            store
            ( \locked ->
                acquireDataFence locked controls request
            )
            >>= right
            >>= right
        _ <-
          withProcessLock
            store
            ( \locked ->
                beginDataChange locked controls token
            )
            >>= right
            >>= right
        writeIORef excluded False
        result <-
          withProcessLock
            store
            ( \locked ->
                verifyDataChange locked controls token
            )
            >>= right
        case result of
          Left _ -> pure ()
          Right () -> assertFailure "lost writer exclusion verified the data change"
        readIORef verifications >>= (@?= 0)
        readIORef restored >>= (@?= 0)
        active <-
          readHead store
            >>= right
            >>= maybe
              (assertFailure "head missing" >> error "head")
              pure
        fmap fencePhase (headDataFence active) @?= Just FenceUnresolved
        writeIORef excluded True
        _ <-
          withProcessLock
            store
            ( \locked ->
                recoverDataFence locked controls token
            )
            >>= right
            >>= right
        _ <-
          withProcessLock
            store
            ( \locked ->
                releaseDataFence locked controls token
            )
            >>= right
            >>= right
        final <-
          readHead store
            >>= right
            >>= maybe
              (assertFailure "head missing" >> error "head")
              pure
        headDataFence final @?= Nothing
    , testCase "lost release acknowledgement is observed without replaying writer restoration" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let original = fixtureControls released restored (pure (Right physical))
            uncertain =
              original
                { restoreFenceWriters = \_ -> do
                    modifyIORef' restored (+ 1)
                    writeIORef released True
                    pure (Left "release acknowledgement lost")
                }
        token <-
          withProcessLock store (\locked -> acquireDataFence locked uncertain request)
            >>= right
            >>= right
        _ <-
          withProcessLock store (\locked -> beginDataChange locked uncertain token)
            >>= right
            >>= right
        _ <-
          withProcessLock store (\locked -> verifyDataChange locked uncertain token)
            >>= right
            >>= right
        outcome <-
          withProcessLock store (\locked -> releaseDataFence locked uncertain token)
            >>= right
        case outcome of
          Left _ -> pure ()
          Right () -> assertFailure "lost acknowledgement should remain unresolved"
        active <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        fmap fencePhase (headDataFence active) @?= Just FenceReleasing
        _ <-
          withProcessLock store (\locked -> releaseDataFence locked uncertain token)
            >>= right
            >>= right
        readIORef restored >>= (@?= 1)
        final <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        headDataFence final @?= Nothing
    , testCase "release resumes after interruption before any writer control" $
        withSystemTempDirectory "nagare-fence-release" $ \root -> do
          store <- openFilesystemStore root >>= right
          _ <- initializeStore store binding "operator-a" >>= right
          released <- newIORef False
          restored <- newIORef (0 :: Int)
          let original = fixtureControls released restored (pure (Right physical))
              interrupted =
                original
                  { restoreFenceWriters = \_ ->
                      pure (Left "interrupted before writer release")
                  }
          token <-
            withProcessLock store (\locked -> acquireDataFence locked original request)
              >>= right
              >>= right
          _ <-
            withProcessLock store (\locked -> beginDataChange locked original token)
              >>= right
              >>= right
          _ <-
            withProcessLock store (\locked -> verifyDataChange locked original token)
              >>= right
              >>= right
          outcome <-
            withProcessLock store (\locked -> releaseDataFence locked interrupted token)
              >>= right
          case outcome of
            Left _ -> pure ()
            Right () -> assertFailure "interrupted release appeared complete"
          readIORef restored >>= (@?= 0)
          reopened <- openFilesystemStore root >>= right
          resumed <-
            withProcessLock reopened (\locked -> resumeDataFence locked "restore-session")
              >>= right
              >>= right
          _ <-
            withProcessLock reopened (\locked -> recoverDataFence locked original resumed)
              >>= right
              >>= right
          readIORef restored >>= (@?= 1)
          final <-
            readHead reopened
              >>= right
              >>= maybe
                (assertFailure "head missing" >> error "head")
                pure
          headDataFence final @?= Nothing
    , testCase "partial writer release is not replayed" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let original = fixtureControls released restored (pure (Right physical))
            partial =
              original
                { restoreFenceWriters = \_ -> do
                    modifyIORef' restored (+ 1)
                    pure (Left "one writer changed before interruption")
                , observeWritersReleased = \_ -> pure (Right WritersPartlyReleased)
                }
        token <-
          withProcessLock store (\locked -> acquireDataFence locked partial request)
            >>= right
            >>= right
        _ <-
          withProcessLock store (\locked -> beginDataChange locked partial token)
            >>= right
            >>= right
        _ <-
          withProcessLock store (\locked -> verifyDataChange locked partial token)
            >>= right
            >>= right
        _ <-
          withProcessLock store (\locked -> releaseDataFence locked partial token)
            >>= right
        repeated <-
          withProcessLock store (\locked -> releaseDataFence locked partial token)
            >>= right
        case repeated of
          Left _ -> pure ()
          Right () -> assertFailure "partial writer release was accepted"
        readIORef restored >>= (@?= 1)
        active <-
          readHead store
            >>= right
            >>= maybe
              (assertFailure "head missing" >> error "head")
              pure
        fmap fencePhase (headDataFence active) @?= Just FenceReleasing
    , testCase "explicit forward recovery completes a partial writer release" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        phase <- newIORef (0 :: Int)
        forwardEffects <- newIORef (0 :: Int)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let original = fixtureControls released restored (pure (Right physical))
            controls =
              original
                { restoreFenceWriters = \_ ->
                    writeIORef phase 1
                      >> pure (Left "first writer restored before response loss")
                , observeWritersReleased = \_ -> do
                    value <- readIORef phase
                    pure
                      ( Right
                          ( if value == 2
                              then WritersFullyReleased
                              else
                                if value == 1
                                  then WritersPartlyReleased
                                  else WritersStillExcluded
                          )
                      )
                , forwardRecoverPartlyReleased =
                    Just
                      ( \_ -> do
                          modifyIORef' forwardEffects (+ 1)
                          writeIORef phase 2
                          pure (Right ())
                      )
                }
        token <-
          withProcessLock store (\locked -> acquireDataFence locked controls request)
            >>= right
            >>= right
        _ <-
          withProcessLock store (\locked -> beginDataChange locked controls token)
            >>= right
            >>= right
        _ <-
          withProcessLock store (\locked -> verifyDataChange locked controls token)
            >>= right
            >>= right
        _ <-
          withProcessLock store (\locked -> releaseDataFence locked controls token)
            >>= right
        ordinary <-
          withProcessLock
            store
            ( \locked ->
                releaseDataFence locked controls token
            )
            >>= right
        case ordinary of
          Left _ -> pure ()
          Right () -> assertFailure "partial release resumed without forward recovery"
        readIORef forwardEffects >>= (@?= 0)
        _ <-
          withProcessLock
            store
            ( \locked ->
                forwardRecoverDataFenceRelease locked controls token
            )
            >>= right
            >>= right
        readIORef forwardEffects >>= (@?= 1)
        final <-
          readHead store
            >>= right
            >>= maybe
              (assertFailure "head missing" >> error "head")
              pure
        headDataFence final @?= Nothing
    , testCase "changed target identity leaves a durable unresolved fence" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let changed = Map.insert target (known (mkPhysicalIdentity "replacement-uid")) physical
            controls = fixtureControls released restored (pure (Right changed))
        outcome <-
          withProcessLock store (\locked -> acquireDataFence locked controls request)
            >>= right
        case outcome of
          Left _ -> pure ()
          Right _ -> assertFailure "changed target identity acquired fence"
        active <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        fmap fencePhase (headDataFence active) @?= Just FenceAcquiring
    , testCase "reviewed transaction may own only its matching fence" $ do
        store <- newMemoryStore
        initial <- initializeStore store binding "operator-a" >>= right
        let transaction = "tx-reviewed-restore"
            active =
              initial
                { headGeneration = 1
                , headActiveTransaction = Just transaction
                , headExecutorClaim = Just (ExecutorClaim transaction "operator-a" 1 "time")
                }
        _ <- replaceHeadIfGenerationMatches store (Just 0) active >>= right
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let controls = fixtureControls released restored (pure (Right physical))
        wrong <-
          withProcessLock
            store
            ( \locked ->
                acquireDataFence
                  locked
                  controls
                  request {fenceTransaction = Just "tx-other"}
            )
            >>= right
        case wrong of
          Left _ -> pure ()
          Right _ -> assertFailure "a foreign transaction acquired the fence"
        _ <-
          replaceHeadIfGenerationMatches
            store
            (Just 1)
            active
              { headGeneration = 2
              , headExecutorClaim =
                  Just (ExecutorClaim transaction "operator-b" 2 "time")
              }
            >>= right
        foreignClaim <-
          withProcessLock
            store
            ( \locked ->
                acquireDataFence
                  locked
                  controls
                  request {fenceTransaction = Just transaction}
            )
            >>= right
        case foreignClaim of
          Left _ -> pure ()
          Right _ -> assertFailure "a foreign executor acquired the fence"
        _ <-
          replaceHeadIfGenerationMatches
            store
            (Just 2)
            active {headGeneration = 3}
            >>= right
        _ <-
          withProcessLock
            store
            ( \locked ->
                acquireDataFence
                  locked
                  controls
                  request {fenceTransaction = Just transaction}
            )
            >>= right
            >>= right
        fenced <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        headActiveTransaction fenced @?= Just transaction
        fmap fenceTransaction (headDataFence fenced) @?= Just (Just transaction)
    , testCase "reviewed transaction cannot journal convergence while fenced" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        let scope = known (mkScopeDeclaration fenceOwner [])
            snapshot = known (mkScopeSnapshot binding Map.empty Map.empty)
            candidate = known (composeInventory snapshot (ReplaceScope scope :| []))
            registry = known (mkAdapterRegistry [])
        history <- loadInventoryHistory store >>= right
        proposal <-
          right
            ( planChanges
                candidate
                noLifecycleDecisions
                history
                (known (observationSet []))
            )
        storeSnapshot <- readStoreSnapshot store >>= right
        review <- prepareReview registry storeSnapshot proposal >>= right
        _ <- publishReview store review >>= right
        issued <- readStoreSnapshot store >>= right
        reviewed <- right (verifyReview issued review)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let controls = fixtureControls released restored (pure (Right physical))
        result <- withProcessLock store $ \locked -> do
          executable <- admit locked registry reviewed >>= right
          admitted <-
            readHead store
              >>= right
              >>= maybe
                (assertFailure "head missing" >> error "head")
                pure
          let transaction =
                maybe
                  (error "transaction missing")
                  id
                  (headActiveTransaction admitted)
          _ <-
            acquireDataFence
              locked
              controls
              request
                { fenceTransaction = Just transaction
                , fenceAccepted = headAccepted admitted
                }
              >>= right
          execute locked registry executable
        outcome <- right result
        case outcome of
          Converged _ -> assertFailure "fenced transaction converged"
          _ -> pure ()
        transaction <- case outcome of
          StoppedAmbiguous value _ -> pure value
          _ -> assertFailure "fenced transaction did not stop unresolved" >> error "transaction"
        resumed <- resumeTransaction store registry transaction
        case resumed of
          Left errors ->
            assertBool
              "resume must defer to explicit fence recovery"
              (any ((== "active-data-fence") . admissionErrorCode) errors)
          Right _ -> assertFailure "resumed an actively fenced restore"
        fenced <-
          readHead store
            >>= right
            >>= maybe
              (assertFailure "head missing" >> error "head")
              pure
        headSequence fenced @?= 1
        assertBool "transaction remains active" (isJust (headActiveTransaction fenced))
        assertBool "fence remains active" (isJust (headDataFence fenced))
    , testCase "mount guard binds an exact PVC and authenticated restore Job" $ do
        let pvcUid = "11111111-2222-3333-4444-555555555555"
            pvUid = "66666666-7777-8888-9999-000000000000"
            jobUid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            statefulUid = "ffffffff-0000-1111-2222-333333333333"
        permit <-
          right
            ( mkPodOwnerPermit
                "Job"
                "restore-job"
                jobUid
                "system:serviceaccount:kube-system:job-controller"
            )
        writerPermit <-
          right
            ( mkPodOwnerPermit
                "StatefulSet"
                "database"
                statefulUid
                "system:serviceaccount:kube-system:statefulset-controller"
            )
        guard <-
          right
            ( mkMountGuard
                "restore-session"
                "restore-space"
                "data-pvc"
                pvcUid
                "pv-data"
                pvUid
                [permit, writerPermit]
            )
        let (policy, bindingValue) = mountGuardObjects guard
            (pvcPolicy, pvcBinding) = pvcMutationGuardObjects guard
            (pvPolicy, _) = pvMutationGuardObjects guard
            (namespacePolicy, _) = namespaceDeleteGuardObjects guard
            field key (Object value) = KM.lookup key value
            field _ _ = Nothing
            policySpec = field "spec" policy
            bindingSpec = field "spec" bindingValue
            validations = policySpec >>= field "validations"
            expression = case validations of
              Just (Array values) | first : _ <- toList values -> field "expression" first
              _ -> Nothing
        (policySpec >>= field "failurePolicy") @?= Just (String "Fail")
        (bindingSpec >>= field "validationActions")
          @?= Just (toJSON (["Deny"] :: [Text]))
        (field "spec" pvcPolicy >>= field "failurePolicy") @?= Just (String "Fail")
        (field "spec" pvcBinding >>= field "validationActions")
          @?= Just (toJSON (["Deny"] :: [Text]))
        case field "spec" pvcPolicy >>= field "validations" of
          Just (Array values) | firstValidation : _ <- toList values ->
            case field "expression" firstValidation of
              Just (String value) ->
                assertBool
                  "claim mutation guard checks the old object"
                  ("oldObject.metadata.name != 'data-pvc'" `T.isInfixOf` value)
              _ -> assertFailure "PVC guard lacks an expression"
          _ -> assertFailure "PVC guard lacks validations"
        let guardedExpression guardedPolicy = case field "spec" guardedPolicy >>= field "validations" of
              Just (Array values)
                | firstValidation : _ <- toList values ->
                    field "expression" firstValidation
              _ -> Nothing
        guardedExpression pvPolicy @?= Just (String "oldObject.metadata.name != 'pv-data'")
        guardedExpression namespacePolicy
          @?= Just (String "oldObject.metadata.name != 'restore-space'")
        serviceGuard <-
          right
            ( withGuardedService
                guard
                "restore-space"
                "database"
                "99999999-8888-7777-6666-555555555555"
            )
        case ( serviceMutationGuardObjects serviceGuard
             , endpointSliceGuardObjects serviceGuard
             , legacyEndpointsGuardObjects serviceGuard
             ) of
          ( Just (servicePolicy, _)
            , Just (slicePolicy, _)
            , Just (legacyPolicy, _)
            ) -> do
              assertBool
                "Service update/delete guard binds the exact name"
                ( maybe
                    False
                    (T.isInfixOf "oldObject.metadata.name != 'database'")
                    ( case guardedExpression servicePolicy of
                        Just (String value) -> Just value
                        _ -> Nothing
                    )
                )
              assertBool
                "empty EndpointSlices remain drainable"
                ( maybe
                    False
                    (T.isInfixOf "object.endpoints == null")
                    ( case guardedExpression slicePolicy of
                        Just (String value) -> Just value
                        _ -> Nothing
                    )
                )
              assertBool
                "empty legacy Endpoints remain drainable"
                ( maybe
                    False
                    (T.isInfixOf "object.subsets == null")
                    ( case guardedExpression legacyPolicy of
                        Just (String value) -> Just value
                        _ -> Nothing
                    )
                )
          _ -> assertFailure "Service route guards were not rendered"
        case expression of
          Just (String value) -> do
            assertBool "PVC name is constrained" ("data-pvc" `T.isInfixOf` value)
            assertBool "Job UID is constrained" (jobUid `T.isInfixOf` value)
            assertBool "writer UID is constrained" (statefulUid `T.isInfixOf` value)
            assertBool
              "controller principal is constrained"
              ("system:serviceaccount:kube-system:job-controller" `T.isInfixOf` value)
          _ -> assertFailure "mount guard lacks a CEL expression"
        case mkPodOwnerPermit "Job" "restore-job" jobUid "foreign' || true" of
          Left _ -> pure ()
          Right _ -> assertFailure "CEL injection was accepted"
        case mkMountGuard
          "restore-session"
          "restore-space"
          "data-pvc"
          "wrong-uid"
          "pv-data"
          pvUid
          [] of
          Left _ -> pure ()
          Right _ -> assertFailure "unbound PVC UID was accepted"
        case mkMountGuard
          "restore-session"
          "restore_space"
          "data-pvc"
          pvcUid
          "pv-data"
          pvUid
          [] of
          Left _ -> pure ()
          Right _ -> assertFailure "invalid Kubernetes namespace was accepted"
    , testCase "guard authority checks exact names and refuses policy editors" $ do
        guard <-
          right
            ( mkMountGuard
                "restore-session"
                "restore-space"
                "data-pvc"
                "11111111-2222-3333-4444-555555555555"
                "pv-data"
                "66666666-7777-8888-9999-000000000000"
                []
            )
        checks <- newIORef ([] :: [GuardAccessQuery])
        let principal = "system:serviceaccount:restore-space:client"
            transport allowed = GuardAccessTransport $ \query -> do
              atomicModifyIORef' checks (\old -> (query : old, ()))
              pure (Right (allowed query))
        observeGuardAuthority (transport (const False)) [principal] guard
          >>= (@?= Right True)
        queried <- readIORef checks
        length queried @?= 26
        assertBool
          "exact Pod policy patch check is missing"
          ( GuardAccessQuery
              principal
              "admissionregistration.k8s.io"
              Nothing
              "patch"
              "validatingadmissionpolicies"
              Nothing
              (mountGuardName guard)
              `elem` queried
          )
        assertBool
          "collection binding deletion check is missing"
          ( GuardAccessQuery
              principal
              "admissionregistration.k8s.io"
              Nothing
              "deletecollection"
              "validatingadmissionpolicybindings"
              Nothing
              ""
              `elem` queried
          )
        writeIORef checks []
        observeGuardAuthority
          ( transport
              ( \query ->
                  accessVerb query == "patch"
                    && accessName query == mountGuardName guard
              )
          )
          [principal]
          guard
          >>= (@?= Right False)
        caseLength <- length <$> readIORef checks
        assertBool "an authorized policy edit stopped the proof" (caseLength < 26)
        malformed <-
          observeGuardAuthority
            (transport (const False))
            ["system:serviceaccount:restore-space:client:other"]
            guard
        case malformed of
          Left _ -> pure ()
          Right _ -> assertFailure "malformed principal was accepted"
    , testCase "mount guard install resumes and proof rejects policy drift" $ do
        guard <-
          right
            ( mkMountGuard
                "restore-session"
                "restore-space"
                "data-pvc"
                "11111111-2222-3333-4444-555555555555"
                "pv-data"
                "66666666-7777-8888-9999-000000000000"
                []
            )
        objects <- newIORef (Map.empty :: Map.Map (Text, Text) Value)
        creates <- newIORef (0 :: Int)
        failSecondCreate <- newIORef True
        denied <- newIORef True
        let address (Object value) = case (KM.lookup "kind" value, KM.lookup "metadata" value) of
              (Just (String kind), Just (Object metadata)) ->
                case KM.lookup "name" metadata of
                  Just (String name) -> (kind, name)
                  _ -> error "guard object lacks name"
              _ -> error "guard object lacks kind"
            address _ = error "guard object is not JSON"
            transport =
              MountGuardTransport
                { readGuardObject = \kind name ->
                    pure . Right . Map.lookup (kind, name) =<< readIORef objects
                , createGuardObject = \value -> do
                    modifyIORef' creates (+ 1)
                    attempt <- readIORef creates
                    failNow <- readIORef failSecondCreate
                    if attempt == 2 && failNow
                      then writeIORef failSecondCreate False >> pure (Left "response lost")
                      else do
                        modifyIORef' objects (Map.insert (address value) value)
                        pure (Right ())
                , deleteGuardObject = \_ _ _ _ -> pure (Left "unexpected guard delete")
                , probeForeignMountDenied = \_ -> Right <$> readIORef denied
                , probeWriterScaleDenied = \_ -> pure (Right True)
                , probeServiceMutationDenied = \_ -> pure (Right True)
                , probeEndpointSliceDenied = \_ -> pure (Right True)
                , probeLegacyEndpointsDenied = \_ -> pure (Right True)
                , probeScheduleDenied = \_ -> pure (Right True)
                }
        firstInstall <- installMountGuard transport guard
        case firstInstall of
          Left _ -> pure ()
          Right () -> assertFailure "partial policy install was reported complete"
        readIORef creates >>= (@?= 2)
        installMountGuard transport guard >>= right
        readIORef creates >>= (@?= 9)
        installMountGuard transport guard >>= right
        readIORef creates >>= (@?= 9)
        observeMountGuard transport guard >>= right >>= (@?= True)
        writeIORef denied False
        observeMountGuard transport guard >>= right >>= (@?= False)
        writeIORef denied True
        let name = mountGuardName guard
        modifyIORef'
          objects
          ( Map.adjust
              ( \value -> case value of
                  Object fields -> Object (KM.insert "spec" (object []) fields)
                  other -> other
              )
              ("ValidatingAdmissionPolicy", name)
          )
        observeMountGuard transport guard >>= right >>= (@?= False)
        result <- installMountGuard transport guard
        case result of
          Left _ -> pure ()
          Right () -> assertFailure "changed policy was accepted on restart"
        readIORef creates >>= (@?= 9)
    , testCase "guard removal is conditional and resumes a lost acknowledgement" $ do
        mountGuard <-
          right
            ( mkMountGuard
                "restore-session"
                "restore-space"
                "data-pvc"
                "11111111-2222-3333-4444-555555555555"
                "pv-data"
                "66666666-7777-8888-9999-000000000000"
                []
            )
        let rendered =
              concatMap
                (\(policy, bindingValue) -> [policy, bindingValue])
                [ mountGuardObjects mountGuard
                , pvcMutationGuardObjects mountGuard
                , pvMutationGuardObjects mountGuard
                , namespaceDeleteGuardObjects mountGuard
                ]
            address (Object fields) = case (KM.lookup "kind" fields, KM.lookup "metadata" fields) of
              (Just (String kind), Just (Object metadata)) -> case KM.lookup "name" metadata of
                Just (String name) -> Just (kind, name)
                _ -> Nothing
              _ -> Nothing
            address _ = Nothing
            stamped (Object fields) = case KM.lookup "metadata" fields of
              Just (Object metadata) ->
                Object
                  ( KM.insert
                      "metadata"
                      ( Object
                          ( KM.insert
                              "uid"
                              (String "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
                              (KM.insert "resourceVersion" (String "42") metadata)
                          )
                      )
                      fields
                  )
              _ -> error "guard metadata missing"
            stamped _ = error "guard object missing"
            entries =
              [ (key, stamped value)
              | value <- rendered
              , Just key <- [address value]
              ]
        length entries @?= 8
        objects <- newIORef (Map.fromList entries)
        deletes <- newIORef ([] :: [Text])
        loseFirst <- newIORef True
        let transport =
              MountGuardTransport
                { readGuardObject = \kind name ->
                    Right . Map.lookup (kind, name) <$> readIORef objects
                , createGuardObject = \_ -> pure (Left "unexpected guard create")
                , deleteGuardObject = \kind name uid revision -> do
                    current <- Map.lookup (kind, name) <$> readIORef objects
                    let pinned = case current of
                          Just (Object fields) -> case KM.lookup "metadata" fields of
                            Just (Object metadata) ->
                              KM.lookup "uid" metadata == Just (String uid)
                                && KM.lookup "resourceVersion" metadata
                                  == Just (String revision)
                            _ -> False
                          _ -> False
                    if not pinned
                      then pure (Left "delete precondition changed")
                      else do
                        modifyIORef' objects (Map.delete (kind, name))
                        modifyIORef' deletes (<> [kind])
                        lost <- readIORef loseFirst
                        if lost
                          then
                            writeIORef loseFirst False
                              >> pure (Left "delete acknowledgement lost")
                          else pure (Right ())
                , probeForeignMountDenied = \_ -> pure (Right False)
                , probeWriterScaleDenied = \_ -> pure (Right True)
                , probeServiceMutationDenied = \_ -> pure (Right True)
                , probeEndpointSliceDenied = \_ -> pure (Right True)
                , probeLegacyEndpointsDenied = \_ -> pure (Right True)
                , probeScheduleDenied = \_ -> pure (Right True)
                }
        let firstKey = case reverse rendered of
              firstObject : _ -> address firstObject
              [] -> Nothing
        key <- maybe (assertFailure "guard key missing" >> error "key") pure firstKey
        modifyIORef'
          objects
          ( Map.adjust
              ( \value -> case value of
                  Object fields -> Object (KM.insert "spec" (object []) fields)
                  other -> other
              )
              key
          )
        drifted <- removeMountGuard transport mountGuard
        case drifted of
          Left _ -> pure ()
          Right () -> assertFailure "drifted guard was deleted"
        readIORef deletes >>= (@?= [])
        writeIORef objects (Map.fromList entries)
        lost <- removeMountGuard transport mountGuard
        lost @?= Left "delete acknowledgement lost"
        readIORef deletes >>= \kinds -> case kinds of
          firstKind : _ -> firstKind @?= "ValidatingAdmissionPolicyBinding"
          [] -> assertFailure "no binding delete occurred"
        removeMountGuard transport mountGuard >>= right
        observeMountGuardAbsent transport mountGuard >>= (@?= Right True)
        readIORef deletes >>= \kinds -> length kinds @?= 8
    , testCase "exact volume evidence counts every Pod and attachment consumer" $ do
        mountGuard <-
          right
            ( mkMountGuard
                "restore-session"
                "restore-space"
                "data-pvc"
                "11111111-2222-3333-4444-555555555555"
                "pv-data"
                "66666666-7777-8888-9999-000000000000"
                []
            )
        let pvc =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("data-pvc" :: Text)
                      , "uid" .= ("11111111-2222-3333-4444-555555555555" :: Text)
                      ]
                , "spec"
                    .= object
                      [ "volumeName" .= ("pv-data" :: Text)
                      , "accessModes" .= (["ReadWriteOnce"] :: [Text])
                      ]
                , "status" .= object ["phase" .= ("Bound" :: Text)]
                ]
            pv =
              object
                [ "metadata"
                    .= object
                      [ "name" .= ("pv-data" :: Text)
                      , "uid" .= ("66666666-7777-8888-9999-000000000000" :: Text)
                      ]
                , "spec"
                    .= object
                      [ "accessModes" .= (["ReadWriteOnce"] :: [Text])
                      , "claimRef"
                          .= object
                            [ "namespace" .= ("restore-space" :: Text)
                            , "name" .= ("data-pvc" :: Text)
                            , "uid" .= ("11111111-2222-3333-4444-555555555555" :: Text)
                            ]
                      , "csi"
                          .= object
                            [ "driver" .= ("example.csi" :: Text)
                            , "volumeHandle" .= ("disk-123" :: Text)
                            ]
                      ]
                , "status" .= object ["phase" .= ("Bound" :: Text)]
                ]
            emptyPods = object ["items" .= ([] :: [Value])]
            emptyAttachments = object ["items" .= ([] :: [Value])]
            mountedPod =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("foreign" :: Text)
                      , "uid" .= ("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" :: Text)
                      ]
                , "spec"
                    .= object
                      [ "volumes"
                          .= [ object
                                 [ "persistentVolumeClaim"
                                     .= object
                                       ["claimName" .= ("data-pvc" :: Text)]
                                 ]
                             ]
                      ]
                ]
            attachment =
              object
                [ "metadata"
                    .= object
                      [ "name" .= ("attachment" :: Text)
                      , "uid" .= ("ffffffff-0000-1111-2222-333333333333" :: Text)
                      ]
                , "spec"
                    .= object
                      [ "source"
                          .= object
                            ["persistentVolumeName" .= ("pv-data" :: Text)]
                      ]
                , "status" .= object ["attached" .= False]
                ]
            backing = CsiVolume "example.csi" "disk-123"
            observed pods attachments =
              parseVolumeEvidence
                mountGuard
                backing
                pvc
                pv
                pods
                attachments
        emptyEvidence <- right (observed emptyPods emptyAttachments)
        assertBool
          "empty volume should have no consumers"
          (volumeHasNoConsumers emptyEvidence)
        probes <- newIORef [True, True]
        let guardObjects =
              concatMap
                ( \(policy, bindingValue) ->
                    [policy, bindingValue]
                )
                [ mountGuardObjects mountGuard
                , pvcMutationGuardObjects mountGuard
                , pvMutationGuardObjects mountGuard
                , namespaceDeleteGuardObjects mountGuard
                ]
            address (Object fields) = case (KM.lookup "kind" fields, KM.lookup "metadata" fields) of
              (Just (String kind), Just (Object metadata)) ->
                case KM.lookup "name" metadata of
                  Just (String name) -> Just (kind, name)
                  _ -> Nothing
              _ -> Nothing
            address _ = Nothing
            guardedTransport =
              MountGuardTransport
                { readGuardObject = \kind name ->
                    pure (Right (find ((== Just (kind, name)) . address) guardObjects))
                , createGuardObject = \_ -> pure (Left "unexpected create")
                , deleteGuardObject = \_ _ _ _ -> pure (Left "unexpected guard delete")
                , probeForeignMountDenied = \_ -> atomicModifyIORef' probes $ \values ->
                    case values of
                      next : rest -> (rest, Right next)
                      [] -> ([], Right False)
                , probeWriterScaleDenied = \_ -> pure (Right True)
                , probeServiceMutationDenied = \_ -> pure (Right True)
                , probeEndpointSliceDenied = \_ -> pure (Right True)
                , probeLegacyEndpointsDenied = \_ -> pure (Right True)
                , probeScheduleDenied = \_ -> pure (Right True)
                }
            volumeTransport =
              VolumeTransport
                { readClaim = \_ _ -> pure (Right pvc)
                , readVolume = \_ -> pure (Right pv)
                , listNamespacePods = \_ -> pure (Right emptyPods)
                , listVolumeAttachments = pure (Right emptyAttachments)
                }
        observeGuardedVolumeExcluded
          guardedTransport
          volumeTransport
          mountGuard
          backing
          >>= right
          >>= (@?= True)
        writeIORef probes [True, False]
        observeGuardedVolumeExcluded
          guardedTransport
          volumeTransport
          mountGuard
          backing
          >>= right
          >>= (@?= False)
        podEvidence <-
          right
            ( observed
                (object ["items" .= [mountedPod]])
                emptyAttachments
            )
        volumePodConsumers podEvidence
          @?= ["foreign/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"]
        assertBool "Pod still has the PVC" (not (volumeHasNoConsumers podEvidence))
        attachmentEvidence <-
          right
            ( observed
                emptyPods
                (object ["items" .= [attachment]])
            )
        assertBool
          "detached attachment intent still exists"
          (not (volumeHasNoConsumers attachmentEvidence))
        case parseVolumeEvidence
          mountGuard
          (CsiVolume "example.csi" "other")
          pvc
          pv
          emptyPods
          emptyAttachments of
          Left _ -> pure ()
          Right _ -> assertFailure "changed CSI handle was accepted"
        let localPv = case pv of
              Object fields
                | Just (Object spec) <- KM.lookup "spec" fields ->
                    Object
                      ( KM.insert
                          "spec"
                          ( Object
                              ( KM.insert
                                  "nodeAffinity"
                                  ( object
                                      [ "required"
                                          .= object
                                            [ "nodeSelectorTerms"
                                                .= [ object
                                                       [ "matchExpressions"
                                                           .= [ object
                                                                  [ "key" .= ("kubernetes.io/hostname" :: Text)
                                                                  , "operator" .= ("In" :: Text)
                                                                  , "values" .= (["node-a"] :: [Text])
                                                                  ]
                                                              ]
                                                       ]
                                                   ]
                                            ]
                                      ]
                                  )
                                  ( KM.insert
                                      "local"
                                      (object ["path" .= ("/data/disk" :: Text)])
                                      (KM.delete "csi" spec)
                                  )
                              )
                          )
                          fields
                      )
              other -> other
        localEvidence <-
          right
            ( parseVolumeEvidence
                mountGuard
                (LocalVolume "/data/disk" "node-a")
                pvc
                localPv
                emptyPods
                emptyAttachments
            )
        assertBool
          "local volume has no consumers"
          (volumeHasNoConsumers localEvidence)
        case parseVolumeEvidence
          mountGuard
          (LocalVolume "/data/disk" "node-b")
          pvc
          localPv
          emptyPods
          emptyAttachments of
          Left _ -> pure ()
          Right _ -> assertFailure "changed local PV node was accepted"
        let replacedClaim = case pvc of
              Object fields
                | Just (Object metadata) <- KM.lookup "metadata" fields ->
                    Object
                      ( KM.insert
                          "metadata"
                          ( Object
                              ( KM.insert
                                  "uid"
                                  (String "bbbbbbbb-2222-3333-4444-555555555555")
                                  metadata
                              )
                          )
                          fields
                      )
              other -> other
        case parseVolumeEvidence
          mountGuard
          backing
          replacedClaim
          pv
          emptyPods
          emptyAttachments of
          Left _ -> pure ()
          Right _ -> assertFailure "replaced PVC UID was accepted"
    , testCase "Deployment writer waits for ReplicaSets and terminating Pods" $ do
        let uid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            replicaUid = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
            deploymentSpec replicas image =
              object
                [ "replicas" .= (replicas :: Int)
                , "selector"
                    .= object
                      [ "matchLabels"
                          .= object
                            ["app" .= ("client" :: Text)]
                      ]
                , "template"
                    .= object
                      [ "spec"
                          .= object
                            ["containers" .= [object ["image" .= (image :: Text)]]]
                      ]
                ]
            deployment replicas statusReplicas generation image =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("client" :: Text)
                      , "uid" .= (uid :: Text)
                      , "resourceVersion" .= ("7" :: Text)
                      , "generation" .= (generation :: Int)
                      ]
                , "spec" .= deploymentSpec replicas image
                , "status"
                    .= object
                      [ "observedGeneration" .= (generation :: Int)
                      , "replicas" .= (statusReplicas :: Int)
                      , "readyReplicas" .= (statusReplicas :: Int)
                      ]
                ]
            replicaSet desired current =
              object
                [ "items"
                    .= [ object
                           [ "metadata"
                               .= object
                                 [ "namespace" .= ("restore-space" :: Text)
                                 , "name" .= ("client-123" :: Text)
                                 , "uid" .= (replicaUid :: Text)
                                 , "ownerReferences"
                                     .= [ object
                                            [ "kind" .= ("Deployment" :: Text)
                                            , "name" .= ("client" :: Text)
                                            , "uid" .= (uid :: Text)
                                            ]
                                        ]
                                 ]
                           , "spec" .= object ["replicas" .= (desired :: Int)]
                           , "status" .= object ["replicas" .= (current :: Int)]
                           ]
                       ]
                ]
            pod phase =
              object
                [ "items"
                    .= [ object
                           [ "metadata"
                               .= object
                                 [ "namespace" .= ("restore-space" :: Text)
                                 , "labels" .= object ["app" .= ("client" :: Text)]
                                 , "ownerReferences"
                                     .= [ object
                                            [ "kind" .= ("ReplicaSet" :: Text)
                                            , "name" .= ("client-123" :: Text)
                                            , "uid" .= (replicaUid :: Text)
                                            ]
                                        ]
                                 ]
                           , "status" .= object ["phase" .= (phase :: Text)]
                           ]
                       ]
                ]
            emptyPods = object ["items" .= ([] :: [Value])]
        pin <-
          right
            ( Deployment.mkDeploymentWriterPin
                "restore-space"
                "client"
                uid
                1
                ( known
                    ( Deployment.digestDeploymentWriterSpec
                        (deployment 1 1 1 "old")
                    )
                )
                (Map.singleton "app" "client")
            )
        current <- newIORef (deployment 1 1 1 "old")
        replicaSets <- newIORef (replicaSet 1 1)
        pods <- newIORef (pod "Running")
        patches <- newIORef (0 :: Int)
        let transport =
              Deployment.DeploymentWriterTransport
                { Deployment.readDeploymentWriter = \_ _ -> Right <$> readIORef current
                , Deployment.patchDeploymentWriter = \_ _ _ -> do
                    count <- atomicModifyIORef' patches (\n -> (n + 1, n + 1))
                    writeIORef
                      current
                      ( deployment
                          (if count == 1 then 0 else 1)
                          (if count == 1 then 1 else 0)
                          count
                          "old"
                      )
                    pure (Right ())
                , Deployment.listDeploymentReplicaSets = \_ -> Right <$> readIORef replicaSets
                , Deployment.listDeploymentPods = \_ -> Right <$> readIORef pods
                }
        Deployment.stopDeploymentWriter transport pin >>= (@?= Right ())
        Deployment.observeDeploymentWriterStopped transport pin >>= (@?= Right False)
        writeIORef current (deployment 0 0 2 "old")
        writeIORef replicaSets (replicaSet 0 0)
        Deployment.observeDeploymentWriterStopped transport pin >>= (@?= Right False)
        writeIORef pods emptyPods
        Deployment.observeDeploymentWriterStopped transport pin >>= (@?= Right True)
        writeIORef current (deployment 0 0 2 "changed")
        Deployment.observeDeploymentWriterStopped transport pin >>= \case
          Left reason ->
            assertBool
              "changed Deployment template was accepted"
              ("differs from reviewed writer intent" `T.isInfixOf` reason)
          Right _ -> assertFailure "changed Deployment template acquired exclusion"
        writeIORef current (deployment 0 0 2 "old")
        wrongSelector <-
          right
            ( Deployment.mkDeploymentWriterPin
                "restore-space"
                "client"
                uid
                1
                ( known
                    ( Deployment.digestDeploymentWriterSpec
                        (deployment 1 1 1 "old")
                    )
                )
                (Map.singleton "app" "other")
            )
        Deployment.observeDeploymentWriterStopped transport wrongSelector
          >>= \case
            Left reason ->
              assertBool
                "changed Deployment selector was accepted"
                ("selector differs" `T.isInfixOf` reason)
            Right _ -> assertFailure "changed Deployment selector acquired exclusion"
        Deployment.restoreDeploymentWriter transport pin >>= (@?= Right ())
        Deployment.observeDeploymentWriterRelease transport pin
          >>= (@?= Right WritersPartlyReleased)
        writeIORef current (deployment 1 1 3 "old")
        Deployment.observeDeploymentWriterRelease transport pin
          >>= (@?= Right WritersFullyReleased)
    , testCase "StatefulSet writer scale and release require observed convergence" $ do
        let uid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        pin <-
          right
            ( mkStatefulWriterPin
                "restore-space"
                "database"
                uid
                2
                ( known
                    ( digestStatefulWriterSpec
                        ( object
                            [ "spec"
                                .= object
                                  ["replicas" .= (2 :: Int)]
                            ]
                        )
                    )
                )
            )
        current <-
          newIORef
            ( object
                [ "metadata"
                    .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("database" :: Text)
                      , "uid" .= (uid :: Text)
                      , "resourceVersion" .= ("10" :: Text)
                      , "generation" .= (1 :: Int)
                      ]
                , "spec" .= object ["replicas" .= (2 :: Int)]
                , "status"
                    .= object
                      [ "observedGeneration" .= (1 :: Int)
                      , "replicas" .= (2 :: Int)
                      , "readyReplicas" .= (2 :: Int)
                      ]
                ]
            )
        patches <- newIORef ([] :: [Value])
        loseAck <- newIORef True
        let replaceObject key update (Object fields)
              | Just (Object nested) <- KM.lookup key fields =
                  Object (KM.insert key (Object (update nested)) fields)
            replaceObject _ _ value = value
            setSpecReplicas replicas =
              replaceObject
                "spec"
                (KM.insert "replicas" (toJSON replicas))
            setStatus replicas generation =
              replaceObject
                "status"
                ( KM.insert "observedGeneration" (toJSON generation)
                    . KM.insert "readyReplicas" (toJSON replicas)
                    . KM.insert "replicas" (toJSON replicas)
                )
            setMetadata =
              replaceObject
                "metadata"
                ( KM.insert "resourceVersion" (String "11")
                    . KM.insert "generation" (toJSON (2 :: Int))
                )
            transport =
              StatefulWriterTransport
                { readStatefulWriter = \_ _ -> Right <$> readIORef current
                , patchStatefulWriter = \_ _ patch -> do
                    modifyIORef' patches (<> [patch])
                    let requested = case patch of
                          Array operations
                            | Just (Object lastOp) <-
                                listToMaybe (reverse (toList operations)) ->
                                KM.lookup "value" lastOp
                          _ -> Nothing
                    case requested of
                      Just (Number value) -> do
                        modifyIORef' current (setMetadata . setSpecReplicas value)
                        lost <- readIORef loseAck
                        if lost
                          then writeIORef loseAck False >> pure (Left "response lost")
                          else pure (Right ())
                      _ -> pure (Left "patch did not replace replicas")
                }
        stopStatefulWriter transport pin >>= (@?= Left "response lost")
        stopStatefulWriter transport pin >>= (@?= Right ())
        readIORef patches >>= \values -> length values @?= 1
        modifyIORef'
          current
          ( replaceObject
              "spec"
              (KM.insert "serviceName" (String "changed"))
          )
        observeStatefulWriterStopped transport pin >>= \case
          Left reason ->
            assertBool
              "changed StatefulSet spec was not refused"
              ("differs from reviewed writer intent" `T.isInfixOf` reason)
          Right _ -> assertFailure "changed StatefulSet spec acquired exclusion"
        modifyIORef' current (replaceObject "spec" (KM.delete "serviceName"))
        observeStatefulWriterStopped transport pin >>= (@?= Right False)
        restoreStatefulWriter transport pin
          >>= (@?= Left "StatefulSet has not finished stopping")
        modifyIORef' current (setStatus (0 :: Int) (2 :: Int))
        observeStatefulWriterStopped transport pin >>= (@?= Right True)
        observeStatefulWriterRelease transport pin >>= (@?= Right WritersStillExcluded)
        restoreStatefulWriter transport pin >>= (@?= Right ())
        observeStatefulWriterRelease transport pin >>= (@?= Right WritersPartlyReleased)
        modifyIORef' current (setStatus (2 :: Int) (2 :: Int))
        observeStatefulWriterRelease transport pin >>= (@?= Right WritersFullyReleased)
        restoreStatefulWriter transport pin >>= (@?= Right ())
        readIORef patches >>= \values -> length values @?= 2
        modifyIORef'
          current
          ( replaceObject
              "metadata"
              (KM.insert "uid" (String "bbbbbbbb-2222-3333-4444-555555555555"))
          )
        stopped <- stopStatefulWriter transport pin
        case stopped of
          Left _ -> pure ()
          Right () -> assertFailure "replaced StatefulSet UID was accepted"
    , testCase "scheduled writer waits for already-started Jobs and Pods" $ do
        let cronUid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" :: Text
            jobUid = "11111111-2222-3333-4444-555555555555" :: Text
            namespace = "restore-space" :: Text
            cronName = "nagare-dbbackup-database" :: Text
            cron suspended active uid =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= namespace
                      , "name" .= cronName
                      , "uid" .= (uid :: Text)
                      , "resourceVersion" .= ("10" :: Text)
                      ]
                , "spec" .= object ["suspend" .= suspended]
                , "status"
                    .= object
                      [ "active"
                          .= if active
                            then [object ["uid" .= jobUid]]
                            else ([] :: [Value])
                      ]
                ]
            job active =
              object
                [ "items"
                    .= [ object
                           [ "metadata"
                               .= object
                                 [ "namespace" .= namespace
                                 , "name" .= (cronName <> "-12345678")
                                 , "uid" .= jobUid
                                 , "ownerReferences"
                                     .= [ object
                                            [ "kind" .= ("CronJob" :: Text)
                                            , "name" .= cronName
                                            , "uid" .= cronUid
                                            , "controller" .= True
                                            ]
                                        ]
                                 ]
                           , "status" .= object ["active" .= (if active then 1 else 0 :: Int)]
                           ]
                       ]
                ]
            pod phase =
              object
                [ "items"
                    .= [ object
                           [ "metadata"
                               .= object
                                 [ "namespace" .= namespace
                                 , "name" .= (cronName <> "-12345678-pod")
                                 , "ownerReferences"
                                     .= [ object
                                            [ "kind" .= ("Job" :: Text)
                                            , "name" .= (cronName <> "-12345678")
                                            , "uid" .= jobUid
                                            , "controller" .= True
                                            ]
                                        ]
                                 ]
                           , "status" .= object ["phase" .= (phase :: Text)]
                           ]
                       ]
                ]
        pin <-
          right
            ( mkScheduledWriterPin
                namespace
                cronName
                cronUid
                (Just False)
                (known (digestScheduledWriterSpec (cron False True cronUid)))
            )
        current <- newIORef (cron False True cronUid)
        activeJob <- newIORef True
        podPhase <- newIORef ("Running" :: Text)
        patches <- newIORef (0 :: Int)
        loseAck <- newIORef True
        let transport =
              ScheduledWriterTransport
                { readScheduledWriter = \_ _ -> Right <$> readIORef current
                , patchScheduledWriter = \_ _ patch -> do
                    modifyIORef' patches (+ 1)
                    let desired = case patch of
                          Array operations
                            | Just (Object lastOp) <-
                                listToMaybe (reverse (toList operations)) ->
                                KM.lookup "value" lastOp
                          _ -> Nothing
                    case desired of
                      Just (Bool value) -> do
                        writeIORef current (cron value True cronUid)
                        lost <- readIORef loseAck
                        if lost
                          then
                            writeIORef loseAck False
                              >> pure (Left "CronJob patch acknowledgement lost")
                          else pure (Right ())
                      _ -> pure (Left "CronJob patch did not set suspend")
                , listScheduledJobs = \_ -> Right . job <$> readIORef activeJob
                , listScheduledPods = \_ -> Right . pod <$> readIORef podPhase
                }
        stopScheduledWriter transport pin
          >>= (@?= Left "CronJob patch acknowledgement lost")
        stopScheduledWriter transport pin >>= (@?= Right ())
        readIORef patches >>= (@?= 1)
        writeIORef
          current
          ( object
              [ "metadata"
                  .= object
                    [ "namespace" .= namespace
                    , "name" .= cronName
                    , "uid" .= cronUid
                    , "resourceVersion" .= ("10" :: Text)
                    ]
              , "spec"
                  .= object
                    [ "suspend" .= True
                    , "schedule" .= ("* * * * *" :: Text)
                    ]
              ]
          )
        observeScheduledWriterStopped transport pin >>= \case
          Left reason ->
            assertBool
              "changed CronJob spec was not refused"
              ("differs from reviewed writer intent" `T.isInfixOf` reason)
          Right _ -> assertFailure "changed CronJob spec acquired exclusion"
        writeIORef current (cron True True cronUid)
        observeScheduledWriterStopped transport pin >>= (@?= Right False)
        restoreScheduledWriter transport pin >>= (@?= Left "CronJob Jobs have not drained")
        writeIORef activeJob False
        writeIORef podPhase "Succeeded"
        writeIORef current (cron True False cronUid)
        observeScheduledWriterStopped transport pin >>= (@?= Right True)
        observeScheduledWriterRelease transport pin >>= (@?= Right WritersStillExcluded)
        restoreScheduledWriter transport pin >>= (@?= Right ())
        observeScheduledWriterRelease transport pin >>= (@?= Right WritersFullyReleased)
        readIORef patches >>= (@?= 2)
        writeIORef
          current
          ( cron
              False
              False
              "bbbbbbbb-2222-3333-4444-555555555555"
          )
        observeScheduledWriterIdentity transport pin >>= \case
          Left _ -> pure ()
          Right () -> assertFailure "replaced CronJob UID was accepted"
    , testCase "writer discovery includes dependency and direct-mount clients" $ do
        let cluster =
              mintResourceId
                fenceOwner
                (known (mkLogicalKey "cluster"))
                (known (mkName "cluster"))
            statefulId =
              mintResourceId
                fenceOwner
                (known (mkLogicalKey "database"))
                (known (mkName "statefulset"))
            serviceId =
              mintResourceId
                fenceOwner
                (known (mkLogicalKey "database-route"))
                (known (mkName "service"))
            clientId =
              mintResourceId
                fenceOwner
                (known (mkLogicalKey "client"))
                (known (mkName "deployment"))
            mountId =
              mintResourceId
                fenceOwner
                (known (mkLogicalKey "mount"))
                (known (mkName "job"))
            unrelatedId =
              mintResourceId
                fenceOwner
                (known (mkLogicalKey "unrelated"))
                (known (mkName "deployment"))
            native =
              object
                [ "spec"
                    .= object
                      [ "template"
                          .= object
                            ["spec" .= object ["containers" .= ([] :: [Value])]]
                      ]
                ]
            mounted =
              object
                [ "spec"
                    .= object
                      [ "template"
                          .= object
                            [ "spec"
                                .= object
                                  [ "volumes"
                                      .= [ object
                                             [ "persistentVolumeClaim"
                                                 .= object
                                                   ["claimName" .= ("data-pvc" :: Text)]
                                             ]
                                         ]
                                  ]
                            ]
                      ]
                ]
            member resource group kind deps value =
              ( ManagedResource
                  resource
                  fenceOwner
                  KubernetesExecutor
                  ( Kubernetes
                      cluster
                      group
                      (known (mkName kind))
                      (Just (known (mkName "restore-space")))
                      (known (mkName (resourceIdText resource & T.take 30)))
                  )
                  []
                  (NativeObject (contentDigest (BL.toStrict (encode value))))
                  Retain
                  Stateless
                  Public
                  deps
                  []
                  (SourceLocation "fixture" kind)
              , BL.toStrict (encode value)
              )
            stateful = member statefulId "apps" "statefulset" [] native
            service =
              member
                serviceId
                ""
                "service"
                []
                ( object
                    [ "spec"
                        .= object
                          [ "selector"
                              .= object
                                ["nagare.dev/database" .= ("database" :: Text)]
                          ]
                    ]
                )
            client =
              member
                clientId
                "apps"
                "deployment"
                [OrderedAfter statefulId]
                native
            routeClient =
              member
                clientId
                "apps"
                "deployment"
                [OrderedAfter serviceId]
                native
            directMount = member mountId "batch" "job" [] mounted
            unrelated = member unrelatedId "apps" "deployment" [] native
            registry entries =
              Map.fromList
                [(resource ^. #identity, (resource, bytes)) | (resource, bytes) <- entries]
            declarations entries = [Managed resource | (resource, _) <- entries]
        selected <-
          right
            ( discoverWriterCandidates
                statefulId
                cluster
                "data-pvc"
                (declarations [stateful, unrelated])
                (registry [stateful, unrelated])
            )
        map candidateResource selected @?= [statefulId]
        dependent <-
          right
            ( discoverWriterCandidates
                statefulId
                cluster
                "data-pvc"
                (declarations [stateful, client])
                (registry [stateful, client])
            )
        assertBool
          "dependent Deployment was not discovered"
          ( any
              ( \candidate ->
                  candidateResource candidate == clientId
                    && candidateKind candidate == DeploymentWriter
              )
              dependent
          )
        routed <-
          right
            ( discoverWriterCandidatesForRoutes
                statefulId
                [serviceId]
                cluster
                "data-pvc"
                (declarations [stateful, service, routeClient])
                (registry [stateful, service, routeClient])
            )
        assertBool
          "Service-dependent Deployment was not discovered"
          ( any
              ( \candidate ->
                  candidateResource candidate == clientId
                    && candidateKind candidate == DeploymentWriter
              )
              routed
          )
        isolated <-
          right
            ( discoverWriterCandidatesForIsolatedNetwork
                statefulId
                [serviceId]
                cluster
                "data-pvc"
                (declarations [stateful, service, routeClient])
                (registry [stateful, service, routeClient])
            )
        map candidateResource isolated @?= [statefulId]
        isolatedMount <-
          right
            ( discoverWriterCandidatesForIsolatedNetwork
                statefulId
                []
                cluster
                "data-pvc"
                (declarations [stateful, directMount])
                (registry [stateful, directMount])
            )
        assertBool
          "network isolation hid a direct PVC mount"
          ( any
              ( \candidate ->
                  candidateResource candidate == mountId
                    && candidateKind candidate == JobWriter
              )
              isolatedMount
          )
        direct <-
          right
            ( discoverWriterCandidates
                statefulId
                cluster
                "data-pvc"
                (declarations [stateful, directMount])
                (registry [stateful, directMount])
            )
        assertBool
          "direct PVC mount was not discovered"
          ( any
              ( \candidate ->
                  candidateResource candidate == mountId
                    && candidateKind candidate == JobWriter
              )
              direct
          )
        case discoverWriterCandidates
          statefulId
          cluster
          "data-pvc"
          (declarations [stateful, directMount])
          (registry [stateful]) of
          Left reason ->
            assertBool
              "missing accepted native Job was not refused"
              (resourceIdText mountId `T.isInfixOf` reason)
          Right _ -> assertFailure "missing native evidence hid a PVC mount"
    , testCase "completed Job pin refuses active Pods and changed native identity" $ do
        let namespace = "restore-space"
            name = "completed-backup"
            uid = "eeeeeeee-1111-2222-3333-444444444444" :: Text
            job :: Text -> Value -> Value
            job selectedUid specValue =
              object
                [ "metadata"
                    .= object
                      ["namespace" .= namespace, "name" .= name, "uid" .= selectedUid]
                , "spec" .= specValue
                , "status"
                    .= object
                      [ "succeeded" .= (1 :: Int)
                      , "conditions"
                          .= [ object
                                 ["type" .= ("Complete" :: Text), "status" .= ("True" :: Text)]
                             ]
                      ]
                ]
            pod :: Text -> Value
            pod phase =
              object
                [ "metadata"
                    .= object
                      [ "namespace" .= namespace
                      , "name" .= ("completed-backup-pod" :: Text)
                      , "uid" .= ("aaaaeeee-1111-2222-3333-444444444444" :: Text)
                      , "ownerReferences"
                          .= [ object
                                 [ "kind" .= ("Job" :: Text)
                                 , "name" .= name
                                 , "uid" .= uid
                                 , "controller" .= True
                                 ]
                             ]
                      ]
                , "status" .= object ["phase" .= phase]
                ]
            podList :: Text -> Value
            podList phase = object ["items" .= [pod phase]]
        jobState <- newIORef (job uid (object ["parallelism" .= (1 :: Int)]))
        podState <- newIORef (podList ("Succeeded" :: Text))
        let transport =
              CompletedJobTransport
                (\_ _ -> Right <$> readIORef jobState)
                (\_ -> Right <$> readIORef podState)
        pin <- captureCompletedJob transport namespace name >>= right
        observeCompletedJob transport pin >>= right
        writeIORef podState (podList ("Running" :: Text))
        active <- observeCompletedJob transport pin
        assertBool "active Job Pod was accepted" (isLeft active)
        writeIORef podState (podList ("Succeeded" :: Text))
        writeIORef
          jobState
          ( job
              "ffffeeee-1111-2222-3333-444444444444"
              (object ["parallelism" .= (1 :: Int)])
          )
        replaced <- observeCompletedJob transport pin
        assertBool "replacement Job UID was accepted" (isLeft replaced)
        writeIORef jobState (job uid (object ["parallelism" .= (2 :: Int)]))
        changed <- observeCompletedJob transport pin
        assertBool "changed Job spec was accepted" (isLeft changed)
    , testCase "reviewed adapter effect runs only inside a verified fence" $ do
        store <- newMemoryStore
        steps <- newIORef ([] :: [Text])
        captures <- newIORef (0 :: Int)
        released <- newIORef False
        let recordStep step = modifyIORef' steps (<> [step])
            controls =
              DataFenceControls
                { validateFenceInputs = \_ -> pure (Right ())
                , stopFenceWriters = \_ -> recordStep "stop" >> pure (Right ())
                , observeFencePhysical = \_ -> pure (Right physical)
                , observeWritersExcluded = \_ -> pure (Right True)
                , verifyRecoveredData = \_ -> recordStep "verify-data" >> pure (Right True)
                , restoreFenceWriters = \_ -> do
                    recordStep "release"
                    writeIORef released True
                    pure (Right ())
                , observeWritersReleased = \_ -> do
                    wasReleased <- readIORef released
                    pure (Right (if wasReleased then WritersFullyReleased else WritersStillExcluded))
                , forwardRecoverPartlyReleased = Nothing
                }
            customize desired registry =
              known
                ( withAdapterFence
                    registry
                    KubernetesExecutor
                    AdapterFence
                      { fenceCapability = "recorded-fence-v1"
                      , fenceForOperation = \_ _ -> do
                          modifyIORef' captures (+ 1)
                          pure
                            ( Right
                                ( Just
                                    (request {fenceContext = fixtureBinding, fenceAccepted = desired})
                                )
                            )
                      , fenceFromReviewedRecord = \_ _ _ -> Right controls
                      , fenceResolveUncertainEffect = Nothing
                      , fenceRestoreRecoveryBackup = Nothing
                      , fenceVerifyRecoveryBackup = Nothing
                      }
                )
            effect _ _ = recordStep "effect" >> pure AdapterEffectCompleted
            recovery _ _ = pure RecoverySafeToRetry
        (reviewed, _) <- preparedFixtureWithRegistry store effect recovery customize
        readIORef captures >>= (@?= 1)
        assertBool
          "review must bind the fence capability"
          ( any
              ((== Just "recorded-fence-v1") . reviewFenceCapability)
              (reviewOperations (reviewedDocument reviewed))
          )
        assertBool
          "review must bind exact fence inputs"
          ( any
              (isJust . reviewFenceDigest)
              (reviewOperations (reviewedDocument reviewed))
          )
        assertBool
          "review must show fence and recovery steps"
          ( any
              ( maybe False (T.isInfixOf "data fence: acquire, verify, release")
                  . reviewFenceSummary
              )
              (reviewOperations (reviewedDocument reviewed))
          )
        case [ digest
             | operation <- reviewOperations (reviewedDocument reviewed)
             , Just digest <- [reviewFenceDigest operation]
             ] of
          [digest] -> do
            snapshot <- readStoreSnapshot store >>= right
            published <- case Set.toList (storeSnapshotReviewDigests snapshot) of
              [reviewId] -> loadPublishedReview store reviewId >>= right
              _ -> assertFailure "review store lacks one published review" >> error "review"
            bytes <-
              maybe
                ( assertFailure "private fence record was not published"
                    >> error "fence"
                )
                pure
                (Map.lookup digest (reviewBundleNative published))
            saved <- right (eitherDecodeStrict' bytes :: Either String DataFenceRecord)
            dataFenceIntentDigest saved @?= digest
            fenceRecoveryArtifact saved @?= "gs://fixture/recovery"
            case [ operation
                 | operation <- reviewOperations (reviewedDocument reviewed)
                 , reviewFenceDigest operation == Just digest
                 ] of
              [operation] -> do
                reviewBundleFenceRecord published operation @?= Right (Just saved)
                withSystemTempDirectory "nagare-public-fence-review" $ \root -> do
                  _ <- writeReviewBundle (root <> "/review") published >>= right
                  public <- loadReviewBundle (root <> "/review") >>= right
                  reviewBundleNative public @?= Map.empty
                  case reviewBundleFenceRecord public operation of
                    Left _ -> pure ()
                    Right _ -> assertFailure "public review supplied a private fence"
              _ -> assertFailure "published review lacks one fenced operation"
          _ -> assertFailure "review lacks one fence digest"
        let expected =
              request
                { fenceContext = fixtureBinding
                , fenceAccepted = reviewDesiredRevisions (reviewedDocument reviewed)
                }
            fresh =
              known
                ( withAdapterFence
                    (recordingRegistryWith (\_ _ -> pure (Right ())) effect recovery)
                    KubernetesExecutor
                    AdapterFence
                      { fenceCapability = "recorded-fence-v1"
                      , fenceForOperation = \_ _ ->
                          pure
                            ( Left
                                "planning capture must not run during apply"
                            )
                      , fenceFromReviewedRecord = \saved _ _ ->
                          if saved == expected
                            then Right controls
                            else Left "apply did not use the exact reviewed fence record"
                      , fenceResolveUncertainEffect = Nothing
                      , fenceRestoreRecoveryBackup = Nothing
                      , fenceVerifyRecoveryBackup = Nothing
                      }
                )
        outcome <- applyReviewed store fresh reviewed >>= right
        readIORef captures >>= (@?= 1)
        case outcome of
          Converged _ -> pure ()
          _ -> assertFailure "fenced reviewed operation did not converge"
        observed <- readIORef steps
        let position step =
              maybe
                (error ("missing " <> T.unpack step))
                id
                (elemIndex step observed)
        assertBool "writer stop precedes effect" (position "stop" < position "effect")
        assertBool
          "data verification follows effect"
          (position "effect" < position "verify-data")
        assertBool
          "release follows verification"
          (position "verify-data" < position "release")
        final <-
          readHead store
            >>= right
            >>= maybe
              (assertFailure "head missing" >> error "head")
              pure
        headDataFence final @?= Nothing
    , testCase "review selects and replays one of two fence capabilities" $ do
        store <- newMemoryStore
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let controls = fixtureControls released restored (pure (Right physical))
            effect _ _ = pure AdapterEffectCompleted
            recovery _ _ = pure RecoverySafeToRetry
            customize desired registry = known $ do
              firstRegistry <-
                withAdapterFence
                  registry
                  KubernetesExecutor
                  AdapterFence
                    { fenceCapability = "a-unselected-fence-v1"
                    , fenceForOperation = \_ _ -> pure (Right Nothing)
                    , fenceFromReviewedRecord = \_ _ _ ->
                        Left
                          "unselected fence replayed"
                    , fenceResolveUncertainEffect = Nothing
                    , fenceRestoreRecoveryBackup = Nothing
                    , fenceVerifyRecoveryBackup = Nothing
                    }
              withAdapterFence
                firstRegistry
                KubernetesExecutor
                AdapterFence
                  { fenceCapability = "b-selected-fence-v1"
                  , fenceForOperation = \_ _ ->
                      pure
                        ( Right
                            ( Just
                                ( request
                                    { fenceContext = fixtureBinding
                                    , fenceAccepted = desired
                                    }
                                )
                            )
                        )
                  , fenceFromReviewedRecord = \_ _ _ -> Right controls
                  , fenceResolveUncertainEffect = Nothing
                  , fenceRestoreRecoveryBackup = Nothing
                  , fenceVerifyRecoveryBackup = Nothing
                  }
        (reviewed, registry) <-
          preparedFixtureWithRegistry
            store
            effect
            recovery
            customize
        assertBool
          "review selected the wrong capability"
          ( any
              ((== Just "b-selected-fence-v1") . reviewFenceCapability)
              (reviewOperations (reviewedDocument reviewed))
          )
        applied <- applyReviewed store registry reviewed >>= right
        case applied of
          Converged _ -> pure ()
          _ -> assertFailure "the selected fence did not converge"
        readIORef restored >>= (@?= 1)
    , testCase "saved fenced review refuses a registry without its capability" $ do
        store <- newMemoryStore
        effects <- newIORef (0 :: Int)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let controls = fixtureControls released restored (pure (Right physical))
            effect _ _ = modifyIORef' effects (+ 1) >> pure AdapterEffectCompleted
            recovery _ _ = pure RecoverySafeToRetry
            customize desired registry =
              known
                ( withAdapterFence
                    registry
                    KubernetesExecutor
                    AdapterFence
                      { fenceCapability = "recorded-fence-v1"
                      , fenceForOperation = \_ _ ->
                          pure
                            ( Right
                                ( Just
                                    (request {fenceContext = fixtureBinding, fenceAccepted = desired})
                                )
                            )
                      , fenceFromReviewedRecord = \_ _ _ -> Right controls
                      , fenceResolveUncertainEffect = Nothing
                      , fenceRestoreRecoveryBackup = Nothing
                      , fenceVerifyRecoveryBackup = Nothing
                      }
                )
        (reviewed, _) <- preparedFixtureWithRegistry store effect recovery customize
        let plain = recordingRegistryWith (\_ _ -> pure (Right ())) effect recovery
        refused <- applyReviewed store plain reviewed
        case refused of
          Left errors ->
            assertBool
              "missing fence capability was not refused"
              (any ((== "data-fence-capability") . admissionErrorCode) errors)
          Right _ -> assertFailure "fenced review ran without the fence provider"
        let changedPhysical =
              Map.insert
                target
                (known (mkPhysicalIdentity "substituted-uid"))
                physical
            altered =
              known
                ( withAdapterFence
                    plain
                    KubernetesExecutor
                    AdapterFence
                      { fenceCapability = "recorded-fence-v1"
                      , fenceForOperation = \_ _ ->
                          pure
                            (Left "planning hook must not run during apply")
                      , fenceFromReviewedRecord = \saved _ _ ->
                          if fencePhysical saved == changedPhysical
                            then Right controls
                            else Left "reviewed physical target differs from provider expectation"
                      , fenceResolveUncertainEffect = Nothing
                      , fenceRestoreRecoveryBackup = Nothing
                      , fenceVerifyRecoveryBackup = Nothing
                      }
                )
        substituted <- applyReviewed store altered reviewed
        case substituted of
          Left errors ->
            assertBool
              "changed physical target escaped review digest"
              (any ((== "data-fence-capability") . admissionErrorCode) errors)
          Right _ -> assertFailure "fenced review admitted a substituted target"
        let provider =
              known
                ( withAdapterFence
                    plain
                    KubernetesExecutor
                    AdapterFence
                      { fenceCapability = "recorded-fence-v1"
                      , fenceForOperation = \_ _ ->
                          pure
                            (Left "planning hook must not run during apply")
                      , fenceFromReviewedRecord = \saved _ _ ->
                          if fenceProviderIntent saved == Just (object ["version" .= (1 :: Int)])
                            then Right controls
                            else Left "reviewed provider intent differs from provider expectation"
                      , fenceResolveUncertainEffect = Nothing
                      , fenceRestoreRecoveryBackup = Nothing
                      , fenceVerifyRecoveryBackup = Nothing
                      }
                )
        substitutedProvider <- applyReviewed store provider reviewed
        case substitutedProvider of
          Left errors ->
            assertBool
              "changed provider intent escaped review digest"
              (any ((== "data-fence-capability") . admissionErrorCode) errors)
          Right _ -> assertFailure "fenced review admitted substituted provider intent"
        readIORef effects >>= (@?= 0)
    , testCase "reviewed acquisition continues after drain without a second data effect" $ do
        store <- newMemoryStore
        drainReady <- newIORef False
        effects <- newIORef (0 :: Int)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let base = fixtureControls released restored (pure (Right physical))
            controls =
              base
                { stopFenceWriters = \_ -> do
                    ready <- readIORef drainReady
                    pure (if ready then Right () else Left "writer is still draining")
                }
            effect _ _ = modifyIORef' effects (+ 1) >> pure AdapterEffectCompleted
            recovery _ _ = pure RecoverySafeToRetry
            customize desired registry =
              known
                ( withAdapterFence
                    registry
                    KubernetesExecutor
                    AdapterFence
                      { fenceCapability = "recorded-fence-v1"
                      , fenceForOperation = \_ _ ->
                          pure
                            ( Right
                                ( Just
                                    (request {fenceContext = fixtureBinding, fenceAccepted = desired})
                                )
                            )
                      , fenceFromReviewedRecord = \_ _ _ -> Right controls
                      , fenceResolveUncertainEffect = Nothing
                      , fenceRestoreRecoveryBackup = Nothing
                      , fenceVerifyRecoveryBackup = Nothing
                      }
                )
        (reviewed, registry) <- preparedFixtureWithRegistry store effect recovery customize
        outcome <- applyReviewed store registry reviewed >>= right
        (transaction, operation) <- case outcome of
          StoppedAmbiguous value selected -> pure (value, selected)
          _ ->
            assertFailure "draining fence did not stop the reviewed effect"
              >> error "transaction"
        current <-
          readHead store
            >>= right
            >>= maybe
              (assertFailure "head missing" >> error "head")
              pure
        fmap fencePhase (headDataFence current) @?= Just FenceAcquiring
        readIORef effects >>= (@?= 0)
        let decision =
              OperatorRecoveryInput
                transaction
                operation
                (known (mkContentDigest (T.drop 3 (transactionIdText transaction))))
                ContinueFencedOperation
        pending <- recordOperatorRecovery store registry decision False
        case pending of
          Left errors ->
            assertBool
              "ongoing drain was not kept fenced"
              (any ((== "data-fence") . admissionErrorCode) errors)
          Right () -> assertFailure "draining writer admitted a data effect"
        readIORef effects >>= (@?= 0)
        writeIORef drainReady True
        recordOperatorRecovery store registry decision False >>= right
        readIORef effects >>= (@?= 1)
        readIORef restored >>= (@?= 1)
        resumeTransaction store registry transaction >>= right >>= \case
          Converged _ -> pure ()
          _ -> assertFailure "recovered reviewed transaction did not converge"
        readIORef effects >>= (@?= 1)
    , testCase "ambiguous reviewed effect keeps its fence and refuses replay" $ do
        store <- newMemoryStore
        effects <- newIORef (0 :: Int)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let controls = fixtureControls released restored (pure (Right physical))
            effect _ _ = do
              modifyIORef' effects (+ 1)
              pure (AdapterEffectAmbiguous "effect acknowledgement lost")
            recovery _ _ = pure RecoverySafeToRetry
            customize desired registry =
              known
                ( withAdapterFence
                    registry
                    KubernetesExecutor
                    AdapterFence
                      { fenceCapability = "recorded-fence-v1"
                      , fenceForOperation = \_ _ ->
                          pure
                            ( Right
                                ( Just
                                    ( request
                                        { fenceContext = fixtureBinding
                                        , fenceAccepted = desired
                                        }
                                    )
                                )
                            )
                      , fenceFromReviewedRecord = \_ _ _ -> Right controls
                      , fenceResolveUncertainEffect = Nothing
                      , fenceRestoreRecoveryBackup = Nothing
                      , fenceVerifyRecoveryBackup = Nothing
                      }
                )
        (reviewed, registry) <- preparedFixtureWithRegistry store effect recovery customize
        outcome <- applyReviewed store registry reviewed >>= right
        (transaction, selectedOperation) <- case outcome of
          StoppedAmbiguous value selected -> pure (value, selected)
          _ -> assertFailure "ambiguous effect did not stop the transaction" >> error "transaction"
        fenced <-
          readHead store
            >>= right
            >>= maybe
              (assertFailure "head missing" >> error "head")
              pure
        fmap fencePhase (headDataFence fenced) @?= Just FenceUnresolved
        resumed <- resumeTransaction store registry transaction
        case resumed of
          Left errors ->
            assertBool
              "ordinary resume bypassed the unresolved fence"
              (any ((== "active-data-fence") . admissionErrorCode) errors)
          Right _ -> assertFailure "ambiguous fenced effect resumed"
        let decision =
              OperatorRecoveryInput
                transaction
                selectedOperation
                (known (mkContentDigest (T.drop 3 (transactionIdText transaction))))
                VerifyFencedEffect
        unproved <- recordOperatorRecovery store registry decision False
        case unproved of
          Left errors ->
            assertBool
              "safe-to-retry was mistaken for effect proof"
              (any ((== "adapter-recovery") . admissionErrorCode) errors)
          Right () -> assertFailure "unproved effect released the data fence"
        token <-
          withProcessLock
            store
            ( \locked ->
                resumeDataFence locked "restore-session"
            )
            >>= right
            >>= right
        _ <-
          withProcessLock
            store
            ( \locked ->
                recoverDataFence locked controls token
            )
            >>= right
            >>= right
        _ <-
          withProcessLock
            store
            ( \locked ->
                releaseDataFence locked controls token
            )
            >>= right
            >>= right
        lostJournal <- resumeTransaction store registry transaction >>= right
        case lostJournal of
          StoppedAmbiguous _ _ -> pure ()
          _ -> assertFailure "safe-to-retry replayed after verified fence release"
        readIORef effects >>= (@?= 1)
        readIORef restored >>= (@?= 1)
    , testCase "only explicit recovery invokes a reviewed fenced resolver" $ do
        store <- newMemoryStore
        effects <- newIORef (0 :: Int)
        resolutions <- newIORef (0 :: Int)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let controls = fixtureControls released restored (pure (Right physical))
            effect _ _ = do
              modifyIORef' effects (+ 1)
              pure (AdapterEffectAmbiguous "terminal parent died")
            recovery _ _ = pure (RecoveryUnresolved "explicit session recovery required")
            customize desired registry =
              known
                ( withAdapterFence
                    registry
                    KubernetesExecutor
                    AdapterFence
                      { fenceCapability = "recorded-fence-v1"
                      , fenceForOperation = \_ _ ->
                          pure
                            ( Right
                                ( Just
                                    ( request
                                        { fenceContext = fixtureBinding
                                        , fenceAccepted = desired
                                        }
                                    )
                                )
                            )
                      , fenceFromReviewedRecord = \_ _ _ -> Right controls
                      , fenceResolveUncertainEffect =
                          Just
                            ( \_ _ _ -> do
                                modifyIORef' resolutions (+ 1)
                                pure (RecoveryProvedComplete (contentDigest "terminated-client"))
                            )
                      , fenceRestoreRecoveryBackup = Nothing
                      , fenceVerifyRecoveryBackup = Nothing
                      }
                )
        (reviewed, registry) <- preparedFixtureWithRegistry store effect recovery customize
        applied <- applyReviewed store registry reviewed >>= right
        (transaction, operation) <- case applied of
          StoppedAmbiguous value selected -> pure (value, selected)
          _ ->
            assertFailure "ambiguous effect did not hold its fence"
              >> error "transaction"
        resumeTransaction store registry transaction >>= \case
          Left errors ->
            assertBool
              "ordinary resume escaped the active fence"
              (any ((== "active-data-fence") . admissionErrorCode) errors)
          Right _ -> assertFailure "ordinary resume completed uncertain effect"
        readIORef resolutions >>= (@?= 0)
        let decision =
              OperatorRecoveryInput
                transaction
                operation
                (known (mkContentDigest (T.drop 3 (transactionIdText transaction))))
                VerifyFencedEffect
        recordOperatorRecovery store registry decision False >>= right
        readIORef resolutions >>= (@?= 1)
        readHead store
          >>= right
          >>= maybe
            (assertFailure "head missing" >> error "head")
            (\headValue -> headDataFence headValue @?= Nothing)
        resumeTransaction store registry transaction >>= right >>= \case
          Converged _ -> pure ()
          _ -> assertFailure "explicit recovery did not converge"
        readIORef effects >>= (@?= 1)
        readIORef restored >>= (@?= 1)
    , testCase "failed live effect restores pinned recovery data and abandons the review" $ do
        store <- newMemoryStore
        effects <- newIORef (0 :: Int)
        recoveries <- newIORef (0 :: Int)
        content <- newIORef ("possibly-partial" :: Text)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let recoveryDigest = contentDigest "pre-change-content"
            controls =
              (fixtureControls released restored (pure (Right physical)))
                { verifyRecoveredData = \_ -> pure (Right False)
                }
            effect _ _ = do
              modifyIORef' effects (+ 1)
              pure (AdapterEffectAmbiguous "effect acknowledgement lost")
            recovery _ _ = pure (RecoveryUnresolved "source content is not proved")
            restoreBackup _ _ _ = do
              modifyIORef' recoveries (+ 1)
              writeIORef content "pre-change-content"
              pure (Right recoveryDigest)
            verifyBackup _ _ _ = do
              observed <- readIORef content
              pure $
                if observed == "pre-change-content"
                  then Right recoveryDigest
                  else Left "pre-change content differs"
            customize desired registry =
              known
                ( withAdapterFence
                    registry
                    KubernetesExecutor
                    AdapterFence
                      { fenceCapability = "recorded-fence-v1"
                      , fenceForOperation = \_ _ ->
                          pure
                            ( Right
                                ( Just
                                    ( request
                                        { fenceContext = fixtureBinding
                                        , fenceAccepted = desired
                                        }
                                    )
                                )
                            )
                      , fenceFromReviewedRecord = \_ _ _ -> Right controls
                      , fenceResolveUncertainEffect = Nothing
                      , fenceRestoreRecoveryBackup = Just restoreBackup
                      , fenceVerifyRecoveryBackup = Just verifyBackup
                      }
                )
        (reviewed, registry) <-
          preparedFixtureWithRegistry
            store
            effect
            recovery
            customize
        applied <- applyReviewed store registry reviewed >>= right
        (transaction, operation) <- case applied of
          StoppedAmbiguous value selected -> pure (value, selected)
          _ ->
            assertFailure "ambiguous effect did not retain the fence"
              >> error "transaction"
        let decision action =
              OperatorRecoveryInput
                transaction
                operation
                (known (mkContentDigest (T.drop 3 (transactionIdText transaction))))
                action
        refused <-
          recordOperatorRecovery
            store
            registry
            (decision VerifyFencedEffect)
            False
        assertBool "source content unexpectedly proved complete" (isLeft refused)
        recordOperatorRecovery
          store
          registry
          (decision RecoverFencedBackup)
          False
          >>= right
        readHead store
          >>= right
          >>= maybe
            (assertFailure "head missing" >> error "head")
            ( \headValue -> do
                headDataFence headValue @?= Nothing
                headActiveTransaction headValue @?= Nothing
                headAccepted headValue @?= headConverged headValue
            )
        readIORef effects >>= (@?= 1)
        readIORef recoveries >>= (@?= 1)
        readIORef restored >>= (@?= 1)
        resumeTransaction store registry transaction >>= \case
          Left errors ->
            assertBool
              "abandoned restore became resumable"
              (any ((== "inactive-transaction") . admissionErrorCode) errors)
          Right _ -> assertFailure "abandoned restore resumed"
    , testCase "partial writer release after backup recovery requires forward action" $ do
        store <- newMemoryStore
        releaseState <- newIORef WritersStillExcluded
        recoveries <- newIORef (0 :: Int)
        effects <- newIORef (0 :: Int)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let recoveryDigest = contentDigest "pre-change-content"
            controls =
              (fixtureControls released restored (pure (Right physical)))
                { verifyRecoveredData = \_ -> pure (Right False)
                , restoreFenceWriters = \_ -> do
                    writeIORef releaseState WritersPartlyReleased
                    pure (Left "lost partial writer release acknowledgement")
                , observeWritersReleased = \_ -> Right <$> readIORef releaseState
                , forwardRecoverPartlyReleased =
                    Just
                      ( \_ -> do
                          writeIORef releaseState WritersFullyReleased
                          pure (Right ())
                      )
                }
            effect _ _ = do
              modifyIORef' effects (+ 1)
              pure (AdapterEffectAmbiguous "effect acknowledgement lost")
            recovery _ _ = pure (RecoveryUnresolved "source content is not proved")
            customize desired registry =
              known
                ( withAdapterFence
                    registry
                    KubernetesExecutor
                    AdapterFence
                      { fenceCapability = "recorded-fence-v1"
                      , fenceForOperation = \_ _ ->
                          pure
                            ( Right
                                ( Just
                                    ( request
                                        { fenceContext = fixtureBinding
                                        , fenceAccepted = desired
                                        }
                                    )
                                )
                            )
                      , fenceFromReviewedRecord = \_ _ _ -> Right controls
                      , fenceResolveUncertainEffect = Nothing
                      , fenceRestoreRecoveryBackup =
                          Just
                            ( \_ _ _ -> do
                                modifyIORef' recoveries (+ 1)
                                pure (Right recoveryDigest)
                            )
                      , fenceVerifyRecoveryBackup =
                          Just
                            ( \_ _ _ ->
                                pure (Right recoveryDigest)
                            )
                      }
                )
        (reviewed, registry) <-
          preparedFixtureWithRegistry
            store
            effect
            recovery
            customize
        applied <- applyReviewed store registry reviewed >>= right
        (transaction, operation) <- case applied of
          StoppedAmbiguous value selected -> pure (value, selected)
          _ ->
            assertFailure "ambiguous effect did not retain the fence"
              >> error "transaction"
        let decision action =
              OperatorRecoveryInput
                transaction
                operation
                (known (mkContentDigest (T.drop 3 (transactionIdText transaction))))
                action
        firstAttempt <-
          recordOperatorRecovery
            store
            registry
            (decision RecoverFencedBackup)
            False
        assertBool "partial writer release was accepted" (isLeft firstAttempt)
        readHead store
          >>= right
          >>= maybe
            (assertFailure "head missing" >> error "head")
            ( \headValue ->
                fmap fencePhase (headDataFence headValue)
                  @?= Just FenceReleasing
            )
        ordinary <-
          recordOperatorRecovery
            store
            registry
            (decision RecoverFencedBackup)
            False
        assertBool "ordinary recovery repeated a partial release" (isLeft ordinary)
        readIORef recoveries >>= (@?= 1)
        recordOperatorRecovery
          store
          registry
          (decision ForwardFencedRelease)
          False
          >>= right
        readHead store
          >>= right
          >>= maybe
            (assertFailure "head missing" >> error "head")
            ( \headValue -> do
                headDataFence headValue @?= Nothing
                headActiveTransaction headValue @?= Nothing
                headAccepted headValue @?= headConverged headValue
            )
        readIORef effects >>= (@?= 1)
        readIORef recoveries >>= (@?= 1)
    ]

fixtureControls ::
  IORef Bool ->
  IORef Int ->
  IO (Either Text (Map.Map ResourceId PhysicalIdentity)) ->
  DataFenceControls
fixtureControls released restored observe =
  DataFenceControls
    { validateFenceInputs = \_ -> pure (Right ())
    , stopFenceWriters = \_ -> pure (Right ())
    , observeFencePhysical = \_ -> observe
    , observeWritersExcluded = \_ -> pure (Right True)
    , verifyRecoveredData = \_ -> pure (Right True)
    , restoreFenceWriters = \_ -> do
        modifyIORef' restored (+ 1)
        writeIORef released True
        pure (Right ())
    , observeWritersReleased = \_ -> do
        wasReleased <- readIORef released
        pure (Right (if wasReleased then WritersFullyReleased else WritersStillExcluded))
    , forwardRecoverPartlyReleased = Nothing
    }

request :: DataFenceRecord
request =
  DataFenceRecord
    binding
    "restore-session"
    Nothing
    Map.empty
    physical
    (Set.singleton target)
    (Set.singleton writer)
    "gs://fixture/recovery"
    (contentDigest "recovery")
    (Map.singleton writer (object []))
    Nothing
    FenceAcquiring
    ""

physical :: Map.Map ResourceId PhysicalIdentity
physical =
  Map.fromList
    [ (target, known (mkPhysicalIdentity "target-uid"))
    , (writer, known (mkPhysicalIdentity "writer-uid"))
    ]

binding :: ContextBinding
binding = ContextBinding (known (mkContextId "fence-fixture")) (known (mkName "project"))

fenceOwner :: ScopeId
fenceOwner = known (mkScopeId Standalone "fence-fixture")

target :: ResourceId
target = mintResourceId fenceOwner (known (mkLogicalKey "target")) (known (mkName "pvc"))

writer :: ResourceId
writer = mintResourceId fenceOwner (known (mkLogicalKey "writer")) (known (mkName "deployment"))

known :: (Show e) => Either e a -> a
known = either (error . show) id

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> error "unreachable") pure
