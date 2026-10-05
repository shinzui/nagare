-- | F61: the PostgreSQL rename's transfer script, run for real with its volume
-- and termination-log paths pointed at temporary directories. The rename
-- world ('InventoryPostgresRenameSpec') models these outcomes; this checks the
-- script agrees with it.
module InventoryTransferScriptSpec (inventoryTransferScriptTests) where

import Control.Monad (forM, forM_)
import Data.List (sort)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Migration.PostgresRename (transferScript)
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

inventoryTransferScriptTests :: TestTree
inventoryTransferScriptTests =
  testGroup
    "rename transfer script (F61)"
    [ testCase "a copy into an empty destination copies and clears its mark" $
        withVolumes [] $ \root -> do
          (code, message) <- transfer root "copy"
          code @?= ExitSuccess
          assertBool ("unexpected result: " <> T.unpack message) ("\"source\"" `T.isInfixOf` message)
          contents (root </> "destination") >>= (@?= sourceFiles)
    , testCase "a copy redoes a destination an interrupted copy left marked" $
        withVolumes [(".nagare-transfer-incomplete", ""), ("PG_VERSION", "18"), ("stale", "partial")] $ \root -> do
          (code, message) <- transfer root "copy"
          code @?= ExitSuccess
          assertBool ("unexpected result: " <> T.unpack message) ("\"source\"" `T.isInfixOf` message)
          contents (root </> "destination") >>= (@?= sourceFiles)
    , testCase "a copy refuses an unmarked destination that differs from the source" $
        withVolumes [("other", "foreign data")] $ \root -> do
          (code, message) <- transfer root "copy"
          code @?= ExitFailure 1
          assertBool ("unexpected refusal: " <> T.unpack message) ("not empty and differs" `T.isInfixOf` message)
          contents (root </> "destination") >>= (@?= [("other", "foreign data")])
    , testCase "verification refuses a destination that is still marked incomplete" $
        withVolumes ((".nagare-transfer-incomplete", "") : sourceFiles) $ \root -> do
          (code, message) <- transfer root "verify"
          code @?= ExitFailure 1
          assertBool ("unexpected refusal: " <> T.unpack message) ("differs from the source" `T.isInfixOf` message)
    ]

sourceFiles :: [(FilePath, String)]
sourceFiles = [("PG_VERSION", "18"), ("base", "known-row-1")]

-- | A source volume with 'sourceFiles' and a destination with the given files.
withVolumes :: [(FilePath, String)] -> (FilePath -> IO a) -> IO a
withVolumes destination action = withSystemTempDirectory "transfer-script" $ \root -> do
  createDirectoryIfMissing True (root </> "source")
  createDirectoryIfMissing True (root </> "destination")
  forM_ sourceFiles $ \(name, body) -> writeFile (root </> "source" </> name) body
  forM_ destination $ \(name, body) -> writeFile (root </> "destination" </> name) body
  action root

transfer :: FilePath -> String -> IO (ExitCode, Text)
transfer root mode = do
  environment <- getEnvironment
  let script =
        T.unpack
          ( T.replace "/migration/source" (T.pack (root </> "source"))
              . T.replace "/migration/destination" (T.pack (root </> "destination"))
              . T.replace "/dev/termination-log" (T.pack (root </> "termination-log"))
              $ transferScript
          )
  (code, _, _) <- readCreateProcessWithExitCode ((proc "bash" ["-c", script]) {env = Just (("MODE", mode) : environment)}) ""
  logged <- doesFileExist (root </> "termination-log")
  message <- if logged then T.pack <$> readFile (root </> "termination-log") else pure ""
  pure (code, message)

contents :: FilePath -> IO [(FilePath, String)]
contents directory = do
  names <- sort <$> listDirectory directory
  forM names $ \name -> (name,) <$> readFile (directory </> name)
