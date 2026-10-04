module InventoryStoreBackupSpec (inventoryStoreBackupTests) where

import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store
import Nagare.Resource.Types
import System.Directory (removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

inventoryStoreBackupTests :: ContextBinding -> TestTree
inventoryStoreBackupTests fixtureBinding =
  testCase "complete backup restores and incomplete backup is refused" $
    withSystemTempDirectory "inventory-backup" $ \root -> do
      source <- openFilesystemStore (root </> "source") >>= expectRight
      _ <- initializeStore source fixtureBinding "client-test" >>= expectRight
      _ <- publishIfAbsent source (objectKeyFor "objects" (contentDigest "retained")) "retained" >>= expectRight
      let receipts = [("image-prune/completed.json", "original-image-proof"), ("vm-power/completed.json", "original-power-proof"), ("cdn-purge/completed.json", "original-purge-proof")]
      forM_ receipts $ \(key, bytes) -> void (publishIfAbsent source key bytes >>= expectRight)
      let backup = root </> "backup"
      exported <- withProcessLock source (\locked -> exportStore locked backup) >>= expectRight
      _ <- expectRight exported
      restored <- newMemoryStore
      readHead restored >>= (@?= Right Nothing)
      let wrongBinding = ContextBinding (ok (mkContextId "different")) (ok (mkName "project"))
      refusedBinding <- restoreStoreFor restored backup wrongBinding
      assertBool "restore wrote a different context" (isLeft refusedBinding)
      readHead restored >>= (@?= Right Nothing)
      _ <- restoreStoreFor restored backup fixtureBinding >>= expectRight
      readHead restored >>= expectRight >>= (@?= Just (HeadManifest 1 0 0 fixtureBinding "client-test" Map.empty Map.empty Map.empty Map.empty Nothing Nothing Nothing Nothing Map.empty))
      forM_ receipts $ \(key, bytes) -> readObject restored key >>= (@?= Right (Just bytes))
      removeFile (backup </> "head.json")
      incomplete <- newMemoryStore
      refused <- restoreStore incomplete backup
      assertBool "missing backup member refused" (isLeft refused)

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> error "unreachable") pure
