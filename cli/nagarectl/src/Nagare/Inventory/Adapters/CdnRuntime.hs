{-# LANGUAGE ScopedTypeVariables #-}

-- | Cloud DNS transport for reviewed A-record changes. The DNS API applies
-- additions and exact old-record deletions atomically; provider errors after
-- submission remain ambiguous until an operator reviews the transaction.
module Nagare.Inventory.Adapters.CdnRuntime
  ( DnsRuntimeConfig (..)
  , DnsChangeStatus (..)
  , dnsRuntimeOps
  , dnsChangeBody
  , parseDnsChangeStatus
  , parseExactDnsListing
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Data.Aeson (Value (..), eitherDecodeStrict, encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isDigit)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (AdapterExecution (..))
import Nagare.Inventory.Adapters.Cdn
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Resource.Inventory (ManagedResource (..))
import Nagare.Resource.Types
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data DnsRuntimeConfig = DnsRuntimeConfig
  { dnsRuntimeProject :: !Name
  , dnsRuntimeGuard :: !(ResourceId -> IO (Either Text ()))
  , dnsRuntimeSpecs :: !(Map ResourceId DnsBinding)
  }

dnsRuntimeOps :: DnsRuntimeConfig -> DnsAdapterOps
dnsRuntimeOps config = DnsAdapterOps
  { dnsInspect = \resource -> do
      guarded <- dnsRuntimeGuard config resource
      case guarded of
        Left reason -> pure (DnsUnavailable reason)
        Right () -> case Map.lookup resource (dnsRuntimeSpecs config) of
          Nothing -> pure (DnsUnavailable "DNS resource is absent from the runtime binding")
          Just binding -> case dnsDeclaration binding ^. #address of
            DnsRecord project zone host
              | project == dnsRuntimeProject config -> do
                  listed <- runGcloud
                    ["dns", "record-sets", "list", "--name=" <> nameText host <> "."
                    ,"--type=A", "--zone=" <> nameText zone, "--format=json"
                    ,"--project=" <> nameText project]
                  pure $ case listed >>= parseExactDnsListing host of
                    Left reason -> DnsUnavailable reason
                    Right Nothing -> DnsMissing
                    Right (Just (target, ttl)) ->
                      let physical = either (error . T.unpack) id
                            (mkPhysicalIdentity ("dns:" <> nameText project <> "/"
                              <> nameText zone <> "/" <> nameText host))
                       in DnsPresent physical target ttl
              | otherwise -> pure (DnsUnavailable "DNS project differs from the active context")
            _ -> pure (DnsUnavailable "DNS binding has an unexpected provider address")
  , dnsCreate = submit config
  , dnsReplace = submit config
  }

dnsChangeBody :: DnsMutationPlan -> Value
dnsChangeBody plan = object
  [ "additions" .= [record (dnsPlanTarget plan) (dnsPlanTtl plan)]
  , "deletions" .= maybe ([] :: [Value]) (\(target, ttl) -> [record target ttl]) (dnsPlanPrevious plan)
  ]
  where
    record target ttl = object
      ["name" .= (nameText (dnsPlanHost plan) <> ".")
      ,"type" .= ("A" :: Text), "ttl" .= ttl, "rrdatas" .= [target]]

data DnsChangeStatus = DnsChangeDone | DnsChangePending !Text
  deriving stock (Eq, Show)

parseDnsChangeStatus :: ByteString -> Either Text DnsChangeStatus
parseDnsChangeStatus bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  fields <- case value of
    Object values -> Right values
    _ -> Left "Cloud DNS change response is not an object"
  status <- required "status" fields
  case status :: Text of
    "done" -> Right DnsChangeDone
    "pending" -> do
      changeId <- required "id" fields
      unless (not (T.null changeId) && T.all isDigit changeId)
        (Left "Cloud DNS change response has an invalid ID")
      Right (DnsChangePending changeId)
    _ -> Left "Cloud DNS change response has an unknown status"
  where
    required key fields = case KM.lookup key fields of
      Nothing -> Left ("Cloud DNS change response has no " <> Key.toText key)
      Just value -> case Aeson.fromJSON value of
        Aeson.Success parsed -> Right parsed
        Aeson.Error _ -> Left ("Cloud DNS change response has invalid " <> Key.toText key)

-- | A successful exact-name gcloud listing is the only absence proof. One
-- RRset with exactly one A value is the bounded shape this adapter owns.
parseExactDnsListing :: Name -> ByteString -> Either Text (Maybe (Text, Int))
parseExactDnsListing host bytes = case eitherDecodeStrict bytes of
  Left reason -> Left (T.pack reason)
  Right (Array records) | null records -> Right Nothing
  Right (Array records) | [Object fields] <- toList records -> do
    name <- field "name" fields
    kind <- field "type" fields
    ttl <- field "ttl" fields
    values <- field "rrdatas" fields
    unless (name == nameText host <> "." && kind == ("A" :: Text))
      (Left "DNS listing returned a different name or type")
    case values of
      [target] -> Right (Just (target, ttl))
      _ -> Left "DNS A record has multiple targets"
  Right _ -> Left "DNS listing did not return zero or one record"
  where
    field :: (Aeson.FromJSON a) => Text -> KM.KeyMap Value -> Either Text a
    field key fields = case KM.lookup (Key.fromText key) fields of
      Nothing -> Left ("DNS record has no " <> key)
      Just value -> case Aeson.fromJSON value of
        Aeson.Success parsed -> Right parsed
        Aeson.Error reason -> Left ("DNS " <> key <> " is invalid: " <> T.pack reason)

submit :: DnsRuntimeConfig -> DnsMutationPlan -> IO AdapterExecution
submit config plan
  | dnsPlanProject plan /= dnsRuntimeProject config =
      pure (AdapterEffectFailed (KnownNoEffect "DNS project differs from the active context"))
  | otherwise = do
      guarded <- dnsRuntimeGuard config (dnsPlanResource plan)
      case guarded of
        Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
        Right () -> do
          tokenResult <- runGcloud ["auth", "print-access-token"]
          case tokenResult of
            Left reason -> pure (AdapterEffectFailed (KnownNoEffect ("Cloud DNS authentication failed: " <> reason)))
            Right tokenBytes -> do
              let token = BC.takeWhile (/= '\n') tokenBytes
                  endpoint = "https://dns.googleapis.com/dns/v1/projects/"
                    <> nameText (dnsPlanProject plan) <> "/managedZones/"
                    <> nameText (dnsPlanZone plan) <> "/changes"
              request <- parseRequest (T.unpack endpoint)
              manager <- newTlsManager
              let change = request
                    { method = "POST"
                    , requestHeaders = [("Authorization", "Bearer " <> token), ("Content-Type", "application/json")]
                    , requestBody = RequestBodyLBS (encode (dnsChangeBody plan))
                    }
              result <- try (httpLbs change manager)
              case result of
                Left (_ :: HttpException) -> pure (AdapterEffectAmbiguous "Cloud DNS request failed after submission")
                Right response
                  | statusCode (responseStatus response) `elem` [200, 201] ->
                      case parseDnsChangeStatus (LBS.toStrict (responseBody response)) of
                        Left reason -> pure (AdapterEffectAmbiguous reason)
                        Right changeStatus -> do
                          settled <- awaitChange manager token endpoint changeStatus 12
                          case settled of
                            Left reason -> pure (AdapterEffectAmbiguous reason)
                            Right () -> awaitDnsRecord plan 8
                  | otherwise -> pure (AdapterEffectAmbiguous
                      ("Cloud DNS change returned HTTP " <> T.pack (show (statusCode (responseStatus response)))))

awaitChange :: Manager -> ByteString -> Text -> DnsChangeStatus -> Int -> IO (Either Text ())
awaitChange _ _ _ DnsChangeDone _ = pure (Right ())
awaitChange _ _ _ (DnsChangePending _) 0 = pure (Left "Cloud DNS change is still pending")
awaitChange manager token endpoint (DnsChangePending changeId) remaining = do
  threadDelay 1000000
  request <- parseRequest (T.unpack (endpoint <> "/" <> changeId))
  let checked = request {requestHeaders = [("Authorization", "Bearer " <> token)]}
  result <- try (httpLbs checked manager)
  case result of
    Left (_ :: HttpException) -> pure (Left "Cloud DNS change status could not be read")
    Right response
      | statusCode (responseStatus response) == 200 ->
          case parseDnsChangeStatus (LBS.toStrict (responseBody response)) of
            Right status -> awaitChange manager token endpoint status (remaining - 1)
            Left reason -> pure (Left reason)
      | otherwise -> pure (Left "Cloud DNS change status returned an unsuccessful response")

awaitDnsRecord :: DnsMutationPlan -> Int -> IO AdapterExecution
awaitDnsRecord plan attempts = do
  listed <- runGcloud
    ["dns", "record-sets", "list", "--name=" <> nameText (dnsPlanHost plan) <> "."
    ,"--type=A", "--zone=" <> nameText (dnsPlanZone plan), "--format=json"
    ,"--project=" <> nameText (dnsPlanProject plan)]
  case listed >>= parseExactDnsListing (dnsPlanHost plan) of
    Right (Just (target, ttl))
      | (target, ttl) == (dnsPlanTarget plan, dnsPlanTtl plan) ->
          pure AdapterEffectCompleted
    _ | attempts <= 1 -> pure (AdapterEffectAmbiguous
          "Cloud DNS change settled but its exact target record is not yet observable")
      | otherwise -> threadDelay 1000000 >> awaitDnsRecord plan (attempts - 1)

runGcloud :: [Text] -> IO (Either Text ByteString)
runGcloud args = do
  result <- try (readProcessWithExitCode "gcloud" (map T.unpack args) "")
  pure $ case result of
    Left (err :: IOException) -> Left (T.pack (show err))
    Right (ExitSuccess, out, _) -> Right (TE.encodeUtf8 (T.pack out))
    Right (ExitFailure code, _, err) -> Left ("gcloud exit " <> T.pack (show code) <> ": " <> T.pack err)
