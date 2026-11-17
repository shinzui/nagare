{-# LANGUAGE OverloadedStrings #-}

-- | The lifecycle webhook signing protocol (EP-234). A request carries
-- @Nagare-Event-Id@, @Nagare-Delivery-Id@, @Nagare-Webhook-Timestamp@
-- (decimal Unix seconds) and @Nagare-Webhook-Signature@. Each signature is
-- HMAC-SHA256 over the UTF-8 bytes of @v1@, the timestamp, the event ID and
-- the delivery ID, each followed by one LF, then the exact raw body with no
-- terminator added. The header holds one @v1;kid=KEY_ID;sig=LOWERCASE_HEX@
-- entry per signing key, comma-separated while a key rotates.
--
-- A receiver checks the timestamp is within five minutes of its clock,
-- compares a signature it can compute in constant time, and records the
-- event IDs it processed: a retry carries the same event ID with a fresh
-- timestamp and signature. A signature proves possession of the
-- subscription's key, not the health of the workload the event is about.
module Nagare.Events.Webhook.Signature
  ( SigningKey (..)
  , mkKeyId
  , KeyId
  , keyIdText
  , SignedHeaders (..)
  , signingInput
  , signatureHeader
  , signRequest
  , Verification (..)
  , verifyRequest
  , timestampWindow
  )
where

import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude

-- | A key ID: 1 to 64 ASCII letters, digits, @-@, @_@ or @.@.
newtype KeyId = KeyId Text deriving stock (Eq, Ord, Show)

mkKeyId :: Text -> Either Text KeyId
mkKeyId value
  | not (T.null value) && T.length value <= 64 && T.all (\c -> c `elem` ("-_." :: String) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) value = Right (KeyId value)
  | otherwise = Left "a signing key ID has 1 to 64 ASCII letters, digits, -, _ or ."

keyIdText :: KeyId -> Text
keyIdText (KeyId value) = value

-- | A key's ID and its secret bytes. The bytes never reach a log.
data SigningKey = SigningKey
  { keyId :: !KeyId
  , secret :: !ByteString
  }
  deriving stock (Generic)

instance Show SigningKey where
  show key = "SigningKey " <> show (key ^. #keyId) <> " <secret>"

data SignedHeaders = SignedHeaders
  { eventId :: !Text
  , deliveryId :: !Text
  , timestamp :: !Integer
  , signature :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | The exact bytes a signature covers.
signingInput :: Integer -> Text -> Text -> ByteString -> ByteString
signingInput timestamp' eventId' deliveryId' body =
  BC.intercalate "\n" ["v1", BC.pack (show timestamp'), TE.encodeUtf8 eventId', TE.encodeUtf8 deliveryId'] <> "\n" <> body

macHex :: ByteString -> ByteString -> ByteString
macHex key input = BC.pack (show (hmacGetDigest (hmac key input :: HMAC SHA256)))

-- | The signature header for every key, in the order given.
signatureHeader :: [SigningKey] -> Integer -> Text -> Text -> ByteString -> Text
signatureHeader keys timestamp' eventId' deliveryId' body =
  T.intercalate "," ["v1;kid=" <> keyIdText (key ^. #keyId) <> ";sig=" <> TE.decodeUtf8 (macHex (key ^. #secret) input) | key <- keys]
  where
    input = signingInput timestamp' eventId' deliveryId' body

-- | The headers of one attempt. IDs with CR or LF are refused: they could
-- not be told apart in the signing input.
signRequest :: [SigningKey] -> Integer -> Text -> Text -> ByteString -> Either Text SignedHeaders
signRequest keys timestamp' eventId' deliveryId' body
  | null keys = Left "a webhook delivery has no signing key"
  | T.any (`elem` ("\r\n" :: String)) (eventId' <> deliveryId') = Left "an event or delivery ID holds a line break"
  | otherwise = Right (SignedHeaders eventId' deliveryId' timestamp' (signatureHeader keys timestamp' eventId' deliveryId' body))

data Verification
  = Verified !KeyId
  | Stale
  | Unsigned
  | Forged
  deriving stock (Eq, Show)

-- | Five minutes, in seconds.
timestampWindow :: Integer
timestampWindow = 300

-- | A receiver's check: the timestamp within the window of @now@, then a
-- signature entry of a known key ID whose MAC matches in constant time.
verifyRequest :: [SigningKey] -> Integer -> SignedHeaders -> ByteString -> Verification
verifyRequest keys now headers body
  | abs (now - headers ^. #timestamp) > timestampWindow = Stale
  | null entries = Unsigned
  | otherwise = case [key ^. #keyId | key <- keys, (kid, sig) <- entries, kid == keyIdText (key ^. #keyId), BA.constEq (TE.encodeUtf8 sig) (macHex (key ^. #secret) input)] of
      kid : _ -> Verified kid
      [] -> Forged
  where
    input = signingInput (headers ^. #timestamp) (headers ^. #eventId) (headers ^. #deliveryId) body
    entries =
      [ (kid, sig)
      | entry <- T.splitOn "," (headers ^. #signature)
      , ["v1", kidPart, sigPart] <- [T.splitOn ";" entry]
      , Just kid <- [T.stripPrefix "kid=" kidPart]
      , Just sig <- [T.stripPrefix "sig=" sigPart]
      ]
