{-# LANGUAGE OverloadedStrings #-}

-- | The webhook adapter (EP-234): it binds a subscription's webhook
-- destination — settings, signing keys read from their Secrets, a
-- connection policy — and publishes one signed POST per attempt.
--
-- Connections are made only to resolved addresses the policy allows, and
-- the connection uses exactly the address it validated, so a DNS answer
-- that changes between the check and the connect cannot redirect it. TLS
-- still verifies the certificate for the URL's host name. Loopback,
-- link-local, metadata and unspecified addresses are always refused;
-- private ranges only for a host the review allowed. No redirect is
-- followed, a request has ten seconds in all, and at most 64 KiB of a
-- response is read.
module Nagare.Events.Webhook.Transport
  ( AddressPolicy (..)
  , productionAddressPolicy
  , addressAllowed
  , SendRequest (..)
  , HttpSend
  , httpSend
  , webhookFactory
  , requestHeaders
  )
where

import Control.Exception (Exception, SomeException, bracketOnError, fromException, throwIO, try)
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Default (def)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Word (Word16, Word8)
import Nagare.Dsl.Prelude
import Nagare.Events.Delivery.Transport
import Nagare.Events.Webhook.Policy
import Nagare.Events.Webhook.Signature
import Nagare.Events.Webhook.Subscription
import Network.Connection qualified as NC
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.Internal qualified as HTTPI
import Network.HTTP.Types (statusCode)
import Network.Socket qualified as NS
import Network.Socket.ByteString qualified as NSB
import System.Timeout (timeout)

-- | Which resolved addresses a connection may use. Production never allows
-- loopback; a local integration test injects a policy that does.
newtype AddressPolicy = AddressPolicy {allowLoopback :: Bool}
  deriving stock (Eq, Show, Generic)

productionAddressPolicy :: AddressPolicy
productionAddressPolicy = AddressPolicy False

-- | Whether one resolved address may be connected to; @private@ is whether
-- the review allowed this host's private addresses.
addressAllowed :: AddressPolicy -> Bool -> NS.SockAddr -> Bool
addressAllowed policy private = \case
  NS.SockAddrInet _ host -> ipv4 (NS.hostAddressToTuple host)
  NS.SockAddrInet6 _ _ host _ -> ipv6 (NS.hostAddress6ToTuple host)
  _ -> False
  where
    ipv4 :: (Word8, Word8, Word8, Word8) -> Bool
    ipv4 (a, b, _, _)
      | a == 127 = policy ^. #allowLoopback
      | a == 0 || (a == 169 && b == 254) || a >= 224 = False
      | a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 100 && b >= 64 && b <= 127) = private
      | otherwise = True
    ipv6 :: (Word16, Word16, Word16, Word16, Word16, Word16, Word16, Word16) -> Bool
    ipv6 (a, b, c, d, e, f, g, h)
      | (a, b, c, d, e, f, g) == (0, 0, 0, 0, 0, 0, 0) = h == 1 && policy ^. #allowLoopback
      -- An IPv4-mapped address is judged as its IPv4 address.
      | (a, b, c, d, e) == (0, 0, 0, 0, 0) && f == 0xffff = ipv4 (fromIntegral (g `shiftR` 8), fromIntegral (g .&. 0xff), fromIntegral (h `shiftR` 8), fromIntegral (h .&. 0xff))
      | a .&. 0xffc0 == 0xfe80 || a .&. 0xff00 == 0xff00 = False
      | a .&. 0xfe00 == 0xfc00 = private
      | otherwise = True

data Refused = Refused !Text
  deriving stock (Show)

instance Exception Refused

data SendRequest = SendRequest
  { url :: !ReceiverUrl
  , headers :: ![(ByteString, ByteString)]
  , body :: !ByteString
  }
  deriving stock (Eq, Show, Generic)

-- | One POST and its classified result.
type HttpSend = SendRequest -> IO HttpResult

