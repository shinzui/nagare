module BadGenericRawCredential where

import GHC.Generics (to)
import Nagare.Resource.Policy
import Nagare.Resource.Types

bad :: RawCredential
bad = to undefined
