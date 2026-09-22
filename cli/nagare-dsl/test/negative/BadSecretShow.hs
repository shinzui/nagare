module BadSecretShow where

import Nagare.Resource.Policy

bad :: RawCredential -> String
bad = show
