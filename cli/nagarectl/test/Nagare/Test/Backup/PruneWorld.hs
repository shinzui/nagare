-- | EP-183 M2 (ADR 25, ADR 26): the scheduled prune and its recovery Job run
-- against a stateful bucket world, with a fault at every tool call. Whatever
-- the prune left, the recovery Job finishes exactly the reviewed deletion:
-- both keys end with no live object, a receipt never outlives its live
-- archive, and nothing else in the bucket changes.
module Nagare.Test.Backup.PruneWorld
  ( pruneWorldTests
  )
where

import Control.Monad (forM, forM_, when)
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Database.Prune (PruneJobInputs (PruneJobInputs), scheduledPruneShell, scheduledReceiptRecoveryShell)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Inventory.ScheduledGcs (parseGcsObjectGenerations)
import Nagare.Inventory.ScheduledPrune (StoppedPrune (..), classifyStoppedPrune, notYetIngestedRuns, scheduledPruneProviderMatches)
import Nagare.Inventory.ScheduledStore (ListedObject (..))
import Nagare.Resource.Canonical (contentDigest)
import Nagare.Resource.Types (digestText)
import Nagare.Test.DataFixtures (localMinioBackend)
import Nagare.Test.World.Bucket
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

pruneWorldTests :: [TestTree]
pruneWorldTests =
  [ testCase "a GCS scheduled prune interrupted at every call is finished by its recovery Job, generation-pinned" (everyFault gcs)
  , testCase "a MinIO scheduled prune interrupted at every call is finished by its recovery Job, version-pinned" (everyFault minio)
  , testCase "a GCS recovery Job refuses a reuploaded live generation and a changed receipt" (refusals gcs)
  , testCase "a MinIO recovery Job refuses a reuploaded live version and a changed receipt" (refusals minio)
  , testCase "recovery planning accepts only the states a stopped prune leaves" stoppedStates
  , testCase "a saved prune's apply preflight needs the accepted listing and both reviewed versions" providerPreflight
  , testCase "a GCS listing yields each live object's generation and refuses an escape or a repeat" gcsGenerations
  , testCase "a run uploaded between planning and apply does not refuse the prune; an older un-ingested run does" uploadedMeanwhile
  ]

knownRuns :: Set.Set Text
knownRuns = Set.fromList [runOf dataKey, runOf otherKey]

runOf :: Text -> Text
runOf key = T.takeWhile (/= '.') (T.drop (T.length "databases/mydb/") key)

-- | EP-183 M2 (decided 2026-10-10): the producer keeps uploading while an
-- operator ingests and prunes. A run no accepted scope names is tolerated,
-- never a candidate, only while it is strictly newer than every accepted run.
uploadedMeanwhile :: Assertion
uploadedMeanwhile = do
  let at hour key = ListedObject key (UTCTime (fromGregorian 2026 10 10) (hour * 3600))
      accepted = [at 1 dataKey, at 1 receiptKey, at 2 otherKey, at 2 (otherKey <> ".receipt.json")]
      expected = Set.fromList (map listedKey accepted)
      newer = "databases/mydb/33333333-3333-3333-3333-333333333333.sql.gz"
      older = "databases/mydb/44444444-4444-4444-4444-444444444444.sql.gz"
      tolerate = notYetIngestedRuns "databases/mydb/" "sql.gz" knownRuns expected
      archiveAt = (dataKey, "7")
      receiptAt = (receiptKey, "9")
      preflight listed = scheduledPruneProviderMatches "databases/mydb/" "sql.gz" knownRuns (Set.toList expected) listed archiveAt receiptAt [archiveAt, receiptAt]
  tolerate accepted @?= Right []
  -- A complete newer run, and one whose receipt is still uploading.
  tolerate (accepted <> [at 3 newer, at 3 (newer <> ".receipt.json")]) @?= Right [runOf newer]
  tolerate (accepted <> [at 3 newer]) @?= Right [runOf newer]
  preflight (accepted <> [at 3 newer, at 3 (newer <> ".receipt.json")]) @?= Right ()
  -- Not newer than the newest accepted run: ingest it first.
  assertBool "an older un-ingested run was tolerated" (isLeft (tolerate (accepted <> [at 0 older, at 0 (older <> ".receipt.json")])))
  assertBool "an un-ingested run as old as the newest accepted one was tolerated" (isLeft (tolerate (accepted <> [at 2 older])))
  assertBool "the preflight tolerated an older un-ingested run" (isLeft (preflight (accepted <> [at 0 older])))
  -- An accepted run's key listed again, or a key that is no run, refuses.
  assertBool "an accepted run's extra key was tolerated" (isLeft (tolerate (accepted <> [at 3 (dataKey <> ".extra")])))
  assertBool "a stray key was tolerated" (isLeft (tolerate (accepted <> [at 3 "databases/mydb/stray"])))
  assertBool "a missing accepted key was tolerated" (isLeft (tolerate (drop 1 accepted)))

