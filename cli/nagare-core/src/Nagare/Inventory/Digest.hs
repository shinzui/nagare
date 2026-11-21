-- | All resource inventory digests are SHA-256 of the exact canonical bytes.
module Nagare.Inventory.Digest (contentDigest) where

import Data.ByteString (ByteString)
import Nagare.Dsl.Prelude ()
import Nagare.Resource.Canonical qualified as Canonical
import Nagare.Resource.Types

contentDigest :: ByteString -> ContentDigest
contentDigest = Canonical.contentDigest
