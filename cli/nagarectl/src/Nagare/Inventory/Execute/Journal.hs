{-# LANGUAGE RankNTypes #-}

-- | Journal responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.Journal
  ( appendEvent
  , appendEventWith
  , commitConvergence
  , readJournal
  , retryPause
  , readJournalAtHead
  , rollbackProof
  , rollbackProvedOperation
  , transactionConverged
  )
where

import Control.Concurrent (threadDelay)
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Prelude
import Nagare.Inventory.Execute.Types (timestamp)
import Nagare.Inventory.Journal
  ( Convergence (convergedReview)
  , JournalEvent
    ( JournalEvent
    , eventConvergence
    , eventDetail
    , eventOperation
    , eventPreviousDigest
    , eventSequence
    , eventState
    , eventTransaction
    )
  , OperationId
  , OperationState (Completed, OperatorResolved)
  , TransactionId
  , convergenceSchemaVersion
  , decodeJournalEvent
  , encodeJournalEvent
  , journalEventDigest
  , operationIdText
  , transactionIdText
  , validateJournal
  )
import Nagare.Inventory.Store
  ( ExecutorClaim (claimClientIdentity, claimTransaction)
  , HeadManifest (headExecutorClaim, headGeneration, headSchemaVersion, headSequence)
  , InventoryStore
  , LockedStore
  , ObservedHead
  , StoreError
    ( StoreConditionFailed
    , StoreInvalidObject
    , StoreObjectConflict
    )
  , appendAtObservedHead
  , journalKey
  , lockedStore
  , observeHead
  , observedHeadManifest
  , readHead
  , readJournalPrefix
  , readObject
  , replaceObservedHead
  , storeClientIdentity
  , storeRetryPause
  )
import Nagare.Resource.Types (ContentDigest, PhysicalIdentity, mkContentDigest)
import System.IO (stderr)

-- | Append one event and commit it by advancing the head. A failure reports
-- the store's own error on stderr, so an operator can tell a refused
-- precondition from a transport failure (F38).
appendEvent :: LockedStore s -> TransactionId -> Maybe OperationId -> OperationState -> Text -> IO (Either StoreError JournalEvent)
appendEvent = appendEventWith Nothing

-- | 'appendEvent', recording the identity the provider returned for the
-- object the operation wrote (ADR 27).
appendEventWith :: Maybe PhysicalIdentity -> LockedStore s -> TransactionId -> Maybe OperationId -> OperationState -> Text -> IO (Either StoreError JournalEvent)
appendEventWith physical locked transaction operation state detail = do
  result <- appendEventAt orphanBudget physical locked transaction operation state detail
  case result of
    Left err ->
      TIO.hPutStrLn stderr $
        "nagarectl: inventory journal append for "
          <> transactionIdText transaction
          <> maybe "" ((" at " <>) . operationIdText) operation
          <> " failed: "
          <> T.pack (show err)
    Right _ -> pure ()
  pure result
  where
    orphanBudget = 2 :: Int

appendEventAt :: Int -> Maybe PhysicalIdentity -> LockedStore s -> TransactionId -> Maybe OperationId -> OperationState -> Text -> IO (Either StoreError JournalEvent)
appendEventAt orphanBudget physical locked transaction operation state detail = do
  let store = lockedStore locked
  headResult <- observeHead store
  case headResult of
    Left err -> pure (Left err)
    Right observed
      | Nothing <- observedHeadManifest observed ->
          pure (Left (StoreConditionFailed "inventory store is not initialized"))
    Right observed | Just headValue <- observedHeadManifest observed -> do
      let claimed = case storeClientIdentity store of
            Nothing -> True
            Just client -> case headExecutorClaim headValue of
              Just owner ->
                claimClientIdentity owner == client
                  && claimTransaction owner == transactionIdText transaction
              Nothing -> False
      if not claimed
        then pure (Left (StoreConditionFailed "inventory executor claim belongs to another client"))
        else do
          previous <- previousDigest store (headSequence headValue)
          case previous of
            Left err -> pure (Left err)
            Right prior -> do
              now <- timestamp
              let event = JournalEvent 1 (headSequence headValue) prior transaction operation state now detail physical Nothing
                  key = journalKey (headSequence headValue)
              published <- appendAtObservedHead store headValue (encodeJournalEvent event)
              case published of
                Right _ -> commitHead store observed headValue event headRetries
                Left (StoreObjectConflict _) -> do
                  existing <- readObject store key
                  case existing of
                    Left err -> pure (Left err)
                    Right Nothing -> pure (Left (StoreInvalidObject key "conflicting journal event is missing"))
                    Right (Just bytes) -> case decodeJournalEvent bytes of
                      Left err -> pure (Left (StoreInvalidObject key err))
                      Right old
                        | not (orphanOfThisChain old event) -> pure (Left (StoreObjectConflict key))
                        | otherwise -> do
                            -- The event at the head's next sequence was published
                            -- by this transaction but never committed: its head
                            -- write failed (F38). Commit it as history rather than
                            -- wedge every later append at this sequence.
                            committed <- commitHead store observed headValue old headRetries
                            case committed of
                              Left err -> pure (Left err)
                              Right _
                                | sameEventMeaning old event || sameCompletion old event -> pure (Right old)
                                | orphanBudget > 0 ->
                                    appendEventAt (orphanBudget - 1) physical locked transaction operation state detail
                                | otherwise -> pure (Left (StoreObjectConflict key))
                Left err -> pure (Left err)
    Right _ -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
  where
    headRetries = 3 :: Int
    orphanOfThisChain old new =
      eventSequence old == eventSequence new
        && eventPreviousDigest old == eventPreviousDigest new
        && eventTransaction old == eventTransaction new
    sameEventMeaning left right =
      orphanOfThisChain left right
        && eventOperation left == eventOperation right
        && eventState left == eventState right
    -- A verified execution receipt and an independent recovery proof of the
    -- same operation are both completions, even when their digests differ.
    -- Keep the orphan's original receipt.
    sameCompletion left right =
      orphanOfThisChain left right
        && isJust (eventOperation left)
        && eventOperation left == eventOperation right
        && isCompleted (eventState left)
        && isCompleted (eventState right)
    isCompleted (Completed _) = True
    isCompleted _ = False

-- | Advance the head over a published event. A failed conditional write may
-- still have landed (an unknown outcome) or have been refused transiently,
-- so reread the head: if it already commits this event, the append
-- succeeded; if it is unchanged, and so still carries this executor's claim,
-- retry the conditional write a bounded number of times. Otherwise stop with
-- the store's original error.
commitHead :: InventoryStore -> ObservedHead -> HeadManifest -> JournalEvent -> Int -> IO (Either StoreError JournalEvent)
commitHead store observed headValue event retries = do
  let replacement = (advancedOver event headValue) {headGeneration = headGeneration headValue + 1, headSequence = headSequence headValue + 1}
  replaced <- replaceObservedHead observed replacement
  case replaced of
    Right () -> pure (Right event)
    Left err -> do
      reread <- observeHead store
      case reread of
        Right now
          | observedHeadManifest now == Just replacement -> pure (Right event)
          | observedHeadManifest now == Just headValue && retries > 0 -> do
              retryPause store retries
              commitHead store now headValue event (retries - 1)
        _ -> pure (Left err)

-- | Wait before retrying a refused head write, longer each time: 250, 500,
-- then 750 ms with three retries left, then two, then one. A store whose
-- backend sets its own pause (the recovery model's) waits that way instead.
retryPause :: InventoryStore -> Int -> IO ()
retryPause store retries = fromMaybe threadDelay (storeRetryPause store) (250000 * (4 - retries))

-- | A head that commits a convergence event has wire version 2, which a
-- version 1 CLI refuses at head read (EP-231). An adopted orphan raises it too.
advancedOver :: JournalEvent -> HeadManifest -> HeadManifest
advancedOver event headValue
  | isJust (eventConvergence event) = headValue {headSchemaVersion = max convergenceSchemaVersion (headSchemaVersion headValue)}
  | otherwise = headValue

-- | EP-231: commit a converged release. Publish its convergence event at the
-- head's next sequence, then replace the head with @released@ advanced over
-- it, so the event and the cleared claim land in one conditional write. A
-- convergence event this transaction already published there, whose release
-- did not land, is committed instead of a new one. An unknown or refused head
-- write is settled like 'commitHead': reread, and retry while the head is
-- unchanged. @known@ is the event at the previous sequence, when the caller
-- has it, which spares a read.
commitConvergence :: InventoryStore -> ObservedHead -> HeadManifest -> HeadManifest -> TransactionId -> Convergence -> Maybe JournalEvent -> IO (Either StoreError JournalEvent)
commitConvergence store observed headValue released transaction convergence known = do
  previous <- case known of
    Just event | eventSequence event + 1 == headSequence headValue -> pure (Right (Just (journalEventDigest event)))
    _ -> previousDigest store (headSequence headValue)
  case previous of
    Left err -> pure (Left err)
    Right prior -> do
      now <- timestamp
      let fresh =
            JournalEvent
              convergenceSchemaVersion
              (headSequence headValue)
              prior
              transaction
              Nothing
              (Completed (convergedReview convergence))
              now
              "transaction released converged"
              Nothing
              (Just convergence)
          key = journalKey (headSequence headValue)
      published <- appendAtObservedHead store headValue (encodeJournalEvent fresh)
      chosen <- case published of
        Right _ -> pure (Right fresh)
        Left (StoreObjectConflict _) -> do
          existing <- readObject store key
          pure $ case existing of
            Left err -> Left err
            Right Nothing -> Left (StoreInvalidObject key "conflicting journal event is missing")
            Right (Just bytes) -> case decodeJournalEvent bytes of
              Left err -> Left (StoreInvalidObject key err)
              Right old
                | eventPreviousDigest old == prior
                , eventTransaction old == transaction
                , fmap convergedReview (eventConvergence old) == Just (convergedReview convergence) ->
                    Right old
                | otherwise -> Left (StoreObjectConflict key)
        Left err -> pure (Left err)
      case chosen of
        Left err -> pure (Left err)
        Right event -> settle observed event releaseRetries
  where
    releaseRetries = 3 :: Int
    replacement event =
      (advancedOver event released)
        { headGeneration = headGeneration headValue + 1
        , headSequence = headSequence headValue + 1
        }
    settle current event retries = do
      replaced <- replaceObservedHead current (replacement event)
      case replaced of
        Right () -> pure (Right event)
        Left err -> do
          reread <- observeHead store
          case reread of
            Right now
              | observedHeadManifest now == Just (replacement event) -> pure (Right event)
              | observedHeadManifest now == Just headValue && retries > 0 -> do
                  retryPause store retries
                  settle now event (retries - 1)
            _ -> pure (Left err)

previousDigest :: InventoryStore -> Integer -> IO (Either StoreError (Maybe ContentDigest))
previousDigest _ 0 = pure (Right Nothing)
previousDigest store sequenceNumber = do
  loaded <- readObject store (journalKey (sequenceNumber - 1))
  pure $ do
    bytes <- loaded >>= maybe (Left (StoreInvalidObject (journalKey (sequenceNumber - 1)) "previous journal event is missing")) Right
    event <- first (StoreInvalidObject (journalKey (sequenceNumber - 1))) (decodeJournalEvent bytes)
    pure (Just (journalEventDigest event))

readJournal :: LockedStore s -> IO (Either StoreError [JournalEvent])
readJournal locked = do
  let store = lockedStore locked
  headResult <- readHead store
  case headResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
    Right (Just headValue) -> readJournalAtHead store headValue

-- The command already observed this committed prefix. Keep that boundary for
-- decoding/hash-chain validation; a later writer-claim CAS still checks freshness.
readJournalAtHead :: InventoryStore -> HeadManifest -> IO (Either StoreError [JournalEvent])
readJournalAtHead store headValue = do
  loaded <- readJournalPrefix store (headSequence headValue)
  pure $ do
    bytes <- loaded
    events <- traverse (first (StoreInvalidObject "journal") . decodeJournalEvent) bytes
    first (StoreInvalidObject "journal") (validateJournal events)

-- | This journal proof is written before writer release. If the process dies
-- after release, a later recovery or resume can close the abandoned review
-- without replaying its original data effect.
rollbackProof ::
  TransactionId ->
  OperationId ->
  [JournalEvent] ->
  Maybe ContentDigest
rollbackProof transaction operation events =
  listToMaybe
    [ proof
    | event <- reverse events
    , eventTransaction event == transaction
    , eventOperation event == Just operation
    , OperatorResolved marker <- [eventState event]
    , Just token <- [T.stripPrefix "fenced-recovery-proved:" marker]
    , Right proof <- [mkContentDigest token]
    ]

rollbackProvedOperation :: TransactionId -> [JournalEvent] -> Maybe OperationId
rollbackProvedOperation transaction events =
  listToMaybe
    [ operation
    | event <- reverse events
    , eventTransaction event == transaction
    , Just operation <- [eventOperation event]
    , isJust (rollbackProof transaction operation events)
    ]

transactionConverged :: TransactionId -> [JournalEvent] -> Bool
transactionConverged transaction = any (\event -> eventTransaction event == transaction && isNothing (eventOperation event) && "converged" `T.isInfixOf` eventDetail event)
