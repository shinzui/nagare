-- | Versioned migration proposals bind two physical incarnations of one
-- logical resource. Validation does not grant mutation authority: the
-- planner and provider adapters must still review and prove every phase.
module Nagare.Inventory.Migration
  ( MigrationContract (..)
  , MigrationTarget (..)
  , MigrationInput (..)
  , ValidatedMigration
  , validatedSource
  , validatedDestination
  , validatedSourcePhysical
  , validatedDestinationAbsence
  , validatedContract
  , decodeMigrationInput
  , validateMigrationInput
  , decideMigration
  ) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing, mapMaybe)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Migration.Types
import Nagare.Inventory.Plan
import Nagare.Inventory.Store (HeadManifest (..), ScopeRevision)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire ()

data MigrationTarget = MigrationTarget
  { migrationResource :: !ResourceId
  , migrationSourceAddress :: !ProviderAddress
  , migrationSourcePhysical :: !PhysicalIdentity
  , migrationDestinationAddress :: !ProviderAddress
  , migrationDestinationAbsence :: !ContentDigest
  , migrationContract :: !MigrationContract
  }
  deriving stock (Eq, Show)

data MigrationInput = MigrationInput
  { migrationCandidateDirectory :: !FilePath
  , migrationBinding :: !ContextBinding
  , migrationTargets :: ![MigrationTarget]
  }
  deriving stock (Eq, Show)

decodeMigrationInput :: ByteString -> Either Text MigrationInput
decodeMigrationInput bytes = first (T.pack . show) (eitherDecodeStrict' bytes)

decideMigration
  :: CompositionCandidate -> MigrationInput -> InventoryHistory
  -> ObservationSet -> MigrationObservationSet
  -> Either (NonEmpty PlanError) LifecycleDecisions
decideMigration candidate input history destinations pairs = do
  validated <- validateMigrationInput candidate history pairs input
  approveMigrations candidate history destinations pairs validated

validateMigrationInput
  :: CompositionCandidate -> InventoryHistory -> MigrationObservationSet
  -> MigrationInput -> Either (NonEmpty PlanError) (Map ResourceId ValidatedMigration)
validateMigrationInput candidate history observations input = do
  unless (null errors) (Left (NE.fromList errors))
  pure (Map.fromList valid)
  where
    desired = Map.fromList
      [(resource ^. #identity, resource)
      | Managed resource <- inventoryDeclarations (candidateInventory candidate)]
    accepted = Map.fromList
      [(resource ^. #identity, (revision, resource))
      | (scope, (revision, declaration)) <- Map.toAscList (historyAccepted history)
      , bundle <- scopeBundles declaration
      , Managed resource <- bundle ^. #declarations
      , resource ^. #owner == scope]
    observed = migrationObservationMap observations
    issue code message resource = PlanError code message [resource]
    checked target = do
      let resource = migrationResource target
      (revision, source) <- Map.lookup resource accepted
      destination <- Map.lookup resource desired
      (sourceFact, destinationFact) <- Map.lookup resource observed
      guard (source ^. #owner == destination ^. #owner
        && (source ^. #address /= destination ^. #address
          || source ^. #executor /= destination ^. #executor)
        && source ^. #address == migrationSourceAddress target
        && destination ^. #address == migrationDestinationAddress target
        && sourceFact == ObservedPresent (migrationSourcePhysical target)
        && destinationFact == ConfirmedAbsent (migrationDestinationAbsence target)
        && source ^. #dataPolicy == destination ^. #dataPolicy
        && case (source ^. #dataPolicy, migrationContract target) of
          (Stateless, StatelessMigration) -> True
          (Durable _, DurableMigration {}) -> True
          _ -> False)
      pure (resource, ValidatedMigration (revision, source) destination
        (migrationSourcePhysical target) (migrationDestinationAbsence target)
        (migrationContract target))
    valid = mapMaybe checked (migrationTargets input)
    errors =
      [issue "migration-binding" "proposal belongs to another context or provider target" (migrationResource target)
      | target <- migrationTargets input
      , migrationBinding input /= inventoryBinding (candidateInventory candidate)
        || migrationBinding input /= headBinding (historyHead history)]
      <> [issue "invalid-migration" "migration needs an accepted source, changed composed destination, exact dual observations, and a matching data contract" (migrationResource target)
         | target <- migrationTargets input, isNothing (checked target)]
      <> [issue "duplicate-migration" "resource appears more than once in the migration proposal" resource
         | resource <- duplicateIds (map migrationResource (migrationTargets input))]
    duplicateIds values = Map.keys (Map.filter (> (1 :: Int))
      (Map.fromListWith (+) [(value, 1 :: Int) | value <- values]))

instance FromJSON MigrationTarget where
  parseJSON = withObject "MigrationTarget" $ \o -> do
    unless (all (`elem` ["resource", "sourceAddress", "sourcePhysicalIdentity", "destinationAddress", "destinationAbsence", "contract"]) (KM.keys o))
      (fail "migration target has an unknown field")
    MigrationTarget <$> o .: "resource" <*> o .: "sourceAddress"
      <*> o .: "sourcePhysicalIdentity" <*> o .: "destinationAddress"
      <*> o .: "destinationAbsence" <*> o .: "contract"

instance FromJSON MigrationInput where
  parseJSON = withObject "MigrationInput" $ \o -> do
    unless (all (`elem` ["version", "candidate", "binding", "resources"]) (KM.keys o))
      (fail "migration input has an unknown field")
    version <- o .: "version" :: Parser Int
    unless (version == 1) (fail "unsupported migration input version")
    candidate <- o .: "candidate"
    when (null (candidate :: FilePath)) (fail "candidate directory is required")
    targets <- o .: "resources"
    when (null (targets :: [MigrationTarget])) (fail "migration proposal needs at least one resource")
    MigrationInput candidate <$> o .: "binding" <*> pure targets
