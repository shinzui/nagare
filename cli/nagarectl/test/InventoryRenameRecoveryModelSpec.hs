-- | EP-173 M2: the reviewed PostgreSQL rename under the recovery model's
-- adversary. The migration adapter reaches Kubernetes only through `kubectl`,
-- so the rename runs in its own modelled API server
-- ('InventoryPostgresRenameSpec'), with one fault at each write it issues. For
-- every schedule, status never reports a renamed member as replaced (I3), the
-- stopped transaction has a supported exit (I1), the data survives, and the
-- transfer copy runs once (I4). A converged rename records each renamed
-- member as its new object or not at all, never a stale one (F52). The source
-- replaced outside review at any read of it is never copied without a
-- reviewed rebind, and the rebind then the rename is its exit (F62). A
-- migration that cannot go forward ends by abandon-migration, and a database
-- that was not renamed never keeps a fenced writer or a suspended backup
-- schedule (F81).
module InventoryRenameRecoveryModelSpec (inventoryRenameRecoveryModelTests) where

import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (sort)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import InventoryPostgresRenameSpec
  ( RenameWorld
  , Transport
  , armPartialCopy
  , dataBearing
  , databaseOwner
  , destinationCopies
  , knownRow
  , newObjectUids
  , newScope
  , planRenameIn
  , rebindMembers
  , recordOldIncarnations
  , renameRelease
  , renameVolumes
  , replaceOutOfBand
  , replacedMembers
  , replacedOldMembers
  , reviewRenamedAgain
  , seededRename
  , sourceKeys
  , sourceScheduleSuspended
  , sourceWriterFenced
  , transferJobs
  , verifyRenamedWorldWith
  )
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (AdapterRegistry)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal
import Nagare.Inventory.KubernetesTransport (KubectlRequest, KubectlResult)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Types (ResourceId, physicalIdentityText)
import Nagare.Resource.Wire (encodeCanonicalScope)
import Nagare.Test.World.Adversary (Interrupted (..))
import System.Exit (ExitCode (..))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

inventoryRenameRecoveryModelTests :: TestTree
inventoryRenameRecoveryModelTests =
  testGroup
    "rename recovery model"
    [ testCase "every single fault at every rename write has an exit and keeps the data (F52)" $ do
        clean <- runRename Nothing
        writes <- either (assertFailure . T.unpack . ("the fault-free rename violates the model: " <>)) pure clean
        assertBool "the rename issues writes" (writes > 0)
        violations <-
          fmap concat . forM ((0, PartialCopy) : [(boundary, fault) | boundary <- [1 .. writes], fault <- [RefusedWrite, LostAcknowledgement, InterruptedAfterWrite]]) $ \schedule ->
            either (: []) (const []) <$> runRename (Just schedule)
        report violations
    , -- EP-184: the source reads are split into shards that tasty runs on
      -- separate cores. The first case proves the shards cover every read
      -- exactly once, so the split exercises the same schedules as one case.
      testGroup
        "a source replaced outside review at any read of it is never copied unreviewed, and rebind then rename is its exit (F62)"
        ( testCase
            "the shards cover every source read exactly once"
            ( do
                sourceReads <- sourceReadCount
                assertBool "the rename reads its source" (sourceReads > 0)
                sort (concatMap (replacedSourceShard sourceReads) [0 .. replacedSourceShards - 1]) @?= replacedSourceSchedules sourceReads
            )
            : [testCase ("source reads " <> show shard <> " of " <> show replacedSourceShards) (replacedSourceAtEveryRead shard) | shard <- [0 .. replacedSourceShards - 1]]
        )
    ]

-- | Fail with every violation, one per line.
report :: [Text] -> Assertion
report violations = case violations of
  [] -> pure ()
  _ -> assertFailure (T.unpack (T.intercalate "\n" (map (T.take 300 . T.replace "\n" " | ") violations)) <> "\n\n" <> show (length violations) <> " violation(s)")

-- | How many shards the replaced-source schedules are split into.
replacedSourceShards :: Int
replacedSourceShards = 16

