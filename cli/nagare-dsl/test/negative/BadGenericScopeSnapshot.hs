module BadGenericScopeSnapshot where
import GHC.Generics (to)
import Nagare.Resource.Types
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
bad :: ScopeSnapshot
bad = to undefined
