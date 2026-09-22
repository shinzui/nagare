-- | All resource inventory digests are SHA-256 of the exact canonical bytes.
module Nagare.Inventory.Digest (contentDigest) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString (ByteString)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Resource.Types

contentDigest :: ByteString -> ContentDigest
contentDigest bytes = either (error . T.unpack) id (mkContentDigest (T.pack (show (hash bytes :: Digest SHA256))))