stoppedStates :: Assertion
stoppedStates = do
  let archiveAt = (dataKey, "7")
      receiptAt = (receiptKey, "9")
      classify = classifyStoppedPrune archiveAt receiptAt
  classify [archiveAt, receiptAt] @?= Right BothRemain
  classify [receiptAt] @?= Right ReceiptRemains
  forM_
    [ []
    , [archiveAt]
    , [(dataKey, "8"), receiptAt]
    , [archiveAt, receiptAt, (otherKey, "3")]
    , [receiptAt, receiptAt]
    ]
    $ \versions -> assertBool ("accepted " <> show versions) (isLeft (classify versions))

providerPreflight :: Assertion
providerPreflight = do
  let listedAt keys = [ListedObject key (UTCTime (fromGregorian 2026 10 10) 0) | key <- keys]
      expected = [dataKey, receiptKey, otherKey]
      check = scheduledPruneProviderMatches "databases/mydb/" "sql.gz" knownRuns expected
      archiveAt = (dataKey, "7")
      receiptAt = (receiptKey, "9")
  check (listedAt expected) archiveAt receiptAt [archiveAt, receiptAt] @?= Right ()
  assertBool "an unaccepted upload passed" (isLeft (check (listedAt (expected <> ["databases/mydb/new.sql.gz"])) archiveAt receiptAt [archiveAt, receiptAt]))
  assertBool "a changed generation passed" (isLeft (check (listedAt expected) archiveAt receiptAt [(dataKey, "8"), receiptAt]))
  assertBool "a missing receipt passed" (isLeft (check (listedAt expected) archiveAt receiptAt [archiveAt]))

gcsGenerations :: Assertion
gcsGenerations = do
  let entry name generation = "{\"bucket\":\"backups\",\"name\":\"" <> name <> "\",\"generation\":\"" <> generation <> "\",\"size\":\"12\",\"updated\":\"2026-10-10T00:00:00Z\"}"
      listing entries = TE.encodeUtf8 ("[" <> T.intercalate "," entries <> "]")
  parseGcsObjectGenerations "backups" "databases/mydb/" (listing [entry dataKey "7", entry receiptKey "9"])
    @?= Right [(dataKey, "7"), (receiptKey, "9")]
  assertBool "an escaped name passed" (isLeft (parseGcsObjectGenerations "backups" "databases/mydb/" (listing [entry "databases/other/x" "7"])))
  assertBool "a repeated name passed" (isLeft (parseGcsObjectGenerations "backups" "databases/mydb/" (listing [entry dataKey "7", entry dataKey "8"])))
  assertBool "another bucket passed" (isLeft (parseGcsObjectGenerations "elsewhere" "databases/mydb/" (listing [entry dataKey "7"])))

-- | One backend's view of the world.
data Backend = Backend
  { label :: !String
  , store :: !StoreBackend
  , scheme :: !Text
  , objectVersion :: !Text
  , receiptVersion :: !Text
  , keepsNoncurrent :: !Bool
  -- ^ Whether a deleted version stays as a noncurrent one.
  }

