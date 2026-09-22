module BadGenericContentDigest where

import GHC.Generics (to)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types

bad :: ContentDigest
bad = to undefined
