-- | Planning a review that lists what it removes (EP-283).
module Nagare.Inventory.Command.Effects
  ( planInventoryCandidateWithEffects
  )
where

import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (AdapterRegistry)
import Nagare.Inventory.Command (dieText, openCandidateInventory, tryReviewInventoryCandidateLoaded, writePlannedReview)
import Nagare.Inventory.Lifecycle (decideMemberRetirement)
import Nagare.Inventory.Plan (InventoryHistory, ReviewEffect, publishReview, withReviewEffects)
import Nagare.Resource.Inventory (CompositionCandidate)
import Nagare.Resource.Types (ResourceId)
import Nagare.Target (ActiveTarget)

-- | Plan a candidate that drops the named members from their scopes, each
-- retained by its own retirement decision, and record what the review takes
-- away. The effects are set before the review is published, so they are
-- under its digest. Saves the review and prints it.
planInventoryCandidateWithEffects ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  ActiveTarget ->
  CompositionCandidate ->
  [ResourceId] ->
  [ReviewEffect] ->
  FilePath ->
  IO ()
planInventoryCandidateWithEffects registryFor target candidate retired effects output = do
  opened <- openCandidateInventory target candidate
  (store, bundle) <-
    tryReviewInventoryCandidateLoaded registryFor (decideMemberRetirement retired candidate) "operator-cli" target opened candidate
      >>= either dieText pure
  let reviewed = withReviewEffects effects bundle
  digest <- publishReview store reviewed >>= either (dieText . T.pack . show) pure
  writePlannedReview output reviewed digest
