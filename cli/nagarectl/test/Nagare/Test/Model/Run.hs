-- | EP-173/EP-177: one execution of the recovery model. A 'Run' is the store,
-- the world, the adversary and the state the invariants keep.
--
-- The faulting store and the model's own view are separate types. Only an
-- operator's command, through 'operatorAction', reaches the store the
-- adversary faults, and it is re-run while new faults fire, as an operator
-- re-runs a failed command. Every check reads through 'InspectStore', which no
-- fault reaches and which cannot write. Neither the faulting store nor the
-- inspection store's constructor is exported, so the compiler enforces this.
--
-- EP-179: a snapshot copies the fake store's objects underneath both handles,
-- the world, the adversary and every invariant reference, so the exit search
-- can restore a stop instead of replaying the scenario up to it.
module Nagare.Test.Model.Run
  ( Run (runObjects, runWorld, runAdversary, runBound, runImages, runIncarnations, runDatabase, runConverged, runPauses)
  , RunSnapshot (..)
  , Checkpoint (..)
  , newRun
  , resumeRun
  , snapshotRun
  , restoreRun
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
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Plan (InventoryHistory, loadInventoryHistory)
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps (ObjectOps (..))
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Types
import Nagare.Test.Model.Fixtures
import Nagare.Test.World.Adversary
import Nagare.Test.World.Kubernetes
import Nagare.Test.World.ObjectStore (FakeObjects, fakeObjectState)
import Nagare.Test.World.Store (faultingObjectOps)
import Test.Tasty.HUnit (assertFailure)

data Run = Run
  { runStore :: !InventoryStore
  -- ^ The store the adversary faults; only 'operatorAction' reaches it.
  , runInspect :: !InspectStore
  , runObjects :: !(IORef FakeObjects)
  -- ^ The objects both store handles read and write. The handles keep no
  -- other state between commands (EP-179 M1).
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
  , runPauses :: !(IORef Int)
  -- ^ How often the store paused to retry a refused head write. It does not
  -- wait, and nothing in the run reads this; a test does (EP-179).
  }

-- | A clean, read-only view of the objects the run's commands wrote.
newtype InspectStore = InspectStore InventoryStore

-- | A fresh run of an application of this shape whose listed images never
-- become Ready, under the schedule.
newRun :: Shape -> [Text] -> [(Boundary, Fault)] -> IO Run
newRun shape unready schedule = do
  adversary <- newAdversary schedule
  -- The model's stores retry refused head writes without waiting (EP-179).
  pauses <- newIORef 0
  (base, objects) <- first (\ops -> ops {pauseBeforeRetry = \_ -> modifyIORef' pauses (+ 1)}) <$> fakeObjectState
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
  pure (Run store (InspectStore inspect) objects world adversary bound images incarnations database converged pauses)

-- | Everything a run's later behaviour depends on. The adversary keeps its
-- counts, so a restored run fires later faults at the same ordinals.
data RunSnapshot = RunSnapshot
  { storeObjects :: !FakeObjects
  , world :: !KubeWorld
  , adversary :: !Adversary
  , bound :: !(Map.Map ContentDigest (Map.Map ResourceId ContentDigest))
  , images :: !(Map.Map ContentDigest (Shape, Text, Text))
  , incarnations :: !(Map.Map ResourceId PhysicalIdentity)
  , database :: !(Map.Map ResourceId (ManagedResource, ByteString))
  , converged :: !(Map.Map ScopeId ScopeRevision)
  }
  deriving stock (Eq, Generic)

-- | A run as one of its steps began, from which a run under another schedule
-- with the same prefix resumes: the state, the step, the image the accepted
-- application then declares, the exits taken, and how each earlier step began
-- (most recent first).
data Checkpoint move = Checkpoint
  { state :: !RunSnapshot
  , step :: !Int
  , image :: !Text
  , taken :: ![(Int, [move])]
  , began :: ![(Map.Map Call Int, Text)]
  }
  deriving stock (Generic)

-- | A fresh run in a checkpoint's state, under this schedule. The adversary
-- keeps its counts and the faults that fired, so a fault of the schedule
-- fires at its boundary only if the checkpoint has not passed it.
resumeRun :: Shape -> [Text] -> [(Boundary, Fault)] -> RunSnapshot -> IO Run
resumeRun shape unready schedule' snapshot = do
  run <- newRun shape unready schedule'
  run <$ restoreRun run (snapshot & #adversary %~ \adversary' -> adversary' {schedule = schedule'})

snapshotRun :: Run -> IO RunSnapshot
snapshotRun run =
  RunSnapshot
    <$> readIORef (runObjects run)
    <*> readIORef (runWorld run)
    <*> readIORef (runAdversary run)
    <*> readIORef (runBound run)
    <*> readIORef (runImages run)
    <*> readIORef (runIncarnations run)
    <*> readIORef (runDatabase run)
    <*> readIORef (runConverged run)

restoreRun :: Run -> RunSnapshot -> IO ()
restoreRun run (RunSnapshot objects' world' adversary' bound' images' incarnations' database' converged') = do
  writeIORef (runObjects run) objects'
  writeIORef (runWorld run) world'
  writeIORef (runAdversary run) adversary'
  writeIORef (runBound run) bound'
  writeIORef (runImages run) images'
  writeIORef (runIncarnations run) incarnations'
  writeIORef (runDatabase run) database'
  writeIORef (runConverged run) converged'

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
