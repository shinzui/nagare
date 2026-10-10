-- | EP-183 M4: the recovery lineage of a member's recorded incarnation, read
-- from the journal, which is where it is recorded. ADR 27 records an
-- incarnation from the identity its creating write returned; the first event
-- that carries that identity is that write. When the write is a reviewed
-- rebuild's create, in a transaction that converged, the review's rebuild
-- proof is the incarnation's lineage. Any other origin (a create, an adoption,
-- a rebind) has none, so a predecessor's backup never restores into it.
module Nagare.Inventory.LineageHistory
  ( RebuildLineage (..)
  , memberLineage
  , lineageOrigin
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (OperationAction (CreateResource), PlannedOperation (..))
import Nagare.Inventory.Journal (JournalEvent (..), OperationId, OperationState (Completed), TransactionId, decodeJournalEvent)
import Nagare.Inventory.Lineage (RebuildProof)
import Nagare.Inventory.Plan (ReviewDocument (..), ReviewOperation (..), loadPublishedReview, reviewBundleDocument)
import Nagare.Inventory.Store (HeadManifest (headIncarnations, headSequence), InventoryStore, readJournalPrefix)
import Nagare.Resource.Types (ContentDigest, PhysicalIdentity, ResourceId)

-- | A member's recorded incarnation, created by a converged rebuild.
data RebuildLineage = RebuildLineage
  { resource :: !ResourceId
  , incarnation :: !PhysicalIdentity
  , proof :: !RebuildProof
  , review :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

-- | The lineage of the member's recorded incarnation, if a converged rebuild
-- created it.
memberLineage :: InventoryStore -> HeadManifest -> ResourceId -> IO (Either Text (Maybe RebuildLineage))
memberLineage store headValue member = case Map.lookup member (headIncarnations headValue) of
  Nothing -> pure (Right Nothing)
  Just recorded -> do
    raw <- readJournalPrefix store (headSequence headValue)
    case first (T.pack . show) raw >>= traverse decodeJournalEvent of
      Left err -> pure (Left ("the journal cannot be read for the incarnation's lineage: " <> err))
      Right events -> case lineageOrigin recorded events of
        Nothing -> pure (Right Nothing)
        Just (_, operation, digest) -> do
          loaded <- loadPublishedReview store digest
          pure $ do
            document <- first (T.pack . show) (reviewBundleDocument <$> loaded)
            let created =
                  any
                    ( \entry ->
                        let planned = reviewPlannedOperation entry
                         in plannedOperationId planned == operation
                              && plannedAction planned == CreateResource
                              && plannedResources planned == member :| []
                    )
                    (reviewOperations document)
            Right
              ( if created
                  then RebuildLineage member recorded <$> Map.lookup member (reviewRebuilds document) <*> pure digest
                  else Nothing
              )

-- | The operation whose write first returned this identity, and the review
-- its transaction converged on. A transaction that never converged has none.
lineageOrigin :: PhysicalIdentity -> [JournalEvent] -> Maybe (TransactionId, OperationId, ContentDigest)
lineageOrigin recorded events = do
  event <- case [candidate | candidate <- events, eventPhysical candidate == Just recorded, isJust (eventOperation candidate)] of
    first' : _ -> Just first'
    [] -> Nothing
  operation <- eventOperation event
  digest <- case [digest | candidate <- events, eventTransaction candidate == eventTransaction event, isNothing (eventOperation candidate), Completed digest <- [eventState candidate]] of
    found : _ -> Just found
    [] -> Nothing
  pure (eventTransaction event, operation, digest)