-- | The real interpreter for one destination: a manager whose connections
-- are bound to policy-checked addresses.
httpSend :: AddressPolicy -> Bool -> IO HttpSend
httpSend policy private = do
  context <- NC.initConnectionContext
  let open secure host port = do
        resolved <- try (NS.getAddrInfo (Just NS.defaultHints {NS.addrSocketType = NS.Stream}) (Just host) (Just (show port)))
        candidates <- case resolved of
          Left (_ :: SomeException) -> throwIO (Refused ("the receiver host " <> T.pack host <> " does not resolve"))
          Right found -> pure [address | address <- found, addressAllowed policy private (NS.addrAddress address)]
        address <- case candidates of
          first' : _ -> pure first'
          [] -> throwIO (Refused ("no address of the receiver host " <> T.pack host <> " is allowed"))
        bracketOnError (NS.socket (NS.addrFamily address) NS.Stream NS.defaultProtocol) NS.close $ \sock -> do
          NS.connect sock (NS.addrAddress address)
          if secure
            then do
              connection <- NC.connectFromSocket context sock (NC.ConnectionParams host (fromIntegral port) (Just def) Nothing)
              HTTPI.makeConnection (NC.connectionGetChunk connection) (NC.connectionPut connection) (NC.connectionClose connection)
            else HTTPI.makeConnection (NSB.recv sock 16384) (NSB.sendAll sock) (NS.close sock)
  manager <-
    HTTP.newManager
      HTTP.defaultManagerSettings
        { HTTP.managerRawConnection = pure (\_ host port -> open False host port)
        , HTTP.managerTlsConnection = pure (\_ host port -> open True host port)
        , HTTP.managerResponseTimeout = HTTP.responseTimeoutMicro requestTimeout
        , HTTP.managerRetryableException = const False
        }
  pure $ \request -> do
    let target = request ^. #url
        prepared =
          HTTP.defaultRequest
            { HTTP.method = "POST"
            , HTTP.secure = target ^. #secure
            , HTTP.host = TE.encodeUtf8 (target ^. #host)
            , HTTP.port = target ^. #port
            , HTTP.path = TE.encodeUtf8 (fst (T.breakOn "?" (target ^. #path)))
            , HTTP.queryString = TE.encodeUtf8 (snd (T.breakOn "?" (target ^. #path)))
            , HTTP.requestHeaders = [(CI.mk name, value) | (name, value) <- request ^. #headers]
            , HTTP.requestBody = HTTP.RequestBodyBS (request ^. #body)
            , HTTP.redirectCount = 0
            }
    outcome <- timeout requestTimeout . try $ HTTP.withResponse prepared manager $ \response -> do
      captured <- HTTP.brReadSome (HTTP.responseBody response) responseLimit
      pure (Responded (statusCode (HTTP.responseStatus response)) [(CI.foldedCase name, value) | (name, value) <- HTTP.responseHeaders response] (LBS.toStrict captured))
    pure $ case outcome of
      Nothing -> Uncertain "the request did not finish within ten seconds"
      Just (Right result) -> result
      Just (Left err) -> failure err
  where
    failure :: SomeException -> HttpResult
    failure err
      | Just (Refused why) <- fromException err = NotConnected why
      | Just (HTTP.HttpExceptionRequest _ content) <- fromException err = case content of
          HTTP.ConnectionFailure inner
            | Just (Refused why) <- fromException inner -> NotConnected why
            | otherwise -> NotConnected "the receiver refused or did not accept the connection"
          HTTP.ConnectionTimeout -> NotConnected "the connection to the receiver timed out"
          HTTP.ResponseTimeout -> Uncertain "the receiver did not answer in time"
          _ -> Uncertain "the response from the receiver was broken"
      | otherwise = Uncertain "the request to the receiver failed"

-- | The headers of one attempt, signed now.
requestHeaders :: [SigningKey] -> UTCTime -> PublicationRequest -> Either Text [(ByteString, ByteString)]
requestHeaders keys now request = do
  let stamp = floor (utcTimeToPOSIXSeconds now) :: Integer
  signed <- signRequest keys stamp (request ^. #eventId) (request ^. #deliveryId) (request ^. #body)
  pure
    [ ("content-type", "application/json")
    , ("user-agent", "nagare-events/1")
    , ("nagare-event-id", TE.encodeUtf8 (signed ^. #eventId))
    , ("nagare-delivery-id", TE.encodeUtf8 (signed ^. #deliveryId))
    , ("nagare-webhook-timestamp", BC.pack (show stamp))
    , ("nagare-webhook-signature", TE.encodeUtf8 (signed ^. #signature))
    ]

-- | The webhook transport for the delivery registry. @secretValue@ reads a
-- signing key's bytes; a missing or unreadable key fails the binding, which
-- pauses that destination with its reason. @connect@ builds the sender for
-- a destination (the real one is 'httpSend').
webhookFactory :: (SecretKeyRef -> IO (Either Text ByteString)) -> (Bool -> IO HttpSend) -> IO UTCTime -> AdapterFactory
webhookFactory secretValue connect clock = AdapterFactory bind' webhookRedirects
  where
    bind' spec = case decodeWebhookSettings spec of
      Left reason -> pure (Left reason)
      Right settings' -> do
        keys <- traverse key (settings' ^. #signing)
        case (,) <$> sequence keys <*> parseReceiverUrl (settings' ^. #allowHosts) (settings' ^. #url) of
          Left reason -> pure (Left reason)
          Right (signingKeys, target) -> do
            send <- connect (target ^. #host `elem` map T.toLower (settings' ^. #allowHosts))
            pure (Right (Adapter webhookTransport webhookPolicy (publish signingKeys target send)))
    key ref = do
      value <- secretValue ref
      pure $ do
        bytes <- first (\reason -> "signing key " <> ref ^. #keyId <> " cannot be read: " <> reason) value
        when (BS.length bytes < 16) (Left ("signing key " <> ref ^. #keyId <> " is shorter than 16 bytes"))
        kid <- mkKeyId (ref ^. #keyId)
        pure (SigningKey kid bytes)
    publish keys target send request = do
      now <- clock
      case requestHeaders keys now request of
        Left reason -> pure (Permanent reason)
        Right headers' -> classify now <$> send (SendRequest target headers' (request ^. #body))
