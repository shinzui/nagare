-- | Runtime / Guards. Executable-private CLI boundary.
module Nagare.Cli.Runtime.Guards
  ( guardLegacyMutationInventory
  )
where

import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Target (ActiveTarget)

guardLegacyMutationInventory :: Text -> ActiveTarget -> IO ()
guardLegacyMutationInventory operation active = do
  opened <- Inventory.openTargetStoreReadOnly active
  case opened of
    Left (InventoryStore.StoreConditionFailed "inventory store is not initialized") -> pure ()
    Left err -> dieT ("could not verify inventory history before " <> operation <> ": " <> T.pack (show err))
    Right store -> do
      loaded <- InventoryStore.readHead store
      case loaded of
        Left err -> dieT ("could not verify inventory history before " <> operation <> ": " <> T.pack (show err))
        Right Nothing -> pure ()
        Right (Just headValue) ->
          when (InventoryStore.hasSubstantiveHistory headValue) $
            dieT
              ( "this context has resource inventory history or transaction state; legacy "
                  <> operation
                  <> " cannot safely mutate it. Use a reviewed inventory command; retain any pending legacy upgrade bundle for guarded recovery with its original operator payload."
              )
