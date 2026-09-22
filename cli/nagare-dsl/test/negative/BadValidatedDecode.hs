module BadValidatedDecode where

import Data.Aeson (eitherDecodeStrict)
import Data.ByteString (ByteString)
import Nagare.Resource.Inventory

bad :: ByteString -> Either String ValidatedInventory
bad = eitherDecodeStrict
