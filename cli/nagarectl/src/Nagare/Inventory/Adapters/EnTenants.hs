-- | EP-262: the en Deployment's proof beyond its rollout. In tenant mode
-- (En ADR 10) @/health/ready@ stays 200 while any tenant serves, so a ready
-- Deployment no longer proves that each tenant opened its database. Apply's
-- verification, and recovery, read @en_tenant_available@ for every tenant the
-- reviewed Deployment declares, with the scrape key of @nagare-en-scrape-keys@.
--
-- A live runtime reads @GET /metrics@ through a private port-forward. An
-- interpreted runtime sends the read to its kubectl interpreter as
-- 'enMetricsRequest', so the fake cluster answers it from its own state
-- (ADR 25).
module Nagare.Inventory.Adapters.EnTenants
  ( enDeclaredTenants
  , TenantVerdict (..)
  , tenantAvailability
  , lastUnavailableReason
  , proveEnTenants
  , enMetricsRequest
  , enScrapeKeySecret
  )
where

import Control.Monad (join)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Database.Secret (b64decode)
import Nagare.Dsl.Prelude
import Nagare.Inventory.EnForward (enRequest, withEnForward)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), dispatchKubectl, invokeKubectl, runtimeLive, runtimePause)
import System.Exit (ExitCode (..))

-- | The Secret whose @metrics@ key En accepts in @EN_METRICS_KEYS@.
enScrapeKeySecret :: Text
enScrapeKeySecret = "nagare-en-scrape-keys"

-- | The tenants a reviewed native object declares, when it is the en
-- Deployment in @nagare-system@ and sets @EN_TENANTS@; otherwise 'Nothing',
-- and the object needs no tenant proof.
enDeclaredTenants :: ByteString -> Maybe [Text]
enDeclaredTenants native = do
  Object root <- either (const Nothing) Just (eitherDecodeStrict native)
  guard (KM.lookup "kind" root == Just (String "Deployment"))
  Object metadata <- KM.lookup "metadata" root
  guard (KM.lookup "name" metadata == Just (String "en"))
  guard (KM.lookup "namespace" metadata == Just (String "nagare-system"))
  Object spec <- KM.lookup "spec" root
  Object template <- KM.lookup "template" spec
  Object podSpec <- KM.lookup "spec" template
  Array containers <- KM.lookup "containers" podSpec
  listToMaybe
    [ tenants
    | Object container <- toList containers
    , KM.lookup "name" container == Just (String "en")
    , Just (Array env) <- [KM.lookup "env" container]
    , Object variable <- toList env
    , KM.lookup "name" variable == Just (String "EN_TENANTS")
    , Just (String value) <- [KM.lookup "value" variable]
    , let tenants = filter (not . T.null) (map T.strip (T.splitOn "," value))
    , not (null tenants)
    ]

-- | What one scrape says about the declared tenants.
data TenantVerdict
  = TenantsAvailable
  | -- | The first declared tenant whose gauge is 0, or absent.
    TenantUnavailable !Text
  deriving stock (Eq, Show)

-- | Every declared tenant must report @en_tenant_available{tenant="X"} 1@.
-- A tenant with no sample is unavailable: the scrape key sees every tenant,
-- so a missing sample is a tenant En does not serve.
tenantAvailability :: [Text] -> Text -> TenantVerdict
tenantAvailability tenants body =
  case [tenant | tenant <- tenants, lookup tenant samples /= Just "1"] of
    tenant : _ -> TenantUnavailable tenant
    [] -> TenantsAvailable
  where
    samples = mapMaybe sample (T.lines body)
    sample line = do
      rest <- T.stripPrefix "en_tenant_available{tenant=\"" (T.strip line)
      let (tenant, after) = T.breakOn "\"}" rest
      value <- T.stripPrefix "\"}" after
      pure (tenant, T.strip value)

