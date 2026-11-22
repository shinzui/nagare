{-# LANGUAGE OverloadedStrings #-}

-- | @change.failed@ and @change.closed@ (EP-276): the candidates the
-- materializer builds from a committed journal stop, with the review its
-- transaction names or the close record it commits.
--
-- The executor's failure path is not changed: each failure event is already
-- committed by the conditional head replacement its append performs, so the
-- worker derives the event from the journal, off the deploy path.
module Nagare.Events.ChangeOutcome
  ( operationActionName
  , failedKey
  , closedKey
  , failureCandidate
  , closureCandidate
  , loadReviewDocument
  , resourceOwner
  )
where

import Data.Aeson (eitherDecodeStrict')
import Data.Generics.Labels ()
import Data.List (nub)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Events.Source
import Nagare.Inventory.Adapter (OperationAction (..), PlannedOperation (plannedAction, plannedOperationId, plannedResources))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (..), TransactionId, operationIdText, reviewDigestOf, transactionIdText)
import Nagare.Inventory.Plan.CloseRecord (CloseRecord (..), ScopeDisposition (..))
import Nagare.Inventory.Plan.Types (ReviewDocument (reviewActor, reviewOperations, reviewSource), ReviewOperation (reviewPlannedOperation))
import Nagare.Inventory.Store (InventoryStore, readObject, reviewKey)
import Nagare.Resource.Types

-- | An operation action's wire name in lifecycle payloads.
operationActionName :: OperationAction -> Text
operationActionName = \case
  CreateResource -> "create"
  UpdateResource -> "update"
  VerifyResource -> "verify"
  AdoptResource -> "adopt"
  RetireResource -> "retire"
  ReplaceStuckPod -> "replace-stuck-pod"
  RunDeclaredOperation -> "run-declared-operation"
  OpenMaintenanceSession -> "open-maintenance-session"
  RestoreLiveDatabase -> "restore-live-database"
  MigrateResource _ -> "migrate"

-- | One failure event per recorded stop: a resume that stops again is
-- another journal event and another event.
failedKey :: TransactionId -> Integer -> Either Text SourceKey
failedKey transaction sequenceNumber = mkSourceKey ("change.failed:" <> transactionIdText transaction <> ":" <> T.pack (show sequenceNumber))

-- | A transaction closes once.
closedKey :: TransactionId -> Either Text SourceKey
closedKey transaction = mkSourceKey ("change.closed:" <> transactionIdText transaction)

-- | The @change.failed@ candidate of a committed failure or unknown
-- outcome, with the review its transaction applies.
failureCandidate :: CommittedStop -> ReviewDocument -> Either Text EventCandidate
failureCandidate stop document = do
  review <- maybe (Left ("the transaction " <> transactionIdText transaction <> " names no review")) Right (reviewDigestOf transaction)
  outcome <- case stop ^. #kind of
    StopFailed (KnownNoEffect _) -> Right FailedNoEffect
    StopFailed (PartialOrUnknown _) -> Right FailedPartialOrUnknown
    StopAmbiguous -> Right AmbiguousOutcome
    StopClosed _ -> Left "a close is not a failure"
  key <- failedKey transaction (stop ^. #journalSequence)
  let planned =
        listToMaybe
          [ reviewPlannedOperation operation
          | Just operationId <- [stop ^. #operation]
          , operation <- reviewOperations document
          , plannedOperationId (reviewPlannedOperation operation) == operationId
          ]
      resources = maybe [] (NE.toList . plannedResources) planned
      owners = nub (mapMaybe resourceOwner resources)
      scope = case owners of
        [] -> Nothing
        several -> Just (primaryScopeOf several)
      member = case resources of
        [only] -> Just only
        _ -> Nothing
  pure
    EventCandidate
      { key
      , resource = ResourceRef (fromMaybe contextScope scope) member Nothing Nothing
      , occurredAt = Nothing
      , evidence = [Evidence "review" review, Evidence "journal-event" (stop ^. #digest)]
      , payload =
          ChangeFailedPayload
            ChangeFailure
              { transaction
              , review
              , actor = reviewActor document
              , source = changeSource (reviewSource document)
              , operation = stop ^. #operation
              , action = operationActionName . plannedAction <$> planned
              , resources
              , scope
              , outcome
              , reason = case stop ^. #kind of
                  StopFailed (KnownNoEffect text) -> Just text
                  StopFailed (PartialOrUnknown text) -> Just text
                  _ -> Nothing
              , detail = stop ^. #detail
              , next = ResumeOrClose
              }
      }
  where
    transaction = stop ^. #transaction

-- | The @change.closed@ candidate of a committed close, from the close
-- record its marker names.
closureCandidate :: CommittedStop -> ContentDigest -> CloseRecord -> Either Text EventCandidate
closureCandidate stop recordDigest record = do
  unless (closedTransaction record == transaction) (Left ("the close record " <> digestText recordDigest <> " names another transaction"))
  key <- closedKey transaction
  let scopes = [ClosedScope scope (disposition value) | (scope, value) <- Map.toAscList (closedScopes record)]
  pure
    EventCandidate
      { key
      , resource = ResourceRef (primaryScopeOf (map (^. #scope) scopes)) Nothing Nothing Nothing
      , occurredAt = Nothing
      , evidence = [Evidence "review" (closedReview record), Evidence "close-record" recordDigest]
      , payload =
          ChangeClosedPayload
            ChangeClosure
              { transaction
              , review = closedReview record
              , record = recordDigest
              , scopes
              , attested = isJust (closedAttestation record)
              }
      }
  where
    transaction = stop ^. #transaction
    disposition = \case
      RevertTo _ -> ClosedReverted
      KeepDesired -> ClosedKept

-- | The published review document at this digest: one exact read, checked
-- against its digest. Its scopes and native objects are not read.
loadReviewDocument :: InventoryStore -> ContentDigest -> IO (Either Text ReviewDocument)
loadReviewDocument store digest = do
  loaded <- readObject store (reviewKey digest)
  pure $ case loaded of
    Left err -> Left ("the review " <> digestText digest <> " cannot be read: " <> T.pack (show err))
    Right Nothing -> Left ("the review " <> digestText digest <> " is missing")
    Right (Just bytes)
      | contentDigest bytes /= digest -> Left ("the review " <> digestText digest <> " does not match its digest")
      | otherwise -> first (\reason -> "the review " <> digestText digest <> " cannot be decoded: " <> T.pack reason) (eitherDecodeStrict' bytes)

-- | The scope a resource ID names: the part before its first @/@.
resourceOwner :: ResourceId -> Maybe ScopeId
resourceOwner resource = case T.splitOn ":" (T.takeWhile (/= '/') (resourceIdText resource)) of
  [kind, name] -> do
    scopeKind <- lookup kind [("platform", Platform), ("application", Application), ("standalone", Standalone), ("publication", Publication)]
    either (const Nothing) Just (mkScopeId scopeKind name)
  _ -> Nothing
