{-# LANGUAGE OverloadedStrings #-}

-- | Materializing committed lifecycle sources into the event feed (EP-231
-- M2). One cycle reads the inventory head once, the journal suffix after the
-- feed's checkpoint and the facts it names, and the backup collector's head
-- and the observations after the feed's receipt checkpoint (EP-233); publishes the new envelopes'
-- segments and index nodes; then advances the feed head and its checkpoint in
-- one conditional write, so a crash can never acknowledge a source without
-- making its events visible. A source already published, by any route, is
-- never published twice: its ID resolves in the ID index.
--
-- EP-276: a committed journal stop becomes a @change.failed@ with the review
-- its transaction names, read at most once per transaction per cycle, and a
-- committed close a @change.closed@ with its close record. Each read counts
-- against the cycle's journal budget. A stop whose review or record cannot be
-- read stops the cycle at that stop, which is never skipped.
module Nagare.Events.Materialize
  ( MaterializeBudget (..)
  , defaultBudget
  , MaterializeOutcome (..)
  , MaterializeError (..)
  , enableFeed
  , materializeOnce
  )
where

import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Events.ChangeOutcome (closureCandidate, failureCandidate, loadReviewDocument)
import Nagare.Events.Envelope
import Nagare.Events.Layout
import Nagare.Events.Receipts (readReceiptChain)
import Nagare.Events.Source
import Nagare.Events.Store
import Nagare.Inventory.Journal (TransactionId, reviewDigestOf, transactionIdText)
import Nagare.Inventory.Plan.CloseRecord (loadCloseRecord)
import Nagare.Inventory.Plan.Types (ReviewDocument)
import Nagare.Inventory.Store (InventoryStore)
import Nagare.Resource.Types

-- | How much one cycle may take on: journal events read, envelopes published
-- and envelope bytes written.
data MaterializeBudget = MaterializeBudget
  { journal :: !Int
  , events :: !Int
  , bytes :: !Int
  }
  deriving stock (Eq, Show, Generic)

defaultBudget :: MaterializeBudget
defaultBudget = MaterializeBudget 500 500 (4 * 1024 * 1024)

data MaterializeOutcome = MaterializeOutcome
  { published :: !Int
  , repeated :: !Int
  -- ^ Candidates whose event was already in the feed.
  , checkpoint :: !SourceCheckpoint
  , count :: !Integer
  , wrote :: !Bool
  , waiting :: !Bool
  -- ^ The source chain stopped at a convergence it cannot decide yet.
  , behind :: !Bool
  -- ^ The cycle stopped at its budget with committed sources left.
  , blocked :: !(Maybe Text)
  -- ^ The cycle stopped at a journal stop it could not resolve, and why.
  }
  deriving stock (Eq, Show, Generic)

data MaterializeError
  = MaterializeFeed !FeedError
  | MaterializeSource !SourceChainError
  | MaterializeContended
  deriving stock (Eq, Show)

-- | Create the feed head for a context, starting at @from@. Enabling an
-- enabled feed of the same context returns its head unchanged.
enableFeed :: FeedStore -> ContextBinding -> Text -> SourceCheckpoint -> IO (Either FeedError FeedHead)
enableFeed store binding epoch from = attempt (3 :: Int)
  where
    initial = FeedHead feedHeadVersion binding epoch 0 0 Nothing Nothing Nothing from initialCheckpoint
    attempt remaining = do
      observed <- observeFeed store binding
      case observed of
        Left err -> pure (Left err)
        Right current | Just headValue <- observedFeedHead current -> pure (Right headValue)
        Right current -> do
          replaced <- replaceFeedHead store current initial
          case replaced of
            Right Replaced -> pure (Right initial)
            -- Another writer created it, or this write did not land: read again.
            _ | remaining > 1 -> attempt (remaining - 1)
            Left err -> pure (Left err)
            Right Superseded -> readFeedHead store binding

-- | One materialization cycle. A head another writer replaced first is
-- reread and the cycle retried, at most three times.
materializeOnce :: InventoryStore -> FeedStore -> ContextBinding -> MaterializeBudget -> IO Text -> IO (Either MaterializeError MaterializeOutcome)
materializeOnce inventory store binding budget clock = attempt (3 :: Int)
  where
    attempt remaining = do
      result <- cycleOnce
      case result of
        Right (Just outcome) -> pure (Right outcome)
        Right Nothing
          | remaining > 1 -> attempt (remaining - 1)
          | otherwise -> pure (Left MaterializeContended)
        Left err -> pure (Left err)
    cycleOnce = do
      observedResult <- observeFeed store binding
      case observedResult >>= \observed -> maybe (Left FeedNotEnabled) (Right . (,) observed) (observedFeedHead observed) of
        Left err -> pure (Left (MaterializeFeed err))
        Right (observed, headValue) -> do
          chain <- readSourceChain inventory (headValue ^. #journal) (budget ^. #journal)
          receiptChain <- readReceiptChain store binding (headValue ^. #receipts) (budget ^. #journal)
          case (chain, receiptChain) of
            (Left err, _) -> pure (Left (MaterializeSource err))
            (_, Left err) -> pure (Left (MaterializeFeed err))
            (Right batch, Right receiptBatch) -> do
              resolved <- resolveJournal inventory (budget ^. #journal) (headValue ^. #journal) batch
              publish observed headValue batch resolved receiptBatch
    publish observed headValue batch resolved receiptBatch = do
      let units =
            resolved ^. #units
              <> [ Unit (observation ^. #observedAt) (observation ^. #events) Nothing (Just (SourceCheckpoint (after ^. #next - 1) (observation ^. #previous)))
                 | (after, observation) <- receiptBatch ^. #observations
                 ]
          (taken, cutAt) = within units
          journalEnd = resolved ^. #through
          (journal', receipts') = case cutAt of
            Nothing -> (journalEnd, receiptBatch ^. #checkpoint)
            Just unit -> case (unit ^. #journalBefore, unit ^. #receiptsBefore) of
              (Just before, _) -> (before, headValue ^. #receipts)
              (_, Just before) -> (journalEnd, before)
              _ -> (headValue ^. #journal, headValue ^. #receipts)
          cutJournal = maybe False (isJust . (^. #journalBefore)) cutAt || resolved ^. #halted
          blocked = if cutJournal && isJust cutAt then Nothing else resolved ^. #blocked
          behind = isJust cutAt || (resolved ^. #halted && isNothing (resolved ^. #blocked))
          context = binding ^. #identity
          candidates = [(unit ^. #observedAt, candidate) | unit <- taken, candidate <- unit ^. #candidates]
          ordered = dedupe Set.empty [(eventIdFor context (candidate ^. #key), pair) | pair@(_, candidate) <- candidates]
          dedupe _ [] = []
          dedupe seen ((eventId, pair) : rest)
            | Set.member eventId seen = dedupe seen rest
            | otherwise = (eventId, pair) : dedupe (Set.insert eventId seen) rest
          idle = MaterializeOutcome 0 0 (headValue ^. #journal) (headValue ^. #count) False (batch ^. #waiting && not cutJournal) behind blocked
      if null candidates && journal' == headValue ^. #journal && receipts' == headValue ^. #receipts
        then pure (Right (Just idle))
        else do
          known <- lookupIds store (headValue ^. #ids) (map fst ordered)
          case known of
            Left err -> pure (Left (MaterializeFeed err))
            Right existing -> do
              now <- clock
              let fresh = [(eventId, pair) | (eventId, pair) <- ordered, Map.notMember eventId existing]
                  envelopes = [envelopeFor context observedAt now candidate | (_, (observedAt, candidate)) <- fresh]
              appended <- appendEnvelopes store headValue envelopes
              case appended of
                Left err -> pure (Left (MaterializeFeed err))
                Right (tailDigest, completedDigest) -> do
                  let positions = zip (map fst fresh) [headValue ^. #count ..]
                  idsRoot <- insertIds store (headValue ^. #ids) positions
                  case idsRoot of
                    Left err -> pure (Left (MaterializeFeed err))
                    Right root -> do
                      let replacement =
                            headValue
                              { generation = headValue ^. #generation + 1
                              , count = headValue ^. #count + fromIntegral (length envelopes)
                              , tail = tailDigest
                              , completed = completedDigest
                              , ids = root
                              , journal = journal'
                              , receipts = receipts'
                              }
                      replaced <- replaceFeedHead store observed replacement
                      pure $ case replaced of
                        Left err -> Left (MaterializeFeed err)
                        Right Superseded -> Right Nothing
                        Right Replaced ->
                          Right
                            ( Just
                                ( MaterializeOutcome
                                    (length envelopes)
                                    (length candidates - length envelopes)
                                    journal'
                                    (replacement ^. #count)
                                    True
                                    (batch ^. #waiting && not cutJournal)
                                    behind
                                    blocked
                                )
                            )
    -- Take whole units while they fit the event and byte budgets; the
    -- first always fits, so a cycle always progresses. The unit a cycle
    -- stops at names the checkpoint before it.
    within units = go [] (0 :: Int) (0 :: Int) units
      where
        go kept _ _ [] = (reverse kept, Nothing)
        go kept eventsSoFar bytesSoFar (unit : rest) =
          let candidates = unit ^. #candidates
              size = sum [BS.length (encodeLayout candidate) | candidate <- candidates]
              fits = null kept || (eventsSoFar + length candidates <= budget ^. #events && bytesSoFar + size <= budget ^. #bytes)
           in if fits
                then go (unit : kept) (eventsSoFar + length candidates) (bytesSoFar + size) rest
                else (reverse kept, Just unit)

-- | The journal's units of one cycle, in journal order: a convergence's
-- facts, or one stop's candidate built from what it names. @through@ is the
-- checkpoint they reach: the batch's own, or the one before a stop the cycle
-- did not take, because its reads would pass the budget (@blocked@ is
-- 'Nothing') or what it names cannot be read (@blocked@ says why).
data Resolved = Resolved
  { units :: ![Unit]
  , through :: !SourceCheckpoint
  , halted :: !Bool
  , blocked :: !(Maybe Text)
  }
  deriving stock (Generic)

resolveJournal :: InventoryStore -> Int -> SourceCheckpoint -> SourceBatch -> IO Resolved
resolveJournal inventory budget from batch = go [] Map.empty (0 :: Int) (journalSources batch)
  where
    go kept _ _ [] = pure (Resolved (reverse kept) (batch ^. #checkpoint) False Nothing)
    go kept reviews reads (item : rest) = case item of
      ConvergedSource source ->
        go (Unit (source ^. #convergedAt) (source ^. #facts . #events) (Just (SourceCheckpoint (source ^. #journalSequence) (source ^. #previous))) Nothing : kept) reviews reads rest
      StoppedSource stop -> do
        let before = SourceCheckpoint (stop ^. #journalSequence) (stop ^. #previous)
            fresh = case stop ^. #kind of
              StopClosed _ -> 1
              _ | Map.member (stop ^. #transaction) reviews -> 0
              _ -> 1
            cost = fromIntegral (stop ^. #journalSequence - from ^. #next + 1) + reads + fresh
            halt reason = pure (Resolved (reverse kept) before True reason)
        -- The first unit always fits, so a cycle always progresses.
        if cost > budget && not (null kept)
          then halt Nothing
          else do
            built <- candidateOf reviews stop
            case built of
              Left reason -> halt (Just ("journal event " <> T.pack (show (stop ^. #journalSequence)) <> ": " <> reason))
              Right (candidate, reviews') -> go (Unit (stop ^. #recordedAt) [candidate] (Just before) Nothing : kept) reviews' (reads + fresh) rest
    candidateOf :: Map.Map TransactionId ReviewDocument -> CommittedStop -> IO (Either Text (EventCandidate, Map.Map TransactionId ReviewDocument))
    candidateOf reviews stop = case stop ^. #kind of
      StopClosed recordDigest -> do
        loaded <- loadCloseRecord inventory recordDigest
        pure (loaded >>= fmap (,reviews) . closureCandidate stop recordDigest)
      _ -> case reviewDigestOf transaction of
        Nothing -> pure (Left ("the transaction " <> transactionIdText transaction <> " names no review"))
        Just digest -> do
          document <- maybe (loadReviewDocument inventory digest) (pure . Right) (Map.lookup transaction reviews)
          pure (document >>= \found -> (,Map.insert transaction found reviews) <$> failureCandidate stop found)
      where
        transaction = stop ^. #transaction

-- | One committed source a cycle may take: a journal convergence or a
-- collector observation, its observation time, its candidates and the
-- checkpoint of the chain it belongs to before it.
data Unit = Unit
  { observedAt :: !Text
  , candidates :: ![EventCandidate]
  , journalBefore :: !(Maybe SourceCheckpoint)
  , receiptsBefore :: !(Maybe SourceCheckpoint)
  }
  deriving stock (Generic)

-- | Publish the segments and index nodes that hold the feed plus
-- @envelopes@, returning the new tail node and completed list digests.
appendEnvelopes :: FeedStore -> FeedHead -> [Envelope] -> IO (Either FeedError (Maybe ContentDigest, Maybe ContentDigest))
appendEnvelopes _ headValue [] = pure (Right (headValue ^. #tail, headValue ^. #completed))
appendEnvelopes store headValue envelopes = do
  let existing = headValue ^. #count
      firstSegment = existing `div` segmentCapacity
  locator <- newLocator store headValue
  -- The partial last segment, if any, is rewritten with the new envelopes.
  partial <-
    if existing `mod` segmentCapacity == 0
      then pure (Right [])
      else do
        digest <- locateSegment locator firstSegment
        case digest of
          Left err -> pure (Left err)
          Right found -> fmap (^. #entries) <$> loadSegment store firstSegment found
  tailNode <- case headValue ^. #tail of
    Nothing -> pure (Right (IndexNode 0 []))
    Just digest -> (>>= decodeLayout "index") <$> readFeedObject store indexKey digest
  completedNodes <- case headValue ^. #completed of
    Nothing -> pure (Right [])
    Just digest -> fmap (\(Completed listed) -> listed) . (>>= decodeLayout "completed") <$> readFeedObject store indexKey digest
  case (,,) <$> partial <*> tailNode <*> completedNodes of
    Left err -> pure (Left err)
    Right (kept, node, listed) -> do
      let chunks = chunked (kept <> envelopes)
          numbered = zip [firstSegment ..] chunks
      written <- traverse (\(k, chunk) -> fmap ((,) k) <$> publishFeedObject store segmentKey (encodeLayout (Segment (k * segmentCapacity) chunk))) numbered
      case sequence written of
        Left err -> pure (Left err)
        Right segmentDigests -> placeAll listed node listed segmentDigests
  where
    chunked [] = []
    chunked items = let (now, later) = splitAt (fromIntegral segmentCapacity) items in now : chunked later
    -- Put each segment digest into its index node, completing full nodes.
    placeAll original node listed [] = finish original node listed
    placeAll original node listed ((k, digest) : rest)
      | k `div` leafCapacity /= node ^. #number = do
          completedDigest <- publishFeedObject store indexKey (encodeLayout node)
          case completedDigest of
            Left err -> pure (Left err)
            Right done -> placeAll original (IndexNode (k `div` leafCapacity) []) (listed <> [done]) ((k, digest) : rest)
      | otherwise =
          let slot = fromIntegral (k `mod` leafCapacity)
              segments' = take slot (node ^. #segments) <> [digest]
           in placeAll original node {segments = segments'} listed rest
    -- An unchanged completed list keeps the head's digest: nothing to write.
    finish original node listed = do
      tailDigest <- publishFeedObject store indexKey (encodeLayout node)
      completedDigest <-
        if listed == original
          then pure (Right (headValue ^. #completed))
          else fmap Just <$> publishFeedObject store indexKey (encodeLayout (Completed listed))
      pure ((,) <$> fmap Just tailDigest <*> completedDigest)