-- | The reason of En's last @[tenant X] UNAVAILABLE: reason@ line, when the
-- tenant has not logged @AVAILABLE@ since.
lastUnavailableReason :: Text -> Text -> Maybe Text
lastUnavailableReason tenant logs =
  case reverse (mapMaybe state (T.lines logs)) of
    Just reason : _ -> Just reason
    _ -> Nothing
  where
    prefix = "[tenant " <> tenant <> "] "
    state line = do
      rest <- T.stripPrefix prefix (T.strip (snd (T.breakOn prefix line)))
      case T.stripPrefix "UNAVAILABLE: " rest of
        Just reason -> Just (Just reason)
        Nothing | rest == "AVAILABLE" -> Just Nothing
        Nothing -> Nothing

-- | The interpreted form of the metrics read: the request a fake cluster
-- answers with En's status on the first line and its body after it. The
-- input carries the scrape key.
enMetricsRequest :: [String]
enMetricsRequest = ["port-forward", "-n", "nagare-system", "svc/en", ":80", "--", "GET", "/metrics"]

-- | Prove every tenant available, retrying while En opens a store (up to a
-- minute after its rollout), and name the first unavailable tenant with En's
-- reason. The key is read from the cluster and never printed.
proveEnTenants :: KubernetesRuntimeConfig -> [Text] -> IO (Either Text ())
proveEnTenants config tenants = do
  guarded <- runtimeGuard config
  case guarded of
    Left reason -> pure (Left ("cluster guard refused the en tenant proof: " <> reason))
    Right () -> do
      key <- readScrapeKey
      case key of
        Left reason -> pure (Left reason)
        Right secret -> attempt (12 :: Int) secret
  where
    attempt remaining secret = do
      verdict <- scrape secret
      case verdict of
        Right TenantsAvailable -> pure (Right ())
        _ | remaining > 1 -> runtimePause config 5000000 >> attempt (remaining - 1) secret
        Left reason -> pure (Left reason)
        Right (TenantUnavailable tenant) -> Left <$> explain tenant
    scrape secret = do
      fetched <- metrics secret
      pure $ case fetched of
        Left reason -> Left ("en metrics could not be read: " <> reason)
        Right (200, body) -> Right (tenantAvailability tenants (TE.decodeUtf8With (\_ _ -> Just '?') body))
        Right (code, _) -> Left ("en metrics answered " <> T.pack (show code) <> " to the scrape key")
    metrics secret
      | runtimeLive config =
          fmap join . withEnForward (runtimeKubectlContext config) $ \base ->
            enRequest (T.unpack secret) base "GET" "/metrics" Null
      | otherwise = do
          answered <- dispatchKubectl config enMetricsRequest (T.unpack secret)
          pure $ case answered of
            Right (ExitSuccess, output, _) -> case T.breakOn "\n" (T.pack output) of
              (code, body) | [(status, "")] <- reads (T.unpack code) -> Right (status, TE.encodeUtf8 (T.drop 1 body))
              _ -> Left "malformed interpreted en metrics answer"
            _ -> Left "en port-forward failed"
    readScrapeKey = do
      read' <- invokeKubectl config ["get", "secret", T.unpack enScrapeKeySecret, "-n", "nagare-system", "-o", "json"] ""
      pure $ case read' of
        Right (ExitSuccess, output, _) -> do
          value <- first (const "en scrape key Secret is malformed") (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)))
          encoded <- case value of
            Object root | Just (Object entries) <- KM.lookup "data" root, Just (String encoded) <- KM.lookup "metrics" entries -> Right encoded
            _ -> Left "en scrape key Secret has no metrics key"
          secret <- first (const "en scrape key is not base64") (b64decode encoded)
          unless (not (T.null secret)) (Left "en scrape key is empty")
          pure secret
        _ -> Left ("en scrape key Secret " <> enScrapeKeySecret <> " could not be read")
    explain tenant = do
      logs <- invokeKubectl config ["logs", "deployment/en", "-n", "nagare-system", "-c", "en", "--tail=500"] ""
      let reason = case logs of
            Right (ExitSuccess, output, _) -> lastUnavailableReason tenant (T.pack output)
            _ -> Nothing
      pure ("en tenant " <> tenant <> " unavailable" <> maybe "" (": " <>) reason)
