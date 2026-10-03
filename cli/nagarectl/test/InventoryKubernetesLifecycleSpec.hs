module InventoryKubernetesLifecycleSpec
  ( nativeSiblingCarryForward
  , liveTaskDeletionProof
  , liveTaskDeletionCommandProof
  , reviewedManualReceiptCleanup
  , reviewedReleaseCleanup
  )
where

import Control.Exception (finally)
import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (GcsBackend, MinioBackend))
import Nagare.Database.Backup (renderDbBackupCronJob, renderPreviousInventoryDbBackupCronJob, renderPreviousSignedInventoryDbBackupCronJob)
import Nagare.Database.Secret (b64decode)
import Nagare.Dsl.Database (Database (Database), Engine (..), defaultEngineVersion, engineVersionText, mkDatabaseName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Task (scheduledTask)
import Nagare.Dsl.Task.Render (renderTask)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..), backupReceiptFromPodList, cacheClientDataMatches, certificateReady, collectionDeleteRequest, completedJobContainerMessageFromPodList, confirmInventoryFieldOwnership, confirmInventoryFieldOwnershipFor, crdEstablished, credentialDataMatches, deploymentAvailable, deploymentSelectorReplacement, desiredFieldsMatch, generatedCredentialTemplate, jobCompleted, knativeReady, materializeCacheKey, materializeCredential, mkKubernetesRuntimeOps, observeCacheClientOutput, observeKubernetesBatchWithGuard, parseObserved, readinessForAddress, statefulSetImmutableReplacement, statefulSetReady, supportedUpdateAddress, withoutCacheClientData)
import Nagare.Inventory.Backup (BackupReceiptExpectation (..), BackupSourceProof (..), ManualBackupRequest (..), VolumeSnapshotRequest (..), compileManualBackupScope, compileVolumeSnapshotScope, manualBackupJobReceiptExpectation, manualBackupJobSourcePins, manualBackupSourceProof, parseBackupReceipt, parseManualBackupReceipt, volumeSnapshotJobSourcePins)
import Nagare.Inventory.CollectionPolicy (supportsRetainedCollection)
import Nagare.Inventory.Components.Foundation (compileContributedNamespaces)
import Nagare.Inventory.DataService (NativeDataKind (..), compileBackupPruneRemovalScope, compileStandaloneDatabase, compileStatefulSetRestartScope, standaloneStatefulSetOwned)
import Nagare.Inventory.Database (compileDatabaseForBackend)
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed, resumeTransaction)
import Nagare.Inventory.Journal
import Nagare.Inventory.Kubernetes
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.KubernetesSources (loadKubernetesSources)
import Nagare.Inventory.Lifecycle (decideCollection, decideRetirement)
import Nagare.Inventory.LiveRestore (LiveBackupInput (..), LiveBackupProof (..), LiveRestoreProof (..), LiveRestoreRequest (..), LiveScheduledProof (..), compileLiveRestoreScope, liveRestoreProof)
import Nagare.Inventory.LiveRestorePostgres (normalizePostgresDump)
import Nagare.Inventory.LiveRestoreSource (verifyLiveStoredFiles)
import Nagare.Inventory.Maintenance (MaintenanceRequest (..), MaintenanceSourceProof (..), compileMaintenanceScope, maintenanceSourceProof)
import Nagare.Inventory.ManualReceipt (ManualReceiptEvidence (..), compileManualReceiptScope, manualReceiptRecord)
import Nagare.Inventory.ManualReceiptSource (inspectManualReceipt, parseGcsManualMetadata)
import Nagare.Inventory.Plan
import Nagare.Inventory.Prune (ManualPruneRequest (..), PruneSourceProof (..), compileManualPruneScope, manualPruneJobBackupPin, manualPruneSourceProof)
import Nagare.Inventory.Restore (ManualRestoreRequest (..), VolumeRestoreRequest (..), compileManualRestoreScope, compileVolumeRestoreScope, manualRestoreJobTargetPins, manualRestoreTargetProof, volumeRestoreJobSourcePins)
import Nagare.Inventory.ScheduledPrune
  ( ScheduledPruneCandidate (..)
  , ScheduledPruneRequest (..)
  , compileScheduledPruneRecoveryScope
  , compileScheduledPruneScope
  , recoverScheduledPruneCandidate
  )
import Nagare.Inventory.ScheduledStore (StoredObject (..))
import Nagare.Inventory.Status (DriftCategory (ImmutableReplacementRequired), classifyDrift, findingCategory, loadAcceptedNative, loadRetainedNative)
import Nagare.Inventory.Store
import Nagare.Inventory.TaskLifecycle (compileTaskSuspensionScope, retireSuspendedTaskScope, taskSuspended)
import Nagare.Inventory.VolumePrune (VolumePruneRequest (..), compileVolumePruneScope, volumePruneJobCredentialPin)
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Inventory hiding (cluster)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue, encodeCanonicalScope)
import Nagare.Storage.Discover (pvcName)
import Nagare.Test.Support.Kubernetes
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode, readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