-- | Every replaced-source schedule: each source read of the fault-free
-- rename, with both replacement contents.
replacedSourceSchedules :: Int -> [(Int, RenameFault)]
replacedSourceSchedules sourceReads = [(boundary, ReplacedSource content) | boundary <- [1 .. sourceReads], content <- ["", replacementRow]]

-- | One shard's schedules: the source reads whose number has this remainder
-- modulo the shard count.
replacedSourceShard :: Int -> Int -> [(Int, RenameFault)]
replacedSourceShard sourceReads shard = [schedule | schedule@(boundary, _) <- replacedSourceSchedules sourceReads, boundary `mod` replacedSourceShards == shard]

-- | F62 for one shard of the source reads: a source replaced outside review
-- at any of them is never copied unreviewed, and rebind then rename is its
-- exit.
replacedSourceAtEveryRead :: Int -> Assertion
replacedSourceAtEveryRead shard = do
  clean <- runRename Nothing
  _ <- either (assertFailure . T.unpack . ("the fault-free rename violates the model: " <>)) pure clean
  sourceReads <- sourceReadCount
  assertBool "the rename reads its source" (sourceReads > 0)
  outcomes <- forM (replacedSourceShard sourceReads shard) $ \schedule ->
    (schedule,) <$> runRename (Just schedule)
  let leftovers = [schedule | (schedule, Left violation) <- outcomes, d1Marker `T.isInfixOf` violation]
  report [violation | (_, Left violation) <- outcomes, not (d1Marker `T.isInfixOf` violation)]
  -- D1, on the deferral ledger: destination objects an abandoned or
  -- reverted rename created block the next rename of that database,
  -- whose data and service are intact. Pinned, so a new case surfaces.
  leftovers @?= [schedule | schedule@(boundary, _) <- d1Schedules, boundary `mod` replacedSourceShards == shard]

d1Marker :: Text
d1Marker = "D1: "

