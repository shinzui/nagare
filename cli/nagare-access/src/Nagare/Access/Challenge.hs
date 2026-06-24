-- | Pure request classification helpers for login challenges.
module Nagare.Access.Challenge
  ( ChallengeMode (..)
  , RequestShape (..)
  , safeReturnDestination
  , loginPathFor
  , classifyChallenge
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types.Header (Header, HeaderName, hAccept)
import Network.HTTP.Types.URI (urlEncode)

data ChallengeMode
  = RedirectDocument Text
  | JsonApi Text
  deriving stock (Eq, Show)

data RequestShape = RequestShape
  { requestPath :: !Text
  , requestHeaders :: ![Header]
  }
  deriving stock (Eq, Show)

-- | Accept only same-host absolute paths. This prevents the login form's @rd@
-- field from becoming an open redirect.
safeReturnDestination :: Text -> Maybe Text
safeReturnDestination rd
  | Text.isPrefixOf "/" rd
  , not (Text.isPrefixOf "//" rd)
  , not ("://" `Text.isInfixOf` rd) =
      Just rd
  | otherwise = Nothing

loginPathFor :: Text -> Text
loginPathFor rd =
  "/_nagare/login?rd=" <> TE.decodeUtf8 (urlEncode True (TE.encodeUtf8 safeRd))
  where
    safeRd = maybe "/" id (safeReturnDestination rd)

classifyChallenge :: RequestShape -> ChallengeMode
classifyChallenge req
  | wantsJson req = JsonApi login
  | otherwise = RedirectDocument login
  where
    login = loginPathFor (requestPath req)

wantsJson :: RequestShape -> Bool
wantsJson req =
  hasHeaderValue "X-Requested-With" (== "XMLHttpRequest") hs
    || hasHeaderValue "Sec-Fetch-Mode" (`elem` ["cors", "same-origin"]) hs
    || hasHeaderValueBytes hAccept (BC.isInfixOf "application/json") hs
  where
    hs = requestHeaders req

hasHeaderValue :: HeaderName -> (BC.ByteString -> Bool) -> [Header] -> Bool
hasHeaderValue name p = hasHeaderValueBytes name (p . BC.strip)

hasHeaderValueBytes :: HeaderName -> (BC.ByteString -> Bool) -> [Header] -> Bool
hasHeaderValueBytes name p =
  any (\(n, v) -> n == name && p v)