gcs, minio :: Backend
gcs = Backend "GCS" (GcsBackend "project" "backups") "gs://backups/" "7" "9" True
minio = Backend "MinIO" localMinioBackend "s3://nagare-backups/" "v-object" "v-receipt" False

dataKey, receiptKey, otherKey :: Text
dataKey = "databases/mydb/11111111-1111-1111-1111-111111111111.sql.gz"
receiptKey = dataKey <> ".receipt.json"
otherKey = "databases/mydb/22222222-2222-2222-2222-222222222222.sql.gz"

archive, receipt :: Text
archive = "archive bytes"
receipt = "receipt bytes"

sha :: Text -> Text
sha = digestText . contentDigest . TE.encodeUtf8

initial :: Backend -> BucketState
initial backend =
  BucketState
    0
    Nothing
    ( Map.fromList
        [ (dataKey, [BucketVersion (objectVersion backend) archive True])
        , (receiptKey, [BucketVersion (receiptVersion backend) receipt True])
        , (otherKey, [BucketVersion "3" "another run" True])
        ]
    )

inputs :: Backend -> PruneJobInputs
inputs backend =
  PruneJobInputs "personal" "nagare-schedprune-test" (scheme backend <> dataKey) (scheme backend <> receiptKey) (sha archive) (sha receipt) 0 (store backend)

-- | Run one shell in the world, with an optional fault.
runShell :: FilePath -> Backend -> Text -> Maybe BucketFault -> IO ExitCode
runShell directory backend script selected = do
  current <- readBucketState directory
  writeBucketState directory current {calls = 0, fault = selected}
  parentEnv <- getEnvironment
  let path = maybe "" id (lookup "PATH" parentEnv)
      variables =
        bucketEnvironment directory path
          <> [ ("OBJECT", T.unpack (scheme backend <> dataKey))
             , ("RECEIPT", T.unpack (scheme backend <> receiptKey))
             , ("EXPECTED_OBJECT_SHA256", T.unpack (sha archive))
             , ("EXPECTED_RECEIPT_SHA256", T.unpack (sha receipt))
             , ("EXPECTED_OBJECT_VERSION", T.unpack (objectVersion backend))
             , ("EXPECTED_RECEIPT_VERSION", T.unpack (receiptVersion backend))
             , ("EXPIRY_EPOCH", "0")
             ]
  (code, _, _) <-
    readCreateProcessWithExitCode
      ((proc "/bin/sh" ["-c", T.unpack script]) {env = Just (variables <> filter ((`notElem` map fst variables) . fst) parentEnv)})
      ""
  pure code

liveVersion :: BucketState -> Text -> Maybe Text
liveVersion state key = case [v | v <- Map.findWithDefault [] key (objects state), live v] of
  [] -> Nothing
  found -> Just (version (last found))

-- | Neither reviewed key is live, the reviewed versions are kept as
-- noncurrent exactly where the backend keeps them, and the other run is
-- untouched.
converged :: Backend -> BucketState -> Assertion
converged backend state = do
  liveVersion state dataKey @?= Nothing
  liveVersion state receiptKey @?= Nothing
  Map.lookup otherKey (objects state) @?= Just [BucketVersion "3" "another run" True]
  let kept key = map version (Map.findWithDefault [] key (objects state))
  kept dataKey @?= [objectVersion backend | keepsNoncurrent backend]
  kept receiptKey @?= [receiptVersion backend | keepsNoncurrent backend]

