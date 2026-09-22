module BadGenericSecretRef where

import GHC.Generics (to)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types

bad :: SecretRef
bad = to undefined
