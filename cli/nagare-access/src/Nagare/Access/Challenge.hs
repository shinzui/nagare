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
import Data.Char (toLower)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Access.Prelude
import Network.HTTP.Types.Header (Header, HeaderName, hAccept, hAuthorization)
import Network.HTTP.Types.URI (urlEncode)

data ChallengeMode
  = RedirectDocument Text
  | JsonApi Text
  deriving stock (Generic, Eq, Show)

-- | What a challenge depends on. 'api' is set when the path is under the
-- backend's API prefix; such a request is always answered as an API call,
-- whatever it accepts, so a machine client sending @Accept: */*@ (or no
-- Accept at all) is never redirected to a login page.
data RequestShape = RequestShape
  { path :: !Text
  , headers :: ![Header]
  , api :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | Accept only same-host absolute paths. This prevents the login form's @rd@
-- field from becoming an open redirect.
--
-- Backslashes are rejected as well as slashes: browsers normalize @\\@ to @/@
-- when resolving a @Location@, so @\/\\evil.com@ would be followed as
-- @\/\/evil.com@ — a protocol-relative URL pointing off-site. Characters below
-- space (and DEL) are rejected because this value is written into a response
-- header, where a CR or LF would split it.
safeReturnDestination :: Text -> Maybe Text
safeReturnDestination rd
  | Text.isPrefixOf "/" rd
  , not (Text.isPrefixOf "//" rd)
  , not ("://" `Text.isInfixOf` rd)
  , not (Text.any forbiddenReturnChar rd) =
      Just rd
  | otherwise = Nothing

-- | Characters that may never appear in a return destination.
forbiddenReturnChar :: Char -> Bool
forbiddenReturnChar c = c == '\\' || c < ' ' || c == '\DEL'

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
    login = loginPathFor (req ^. #path)

wantsJson :: RequestShape -> Bool
wantsJson req =
  req ^. #api
    || hasHeaderValue "X-Requested-With" (== "XMLHttpRequest") hs
    || hasHeaderValue "Sec-Fetch-Mode" (`elem` ["cors", "same-origin"]) hs
    || hasHeaderValue hAuthorization (BC.isPrefixOf "bearer " . BC.map toLower) hs
    || hasHeaderValueBytes hAccept prefersJson hs
  where
    hs = req ^. #headers

-- | Whether an Accept header ranks a JSON media type (@application/json@ or
-- any structured @+json@ suffix) at least as high as HTML, with a nonzero
-- quality. Wildcards count for neither, so a browser's
-- @text/html,…,*/*;q=0.8@ is still a document request.
prefersJson :: BC.ByteString -> Bool
prefersJson accept =
  jsonQ > 0 && jsonQ >= htmlQ
  where
    ranges = map mediaRange (BC.split ',' accept)
    best p = maximum (0 : [q | (media, q) <- ranges, p media])
    jsonQ = best (\m -> m == "application/json" || "+json" `BC.isSuffixOf` m)
    htmlQ = best (`elem` ["text/html", "application/xhtml+xml"])

mediaRange :: BC.ByteString -> (BC.ByteString, Double)
mediaRange range =
  case map BC.strip (BC.split ';' range) of
    media : params -> (BC.map toLower media, foldr quality 1 params)
    [] -> ("", 0)
  where
    quality param q =
      case BC.break (== '=') param of
        (name, value)
          | BC.map toLower (BC.strip name) == "q"
          , [(parsed, "")] <- reads (BC.unpack (BC.strip (BC.drop 1 value)))
          , parsed >= 0
          , parsed <= 1 ->
              parsed
        _ -> q

hasHeaderValue :: HeaderName -> (BC.ByteString -> Bool) -> [Header] -> Bool
hasHeaderValue name p = hasHeaderValueBytes name (p . BC.strip)

hasHeaderValueBytes :: HeaderName -> (BC.ByteString -> Bool) -> [Header] -> Bool
hasHeaderValueBytes name p =
  any (\(n, v) -> n == name && p v)
