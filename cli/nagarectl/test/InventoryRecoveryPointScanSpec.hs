-- | F92: doctor grades a database's recovery point from its newest verified
-- backup, verifying newest-first and stopping there, not every retained one.
module InventoryRecoveryPointScanSpec (inventoryRecoveryPointScanTests) where

import Data.IORef
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Nagare.Dsl.Prelude
import Nagare.Inventory.BackupFreshness (newestRecoveryPoint)
import Test.Tasty
import Test.Tasty.HUnit

inventoryRecoveryPointScanTests :: TestTree
inventoryRecoveryPointScanTests =
  testGroup
    "recovery point scan (F92)"
    [ testCase "the newest backup that verifies is the point, and no older one is read" $ do
        (point, read') <- scan (const True)
        point @?= Just "job-c"
        read' @?= ["job-c"]
    , testCase "an unverified newest backup is skipped for the next newest" $ do
        (point, read') <- scan (/= "job-c")
        point @?= Just "job-b"
        read' @?= ["job-c", "job-b"]
    , testCase "no verified backup is no recovery point" $ do
        (point, read') <- scan (const False)
        point @?= Nothing
        read' @?= ["job-c", "job-b", "job-a"]
    ]
  where
    -- Backup IDs are Job UIDs: their order says nothing about time.
    candidates :: [(Text, UTCTime)]
    candidates = [("job-b", minute 900), ("job-a", minute 0), ("job-c", minute 1800)]
    scan verifies = do
      verified <- newIORef []
      point <- newestRecoveryPoint candidates $ \key -> do
        modifyIORef' verified (<> [key])
        pure (if verifies key then Just key else Nothing)
      (point,) <$> readIORef verified

minute :: Integer -> UTCTime
minute seconds = addUTCTime (fromInteger seconds) (posixSecondsToUTCTime 1791500000)
