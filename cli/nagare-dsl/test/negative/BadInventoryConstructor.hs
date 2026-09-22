module BadInventoryConstructor where

import Nagare.Resource.Inventory

bad :: ValidatedInventory
bad = ValidatedInventory undefined undefined []
