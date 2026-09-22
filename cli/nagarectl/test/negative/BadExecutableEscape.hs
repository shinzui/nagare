module BadExecutableEscape where

import Data.List.NonEmpty (NonEmpty)
import Nagare.Inventory.Adapter
import Nagare.Inventory.Execute
import Nagare.Inventory.Plan
import Nagare.Inventory.Store (InventoryStore, StoreError)

-- This must not compile: the scope parameter belongs to the callback passed to
-- withProcessLock and cannot appear in the returned type.
escapeExecutable :: InventoryStore -> AdapterRegistry -> ReviewedPlan -> IO (Either StoreError (Either (NonEmpty AdmissionError) (ExecutablePlan s)))
escapeExecutable store registry reviewed =
  withProcessLock store (\locked -> admit locked registry reviewed)
