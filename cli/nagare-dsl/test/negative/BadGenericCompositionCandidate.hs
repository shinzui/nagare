module BadGenericCompositionCandidate where

import GHC.Generics (to)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types

bad :: CompositionCandidate
bad = to undefined
