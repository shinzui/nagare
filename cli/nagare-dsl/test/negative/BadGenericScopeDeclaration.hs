module BadGenericScopeDeclaration where

import GHC.Generics (to)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types

bad :: ScopeDeclaration
bad = to undefined