nativeSiblingCarryForward :: IO ()
nativeSiblingCarryForward = do
  let binding =
        ContextBinding
          (ok (mkContextId "native-carry-forward"))
          (ok (mkName "project"))
      siblingId = mintResourceId scope (ok (mkLogicalKey "sibling")) (ok (mkName "resource"))
      siblingValue =
        object
          [ "apiVersion" .= ("v1" :: Text)
          , "kind" .= ("ConfigMap" :: Text)
          , "metadata"
              .= object
                [ "name" .= ("native-sibling" :: Text)
                , "namespace" .= ("personal" :: Text)
                ]
          ]
      siblingBytes = ok (canonicalValue siblingValue)
      sibling =
        ok
          ( bindKubernetesObject
              ( input
                  { resourceId = siblingId
                  , inputObject = siblingValue
                  , objectDigest = contentDigest siblingBytes
                  }
              )
          )
      initialNative = Map.insert siblingId sibling specs
      initialScope =
        ok
          ( mkScopeDeclaration
              scope
              [ResourceBundle [Managed declaration, Managed (fst sibling)] [] [] [] [] []]
          )
      initial =
        ok
          ( composeInventory
              (ok (mkScopeSnapshot binding Map.empty Map.empty))
              (ReplaceScope initialScope :| [])
          )
      physicalFor rid = ok (mkPhysicalIdentity (if rid == resource then "uid-service" else "uid-sibling"))
      absentFor rid = contentDigest (TE.encodeUtf8 ("absent:" <> resourceIdText rid))
  states <- newIORef Map.empty
  let registryFor native =
        ok
          ( mkAdapterRegistry
              [ mkKubernetesAdapter
                  native
                  KubernetesAdapterOps
                    { kubernetesContext = ok (mkContextId "native-carry-forward")
                    , kubernetesObserve = \rid -> do
                        present <- readIORef states
                        pure (Map.findWithDefault (KubernetesAbsent (absentFor rid)) rid present)
                    , kubernetesMutateConditional = \mutation -> do
                        present <- readIORef states
                        let rid = mutationResource mutation
                            before = Map.findWithDefault (KubernetesAbsent (absentFor rid)) rid present
                        if before /= mutationBefore mutation
                          then pure (AdapterEffectFailed (KnownNoEffect "stale native observation"))
                          else do
                            modifyIORef'
                              states
                              ( Map.insert
                                  rid
                                  ( KubernetesPresent
                                      (physicalFor rid)
                                      "7"
                                      (Just rid)
                                      (mutationNativeDigest mutation)
                                  )
                              )
                            pure AdapterEffectCompleted
                    }
              ]
          )
      converge store candidate native = do
        history <- loadInventoryHistory store >>= expectRight
        let registry = registryFor native
        observed <-
          observeWithRegistry
            registry
            (requirementsByExecutor (observationRequirements candidate history))
            >>= expectRight
        proposal <- expectRight (planChanges candidate noLifecycleDecisions history observed)
        before <- readStoreSnapshot store >>= expectRight
        reviewBundle <- prepareReview registry before proposal >>= expectRight
        _ <- publishReview store reviewBundle >>= expectRight
        published <- readStoreSnapshot store >>= expectRight
        reviewed <- expectRight (verifyReview published reviewBundle)
        result <- applyReviewed store registry reviewed >>= expectRight
        case result of
          Converged _ -> pure reviewBundle
          other -> assertFailure ("native carry-forward did not converge: " <> show other)
  store <- newMemoryStore
  _ <- initializeStore store binding "native-carry-forward" >>= expectRight
  _ <- converge store initial initialNative
  firstHistory <- loadInventoryHistory store >>= expectRight
  let changedValue = case nativeObject of
        Object root ->
          Object
            ( KM.insert
                "metadata"
                ( object
                    [ "name" .= ("cache" :: Text)
                    , "namespace" .= ("personal" :: Text)
                    , "labels" .= object ["revision" .= ("two" :: Text)]
                    ]
                )
                root
            )
        _ -> error "native fixture is not an object"
      changedBytes = ok (canonicalValue changedValue)
      changedMember =
        ok
          ( bindKubernetesObject
              ( input
                  { inputObject = changedValue
                  , objectDigest = contentDigest changedBytes
                  }
              )
          )
      changedNative = Map.insert resource changedMember initialNative
      changedScope =
        ok
          ( mkScopeDeclaration
              scope
              [ResourceBundle [Managed (fst changedMember), Managed (fst sibling)] [] [] [] [] []]
          )
      accepted =
        Map.map
          ( \(revision, declared) ->
              (revisionGeneration revision, declared)
          )
          (historyAccepted firstHistory)
      updated =
        ok
          ( composeInventory
              (ok (mkScopeSnapshot binding accepted Map.empty))
              (ReplaceScope changedScope :| [])
          )
  _ <- converge store updated changedNative
  finalHistory <- loadInventoryHistory store >>= expectRight
  (reloaded, _) <-
    loadAcceptedNative store finalHistory (candidateInventory updated)
      >>= expectRight
  Map.lookup siblingId reloaded @?= Just sibling
  Map.lookup resource reloaded @?= Just changedMember
  let sourcedMember = fst changedMember & #source .~ SourceLocation "moved/Config.hs" "document[1]"
      sourcedNative = Map.insert resource (sourcedMember, snd changedMember) changedNative
      sourcedScope =
        ok
          ( mkScopeDeclaration
              scope
              [ResourceBundle [Managed sourcedMember, Managed (fst sibling)] [] [] [] [] []]
          )
      nextAccepted =
        Map.map
          ( \(revision, declared) ->
              (revisionGeneration revision, declared)
          )
          (historyAccepted finalHistory)
      sourceOnly =
        ok
          ( composeInventory
              (ok (mkScopeSnapshot binding nextAccepted Map.empty))
              (ReplaceScope sourcedScope :| [])
          )
  _ <- converge store sourceOnly sourcedNative
  sourcedHistory <- loadInventoryHistory store >>= expectRight
  (sourcedReload, _) <-
    loadAcceptedNative store sourcedHistory (candidateInventory sourceOnly)
      >>= expectRight
  Map.lookup resource sourcedReload @?= Just (sourcedMember, snd changedMember)
  Map.lookup siblingId sourcedReload @?= Just sibling

