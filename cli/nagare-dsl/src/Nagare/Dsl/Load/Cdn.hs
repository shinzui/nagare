-- | Cdn responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Cdn
  ( JsonCdn (..)
  , toCdn
  )
where

import Data.Aeson
  ( FromJSON (parseJSON)
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  )
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Nagare.Dsl.Cdn.Types
  ( Cdn (..)
  , CdnProvider (CloudflareCdn, GcpCloudCdn)
  , mkCdnCacheRule
  )
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Prelude

-- ---------------------------------------------------------------------------
-- JSON intermediate for the optional CDN block (mirrors Nagare.Dsl.Config.cdnJSON)

-- | One entry of the @cdn.cacheRules@ array. @edgeTtlSeconds@ is read with
-- @.:?@ so a missing key is 'Nothing'; the encoder always writes the key (as
-- @null@ for the never-cache case), so the round-trip preserves 'Nothing'.
data JsonCdnCacheRule = JsonCdnCacheRule
  { pathPrefix :: !Text
  , edgeTtlSeconds :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonCdnCacheRule where
  parseJSON = withObject "CdnCacheRule" $ \o ->
    JsonCdnCacheRule <$> o .: "pathPrefix" <*> o .:? "edgeTtlSeconds"

-- | The decoded @"cdn"@ object. @cacheStaticAssets@ defaults to 'True' and
-- @cacheRules@ to @[]@ so a hand-written partial object is forgiving, mirroring
-- how 'JsonVolume'/'JsonHealthCheck' default their optional fields.
data JsonCdn = JsonCdn
  { provider :: !Text
  , defaultTtlSeconds :: !(Maybe Int)
  , cacheStaticAssets :: !Bool
  , cacheRules :: ![JsonCdnCacheRule]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonCdn where
  parseJSON = withObject "Cdn" $ \o ->
    JsonCdn
      <$> o .: "provider"
      <*> o .:? "defaultTtlSeconds"
      <*> o .:? "cacheStaticAssets" .!= True
      <*> o .:? "cacheRules" .!= []

-- | Re-validate a decoded @"cdn"@ object back into a 'Cdn', re-running the
-- per-path smart constructor and decoding the provider token. The provider
-- tokens are the wire contract fixed by EP-55 (@"Cloudflare"@ / @"GcpCloudCdn"@);
-- a negative @defaultTtlSeconds@ is rejected here because neither the encoder
-- nor 'Nagare.Dsl.Cdn.Types.withDefaultTtl' can catch a hand-written value.
toCdn :: JsonCdn -> Either LoadError Cdn
toCdn j = do
  prov <- case j ^. #provider of
    "Cloudflare" -> Right CloudflareCdn
    "GcpCloudCdn" -> Right GcpCloudCdn
    other -> Left (MarshalError "cdn.provider" ("unknown cdn provider: " <> other))
  case j ^. #defaultTtlSeconds of
    Just n
      | n < 0 ->
          Left (MarshalError "cdn.defaultTtlSeconds" ("must be >= 0, got: " <> Text.pack (show n)))
    _ -> Right ()
  rules <- traverse toCdnCacheRule (j ^. #cacheRules)
  Right
    Cdn
      { provider = prov
      , defaultTtlSeconds = j ^. #defaultTtlSeconds
      , cacheStaticAssets = j ^. #cacheStaticAssets
      , cacheRules = rules
      }
  where
    toCdnCacheRule r =
      first (MarshalError "cdn.cacheRules") $
        mkCdnCacheRule (r ^. #pathPrefix) (r ^. #edgeTtlSeconds)
