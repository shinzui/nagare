-- | Team identity for reviewed access relationships (MasterPlan 27, EP-187).
--
-- A team is an en @group@ object with flat user membership. Its key is an
-- immutable lowercase identifier chosen by the operator; en never sees a
-- display name, and a key is never rewritten into another one.
module Nagare.Resource.Access
  ( TeamKey
  , mkTeamKey
  , teamKeyText
  , validAccessEndpoint
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Text qualified as T
import Nagare.Dsl.Prelude

newtype TeamKey = TeamKey Text
  deriving stock (Eq, Ord, Show, Generic)

-- | @[a-z][a-z0-9_-]{0,62}@: a lowercase ASCII identifier that starts with a
-- letter. Anything else is refused rather than normalized, so the key an
-- operator typed is the key en stores.
mkTeamKey :: Text -> Either Text TeamKey
mkTeamKey raw
  | T.null raw = Left "team key must not be empty"
  | T.length raw > 63 = Left ("team key too long (" <> T.pack (show (T.length raw)) <> " chars, max 63)")
  | not (isAsciiLower (T.head raw)) = Left ("team key must start with a lowercase letter: " <> raw)
  | not (T.all keyChar raw) = Left ("team key contains invalid characters (allowed: a-z, 0-9, _, -): " <> raw)
  | otherwise = Right (TeamKey raw)
  where
    keyChar c = isAsciiLower c || isDigit c || c == '_' || c == '-'

teamKeyText :: TeamKey -> Text
teamKeyText (TeamKey t) = t

-- | The en endpoint a reviewed relationship was written through: an HTTP(S)
-- origin with a host and no user info, query, or fragment.
validAccessEndpoint :: Text -> Bool
validAccessEndpoint endpoint =
  ("https://" `T.isPrefixOf` endpoint || "http://" `T.isPrefixOf` endpoint)
    && not (T.any (\c -> c <= ' ' || c `elem` ("@?#" :: String)) endpoint)
    && not (T.null (T.takeWhile (/= '/') (T.drop 3 (snd (T.breakOn "://" endpoint)))))
