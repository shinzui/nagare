module BadGenericCanonicalClaim where

import GHC.Generics (to)
import Nagare.Resource.Policy
import Nagare.Resource.Types

bad :: CanonicalClaim
bad = to undefined
