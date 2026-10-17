-- | One bounded JSON access line per request, probes excluded
-- (@mori://shinzui/haskell-jitsurei/docs/api-request-logging@).
--
-- The line carries the method, the path without its query string, the
-- status, the monotonic duration, the user agent, and what the handler did:
-- whether its representation came from the cache and whether it ran out of
-- time. It never carries a body, a credential, a cookie or the query string.
-- Writing it is one handle operation on the caller's sink (stdout in the
-- server, which the cluster's log collector reads), so no request waits on a
-- telemetry collector.
module Nagare.Api.Server.RequestLog
  ( requestLog
  )
where

import Control.Exception (onException)
import Data.Aeson (encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (getCurrentTime)
import GHC.Clock (getMonotonicTimeNSec)
import Nagare.Api.Server.Serve (Env, RequestStats (..), beginRequest, endRequest)
import Nagare.Contract.Prelude hiding ((.=))
import Network.HTTP.Types (hUserAgent, statusCode)
import Network.Wai (Middleware, rawPathInfo, requestHeaders, requestMethod, responseStatus)
import Servant.Health.Paths (healthRawPaths)

requestLog :: Env -> (ByteString -> IO ()) -> Middleware
requestLog env sink application request respond
  | rawPathInfo request `elem` healthRawPaths = application request respond
  | otherwise = do
      started <- getMonotonicTimeNSec
      beginRequest env
      (`onException` endRequest env) . application request $ \response -> do
        finished <- getMonotonicTimeNSec
        stats <- endRequest env
        now <- getCurrentTime
        let line =
              object
                [ "time" .= now
                , "method" .= decode (requestMethod request)
                , "path" .= decode (rawPathInfo request)
                , "status" .= statusCode (responseStatus response)
                , "duration_ms" .= (fromIntegral (finished - started) / 1000000 :: Double)
                , "user_agent" .= fmap decode (lookup hUserAgent (requestHeaders request))
                , "cache" .= fmap (\hit -> if hit then "hit" else "miss" :: Text) (stats ^. #cache)
                , "deadline_exceeded" .= (stats ^. #deadlineExceeded)
                ]
        sink (LBS.toStrict (encode line) <> "\n")
        respond response
  where
    decode = TE.decodeUtf8With lenientDecode
