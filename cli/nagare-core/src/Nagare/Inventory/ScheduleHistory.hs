-- | The converged revisions of a backup schedule (EP-207). A scheduled run
-- signs its receipt with the metadata of the schedule revision it ran under;
-- after the schedule changes, its earlier runs are still runs Nagare
-- accepted. Their authority is the CronJob bytes of every revision whose
-- transaction converged: the journal's transaction-level 'Completed' event
-- names the review it converged on, and that review's desired revision of the
-- schedule's scope holds the CronJob member whose bytes the native store
-- keeps. A revision only reviewed, or whose transaction did not converge,
-- authorizes nothing.
module Nagare.Inventory.ScheduleHistory
  ( convergedScheduleRevisions
  , convergedScheduleRevisionsIn
  , convergedReviewDocuments
  , convergedScheduleRevisionsFromReviews
  , convergedReviews
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Events.ChangeOutcome (loadReviewDocument)
import Nagare.Inventory.Journal (JournalEvent (..), OperationState (Completed), decodeJournalEvent)
import Nagare.Inventory.ObservationNative (ObservationNativeError (..), loadObservationNativeChecked, observationKubernetes)
import Nagare.Inventory.Plan.Types (ReviewDocument (reviewDesiredRevisions))
import Nagare.Inventory.ScopeMember (decodeScopeMember)
import Nagare.Inventory.Store (HeadManifest (headSequence), InventoryStore, readJournalPrefix, readObject, revisionDigest, scopeKey)
import Nagare.Resource.Inventory (Declaration (Managed), ManagedResource, ResourceBundle (declarations), scopeBundles)
import Nagare.Resource.Types (ContentDigest)

-- | The CronJob bytes of every converged revision of the schedule, oldest
-- first and without repeats. A revision whose bytes predate the native store
-- is left out: it narrows what is accepted, never widens it.
convergedScheduleRevisions :: InventoryStore -> HeadManifest -> ManagedResource -> IO (Either Text [ByteString])
convergedScheduleRevisions store headValue cron = do
  raw <- readJournalPrefix store (headSequence headValue)
  case first (T.pack . show) raw >>= traverse decodeJournalEvent of
    Left err -> pure (Left ("the journal cannot be read for the schedule's revisions: " <> err))
    Right events -> convergedScheduleRevisionsIn store events cron

-- | As 'convergedScheduleRevisions', over journal events already read, so a
-- caller resolving several schedules reads the journal once (EP-233).
convergedScheduleRevisionsIn :: InventoryStore -> [JournalEvent] -> ManagedResource -> IO (Either Text [ByteString])
convergedScheduleRevisionsIn store events cron = do
  reviews <- convergedReviewDocuments store events
  either (pure . Left) (\docs -> convergedScheduleRevisionsFromReviews store docs cron) reviews

-- | Read each converged review's digest-verified document once. The callers
-- that resolve several schedules share the decoded documents.
convergedReviewDocuments :: InventoryStore -> [JournalEvent] -> IO (Either Text [ReviewDocument])
convergedReviewDocuments store = fmap sequence . traverse (loadReviewDocument store) . convergedReviews

convergedScheduleRevisionsFromReviews :: InventoryStore -> [ReviewDocument] -> ManagedResource -> IO (Either Text [ByteString])
convergedScheduleRevisionsFromReviews store reviews cron = do
  let revisions = nub (mapMaybe (Map.lookup owner . reviewDesiredRevisions) reviews)
  loaded <- traverse (revisionIn . revisionDigest) revisions
  pure (nub . catMaybes <$> sequence loaded)
  where
    owner = cron ^. #owner

    revisionIn scopeDigest = do
      found <- readObject store (scopeKey scopeDigest)
      case first (T.pack . show) found >>= first (T.pack . show) . decodeScopeMember owner scopeDigest of
        Left err -> pure (Left ("a converged revision of the schedule's scope cannot be read: " <> err))
        Right scope -> case [member | bundle <- scopeBundles scope, Managed member <- declarations bundle, member ^. #identity == cron ^. #identity] of
          [member] -> do
            native <- loadObservationNativeChecked store [member]
            pure $ case native of
              Right observed -> Right (snd <$> Map.lookup (cron ^. #identity) (observationKubernetes observed))
              Left (ObservationNativeMissing _) -> Right Nothing
              Left (ObservationNativeInvalid reason) -> Left ("a converged revision of the schedule has invalid native bytes: " <> reason)
          _ -> pure (Right Nothing)

-- | The reviews whose transactions converged, in journal order: a
-- transaction-level 'Completed' event names its review. A transaction that
-- failed, is in flight or was resolved by an operator converged nothing.
convergedReviews :: [JournalEvent] -> [ContentDigest]
convergedReviews events = nub [digest | event <- events, isNothing (eventOperation event), Completed digest <- [eventState event]]