liveTaskDeletionProof :: IO ()
liveTaskDeletionProof =
  lookupEnv "NAGARE_EP148_TEST_CONTEXT" >>= \case
    Nothing -> pure ()
    Just selectedContext -> do
      assertBool
        "refusing a non-disposable Kubernetes context"
        ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
      let binding =
            ContextBinding
              (ok (mkContextId "ep148-task-delete"))
              (ok (mkName "project"))
          owner = ok (mkScopeId Application "ep148-task-delete")
          foundation = ok (mkScopeId Platform "ep148-task-delete-foundation")
          clusterId = mintResourceId foundation (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
          taskId = mintResourceId owner (ok (mkLogicalKey "ep148-delete")) (ok (mkName "cronjob"))
          siblingId = mintResourceId owner (ok (mkLogicalKey "sibling")) (ok (mkName "configmap"))
          source = SourceLocation "fixture" "task-delete"
          task =
            ok (scheduledTask "ep148-delete" "0 2 * * *" "busybox" "true")
              & #namespace
              .~ ok (Dsl.mkNamespace "default")
              & #app
              .~ Just (ok (Dsl.mkServiceName "ep148-delete"))
          cronValue = ok (Yaml.decodeEither' (renderTask task))
          siblingValue =
            object
              [ "apiVersion" .= ("v1" :: Text)
              , "kind" .= ("ConfigMap" :: Text)
              , "metadata"
                  .= object
                    [ "name" .= ("ep148-delete-sibling" :: Text)
                    , "namespace" .= ("default" :: Text)
                    ]
              , "data" .= object ["value" .= ("keep" :: Text)]
              ]
          bind rid value =
            ok
              ( bindKubernetesObject
                  ( KubernetesInput
                      rid
                      owner
                      clusterId
                      value
                      (contentDigest (ok (canonicalValue value)))
                      DeleteWhenUnreferenced
                      Stateless
                      Private
                      source
                  )
              )
          cron@(cronMember, _) = bind taskId cronValue
          sibling@(siblingMember, _) = bind siblingId siblingValue
          initialNative = Map.fromList [(taskId, cron), (siblingId, sibling)]
          initialScope =
            ok
              ( mkScopeDeclaration
                  owner
                  [ResourceBundle [Managed cronMember, Managed siblingMember] [] [] [] [] []]
              )
          config =
            KubernetesRuntimeConfig
              (ok (mkContextId "ep148-task-delete"))
              (T.pack selectedContext)
              (pure (Right ()))
          makeRegistry members =
            ok
              ( mkAdapterRegistry
                  [mkKubernetesAdapter members (mkKubernetesRuntimeOps config members)]
              )
          acceptedSnapshot history =
            ok
              ( mkScopeSnapshot
                  binding
                  ( Map.map
                      (\(revision, declared) -> (revisionGeneration revision, declared))
                      (historyAccepted history)
                  )
                  (historyReservations history)
              )
          cleanup =
            mapM_
              ( \(kind, name) -> do
                  _ <-
                    readProcessWithExitCode
                      "kubectl"
                      [ "--context"
                      , selectedContext
                      , "-n"
                      , "default"
                      , "delete"
                      , kind
                      , name
                      , "--ignore-not-found"
                      , "--wait=false"
                      ]
                      ""
                  pure ()
              )
              [ ("cronjob", "nagare-task-ep148-delete")
              , ("configmap", "ep148-delete-sibling")
              ]
          checkLive kind name = do
            (status, _, _) <-
              readProcessWithExitCode
                "kubectl"
                ["--context", selectedContext, "-n", "default", "get", kind, name]
                ""
            pure (status == ExitSuccess)
          siblingUid = do
            (status, uid, errors) <-
              readProcessWithExitCode
                "kubectl"
                [ "--context"
                , selectedContext
                , "-n"
                , "default"
                , "get"
                , "configmap"
                , "ep148-delete-sibling"
                , "-o"
                , "jsonpath={.metadata.uid}"
                ]
                ""
            status @?= ExitSuccess
            assertBool ("sibling UID is empty: " <> errors) (not (null uid))
            pure uid
      cleanup
      ( do
          store <- newMemoryStore
          _ <- initializeStore store binding "ep148-task-delete" >>= expectRight
          let reviewAndApply stage candidate members decide = do
                history <- loadInventoryHistory store >>= expectRight
                let registry = makeRegistry members
                observed <-
                  observeWithRegistry
                    registry
                    (requirementsByExecutor (observationRequirements candidate history))
                    >>= expectRight
                decisions <- expectRight (decide candidate history observed)
                proposal <- case planChanges candidate decisions history observed of
                  Left failure ->
                    assertFailure (stage <> ": " <> show failure <> "; facts: " <> show observed)
                      >> fail "task deletion planning failed"
                  Right value -> pure value
                before <- readStoreSnapshot store >>= expectRight
                review <- prepareReview registry before proposal >>= expectRight
                _ <- publishReview store review >>= expectRight
                published <- readStoreSnapshot store >>= expectRight
                reviewed <- expectRight (verifyReview published review)
                result <- applyReviewed store registry reviewed >>= expectRight
                case result of
                  Converged _ -> pure ()
                  other -> assertFailure ("task deletion review did not converge: " <> show other)
              noDecision _ _ _ = Right noLifecycleDecisions
          let initial =
                ok
                  ( composeInventory
                      (ok (mkScopeSnapshot binding Map.empty Map.empty))
                      (ReplaceScope initialScope :| [])
                  )
          reviewAndApply "initial" initial initialNative noDecision
          originalSiblingUid <- siblingUid
          initialHistory <- loadInventoryHistory store >>= expectRight
          (acceptedNative, _) <-
            loadAcceptedNative store initialHistory (candidateInventory initial)
              >>= expectRight
          (suspendedScope, suspendedNative) <-
            expectRight
              (compileTaskSuspensionScope (Just "ep148-delete") cronMember initialScope acceptedNative)
          let suspension =
                ok
                  ( composeInventory
                      (acceptedSnapshot initialHistory)
                      (ReplaceScope suspendedScope :| [])
                  )
          reviewAndApply "suspend" suspension suspendedNative noDecision
          (code, liveSuspended, _) <-
            readProcessWithExitCode
              "kubectl"
              [ "--context"
              , selectedContext
              , "-n"
              , "default"
              , "get"
              , "cronjob"
              , "nagare-task-ep148-delete"
              , "-o"
              , "jsonpath={.spec.suspend}"
              ]
              ""
          code @?= ExitSuccess
          liveSuspended @?= "true"
          suspendedHistory <- loadInventoryHistory store >>= expectRight
          (reloadedNative, _) <-
            loadAcceptedNative store suspendedHistory (candidateInventory suspension)
              >>= expectRight
          (acceptedCron, acceptedBytes) <-
            maybe
              (assertFailure "suspended CronJob was not saved" >> fail "missing CronJob")
              pure
              (Map.lookup taskId reloadedNative)
          taskSuspended (Just "ep148-delete") acceptedCron acceptedBytes @?= Right True
          retiredScope <-
            expectRight
              (retireSuspendedTaskScope (Just "ep148-delete") acceptedCron suspendedScope reloadedNative)
          let retirement =
                ok
                  ( composeInventory
                      (acceptedSnapshot suspendedHistory)
                      (ReplaceScope retiredScope :| [])
                  )
              decideMemberRetirement candidate history observations = do
                fact <-
                  maybe
                    (Left (PlanError "task-observation" "CronJob observation is missing" [taskId] :| []))
                    Right
                    (Map.lookup taskId (observationMap observations))
                validateLifecycleDecisions
                  candidate
                  history
                  observations
                  [ LifecycleProposal
                      taskId
                      ApproveRetirement
                      (lifecycleObservationDigest binding taskId fact)
                  ]
          reviewAndApply "retain" retirement reloadedNative decideMemberRetirement
          afterRetention <- loadInventoryHistory store >>= expectRight
          assertBool "CronJob was not retained" (Map.member taskId (historyRetained afterRetention))
          assertBool "retention deleted the live CronJob"
            =<< checkLive "cronjob" "nagare-task-ep148-delete"
          let collection =
                ok
                  ( composeInventory
                      (acceptedSnapshot afterRetention)
                      (CollectRetained taskId :| [])
                  )
          reviewAndApply "collect" collection (Map.singleton taskId (acceptedCron, acceptedBytes)) decideCollection
          afterCollection <- loadInventoryHistory store >>= expectRight
          assertBool "CronJob is still retained" (Map.notMember taskId (historyRetained afterCollection))
          assertBool "collection left the live CronJob"
            . not
            =<< checkLive "cronjob" "nagare-task-ep148-delete"
          assertBool "task deletion changed its sibling ConfigMap"
            =<< checkLive "configmap" "ep148-delete-sibling"
          siblingUid >>= (@?= originalSiblingUid)
        )
        `finally` cleanup

liveTaskDeletionCommandProof :: IO ()
liveTaskDeletionCommandProof =
  lookupEnv "NAGARE_EP148_TEST_CONTEXT" >>= \case
    Nothing -> pure ()
    Just selectedContext -> do
      assertBool
        "refusing a non-disposable Kubernetes context"
        ("k3d-nagare-inventory-" `T.isPrefixOf` T.pack selectedContext)
      cli <-
        lookupEnv "NAGARE_EP148_TEST_CLI"
          >>= maybe
            (assertFailure "set NAGARE_EP148_TEST_CLI to the built nagarectl executable" >> fail "missing CLI")
            pure
      withSystemTempDirectory "ep148-task-cli" $ \root -> do
        let namespace = "ep148-task-cli" :: String
            taskName = "ep148-delete-cli"
            cronName = "nagare-task-" <> taskName
            siblingName = "ep148-delete-cli-sibling"
            binding = ContextBinding (ok (mkContextId (T.pack selectedContext))) (ok (mkName "project"))
            foundation = ok (mkScopeId Platform "foundation")
            owner = ok (mkScopeId Application (T.pack taskName))
            clusterId = mintResourceId foundation (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            namespaceId =
              mintResourceId
                foundation
                (ok (mkLogicalKey "foundation"))
                (ok (mkName (T.pack ("namespace-" <> namespace))))
            taskId = mintResourceId owner (ok (mkLogicalKey "task")) (ok (mkName "cronjob"))
            siblingId = mintResourceId owner (ok (mkLogicalKey "sibling")) (ok (mkName "configmap"))
            source = SourceLocation "fixture" "task-delete-cli"
            namespaceValue =
              object
                [ "apiVersion" .= ("v1" :: Text)
                , "kind" .= ("Namespace" :: Text)
                , "metadata" .= object ["name" .= namespace]
                ]
            task =
              ok (scheduledTask (T.pack taskName) "0 2 * * *" "busybox" "true")
                & #namespace
                .~ ok (Dsl.mkNamespace (T.pack namespace))
                & #app
                .~ Just (ok (Dsl.mkServiceName (T.pack taskName)))
            cronValue = ok (Yaml.decodeEither' (renderTask task))
            siblingValue =
              object
                [ "apiVersion" .= ("v1" :: Text)
                , "kind" .= ("ConfigMap" :: Text)
                , "metadata" .= object ["name" .= siblingName, "namespace" .= namespace]
                , "data" .= object ["value" .= ("keep" :: Text)]
                ]
            bind rid ownerScope lifecycle value =
              ok
                ( bindKubernetesObject
                    ( KubernetesInput
                        rid
                        ownerScope
                        clusterId
                        value
                        (contentDigest (ok (canonicalValue value)))
                        lifecycle
                        Stateless
                        Private
                        source
                    )
                )
            namespaceMember = bind namespaceId foundation Retain namespaceValue
            cronMember = bind taskId owner DeleteWhenUnreferenced cronValue
            siblingMember = bind siblingId owner DeleteWhenUnreferenced siblingValue
            foundationScope =
              ok
                ( mkScopeDeclaration
                    foundation
                    [ResourceBundle [Managed (fst namespaceMember)] [] [] [] [] []]
                )
            taskScope =
              ok
                ( mkScopeDeclaration
                    owner
                    [ResourceBundle [Managed (fst cronMember), Managed (fst siblingMember)] [] [] [] [] []]
                )
            config =
              KubernetesRuntimeConfig
                (ok (mkContextId (T.pack selectedContext)))
                (T.pack selectedContext)
                (pure (Right ()))
            makeRegistry members =
              ok
                ( mkAdapterRegistry
                    [mkKubernetesAdapter members (mkKubernetesRuntimeOps config members)]
                )
            configRoot = root </> "config"
            stateRoot = root </> "state"
            storePath = stateRoot </> "nagare" </> selectedContext </> "inventory"
            contextFile = configRoot </> "nagare" </> "contexts" </> selectedContext <> ".env"
            cleanup = do
              _ <-
                readProcessWithExitCode
                  "kubectl"
                  [ "--context"
                  , selectedContext
                  , "delete"
                  , "namespace"
                  , namespace
                  , "--ignore-not-found"
                  , "--wait=false"
                  ]
                  ""
              pure ()
            checkLive kind name = do
              (status, _, _) <-
                readProcessWithExitCode
                  "kubectl"
                  ["--context", selectedContext, "-n", namespace, "get", kind, name]
                  ""
              pure (status == ExitSuccess)
            siblingUid = do
              (status, uid, errors) <-
                readProcessWithExitCode
                  "kubectl"
                  [ "--context"
                  , selectedContext
                  , "-n"
                  , namespace
                  , "get"
                  , "configmap"
                  , siblingName
                  , "-o"
                  , "jsonpath={.metadata.uid}"
                  ]
                  ""
              status @?= ExitSuccess
              assertBool ("sibling UID is empty: " <> errors) (not (null uid))
              pure uid
        createDirectoryIfMissing True (configRoot </> "nagare" </> "contexts")
        writeFile contextFile "CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=local\n"
        inherited <- getEnvironment
        let cliEnv =
              Just
                ( ("XDG_CONFIG_HOME", configRoot)
                    : ("XDG_STATE_HOME", stateRoot)
                    : ("CLOUDSDK_CORE_PROJECT", "project")
                    : ("NAGARE_MODE", "local")
                    : filter
                      ( \(key, _) ->
                          key
                            `notElem` ["XDG_CONFIG_HOME", "XDG_STATE_HOME", "CLOUDSDK_CORE_PROJECT", "NAGARE_MODE"]
                      )
                      inherited
                )
            runCli args = do
              (status, output, errors) <-
                readCreateProcessWithExitCode
                  ((proc cli (["--context", selectedContext] <> args)) {env = cliEnv})
                  ""
              assertBool
                ("nagarectl " <> unwords args <> " failed: " <> output <> errors)
                (status == ExitSuccess)
            readHistory store = loadInventoryHistory store >>= expectRight
            acceptedSnapshot history =
              ok
                ( mkScopeSnapshot
                    binding
                    ( Map.map
                        (\(revision, declared) -> (revisionGeneration revision, declared))
                        (historyAccepted history)
                    )
                    (historyReservations history)
                )
            reviewAndApply store stage candidate members = do
              history <- readHistory store
              let registry = makeRegistry members
              observed <-
                observeWithRegistry
                  registry
                  (requirementsByExecutor (observationRequirements candidate history))
                  >>= expectRight
              proposal <- case planChanges candidate noLifecycleDecisions history observed of
                Left failure ->
                  assertFailure (stage <> ": " <> show failure)
                    >> fail "initial task CLI planning failed"
                Right value -> pure value
              before <- readStoreSnapshot store >>= expectRight
              savedReview <- prepareReview registry before proposal >>= expectRight
              _ <- publishReview store savedReview >>= expectRight
              published <- readStoreSnapshot store >>= expectRight
              reviewed <- expectRight (verifyReview published savedReview)
              result <- applyReviewed store registry reviewed >>= expectRight
              case result of
                Converged _ -> pure ()
                other -> assertFailure (stage <> " did not converge: " <> show other)
            nextStage stage = do
              let reviewPath = root </> stage
              runCli
                [ "task"
                , "delete"
                , taskName
                , taskName
                , "--namespace"
                , namespace
                , "--save-plan"
                , reviewPath
                ]
              runCli ["inventory", "apply", reviewPath, "--yes"]
        cleanup
        ( do
            store <- openFilesystemStore storePath >>= expectRight
            _ <- initializeStore store binding "ep148-task-cli" >>= expectRight
            let foundationCandidate =
                  ok
                    ( composeInventory
                        (ok (mkScopeSnapshot binding Map.empty Map.empty))
                        (ReplaceScope foundationScope :| [])
                    )
            reviewAndApply
              store
              "foundation"
              foundationCandidate
              (Map.singleton namespaceId namespaceMember)
            foundationHistory <- readHistory store
            let taskCandidate =
                  ok
                    ( composeInventory
                        (acceptedSnapshot foundationHistory)
                        (ReplaceScope taskScope :| [])
                    )
            reviewAndApply
              store
              "task"
              taskCandidate
              (Map.fromList [(taskId, cronMember), (siblingId, siblingMember)])
            originalSiblingUid <- siblingUid
            nextStage "suspend"
            (status, suspended, errors) <-
              readProcessWithExitCode
                "kubectl"
                [ "--context"
                , selectedContext
                , "-n"
                , namespace
                , "get"
                , "cronjob"
                , cronName
                , "-o"
                , "jsonpath={.spec.suspend}"
                ]
                ""
            status @?= ExitSuccess
            assertBool errors (suspended == "true")
            nextStage "retain"
            retained <- readHistory store
            assertBool
              "CLI retention did not retain the CronJob"
              (Map.member taskId (historyRetained retained))
            assertBool "CLI retention deleted the CronJob" =<< checkLive "cronjob" cronName
            nextStage "collect"
            collected <- readHistory store
            assertBool
              "CLI collection left the CronJob retained"
              (Map.notMember taskId (historyRetained collected))
            assertBool "CLI collection left the CronJob live"
              . not
              =<< checkLive "cronjob" cronName
            assertBool "CLI deletion removed the sibling"
              =<< checkLive "configmap" siblingName
            siblingUid >>= (@?= originalSiblingUid)
          )
          `finally` cleanup

reviewedReleaseCleanup :: IO ()
reviewedReleaseCleanup = do
  let owner = ok (mkScopeId Application "release-cleanup")
      dataOwner = ok (mkScopeId Standalone "release-cleanup-database")
      key = ok (mkLogicalKey "web")
      dataKey = ok (mkLogicalKey "database")
      serviceId = mintResourceId owner key (ok (mkName "service"))
      releaseId = mintResourceId owner key (ok (mkName "release-history"))
      routeId = mintResourceId owner key (ok (mkName "domain-mapping"))
      databaseId = mintResourceId dataOwner dataKey (ok (mkName "statefulset"))
      pvcId = mintResourceId dataOwner dataKey (ok (mkName "pvc"))
      backupId = mintResourceId dataOwner dataKey (ok (mkName "backup-job"))
      serviceValue =
        object
          [ "apiVersion" .= ("v1" :: Text)
          , "kind" .= ("Service" :: Text)
          , "metadata" .= object ["name" .= ("web" :: Text), "namespace" .= ("personal" :: Text)]
          ]
      releaseValue =
        object
          [ "apiVersion" .= ("v1" :: Text)
          , "kind" .= ("ConfigMap" :: Text)
          , "metadata" .= object ["name" .= ("web-history" :: Text), "namespace" .= ("personal" :: Text)]
          , "data" .= object ["current" .= ("v1" :: Text)]
          ]
      routeValue =
        object
          [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
          , "kind" .= ("DomainMapping" :: Text)
          , "metadata"
              .= object
                [ "name" .= ("web.example.test" :: Text)
                , "namespace" .= ("personal" :: Text)
                ]
          , "spec"
              .= object
                [ "ref"
                    .= object
                      [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
                      , "kind" .= ("Service" :: Text)
                      , "name" .= ("web" :: Text)
                      , "namespace" .= ("personal" :: Text)
                      ]
                ]
          ]
      databaseValue =
        object
          [ "apiVersion" .= ("apps/v1" :: Text)
          , "kind" .= ("StatefulSet" :: Text)
          , "metadata" .= object ["name" .= ("pg-main" :: Text), "namespace" .= ("personal" :: Text)]
          , "spec" .= object ["replicas" .= (1 :: Int)]
          ]
      pvcValue =
        object
          [ "apiVersion" .= ("v1" :: Text)
          , "kind" .= ("PersistentVolumeClaim" :: Text)
          , "metadata" .= object ["name" .= ("pg-main-data" :: Text), "namespace" .= ("personal" :: Text)]
          , "spec" .= object ["accessModes" .= ["ReadWriteOnce" :: Text]]
          ]
      backupValue =
        object
          [ "apiVersion" .= ("batch/v1" :: Text)
          , "kind" .= ("Job" :: Text)
          , "metadata" .= object ["name" .= ("pg-main-backup" :: Text), "namespace" .= ("personal" :: Text)]
          , "spec"
              .= object
                [ "template"
                    .= object
                      [ "spec"
                          .= object
                            [ "restartPolicy" .= ("Never" :: Text)
                            , "containers"
                                .= [object ["name" .= ("backup" :: Text), "image" .= ("busybox:1.36" :: Text)]]
                            ]
                      ]
                ]
          ]
      bind selectedId value policy =
        let bytes = ok (canonicalValue value)
         in ok
              ( bindKubernetesObject
                  ( input
                      { resourceId = selectedId
                      , ownerScope = owner
                      , inputObject = value
                      , objectDigest = contentDigest bytes
                      , lifecyclePolicy = policy
                      }
                  )
              )
      (service, serviceBytes) = bind serviceId serviceValue DeleteWhenUnreferenced
      (oldRelease, releaseBytes) = bind releaseId releaseValue Retain
      (unboundRoute, routeBytes) = bind routeId routeValue DeleteWhenUnreferenced
      bindData selectedId value policy dataPolicy =
        let bytes = ok (canonicalValue value)
         in ok
              ( bindKubernetesObject
                  ( input
                      { resourceId = selectedId
                      , ownerScope = dataOwner
                      , inputObject = value
                      , objectDigest = contentDigest bytes
                      , lifecyclePolicy = policy
                      , inputDataPolicy = dataPolicy
                      }
                  )
              )
      durable =
        Durable
          ( RecoveryIntent
              (ok (mkName "archive"))
              (mkSecretRef (ok (mkName "restore-key")) (ok (mkName "v1")) :| [])
          )
      (database, databaseBytes) = bindData databaseId databaseValue Retain Stateless
      (pvc, pvcBytes) = bindData pvcId pvcValue Retain durable
      (backup, backupBytes) = bindData backupId backupValue Retain Stateless
      route = unboundRoute {dependencies = [OrderedAfter serviceId]}
      release =
        oldRelease
          { lifecycle = DeleteWhenUnreferenced
          , dependencies = [OrderedAfter serviceId]
          }
      legacyRelease = oldRelease {dependencies = [OrderedAfter serviceId]}
      oldSpecs =
        Map.fromList
          [ (serviceId, (service, serviceBytes))
          , (releaseId, (legacyRelease, releaseBytes))
          , (routeId, (route, routeBytes))
          ]
      currentSpecs =
        Map.fromList
          [ (serviceId, (service, serviceBytes))
          , (releaseId, (release, releaseBytes))
          , (routeId, (route, routeBytes))
          ]
      dataSpecs =
        Map.fromList
          [ (databaseId, (database, databaseBytes))
          , (pvcId, (pvc, pvcBytes))
          , (backupId, (backup, backupBytes))
          ]
      dataScope =
        ok
          ( mkScopeDeclaration
              dataOwner
              [ResourceBundle [Managed database, Managed pvc, Managed backup] [] [] [] [] []]
          )
      scopeFor historyMember =
        ok
          ( mkScopeDeclaration
              owner
              [ResourceBundle [Managed service, Managed historyMember, Managed route] [] [] [] [] []]
          )
      oldScope = scopeFor legacyRelease
      newScope = scopeFor release
      binding = ContextBinding (ok (mkContextId "release-cleanup")) (ok (mkName "project"))
      physicalFor selectedId
        | selectedId == serviceId = ok (mkPhysicalIdentity "web-uid")
        | selectedId == releaseId = ok (mkPhysicalIdentity "history-uid")
        | selectedId == databaseId = ok (mkPhysicalIdentity "database-uid")
        | selectedId == pvcId = ok (mkPhysicalIdentity "pvc-uid")
        | selectedId == backupId = ok (mkPhysicalIdentity "backup-uid")
        | otherwise = ok (mkPhysicalIdentity "route-uid")
      dataIds = [databaseId, pvcId, backupId]
  states <-
    newIORef
      ( Map.fromList
          [ (serviceId, KubernetesAbsent absence)
          , (releaseId, KubernetesAbsent absence)
          , (routeId, KubernetesAbsent absence)
          , (databaseId, KubernetesAbsent absence)
          , (pvcId, KubernetesAbsent absence)
          , (backupId, KubernetesAbsent absence)
          ]
      )
  store <- newMemoryStore
  let runtime =
        KubernetesAdapterOps
          { kubernetesContext = ok (mkContextId "release-cleanup")
          , kubernetesObserve = \selectedId -> Map.findWithDefault (KubernetesUnknown "missing") selectedId <$> readIORef states
          , kubernetesMutateConditional = \mutation -> do
              let selectedId = mutationResource mutation
              current <- Map.findWithDefault (KubernetesUnknown "missing") selectedId <$> readIORef states
              if current /= mutationBefore mutation
                then pure (AdapterEffectFailed (KnownNoEffect "changed before conditional write"))
                else do
                  let next =
                        if mutationAction mutation == RetireResource
                          then KubernetesAbsent absence
                          else KubernetesPresent (physicalFor selectedId) "5" (Just selectedId) (mutationNativeDigest mutation)
                  modifyIORef' states (Map.insert selectedId next)
                  pure AdapterEffectCompleted
          }
      registry members = ok (mkAdapterRegistry [mkKubernetesAdapter members runtime])
      snapshot history =
        ok
          ( mkScopeSnapshot
              binding
              ( Map.map
                  (\(revision, value) -> (revisionGeneration revision, value))
                  (historyAccepted history)
              )
              (historyReservations history)
          )
      observations selected candidate history =
        observeWithRegistry
          selected
          (requirementsByExecutor (observationRequirements candidate history))
          >>= expectRight
      reviewAndApply selected candidate history decisions facts = do
        let proposal = ok (planChanges candidate decisions history facts)
        before <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReview selected before proposal >>= expectRight
        _ <- publishReview store bundle >>= expectRight
        published <- readStoreSnapshot store >>= expectRight
        reviewed <- expectRight (verifyReview published bundle)
        result <- applyReviewed store selected reviewed >>= expectRight
        case result of Converged _ -> pure (); other -> assertFailure (show other)
        pure proposal
  _ <- initializeStore store binding "release-cleanup" >>= expectRight
  emptyHistory <- loadInventoryHistory store >>= expectRight
  let initial =
        ok
          ( composeInventory
              (snapshot emptyHistory)
              (ReplaceScope oldScope :| [ReplaceScope dataScope])
          )
      oldRegistry = registry (Map.union oldSpecs dataSpecs)
  initialFacts <- observations oldRegistry initial emptyHistory
  _ <- reviewAndApply oldRegistry initial emptyHistory noLifecycleDecisions initialFacts
  accepted <- loadInventoryHistory store >>= expectRight
  let acceptedData = Map.lookup dataOwner (historyAccepted accepted)
      stableData = do
        history <- loadInventoryHistory store >>= expectRight
        Map.lookup dataOwner (historyAccepted history) @?= acceptedData
        current <- readIORef states
        forM_ dataIds $ \selectedId ->
          Map.lookup selectedId current
            @?= Just
              ( KubernetesPresent
                  (physicalFor selectedId)
                  "5"
                  (Just selectedId)
                  (contentDigest (snd (dataSpecs Map.! selectedId)))
              )
  assertBool
    "database scope was not accepted"
    (Map.member dataOwner (historyAccepted accepted))
  stableData
  let update =
        ok
          ( composeInventory
              (snapshot accepted)
              (ReplaceScope newScope :| [])
          )
      newRegistry = registry (Map.union currentSpecs dataSpecs)
  updateFacts <- observations newRegistry update accepted
  updated <- reviewAndApply newRegistry update accepted noLifecycleDecisions updateFacts
  map plannedAction (proposalOperations updated) @?= [UpdateResource]
  map (NE.toList . plannedResources) (proposalOperations updated) @?= [[releaseId]]
  updatedHistory <- loadInventoryHistory store >>= expectRight
  stableData
  let retirement =
        ok
          ( composeInventory
              (snapshot updatedHistory)
              (RetireScope owner RetainResources :| [])
          )
  retirementFacts <- observations newRegistry retirement updatedHistory
  retirementDecisions <- expectRight (decideRetirement retirement updatedHistory retirementFacts)
  retired <- reviewAndApply newRegistry retirement updatedHistory retirementDecisions retirementFacts
  proposalOperations retired @?= []
  retained <- loadInventoryHistory store >>= expectRight
  stableData
  let collection selectedId history =
        ok
          ( composeInventory
              (snapshot history)
              (CollectRetained selectedId :| [])
          )
      attempt selectedId history = do
        let candidate = collection selectedId history
        facts <- observations newRegistry candidate history
        pure (candidate, facts, decideCollection candidate history facts)
  (_, _, premature) <- attempt serviceId retained
  assertBool "release-history dependency allowed premature Service collection" (isLeft premature)
  (historyCollection, historyFacts, historyDecision) <- attempt releaseId retained
  _ <-
    reviewAndApply
      newRegistry
      historyCollection
      retained
      (ok historyDecision)
      historyFacts
  afterHistory <- loadInventoryHistory store >>= expectRight
  stableData
  (_, _, stillBlocked) <- attempt serviceId afterHistory
  assertBool "route dependency allowed premature Service collection" (isLeft stillBlocked)
  (routeCollection, routeFacts, routeDecision) <- attempt routeId afterHistory
  _ <-
    reviewAndApply
      newRegistry
      routeCollection
      afterHistory
      (ok routeDecision)
      routeFacts
  afterRoute <- loadInventoryHistory store >>= expectRight
  stableData
  (serviceCollection, serviceFacts, serviceDecision) <- attempt serviceId afterRoute
  _ <-
    reviewAndApply
      newRegistry
      serviceCollection
      afterRoute
      (ok serviceDecision)
      serviceFacts
  final <- loadInventoryHistory store >>= expectRight
  stableData
  Map.null (historyRetained final) @?= True
  Map.keys (headCollected (historyHead final)) @?= sort [serviceId, releaseId, routeId]

reviewedManualReceiptCleanup ::
  ScopeDeclaration ->
  Map.Map ResourceId (ManagedResource, ByteString) ->
  ScopeDeclaration ->
  Map.Map ResourceId (ManagedResource, ByteString) ->
  ScopeDeclaration ->
  PhysicalIdentity ->
  IO ()
reviewedManualReceiptCleanup
  databaseScope
  databaseNative
  backupScope
  backupNative
  receiptRecord
  backupUid = do
    let binding =
          ContextBinding
            (ok (mkContextId "manual-receipt-cleanup"))
            (ok (mkName "project"))
        backupOwner = scopeId backupScope
        jobId = case Map.keys backupNative of
          [single] -> single
          _ -> error "manual receipt lifecycle fixture needs one backup Job"
        members = Map.union backupNative databaseNative
        assigned = Map.fromList (zip (Map.keys members) [1 :: Int ..])
        physicalFor selectedId
          | selectedId == jobId = backupUid
          | otherwise =
              ok
                ( mkPhysicalIdentity
                    ("neighbor-uid-" <> T.pack (show (assigned Map.! selectedId)))
                )
        present selectedId bytes =
          KubernetesPresent
            (physicalFor selectedId)
            "1"
            (Just selectedId)
            (contentDigest bytes)
        sourceScopes =
          Map.fromList
            [ (scopeId databaseScope, (ok (mkScopeGeneration 3), databaseScope))
            , (backupOwner, (ok (mkScopeGeneration 1), backupScope))
            ]
        initialSnapshot = ok (mkScopeSnapshot binding sourceScopes Map.empty)
        dummy =
          ok
            ( mkScopeDeclaration
                (ok (mkScopeId Standalone "receipt-seed"))
                [ResourceBundle [] [] [] [] [] []]
            )
    states <-
      newIORef
        ( Map.mapWithKey
            (\selectedId (_, bytes) -> present selectedId bytes)
            members
        )
    mutations <- newIORef (0 :: Int)
    store <- newMemoryStore
    let runtime =
          KubernetesAdapterOps
            { kubernetesContext = ok (mkContextId "manual-receipt-cleanup")
            , kubernetesObserve = \selectedId ->
                Map.findWithDefault
                  (KubernetesUnknown "missing")
                  selectedId
                  <$> readIORef states
            , kubernetesMutateConditional = \mutation -> do
                let selectedId = mutationResource mutation
                current <-
                  Map.findWithDefault (KubernetesUnknown "missing") selectedId
                    <$> readIORef states
                if selectedId == jobId
                  && mutationAction mutation == RetireResource
                  && current == mutationBefore mutation
                  then do
                    modifyIORef' mutations (+ 1)
                    modifyIORef' states (Map.insert selectedId (KubernetesAbsent absence))
                    pure AdapterEffectCompleted
                  else
                    pure
                      ( AdapterEffectFailed
                          ( KnownNoEffect
                              "receipt lifecycle fixture refused an unexpected mutation"
                          )
                      )
            }
        registry = ok (mkAdapterRegistry [mkKubernetesAdapter members runtime])
        snapshot history =
          ok
            ( mkScopeSnapshot
                binding
                ( Map.map
                    (\(revision, selected) -> (revisionGeneration revision, selected))
                    (historyAccepted history)
                )
                (historyReservations history)
            )
        observe candidate history =
          observeWithRegistry
            registry
            (requirementsByExecutor (observationRequirements candidate history))
            >>= expectRight
        reviewAndApply candidate history decisions facts = do
          proposal <- expectRight (planChanges candidate decisions history facts)
          before <- readStoreSnapshot store >>= expectRight
          bundle <- prepareReview registry before proposal >>= expectRight
          _ <- publishReview store bundle >>= expectRight
          published <- readStoreSnapshot store >>= expectRight
          reviewed <- expectRight (verifyReview published bundle)
          result <- applyReviewed store registry reviewed >>= expectRight
          case result of Converged _ -> pure (); other -> assertFailure (show other)
          pure proposal
    _ <- initializeStore store binding "manual-receipt-cleanup" >>= expectRight
    let seed = ok (composeInventory initialSnapshot (ReplaceScope dummy :| []))
    _ <- seedInventoryHistory store seed >>= expectRight
    accepted <- loadInventoryHistory store >>= expectRight
    let databaseRevision = Map.lookup (scopeId databaseScope) (historyAccepted accepted)
        replacement =
          ok
            ( composeInventory
                (snapshot accepted)
                (ReplaceScope receiptRecord :| [])
            )
    replacementFacts <- observe replacement accepted
    jobFact <-
      maybe
        (assertFailure "retired Job was not observed")
        pure
        (Map.lookup jobId (observationMap replacementFacts))
    retirement <-
      expectRight
        ( validateLifecycleDecisions
            replacement
            accepted
            replacementFacts
            [ LifecycleProposal
                jobId
                ApproveRetirement
                (lifecycleObservationDigest binding jobId jobFact)
            ]
        )
    proposal <- reviewAndApply replacement accepted retirement replacementFacts
    proposalOperations proposal @?= []
    readIORef mutations >>= (@?= 0)
    retained <- loadInventoryHistory store >>= expectRight
    assertBool
      "manual receipt record was not accepted"
      (maybe False ((== receiptRecord) . snd) (Map.lookup backupOwner (historyAccepted retained)))
    assertBool
      "backup Job was not retained for separate collection"
      (Map.member jobId (historyRetained retained))
    Map.lookup (scopeId databaseScope) (historyAccepted retained) @?= databaseRevision
    let collection =
          ok
            ( composeInventory
                (snapshot retained)
                (CollectRetained jobId :| [])
            )
    collectionFacts <- observe collection retained
    collectionDecision <- expectRight (decideCollection collection retained collectionFacts)
    _ <- reviewAndApply collection retained collectionDecision collectionFacts
    final <- loadInventoryHistory store >>= expectRight
    Map.lookup (scopeId databaseScope) (historyAccepted final) @?= databaseRevision
    Map.lookup backupOwner (historyAccepted final)
      @?= Map.lookup backupOwner (historyAccepted retained)
    case Map.lookup jobId (headCollected (historyHead final)) of
      Just tombstone -> tombstonePhysical tombstone @?= backupUid
      Nothing -> assertFailure "manual backup Job collection has no tombstone"
    readIORef mutations >>= (@?= 1)
    current <- readIORef states
    forM_ (Map.toList databaseNative) $ \(selectedId, (_, bytes)) ->
      Map.lookup selectedId current @?= Just (present selectedId bytes)
