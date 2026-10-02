-- | Domains responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Domains
  ( domainTlsTests
  , domainsTests
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Domain.Tls
  ( TlsPreflightOps (..)
  , parseIssuerName
  , parseManagedZoneNames
  , preflightDomainTlsWith
  , secretHasTlsKeys
  , verifyDomainTlsReadyWith
  )
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Types
  ( DomainSpec
  , mkDomains
  , mkSecretName
  , withTlsSecret
  )
import Nagare.Ops.Domains
  ( CertificateEvidence (..)
  , CertificateState (..)
  , DnsExpectation (..)
  , DnsObservation (..)
  , DomainMapping (..)
  , DomainRow (..)
  , MappingState (..)
  , Observation (..)
  , TlsMode (..)
  , certificateStateFor
  , dnsExpectationFor
  , domainCheckFailures
  , domainReportValue
  , extractCertificateEvidence
  , extractDomainMappings
  , formatDomainList
  , observeDnsWith
  , parseDigShort
  , queryDomainRowsWith
  )
import Nagare.Target (Mode (Local))
import Nagare.Test.Support.Assertions (unsafe)
import Nagare.Test.Support.Profiles (tnbProfile)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

-- ---------------------------------------------------------------------------
-- Nagare.Ops.Domains (MasterPlan 8, EP-40): the pure DomainMapping/Certificate
-- extractors, the computed DNS expectation, and the table formatter.

domainsTests :: [TestTree]
domainsTests =
  [ testCase "extractDomainMappings preserves route reason and message" $
      extractDomainMappings domainMappingJson
        @?= Right
          [ DomainMapping "blog.apps.example.com" (Just "blog") MappingReady
          , DomainMapping "app.nadeem.dev" (Just "shop") (MappingFailed "DomainAlreadyClaimed: owned by other")
          ]
  , testCase "extractDomainMappings malformed -> Left" $
      assertBool "Left" (isLeft (extractDomainMappings "{not json"))
  , testCase "extractDomainMappings empty list -> Right []" $
      extractDomainMappings "{\"items\":[]}" @?= Right []
  , testCase "extractCertificateEvidence preserves ACME failure detail" $
      extractCertificateEvidence failedCertJson
        @?= Right
          [ CertificateEvidence
              "blog-cert"
              ["blog.apps.example.com"]
              (Just "False")
              (Just "Failed")
              (Just "DNS01 challenge failed")
          ]
  , testCase "parseDigShort strips DNS terminal dots" $
      parseDigShort "203.0.113.10\nedge.example.test.\n" @?= ["203.0.113.10", "edge.example.test"]
  , testCase "DNS apex expects exact apexIp, never the wildcard" $
      dnsExpectationFor base (Just vmIp) (Just apexIp) (Just cdnIp) base
        @?= ExpectedAddresses [apexIp]
  , testCase "one-label DNS accepts wildcard VM or exact CDN target" $
      dnsExpectationFor base (Just vmIp) (Just apexIp) (Just cdnIp) "blog.apps.example.com"
        @?= ExpectedAddresses [vmIp, cdnIp]
  , testCase "deeper and unrelated DNS have no platform target" $ do
      dnsExpectationFor base (Just vmIp) (Just apexIp) (Just cdnIp) "a.b.apps.example.com"
        @?= NoPlatformDnsExpectation
      dnsExpectationFor base (Just vmIp) (Just apexIp) (Just cdnIp) "app.nadeem.dev"
        @?= NoPlatformDnsExpectation
  , testCase "recording dig distinguishes NXDOMAIN from an unavailable command" $ do
      nxdomain <- observeDnsWith (constantRunner (Observed "")) base "missing.apps.example.com"
      nxdomain @?= NotFound
      missing <- observeDnsWith (constantRunner (Unavailable "dig unavailable")) base "blog.apps.example.com"
      missing @?= Unavailable "dig unavailable"
      failed <- observeDnsWith (constantRunner (Unavailable "dig exited 9")) base "blog.apps.example.com"
      failed @?= Unavailable "dig exited 9"
  , testCase "recording dig captures A, CNAME, and authoritative NS answers" $ do
      calls <- newIORef []
      observed <- observeDnsWith (dnsRunner calls cdnIp) base "blog.apps.example.com"
      observed
        @?= Observed (DnsObservation [cdnIp] (Just "edge.example.test") ["ns-cloud-a.example"])
      recorded <- readIORef calls
      recorded
        @?= [ ["+short", "A", "blog.apps.example.com"]
            , ["+short", "AAAA", "blog.apps.example.com"]
            , ["+short", "CNAME", "blog.apps.example.com"]
            , ["+short", "NS", "apps.example.com"]
            ]
  , testCase "TLS-disabled mode is explicit, not a missing certificate" $
      certificateStateFor TlsGloballyDisabled (Unavailable "unused") (Unavailable "unused") base
        @?= TlsDisabled
  , testCase "pending ACME challenge preserves reason" $
      certificateStateFor TlsEnabled (Observed True) (Observed [pendingCertificate]) "blog.apps.example.com"
        @?= CertificatePending "blog-cert: Pending: Waiting for DNS01 challenge"
  , testCase "failed ACME challenge preserves reason" $
      certificateStateFor TlsEnabled (Observed True) (Observed [failedCertificate]) "blog.apps.example.com"
        @?= CertificateFailed "blog-cert: Failed: DNS01 challenge failed"
  , testCase "apex mismatch fails while wildcard VM and exact CDN answers pass" $ do
      assertBool "apex mismatch" (not (null (domainCheckFailures [healthyRow base Nothing (ExpectedAddresses [apexIp]) vmIp TlsDisabled])))
      domainCheckFailures [healthyRow "blog.apps.example.com" (Just "blog") (ExpectedAddresses [vmIp, cdnIp]) vmIp (CertificateReady "blog-cert")]
        @?= []
      domainCheckFailures [healthyRow "www.apps.example.com" (Just "www") (ExpectedAddresses [vmIp, cdnIp]) cdnIp (CertificateReady "www-cert")]
        @?= []
  , testCase "recording kubectl fixture produces a fully ready row" $ do
      calls <- newIORef []
      observed <- queryDomainRowsWith (inventoryRunner calls) base (Just vmIp) (Just apexIp) (Just cdnIp) "personal"
      case observed of
        Observed rows -> domainCheckFailures rows @?= []
        other -> assertFailure ("expected observed rows, got " <> show other)
      commands <- readIORef calls
      assertBool "DomainMapping queried" (("kubectl", ["get", "domainmapping", "-n", "personal", "-o", "json"]) `elem` commands)
      assertBool "dig queried" (("dig", ["+short", "A", "blog.apps.example.com"]) `elem` commands)
  , testCase "versioned JSON report does not depend on table columns" $
      assertBool
        "schemaVersion"
        ("\"schemaVersion\":1" `BS.isInfixOf` LBS.toStrict (Aeson.encode (domainReportValue [] [healthyRow base Nothing (ExpectedAddresses [apexIp]) apexIp TlsDisabled])))
  , testCase "formatDomainList keeps a readable observation table" $
      assertBool
        "contains observed target"
        (cdnIp `T.isInfixOf` formatDomainList [healthyRow "www.apps.example.com" (Just "www") (ExpectedAddresses [vmIp, cdnIp]) cdnIp (CertificateReady "www-cert")])
  , testCase "formatDomainList: empty -> (no domains)" $
      formatDomainList [] @?= "(no domains)\n"
  ]
  where
    base = "apps.example.com"
    vmIp = "203.0.113.10"
    cdnIp = "198.51.100.20"
    apexIp = cdnIp
    domainMappingJson =
      "{\"items\":[\
      \{\"metadata\":{\"name\":\"blog.apps.example.com\"},\"spec\":{\"ref\":{\"name\":\"blog\"}},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}},\
      \{\"metadata\":{\"name\":\"app.nadeem.dev\"},\"spec\":{\"ref\":{\"name\":\"shop\"}},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"False\",\"reason\":\"DomainAlreadyClaimed\",\"message\":\"owned by other\"}]}}\
      \]}"
    failedCertJson = certificateListJson "False" "Failed" "DNS01 challenge failed"
    pendingCertificate = CertificateEvidence "blog-cert" ["blog.apps.example.com"] (Just "False") (Just "Pending") (Just "Waiting for DNS01 challenge")
    failedCertificate = CertificateEvidence "blog-cert" ["blog.apps.example.com"] (Just "False") (Just "Failed") (Just "DNS01 challenge failed")
    certificateListJson status reason message =
      TE.encodeUtf8
        ( "{\"items\":[{\"metadata\":{\"name\":\"blog-cert\"},\"spec\":{\"dnsNames\":[\"blog.apps.example.com\"]},"
            <> "\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\""
            <> status
            <> "\",\"reason\":\""
            <> reason
            <> "\",\"message\":\""
            <> message
            <> "\"}]}}]}"
        )
    healthyRow hostname owner expectation answer cert =
      DomainRow hostname owner (if isNothing owner then NotFound else Observed MappingReady) expectation (Observed (DnsObservation [answer] Nothing ["ns-cloud-a.example"])) cert
    constantRunner observation _ _ = pure observation
    dnsRunner calls answer _ args = do
      modifyIORef' calls (<> [args])
      pure $ Observed $ case args of
        ["+short", "A", _] -> TE.encodeUtf8 (answer <> "\n")
        ["+short", "CNAME", _] -> "edge.example.test.\n"
        ["+short", "NS", _] -> "ns-cloud-a.example.\n"
        _ -> ""
    inventoryRunner calls executable args = do
      modifyIORef' calls (<> [(executable, args)])
      pure $ Observed $ case (executable, args) of
        ("kubectl", ["get", "domainmapping", "-n", "personal", "-o", "json"]) ->
          "{\"items\":[{\"metadata\":{\"name\":\"blog.apps.example.com\"},\"spec\":{\"ref\":{\"name\":\"blog\"}},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}]}"
        ("kubectl", ["-n", "knative-serving", "get", "configmap", "config-network", "-o", "json"]) ->
          "{\"data\":{\"external-domain-tls\":\"Enabled\"}}"
        ("kubectl", ["-n", "knative-serving", "get", "configmap", "config-certmanager", "-o", "json"]) ->
          "{\"data\":{\"issuerRef\":\"kind: ClusterIssuer\\nname: letsencrypt-dns\\n\"}}"
        ("kubectl", ["get", "clusterissuer", "letsencrypt-dns", "-o", "json"]) ->
          "{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}"
        ("kubectl", ["get", "certificates.cert-manager.io", "-n", "personal", "-o", "json"]) ->
          certificateListJson "True" "Issued" "Certificate is up to date"
        ("kubectl", ["get", "certificates.networking.internal.knative.dev", "-n", "personal", "-o", "json"]) ->
          "{\"items\":[]}"
        ("dig", ["+short", "A", _]) -> TE.encodeUtf8 (vmIp <> "\n")
        ("dig", ["+short", "NS", _]) -> "ns-cloud-a.example.\n"
        _ -> ""

-- ---------------------------------------------------------------------------
-- Nagare.Domain.Tls: read-only automatic/supplied origin-TLS enforcement.

domainTlsTests :: [TestTree]
domainTlsTests =
  [ testCase "issuerRef parser follows the configured local issuer" $
      parseIssuerName configCertManagerLocal @?= Right "nagare-local-ca"
  , testCase "Cloud DNS parser normalizes terminal dots" $
      parseManagedZoneNames "[{\"dnsName\":\"example.net.\"},{\"dnsName\":\"apps.example.com.\"}]"
        @?= Right ["example.net", "apps.example.com"]
  , testCase "supplied TLS Secret requires both standard keys" $ do
      secretHasTlsKeys "{\"data\":{\"tls.crt\":\"YQ==\",\"tls.key\":\"Yg==\"}}" @?= Right ()
      assertBool "missing key rejected" (isLeft (secretHasTlsKeys "{\"data\":{\"tls.crt\":\"YQ==\"}}"))
  , testCase "local automatic TLS accepts the configured CA without gcloud" $ do
      calls <- newIORef []
      result <- preflightDomainTlsWith (ops calls configCertManagerLocal "[]" validSecret) (tnbProfile & #mode .~ Local) base "personal" (domains "outside.example.net")
      result @?= Right ()
      commands <- readIORef calls
      assertBool "no gcloud" (all ((/= "gcloud") . fst) commands)
      assertBool "local issuer checked" (("kubectl", ["get", "clusterissuer", "nagare-local-ca", "-o", "json"]) `elem` commands)
  , testCase "cloud automatic TLS under the platform zone needs no zone lookup" $ do
      calls <- newIORef []
      result <- preflightDomainTlsWith (ops calls configCertManager "[]" validSecret) tnbProfile base "personal" (domains "blog.apps.example.com")
      result @?= Right ()
      commands <- readIORef calls
      assertBool "no gcloud" (all ((/= "gcloud") . fst) commands)
  , testCase "cloud automatic TLS accepts an authoritative project zone" $ do
      calls <- newIORef []
      result <- preflightDomainTlsWith (ops calls configCertManager "[{\"dnsName\":\"example.net.\"}]" validSecret) tnbProfile base "personal" (domains "outside.example.net")
      result @?= Right ()
      commands <- readIORef calls
      assertBool
        "project-pinned zone read"
        ( ( "gcloud"
          , ["dns", "managed-zones", "list", "--format=json", "--project=tan-nb-exp"]
          )
            `elem` commands
        )
  , testCase "unsupported DNS authority fails before apply and names supplied-secret escape hatch" $ do
      calls <- newIORef []
      result <- preflightDomainTlsWith (ops calls configCertManager "[]" validSecret) tnbProfile base "personal" (domains "outside.example.net")
      case result of
        Left err -> do
          assertBool "authority" ("no authoritative Cloud DNS parent zone" `T.isInfixOf` err)
          assertBool "escape hatch" ("supplied Kubernetes TLS Secret" `T.isInfixOf` err)
        Right () -> assertFailure "unsupported automatic TLS was accepted"
      commands <- readIORef calls
      assertBool "no apply" (all (notElem "apply" . snd) commands)
  , testCase "unusable supplied Secret fails without querying automatic TLS" $ do
      calls <- newIORef []
      let supplied = [withTlsSecret (unsafe (mkSecretName "external-tls")) (oneDomain "outside.example.net")]
      result <- preflightDomainTlsWith (ops calls configCertManager "[]" "{\"data\":{\"tls.crt\":\"YQ==\"}}") tnbProfile base "personal" supplied
      case result of
        Left err -> assertBool "keys named" ("tls.crt and tls.key" `T.isInfixOf` err)
        Right () -> assertFailure "incomplete TLS Secret was accepted"
      commands <- readIORef calls
      assertBool "only supplied-secret query" (all (\(_, args) -> "config-network" `notElem` args) commands)
  , testCase "post-route verification requires a ready covering certificate" $ do
      calls <- newIORef []
      ready <- verifyDomainTlsReadyWith (ops calls configCertManager "[]" validSecret) tnbProfile base "personal" (domains "blog.apps.example.com")
      ready @?= Right ()
  ]
  where
    base = "apps.example.com"
    validSecret = "{\"data\":{\"tls.crt\":\"YQ==\",\"tls.key\":\"Yg==\"}}"
    configNetwork = "{\"data\":{\"external-domain-tls\":\"Enabled\"}}"
    configCertManager = "{\"data\":{\"issuerRef\":\"kind: ClusterIssuer\\nname: letsencrypt-dns\\n\"}}"
    configCertManagerLocal = "{\"data\":{\"issuerRef\":\"kind: ClusterIssuer\\nname: nagare-local-ca\\n\"}}"
    issuerReady = "{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}"
    certificateReady =
      "{\"items\":[{\"metadata\":{\"name\":\"blog-cert\"},\"spec\":{\"dnsNames\":[\"blog.apps.example.com\"]},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}]}"
    domains :: Text -> [DomainSpec]
    domains hostname = unsafe (mkDomains [(hostname, True)])
    oneDomain :: Text -> DomainSpec
    oneDomain hostname = case domains hostname of
      [domain] -> domain
      _ -> error "mkDomains did not return exactly one test domain"
    ops calls issuerConfig zones secret =
      TlsPreflightOps $ \executable args -> do
        modifyIORef' calls (<> [(executable, args)])
        pure $ case (executable, args) of
          ("kubectl", ["-n", "knative-serving", "get", "configmap", "config-network", "-o", "json"]) -> Right configNetwork
          ("kubectl", ["-n", "knative-serving", "get", "configmap", "config-certmanager", "-o", "json"]) -> Right issuerConfig
          ("kubectl", ["get", "clusterissuer", "nagare-local-ca", "-o", "json"]) -> Right issuerReady
          ("kubectl", ["get", "clusterissuer", "letsencrypt-dns", "-o", "json"]) -> Right issuerReady
          ("gcloud", ["dns", "managed-zones", "list", "--format=json", "--project=tan-nb-exp"]) -> Right zones
          ("kubectl", ["get", "secret", "external-tls", "-n", "personal", "-o", "json"]) -> Right secret
          ("kubectl", ["get", "certificates.cert-manager.io", "-n", "personal", "-o", "json"]) -> Right certificateReady
          ("kubectl", ["get", "certificates.networking.internal.knative.dev", "-n", "personal", "-o", "json"]) -> Right "{\"items\":[]}"
          _ -> Left ("unexpected command: " <> T.pack executable <> " " <> T.unwords (map T.pack args))
