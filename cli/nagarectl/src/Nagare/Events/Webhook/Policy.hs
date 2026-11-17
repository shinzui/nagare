{-# LANGUAGE OverloadedStrings #-}

-- | The webhook adapter's delivery policy (EP-234): how an HTTP result
-- becomes a transport-neutral outcome, and the default retry limits the
-- shared scheduler applies. Only 2xx acknowledges. 408, 429 and 5xx are
-- retried, honouring a valid @Retry-After@; other 3xx and 4xx are terminal.
-- A connection that never opened is retried; a timeout or a broken
-- response after the request may have been received is unknown, and its
-- retry may duplicate the event.
module Nagare.Events.Webhook.Policy
  ( webhookPolicy
  , requestTimeout
  , responseLimit
  , HttpResult (..)
  , classify
  , parseRetryAfter
  )
where

import Data.Aeson (object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Delivery.Transport
import Nagare.Events.Subscription (PolicyRef (..))

-- | At most ten automatic attempts within 24 hours, from ten seconds
-- doubling up to one hour with up to a quarter more of jitter, one
-- attempt in flight per subscription.
webhookPolicy :: RetryPolicy
webhookPolicy = RetryPolicy (PolicyRef "webhook" 1) 10 (24 * 3600) 10 3600 0.25 1

-- | Ten seconds for the whole request.
requestTimeout :: Int
requestTimeout = 10 * 1000000

-- | At most 64 KiB of a response is read.
responseLimit :: Int
responseLimit = 64 * 1024

data HttpResult
  = -- | A response: status, headers (lowercased names) and the captured body.
    Responded !Int ![(ByteString, ByteString)] !ByteString
  | -- | No connection was made: nothing was sent.
    NotConnected !Text
  | -- | The request may have been received: a timeout, a reset, a truncated response.
    Uncertain !Text
  deriving stock (Eq, Show)

classify :: UTCTime -> HttpResult -> Outcome
classify now = \case
  Responded status headers _
    | status >= 200 && status < 300 -> Acknowledged (Receipt "http" 1 (object ["status" .= status]))
    | status == 408 || status == 429 || (status >= 500 && status < 600) ->
        Retryable (lookup "retry-after" headers >>= parseRetryAfter now) ("the receiver answered " <> T.pack (show status))
    | otherwise -> Permanent ("the receiver answered " <> T.pack (show status))
  NotConnected why -> Retryable Nothing why
  Uncertain why -> Unknown why

-- | Delta seconds, or an HTTP date after @now@; at most 24 hours.
parseRetryAfter :: UTCTime -> ByteString -> Maybe NominalDiffTime
parseRetryAfter now raw = case BC.readInteger value of
  Just (seconds, rest) | BC.null rest && seconds >= 0 -> Just (min day (fromInteger seconds))
  _ -> do
    at <- parseTimeM True defaultTimeLocale "%a, %d %b %Y %H:%M:%S GMT" (T.unpack (TE.decodeLatin1 value))
    let delay = diffUTCTime at now
    if delay > 0 then Just (min day delay) else Nothing
  where
    value = BC.strip raw
    day = 24 * 3600
