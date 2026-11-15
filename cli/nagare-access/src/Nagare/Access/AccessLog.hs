-- | One bounded JSON access line per request, probes excluded (EP-245 D4,
-- @mori://shinzui/haskell-jitsurei/docs/api-request-logging@).
--
-- The line carries the time, host, method, path without its query string,
-- status, monotonic duration and user agent. It never carries a body, a
-- cookie, a credential or the query string.
--
-- Behind Cloudflare ('EdgeAttribution') it also carries @CF-Connecting-IP@
-- and @CF-Ray@, for attribution only: nothing authorizes, throttles or
-- decides on them, because a pod in the cluster can reach Kourier with a
-- forged header. Without an edge the middleware removes both headers from the
-- request, so no upstream (the admin API included) ever sees a value a
-- direct client chose.
module Nagare.Access.AccessLog
  ( EdgeAttribution (..)
  , accessLog
  , parseEdgeAttribution
  )
where

import Data.Aeson (Key, Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (getCurrentTime)
import GHC.Clock (getMonotonicTimeNSec)
import Nagare.Access.Prelude hiding ((.=))
import Network.HTTP.Types (HeaderName, hUserAgent, statusCode)
import Network.Wai qualified as Wai

data EdgeAttribution = NoEdgeAttribution | CloudflareAttribution
  deriving stock (Eq, Show)

-- | @NAGARE_ACCESS_EDGE_ATTRIBUTION@: unset means no edge; @cloudflare@ is
-- the only other value.
parseEdgeAttribution :: Maybe Text -> Either Text EdgeAttribution
parseEdgeAttribution Nothing = Right NoEdgeAttribution
parseEdgeAttribution (Just "cloudflare") = Right CloudflareAttribution
parseEdgeAttribution (Just _) = Left "NAGARE_ACCESS_EDGE_ATTRIBUTION must be unset or cloudflare"

edgeHeaders :: [HeaderName]
edgeHeaders = ["CF-Connecting-IP", "CF-Ray"]

accessLog :: EdgeAttribution -> (ByteString -> IO ()) -> Wai.Middleware
accessLog attribution sink application incoming respond
  | Wai.rawPathInfo request == "/_nagare/healthz" = application request respond
  | otherwise = do
      started <- getMonotonicTimeNSec
      application request $ \response -> do
        finished <- getMonotonicTimeNSec
        now <- getCurrentTime
        let line =
              object $
                [ "time" .= now
                , "host" .= fmap bounded (Wai.requestHeaderHost request)
                , "method" .= bounded (Wai.requestMethod request)
                , "path" .= bounded (Wai.rawPathInfo request)
                , "status" .= statusCode (Wai.responseStatus response)
                , "duration_ms" .= (fromIntegral (finished - started) / 1000000 :: Double)
                , "user_agent" .= fmap bounded (header hUserAgent)
                ]
                  <> edgeFields
        sink (LBS.toStrict (encode line) <> "\n")
        respond response
  where
    request = case attribution of
      CloudflareAttribution -> incoming
      NoEdgeAttribution -> incoming {Wai.requestHeaders = filter ((`notElem` edgeHeaders) . fst) (Wai.requestHeaders incoming)}
    header name = lookup name (Wai.requestHeaders request)
    edgeFields :: [(Key, Value)]
    edgeFields = case attribution of
      NoEdgeAttribution -> []
      CloudflareAttribution ->
        [ "cf_connecting_ip" .= fmap bounded (header "CF-Connecting-IP")
        , "cf_ray" .= fmap bounded (header "CF-Ray")
        ]
    bounded = TE.decodeUtf8With lenientDecode . BS.take 256
