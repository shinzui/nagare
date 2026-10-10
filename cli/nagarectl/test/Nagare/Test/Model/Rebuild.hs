-- | EP-183 M4: the recovery model's rebuild. The cluster is lost (every
-- object goes, as when the VM is lost), and the database is rebuilt through
-- reviewed rebuild decisions generated as `inventory rebuild-decisions` does:
-- its volume from one recovery point of its predecessor, its generated
-- Secrets anew. The rebuild transaction then faces every fault placement.
module Nagare.Test.Model.Rebuild
  ( loseCluster
  , decideModelRebuild
  , rebuildPoint
  , rebuildLineageHolds
  )
where

import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (ObservationSet)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Lineage
import Nagare.Inventory.Plan
import Nagare.Inventory.Rebuild (RebuildInput (..), decideRebuild, rebuildTargets)
import Nagare.Inventory.Store
import Nagare.Resource.Inventory (CompositionCandidate)
import Nagare.Resource.Policy (DataPolicy (Durable))
import Nagare.Resource.Types
import Nagare.Test.Model.Fixtures
import Nagare.Test.Model.Run
import Nagare.Test.World.Kubernetes

-- | The VM is lost: the cluster keeps no object. UIDs are never reused.
loseCluster :: Run -> IO ()
loseCluster run = modifyIORef' (runWorld run) (#server %~ \server -> server & #objects .~ Map.empty & #inUse .~ Set.empty & #frozen .~ Set.empty)

-- | The recovery point the model's operator chose for the volume.
rebuildPoint :: RecoveryPoint
rebuildPoint = RecoveryPoint ScheduledRecoveryPoint "gs://bucket/databases/pg/job-1.sql.gz.receipt.json" (contentDigest "receipt")

-- | Rebuild every missing durable member, as the generated decisions do: a
-- volume from the recovery point of its recorded predecessor, or, when no
-- incarnation was ever recorded (a create whose response was lost, a closed
-- review), fresh, as the operator then chooses.
decideModelRebuild :: CompositionCandidate -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions
decideModelRebuild candidate history observations = do
  targets <- rebuildTargets candidate history observations (\_ predecessor -> Right (maybe Fresh (const (FromRecoveryPoint rebuildPoint)) predecessor))
  decideRebuild candidate history observations (RebuildInput fixtureBinding targets)

-- | After the rebuild converged, each durable member of the database is
-- recorded as its live object: the new incarnation the rebuild created (the
-- lost cluster's UIDs are never reused, so it is not the predecessor).
rebuildLineageHolds :: Run -> IO (Either Text ())
rebuildLineageHolds run = do
  current <- inspectHead run >>= orFail "read head"
  world <- readIORef (runWorld run)
  let recorded = maybe Map.empty headIncarnations current
      durable = [member ^. #identity | (member, _) <- Map.elems databaseNative, Durable _ <- [member ^. #dataPolicy]]
      wrong = [resource | resource <- durable, Map.lookup resource recorded /= (uid <$> Map.lookup resource (objects world))]
  pure $ case wrong of
    [] -> Right ()
    resource : _ -> Left ("I3: rebuilt " <> resourceIdText resource <> " is not recorded as its live new incarnation (" <> T.pack (show (Map.lookup resource recorded)) <> ")")
