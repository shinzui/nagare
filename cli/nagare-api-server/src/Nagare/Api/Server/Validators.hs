-- | Representation validators (RFC 9110 sections 8.8 and 13.1.2).
--
-- A strong ETag is the hash of the serving build's identity and the exact
-- representation bytes, so a changed binary never revalidates an old
-- representation. @If-None-Match@ compares weakly, accepts a list and @*@.
module Nagare.Api.Server.Validators
  ( entityTag
  , noneMatch
  , stateValidators
  , buildValidators
  , errorCacheControl
  )
where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Api.Response (Validators (..))
import Nagare.Contract.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types (digestText)

-- | The quoted strong ETag of a representation served by this build.
entityTag :: Text -> LBS.ByteString -> Text
entityTag build bytes = "\"" <> digestText (contentDigest (TE.encodeUtf8 build <> "\n" <> LBS.toStrict bytes)) <> "\""

-- | Whether an @If-None-Match@ value matches the current ETag, so the
-- request is answered 304. Weak comparison: @W/@ prefixes are ignored.
noneMatch :: Maybe Text -> Text -> Bool
noneMatch Nothing _ = False
noneMatch (Just header) current =
  any matches (map Text.strip (Text.splitOn "," header))
  where
    matches "*" = True
    matches candidate = opaque candidate == opaque current
    opaque tag = fromMaybe tag (Text.stripPrefix "W/" tag)

-- | Every use of a protected representation is revalidated, and a shared
-- cache must key it by credentials and media type.
stateValidators :: Text -> Validators
stateValidators tag = Validators {etag = tag, cacheControl = "private, no-cache", vary = "Authorization, Cookie, Accept"}

buildValidators :: Text -> Validators
buildValidators = stateValidators

-- | Errors are never stored.
errorCacheControl :: Text
errorCacheControl = "no-store"