-- | The schedules D1 covers (F81's deferral ledger entry).
d1Schedules :: [(Int, RenameFault)]
d1Schedules = [(boundary, ReplacedSource content) | boundary <- [93 .. 107] <> [111 .. 120], content <- ["", replacementRow]]

-- | A fault at one write (`create`, `patch` or `delete`) of the rename.
data RenameFault
  = -- | The API server refuses the write before any effect.
    RefusedWrite
  | -- | The write lands and its acknowledgement is lost.
    LostAcknowledgement
  | -- | The executor dies right after the write lands.
    InterruptedAfterWrite
  | -- | The copy Job dies part way through (evicted, disk full), leaving
    -- partial data in the destination; scheduled once, not at a write.
    PartialCopy
  | -- | The source's claim or writer is deleted and recreated outside review
    -- just before this read of it (ADR 27; F62), scheduled at a source read,
    -- not at a write. A replaced claim binds a new volume holding the given
    -- data: none (a newly provisioned volume) or other data (a claim bound to
    -- another volume).
    ReplacedSource !Text
  deriving stock (Eq, Ord, Show)

-- | The data a claim replaced onto another volume holds.
replacementRow :: Text
replacementRow = "pgdata:replacement-row"

-- | Count writes and source reads, and fire the scheduled fault at its write
-- or read.
adversary :: RenameWorld -> IORef [Text] -> IORef Int -> Maybe (Int, RenameFault) -> Transport
adversary world written sourceReads schedule next request
  | writes (request ^. #arguments) = do
      count <- atomicModifyIORef' written (\seen -> (seen <> [T.pack (unwords (take 3 (request ^. #arguments)))], length seen + 1))
      case schedule of
        Just (boundary, fault)
          | boundary == count -> case fault of
              RefusedWrite -> pure (Right (ExitFailure 1, "", "injected: the API server refused the write"))
              LostAcknowledgement -> next request >> pure (Right (ExitFailure 1, "", "injected: unable to connect to the server: EOF"))
              InterruptedAfterWrite -> next request >> throwIO Interrupted
              PartialCopy -> next request
              ReplacedSource _ -> next request
        _ -> next request
  | Just key <- sourceRead (request ^. #arguments) = do
      count <- atomicModifyIORef' sourceReads (\seen -> (seen + 1, seen + 1))
      case schedule of
        Just (boundary, ReplacedSource content) | boundary == count -> replaceOutOfBand world content key
        _ -> pure ()
      next request
  | otherwise = next request
  where
    writes arguments = case arguments of
      verb : _ -> verb `elem` ["create", "patch", "delete", "apply", "replace", "scale"]
      [] -> False
    sourceRead arguments = case arguments of
      "get" : kind : name : _ -> listToMaybe [key | key@(sourceKind, _, sourceName) <- sourceKeys, sourceKind == T.pack kind, sourceName == T.pack name]
      _ -> Nothing

-- | The fault-free rename's reads of its source.
sourceReadCount :: IO Int
sourceReadCount = withSystemTempDirectory "rename-model-reads" $ \root -> do
  written <- newIORef []
  sourceReads <- newIORef 0
  probe <- newIORef Nothing
  (store, world) <- seededRename recordOldIncarnations root
  let transport = adversary world written sourceReads Nothing
  (reviewed, registry) <- planRenameIn store world transport probe
  _ <- applyReviewed store registry reviewed
  readIORef sourceReads

-- | Run the rename under one schedule. 'Right' carries the number of writes.
runRename :: Maybe (Int, RenameFault) -> IO (Either Text Int)
runRename schedule = withSystemTempDirectory "rename-model" $ \root -> do
  written <- newIORef []
  sourceReads <- newIORef 0
  probe <- newIORef Nothing
  abandoned <- newIORef Nothing
  (store, world) <- seededRename recordOldIncarnations root
  let transport = adversary world written sourceReads schedule
      replacing = case schedule of
        Just (_, ReplacedSource _) -> True
        _ -> False
  when (fmap snd schedule == Just PartialCopy) (armPartialCopy world)
  -- The data a review accepted as the source's: the seeded data until a
  -- reviewed rebind accepts a replacement's.
  accepted <- newIORef knownRow
  outcome <- renameOnce store world transport probe abandoned replacing
  -- ADR 27 §3: a source replaced outside review is refused before any copy,
  -- and its exit is a reviewed rebind of the members status reports
  -- replaced, then the rename again.
  exited <- case outcome of
    Right ()
      | replacing -> do
          renamed <- renamedIn store
          if renamed
            then pure (Right ())
            else do
              stale <- replacedMembers store world
              rebound <- try @SomeException (rebindMembers store world transport probe stale)
              case rebound of
                Left reason -> pure (Left ("I1: the rebind of the replaced source " <> T.pack (show stale) <> " failed: " <> T.pack (displayException reason)))
                Right () -> do
                  readIORef world >>= writeIORef accepted . fromMaybe "" . Map.lookup "nagare-db-pg-old-data" . renameVolumes
                  -- E2: the rebind recorded a replacement that still carries
                  -- this migration's fence; the same exit now releases it.
                  readIORef abandoned >>= mapM_ (\input -> try @SomeException (abandonMigration store (renameRelease world id probe) input))
                  again <- renameOnce store world transport probe abandoned False
                  renamed' <- renamedIn store
                  stopped <- readIORef world
                  pure $ case again of
                    Left violation
                      | "rename destination address is not confirmed absent" `T.isInfixOf` violation
                      , not (sourceWriterFenced stopped || sourceScheduleSuspended stopped) ->
                          Left (d1Marker <> violation)
                    Left violation -> Left violation
                    Right ()
                      | renamed' -> Right ()
                      -- The copy script refuses an empty source, so a rebound
                      -- empty volume cannot be renamed; the rename then ends by
                      -- abandon-migration, and finalChecks proves it clean.
                      | Map.lookup "nagare-db-pg-old-data" (renameVolumes stopped) == Just "" -> Right ()
                      | otherwise -> Left "I1: the rename after the reviewed rebind did not rename the database"
    other -> pure other
  seen <- readIORef written
  let faulted = case schedule of
        Just (boundary, ReplacedSource _) -> " at source read " <> T.pack (show boundary)
        Just (boundary, _) -> " at `kubectl " <> fromMaybe "?" (listToMaybe (drop (boundary - 1) seen)) <> "`"
        Nothing -> ""
      explain violation = "faults: " <> T.pack (show schedule) <> faulted <> "\nviolation: " <> violation
  -- Any later converged review keeps what the rename recorded (F52).
  later <- case exited of
    Right () -> do
      renamed <- renamedIn store
      if not renamed
        then pure (Right ())
        else do
          reviewed <- try @SomeException (reviewRenamedAgain store world id probe)
          pure (either (\reason -> Left ("a later review of the renamed database failed: " <> T.pack (displayException reason))) Right reviewed)
    other -> pure other
  case later of
    Left violation -> pure (Left (explain violation))
    Right () -> do
      copied <- readIORef accepted
      final <- finalChecks store world copied
      count <- length <$> readIORef written
      pure (either (Left . explain) (const (Right count)) final)

-- | Plan and run the rename once, recovering a stopped transaction through
-- its supported exits. A planning or admission refusal, which has no effect,
-- is the expected outcome only when the source was replaced outside review.
renameOnce :: InventoryStore -> RenameWorld -> Transport -> IORef (Maybe (IO ())) -> IORef (Maybe AbandonInput) -> Bool -> IO (Either Text ())
renameOnce store world transport probe abandoned replacing = do
  planned <- try @SomeException (planRenameIn store world transport probe)
  case planned of
    Left refusal
      | replacing -> pure (Right ())
      | otherwise -> pure (Left ("planning refused: " <> T.pack (displayException refusal)))
    Right (reviewed, registry) -> do
      applied <- try @SomeException (applyReviewed store registry reviewed)
      case applied of
        Right (Right (Converged _)) -> pure (Right ())
        Right (Left errors)
          | replacing -> pure (Right ())
          | otherwise -> pure (Left ("admission refused: " <> T.pack (show (NE.toList errors))))
        _ -> recover store world registry (renameRelease world id probe) abandoned reviewed

-- | Whether the accepted database is the renamed one.
renamedIn :: InventoryStore -> IO Bool
renamedIn store = do
  history <- loadInventoryHistory store
  pure $ case history of
    Right loaded -> (revisionDigest . fst <$> Map.lookup databaseOwner (historyAccepted loaded)) == Just (contentDigest (encodeCanonicalScope newScope))
    Left _ -> False

-- | The members status reports replaced that were not replaced outside
-- review: before the rename, a source member replaced outside review is
-- correctly reported replaced until its rebind.
wronglyReplaced :: InventoryStore -> RenameWorld -> IO [ResourceId]
wronglyReplaced store world = do
  stale <- replacedMembers store world
  renamed <- renamedIn store
  outsideReview <- replacedOldMembers <$> readIORef world
  pure (if renamed then stale else filter (`notElem` outsideReview) stale)

-- | After a stop: I3 at the stop, then the supported exits. Resume first (a
-- transient fault clears); if the transaction is still active, each recovery
-- decision for each open operation, then resume again.
recover :: InventoryStore -> RenameWorld -> AdapterRegistry -> MigrationExit -> IORef (Maybe AbandonInput) -> ReviewedPlan -> IO (Either Text ())
recover store world registry release abandoned reviewed = do
  stale <- wronglyReplaced store world
  if not (null stale)
    then pure (Left ("I3: status reports renamed members as replaced while stopped: " <> T.pack (show stale)))
    else resumeUpTo (3 :: Int)
  where
    resumeUpTo attempts = do
      active <- activeTransaction store
      case active of
        Nothing -> pure (Right ())
        Just transaction
          | attempts == 0 -> decide transaction
          | otherwise -> do
              _ <- try @SomeException (resumeTransaction store registry transaction)
              stale <- wronglyReplaced store world
              if null stale
                then resumeUpTo (attempts - 1)
                else pure (Left ("I3: status reports renamed members as replaced after resume: " <> T.pack (show stale)))
    -- ADR 26: the supported exits are resume and close. Close refuses an
    -- active migration, whose exits are resume and its forward copy redo.
    -- ADR 26 and F81: close, and for a migration that cannot go forward,
    -- abandon-migration.
    decide transaction = do
      open <- openOperations store transaction
      let review = contentDigest (encodeReviewDocument (reviewedDocument reviewed))
      _ <- try @SomeException (closeTransaction store registry (CloseInput transaction review False Nothing))
      closed <- isNothing <$> activeTransaction store
      abandoned <-
        if closed
          then pure (Right ())
          else do
            writeIORef abandoned (Just (AbandonInput transaction review False))
            either (Left . T.pack . displayException) (either (Left . T.pack . show) (const (Right ()))) <$> try @SomeException (abandonMigration store release (AbandonInput transaction review False))
      done <- isNothing <$> activeTransaction store
      pure $
        if done
          then Right ()
          else Left ("I1: the rename stopped with no supported exit; open operations " <> T.pack (show (map operationIdText open)) <> "; abandon-migration: " <> either id (const "ended nothing") abandoned)

-- | At an idle head: status reports nothing replaced (I3); a renamed database
-- has every reviewed effect, copied the data a review accepted exactly once
-- (I4) and records each renamed member as its new object or not at all
-- (F52); the source still holds its data unless it was replaced outside
-- review.
finalChecks :: InventoryStore -> RenameWorld -> Text -> IO (Either Text ())
finalChecks store world copied = do
  stale <- wronglyReplaced store world
  renamed <- renamedIn store
  final <- readIORef world
  recorded <- either (const Map.empty) (maybe Map.empty headIncarnations) <$> readHead store
  let source = fromMaybe "" (Map.lookup "nagare-db-pg-old-data" (renameVolumes final))
      sourceReplaced = not (null (replacedOldMembers final))
      current = newObjectUids final
      staleRecords = [member | (member, physical) <- Map.toList recorded, Map.lookup member current /= Just (physicalIdentityText physical)]
  checked <-
    if renamed
      then either (Left . T.pack . displayException) Right <$> try @SomeException (verifyRenamedWorldWith copied source final)
      else pure (Right ())
  -- A lost write response leaves a member unrecorded (ADR 27), but the
  -- convergence observation records a migrated data-bearing member.
  let unrecordedData = [member | member <- dataBearing, Map.member member current, Map.notMember member recorded]
  pure (verdict stale checked renamed final source sourceReplaced staleRecords unrecordedData)
  where
    verdict stale checked renamed final source sourceReplaced staleRecords unrecordedData
      | not (null stale) = Left ("I3: status reports renamed members as replaced at the end: " <> T.pack (show stale))
      | Left reason <- checked = Left ("the renamed database is incomplete, or copied data no review accepted: " <> reason)
      | renamed && destinationCopies final /= 1 = Left ("I4: the destination volume was written " <> T.pack (show (destinationCopies final)) <> " times (transfer Jobs " <> T.pack (show (transferJobs final)) <> ")")
      | not renamed && sourceWriterFenced final = Left "F81: the database was not renamed, but its writer is still fenced"
      | not renamed && sourceScheduleSuspended final = Left "F81: the database was not renamed, but its backup schedule is still suspended"
      | renamed && not (null unrecordedData) = Left ("F52: a renamed data-bearing member is unrecorded after convergence: " <> T.pack (show unrecordedData))
      | renamed && not (null staleRecords) = Left ("F52: a renamed member's record names an object other than its new one: " <> T.pack (show staleRecords))
      | source /= knownRow && not sourceReplaced = Left "the source volume lost its data"
      | otherwise = Right ()

activeTransaction :: InventoryStore -> IO (Maybe TransactionId)
activeTransaction store = do
  current <- readHead store
  pure $ case current of
    Right (Just value) -> headActiveTransaction value >>= either (const Nothing) Just . mkTransactionId
    _ -> Nothing

-- | Operations of the transaction without a completion, from the journal.
openOperations :: InventoryStore -> TransactionId -> IO [OperationId]
openOperations store transaction = do
  current <- readHead store
  raw <- case current of
    Right (Just value) -> either (const []) id <$> readJournalPrefix store (headSequence value)
    _ -> pure []
  let events = [event | Right event <- map decodeJournalEvent raw, eventTransaction event == transaction]
  pure
    [ operation
    | (operation, state) <- Map.toList (operationStates transaction events)
    , case state of
        Completed _ -> False
        _ -> True
    ]
