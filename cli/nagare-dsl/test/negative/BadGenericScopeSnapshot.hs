module BadGenericScopeSnapshot where

import GHC.Generics (to)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types

bad :: ScopeSnapshot
bad = to undefined
