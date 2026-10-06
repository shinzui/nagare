-- | EP-173/EP-177: one execution of the recovery model. A 'Run' is the store,
-- the world, the adversary and the state the invariants keep.
--
-- The faulting store and the model's own view are separate types. Only an
-- operator's command, through 'operatorAction', reaches the store the
-- adversary faults, and it is re-run while new faults fire, as an operator
-- re-runs a failed command. Every check reads through 'InspectStore', which no
-- fault reaches and which cannot write. Neither the faulting store nor the
-- inspection store's constructor is exported, so the compiler enforces this.
module Nagare.Test.Model.Run
  ( Run (runWorld, runAdversary, runBound, runImages, runIncarnations, runDatabase, runConverged)
  , newRun
  , Failure (..)
  , operatorAction
  , orTrouble
  , inspectHead
  , inspectJournal
  , inspectHistory
  , inspectIncarnations
  , orFail
  )
where

import Control.Exception (Exception, throwIO, try)
import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import InventoryObjectOpsSpec (fakeObjectOps)
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Plan (InventoryHistory, loadInventoryHistory)
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Types
import Nagare.Test.Model.Fixtures
import Nagare.Test.World.Adversary
import Nagare.Test.World.Kubernetes
import Nagare.Test.World.Store (faultingObjectOps)
import Test.Tasty.HUnit (assertFailure)

data Run = Run
  { runStore :: !InventoryStore
  -- ^ The store the adversary faults; only 'operatorAction' reaches it.
  , runInspect :: !InspectStore
  , runWorld :: !(IORef KubeWorld)
  , runAdversary :: !(IORef Adversary)
  , runBound :: !(IORef (Map.Map ContentDigest (Map.Map ResourceId ContentDigest)))
  -- ^ Native digests the review of each desired scope revision bound.
  , runImages :: !(IORef (Map.Map ContentDigest (Shape, Text, Text)))
  -- ^ The volume, service image and history image each desired scope revision
  -- declares, so the model can observe accepted members (I3).
  , runIncarnations :: !(IORef (Map.Map ResourceId PhysicalIdentity))
  -- ^ The last incarnation the head recorded for each member, kept after the
  -- head drops the record (I3's retirement clause).
  , runDatabase :: !(IORef (Map.Map ResourceId (ManagedResource, ByteString)))
  -- ^ The database revision's native specs the current review binds.
  , runConverged :: !(IORef (Map.Map ScopeId ScopeRevision))
  -- ^ The converged revisions last checked; I2 checks a revision when the
  -- head first reports it converged.
  }

-- | A clean, read-only view of the objects the run's commands wrote.
newtype InspectStore = InspectStore InventoryStore

-- | A fresh run of an application of this shape whose listed images never
-- become Ready, under the schedule.
newRun :: Shape -> [Text] -> [(Boundary, Fault)] -> IO Run
newRun shape unready schedule = do
  adversary <- newAdversary schedule
  base <- fakeObjectOps
  store <- newObjectStore (faultingObjectOps adversary base) fixtureBinding "recovery-model" Nothing >>= orFail "open store"
  inspect <- newObjectStore base fixtureBinding "recovery-inspect" Nothing >>= orFail "open inspection store"
  _ <- initializeStore store fixtureBinding "recovery-model" >>= orFail "initialize store"
  modifyIORef' adversary (\value -> value {storeArmed = True})
  world <- newKubeWorld (Set.fromList [if shapeWorker shape then workerDigest image else serviceDigest image | image <- unready])
  bound <- newIORef Map.empty
  images <- newIORef Map.empty
  incarnations <- newIORef Map.empty
  database <- newIORef databaseNative
  converged <- newIORef Map.empty
  pure (Run store (InspectStore inspect) world adversary bound images incarnations database converged)

-- | Why an operator's command failed for good.
data Failure e
  = -- | The command's own refusal.
    CommandRefused !e
  | -- | The executor died (an injected crash).
    CommandCrashed
  | -- | A store read or write the command needed failed.
    CommandTrouble !Text
  deriving stock (Eq, Show)

-- | Run an operator's command against the faulting store. While it fails (its
-- own refusal, a store failure, or a crash) and new faults fired during it,
-- run it again, as an operator re-runs a failed command. The schedule is
-- finite, so this ends. What counts as failure is the command's 'Left'; a
-- command whose failure an operator answers with another command (a stopped
-- transaction is ended by an exit, not by re-applying) returns it as 'Right'.
operatorAction :: Run -> (InventoryStore -> IO (Either e a)) -> IO (Either (Failure e) a)
operatorAction run command = do
  before <- length . fired <$> readIORef (runAdversary run)
  attempt <- try (try (command (runStore run)))
  after <- length . fired <$> readIORef (runAdversary run)
  case attempt of
    Right (Right (Right value)) -> pure (Right value)
    _ | after > before -> operatorAction run command
    Left Interrupted -> pure (Left CommandCrashed)
    Right (Left (StoreTrouble err)) -> pure (Left (CommandTrouble err))
    Right (Right (Left err)) -> pure (Left (CommandRefused err))

newtype StoreTrouble = StoreTrouble Text
  deriving stock (Show)

instance Exception StoreTrouble

-- | Inside an operator's command: a failed store call fails the command.
orTrouble :: (Show e) => Text -> Either e a -> IO a
orTrouble context = either (\err -> throwIO (StoreTrouble (context <> ": " <> T.pack (show err)))) pure

inspectHead :: Run -> IO (Either StoreError (Maybe HeadManifest))
inspectHead run = let InspectStore store = runInspect run in readHead store

inspectJournal :: Run -> Integer -> IO (Either StoreError [ByteString])
inspectJournal run count = let InspectStore store = runInspect run in readJournalPrefix store count

inspectHistory :: Run -> IO (Either StoreError InventoryHistory)
inspectHistory run = let InspectStore store = runInspect run in loadInventoryHistory store

inspectIncarnations :: Run -> HeadManifest -> IO (Either Text (Map.Map ResourceId PhysicalIdentity))
inspectIncarnations run headValue = let InspectStore store = runInspect run in Status.statusIncarnations store headValue

-- | A model read that cannot fail unless the harness itself is wrong.
orFail :: (Show e) => String -> Either e a -> IO a
orFail context = either (\err -> assertFailure (context <> ": " <> show err) >> pure (error "unreachable")) pure
