-- | Fail-closed origin-TLS checks shared by ordinary, static, and server
-- deploys. The module performs reads only; Knative and net-certmanager remain
-- the owners of certificate creation.
module Nagare.Domain.Tls
  ( TlsPreflightOps (..)
  , defaultTlsPreflightOps
  , preflightDomainTls
  , preflightDomainTlsWith
  , verifyDomainTlsReady
  , verifyDomainTlsReadyWith
  , parseManagedZoneNames
  , parseIssuerName
  , secretHasTlsKeys
  , renderDomainTlsCheck
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (find)
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (DomainSpec, DomainTls (..), domainText, secretNameText)
import Nagare.Ops.Domains
  ( CertificateEvidence (..)
  , CertificateState (..)
  , Observation (..)
  , TlsMode (..)
  , certificateStateFor
  , extractCertificateEvidence
  , parseClusterIssuerObservation
  , parseTlsMode
  )
import Nagare.Ops.Probe (captureTool)
import Nagare.Target (Mode (..), TargetProfile)

newtype TlsPreflightOps = TlsPreflightOps
  { runTool :: String -> [String] -> IO (Either Text ByteString)
  }
  deriving stock (Generic)

defaultTlsPreflightOps :: TlsPreflightOps
defaultTlsPreflightOps =
  TlsPreflightOps $ \executable args -> do
    result <- captureTool executable args
    pure $ maybe (Left (T.pack executable <> " failed or is unavailable")) Right result

preflightDomainTls :: TargetProfile -> Text -> Text -> [DomainSpec] -> IO (Either Text ())
preflightDomainTls = preflightDomainTlsWith defaultTlsPreflightOps

preflightDomainTlsWith :: TlsPreflightOps -> TargetProfile -> Text -> Text -> [DomainSpec] -> IO (Either Text ())
preflightDomainTlsWith ops profile base namespace domains = do
  automaticEnvironment <-
    if null automatic
      then pure (Right ())
      else verifyAutomaticEnvironment ops
  case automaticEnvironment of
    Left err -> pure (Left err)
    Right () -> do
      zones <- requiredZones
      case zones of
        Left err -> pure (Left err)
        Right authoritativeZones -> do
          let unsupported =
                [ hostname
                | spec <- automatic
                , let hostname = domainText (spec ^. #domain)
                , profile ^. #mode == Cloud
                , not (underDomain base hostname)
                , not (any (`underDomain` hostname) authoritativeZones)
                ]
          case unsupported of
            hostname : _ -> pure (Left (unsupportedAuthority hostname (profile ^. #project)))
            [] -> checkSuppliedSecrets ops namespace supplied
  where
    automatic = [spec | spec <- domains, spec ^. #tls == AutomaticTls]
    supplied = [spec | spec <- domains, isSupplied (spec ^. #tls)]
    isSupplied (SuppliedTlsSecret _) = True
    isSupplied AutomaticTls = False
    needsZoneLookup =
      profile ^. #mode == Cloud
        && any (not . underDomain base . domainText . (^. #domain)) automatic
    requiredZones
      | not needsZoneLookup = pure (Right [])
      | otherwise = do
          response <-
            runTool
              ops
              "gcloud"
              [ "dns"
              , "managed-zones"
              , "list"
              , "--format=json"
              , "--project=" <> T.unpack (profile ^. #project)
              ]
          pure (response >>= parseManagedZoneNames)

verifyAutomaticEnvironment :: TlsPreflightOps -> IO (Either Text ())
verifyAutomaticEnvironment ops = do
  network <- runTool ops "kubectl" ["-n", "knative-serving", "get", "configmap", "config-network", "-o", "json"]
  certManager <- runTool ops "kubectl" ["-n", "knative-serving", "get", "configmap", "config-certmanager", "-o", "json"]
  case (network >>= parseTlsMode, certManager >>= parseIssuerName) of
    (Left err, _) -> pure (Left ("cannot verify external-domain TLS: " <> err))
    (_, Left err) -> pure (Left ("cannot verify the configured certificate issuer: " <> err))
    (Right TlsGloballyDisabled, _) ->
      pure (Left "automatic TLS was requested, but Knative external-domain-tls is disabled")
    (Right TlsEnabled, Right issuerName) -> do
      issuer <- runTool ops "kubectl" ["get", "clusterissuer", T.unpack issuerName, "-o", "json"]
      pure $ case issuer >>= parseClusterIssuerObservation of
        Left err -> Left ("cannot verify ClusterIssuer " <> issuerName <> ": " <> err)
        Right (Observed True) -> Right ()
        Right (Observed False) -> Left ("ClusterIssuer " <> issuerName <> " is not Ready")
        Right NotFound -> Left ("ClusterIssuer " <> issuerName <> " was not found")
        Right (Unavailable detail) -> Left ("ClusterIssuer " <> issuerName <> " is unavailable: " <> detail)

checkSuppliedSecrets :: TlsPreflightOps -> Text -> [DomainSpec] -> IO (Either Text ())
checkSuppliedSecrets _ _ [] = pure (Right ())
checkSuppliedSecrets ops namespace (spec : rest) =
  case spec ^. #tls of
    AutomaticTls -> checkSuppliedSecrets ops namespace rest
    SuppliedTlsSecret secret -> do
      let secretName = secretNameText secret
          hostname = domainText (spec ^. #domain)
      response <- runTool ops "kubectl" ["get", "secret", T.unpack secretName, "-n", T.unpack namespace, "-o", "json"]
      case response >>= secretHasTlsKeys of
        Left err -> pure (Left (hostname <> ": supplied TLS Secret " <> secretName <> " is not usable: " <> err))
        Right () -> checkSuppliedSecrets ops namespace rest

verifyDomainTlsReady :: TargetProfile -> Text -> Text -> [DomainSpec] -> IO (Either Text ())
verifyDomainTlsReady profile base namespace domains = do
  checked <- preflightDomainTlsWith defaultTlsPreflightOps profile base namespace domains
  case checked of
    Left err -> pure (Left err)
    Right () -> waitForCertificates 300
  where
    waitForCertificates :: Int -> IO (Either Text ())
    waitForCertificates remaining = do
      observed <- verifyCertificatesWith defaultTlsPreflightOps namespace domains
      case observed of
        Right () -> pure (Right ())
        Left err
          | remaining <= 0 -> pure (Left (err <> " (timed out waiting for origin TLS)"))
          | otherwise -> do
              threadDelay 1_000_000
              waitForCertificates (remaining - 1)

verifyDomainTlsReadyWith :: TlsPreflightOps -> TargetProfile -> Text -> Text -> [DomainSpec] -> IO (Either Text ())
verifyDomainTlsReadyWith ops profile base namespace domains = do
  checked <- preflightDomainTlsWith ops profile base namespace domains
  case checked of
    Left err -> pure (Left err)
    Right () -> verifyCertificatesWith ops namespace domains

verifyCertificatesWith :: TlsPreflightOps -> Text -> [DomainSpec] -> IO (Either Text ())
verifyCertificatesWith ops namespace domains
  | null automatic = pure (Right ())
  | otherwise = do
      certManager <- certificateList "certificates.cert-manager.io"
      knative <- certificateList "certificates.networking.internal.knative.dev"
      pure $ do
        evidence <- mergeEvidence certManager knative
        mapM_ (ready evidence) automatic
  where
    automatic = [spec | spec <- domains, spec ^. #tls == AutomaticTls]
    certificateList resource = do
      response <- runTool ops "kubectl" ["get", resource, "-n", T.unpack namespace, "-o", "json"]
      pure (response >>= extractCertificateEvidence)
    mergeEvidence (Right a) (Right b) = Right (a <> b)
    mergeEvidence (Right a) (Left _) = Right a
    mergeEvidence (Left _) (Right b) = Right b
    mergeEvidence (Left a) (Left b) = Left ("could not inspect certificate objects: " <> a <> "; " <> b)
    ready evidence spec =
      let hostname = domainText (spec ^. #domain)
       in case certificateStateFor TlsEnabled (Observed True) (Observed evidence) hostname of
            CertificateReady _ -> Right ()
            CertificatePending detail -> Left (hostname <> ": certificate is pending: " <> detail)
            CertificateFailed detail -> Left (hostname <> ": certificate failed: " <> detail)
            CertificateUnknown detail -> Left (hostname <> ": certificate is unknown: " <> detail)
            TlsDisabled -> Left (hostname <> ": certificate state unexpectedly reports TLS disabled")

parseManagedZoneNames :: ByteString -> Either Text [Text]
parseManagedZoneNames bytes =
  case eitherDecodeStrict bytes of
    Left err -> Left ("could not decode Cloud DNS managed-zone JSON: " <> T.pack err)
    Right (Aeson.Array zones) ->
      Right
        [ normalizeDomain dnsName
        | Aeson.Object zone <- V.toList zones
        , Just (Aeson.String dnsName) <- [KeyMap.lookup "dnsName" zone]
        ]
    Right _ -> Left "Cloud DNS managed-zone response is not an array"

parseIssuerName :: ByteString -> Either Text Text
parseIssuerName bytes =
  case eitherDecodeStrict bytes of
    Left err -> Left ("could not decode config-certmanager JSON: " <> T.pack err)
    Right (Aeson.Object object) -> case KeyMap.lookup "data" object of
      Just (Aeson.Object values) -> case KeyMap.lookup "issuerRef" values of
        Just (Aeson.String issuerRef) ->
          maybe (Left "config-certmanager issuerRef has no name") Right (nameLine issuerRef)
        _ -> Left "config-certmanager has no issuerRef"
      _ -> Left "config-certmanager has no data object"
    Right _ -> Left "config-certmanager response is not an object"
  where
    nameLine =
      fmap (T.strip . T.drop 5)
        . find ("name:" `T.isPrefixOf`)
        . map T.strip
        . T.lines

secretHasTlsKeys :: ByteString -> Either Text ()
secretHasTlsKeys bytes =
  case eitherDecodeStrict bytes of
    Left err -> Left ("could not decode Secret JSON: " <> T.pack err)
    Right (Aeson.Object object) -> case KeyMap.lookup "data" object of
      Just (Aeson.Object values)
        | hasKey "tls.crt" values && hasKey "tls.key" values -> Right ()
        | otherwise -> Left "Secret must contain data keys tls.crt and tls.key"
      _ -> Left "Secret has no data object"
    Right _ -> Left "Secret response is not an object"
  where
    hasKey key = KeyMap.member (Key.fromText key)

underDomain :: Text -> Text -> Bool
underDomain suffix hostname = hostname == suffix || ("." <> suffix) `T.isSuffixOf` hostname

normalizeDomain :: Text -> Text
normalizeDomain = T.toLower . T.dropWhileEnd (== '.') . T.strip

unsupportedAuthority :: Text -> Text -> Text
unsupportedAuthority hostname project =
  hostname
    <> " requests automatic TLS, but no authoritative Cloud DNS parent zone exists in project "
    <> project
    <> ". Configure a cert-manager solver for that DNS authority, or set tls to a supplied Kubernetes TLS Secret."

renderDomainTlsCheck :: DomainSpec -> Text
renderDomainTlsCheck spec =
  domainText (spec ^. #domain) <> case spec ^. #tls of
    AutomaticTls -> " (automatic certificate)"
    SuppliedTlsSecret secret -> " (supplied Secret " <> secretNameText secret <> ")"
