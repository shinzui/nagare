-- | Inventory / PublicEvidence. Executable-private CLI boundary.
module Nagare.Cli.Inventory.PublicEvidence
  ( publicDataFence
  )
where

import Data.Aeson qualified as Aeson
import Data.Map qualified as Map
import Data.Set qualified as Set
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store qualified as InventoryStore

publicDataFence :: InventoryStore.DataFenceRecord -> Aeson.Value
publicDataFence fence =
  Aeson.object
    [ "session" Aeson..= InventoryStore.fenceSession fence
    , "phase" Aeson..= InventoryStore.fencePhase fence
    , "affected" Aeson..= Set.toAscList (InventoryStore.fenceAffected fence)
    , "targets"
        Aeson..= [ Aeson.object ["resource" Aeson..= resource, "physical" Aeson..= physical]
                 | (resource, physical) <- Map.toAscList (InventoryStore.fencePhysical fence)
                 ]
    , "recoveryDigest" Aeson..= InventoryStore.fenceRecoveryDigest fence
    ]
