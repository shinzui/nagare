module InventoryObjectOpsSpec (inventoryObjectOpsTests, fakeObjectOps) where

import Data.Aeson (object)
import Data.IORef
import Crypto.Random (getRandomBytes)
import Data.Either (isLeft, isRight)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (exerciseStore, fixtureBinding, preparedFixtureWith, recordingRegistryWith)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.DataFence
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal
import Nagare.Inventory.Status (loadActiveTransactionStatus)
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Ops.PulumiBackend (GcloudOps (..), bucketOwnershipVerdict, bucketProjectNumberArgs, gcsBucketOfUrl, projectNumberArgs, realGcloudOps)
import Nagare.Resource.Types
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

inventoryObjectOpsTests :: TestTree
inventoryObjectOpsTests = testGroup "inventory object operations"
  [ testCase "conditional upload accepts only an exact version-specific created URL" $ do
      let prefix = "gs://example-bucket/private/inventory"
          name = ObjectName "journal/00000000000000000001.json"
      createdGeneration prefix name "Created gs://example-bucket/private/inventory/journal/00000000000000000001.json#123\n"
        @?= Just (Generation 123)
      createdGeneration prefix name "Created gs://example-bucket/private/inventory/journal/00000000000000000002.json#123\n"
        @?= Nothing
      createdGeneration prefix name "Created gs://example-bucket/private/inventory/journal/00000000000000000001.json#bad\n"
        @?= Nothing
  , testCase "future canonical inventory head remains discoverable without decoding ownership" $ do
      inspectHeadSchema "{\"version\":2}" @?= Right 2
      assertBool "noncanonical future head is refused"
        (isLeft (inspectHeadSchema "{ \"version\": 2 }"))
      assertBool "missing schema is refused"
        (isLeft (inspectHeadSchema "{}"))
      store <- newMemoryStore
      _ <- publishIfAbsent store "head.json" "{\"version\":2}"
        >>= either (assertFailure . show) pure
      readHead store >>= assertBool "future head cannot be used for mutation" . isLeft
  , testCase "object-backed inventory obeys the existing conditional store contract" $ do
      ops <- fakeObjectOps
      store <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
      exerciseStore store
  , testCase "journal replay reads 50 and 500 committed members in one batch and rejects gaps" $ do
      baseOps <- fakeObjectOps
      store <- newObjectStore baseOps fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      mapM_ (\sequenceNumber ->
        appendAtSequence store sequenceNumber ("event-" <> BC.pack (show sequenceNumber))
          >>= either (assertFailure . show) pure) [0 .. 499]
      batches <- newIORef (0 :: Int)
      singles <- newIORef (0 :: Int)
      let countedOps = baseOps
            { getObject = \name -> modifyIORef' singles (+ 1) >> getObject baseOps name
            , getObjects = \name -> modifyIORef' batches (+ 1) >> getObjects baseOps name
            }
      replay <- newObjectStore countedOps fixtureBinding "client-b" Nothing
        >>= either (assertFailure . show) pure
      writeIORef singles 0
      first50 <- readJournalPrefix replay 50 >>= either (assertFailure . show) pure
      length first50 @?= 50
      all500 <- readJournalPrefix replay 500 >>= either (assertFailure . show) pure
      length all500 @?= 500
      readIORef batches >>= (@?= 2)
      readIORef singles >>= (@?= 0)
      missing <- readJournalPrefix replay 501
      assertBool "a missing committed member is an error" (isLeft missing)
  , testCase "observed head carries provider generation without rediscovery and refuses ABA replacement" $ do
      base <- fakeObjectOps
      gets <- newIORef (0 :: Int)
      let counted = base {getObject = \key -> modifyIORef' gets (+ 1) >> getObject base key}
      store <- newObjectStore counted fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
      initial <- initializeStore store fixtureBinding "client-a" >>= either (assertFailure . show) pure
      writeIORef gets 0
      observed <- observeHead store >>= either (assertFailure . show) pure
      observedHeadManifest observed @?= Just initial
      readIORef gets >>= (@?= 1)
      replaceObservedHead observed initial {headGeneration = 1} >>= (@?= Right ())
      readIORef gets >>= (@?= 1)
      -- Rewrite identical bytes under a new provider generation. Logical head
      -- equality cannot detect this; the captured provider generation must.
      stale <- observeHead store >>= either (assertFailure . show) pure
      current <- getObject base (ObjectName "head.json")
      case current of
        ObjectFound generation bytes -> do
          _ <- putObject base (IfGenerationMatches generation) (ObjectName "head.json") bytes
          pure ()
        _ -> assertFailure "head missing"
      rejected <- replaceObservedHead stale initial {headGeneration = 2}
      assertBool "stale provider generation accepted" (isLeft rejected)
      replaceObservedHead observed initial {headGeneration = 1}
        >>= assertBool "reused observation accepted" . isLeft
  , testCase "local observed head refuses intervening updates and migrated authority" $ do
      store <- newMemoryStore
      initial <- initializeStore store fixtureBinding "client-a" >>= either (assertFailure . show) pure
      observed <- observeHead store >>= either (assertFailure . show) pure
      replaceHeadIfGenerationMatches store (Just 0) initial {headGeneration = 1}
        >>= (@?= Right ())
      replaceObservedHead observed initial {headGeneration = 1}
        >>= assertBool "local stale observation accepted" . isLeft
      migrated <- observeHead store >>= either (assertFailure . show) pure
      replaceObservedHead migrated initial {headGeneration = 2,
        headMigration = Just (MigrationTombstone "elsewhere" (contentDigest "destination"))}
        >>= (@?= Right ())
      tombstone <- observeHead store >>= either (assertFailure . show) pure
      replaceObservedHead tombstone initial {headGeneration = 3}
        >>= assertBool "migrated head allowed a write" . isLeft
  , testCase "known-head journal append uses one conditional write without rediscovery" $ do
      baseOps <- fakeObjectOps
      gets <- newIORef (0 :: Int)
      puts <- newIORef (0 :: Int)
      let countedOps = baseOps
            { getObject = \name -> modifyIORef' gets (+ 1) >> getObject baseOps name
            , putObject = \condition name bytes ->
                modifyIORef' puts (+ 1) >> putObject baseOps condition name bytes
            }
      store <- newObjectStore countedOps fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      headValue <- initializeStore store fixtureBinding "client-a"
        >>= either (assertFailure . show) pure
      writeIORef gets 0
      writeIORef puts 0
      _ <- appendAtObservedHead store headValue "event-0" >>= either (assertFailure . show) pure
      readIORef gets >>= (@?= 0)
      readIORef puts >>= (@?= 1)
      conflict <- appendAtObservedHead store headValue "event-1"
      assertBool "conditional creation refuses a competing event" (isLeft conflict)
  , testCase "active status verifies 50 and 500 chained events with one batch each" $ do
      baseOps <- fakeObjectOps
      store <- newObjectStore baseOps fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      initial <- initializeStore store fixtureBinding "client-a"
        >>= either (assertFailure . show) pure
      transaction <- either (assertFailure . T.unpack) pure (mkTransactionId "tx-status-batch")
      previous <- newIORef Nothing
      mapM_ (\sequenceNumber -> do
        prior <- readIORef previous
        let event = JournalEvent 1 sequenceNumber prior transaction Nothing Pending
              "2026-09-29T00:00:00Z" "status batch regression"
        _ <- appendAtSequence store sequenceNumber (encodeJournalEvent event)
          >>= either (assertFailure . show) pure
        writeIORef previous (Just (journalEventDigest event))) [0 .. 499]
      singles <- newIORef (0 :: Int)
      batches <- newIORef (0 :: Int)
      let countedOps = baseOps
            { getObject = \name -> modifyIORef' singles (+ 1) >> getObject baseOps name
            , getObjects = \name -> modifyIORef' batches (+ 1) >> getObjects baseOps name }
      replay <- newObjectStore countedOps fixtureBinding "client-b" Nothing
        >>= either (assertFailure . show) pure
      writeIORef singles 0
      mapM_ (\count -> do
        let committed = initial {headSequence = count,
              headActiveTransaction = Just (transactionIdText transaction)}
        loaded <- loadActiveTransactionStatus replay committed
        assertBool "active status rejected a valid chained prefix" (isRight loaded)) [50, 500]
      readIORef singles >>= (@?= 0)
      readIORef batches >>= (@?= 2)
      let missingOps = countedOps {getObjects = \name ->
            fmap (fmap (Map.delete (ObjectName (T.pack (journalKey 49)))))
              (getObjects baseOps name)}
      missingStore <- newObjectStore missingOps fixtureBinding "client-c" Nothing
        >>= either (assertFailure . show) pure
      missing <- loadActiveTransactionStatus missingStore initial
        {headSequence = 50, headActiveTransaction = Just (transactionIdText transaction)}
      assertBool "active status accepted a committed journal gap" (isLeft missing)
  , testCase "converged replay needs no provider registry or repeated journal pass" $ do
      baseOps <- fakeObjectOps
      store <- newObjectStore baseOps fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      effects <- newIORef (0 :: Int)
      (reviewed, registry) <- preparedFixtureWith store
        (\_ _ -> modifyIORef' effects (+ 1) >> pure AdapterEffectCompleted)
        (\_ _ -> pure RecoverySafeToRetry)
      applied <- applyReviewed store registry reviewed
        >>= either (assertFailure . show) pure
      transaction <- case applied of
        Converged value -> pure value
        other -> assertFailure (show other) >> error "unreachable"
      batches <- newIORef (0 :: Int)
      let countedOps = baseOps {getObjects = \name ->
            modifyIORef' batches (+ 1) >> getObjects baseOps name}
      replay <- newObjectStore countedOps fixtureBinding "client-b" Nothing
        >>= either (assertFailure . show) pure
      emptyRegistry <- either (assertFailure . T.unpack) pure (mkAdapterRegistry [])
      resumeTransaction replay emptyRegistry transaction
        >>= either (assertFailure . show) pure >>= (@?= Converged transaction)
      readIORef batches >>= (@?= 1)
      readIORef effects >>= (@?= 1)
  , testCase "active resume reads one journal batch and does not repeat proved effect" $ do
      baseOps <- fakeObjectOps
      firstStore <- newObjectStore baseOps fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      effects <- newIORef ([] :: [OperationId])
      let executeOnce operation _ = do
            modifyIORef' effects (<> [plannedOperationId operation])
            pure (AdapterEffectAmbiguous "provider effect completed; acknowledgement lost")
          recover operation _ = pure (RecoveryProvedComplete
            (contentDigest (TE.encodeUtf8 (operationIdText (plannedOperationId operation)))))
      (reviewed, registry) <- preparedFixtureWith firstStore executeOnce
        recover
      stopped <- applyReviewed firstStore registry reviewed
        >>= either (assertFailure . show) pure
      transaction <- case stopped of
        StoppedAmbiguous value _ -> pure value
        other -> assertFailure (show other) >> error "unreachable"
      readIORef effects >>= (\calls -> length calls @?= 1)
      batches <- newIORef (0 :: Int)
      let countedOps = baseOps {getObjects = \name ->
            modifyIORef' batches (+ 1) >> getObjects baseOps name}
      replay <- newObjectStore countedOps fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      resumeTransaction replay registry transaction
        >>= either (assertFailure . show) pure >>= (@?= Converged transaction)
      readIORef batches >>= (@?= 1)
      readIORef effects >>= (\calls -> length calls @?= 1)
  , testCase "two object clients sharing a workstation process lock cannot overlap" $
      withSystemTempDirectory "inventory-object-lock" $ \root -> do
        ops <- fakeObjectOps
        let lockPath = root </> "inventory-remote.lock"
        firstStore <- newObjectStoreWithLock ops fixtureBinding "client-a" Nothing lockPath
          >>= either (assertFailure . show) pure
        secondStore <- newObjectStoreWithLock ops fixtureBinding "client-b" Nothing lockPath
          >>= either (assertFailure . show) pure
        held <- withProcessLock firstStore $ \_ -> withProcessLock secondStore (\_ -> pure ())
        held @?= Right (Left StoreBusy)
  , testCase "two clients cannot replace one observed head generation" $ do
      ops <- fakeObjectOps
      firstStore <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
      secondStore <- newObjectStore ops fixtureBinding "client-b" Nothing >>= either (assertFailure . show) pure
      let known = either (error . T.unpack) id
          binding = ContextBinding (known (mkContextId "object-test")) (known (mkName "project"))
      initial <- initializeStore firstStore binding "client-a" >>= either (assertFailure . show) pure
      observed <- readHead secondStore >>= either (assertFailure . show) pure
      observed @?= Just initial
      _ <- replaceHeadIfGenerationMatches firstStore (Just 0) (initial {headGeneration = 1})
        >>= either (assertFailure . show) pure
      stale <- replaceHeadIfGenerationMatches secondStore (Just 0) (initial {headGeneration = 1})
      assertBool "second client must see a stale head" (isLeft stale)
  , testCase "second client cannot admit a review while the first holds its claim" $ do
      ops <- fakeObjectOps
      firstStore <- newObjectStore ops fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      secondStore <- newObjectStore ops fixtureBinding "client-b" Nothing
        >>= either (assertFailure . show) pure
      effects <- newIORef (0 :: Int)
      (reviewed, registry) <- preparedFixtureWith firstStore
        (\_ _ -> modifyIORef' effects (+ 1) >> pure AdapterEffectCompleted)
        (\_ _ -> pure RecoverySafeToRetry)
      firstAdmission <- withProcessLock firstStore (\lock -> fmap (fmap (const ())) (admit lock registry reviewed))
      case firstAdmission of
        Right (Right _) -> pure ()
        other -> assertFailure (show other)
      second <- applyReviewed secondStore registry reviewed
      case second of
        Left failures -> assertBool "second admission did not see the active claim"
          ("active-transaction" `elem` map admissionErrorCode (NE.toList failures))
        Right _ -> assertFailure "second client admitted the same review"
      readIORef effects >>= (@?= 0)
  , testCase "second object client sees a durable fence and refuses a saved review" $ do
      ops <- fakeObjectOps
      firstStore <- newObjectStore ops fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      secondStore <- newObjectStore ops fixtureBinding "client-b" Nothing
        >>= either (assertFailure . show) pure
      effects <- newIORef (0 :: Int)
      (reviewed, registry) <- preparedFixtureWith firstStore
        (\_ _ -> modifyIORef' effects (+ 1) >> pure AdapterEffectCompleted)
        (\_ _ -> pure RecoverySafeToRetry)
      current <- readHead firstStore >>= either (assertFailure . show) pure
        >>= maybe (assertFailure "head missing" >> error "unreachable") pure
      let known = either (error . T.unpack) id
          owner = known (mkScopeId Standalone "fence-object")
          target = mintResourceId owner (known (mkLogicalKey "target")) (known (mkName "pvc"))
          writer = mintResourceId owner (known (mkLogicalKey "writer")) (known (mkName "deployment"))
          physical = Map.fromList
            [ (target, known (mkPhysicalIdentity "target-uid"))
            , (writer, known (mkPhysicalIdentity "writer-uid"))
            ]
          request = DataFenceRecord fixtureBinding "object-fence-session" Nothing
            (headAccepted current) physical (Set.singleton target) (Set.singleton writer)
            "gs://fixture/recovery" (contentDigest "recovery")
            (Map.singleton writer (object [])) Nothing FenceAcquiring ""
          controls = DataFenceControls
            { validateFenceInputs = \_ -> pure (Right ())
            , stopFenceWriters = \_ -> pure (Right ())
            , observeFencePhysical = \_ -> pure (Right physical)
            , observeWritersExcluded = \_ -> pure (Right True)
            , verifyRecoveredData = \_ -> pure (Right True)
            , restoreFenceWriters = \_ -> pure (Right ())
            , observeWritersReleased = \_ -> pure (Right WritersFullyReleased)
            , forwardRecoverPartlyReleased = Nothing
            }
      acquired <- withProcessLock firstStore (\lock -> acquireDataFence lock controls request)
      case acquired of
        Right (Right _) -> pure ()
        _ -> assertFailure "object-backed fence acquisition failed"
      observed <- readHead secondStore >>= either (assertFailure . show) pure
        >>= maybe (assertFailure "head missing" >> error "unreachable") pure
      fmap fenceSession (headDataFence observed) @?= Just "object-fence-session"
      fmap fencePhase (headDataFence observed) @?= Just FenceExcluded
      second <- applyReviewed secondStore registry reviewed
      case second of
        Left failures -> assertBool "second state root did not see the fence"
          ("active-data-fence" `elem` map admissionErrorCode (NE.toList failures))
        Right _ -> assertFailure "second state root admitted a fenced review"
      readIORef effects >>= (@?= 0)
  , testCase "a second client sees the completed reviewed transaction" $ do
      ops <- fakeObjectOps
      firstStore <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
      secondStore <- newObjectStore ops fixtureBinding "client-b" Nothing >>= either (assertFailure . show) pure
      effects <- newIORef (0 :: Int)
      let executeOnce _ _ = modifyIORef' effects (+ 1) >> pure AdapterEffectCompleted
      (reviewed, registry) <- preparedFixtureWith firstStore executeOnce
        (\_ _ -> pure RecoverySafeToRetry)
      result <- applyReviewed firstStore registry reviewed >>= either (assertFailure . show) pure
      transaction <- case result of
        Converged value -> pure value
        other -> assertFailure (show other) >> error "unreachable"
      before <- readIORef effects
      replay <- resumeTransaction secondStore registry transaction >>= either (assertFailure . show) pure
      replay @?= Converged transaction
      readIORef effects >>= (@?= before)
  , testCase "lost journal acknowledgement cannot duplicate an effect" $ do
      baseOps <- fakeObjectOps
      injected <- newIORef False
      let ops = baseOps
            { putObject = \condition name@(ObjectName objectPath) bytes -> do
                shouldInject <- if "journal/" `T.isPrefixOf` objectPath
                  then atomicModifyIORef' injected (\used -> (True, not used))
                  else pure False
                if shouldInject then do
                  _ <- putObject baseOps condition name bytes
                  observed <- getObject baseOps name
                  pure (classifyPutReadback condition bytes observed)
                else putObject baseOps condition name bytes
            }
      firstStore <- newObjectStore ops fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      secondStore <- newObjectStore ops fixtureBinding "client-b" Nothing
        >>= either (assertFailure . show) pure
      effects <- newIORef (0 :: Int)
      (reviewed, registry) <- preparedFixtureWith firstStore
        (\_ _ -> modifyIORef' effects (+ 1) >> pure AdapterEffectCompleted)
        (\_ _ -> pure RecoverySafeToRetry)
      result <- applyReviewed firstStore registry reviewed >>= either (assertFailure . show) pure
      transaction <- case result of
        Converged value -> pure value
        other -> assertFailure (show other) >> error "unreachable"
      readIORef injected >>= (@?= True)
      replay <- resumeTransaction secondStore registry transaction >>= either (assertFailure . show) pure
      replay @?= Converged transaction
      readIORef effects >>= (@?= 1)
  , testCase "foreign claim requires explicit takeover and advances its epoch" $ do
      ops <- fakeObjectOps
      firstStore <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
      secondStore <- newObjectStore ops fixtureBinding "client-b" Nothing >>= either (assertFailure . show) pure
      effects <- newIORef (0 :: Int)
      seenEpoch <- newIORef (Nothing :: Maybe Integer)
      (reviewed, registry) <- preparedFixtureWith firstStore
        (\_ _ -> do
          current <- readHead secondStore
          writeIORef seenEpoch (either (const Nothing) (>>= fmap claimEpoch . headExecutorClaim) current)
          modifyIORef' effects (+ 1)
          pure AdapterEffectCompleted)
        (\_ _ -> pure RecoverySafeToRetry)
      admitted <- withProcessLock firstStore (\lock -> fmap (fmap (const ())) (admit lock registry reviewed))
      case admitted of
        Right (Right _) -> pure ()
        other -> assertFailure (show other)
      claimed <- readHead firstStore >>= either (assertFailure . show) pure
        >>= maybe (assertFailure "head missing" >> error "unreachable") pure
      token <- maybe (assertFailure "transaction missing" >> error "unreachable") pure (headActiveTransaction claimed)
      transaction <- either (assertFailure . T.unpack) pure (mkTransactionId token)
      refused <- resumeTransaction secondStore registry transaction
      assertBool "foreign client must refuse without takeover" (isLeft refused)
      readIORef effects >>= (@?= 0)
      resumed <- resumeTransactionWithTakeover secondStore registry transaction True
        >>= either (assertFailure . show) pure
      resumed @?= Converged transaction
      readIORef effects >>= (@?= 1)
      readIORef seenEpoch >>= (@?= Just 2)
  , testCase "superseded executor stops before its next effect" $ do
      ops <- fakeObjectOps
      firstStore <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
      secondStore <- newObjectStore ops fixtureBinding "client-b" Nothing >>= either (assertFailure . show) pure
      effects <- newIORef (0 :: Int)
      let executeOnce _ _ = modifyIORef' effects (+ 1) >> pure AdapterEffectCompleted
          takeover _ _ = do
            observed <- readHead secondStore
            case observed of
              Right (Just current) | Just transaction <- headActiveTransaction current -> do
                let replacement = current
                      { headGeneration = headGeneration current + 1
                      , headExecutorClaim = Just (ExecutorClaim transaction "client-b" 2 "takeover")
                      }
                replaced <- replaceHeadIfGenerationMatches secondStore
                  (Just (headGeneration current)) replacement
                pure (either (Left . T.pack . show) (const (Right ())) replaced)
              _ -> pure (Right ())
      (reviewed, _) <- preparedFixtureWith firstStore executeOnce
        (\_ _ -> pure RecoverySafeToRetry)
      let registry = recordingRegistryWith takeover executeOnce
            (\_ _ -> pure RecoverySafeToRetry)
      outcome <- applyReviewed firstStore registry reviewed >>= either (assertFailure . show) pure
      case outcome of
        StoppedAmbiguous _ _ -> pure ()
        other -> assertFailure ("superseded executor continued: " <> show other)
      readIORef effects >>= (@?= 0)
  , testCase "a listing failure cannot look like an empty review catalogue" $ do
      ops <- fakeObjectOps
      store <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
      let known = either (error . T.unpack) id
          binding = ContextBinding (known (mkContextId "object-test")) (known (mkName "project"))
      _ <- initializeStore store binding "client-a" >>= either (assertFailure . show) pure
      unreadable <- newObjectStore (ops {listObjects = \_ -> pure (Left "listing denied")}) fixtureBinding "client-b" Nothing
        >>= either (assertFailure . show) pure
      snapshot <- readStoreSnapshot unreadable
      assertBool "failed listing must stop snapshot loading" (isLeft snapshot)
  , testCase "one object prefix refuses another context binding" $ do
      ops <- fakeObjectOps
      _ <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
      let known = either (error . T.unpack) id
          foreignBinding = ContextBinding (known (mkContextId "other-context")) (known (mkName "project"))
      foreignResult <- newObjectStore ops foreignBinding "client-b" Nothing
      assertBool "format binding mismatch must refuse" (isLeft foreignResult)
  , testCase "read-only open refuses an uninitialized prefix without creating it" $ do
      ops <- fakeObjectOps
      unopened <- openObjectStoreReadOnly ops fixtureBinding "viewer" Nothing
      assertBool "status cannot create format" (isLeft unopened)
      getObject ops (ObjectName "format.json") >>= (@?= ObjectAbsent)
  , testCase "migration verifies the copy, tombstones the source, and resumes safely" $ do
      sourceOps <- fakeObjectOps
      destinationOps <- fakeObjectOps
      source <- newObjectStore sourceOps fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      destination <- newObjectStore destinationOps fixtureBinding "client-b" Nothing
        >>= either (assertFailure . show) pure
      original <- initializeStore source fixtureBinding "client-a"
        >>= either (assertFailure . show) pure
      _ <- publishIfAbsent source "objects/sample.json" "sample"
        >>= either (assertFailure . show) pure
      migrateStore source destination "local" "gs://state/inventory" >>= (@?= Right ())
      migrated <- readHead source >>= either (assertFailure . show) pure
      assertBool "source has a migration marker" (maybe False (isJust . headMigration) migrated)
      readHead destination >>= (@?= Right (Just original))
      publishIfAbsent source "objects/late.json" "late" >>= \result ->
        assertBool "source refuses late writes" (isLeft result)
      migrateStore source destination "local" "gs://state/inventory" >>= (@?= Right ())
      readObject destination "objects/sample.json" >>= (@?= Right (Just "sample"))
      migrateStore destination source "gs://state/inventory" "local" >>= (@?= Right ())
      readHead source >>= (@?= Right (Just original))
      reverseHead <- readHead destination >>= either (assertFailure . show) pure
      assertBool "remote source tombstoned after reverse migration"
        (maybe False (isJust . headMigration) reverseHead)
  , testCase "migration resumes after a failed destination-head write" $ do
      sourceOps <- fakeObjectOps
      baseDestinationOps <- fakeObjectOps
      failHead <- newIORef True
      let destinationOps = baseDestinationOps
            { putObject = \condition name bytes -> do
                failNow <- if name == ObjectName "head.json"
                  then atomicModifyIORef' failHead (\pending -> (False, pending))
                  else pure False
                if failNow
                  then pure (PutUnknown "injected head write failure")
                  else putObject baseDestinationOps condition name bytes
            }
      source <- newObjectStore sourceOps fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      destination <- newObjectStore destinationOps fixtureBinding "client-b" Nothing
        >>= either (assertFailure . show) pure
      _ <- initializeStore source fixtureBinding "client-a" >>= either (assertFailure . show) pure
      _ <- publishIfAbsent source "objects/sample.json" "sample"
        >>= either (assertFailure . show) pure
      firstAttempt <- migrateStore source destination "local" "gs://state/inventory"
      assertBool "failed head write must stop migration" (isLeft firstAttempt)
      before <- readHead source >>= either (assertFailure . show) pure
      assertBool "source remains writable before tombstone" (maybe False (not . isJust . headMigration) before)
      migrateStore source destination "local" "gs://state/inventory" >>= (@?= Right ())
      afterHead <- readHead source >>= either (assertFailure . show) pure
      assertBool "source tombstoned after successful retry" (maybe False (isJust . headMigration) afterHead)
  , testCase "migration never opens destination while source remains writable" $ do
      sourceOps <- fakeObjectOps
      baseDestinationOps <- fakeObjectOps
      staged <- newIORef False
      let destinationOps = baseDestinationOps
            { putObject = \condition name bytes -> do
                result <- putObject baseDestinationOps condition name bytes
                when (name == ObjectName "head.json" && case result of PutWritten _ -> True; _ -> False)
                  (writeIORef staged True)
                pure result
            }
      source <- newObjectStore sourceOps fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      destination <- newObjectStore destinationOps fixtureBinding "client-b" Nothing
        >>= either (assertFailure . show) pure
      _ <- initializeStore source fixtureBinding "client-a" >>= either (assertFailure . show) pure
      _ <- publishIfAbsent source "objects/sample.json" "sample"
        >>= either (assertFailure . show) pure
      let interruptingSourceOps = sourceOps
            { putObject = \condition name bytes -> do
                interrupt <- readIORef staged
                if interrupt && name == ObjectName "head.json"
                  then pure (PutUnknown "injected source tombstone failure")
                  else putObject sourceOps condition name bytes
            }
      interrupted <- newObjectStore interruptingSourceOps fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      migrateStore interrupted destination "local" "gs://state/inventory" >>= \result ->
        assertBool "source tombstone failure stops migration" (isLeft result)
      readHead destination >>= \result ->
        assertBool "destination remains staged" (maybe False (isJust . headMigration) (either (const Nothing) id result))
      publishIfAbsent destination "objects/late.json" "late" >>= \result ->
        assertBool "staged destination refuses writes" (isLeft result)
      publishIfAbsent source "objects/late.json" "late" >>= \result ->
        assertBool "source remains writable" (not (isLeft result))
  , testCase "migration resumes after source tombstone but before destination activation" $ do
      sourceOps <- fakeObjectOps
      baseDestinationOps <- fakeObjectOps
      headWrites <- newIORef (0 :: Int)
      let destinationOps = baseDestinationOps
            { putObject = \condition name bytes -> do
                count <- if name == ObjectName "head.json"
                  then atomicModifyIORef' headWrites (\value -> let next = value + 1 in (next, next))
                  else pure 0
                if count == 2 then pure (PutUnknown "injected activation failure")
                  else putObject baseDestinationOps condition name bytes
            }
      source <- newObjectStore sourceOps fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      destination <- newObjectStore destinationOps fixtureBinding "client-b" Nothing
        >>= either (assertFailure . show) pure
      original <- initializeStore source fixtureBinding "client-a"
        >>= either (assertFailure . show) pure
      _ <- publishIfAbsent source "objects/sample.json" "sample"
        >>= either (assertFailure . show) pure
      migrateStore source destination "local" "gs://state/inventory" >>= \result ->
        assertBool "activation failure leaves a resumable handoff" (isLeft result)
      sourceHead <- readHead source >>= either (assertFailure . show) pure
      destinationHead <- readHead destination >>= either (assertFailure . show) pure
      assertBool "source tombstoned" (maybe False (isJust . headMigration) sourceHead)
      assertBool "destination remains staged" (maybe False (isJust . headMigration) destinationHead)
      migrateStore source destination "local" "gs://state/inventory" >>= (@?= Right ())
      readHead destination >>= (@?= Right (Just original))
  , testCase "migration refuses an unresolved source transaction" $ do
      sourceOps <- fakeObjectOps
      destinationOps <- fakeObjectOps
      source <- newObjectStore sourceOps fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      destination <- newObjectStore destinationOps fixtureBinding "client-b" Nothing
        >>= either (assertFailure . show) pure
      initial <- initializeStore source fixtureBinding "client-a" >>= either (assertFailure . show) pure
      replaceHeadIfGenerationMatches source (Just 0)
        (initial {headGeneration = 1, headActiveTransaction = Just "tx-unresolved"})
        >>= (@?= Right ())
      attempt <- migrateStore source destination "local" "gs://state/inventory"
      assertBool "active transaction must stop migration" (isLeft attempt)
      readHead destination >>= (@?= Right Nothing)
  , testCase "poisoned immutable cache is refetched and repaired" $
      withSystemTempDirectory "inventory-object-cache" $ \cacheRoot -> do
        ops <- fakeObjectOps
        store <- newObjectStore ops fixtureBinding "client-a" (Just cacheRoot)
          >>= either (assertFailure . show) pure
        let bytes = "immutable member"
            digest = contentDigest bytes
            key = objectKeyFor "objects" digest
            cached = cacheRoot </> T.unpack (digestText digest)
        _ <- publishIfAbsent store key bytes >>= either (assertFailure . show) pure
        readObject store key >>= (@?= Right (Just bytes))
        BS.writeFile cached "poisoned"
        setFileMode cached 0o600
        readObject store key >>= (@?= Right (Just bytes))
        BS.readFile cached >>= (@?= bytes)
  , testCase "gcloud writes carry the exact generation precondition" $ do
      let prefix = "gs://context-state/nagare/demo/inventory"
          name = ObjectName "head.json"
      putArgs "/private/staged" prefix name IfAbsent @?=
        ["storage", "cp", "/private/staged", "gs://context-state/nagare/demo/inventory/head.json",
         "--if-generation-match=0", "--print-created-message", "--quiet"]
      putArgs "/private/staged" prefix name (IfGenerationMatches (Generation 31)) @?=
        ["storage", "cp", "/private/staged", "gs://context-state/nagare/demo/inventory/head.json",
         "--if-generation-match=31", "--print-created-message", "--quiet"]
      describeArgs prefix name @?=
        ["storage", "objects", "describe", "gs://context-state/nagare/demo/inventory/head.json",
         "--format=value(generation)", "--quiet"]
      listedObjectNames "nagare/demo/inventory"
        "[{\"name\":\"nagare/demo/inventory/head.json\"},{\"name\":\"nagare/demo/inventory/head.json\"},{\"name\":\"nagare/other/head.json\"}]"
        @?= Right [name]
  , testCase "read-back separates landed, conflicting, retryable, and unknown writes" $ do
      let sent = "new-head"
          previous = Generation 12
      classifyPutReadback (IfGenerationMatches previous) sent
        (ObjectFound (Generation 13) sent) @?= PutWritten (Generation 13)
      classifyPutReadback IfAbsent sent
        (ObjectFound previous "other") @?= PutPreconditionFailed
      classifyPutReadback (IfGenerationMatches previous) sent
        (ObjectFound previous "old-head") @?=
          PutNoEffect "object is unchanged after failed put"
      classifyPutReadback (IfGenerationMatches previous) sent
        (ObjectFound (Generation 13) "other") @?= PutPreconditionFailed
      classifyPutReadback IfAbsent sent ObjectAbsent @?=
        PutNoEffect "object remains absent after failed put"
      classifyPutReadback IfAbsent sent (GetUnknown "read denied") @?=
        PutUnknown "read denied"
  , testCase "a write that lands before its acknowledgement is accepted by read-back" $ do
      baseOps <- fakeObjectOps
      let ops = baseOps
            { putObject = \condition name bytes -> do
                _ <- putObject baseOps condition name bytes
                observed <- getObject baseOps name
                pure (classifyPutReadback condition bytes observed)
            }
      store <- newObjectStore ops fixtureBinding "client-a" Nothing
        >>= either (assertFailure . show) pure
      headValue <- initializeStore store fixtureBinding "client-a"
        >>= either (assertFailure . show) pure
      readHead store >>= (@?= Right (Just headValue))
  , testCase "gated real bucket passes the conditional store contract" $ do
      requestedUrl <- lookupEnv "NAGARE_TEST_INVENTORY_STORE_URL"
      requestedProject <- lookupEnv "NAGARE_TEST_EXPECTED_PROJECT"
      case (requestedUrl, requestedProject) of
        (Nothing, Nothing) -> pure ()
        (Just url, Just project) -> do
          (code, configured, _) <- readProcessWithExitCode "gcloud" ["config", "get-value", "project", "--quiet"] ""
          assertBool "gcloud must use the expected project"
            (code == ExitSuccess && T.strip (T.pack configured) == T.pack project)
          bucket <- maybe (assertFailure "test URL has no bucket" >> error "unreachable") pure
            (gcsBucketOfUrl (T.pack url))
          bucketNumber <- capture realGcloudOps (bucketProjectNumberArgs bucket)
          projectNumber <- capture realGcloudOps (projectNumberArgs (T.pack project))
          either (assertFailure . T.unpack) pure
            (bucketOwnershipVerdict bucket (T.pack project) bucketNumber projectNumber)
          nonce <- getRandomBytes 32 :: IO BS.ByteString
          let childUrl = T.pack url <> "/rehearsal-" <> digestText (contentDigest nonce)
          ops <- either (assertFailure . T.unpack) pure (gcloudObjectOps childUrl)
          store <- newObjectStore ops fixtureBinding "real-client-a" Nothing
            >>= either (assertFailure . show) pure
          exerciseStore store
        _ -> assertFailure "set both NAGARE_TEST_INVENTORY_STORE_URL and NAGARE_TEST_EXPECTED_PROJECT"
  ]

fakeObjectOps :: IO ObjectOps
fakeObjectOps = do
  state <- newIORef (0 :: Integer, Map.empty)
  pure ObjectOps
    { getObject = \name -> do
        (_, objects) <- readIORef state
        pure $ maybe ObjectAbsent (uncurry ObjectFound) (Map.lookup name objects)
    , getObjects = \(ObjectName prefix) -> do
        (_, objects) <- readIORef state
        pure (Right (Map.map snd (Map.filterWithKey (\(ObjectName name) _ -> (prefix <> "/") `T.isPrefixOf` name) objects)))
    , putObject = \condition name bytes -> atomicModifyIORef' state $ \(lastGeneration, objects) ->
        let existing = Map.lookup name objects
            matches = case condition of
              IfAbsent -> maybe True (const False) existing
              IfGenerationMatches expected -> maybe False ((== expected) . fst) existing
         in if matches then
              let next = lastGeneration + 1
                  generation = Generation next
               in ((next, Map.insert name (generation, bytes) objects), PutWritten generation)
            else ((lastGeneration, objects), PutPreconditionFailed)
    , listObjects = \(ObjectName prefix) -> do
        (_, objects) <- readIORef state
        pure (Right [name | name@(ObjectName value) <- Map.keys objects,
                     prefix `T.isPrefixOf` value])
    }
