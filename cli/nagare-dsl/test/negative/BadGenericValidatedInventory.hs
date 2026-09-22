module BadGenericValidatedInventory where

import GHC.Generics (to)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types

bad :: ValidatedInventory
bad = to undefined
