-- | EP-212: a store counts what a command does to it, and admission decides
-- from a history of the head it holds under the writer lock.
module InventoryStoreOnceSpec (inventoryStoreOnceTests) where

import Control.Monad (forM_, replicateM_)
import InventoryTransactionSpec (fixtureBinding, preparedFixtureWith)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Counters
import Nagare.Test.World.ObjectStore (fakeObjectOps)
import System.IO.Temp (withSystemTempDirectory)
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
          _ <- publishIfAbsent store (scopeKey (contentDigest fresh)) fresh >>= either (assertFailure . show) pure
          counts <- snapshotCounters (storeCounters store)
          -- Remote gets: format.json at open, the head, the miss, and the
          -- publication's head check and existence read.
          map (`countOf` counts) [StoreOpen, HeadRead, HistoryLoad, RemoteGet, CachedGet, RemotePut, Listing]
            @?= [1, 1, 0, 5, 1, 1, 0]
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
    ]
