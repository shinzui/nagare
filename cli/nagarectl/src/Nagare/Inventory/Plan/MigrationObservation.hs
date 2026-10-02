-- | MigrationObservation responsibilities; internal implementation behind Nagare.Inventory.Plan.
module Nagare.Inventory.Plan.MigrationObservation
  ( observeMigrationIncarnations
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Inventory.Adapter
  ( AdapterRegistry
  , MigrationObservationSet
  , migrationObservationSet
  , observeWithRegistry
  )
import Nagare.Inventory.Plan.Types (ObservationRequirements (..))

-- | Observe the old and new provider bindings through separately constructed
-- registries. The same ResourceId may be requested from both, but never from
-- two adapters in one ordinary ObservationSet.
observeMigrationIncarnations ::
  AdapterRegistry ->
  AdapterRegistry ->
  ObservationRequirements ->
  IO (Either Text MigrationObservationSet)
observeMigrationIncarnations sourceRegistry destinationRegistry requirements = do
  let migrationIds = Map.keysSet (migrationIncarnations requirements)
      destinationRequests =
        Map.mapMaybe
          nonempty
          ( fmap
              (filter (`Set.member` migrationIds))
              (requirementsByExecutor requirements)
          )
  sources <- observeWithRegistry sourceRegistry (migrationSourcesByExecutor requirements)
  destinations <- observeWithRegistry destinationRegistry destinationRequests
  pure $ do
    sourceFacts <- sources
    destinationFacts <- destinations
    migrationObservationSet migrationIds sourceFacts destinationFacts
  where
    nonempty [] = Nothing
    nonempty resources = Just resources
