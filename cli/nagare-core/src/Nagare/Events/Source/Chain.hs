{-# LANGUAGE OverloadedStrings #-}

-- | Reading committed lifecycle sources from the inventory journal (EP-231).
-- Implementation behind "Nagare.Events.Source".
--
-- A converged release appends its convergence event in the head replacement
-- that clears its claim. If that head write fails, the event stays an
-- uncommitted orphan, and a later append by the same transaction may commit
-- it as ordinary history while the transaction stays active. Such an adopted
-- event is not a source. The rule that tells them apart: while a transaction
-- is active, only its own events are appended, so a convergence event is a
-- committed source exactly when the next event belongs to another
-- transaction, or when it is the last event and its transaction is no longer
-- active. It is never a source when the next event is its own transaction's.
--
-- EP-276: a committed event that records an operation's failure or unknown
-- outcome, or the close of its transaction, is a source too. Every event
-- below the head's sequence was committed by a head replacement, and an
-- adopted orphan is history the executor itself acts on, so no rule beyond
-- that is needed.
module Nagare.Events.Source.Chain
  ( SourceCheckpoint (..)
  , initialCheckpoint
  , CommittedSource (..)
  , StopKind (..)
  , CommittedStop (..)
  , JournalSource (..)
  , journalSources
  , SourceBatch (..)
  , SourceChainError (..)
  , readSourceChain
  , tipCheckpoint
  , ControlStep (..)
  , consumeControls
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Source.Facts
import Nagare.Inventory.Journal
  ( Convergence (convergedFacts, convergedReview)
  , FailureClass
  , JournalEvent (eventConvergence, eventDetail, eventOperation, eventPreviousDigest, eventSequence, eventState, eventTimestamp, eventTransaction)
  , OperationId
  , OperationState (Ambiguous, Failed, OperatorResolved)
  , TransactionId
  , decodeJournalEvent
  , journalEventDigest
  , transactionIdText
  )
import Nagare.Inventory.Plan.CloseRecord (closedMarker)
import Nagare.Inventory.Store
  ( HeadManifest (headActiveTransaction, headMigration, headSequence, headTransition)
  , InventoryStore
  , StoreError
  , journalKey
  , readHead
  , readImmutableObjects
  , readImmutableObjectsEach
  , readObject
  )
import Nagare.Resource.Types (ContentDigest, mkContentDigest)

-- | Where a consumer resumes: the next journal sequence it has not decided,
-- and the digest of the event before it, so the suffix is linked to what the
-- consumer already read without reading it again.
data SourceCheckpoint = SourceCheckpoint
  { next :: !Integer
  , previous :: !(Maybe ContentDigest)
  }
  deriving stock (Eq, Show, Generic)

initialCheckpoint :: SourceCheckpoint
initialCheckpoint = SourceCheckpoint 0 Nothing

-- | A committed convergence that carries source facts.
data CommittedSource = CommittedSource
  { journalSequence :: !Integer
  , previous :: !(Maybe ContentDigest)
  -- ^ The digest of the journal event before it.
  , transaction :: !TransactionId
  , convergedAt :: !Text
  -- ^ The committed convergence event's time: its events' occurrence and
  -- observation time unless a candidate names its own occurrence.
  , facts :: !SourceFacts
  }
  deriving stock (Eq, Show, Generic)

-- | How a committed journal event stopped or ended a change (EP-276).
data StopKind
  = StopFailed !FailureClass
  | StopAmbiguous
  | -- | The close of the transaction, by the digest of its close record.
    StopClosed !ContentDigest
  deriving stock (Eq, Show, Generic)

-- | A committed journal event that records a stop or a close.
data CommittedStop = CommittedStop
  { journalSequence :: !Integer
  , previous :: !(Maybe ContentDigest)
  , digest :: !ContentDigest
  -- ^ The digest of the stop's own journal event.
  , transaction :: !TransactionId
  , operation :: !(Maybe OperationId)
  , kind :: !StopKind
  , detail :: !Text
  , recordedAt :: !Text
  }
  deriving stock (Eq, Show, Generic)

data JournalSource = ConvergedSource !CommittedSource | StoppedSource !CommittedStop
  deriving stock (Eq, Show, Generic)

data SourceBatch = SourceBatch
  { sources :: ![CommittedSource]
  , stops :: ![CommittedStop]
  -- ^ EP-276: the committed stops and closes of the decided prefix.
  , checkpoint :: !SourceCheckpoint
  -- ^ After the decided prefix; resume here.
  , observedSequence :: !Integer
  -- ^ The inventory head's sequence this batch observed.
  , waiting :: !Bool
  -- ^ The batch stopped at a convergence event it cannot decide yet: the
  -- last event, whose transaction is still active.
  , settled :: !Bool
  -- ^ EP-276: the head this batch observed holds no release transition
  -- marker and no active transaction.
  }
  deriving stock (Eq, Show, Generic)

data SourceChainError
  = SourceUninitialized
  | SourceStoreMoved
  | SourceStoreError !StoreError
  | SourceCheckpointAhead !Integer !Integer
  | SourceChainBroken !Integer !Text
  | SourceFactsInvalid !Integer !Text
  deriving stock (Eq, Show)

-- | Decide at most @budget@ journal events after @from@: read the head once,
-- then only the journal suffix after the checkpoint, one event beyond it to
-- decide a convergence at its end, and the facts objects committed sources
-- name. Never the whole journal.
readSourceChain :: InventoryStore -> SourceCheckpoint -> Int -> IO (Either SourceChainError SourceBatch)
readSourceChain store from budget = do
  loadedHead <- readHead store
  case loadedHead of
    Left err -> pure (Left (SourceStoreError err))
    Right Nothing -> pure (Left SourceUninitialized)
    Right (Just headValue)
      | isJust (headMigration headValue) -> pure (Left SourceStoreMoved)
      | from ^. #next > headSequence headValue -> pure (Left (SourceCheckpointAhead (from ^. #next) (headSequence headValue)))
      | otherwise -> do
          let tip = headSequence headValue
              end = min tip (from ^. #next + fromIntegral (max 1 budget))
              wanted = [from ^. #next .. min (tip - 1) end]
          loaded <- readImmutableObjectsEach store (map journalKey wanted)
          case traverse (decodeAt loaded) wanted >>= link (from ^. #previous) of
            Left err -> pure (Left err)
            Right events -> decide headValue end events
  where
    decodeAt loaded sequenceNumber = case Map.lookup (journalKey sequenceNumber) loaded of
      Just (Right (Just bytes)) -> case decodeJournalEvent bytes of
        Right event | eventSequence event == sequenceNumber -> Right event
        Right _ -> Left (SourceChainBroken sequenceNumber "journal event has the wrong sequence")
        Left err -> Left (SourceChainBroken sequenceNumber err)
      Just (Right Nothing) -> Left (SourceChainBroken sequenceNumber "committed journal event is missing")
      Just (Left err) -> Left (SourceStoreError err)
      Nothing -> Left (SourceChainBroken sequenceNumber "committed journal event was not read")
    link _ [] = Right []
    link expected (event : rest)
      | eventPreviousDigest event /= expected = Left (SourceChainBroken (eventSequence event) "journal digest chain is broken")
      | otherwise = (event :) <$> link (Just (journalEventDigest event)) rest
    decide headValue end events = do
      let window = takeWhile ((< end) . eventSequence) events
          following = Map.fromList [(eventSequence event, event) | event <- events]
          tip = headSequence headValue
          verdict event = case eventConvergence event of
            Nothing -> Passed
            Just convergence
              | Just after <- Map.lookup (eventSequence event + 1) following ->
                  if eventTransaction after == eventTransaction event then Passed else Committed convergence
              | eventSequence event + 1 == tip
              , headActiveTransaction headValue /= Just (transactionIdText (eventTransaction event)) ->
                  Committed convergence
              | otherwise -> Undecided
          (decided, stopped) = break ((== Undecided) . verdict) window
          committed = [(event, convergence) | event <- decided, Committed convergence <- [verdict event]]
          named = [(event, digest) | (event, convergence) <- committed, Just digest <- [convergedFacts convergence]]
          resume = case reverse decided of
            lastEvent : _ -> SourceCheckpoint (eventSequence lastEvent + 1) (Just (journalEventDigest lastEvent))
            [] -> from
          stops =
            [ CommittedStop (eventSequence event) (eventPreviousDigest event) (journalEventDigest event) (eventTransaction event) (eventOperation event) kind (eventDetail event) (eventTimestamp event)
            | event <- decided
            , Just kind <- [stopKind event]
            ]
      loadedFacts <- readImmutableObjects store (map (factsKey . snd) named)
      pure $ do
        objects <- first SourceStoreError loadedFacts
        sources <- traverse (source objects committed) named
        pure (SourceBatch sources stops resume tip (not (null stopped)) (isNothing (headTransition headValue) && isNothing (headActiveTransaction headValue)))
    -- A failure or unknown outcome the executor recorded, or the close
    -- marker that commits a close; no other operator resolution ends or
    -- stops a change.
    stopKind event = case eventState event of
      Failed failure -> Just (StopFailed failure)
      Ambiguous -> Just StopAmbiguous
      OperatorResolved marker
        | isNothing (eventOperation event)
        , Just token <- T.stripPrefix closedMarker marker
        , Right digest <- mkContentDigest token ->
            Just (StopClosed digest)
      _ -> Nothing
    source objects committed (event, digest) = do
      let sequenceNumber = eventSequence event
      bytes <- maybe (Left (SourceFactsInvalid sequenceNumber "facts object was not read")) Right (Map.lookup (factsKey digest) objects)
      decoded <- first (SourceFactsInvalid sequenceNumber) (decodeSourceFacts bytes)
      let review = lookup sequenceNumber [(eventSequence e, convergedReview c) | (e, c) <- committed]
      unless (decoded ^. #transaction == eventTransaction event) (Left (SourceFactsInvalid sequenceNumber "facts name another transaction"))
      unless (Just (decoded ^. #review) == review) (Left (SourceFactsInvalid sequenceNumber "facts name another review"))
      pure (CommittedSource sequenceNumber (eventPreviousDigest event) (eventTransaction event) (eventTimestamp event) decoded)

-- | A batch's convergences and stops in journal order.
journalSources :: SourceBatch -> [JournalSource]
journalSources batch = Map.elems (Map.fromList (converged <> stopped))
  where
    converged = [(source ^. #journalSequence, ConvergedSource source) | source <- batch ^. #sources]
    stopped = [(stop ^. #journalSequence, StoppedSource stop) | stop <- batch ^. #stops]

-- | The checkpoint at the journal's current tip: a consumer starting here
-- reads only what is committed after now (EP-233 activation).
tipCheckpoint :: InventoryStore -> IO (Either SourceChainError SourceCheckpoint)
tipCheckpoint store = do
  loadedHead <- readHead store
  case loadedHead of
    Left err -> pure (Left (SourceStoreError err))
    Right Nothing -> pure (Left SourceUninitialized)
    Right (Just headValue)
      | headSequence headValue == 0 -> pure (Right initialCheckpoint)
      | otherwise -> do
          let lastSequence = headSequence headValue - 1
          loaded <- readObject store (journalKey lastSequence)
          pure $ case loaded of
            Left err -> Left (SourceStoreError err)
            Right Nothing -> Left (SourceChainBroken lastSequence "the journal tip is missing")
            Right (Just bytes) -> case decodeJournalEvent bytes of
              Left err -> Left (SourceChainBroken lastSequence err)
              Right event -> Right (SourceCheckpoint (headSequence headValue) (Just (journalEventDigest event)))

data Verdict = Passed | Committed !Convergence | Undecided

instance Eq Verdict where
  Passed == Passed = True
  Undecided == Undecided = True
  Committed left == Committed right = convergedReview left == convergedReview right && convergedFacts left == convergedFacts right
  _ == _ = False

-- | One control consumer's step over a batch: the controls addressed to its
-- channel that it read, and the checkpoint it may record. A control whose
-- version the consumer refuses stops it before that control's source, so the
-- refusal is never acknowledged by advancing past it.
data ControlStep a = ControlStep
  { accepted :: ![a]
  , checkpoint :: !SourceCheckpoint
  , refused :: !(Maybe (SourceKey, Text))
  }
  deriving stock (Generic)

consumeControls :: ControlChannel -> (ControlFact -> Either Text a) -> SourceBatch -> ControlStep a
consumeControls channel decode batch = go [] (batch ^. #sources)
  where
    go kept [] = ControlStep (reverse kept) (batch ^. #checkpoint) Nothing
    go kept (committed : rest) =
      let mine = [control | control <- committed ^. #facts . #controls, control ^. #channel == channel]
       in case traverse (\control -> first ((,) (control ^. #key)) (decode control)) mine of
            Left refusal -> ControlStep (reverse kept) (SourceCheckpoint (committed ^. #journalSequence) (committed ^. #previous)) (Just refusal)
            Right values -> go (reverse values <> kept) rest

instance ToJSON SourceCheckpoint where
  toJSON value = object ["next" .= (value ^. #next), "previous" .= (value ^. #previous)]

instance FromJSON SourceCheckpoint where
  parseJSON = withObject "source checkpoint" $ \o -> do
    unless (all (`elem` ["next", "previous"]) (KM.keys o)) (fail "source checkpoint has an unknown field")
    value <- SourceCheckpoint <$> o .: "next" <*> o .: "previous"
    unless (value ^. #next >= 0) (fail "a source checkpoint sequence must not be negative")
    when (value ^. #next == 0 && isJust (value ^. #previous)) (fail "the first source checkpoint has no previous event")
    when (value ^. #next > 0 && isNothing (value ^. #previous)) (fail "a source checkpoint names the event before it")
    pure value
