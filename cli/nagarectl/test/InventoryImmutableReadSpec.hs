-- | EP-213: content-addressed members read through the digest cache in
-- bounded concurrent waves, over the in-memory fake transport.
module InventoryImmutableReadSpec (inventoryImmutableReadTests) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket_)
import Control.Monad (forM, forM_)
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types
import Nagare.Test.World.ObjectStore (fakeObjectOps)
import System.Directory (listDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

inventoryImmutableReadTests :: TestTree
inventoryImmutableReadTests =
  testGroup
    "inventory immutable member reads"
    [ testCase "immutable members load with at most eight reads in flight, and none from a warm cache (EP-213)" $
        withSystemTempDirectory "inventory-immutable-cache" $ \cache -> do
          base <- fakeObjectOps
          (ops, issued, highest) <- delayedImmutableReads base
          keys <- publishMembers base 100
          store <- newObjectStore ops fixtureBinding "client-a" (Just cache) >>= either (assertFailure . show) pure
          loaded <- readImmutableObjects store keys >>= either (assertFailure . show) pure
          Map.keys loaded @?= Set.toAscList (Set.fromList keys)
          readIORef issued >>= (@?= 100)
          high <- readIORef highest
          assertBool "member reads were serialized" (high > 1)
          assertBool "more than eight member reads in flight" (high <= 8)
          readImmutableObjects store keys >>= (@?= Right loaded)
          readIORef issued >>= (@?= 100)
          -- A key that names no digest is refused before any read.
          cold <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
          readImmutableObjects cold ("head.json" : keys) >>= assertBool "a mutable key was read as a member" . isLeft
          readIORef issued >>= (@?= 100)
    , testCase "one failed immutable read schedules no further read, returns no partial map, and caches nothing for its key (EP-213)" $
        withSystemTempDirectory "inventory-immutable-failure" $ \cache -> do
          base <- fakeObjectOps
          keys <- Set.toAscList . Set.fromList <$> publishMembers base 100
          issued <- newIORef (0 :: Int)
          let failing = keys !! 2
              ops =
                base
                  { getImmutableObject = \name -> do
                      atomicModifyIORef' issued (\n -> (n + 1, ()))
                      if name == ObjectName (T.pack failing)
                        then pure (ImmutableUnknown "injected: member read failed")
                        else getImmutableObject base name
                  }
          store <- newObjectStore ops fixtureBinding "client-a" (Just cache) >>= either (assertFailure . show) pure
          readImmutableObjects store keys >>= (@?= Left (StoreIoError "injected: member read failed"))
          -- The failing read's wave of eight ran; no later wave was scheduled.
          readIORef issued >>= (@?= 8)
          cached <- listDirectory cache
          length cached @?= 7
          assertBool "the failed member was cached" (maybe True ((`notElem` cached) . T.unpack . digestText) (immutableKeyDigest failing))
          let absent = scopeKey (contentDigest "never published")
          readImmutableObjects store [absent] >>= (@?= Left (StoreInvalidObject absent "immutable member is missing"))
    , testCase "every member's own result is read with at most eight in flight, a missing one among them (EP-218)" $ do
        base <- fakeObjectOps
        (ops, issued, highest) <- delayedImmutableReads base
        keys <- publishMembers base 100
        let absent = scopeKey (contentDigest "never published")
        store <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
        results <- readImmutableObjectsEach store (absent : keys)
        Map.lookup absent results @?= Just (Right Nothing)
        length [() | Right (Just _) <- Map.elems results] @?= 100
        readIORef issued >>= (@?= 101)
        high <- readIORef highest
        assertBool "native reads were serialized or exceeded eight in flight" (high > 1 && high <= 8)
    ]

-- | Publish @count@ distinct scope members directly to the transport and
-- return their keys.
publishMembers :: ObjectOps -> Int -> IO [FilePath]
publishMembers ops count =
  forM [1 .. count] $ \n -> do
    let bytes = "member-" <> BC.pack (show n)
        key = scopeKey (contentDigest bytes)
    _ <- putObject ops IfAbsent (ObjectName (T.pack key)) bytes
    pure key

-- | Immutable reads that each take 20 ms, counting the reads issued and the
-- most in flight at once.
delayedImmutableReads :: ObjectOps -> IO (ObjectOps, IORef Int, IORef Int)
delayedImmutableReads base = do
  issued <- newIORef 0
  inFlight <- newIORef (0 :: Int)
  highest <- newIORef 0
  let enter = do
        atomicModifyIORef' issued (\n -> (n + 1, ()))
        now <- atomicModifyIORef' inFlight (\n -> (n + 1, n + 1))
        atomicModifyIORef' highest (\n -> (max n now, ()))
      leave = atomicModifyIORef' inFlight (\n -> (n - 1, ()))
      delayed name = bracket_ enter leave (threadDelay 20000 >> getImmutableObject base name)
  pure (base {getImmutableObject = delayed}, issued, highest)
