{-# LANGUAGE OverloadedStrings #-}

-- | Bounded, read-only collection of verified scheduled database backups
-- (EP-233). One cycle lists each backup key-space root once, so its cost
-- does not grow with the number of schedules; finds the complete
-- archive/receipt pairs newer than the activation baseline whose completion
-- is not yet known; verifies at most a budget of them at their exact listed
-- versions with the real receipt verifier; and commits the verified ones as
-- one observation of the collector's chain, with its state, before anything
-- else counts them as seen.
--
-- The collector's authority is its 'CollectorOps': listing and exact reads
-- of the backup bucket, the accepted signing keys, and writes under the
-- lifecycle prefix's @receipts/@. It holds no inventory claim and can create,
-- ingest, restore or prune nothing. Observing a backup never accepts it.
--
-- A run that fails verification is never published as completed. It stays
-- pending with its reason, first-seen time and a growing backoff while later
-- runs progress; one invalid object cannot starve the rest. EP-276: a run
-- whose failure no later cycle can clear on its own (a bad signature, a
-- source that is not the recorded incarnation, changed bytes) is announced
-- once as @database.backup.failed@, and each schedule's freshness against its
-- signed recovery-point objective is graded every cycle and announced when it
-- moves, as @database.backup.freshness.changed@. A listing is
-- complete every cycle, so a receipt that appears late, behind any name
-- order, is found on the next cycle; the activation baseline, not a cursor,
-- decides what is new.
module Nagare.Events.BackupCollector
  ( CollectorState (..)
  , collectorStateVersion
  , Baseline (..)
  , PendingRun (..)
  , ScheduleFreshness (..)
  , VerifyFailure (..)
  , classifyFailure
  , CollectorOps (..)
  , CollectBudget (..)
  , defaultCollectBudget
  , CollectOutcome (..)
  , CollectError (..)
  , activateCollection
  , collectOnce
  , keySpaceRoot
  )
where

import Control.Concurrent.Async (mapConcurrently)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (nub, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Backup
import Nagare.Events.Envelope (eventIdFor)
import Nagare.Events.Layout (lookupIds)
import Nagare.Events.Receipts
import Nagare.Events.Source
import Nagare.Events.Store
import Nagare.Inventory.Backup (ScheduledBackupReceipt (..), ScheduledReceiptExpectation (..))
import Nagare.Inventory.BackupFreshness (BackupFreshness (..), RecoveryPointObjective (..), backupFreshness)
import Nagare.Inventory.ScheduledReceipt (ScheduledReceiptEvidence (..), inspectScheduledReceiptAt)
import Nagare.Inventory.ScheduledStore (StoredObject, VersionedObject (..), VersionedReader (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | What the collector remembers between cycles, in one immutable object
-- the collector head names. It is bounded: the most recent observed backup
-- IDs, which cover observations the feed has not materialized yet, and the
-- oldest pending runs.
data CollectorState = CollectorState
  { schemaVersion :: !Int
  , activatedAt :: !UTCTime
  , baseline :: !Baseline
  , recent :: ![Text]
  , pending :: ![PendingRun]
  , dropped :: !Int
  -- ^ Pending runs beyond the bound, still retried by later cycles.
  , freshness :: !(Map Text ScheduleFreshness)
  -- ^ EP-276: each schedule's newest verified recovery point and the grade
  -- last recorded for it, by schedule label. Version 1 had none.
  }
  deriving stock (Eq, Show, Generic)

-- | Version 2 (EP-276) adds 'freshness'; a version 1 state reads as one
-- with no schedule graded yet.
collectorStateVersion :: Int
collectorStateVersion = 2

-- | A schedule's newest verified recovery point, and the grade recorded for
-- it, once it had one.
data ScheduleFreshness = ScheduleFreshness
  { newest :: !UTCTime
  , grade :: !(Maybe FreshnessGrade)
  }
  deriving stock (Eq, Show, Generic)

-- | Why a run did not verify: for good, or for a reason a later cycle may
-- clear (an unreadable key, a schedule with no accepted revision, a receipt
-- with no backup object yet, a race with an upload).
data VerifyFailure
  = TerminalFailure !BackupFailureReason !Text
  | RetryableFailure !Text
  deriving stock (Eq, Show, Generic)

-- | The verifier's reasons, typed. A reason is terminal only when it is
-- listed here; every other one is retryable.
classifyFailure :: Text -> VerifyFailure
classifyFailure reason'
  | reason' `elem` ["scheduled receipt HMAC differs from the accepted signing key", "scheduled receipt has an invalid HMAC"] = TerminalFailure BadSignature reason'
  | reason' == "scheduled receipt source incarnation differs from accepted evidence" = TerminalFailure WrongSource reason'
  | reason' == "scheduled backup version, length, or checksum changed" = TerminalFailure ChangedBytes reason'
  | otherwise = RetryableFailure reason'

failureText :: VerifyFailure -> Text
failureText = \case
  TerminalFailure _ text -> text
  RetryableFailure text -> text

isTerminal :: VerifyFailure -> Bool
isTerminal = \case
  TerminalFailure _ _ -> True
  RetryableFailure _ -> False

-- | The receipts present at activation: every receipt version the provider
-- dated at or before @through@, except those dated exactly then and not
-- named in @at@, is preexisting and never announced.
data Baseline = Baseline
  { through :: !(Maybe UTCTime)
  , at :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | A run that is not verified yet, and why.
data PendingRun = PendingRun
  { schedule :: !Text
  , run :: !Text
  , receipt :: !StoredVersion
  , reason :: !Text
  , firstSeen :: !UTCTime
  , attempts :: !Int
  , retryAfter :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

data CollectorOps = CollectorOps
  { objects :: !VersionedReader
  , bucketAddress :: !Text
  -- ^ The full address of the bucket's root, as receipts name objects:
  -- @gs://BUCKET/@ or @s3://BUCKET/@.
  , signingKey :: !(SigningRef -> IO (Either Text (Text, PhysicalIdentity)))
  -- ^ The HMAC key a signing Secret holds and that Secret's live UID.
  , clock :: !(IO UTCTime)
  }
  deriving stock (Generic)

-- | At most @verifications@ runs and @bytes@ archive bytes verified per
-- cycle, @concurrency@ at a time. A run past the budget is deferred to the
-- next cycle, never skipped.
data CollectBudget = CollectBudget
  { verifications :: !Int
  , bytes :: !Integer
  , concurrency :: !Int
  }
  deriving stock (Eq, Show, Generic)

defaultCollectBudget :: CollectBudget
defaultCollectBudget = CollectBudget 64 (256 * 1024 * 1024) 4

data CollectOutcome = CollectOutcome
  { listed :: !Int
  -- ^ Objects the cycle's listings returned.
  , verified :: !Int
  , published :: !Int
  , known :: !Int
  , deferred :: !Int
  , pendingRuns :: !Int
  , oldestPending :: !(Maybe UTCTime)
  , failures :: ![(Text, Text)]
  -- ^ This cycle's verification failures: run and reason.
  , wrote :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data CollectError
  = CollectNotActive
  | CollectFeed !FeedError
  | CollectListing !Text !Text
  | CollectContended
  deriving stock (Eq, Show)

-- | The first segment of a bucket-relative prefix: @databases/@ for
-- @databases/mydb/@. Each root is listed once per cycle.
keySpaceRoot :: Text -> Text
keySpaceRoot prefix = fst (T.breakOn "/" prefix) <> "/"

-- | Start collection for a context: pin the receipts present now as the
-- baseline. Activating an active collector returns its head unchanged.
activateCollection :: FeedStore -> ContextBinding -> CollectorOps -> [BackupSchedule] -> IO (Either CollectError CollectorHead)
activateCollection store binding ops schedules = do
  observed <- observeCollector store binding
  case observed of
    Left err -> pure (Left (CollectFeed err))
    Right current | Just headValue <- observedCollectorHead current -> pure (Right headValue)
    Right current -> do
      listing <- listRoots ops schedules
      case listing of
        Left err -> pure (Left err)
        Right objectsListed -> do
          now <- ops ^. #clock
          let receipts = [object' | object' <- objectsListed, ".receipt.json" `T.isSuffixOf` versionedKey object']
              through = if null receipts then Nothing else Just (maximum (map versionedModified receipts))
              tied = [address ops (versionedKey object') | object' <- receipts, Just (versionedModified object') == through]
              state' = CollectorState collectorStateVersion now (Baseline through tied) [] [] 0 Map.empty
          stored <- publishFeedObject store stateKey (encodeState state')
          case stored of
            Left err -> pure (Left (CollectFeed err))
            Right digest -> do
              let headValue = CollectorHead collectorHeadVersion binding 0 initialCheckpoint digest
              replaced <- replaceCollectorHead store current headValue
              case replaced of
                Left err -> pure (Left (CollectFeed err))
                Right Replaced -> pure (Right headValue)
                Right Superseded -> do
                  again <- observeCollector store binding
                  pure (either (Left . CollectFeed) (maybe (Left CollectContended) Right . observedCollectorHead) again)

-- | A run found in a listing: its receipt version and, when uploaded, its
-- archive version.
data Found = Found
  { schedule :: !BackupSchedule
  , run :: !Text
  , receipt :: !VersionedObject
  , archive :: !(Maybe VersionedObject)
  }
  deriving stock (Generic)

-- | One collection cycle.
collectOnce :: FeedStore -> ContextBinding -> CollectorOps -> CollectBudget -> [BackupSchedule] -> IO (Either CollectError CollectOutcome)
collectOnce store binding ops budget schedules = do
  loaded <- loadCollector store binding
  case loaded of
    Left err -> pure (Left err)
    Right (_, _, state') -> do
      listing <- listRoots ops schedules
      case listing of
        Left err -> pure (Left err)
        Right objectsListed -> do
          now <- ops ^. #clock
          feedIds <- either (const Nothing) (^. #ids) <$> readFeedHead store binding
          let found = discover objectsListed
              fresh = sortOn (versionedModified . (^. #receipt)) [candidate | candidate <- found, isNew (state' ^. #baseline) candidate]
              recentSet = Set.fromList (state' ^. #recent)
              pendingBy = Map.fromList [(pendingKey entry, entry) | entry <- state' ^. #pending]
              due candidate = maybe True (\entry -> entry ^. #retryAfter <= now) (Map.lookup (foundKey candidate) pendingBy)
              unseen = [candidate | candidate <- fresh, maybe True (`Set.notMember` recentSet) (backupOf candidate)]
          inFeed <- lookupIds store feedIds [eventIdFor (binding ^. #identity) (completionKey backup) | Just backup <- map backupOf unseen]
          case inFeed of
            Left err -> pure (Left (CollectFeed err))
            Right present -> do
              let seenInFeed candidate = maybe False (\backup -> Map.member (eventIdFor (binding ^. #identity) (completionKey backup)) present) (backupOf candidate)
                  open' = [candidate | candidate <- unseen, not (seenInFeed candidate)]
                  known' = length fresh - length open'
                  (missingArchive, complete) = partitionArchive (filter due open')
                  (chosen, later) = withinBudget complete
              keys <- signingKeys (nub [candidate ^. #schedule | candidate <- chosen])
              results <- inWaves (max 1 (budget ^. #concurrency)) (verifyFound keys) chosen
              let successes = [(candidate, run') | (candidate, Right run') <- zip chosen results]
                  typed = [(candidate, classifyFailure reason') | (candidate, Left reason') <- zip chosen results] <> [(candidate, RetryableFailure "the receipt has no backup object") | candidate <- missingArchive]
                  failed = [(candidate, failureText failure) | (candidate, failure) <- typed]
                  events' = [scheduledCompletion (candidate ^. #schedule) run' | (candidate, run') <- successes]
                  updates = Map.fromList [(foundKey candidate, failedEntry pendingBy now (foundKey candidate) candidate reason') | (candidate, reason') <- failed]
                  -- A terminal failure is announced when it is first recorded:
                  -- a retry, or a restarted collector, finds it pending.
                  failures' =
                    [ event
                    | (candidate, TerminalFailure why detail') <- typed
                    , maybe True (not . isTerminal . classifyFailure . (^. #reason)) (Map.lookup (foundKey candidate) pendingBy)
                    , Right event <- [failureEvent candidate why detail']
                    ]
                  points =
                    Map.fromListWith
                      max
                      [ (candidate ^. #schedule . #label, point)
                      | (candidate, run') <- successes
                      , Just point <- [scheduledRecoveryPoint (scheduledReceipt (run' ^. #evidence))]
                      , point <= now
                      ]
                  listedKeys = Set.fromList (map foundKey found)
                  -- Verified, already known, or no longer listed: nothing is pending.
                  resolved =
                    Set.fromList
                      ( map (foundKey . fst) successes
                          <> [foundKey candidate | candidate <- found, Just backup <- [backupOf candidate], Set.member backup recentSet || seenInFeed candidate]
                          <> [key' | key' <- Map.keys pendingBy, Set.notMember key' listedKeys]
                      )
              committed <- commit store binding now (events' <> failures') (gradeSchedules now schedules points) updates resolved
              pure $ do
                (wrote', stateAfter) <- committed
                pure
                  CollectOutcome
                    { listed = length objectsListed
                    , verified = length successes
                    , published = length events'
                    , known = known'
                    , deferred = length later
                    , pendingRuns = length (stateAfter ^. #pending) + stateAfter ^. #dropped
                    , oldestPending = if null (stateAfter ^. #pending) then Nothing else Just (minimum (map (^. #firstSeen) (stateAfter ^. #pending)))
                    , failures = [(candidate ^. #run, reason') | (candidate, reason') <- failed]
                    , wrote = wrote'
                    }
  where
    discover objectsListed =
      let byKey = Map.fromList [(versionedKey object', object') | object' <- objectsListed]
       in [ Found schedule' run' receipt' (Map.lookup archiveKey byKey)
          | schedule' <- schedules
          , receipt' <- objectsListed
          , Just rest <- [T.stripPrefix (schedule' ^. #keyPrefix) (versionedKey receipt')]
          , Just archiveRest <- [T.stripSuffix ".receipt.json" rest]
          , let run' = fst (T.breakOn "." archiveRest)
                archiveKey = schedule' ^. #keyPrefix <> archiveRest
          , not (T.null run') && not ("/" `T.isInfixOf` archiveRest)
          ]
    isNew baselineValue candidate =
      let modified = versionedModified (candidate ^. #receipt)
       in case baselineValue ^. #through of
            Nothing -> True
            Just through'
              | modified > through' -> True
              | modified == through' -> address ops (versionedKey (candidate ^. #receipt)) `notElem` baselineValue ^. #at
              | otherwise -> False
    backupOf candidate = do
      archive' <- candidate ^. #archive
      pure (backupIdFor ScheduledBackup (candidate ^. #schedule . #owner) (candidate ^. #run) (stored archive') (stored (candidate ^. #receipt)))
    stored object' = StoredVersion (address ops (versionedKey object')) (versionedVersion object')
    failureEvent candidate why detail' = do
      key <- mkSourceKey ("database.backup.failed:" <> candidate ^. #schedule . #label <> ":" <> candidate ^. #run)
      pure
        EventCandidate
          { key
          , resource = candidate ^. #schedule . #source
          , occurredAt = Just (stamp (versionedModified (candidate ^. #receipt)))
          , evidence = []
          , payload =
              BackupFailedPayload
                BackupFailure
                  { schedule = candidate ^. #schedule . #label
                  , run = candidate ^. #run
                  , receipt = stored (candidate ^. #receipt)
                  , archive = stored <$> candidate ^. #archive
                  , reason = why
                  , detail = detail'
                  }
          }
    foundKey candidate = (candidate ^. #schedule . #label, stored (candidate ^. #receipt))
    partitionArchive candidates = ([c | c <- candidates, isNothing (c ^. #archive)], [c | c <- candidates, isJust (c ^. #archive)])
    withinBudget = go 0 (0 :: Int) []
      where
        go _ _ kept [] = (reverse kept, [])
        go spent count kept (candidate : rest)
          | count >= budget ^. #verifications = (reverse kept, candidate : rest)
          | otherwise =
              let size = maybe 0 versionedSize (candidate ^. #archive)
               in if spent + size > budget ^. #bytes && not (null kept)
                    then (reverse kept, candidate : rest)
                    else go (spent + size) (count + 1) (candidate : kept) rest
    signingKeys chosenSchedules = do
      fetched <- traverse (\schedule' -> (,) (schedule' ^. #label) <$> checkedKey schedule') chosenSchedules
      pure (Map.fromList fetched)
    checkedKey schedule' = do
      answer <- (ops ^. #signingKey) (schedule' ^. #signing)
      pure $ case answer of
        Left reason' -> Left ("the signing key cannot be read: " <> reason')
        Right (key, uid)
          | uid == schedule' ^. #signing . #incarnation -> Right key
          | otherwise -> Left "the signing Secret is not the recorded incarnation"
    verifyFound keys candidate = case (Map.lookup (candidate ^. #schedule . #label) keys, candidate ^. #archive) of
      (Just (Right key), Just archive') -> tryExpectations key archive' (candidate ^. #schedule . #expectations)
      (Just (Left reason'), _) -> pure (Left reason')
      _ -> pure (Left "the receipt has no backup object")
      where
        tryExpectations _ _ [] = pure (Left "the schedule has no accepted revision")
        tryExpectations key archive' (current : historical) = do
          first' <- inspect key archive' current
          case first' of
            Right evidence -> pure (Right (VerifiedRun evidence (Just (versionedModified (candidate ^. #receipt)))))
            Left reason' -> fallback reason' key archive' historical
        fallback reason' _ _ [] = pure (Left reason')
        fallback reason' key archive' (expectation : rest)
          | scheduledFormat expectation /= formatOf archive' = fallback reason' key archive' rest
          | otherwise = do
              attempt' <- inspect key archive' expectation
              case attempt' of
                Right evidence -> pure (Right (VerifiedRun evidence (Just (versionedModified (candidate ^. #receipt)))))
                Left _ -> fallback reason' key archive' rest
        formatOf archive' = T.drop 1 (snd (T.breakOn "." (T.drop (T.length (candidate ^. #schedule . #keyPrefix)) (versionedKey archive'))))
        inspect key archive' expectation =
          inspectScheduledReceiptAt (readAt ops) expectation (candidate ^. #run) key (versionedVersion (candidate ^. #receipt)) (versionedVersion archive')

-- | Bucket-relative key to the full object address receipts use.
address :: CollectorOps -> Text -> Text
address ops key = ops ^. #bucketAddress <> key

readAt :: CollectorOps -> Text -> Text -> FilePath -> IO (Either Text StoredObject)
readAt ops fullAddress version path = case T.stripPrefix (ops ^. #bucketAddress) fullAddress of
  Just key -> readVersionToFile (ops ^. #objects) key version path
  Nothing -> pure (Left "a receipt names an object outside the backup bucket")

-- | Every live object under the schedules' key-space roots, one complete
-- listing per root.
listRoots :: CollectorOps -> [BackupSchedule] -> IO (Either CollectError [VersionedObject])
listRoots ops schedules = go [] (nub (map (keySpaceRoot . (^. #keyPrefix)) schedules))
  where
    go acc [] = pure (Right (concat (reverse acc)))
    go acc (root : rest) = do
      listedObjects <- listLiveVersions (ops ^. #objects) root
      case listedObjects of
        Left reason' -> pure (Left (CollectListing root reason'))
        Right entries -> go (entries : acc) rest

inWaves :: Int -> (a -> IO b) -> [a] -> IO [b]
inWaves _ _ [] = pure []
inWaves width action items = do
  let (wave, rest) = splitAt width items
  done <- mapConcurrently action wave
  (done <>) <$> inWaves width action rest

pendingKey :: PendingRun -> (Text, StoredVersion)
pendingKey entry = (entry ^. #schedule, entry ^. #receipt)

-- | A failure doubles its run's backoff from five minutes, up to six hours.
failedEntry :: Map (Text, StoredVersion) PendingRun -> UTCTime -> (Text, StoredVersion) -> Found -> Text -> PendingRun
failedEntry existing now key' candidate reason' =
  let previous' = Map.lookup key' existing
      attempts' = maybe 1 ((+ 1) . (^. #attempts)) previous'
      backoff = min (6 * 3600) (300 * 2 ^ min 7 (attempts' - 1)) :: NominalDiffTime
   in PendingRun
        { schedule = fst key'
        , run = candidate ^. #run
        , receipt = snd key'
        , reason = reason'
        , firstSeen = maybe now (^. #firstSeen) previous'
        , attempts = attempts'
        , retryAfter = addUTCTime backoff now
        }

loadCollector :: FeedStore -> ContextBinding -> IO (Either CollectError (ObservedCollector, CollectorHead, CollectorState))
loadCollector store binding = do
  observed <- observeCollector store binding
  case observed of
    Left err -> pure (Left (CollectFeed err))
    Right current -> case observedCollectorHead current of
      Nothing -> pure (Left CollectNotActive)
      Just headValue -> do
        bytes' <- readFeedObject store stateKey (headValue ^. #state)
        pure $ case bytes' >>= decodeState of
          Left err -> Left (CollectFeed err)
          Right state' -> Right (current, headValue, state')

-- | Commit verified candidates and pending changes on the current head: an
-- observation at the chain's next sequence, adopting an orphan there first,
-- then the head over it and the new state in one conditional write. A head
-- another collector replaced is reread and the commit applied to it, at
-- most three times; candidates it already observed are dropped.
commit :: FeedStore -> ContextBinding -> UTCTime -> [EventCandidate] -> (Map Text ScheduleFreshness -> (Map Text ScheduleFreshness, [EventCandidate])) -> Map (Text, StoredVersion) PendingRun -> Set.Set (Text, StoredVersion) -> IO (Either CollectError (Bool, CollectorState))
commit store binding now candidates freshen updates resolved = attempt' (3 :: Int)
  where
    attempt' remaining = do
      loaded <- loadCollector store binding
      case loaded of
        Left err -> pure (Left err)
        Right (observed, headValue, state') -> do
          let recentSet = Set.fromList (state' ^. #recent)
              (graded, freshnessEvents) = freshen (state' ^. #freshness)
              wanted = [candidate | candidate <- candidates, maybe True (`Set.notMember` recentSet) (backupIdOf candidate)] <> freshnessEvents
              merged = Map.union updates (Map.fromList [(pendingKey entry, entry) | entry <- state' ^. #pending, Set.notMember (pendingKey entry) resolved])
              ordered = sortOn (^. #firstSeen) (Map.elems merged)
              (kept, overflow) = splitAt pendingBound ordered
              withPending = state' {pending = kept, dropped = length overflow, freshness = graded}
          if null wanted && withPending == state'
            then pure (Right (False, state'))
            else do
              appended <- appendObservation headValue wanted
              case appended of
                Left err -> pure (Left err)
                Right (chain', added) -> do
                  let state'' = withPending {recent = take recentBound (added <> state' ^. #recent)}
                  stored <- publishFeedObject store stateKey (encodeState state'')
                  case stored of
                    Left err -> pure (Left (CollectFeed err))
                    Right digest -> do
                      replaced <- replaceCollectorHead store observed headValue {generation = headValue ^. #generation + 1, chain = chain', state = digest}
                      case replaced of
                        Left err -> pure (Left (CollectFeed err))
                        Right Replaced -> pure (Right (True, state''))
                        Right Superseded
                          | remaining > 1 -> attempt' (remaining - 1)
                          | otherwise -> pure (Left CollectContended)
    -- An orphan at the next sequence is committed history: its candidates
    -- were verified. It is appended over first, then ours after it.
    appendObservation headValue wanted
      | null wanted = pure (Right (headValue ^. #chain, []))
      | otherwise = go (headValue ^. #chain) [] wanted (3 :: Int)
      where
        go position added pendingCandidates budgetLeft = do
          let observation = Observation observationVersion (position ^. #next) (position ^. #previous) (stamp now) pendingCandidates
          outcome <- publishObservation store observation
          case outcome of
            Left err -> pure (Left (CollectFeed err))
            Right Published -> pure (Right (advance position observation, mapMaybe backupIdOf pendingCandidates <> added))
            Right (Orphan orphan)
              | budgetLeft <= 1 -> pure (Left CollectContended)
              | otherwise -> do
                  let adopted = mapMaybe backupIdOf (orphan ^. #events)
                      remaining' = [candidate | candidate <- pendingCandidates, maybe True (`notElem` adopted) (backupIdOf candidate)]
                      position' = advance position orphan
                  if null remaining'
                    then pure (Right (position', adopted <> added))
                    else go position' (adopted <> added) remaining' (budgetLeft - 1)
    advance position observation = SourceCheckpoint (position ^. #next + 1) (Just (observationDigest observation))
    backupIdOf candidate = case candidate ^. #payload of
      BackupCompletedPayload completion -> Just (completion ^. #backup)
      _ -> Nothing

-- | Grade each schedule the cycle was given from its newest verified
-- recovery point, and the events of the grades that moved. A schedule the
-- cycle was not given drops out, so a retired database never grades to
-- breached; one with no verified point, no objective or only a point in the
-- future records nothing new; a first grade is recorded without an event.
gradeSchedules :: UTCTime -> [BackupSchedule] -> Map Text UTCTime -> Map Text ScheduleFreshness -> (Map Text ScheduleFreshness, [EventCandidate])
gradeSchedules now schedules points recorded =
  (Map.fromList [(label, entry) | (label, entry, _) <- graded], [event | (_, _, Just event) <- graded])
  where
    graded = mapMaybe gradeOne schedules
    gradeOne schedule' = do
      let label = schedule' ^. #label
          earlier = Map.lookup label recorded
      newest' <- maximumMaybe (maybe [] (\entry -> [entry ^. #newest]) earlier <> maybe [] pure (Map.lookup label points))
      let previous' = earlier >>= (^. #grade)
          keep = (label, ScheduleFreshness newest' previous', Nothing)
      pure $ case (listToMaybe (map scheduledObjective (schedule' ^. #expectations)), previous') of
        (Nothing, _) -> keep
        (Just objective', _) -> case gradeOf (backupFreshness objective' now [newest']) of
          Nothing -> keep
          Just (current, _) | previous' == Nothing || previous' == Just current -> (label, ScheduleFreshness newest' (Just current), Nothing)
          Just (current, age) -> case (previous', changeEvent schedule' objective' newest' current age) of
            (Just from', Right event) -> (label, ScheduleFreshness newest' (Just current), Just (event from'))
            -- A key the alphabet refuses records nothing new.
            _ -> keep
    gradeOf = \case
      Fresh age -> Just (GradeFresh, age)
      Deteriorating age -> Just (GradeDeteriorating, age)
      Breached age -> Just (GradeBreached, age)
      NoRecoveryPoint -> Nothing
      FutureRecoveryPoint -> Nothing
    changeEvent schedule' objective' newest' current age = do
      key <- mkSourceKey ("database.backup.freshness:" <> schedule' ^. #label <> ":" <> freshnessGradeText current <> ":" <> T.toLower (T.pack (formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" newest')))
      pure $ \from' ->
        EventCandidate
          { key
          , resource = schedule' ^. #source
          , occurredAt = Nothing
          , evidence = []
          , payload =
              FreshnessChangedPayload
                FreshnessChange
                  { schedule = schedule' ^. #label
                  , from = from'
                  , to = current
                  , objective = case objective' of
                      HourlyRecoveryPoint -> HourlyObjective
                      DailyRecoveryPoint -> DailyObjective
                  , newestRecoveryPoint = stamp newest'
                  , ageSeconds = age
                  }
          }
    maximumMaybe = \case
      [] -> Nothing
      values -> Just (maximum values)
    listToMaybe = \case
      value : _ -> Just value
      [] -> Nothing

recentBound, pendingBound :: Int
recentBound = 256
pendingBound = 256

stamp :: UTCTime -> Text
stamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

encodeState :: CollectorState -> ByteString
encodeState = either (error . T.unpack) id . canonicalValue . toJSON

decodeState :: ByteString -> Either FeedError CollectorState
decodeState bytes' = do
  -- Canonical at the version it was written, which may be an earlier one.
  raw <- first (FeedInvalid "collector state" . T.pack) (eitherDecodeStrict' bytes')
  unless (canonicalValue (raw :: Value) == Right bytes') (Left (FeedInvalid "collector state" "not canonical"))
  first (FeedInvalid "collector state" . T.pack) (parseEither parseJSON raw)

strictFields :: Options
strictFields = defaultOptions {rejectUnknownFields = True}

instance ToJSON Baseline where toJSON = genericToJSON strictFields

instance FromJSON Baseline where parseJSON = genericParseJSON strictFields

instance ToJSON PendingRun where toJSON = genericToJSON strictFields

instance FromJSON PendingRun where parseJSON = genericParseJSON strictFields

instance ToJSON ScheduleFreshness where toJSON = genericToJSON strictFields

instance FromJSON ScheduleFreshness where parseJSON = genericParseJSON strictFields

-- | Always written at the current version.
instance ToJSON CollectorState where
  toJSON state' =
    object
      [ "version" .= collectorStateVersion
      , "activatedAt" .= (state' ^. #activatedAt)
      , "baseline" .= (state' ^. #baseline)
      , "recent" .= (state' ^. #recent)
      , "pending" .= (state' ^. #pending)
      , "dropped" .= (state' ^. #dropped)
      , "freshness" .= (state' ^. #freshness)
      ]

-- | Versions 1 and 2. A version 1 state has no freshness and reads as one
-- with no schedule graded; it decodes to the current version, so the next
-- write moves it to version 2.
instance FromJSON CollectorState where
  parseJSON = withObject "collector state" $ \o -> do
    version <- o .: "version"
    let base = ["version", "activatedAt", "baseline", "recent", "pending", "dropped"]
    case version :: Int of
      1 -> unless (all (`elem` base) (KM.keys o)) (fail "the collector state has an unknown field")
      2 -> unless (all (`elem` ("freshness" : base)) (KM.keys o)) (fail "the collector state has an unknown field")
      _ -> fail "unsupported collector state version"
    freshness' <- if version == 1 then pure Map.empty else o .: "freshness"
    CollectorState collectorStateVersion <$> o .: "activatedAt" <*> o .: "baseline" <*> o .: "recent" <*> o .: "pending" <*> o .: "dropped" <*> pure freshness'
