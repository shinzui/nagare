-- | EP-212: a store counts what a command does to it, and admission decides
-- from a history of the head it holds under the writer lock. EP-217: a
-- command serves the journal it cached and fetches only the new tail.
module InventoryStoreOnceSpec (inventoryStoreOnceTests) where

import Control.Monad (forM_, replicateM_)
import Data.ByteString qualified as BS
import Data.Either (isLeft, isRight)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import InventoryTransactionSpec (fixtureBinding, preparedFixtureWith)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Counters
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types (digestText)
import Nagare.Test.World.ObjectStore (fakeObjectOps)
import System.FilePath (takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Tasty
import Test.Tasty.HUnit

inventoryStoreOnceTests :: TestTree
inventoryStoreOnceTests =
  testGroup
    "inventory store opened once (EP-212)"
    [ testCase "a store counts its open, head reads, cached and remote gets and puts" $
        withSystemTempDirectory "inventory-counters" $ \cache -> do
          base <- fakeObjectOps
          writer <- newObjectStore base fixtureBinding "client-a" (Just cache) >>= either (assertFailure . show) pure
          _ <- initializeStore writer fixtureBinding "client-a" >>= either (assertFailure . show) pure
          let member = "counted member"
              fresh = "fresh member"
          _ <- publishIfAbsent writer (scopeKey (contentDigest member)) member >>= either (assertFailure . show) pure
          store <- newObjectStore base fixtureBinding "client-a" (Just cache) >>= either (assertFailure . show) pure
          _ <- readHead store >>= either (assertFailure . show) pure
          -- The first read misses the cache and fills it; the second is local.
          replicateM_ 2 (readObject store (scopeKey (contentDigest member)) >>= (@?= Right (Just member)))
          -- A member already in the verified cache is published without a write.
          _ <- publishIfAbsent store (scopeKey (contentDigest member)) member >>= either (assertFailure . show) pure
          _ <- publishIfAbsent store (scopeKey (contentDigest fresh)) fresh >>= either (assertFailure . show) pure
          counts <- snapshotCounters (storeCounters store)
          -- Remote gets: format.json at open, the head, the miss, and the new
          -- object's head check; it is created without a read first
          -- (EP-213), and a cached one costs no remote call at all.
          map (`countOf` counts) [StoreOpen, HeadRead, HistoryLoad, RemoteGet, CachedGet, RemotePut, Listing]
            @?= [1, 1, 0, 4, 2, 1, 0]
    , testCase "admission reuses a pinned history only under the head it was loaded from" $
        forM_ [(False, 0), (True, 1)] $ \(otherHead, admissionLoads) -> do
          store <- newMemoryStore
          (reviewed, registry) <-
            preparedFixtureWith store (\_ _ -> pure AdapterEffectCompleted) (\_ _ -> pure RecoverySafeToRetry)
          pinned <- loadInventoryHistory store >>= either (assertFailure . show) pure
          let given
                | otherHead = pinned {historyHead = (historyHead pinned) {headGeneration = 0}}
                | otherwise = pinned
          before <- countOf HistoryLoad <$> snapshotCounters (storeCounters store)
          result <- applyReviewedWithHistory store registry reviewed (Just given) >>= either (assertFailure . show) pure
          after <- countOf HistoryLoad <$> snapshotCounters (storeCounters store)
          case result of
            Converged _ -> pure ()
            other -> assertFailure (show other)
          (otherHead, after - before) @?= (otherHead, admissionLoads)
    , testCase "a cached journal is anchored by one read and only its new tail is fetched (EP-217)" $
        withSystemTempDirectory "journal-cache" $ \cache -> do
          base <- fakeObjectOps
          writer <- newObjectStore base fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
          let events = chainedEvents 503
              append (sequenceNumber, event) = appendAtSequence writer sequenceNumber (encodeJournalEvent event) >>= either (assertFailure . show) pure
          mapM_ append (zip [0 ..] (take 500 events))
          batches <- newIORef (0 :: Int)
          singles <- newIORef (0 :: Int)
          let counting =
                base
                  { getObjects = \name -> modifyIORef' batches (+ 1) >> getObjects base name
                  , getImmutableObject = \name -> modifyIORef' singles (+ 1) >> getImmutableObject base name
                  }
              calls = (,) <$> readIORef batches <*> readIORef singles
              reset = writeIORef batches 0 >> writeIORef singles 0
              cachedEvent sequenceNumber = cache </> "journal" </> takeFileName (journalKey sequenceNumber)
              chainChecks bytes = validateJournal =<< traverse decodeJournalEvent bytes
          reader <- newObjectStore counting fixtureBinding "client-b" (Just cache) >>= either (assertFailure . show) pure
          cold <- readJournalPrefix reader 500 >>= either (assertFailure . show) pure
          (length cold,) <$> calls >>= (@?= (500, (1, 0)))
          mapM_ append (drop 500 (zip [0 ..] events))
          reset
          warm <- readJournalPrefix reader 503 >>= either (assertFailure . show) pure
          warm @?= map encodeJournalEvent events
          -- One anchor read of the newest cached event and the three new ones.
          calls >>= (@?= (0, 4))
          -- A cached event that differs from the store fails the chain check.
          BS.writeFile (cachedEvent 200) (encodeJournalEvent ((events !! 200) {eventDetail = "rewritten"}))
          setFileMode (cachedEvent 200) 0o600
          tampered <- readJournalPrefix reader 503 >>= either (assertFailure . show) pure
          assertBool "a tampered cached event passed the chain check" (isLeft (chainChecks tampered))
          -- A newest cached event that differs from the store refills the copy.
          BS.writeFile (cachedEvent 502) "not the store's event"
          setFileMode (cachedEvent 502) 0o600
          reset
          refreshed <- readJournalPrefix reader 503 >>= either (assertFailure . show) pure
          refreshed @?= map encodeJournalEvent events
          assertBool "the refilled journal fails the chain check" (isRight (chainChecks refreshed))
          fst <$> calls >>= (@?= 1)
    ]

-- | A valid hash-chained journal of the given length.
chainedEvents :: Int -> [JournalEvent]
chainedEvents count = take count (go 0 Nothing)
  where
    transaction = either (error . T.unpack) id (mkTransactionId ("tx-" <> digestText (contentDigest "journal-cache")))
    go sequenceNumber previous =
      let event = JournalEvent 1 sequenceNumber previous transaction Nothing Pending "2026-10-22T00:00:00Z" ("event " <> T.pack (show sequenceNumber)) Nothing
       in event : go (sequenceNumber + 1) (Just (journalEventDigest event))
