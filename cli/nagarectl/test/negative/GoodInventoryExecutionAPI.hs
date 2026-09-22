module GoodInventoryExecutionAPI where

import Data.List.NonEmpty (NonEmpty)
import Nagare.Inventory.Adapter
import Nagare.Inventory.Execute
import Nagare.Inventory.Plan
import Nagare.Inventory.Store (InventoryStore)

applyInsideLock :: InventoryStore -> AdapterRegistry -> ReviewedPlan -> IO (Either (NonEmpty AdmissionError) TransactionResult)
applyInsideLock = applyReviewed
