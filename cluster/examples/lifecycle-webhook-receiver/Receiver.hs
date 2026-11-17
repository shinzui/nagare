#!/usr/bin/env cabal
{- cabal:
build-depends: base, bytestring, containers, crypton, http-types, time, wai, warp, directory
-}
{-# LANGUAGE OverloadedStrings #-}

-- | A minimal receiver of Nagare lifecycle webhooks (EP-234), independent of
-- Nagare's own code. It checks the timestamp is within five minutes,
-- recomputes the v1 HMAC-SHA256 over "v1", the timestamp, the event ID and
-- the delivery ID, each followed by LF, then the raw body, compares it in
-- constant time with each signature entry, and performs its side effect once
-- per event ID, remembered in a file so a restart does not repeat it.
--
-- Run: NAGARE_WEBHOOK_KEY=... PORT=8080 cabal run Receiver.hs
module Main (main) where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.Bits (xor, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Set qualified as Set
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Types (status200, status400, status401)
import Network.Wai (Application, requestHeaders, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (run)
import System.Directory (doesFileExist)
import System.Environment (getEnv, lookupEnv)

main :: IO ()
main = do
  key <- BC.pack <$> getEnv "NAGARE_WEBHOOK_KEY"
  port <- maybe 8080 read <$> lookupEnv "PORT"
  let store = "processed-events.txt"
  known <- doesFileExist store >>= \exists -> if exists then Set.fromList . BC.lines <$> BC.readFile store else pure Set.empty
  processed <- newMVar known
  run port (receiver key store processed)

receiver :: ByteString -> FilePath -> MVar (Set.Set ByteString) -> Application
receiver key store processed request respond = do
  body <- LBS.toStrict <$> strictRequestBody request
  now <- floor <$> getPOSIXTime :: IO Integer
  let header name = maybe "" id (lookup name (requestHeaders request))
      eventId = header "Nagare-Event-Id"
      deliveryId = header "Nagare-Delivery-Id"
      stamp = header "Nagare-Webhook-Timestamp"
      input = BC.intercalate "\n" ["v1", stamp, eventId, deliveryId] <> "\n" <> body
      expected = BC.pack (show (hmacGetDigest (hmac key input :: HMAC SHA256)))
      entries = [BC.drop 4 sig | entry <- BC.split ',' (header "Nagare-Webhook-Signature"), [v, _kid, sig] <- [BC.split ';' entry], v == "v1", "sig=" `BC.isPrefixOf` sig]
  case BC.readInteger stamp of
    Just (sent, "") | abs (now - sent) <= 300 ->
      if any (constEq expected) entries
        then do
          fresh <- modifyMVar processed $ \seen ->
            if Set.member eventId seen
              then pure (seen, False)
              else BC.appendFile store (eventId <> "\n") >> pure (Set.insert eventId seen, True)
          -- The side effect runs once per event ID; a retry is acknowledged too.
          if fresh then BC.putStrLn ("processed " <> eventId <> ": " <> body) else BC.putStrLn ("duplicate " <> eventId)
          respond (responseLBS status200 [] "ok")
        else respond (responseLBS status401 [] "bad signature")
    _ -> respond (responseLBS status400 [] "stale or missing timestamp")

-- | Equal bytes, in time independent of where they differ.
constEq :: ByteString -> ByteString -> Bool
constEq a b = BS.length a == BS.length b && foldr (.|.) 0 (BS.zipWith xor a b) == 0
