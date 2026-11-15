-- | The enforcer's control over what an edge in front of it may store
-- (ADR 34, EP-245 D1). It tightens the upstream's @Cache-Control@ rather
-- than replacing it, so validators, @max-age@ and @immutable@ still reach the
-- browser while no shared cache may store a protected response.
module Nagare.Access.EdgeCacheControl
  ( cdnOverrideHeaders
  , tightenCacheControl
  , tightenResponseHeaders
  , withProxiedCacheControl
  )
where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.Char (isSpace, toLower)
import Nagare.Access.Prelude
import Network.HTTP.Types (Header, HeaderName, hCacheControl)
import Network.Wai qualified as Wai

-- | Headers Cloudflare reads in preference to @Cache-Control@. Each could let
-- the edge store a response the tightened @Cache-Control@ forbids.
cdnOverrideHeaders :: [HeaderName]
cdnOverrideHeaders = ["Cloudflare-CDN-Cache-Control", "CDN-Cache-Control", "Surrogate-Control"]

-- | 'Nothing' leaves the response as the upstream sent it (direct mode).
-- @Just fallback@ tightens it; the fallback is the whole header for a
-- response that has none.
withProxiedCacheControl :: Maybe BS.ByteString -> Wai.Response -> Wai.Response
withProxiedCacheControl Nothing = id
withProxiedCacheControl (Just fallback) = Wai.mapResponseHeaders (tightenResponseHeaders fallback)

tightenResponseHeaders :: BS.ByteString -> [Header] -> [Header]
tightenResponseHeaders fallback headers =
  (hCacheControl, fromMaybe fallback (tightenCacheControl [value | (name, value) <- headers, name == hCacheControl]))
    : filter (\(name, _) -> name /= hCacheControl && name `notElem` cdnOverrideHeaders) headers

-- | Every @Cache-Control@ value of a response, merged and tightened:
-- @public@, @s-maxage@ and any qualified @private@ are dropped, a bare
-- @private@ leads, @no-transform@ ends, and every other directive is kept in
-- order. 'Nothing' when the upstream sent no directive at all.
tightenCacheControl :: [BS.ByteString] -> Maybe BS.ByteString
tightenCacheControl values =
  case concatMap directives values of
    [] -> Nothing
    found ->
      let kept = filter ((`notElem` ["public", "s-maxage", "private"]) . directiveName) found
          suffix = ["no-transform" | "no-transform" `notElem` map directiveName kept]
       in Just (B8.intercalate ", " ("private" : kept <> suffix))

directiveName :: BS.ByteString -> BS.ByteString
directiveName = B8.map toLower . trim . B8.takeWhile (/= '=')

-- | Split on commas outside quoted strings, so @no-cache="Set-Cookie, X"@ stays
-- one directive.
directives :: BS.ByteString -> [BS.ByteString]
directives = filter (not . BS.null) . map trim . go False [] . B8.unpack
  where
    go _ acc [] = [B8.pack (reverse acc)]
    go quoted acc ('\\' : c : rest) | quoted = go quoted (c : '\\' : acc) rest
    go quoted acc ('"' : rest) = go (not quoted) ('"' : acc) rest
    go False acc (',' : rest) = B8.pack (reverse acc) : go False [] rest
    go quoted acc (c : rest) = go quoted (c : acc) rest

trim :: BS.ByteString -> BS.ByteString
trim = B8.dropWhile isSpace . B8.dropWhileEnd isSpace
