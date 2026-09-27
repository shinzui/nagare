module DataFenceSpec (dataFenceTests) where

import Data.Aeson (Value (..), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.IORef
import Data.List (elemIndex, find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
  ( AdapterExecution (..), AdapterFence (..)
  , RecoveryDecision (..), mkAdapterRegistry, observationSet, withAdapterFence )
import Nagare.Inventory.DataFence
import Nagare.Inventory.DataFence.MountGuard
import Nagare.Inventory.DataFence.MountGuardRuntime
import Nagare.Inventory.DataFence.StatefulWriter
import Nagare.Inventory.DataFence.VolumeState
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute
  ( AdmissionError (..), TransactionResult (..), admit, applyReviewed, execute, resumeTransaction )
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import InventoryTransactionSpec
  ( fixtureBinding, preparedFixtureWithRegistry, recordingRegistryWith )
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

dataFenceTests :: TestTree
dataFenceTests = testGroup "data fence"
  [ testCase "reservation survives a new process and blocks planning until verified release" $
      withSystemTempDirectory "nagare-data-fence" $ \root -> do
        store <- openFilesystemStore root >>= right
        _ <- initializeStore store binding "operator-a" >>= right
        let scope = known (mkScopeDeclaration fenceOwner [])
            snapshot = known (mkScopeSnapshot binding Map.empty Map.empty)
            candidate = known (composeInventory snapshot (ReplaceScope scope :| []))
            registry = known (mkAdapterRegistry [])
        initialHistory <- loadInventoryHistory store >>= right
        proposal <- right (planChanges candidate noLifecycleDecisions initialHistory
          (known (observationSet [])))
        storeSnapshot <- readStoreSnapshot store >>= right
        review <- prepareReview registry storeSnapshot proposal >>= right
        _ <- publishReview store review >>= right
        issued <- readStoreSnapshot store >>= right
        reviewed <- right (verifyReview issued review)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let controls = fixtureControls released restored (pure (Right physical))
        token <- withProcessLock store (\locked -> acquireDataFence locked controls request)
          >>= right >>= right
        active <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        fmap fencePhase (headDataFence active) @?= Just FenceExcluded
        eitherDecode (encode active) @?= Right active
        reopened <- openFilesystemStore root >>= right
        history <- loadInventoryHistory reopened >>= right
        case planChanges candidate noLifecycleDecisions history (known (observationSet [])) of
          Left failures -> assertBool "active fence must block planning"
            (any ((== "active-data-fence") . planErrorCode) failures)
          Right _ -> assertFailure "active fence admitted a competing review"
        admission <- withProcessLock reopened (\locked ->
          fmap (fmap (const ())) (admit locked registry reviewed))
          >>= right
        case admission of
          Left errors -> assertBool "active fence must block saved review admission"
            (any ((== "active-data-fence") . admissionErrorCode) errors)
          Right _ -> assertFailure "active fence admitted a saved review"
        _ <- withProcessLock reopened (\locked -> beginDataChange locked controls token)
          >>= right >>= right
        _ <- withProcessLock reopened (\locked -> markDataFenceUnresolved locked token)
          >>= right >>= right
        resumed <- withProcessLock reopened (\locked -> resumeDataFence locked "restore-session")
          >>= right >>= right
        _ <- withProcessLock reopened (\locked -> recoverDataFence locked controls resumed)
          >>= right >>= right
        _ <- withProcessLock reopened (\locked -> releaseDataFence locked controls resumed)
          >>= right >>= right
        final <- readHead reopened >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        headDataFence final @?= Nothing
        readIORef restored >>= (@?= 1)
        readIORef released >>= (@?= True)
    , testCase "lost release acknowledgement is observed without replaying writer restoration" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let original = fixtureControls released restored (pure (Right physical))
            uncertain = original {restoreFenceWriters = \_ -> do
              modifyIORef' restored (+ 1)
              writeIORef released True
              pure (Left "release acknowledgement lost")}
        token <- withProcessLock store (\locked -> acquireDataFence locked uncertain request)
          >>= right >>= right
        _ <- withProcessLock store (\locked -> beginDataChange locked uncertain token)
          >>= right >>= right
        _ <- withProcessLock store (\locked -> verifyDataChange locked uncertain token)
          >>= right >>= right
        outcome <- withProcessLock store (\locked -> releaseDataFence locked uncertain token)
          >>= right
        case outcome of
          Left _ -> pure ()
          Right () -> assertFailure "lost acknowledgement should remain unresolved"
        active <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        fmap fencePhase (headDataFence active) @?= Just FenceReleasing
        _ <- withProcessLock store (\locked -> releaseDataFence locked uncertain token)
          >>= right >>= right
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
              interrupted = original {restoreFenceWriters = \_ ->
                pure (Left "interrupted before writer release")}
          token <- withProcessLock store (\locked -> acquireDataFence locked original request)
            >>= right >>= right
          _ <- withProcessLock store (\locked -> beginDataChange locked original token)
            >>= right >>= right
          _ <- withProcessLock store (\locked -> verifyDataChange locked original token)
            >>= right >>= right
          outcome <- withProcessLock store (\locked -> releaseDataFence locked interrupted token)
            >>= right
          case outcome of
            Left _ -> pure ()
            Right () -> assertFailure "interrupted release appeared complete"
          readIORef restored >>= (@?= 0)
          reopened <- openFilesystemStore root >>= right
          resumed <- withProcessLock reopened (\locked -> resumeDataFence locked "restore-session")
            >>= right >>= right
          _ <- withProcessLock reopened (\locked -> recoverDataFence locked original resumed)
            >>= right >>= right
          readIORef restored >>= (@?= 1)
          final <- readHead reopened >>= right >>= maybe
            (assertFailure "head missing" >> error "head") pure
          headDataFence final @?= Nothing
    , testCase "partial writer release is not replayed" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let original = fixtureControls released restored (pure (Right physical))
            partial = original
              { restoreFenceWriters = \_ -> do
                  modifyIORef' restored (+ 1)
                  pure (Left "one writer changed before interruption")
              , observeWritersReleased = \_ -> pure (Right WritersPartlyReleased)
              }
        token <- withProcessLock store (\locked -> acquireDataFence locked partial request)
          >>= right >>= right
        _ <- withProcessLock store (\locked -> beginDataChange locked partial token)
          >>= right >>= right
        _ <- withProcessLock store (\locked -> verifyDataChange locked partial token)
          >>= right >>= right
        _ <- withProcessLock store (\locked -> releaseDataFence locked partial token)
          >>= right
        repeated <- withProcessLock store (\locked -> releaseDataFence locked partial token)
          >>= right
        case repeated of
          Left _ -> pure ()
          Right () -> assertFailure "partial writer release was accepted"
        readIORef restored >>= (@?= 1)
        active <- readHead store >>= right >>= maybe
          (assertFailure "head missing" >> error "head") pure
        fmap fencePhase (headDataFence active) @?= Just FenceReleasing
    , testCase "changed target identity leaves a durable unresolved fence" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let changed = Map.insert target (known (mkPhysicalIdentity "replacement-uid")) physical
            controls = fixtureControls released restored (pure (Right changed))
        outcome <- withProcessLock store (\locked -> acquireDataFence locked controls request)
          >>= right
        case outcome of
          Left _ -> pure ()
          Right _ -> assertFailure "changed target identity acquired fence"
        active <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        fmap fencePhase (headDataFence active) @?= Just FenceUnresolved
    , testCase "reviewed transaction may own only its matching fence" $ do
        store <- newMemoryStore
        initial <- initializeStore store binding "operator-a" >>= right
        let transaction = "tx-reviewed-restore"
            active = initial
              { headGeneration = 1
              , headActiveTransaction = Just transaction
              , headExecutorClaim = Just (ExecutorClaim transaction "operator-a" 1 "time")
              }
        _ <- replaceHeadIfGenerationMatches store (Just 0) active >>= right
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let controls = fixtureControls released restored (pure (Right physical))
        wrong <- withProcessLock store (\locked -> acquireDataFence locked controls
          request {fenceTransaction = Just "tx-other"}) >>= right
        case wrong of
          Left _ -> pure ()
          Right _ -> assertFailure "a foreign transaction acquired the fence"
        _ <- replaceHeadIfGenerationMatches store (Just 1)
          active {headGeneration = 2, headExecutorClaim =
            Just (ExecutorClaim transaction "operator-b" 2 "time")} >>= right
        foreignClaim <- withProcessLock store (\locked -> acquireDataFence locked controls
          request {fenceTransaction = Just transaction}) >>= right
        case foreignClaim of
          Left _ -> pure ()
          Right _ -> assertFailure "a foreign executor acquired the fence"
        _ <- replaceHeadIfGenerationMatches store (Just 2)
          active {headGeneration = 3} >>= right
        _ <- withProcessLock store (\locked -> acquireDataFence locked controls
          request {fenceTransaction = Just transaction}) >>= right >>= right
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
        proposal <- right (planChanges candidate noLifecycleDecisions history
          (known (observationSet [])))
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
          admitted <- readHead store >>= right >>= maybe
            (assertFailure "head missing" >> error "head") pure
          let transaction = maybe (error "transaction missing") id
                (headActiveTransaction admitted)
          _ <- acquireDataFence locked controls request
            { fenceTransaction = Just transaction
            , fenceAccepted = headAccepted admitted
            } >>= right
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
          Left errors -> assertBool "resume must defer to explicit fence recovery"
            (any ((== "active-data-fence") . admissionErrorCode) errors)
          Right _ -> assertFailure "resumed an actively fenced restore"
        fenced <- readHead store >>= right >>= maybe
          (assertFailure "head missing" >> error "head") pure
        headSequence fenced @?= 1
        assertBool "transaction remains active" (isJust (headActiveTransaction fenced))
        assertBool "fence remains active" (isJust (headDataFence fenced))
    , testCase "mount guard binds an exact PVC and authenticated restore Job" $ do
        let pvcUid = "11111111-2222-3333-4444-555555555555"
            pvUid = "66666666-7777-8888-9999-000000000000"
            jobUid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            statefulUid = "ffffffff-0000-1111-2222-333333333333"
        permit <- right (mkPodOwnerPermit "Job" "restore-job" jobUid
          "system:serviceaccount:kube-system:job-controller")
        writerPermit <- right (mkPodOwnerPermit "StatefulSet" "database" statefulUid
          "system:serviceaccount:kube-system:statefulset-controller")
        guard <- right (mkMountGuard "restore-session" "restore-space" "data-pvc"
          pvcUid "pv-data" pvUid [permit, writerPermit])
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
        (bindingSpec >>= field "validationActions") @?=
          Just (toJSON (["Deny"] :: [Text]))
        (field "spec" pvcPolicy >>= field "failurePolicy") @?= Just (String "Fail")
        (field "spec" pvcBinding >>= field "validationActions") @?=
          Just (toJSON (["Deny"] :: [Text]))
        case field "spec" pvcPolicy >>= field "validations" of
          Just (Array values) | firstValidation : _ <- toList values ->
            case field "expression" firstValidation of
              Just (String value) -> assertBool "claim mutation guard checks the old object"
                ("oldObject.metadata.name != 'data-pvc'" `T.isInfixOf` value)
              _ -> assertFailure "PVC guard lacks an expression"
          _ -> assertFailure "PVC guard lacks validations"
        let guardedExpression guardedPolicy = case field "spec" guardedPolicy >>= field "validations" of
              Just (Array values) | firstValidation : _ <- toList values ->
                field "expression" firstValidation
              _ -> Nothing
        guardedExpression pvPolicy @?= Just (String "oldObject.metadata.name != 'pv-data'")
        guardedExpression namespacePolicy @?=
          Just (String "oldObject.metadata.name != 'restore-space'")
        case expression of
          Just (String value) -> do
            assertBool "PVC name is constrained" ("data-pvc" `T.isInfixOf` value)
            assertBool "Job UID is constrained" (jobUid `T.isInfixOf` value)
            assertBool "writer UID is constrained" (statefulUid `T.isInfixOf` value)
            assertBool "controller principal is constrained"
              ("system:serviceaccount:kube-system:job-controller" `T.isInfixOf` value)
          _ -> assertFailure "mount guard lacks a CEL expression"
        case mkPodOwnerPermit "Job" "restore-job" jobUid "foreign' || true" of
          Left _ -> pure ()
          Right _ -> assertFailure "CEL injection was accepted"
        case mkMountGuard "restore-session" "restore-space" "data-pvc"
          "wrong-uid" "pv-data" pvUid [] of
          Left _ -> pure ()
          Right _ -> assertFailure "unbound PVC UID was accepted"
        case mkMountGuard "restore-session" "restore_space" "data-pvc"
          pvcUid "pv-data" pvUid [] of
          Left _ -> pure ()
          Right _ -> assertFailure "invalid Kubernetes namespace was accepted"
    , testCase "mount guard install resumes and proof rejects policy drift" $ do
        guard <- right (mkMountGuard "restore-session" "restore-space" "data-pvc"
          "11111111-2222-3333-4444-555555555555" "pv-data"
          "66666666-7777-8888-9999-000000000000" [])
        objects <- newIORef (Map.empty :: Map.Map (Text, Text) Value)
        creates <- newIORef (0 :: Int)
        failSecondCreate <- newIORef True
        denied <- newIORef True
        let address (Object value) = case
              (KM.lookup "kind" value, KM.lookup "metadata" value) of
              (Just (String kind), Just (Object metadata)) ->
                case KM.lookup "name" metadata of
                  Just (String name) -> (kind, name)
                  _ -> error "guard object lacks name"
              _ -> error "guard object lacks kind"
            address _ = error "guard object is not JSON"
            transport = MountGuardTransport
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
              , probeForeignMountDenied = \_ -> Right <$> readIORef denied
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
        modifyIORef' objects (Map.adjust (\value -> case value of
          Object fields -> Object (KM.insert "spec" (object []) fields)
          other -> other) ("ValidatingAdmissionPolicy", name))
        observeMountGuard transport guard >>= right >>= (@?= False)
        result <- installMountGuard transport guard
        case result of
          Left _ -> pure ()
          Right () -> assertFailure "changed policy was accepted on restart"
        readIORef creates >>= (@?= 9)
    , testCase "exact volume evidence counts every Pod and attachment consumer" $ do
        mountGuard <- right (mkMountGuard "restore-session" "restore-space" "data-pvc"
          "11111111-2222-3333-4444-555555555555" "pv-data"
          "66666666-7777-8888-9999-000000000000" [])
        let pvc = object
              [ "metadata" .= object
                  [ "namespace" .= ("restore-space" :: Text)
                  , "name" .= ("data-pvc" :: Text)
                  , "uid" .= ("11111111-2222-3333-4444-555555555555" :: Text)]
              , "spec" .= object
                  [ "volumeName" .= ("pv-data" :: Text)
                  , "accessModes" .= (["ReadWriteOnce"] :: [Text])]
              , "status" .= object ["phase" .= ("Bound" :: Text)]
              ]
            pv = object
              [ "metadata" .= object
                  [ "name" .= ("pv-data" :: Text)
                  , "uid" .= ("66666666-7777-8888-9999-000000000000" :: Text)]
              , "spec" .= object
                  [ "accessModes" .= (["ReadWriteOnce"] :: [Text])
                  , "claimRef" .= object
                      [ "namespace" .= ("restore-space" :: Text)
                      , "name" .= ("data-pvc" :: Text)
                      , "uid" .= ("11111111-2222-3333-4444-555555555555" :: Text)]
                  , "csi" .= object
                      [ "driver" .= ("example.csi" :: Text)
                      , "volumeHandle" .= ("disk-123" :: Text)]
                  ]
              , "status" .= object ["phase" .= ("Bound" :: Text)]
              ]
            emptyPods = object ["items" .= ([] :: [Value])]
            emptyAttachments = object ["items" .= ([] :: [Value])]
            mountedPod = object
              [ "metadata" .= object
                  [ "namespace" .= ("restore-space" :: Text)
                  , "name" .= ("foreign" :: Text)
                  , "uid" .= ("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" :: Text)]
              , "spec" .= object ["volumes" .= [object
                  [ "persistentVolumeClaim" .= object
                      ["claimName" .= ("data-pvc" :: Text)]]]]
              ]
            attachment = object
              [ "metadata" .= object
                  [ "name" .= ("attachment" :: Text)
                  , "uid" .= ("ffffffff-0000-1111-2222-333333333333" :: Text)]
              , "spec" .= object ["source" .= object
                  ["persistentVolumeName" .= ("pv-data" :: Text)]]
              , "status" .= object ["attached" .= False]
              ]
            backing = CsiVolume "example.csi" "disk-123"
            observed pods attachments = parseVolumeEvidence mountGuard backing
              pvc pv pods attachments
        emptyEvidence <- right (observed emptyPods emptyAttachments)
        assertBool "empty volume should have no consumers"
          (volumeHasNoConsumers emptyEvidence)
        probes <- newIORef [True, True]
        let guardObjects = concatMap (\(policy, bindingValue) ->
              [policy, bindingValue])
              [ mountGuardObjects mountGuard
              , pvcMutationGuardObjects mountGuard
              , pvMutationGuardObjects mountGuard
              , namespaceDeleteGuardObjects mountGuard
              ]
            address (Object fields) = case
              (KM.lookup "kind" fields, KM.lookup "metadata" fields) of
              (Just (String kind), Just (Object metadata)) ->
                case KM.lookup "name" metadata of
                  Just (String name) -> Just (kind, name)
                  _ -> Nothing
              _ -> Nothing
            address _ = Nothing
            guardedTransport = MountGuardTransport
              { readGuardObject = \kind name ->
                  pure (Right (find ((== Just (kind, name)) . address) guardObjects))
              , createGuardObject = \_ -> pure (Left "unexpected create")
              , probeForeignMountDenied = \_ -> atomicModifyIORef' probes $ \values ->
                  case values of
                    next : rest -> (rest, Right next)
                    [] -> ([], Right False)
              }
            volumeTransport = VolumeTransport
              { readClaim = \_ _ -> pure (Right pvc)
              , readVolume = \_ -> pure (Right pv)
              , listNamespacePods = \_ -> pure (Right emptyPods)
              , listVolumeAttachments = pure (Right emptyAttachments)
              }
        observeGuardedVolumeExcluded guardedTransport volumeTransport
          mountGuard backing >>= right >>= (@?= True)
        writeIORef probes [True, False]
        observeGuardedVolumeExcluded guardedTransport volumeTransport
          mountGuard backing >>= right >>= (@?= False)
        podEvidence <- right (observed
          (object ["items" .= [mountedPod]]) emptyAttachments)
        volumePodConsumers podEvidence @?=
          ["foreign/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"]
        assertBool "Pod still has the PVC" (not (volumeHasNoConsumers podEvidence))
        attachmentEvidence <- right (observed emptyPods
          (object ["items" .= [attachment]]))
        assertBool "detached attachment intent still exists"
          (not (volumeHasNoConsumers attachmentEvidence))
        case parseVolumeEvidence mountGuard (CsiVolume "example.csi" "other")
          pvc pv emptyPods emptyAttachments of
          Left _ -> pure ()
          Right _ -> assertFailure "changed CSI handle was accepted"
        let localPv = case pv of
              Object fields | Just (Object spec) <- KM.lookup "spec" fields ->
                Object (KM.insert "spec" (Object
                  (KM.insert "nodeAffinity" (object ["required" .= object
                    ["nodeSelectorTerms" .= [object ["matchExpressions" .= [object
                      [ "key" .= ("kubernetes.io/hostname" :: Text)
                      , "operator" .= ("In" :: Text)
                      , "values" .= (["node-a"] :: [Text])]]]]]])
                    (KM.insert "local" (object ["path" .= ("/data/disk" :: Text)])
                    (KM.delete "csi" spec)))) fields)
              other -> other
        localEvidence <- right (parseVolumeEvidence mountGuard
          (LocalVolume "/data/disk" "node-a") pvc localPv
          emptyPods emptyAttachments)
        assertBool "local volume has no consumers"
          (volumeHasNoConsumers localEvidence)
        case parseVolumeEvidence mountGuard (LocalVolume "/data/disk" "node-b")
          pvc localPv emptyPods emptyAttachments of
          Left _ -> pure ()
          Right _ -> assertFailure "changed local PV node was accepted"
        let replacedClaim = case pvc of
              Object fields | Just (Object metadata) <- KM.lookup "metadata" fields ->
                Object (KM.insert "metadata" (Object (KM.insert "uid"
                  (String "bbbbbbbb-2222-3333-4444-555555555555") metadata)) fields)
              other -> other
        case parseVolumeEvidence mountGuard backing replacedClaim pv
          emptyPods emptyAttachments of
          Left _ -> pure ()
          Right _ -> assertFailure "replaced PVC UID was accepted"
    , testCase "StatefulSet writer scale and release require observed convergence" $ do
        let uid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        pin <- right (mkStatefulWriterPin "restore-space" "database" uid 2)
        current <- newIORef (object
          [ "metadata" .= object
              [ "namespace" .= ("restore-space" :: Text)
              , "name" .= ("database" :: Text)
              , "uid" .= (uid :: Text)
              , "resourceVersion" .= ("10" :: Text)
              , "generation" .= (1 :: Int)]
          , "spec" .= object ["replicas" .= (2 :: Int)]
          , "status" .= object
              [ "observedGeneration" .= (1 :: Int)
              , "replicas" .= (2 :: Int)
              , "readyReplicas" .= (2 :: Int)]
          ])
        patches <- newIORef ([] :: [Value])
        loseAck <- newIORef True
        let replaceObject key update (Object fields)
              | Just (Object nested) <- KM.lookup key fields =
                  Object (KM.insert key (Object (update nested)) fields)
            replaceObject _ _ value = value
            setSpecReplicas replicas = replaceObject "spec"
              (KM.insert "replicas" (toJSON replicas))
            setStatus replicas generation = replaceObject "status"
              (KM.insert "observedGeneration" (toJSON generation)
                . KM.insert "readyReplicas" (toJSON replicas)
                . KM.insert "replicas" (toJSON replicas))
            setMetadata = replaceObject "metadata"
              (KM.insert "resourceVersion" (String "11")
                . KM.insert "generation" (toJSON (2 :: Int)))
            transport = StatefulWriterTransport
              { readStatefulWriter = \_ _ -> Right <$> readIORef current
              , patchStatefulWriter = \_ _ patch -> do
                  modifyIORef' patches (<> [patch])
                  let requested = case patch of
                        Array operations | Just (Object lastOp) <-
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
        observeStatefulWriterStopped transport pin >>= (@?= Right False)
        restoreStatefulWriter transport pin >>=
          (@?= Left "StatefulSet has not finished stopping")
        modifyIORef' current (setStatus (0 :: Int) (2 :: Int))
        observeStatefulWriterStopped transport pin >>= (@?= Right True)
        observeStatefulWriterRelease transport pin >>= (@?= Right WritersStillExcluded)
        restoreStatefulWriter transport pin >>= (@?= Right ())
        observeStatefulWriterRelease transport pin >>= (@?= Right WritersPartlyReleased)
        modifyIORef' current (setStatus (2 :: Int) (2 :: Int))
        observeStatefulWriterRelease transport pin >>= (@?= Right WritersFullyReleased)
        restoreStatefulWriter transport pin >>= (@?= Right ())
        readIORef patches >>= \values -> length values @?= 2
        modifyIORef' current (replaceObject "metadata"
          (KM.insert "uid" (String "bbbbbbbb-2222-3333-4444-555555555555")))
        stopped <- stopStatefulWriter transport pin
        case stopped of
          Left _ -> pure ()
          Right () -> assertFailure "replaced StatefulSet UID was accepted"
    , testCase "reviewed adapter effect runs only inside a verified fence" $ do
        store <- newMemoryStore
        steps <- newIORef ([] :: [Text])
        released <- newIORef False
        let recordStep step = modifyIORef' steps (<> [step])
            controls = DataFenceControls
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
              }
            customize desired registry = known (withAdapterFence registry KubernetesExecutor
              AdapterFence
                { fenceCapability = "recorded-fence-v1"
                , fenceForOperation = \_ _ -> Right (Just
                    (request {fenceContext = fixtureBinding, fenceAccepted = desired}, controls))
                })
            effect _ _ = recordStep "effect" >> pure AdapterEffectCompleted
            recovery _ _ = pure RecoverySafeToRetry
        (reviewed, registry) <- preparedFixtureWithRegistry store effect recovery customize
        assertBool "review must bind the fence capability" (any
          ((== Just "recorded-fence-v1") . reviewFenceCapability)
          (reviewOperations (reviewedDocument reviewed)))
        assertBool "review must bind exact fence inputs" (any
          (isJust . reviewFenceDigest) (reviewOperations (reviewedDocument reviewed)))
        assertBool "review must show fence and recovery steps" (any
          (maybe False (T.isInfixOf "data fence: acquire, verify, release")
            . reviewFenceSummary)
          (reviewOperations (reviewedDocument reviewed)))
        outcome <- applyReviewed store registry reviewed >>= right
        case outcome of
          Converged _ -> pure ()
          _ -> assertFailure "fenced reviewed operation did not converge"
        observed <- readIORef steps
        let position step = maybe (error ("missing " <> T.unpack step)) id
              (elemIndex step observed)
        assertBool "writer stop precedes effect" (position "stop" < position "effect")
        assertBool "data verification follows effect"
          (position "effect" < position "verify-data")
        assertBool "release follows verification"
          (position "verify-data" < position "release")
        final <- readHead store >>= right >>= maybe
          (assertFailure "head missing" >> error "head") pure
        headDataFence final @?= Nothing
    , testCase "saved fenced review refuses a registry without its capability" $ do
        store <- newMemoryStore
        effects <- newIORef (0 :: Int)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let controls = fixtureControls released restored (pure (Right physical))
            effect _ _ = modifyIORef' effects (+ 1) >> pure AdapterEffectCompleted
            recovery _ _ = pure RecoverySafeToRetry
            customize desired registry = known (withAdapterFence registry KubernetesExecutor
              AdapterFence
                { fenceCapability = "recorded-fence-v1"
                , fenceForOperation = \_ _ -> Right (Just
                    (request {fenceContext = fixtureBinding, fenceAccepted = desired}, controls))
                })
        (reviewed, _) <- preparedFixtureWithRegistry store effect recovery customize
        let plain = recordingRegistryWith (\_ _ -> pure (Right ())) effect recovery
        refused <- applyReviewed store plain reviewed
        case refused of
          Left errors -> assertBool "missing fence capability was not refused"
            (any ((== "data-fence-capability") . admissionErrorCode) errors)
          Right _ -> assertFailure "fenced review ran without the fence provider"
        let changedPhysical = Map.insert target
              (known (mkPhysicalIdentity "substituted-uid")) physical
            altered = known (withAdapterFence plain KubernetesExecutor AdapterFence
              { fenceCapability = "recorded-fence-v1"
              , fenceForOperation = \_ _ -> Right (Just
                  (request
                    { fenceContext = fixtureBinding
                    , fenceAccepted = reviewDesiredRevisions (reviewedDocument reviewed)
                    , fencePhysical = changedPhysical
                    }, controls))
              })
        substituted <- applyReviewed store altered reviewed
        case substituted of
          Left errors -> assertBool "changed physical target escaped review digest"
            (any ((== "data-fence-capability") . admissionErrorCode) errors)
          Right _ -> assertFailure "fenced review admitted a substituted target"
        readIORef effects >>= (@?= 0)
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
            customize desired registry = known (withAdapterFence registry KubernetesExecutor
              AdapterFence
                { fenceCapability = "recorded-fence-v1"
                , fenceForOperation = \_ _ -> Right (Just
                    (request {fenceContext = fixtureBinding, fenceAccepted = desired}, controls))
                })
        (reviewed, registry) <- preparedFixtureWithRegistry store effect recovery customize
        outcome <- applyReviewed store registry reviewed >>= right
        transaction <- case outcome of
          StoppedAmbiguous value _ -> pure value
          _ -> assertFailure "ambiguous effect did not stop the transaction" >> error "transaction"
        fenced <- readHead store >>= right >>= maybe
          (assertFailure "head missing" >> error "head") pure
        fmap fencePhase (headDataFence fenced) @?= Just FenceUnresolved
        resumed <- resumeTransaction store registry transaction
        case resumed of
          Left errors -> assertBool "ordinary resume bypassed the unresolved fence"
            (any ((== "active-data-fence") . admissionErrorCode) errors)
          Right _ -> assertFailure "ambiguous fenced effect resumed"
        readIORef effects >>= (@?= 1)
        readIORef restored >>= (@?= 0)
  ]

fixtureControls :: IORef Bool -> IORef Int
  -> IO (Either Text (Map.Map ResourceId PhysicalIdentity)) -> DataFenceControls
fixtureControls released restored observe = DataFenceControls
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
  }

request :: DataFenceRecord
request = DataFenceRecord binding "restore-session" Nothing Map.empty physical
  (Set.singleton target) (Set.singleton writer) "gs://fixture/recovery"
  (contentDigest "recovery") (Map.singleton writer (object [])) FenceAcquiring ""

physical :: Map.Map ResourceId PhysicalIdentity
physical = Map.fromList
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

known :: Show e => Either e a -> a
known = either (error . show) id

right :: Show e => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> error "unreachable") pure
