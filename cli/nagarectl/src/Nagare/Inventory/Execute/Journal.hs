{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

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

import Data.Maybe (listToMaybe)
import Data.Text qualified as T
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
  , OperationState (OperatorResolved)
  , TransactionId
  , decodeJournalEvent
  , encodeJournalEvent
  , journalEventDigest
  , transactionIdText
  , validateJournal
  )
import Nagare.Inventory.Store
  ( ExecutorClaim (claimClientIdentity, claimTransaction)
  , HeadManifest (headExecutorClaim, headGeneration, headSequence)
  , InventoryStore
  , LockedStore
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

appendEvent :: LockedStore s -> TransactionId -> Maybe OperationId -> OperationState -> Text -> IO (Either StoreError JournalEvent)
appendEvent locked transaction operation state detail = do
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
                Right _ -> advance observed headValue event
                Left (StoreObjectConflict _) -> do
                  existing <- readObject store key
                  case existing of
                    Left err -> pure (Left err)
                    Right Nothing -> pure (Left (StoreInvalidObject key "conflicting journal event is missing"))
                    Right (Just bytes) -> case decodeJournalEvent bytes of
                      Left err -> pure (Left (StoreInvalidObject key err))
                      Right old
                        | sameEventMeaning old event -> advance observed headValue old
                        | otherwise -> pure (Left (StoreObjectConflict key))
                Left err -> pure (Left err)
    Right _ -> pure (Left (StoreConditionFailed "inventory store is not initialized"))
  where
    advance observed headValue event = do
      let replacement = headValue {headGeneration = headGeneration headValue + 1, headSequence = headSequence headValue + 1}
      replaced <- replaceObservedHead observed replacement
      pure (event <$ replaced)
    sameEventMeaning left right =
      eventSequence left == eventSequence right
        && eventPreviousDigest left == eventPreviousDigest right
        && eventTransaction left == eventTransaction right
        && eventOperation left == eventOperation right
        && eventState left == eventState right

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
