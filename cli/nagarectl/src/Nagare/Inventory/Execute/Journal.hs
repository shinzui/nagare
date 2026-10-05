{-# LANGUAGE RankNTypes #-}

-- | Journal responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.Journal
  ( appendEvent
  , readJournal
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
  ( JournalEvent
      ( JournalEvent
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
  , decodeJournalEvent
  , encodeJournalEvent
  , journalEventDigest
  , operationIdText
  , transactionIdText
  , validateJournal
  )
import Nagare.Inventory.Store
  ( ExecutorClaim (claimClientIdentity, claimTransaction)
  , HeadManifest (headExecutorClaim, headGeneration, headSequence)
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
  )
import Nagare.Resource.Types (ContentDigest, mkContentDigest)
import System.IO (stderr)

-- | Append one event and commit it by advancing the head. A failure reports
-- the store's own error on stderr, so an operator can tell a refused
-- precondition from a transport failure (F38).
appendEvent :: LockedStore s -> TransactionId -> Maybe OperationId -> OperationState -> Text -> IO (Either StoreError JournalEvent)
appendEvent locked transaction operation state detail = do
  result <- appendEventAt orphanBudget locked transaction operation state detail
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

appendEventAt :: Int -> LockedStore s -> TransactionId -> Maybe OperationId -> OperationState -> Text -> IO (Either StoreError JournalEvent)
appendEventAt orphanBudget locked transaction operation state detail = do
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
              let event = JournalEvent 1 (headSequence headValue) prior transaction operation state now detail
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
                                    appendEventAt (orphanBudget - 1) locked transaction operation state detail
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
  let replacement = headValue {headGeneration = headGeneration headValue + 1, headSequence = headSequence headValue + 1}
  replaced <- replaceObservedHead observed replacement
  case replaced of
    Right () -> pure (Right event)
    Left err -> do
      reread <- observeHead store
      case reread of
        Right now
          | observedHeadManifest now == Just replacement -> pure (Right event)
          | observedHeadManifest now == Just headValue && retries > 0 -> do
              threadDelay (250000 * (4 - retries))
              commitHead store now headValue event (retries - 1)
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
