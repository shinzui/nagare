-- | Canonical JSON and content digests shared by pure inventory composers and
-- the wire boundary. Object keys are sorted independently of aeson settings.
module Nagare.Resource.Canonical (canonicalValue, contentDigest) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Result (..), Value (..), encode, fromJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Resource.Types

canonicalValue :: Value -> Either Text ByteString
canonicalValue = \case
  Object o -> do
    pairs <-
      traverse
        (\(k, v) -> ((BL.toStrict (encode (Key.toText k)) <> ":") <>) <$> canonicalValue v)
        (sortOn (Key.toText . fst) (KM.toList o))
    pure ("{" <> BS.intercalate "," pairs <> "}")
  Array a -> (\vs -> "[" <> BS.intercalate "," vs <> "]") <$> traverse canonicalValue (toList a)
  Number n -> case fromJSON (Number n) :: Result Integer of
    Success i -> Right (BC.pack (show i))
    Error _ -> Left "canonical resource JSON permits integers only"
  v -> Right (BL.toStrict (encode v))

contentDigest :: ByteString -> ContentDigest
contentDigest bytes = either (error . T.unpack) id (mkContentDigest (T.pack (show (hash bytes :: Digest SHA256))))
