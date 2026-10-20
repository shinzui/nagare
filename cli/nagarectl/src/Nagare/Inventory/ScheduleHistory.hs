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
  , convergedReviews
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Journal (JournalEvent (..), OperationState (Completed), decodeJournalEvent)
import Nagare.Inventory.ObservationNative (ObservationNativeError (..), loadObservationNativeChecked, observationKubernetes)
import Nagare.Inventory.Plan (ReviewDocument (..), loadPublishedReview, reviewBundleDocument, reviewBundleScopes)
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
    Right events -> do
      revisions <- traverse revisionIn (convergedReviews events)
      pure (nub . catMaybes <$> sequence revisions)
  where
    owner = cron ^. #owner

    revisionIn digest = do
      loaded <- loadPublishedReview store digest
      case loaded of
        Left err -> pure (Left ("a converged review cannot be read: " <> T.pack (show err)))
        Right bundle -> case Map.lookup owner (reviewDesiredRevisions (reviewBundleDocument bundle)) of
          Nothing -> pure (Right Nothing)
          Just revision -> do
            let scopeDigest = revisionDigest revision
            found <- case Map.lookup scopeDigest (reviewBundleScopes bundle) of
              Just bytes -> pure (Right (Just bytes))
              Nothing -> readObject store (scopeKey scopeDigest)
            case first (T.pack . show) found >>= first (T.pack . show) . decodeScopeMember owner scopeDigest of
              Left err -> pure (Left ("a converged revision of the schedule's scope cannot be read: " <> err))
              Right scope -> case [member | bundle' <- scopeBundles scope, Managed member <- declarations bundle', member ^. #identity == cron ^. #identity] of
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
