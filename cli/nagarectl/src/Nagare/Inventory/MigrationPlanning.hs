-- | Reviewed migration planning: observe both incarnations, decide the
-- migration from exact observations, and publish the review. The file-based
-- entry point and the typed database rename share one pipeline.
module Nagare.Inventory.MigrationPlanning
  ( planInventoryMigrationWith
  , planInventoryMigrationCandidateWith
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Command (clientIdentity, dieText, loadCandidate, openTargetStore, rejectReentry, validateTarget)
import Nagare.Inventory.Migration
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Target (ActiveTarget)
import System.FilePath (isAbsolute, takeDirectory, (</>))

planInventoryMigrationWith ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  ActiveTarget ->
  FilePath ->
  FilePath ->
  IO ()
planInventoryMigrationWith sourceRegistryFor destinationRegistryFor target inputFile output = do
  bytes <-
    (try (BS.readFile inputFile) :: IO (Either IOException ByteString))
      >>= either (dieText . showText) pure
  proposalInput <- either dieText pure (decodeMigrationInput bytes)
  let relative = migrationCandidateDirectory proposalInput
      candidateDirectory = if isAbsolute relative then relative else takeDirectory inputFile </> relative
  candidate <- loadCandidate candidateDirectory >>= either dieText pure
  planInventoryMigrationCandidateWith
    sourceRegistryFor
    destinationRegistryFor
    target
    candidate
    (\_ _ -> pure (Right proposalInput))
    output

-- | Plan a migration of an in-memory candidate. The proposal is built after
-- both incarnations are observed, so a command can derive it from the exact
-- observations that review will bind.
planInventoryMigrationCandidateWith ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  ActiveTarget ->
  CompositionCandidate ->
  (InventoryHistory -> MigrationObservationSet -> IO (Either Text MigrationInput)) ->
  FilePath ->
  IO ()
planInventoryMigrationCandidateWith sourceRegistryFor destinationRegistryFor target candidate proposalFor output = do
  rejectReentry
  validateTarget target candidate
  store <- openTargetStore target
  let binding = inventoryBinding (candidateInventory candidate)
  _ <- initializeStore store binding (clientIdentity target) >>= either (dieText . showText) pure
  _ <- seedInventoryHistory store candidate >>= either (dieText . showText) pure
  history <- loadInventoryPlanningHistory store candidate >>= either (dieText . showText) pure
  destinationRegistry <- destinationRegistryFor candidate history
  sourceRegistry <- sourceRegistryFor candidate history
  let requirements = observationRequirements candidate history
  destinations <-
    observeWithRegistry destinationRegistry (requirementsByExecutor requirements)
      >>= either dieText pure
  incarnationFacts <-
    observeMigrationIncarnations sourceRegistry destinationRegistry requirements
      >>= either dieText pure
  proposalInput <- proposalFor history incarnationFacts >>= either dieText pure
  decisions <-
    either
      (dieText . showText . NE.toList)
      pure
      (decideMigration candidate proposalInput history destinations incarnationFacts)
  proposal <-
    either
      (dieText . showText . NE.toList)
      pure
      (planChanges candidate decisions history destinations)
  -- A source executor absent from the desired candidate can otherwise fall
  -- back to manifest-only preparation. Its fabricated accepted observation
  -- must never become native migration evidence in a published review.
  forM_ (proposalOperations proposal) $ \operation -> case plannedAction operation of
    MigrateResource _ -> do
      adapter <- either dieText pure (lookupAdapter destinationRegistry (plannedExecutor operation))
      when
        (adapterIdentity adapter == "manifest-only")
        (dieText "migration stage lacks an installed native provider adapter")
    _ -> pure ()
  snapshot <- readStoreSnapshot store >>= either (dieText . showText) pure
  bundle <-
    prepareReview destinationRegistry snapshot proposal
      >>= either (dieText . showText . NE.toList) pure
  digest <- publishReview store bundle >>= either (dieText . showText) pure
  _ <- writeReviewBundle output bundle >>= either dieText pure
  TIO.putStrLn (digestText digest)

showText :: (Show a) => a -> Text
showText = T.pack . show