everyFault :: Backend -> Assertion
everyFault backend = withSystemTempDirectory "nagare-prune-world" $ \directory -> do
  installBucketTools directory
  writeBucketState directory (initial backend)
  clean <- runShell directory backend (scheduledPruneShell (inputs backend)) Nothing
  clean @?= ExitSuccess
  readBucketState directory >>= converged backend
  total <- calls <$> readBucketState directory
  assertBool "the clean prune made no tool call" (total > 0)
  -- Every place the prune can stop, and the distinct states it leaves.
  stops <- forM [BucketFault n selected | n <- [1 .. total], selected <- [minBound .. maxBound]] $ \selected -> do
    let context = label backend <> " fault " <> show selected
    writeBucketState directory (initial backend)
    stopped <- runShell directory backend (scheduledPruneShell (inputs backend)) (Just selected)
    left <- readBucketState directory
    -- A lost acknowledgement of a read whose bytes the hash then verifies
    -- may still succeed; success must mean the deletion is complete.
    when (stopped == ExitSuccess) (converged backend left)
    assertBool
      (context <> ": the receipt went before its archive")
      (not (isJust (liveVersion left dataKey) && isNothing (liveVersion left receiptKey)))
    pure (objects left)
  forM_ (Map.keys (Map.fromList [(state, ()) | state <- stops])) $ \left -> do
    let start = (initial backend) {objects = left}
    -- The recovery Job may itself be interrupted at any call; run it again.
    writeBucketState directory start
    _ <- runShell directory backend (scheduledReceiptRecoveryShell (inputs backend)) Nothing
    readBucketState directory >>= converged backend
    recoveryCalls <- calls <$> readBucketState directory
    forM_ [BucketFault m selected | m <- [1 .. recoveryCalls], selected <- [minBound .. maxBound]] $ \second -> do
      writeBucketState directory start
      _ <- runShell directory backend (scheduledReceiptRecoveryShell (inputs backend)) (Just second)
      interrupted <- readBucketState directory
      assertBool
        (label backend <> " recovery fault " <> show second <> ": the receipt went before its archive")
        (not (isJust (liveVersion interrupted dataKey) && isNothing (liveVersion interrupted receiptKey)))
      finished <- runShell directory backend (scheduledReceiptRecoveryShell (inputs backend)) Nothing
      assertBool (label backend <> " recovery fault " <> show second <> ": recovery did not finish") (finished == ExitSuccess)
      readBucketState directory >>= converged backend
    -- Recovery after convergence changes nothing.
    again <- runShell directory backend (scheduledReceiptRecoveryShell (inputs backend)) Nothing
    again @?= ExitSuccess
    readBucketState directory >>= converged backend
  -- The states the prune leaves are exactly: untouched, archive gone, both gone.
  length (Map.keys (Map.fromList [(state, ()) | state <- stops])) @?= 3

refusals :: Backend -> Assertion
refusals backend = withSystemTempDirectory "nagare-prune-world" $ \directory -> do
  installBucketTools directory
  -- A run re-uploaded at the archive key is not the reviewed version.
  let reuploaded =
        (initial backend)
          { objects =
              Map.insert dataKey [BucketVersion "8" "a reuploaded upload" True] (objects (initial backend))
          }
  writeBucketState directory reuploaded
  refused <- runShell directory backend (scheduledReceiptRecoveryShell (inputs backend)) Nothing
  assertBool "a reuploaded live version was recovered" (refused /= ExitSuccess)
  after <- readBucketState directory
  objects after @?= objects reuploaded
  -- The same bytes uploaded again are still another version: only the pin
  -- refuses them, since the hash matches.
  let identical =
        (initial backend)
          { objects =
              Map.insert dataKey [BucketVersion (objectVersion backend) archive False, BucketVersion "8" archive True] (objects (initial backend))
          }
  writeBucketState directory identical
  refusedIdentical <- runShell directory backend (scheduledReceiptRecoveryShell (inputs backend)) Nothing
  assertBool "an identical re-upload at another version was recovered" (refusedIdentical /= ExitSuccess)
  identicalAfter <- readBucketState directory
  objects identicalAfter @?= objects identical
  -- A receipt whose bytes changed is left in place, after the reviewed
  -- archive is gone.
  let changed =
        (initial backend)
          { objects =
              Map.insert receiptKey [BucketVersion (receiptVersion backend) "rewritten receipt" True] (objects (initial backend))
          }
  writeBucketState directory changed
  refusedReceipt <- runShell directory backend (scheduledReceiptRecoveryShell (inputs backend)) Nothing
  assertBool "a changed receipt was deleted" (refusedReceipt /= ExitSuccess)
  left <- readBucketState directory
  liveVersion left dataKey @?= Nothing
  liveVersion left receiptKey @?= Just (receiptVersion backend)
