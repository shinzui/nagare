-- | Compose a platform release against the complete accepted context.
-- Application and standalone scopes remain at their accepted revisions, while
-- the shared inventory validator checks their references to the new platform.
module Nagare.Inventory.PlatformUpgrade
  ( composePlatformUpgrade
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Types

composePlatformUpgrade
  :: ScopeSnapshot
  -> NonEmpty ScopeChange
  -> Either (NonEmpty InventoryError) CompositionCandidate
composePlatformUpgrade snapshot changes = do
  case [change | change <- NE.toList changes, not (platformChange change)] of
    [] -> pure ()
    _ -> Left (inventoryError "platform-upgrade-scope"
      "platform upgrades may change only platform scopes" :| [])
  candidate <- composeInventory snapshot changes
  let unchanged scopes = Map.filterWithKey (\owner _ -> scopeKind owner /= Platform) scopes
      accepted = snapshotScopes snapshot
      desired = inventoryScopes (candidateInventory candidate)
  if unchanged desired == unchanged (fmap snd accepted)
      && unchanged (candidateGenerations candidate) == unchanged (fmap fst accepted)
    then Right candidate
    else Left (inventoryError "platform-upgrade-preservation"
      "platform upgrade changed an independently owned scope" :| [])
  where
    platformChange (ReplaceScope scope) = scopeKind (scopeId scope) == Platform
    platformChange (RetireScope owner _) = scopeKind owner == Platform
    platformChange (CollectRetained _) = False
