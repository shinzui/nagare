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
module Nagare.Events.Source.Chain
  ( SourceCheckpoint (..)
  , initialCheckpoint
  , CommittedSource (..)
  , SourceBatch (..)
  , SourceChainError (..)
  , readSourceChain
  , ControlStep (..)
  , consumeControls
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Source.Facts
import Nagare.Inventory.Journal
  ( Convergence (convergedFacts, convergedReview)
  , JournalEvent (eventConvergence, eventPreviousDigest, eventSequence, eventTransaction)
  , TransactionId
  , decodeJournalEvent
  , journalEventDigest
  , transactionIdText
  )
import Nagare.Inventory.Store
  ( HeadManifest (headActiveTransaction, headMigration, headSequence)
  , InventoryStore
  , StoreError
  , journalKey
  , readHead
  , readImmutableObjects
  , readImmutableObjectsEach
  )
import Nagare.Resource.Types (ContentDigest)

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
  { sequence :: !Integer
  , previous :: !(Maybe ContentDigest)
  -- ^ The digest of the journal event before it.
  , transaction :: !TransactionId
  , facts :: !SourceFacts
  }
  deriving stock (Eq, Show, Generic)

data SourceBatch = SourceBatch
  { sources :: ![CommittedSource]
  , checkpoint :: !SourceCheckpoint
  -- ^ After the decided prefix; resume here.
  , observedSequence :: !Integer
  -- ^ The inventory head's sequence this batch observed.
  , waiting :: !Bool
  -- ^ The batch stopped at a convergence event it cannot decide yet: the
  -- last event, whose transaction is still active.
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
      loadedFacts <- readImmutableObjects store (map (factsKey . snd) named)
      pure $ do
        objects <- first SourceStoreError loadedFacts
        sources <- traverse (source objects committed) named
        pure (SourceBatch sources resume tip (not (null stopped)))
    source objects committed (event, digest) = do
      let sequenceNumber = eventSequence event
      bytes <- maybe (Left (SourceFactsInvalid sequenceNumber "facts object was not read")) Right (Map.lookup (factsKey digest) objects)
      decoded <- first (SourceFactsInvalid sequenceNumber) (decodeSourceFacts bytes)
      let review = lookup sequenceNumber [(eventSequence e, convergedReview c) | (e, c) <- committed]
      unless (decoded ^. #transaction == eventTransaction event) (Left (SourceFactsInvalid sequenceNumber "facts name another transaction"))
      unless (Just (decoded ^. #review) == review) (Left (SourceFactsInvalid sequenceNumber "facts name another review"))
      pure (CommittedSource sequenceNumber (eventPreviousDigest event) (eventTransaction event) decoded)

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
            Left refusal -> ControlStep (reverse kept) (SourceCheckpoint (committed ^. #sequence) (committed ^. #previous)) (Just refusal)
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
