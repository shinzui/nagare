-- | Domains responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Domains
  ( certificateChainTests
  , domainsTests
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Foldable (forM_)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Ops.CertificateChain
  ( ChainReport (..)
  , ChainVerdict (..)
  , chainReportValue
  , readChainWith
  , renderChainReport
  , renewChainWith
  , renewDecision
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
  , ToolRunner
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
import System.FilePath ((</>))
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
              Nothing
              Nothing
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
  , testCase "the Certificate's own status decides failed or pending before message words" $ do
      let recorded = CertificateEvidence "blog-cert" ["blog.apps.example.com"] (Just "False") (Just "DoesNotExist") (Just "Issuing certificate as Secret does not exist") (Just "False") (Just "2026-10-13T14:03:41Z")
          issuing = CertificateEvidence "blog-cert" ["blog.apps.example.com"] (Just "False") (Just "Failed") (Just "previous error") (Just "True") (Just "2026-10-13T14:03:41Z")
      certificateStateFor TlsEnabled (Observed True) (Observed [recorded]) "blog.apps.example.com"
        @?= CertificateFailed "blog-cert: DoesNotExist: Issuing certificate as Secret does not exist; run `nagarectl domains tls blog.apps.example.com` for the issuance chain"
      certificateStateFor TlsEnabled (Observed True) (Observed [issuing]) "blog.apps.example.com"
        @?= CertificatePending "blog-cert: Failed: previous error"
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
    pendingCertificate = CertificateEvidence "blog-cert" ["blog.apps.example.com"] (Just "False") (Just "Pending") (Just "Waiting for DNS01 challenge") Nothing Nothing
    failedCertificate = CertificateEvidence "blog-cert" ["blog.apps.example.com"] (Just "False") (Just "Failed") (Just "DNS01 challenge failed") Nothing Nothing
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
-- Nagare.Ops.CertificateChain (EP-191): one host's issuance chain from
-- recorded kubectl lists, its verdict, and the single renew patch.

data Event = Ran String [String] | Said Text
  deriving stock (Eq, Show)

certificateChainTests :: [TestTree]
certificateChainTests =
  [ testCase "ready certificate is ready and needs nothing" $ do
      (report, _) <- diagnose "ready"
      report ^. #verdict @?= VerdictReady
      report ^. #failedIssuanceAttempts @?= Nothing
      assertHas "ready human" (renderChainReport report) ["certificate ready", "Certificate", "Issued", "next: nothing to do"]
      assertJson "ready json" report [("verdict", Aeson.String "ready")]
  , testCase "pending DNS-01 challenge is issuing and names the challenge" $ do
      (report, _) <- diagnose "pending-dns01"
      report ^. #verdict @?= VerdictIssuing
      assertHas
        "issuing human"
        (renderChainReport report)
        ["certificate issuing", "Challenge", "pending (DNS-01 docs.labs.example.com)", "Waiting for DNS-01 challenge propagation"]
      assertJson "issuing json" report [("verdict", Aeson.String "issuing")]
  , testCase "the IR-28 finalize 404 is failed with the Order error and the next retry" $ do
      (report, _) <- diagnose "failed-finalize"
      report ^. #verdict @?= VerdictFailed
      report ^. #problemType @?= Just "urn:ietf:params:acme:error:malformed"
      report ^. #upstream @?= Just "Failed to finalize Order: 404 urn:ietf:params:acme:error:malformed: Certificate not found"
      report ^. #failedIssuanceAttempts @?= Just 1
      report ^. #nextRetry @?= Just (time "2026-10-13T15:03:41Z")
      assertHas
        "failed human"
        (renderChainReport report)
        [ "docs.labs.example.com: certificate failed after 1 failed attempt: Failed to finalize Order: 404 urn:ietf:params:acme:error:malformed: Certificate not found; cert-manager retries at 2026-10-13T15:03:41Z"
        , "Order"
        , "errored"
        , "next: renew once with `nagarectl domains tls docs.labs.example.com --renew --yes`"
        ]
      assertJson
        "failed json"
        report
        [ ("verdict", Aeson.String "failed")
        , ("problemType", Aeson.String "urn:ietf:params:acme:error:malformed")
        , ("failedIssuanceAttempts", Aeson.Number 1)
        , ("nextRetry", Aeson.String "2026-10-13T15:03:41Z")
        , ("renew", Aeson.object ["allowed" Aeson..= True])
        ]
  , testCase "a rate-limited failure is its own verdict with the CA's retry time" $ do
      (report, _) <- diagnose "rate-limited"
      report ^. #verdict @?= VerdictRateLimited
      report ^. #problemType @?= Just "urn:ietf:params:acme:error:rateLimited"
      report ^. #caRetryAfter @?= Just "2026-10-14 08:00:00 UTC"
      report ^. #nextRetry @?= Just (time "2026-10-13T18:03:41Z")
      assertHas "rate-limited human" (renderChainReport report) ["certificate rate-limited after 3 failed attempts", "CA retry after: 2026-10-14 08:00:00 UTC", "wait for the CA's retry time"]
      assertJson "rate-limited json" report [("verdict", Aeson.String "rate-limited"), ("caRetryAfter", Aeson.String "2026-10-14 08:00:00 UTC")]
  , testCase "a missing cert-manager Certificate is incomplete and named" $ do
      (report, _) <- diagnose "missing-certificate"
      report ^. #verdict @?= VerdictIncomplete
      report ^. #missing @?= Just "cert-manager Certificate"
      assertHas "incomplete human" (renderChainReport report) ["certificate incomplete (no cert-manager Certificate)", "Knative Certificate"]
      assertJson "incomplete json" report [("verdict", Aeson.String "incomplete"), ("missing", Aeson.String "cert-manager Certificate")]
  , testCase "a ready certificate whose renewal failed stays ready and shows the failure" $ do
      (report, _) <- diagnose "ready-renewal-failed"
      report ^. #verdict @?= VerdictReady
      report ^. #failedIssuanceAttempts @?= Just 2
      report ^. #lastFailureTime @?= Just (time "2026-12-12T09:00:00Z")
      assertHas "renewal human" (renderChainReport report) ["certificate ready", "failed issuance attempts: 2", "last failure: 2026-12-12T09:00:00Z"]
      assertJson "renewal json" report [("verdict", Aeson.String "ready"), ("failedIssuanceAttempts", Aeson.Number 2)]
  , testCase "PEM text in an upstream message is withheld" $ do
      (report, _) <- diagnose "pem-in-message"
      report ^. #upstream @?= Just "(detail withheld: it contains PEM text)"
  , testCase "renew patches exactly once, for an owned failed host, after the full diagnosis" $ do
      (result, events) <- renew "failed-finalize" (pure (Right "cluster guard: ok"))
      result @?= Right ()
      let patches = [args | Ran "kubectl" args@("patch" : _) <- events]
      patches
        @?= [
              [ "patch"
              , "certificates.cert-manager.io"
              , "docs.labs.example.com"
              , "-n"
              , "nagare-system"
              , "--subresource=status"
              , "--type=json"
              , "-p"
              , "[{\"op\":\"test\",\"path\":\"/metadata/resourceVersion\",\"value\":\"83304\"},{\"op\":\"replace\",\"path\":\"/status/conditions/1\",\"value\":{\"lastTransitionTime\":\"2026-10-13T15:00:00Z\",\"message\":\"Certificate re-issuance manually triggered\",\"observedGeneration\":1,\"reason\":\"ManuallyTriggered\",\"status\":\"True\",\"type\":\"Issuing\"}}]"
              ]
            ]
      let diagnosisAt = findIndexOf (\case Said t -> "certificate failed after 1 failed attempt" `T.isInfixOf` t; _ -> False) events
          patchAt = findIndexOf (\case Ran _ ("patch" : _) -> True; _ -> False) events
      assertBool "diagnosis printed before the patch" (diagnosisAt < patchAt)
      assertBool "names the follow-up" (any (\case Said t -> "inventory resume TX --yes" `T.isInfixOf` t; _ -> False) events)
  , testCase "renew refuses every other case without a patch"
      $ forM_
        [ ("foreign-context", "belongs to context other, not labs")
        , ("unmanaged", "carries no nagare.dev/context-id")
        , ("no-domainmapping", "no Nagare DomainMapping is named")
        , ("wildcard", "namespace wildcard")
        , ("ready", "the certificate is Ready")
        , ("ready-renewal-failed", "the certificate is Ready")
        , ("pending-dns01", "issuance is in progress")
        , ("rate-limited", "rate-limited")
        , ("missing-certificate", "the chain has no cert-manager Certificate")
        , ("denied", "the latest CertificateRequest is Denied")
        ]
      $ \(name, why) -> do
        (result, events) <- renew name (pure (Right "cluster guard: ok"))
        case result of
          Left err -> assertBool (name <> ": " <> T.unpack err) (why `T.isInfixOf` err)
          Right () -> assertFailure (name <> ": renew was allowed")
        [() | Ran _ ("patch" : _) <- events] @?= []
        assertNoSecrets name events
  , testCase "renew refuses before reading anything when the cluster guard refuses" $ do
      (result, events) <- renew "failed-finalize" (pure (Left "the active Kubernetes context is 'other'"))
      result @?= Left "cluster guard refused: the active Kubernetes context is 'other'"
      [() | Ran _ _ <- events] @?= []
  , testCase "the JSON renew field states the refusal" $ do
      (report, _) <- diagnose "foreign-context"
      case Aeson.toJSON (chainReportValue (renewDecision "labs" report) report) of
        Aeson.Object o -> assertBool "refusal" ("belongs to context other" `T.isInfixOf` T.pack (show o))
        other -> assertFailure ("not an object: " <> show other)
  ]
  where
    now = time "2026-10-13T15:00:00Z"
    diagnose :: String -> IO (ChainReport, [Event])
    diagnose name = do
      events <- newIORef []
      result <- readChainWith (fixtureRunner name events) "docs.labs.example.com"
      recorded <- readIORef events
      case result of
        Left err -> assertFailure (name <> ": " <> T.unpack err)
        Right report -> do
          assertNoSecrets name recorded
          let rendered = renderChainReport report <> TE.decodeUtf8 (LBS.toStrict (Aeson.encode (chainReportValue (renewDecision "labs" report) report)))
          forM_ decoys $ \decoy -> assertBool (name <> ": output carries " <> T.unpack decoy) (not (decoy `T.isInfixOf` rendered))
          pure (report, recorded)
    renew :: String -> IO (Either Text Text) -> IO (Either Text (), [Event])
    renew name guardCluster = do
      events <- newIORef []
      result <- renewChainWith (fixtureRunner name events) guardCluster "labs" now "docs.labs.example.com" (\t -> modifyIORef' events (<> [Said t]))
      recorded <- readIORef events
      forM_ [t | Said t <- recorded] $ \said ->
        forM_ decoys $ \decoy -> assertBool (name <> ": renew output carries " <> T.unpack decoy) (not (decoy `T.isInfixOf` said))
      pure (result, recorded)
    fixtureRunner :: String -> IORef [Event] -> ToolRunner
    fixtureRunner name events executable args = do
      modifyIORef' events (<> [Ran executable args])
      let file f = Observed <$> BS.readFile ("test/fixtures/certificate-chain" </> name </> f)
      case (executable, args) of
        ("kubectl", ["get", "domainmappings.serving.knative.dev", "-A", "--field-selector", "metadata.name=docs.labs.example.com", "-o", "json"]) -> file "domainmappings.json"
        ("kubectl", ["get", resource, "-n", "nagare-system", "-o", "json"]) -> case resource of
          "certificates.networking.internal.knative.dev" -> file "knative-certificates.json"
          "certificates.cert-manager.io" -> file "certificates.json"
          "certificaterequests.cert-manager.io" -> file "certificaterequests.json"
          "orders.acme.cert-manager.io" -> file "orders.json"
          "challenges.acme.cert-manager.io" -> file "challenges.json"
          "secrets" -> file "secrets.json"
          _ -> pure (Unavailable ("unexpected resource " <> T.pack resource))
        ("kubectl", "patch" : _) -> pure (Observed "certificate.cert-manager.io/docs.labs.example.com patched")
        _ -> pure (Unavailable ("unexpected command " <> T.pack (unwords (executable : args))))
    assertNoSecrets name events =
      assertBool (name <> ": a Secret was read") (null [() | Ran _ args <- events, any (`elem` ["secret", "secrets"]) args])
    -- The Secret fixture's key and certificate, the requests' CSR and
    -- certificate, the challenge key and token, and raw PEM.
    decoys =
      [ "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCkVQMTkxLURFQ09ZLUtFWQ=="
      , "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCkVQMTkxLURFQ09ZLUNFUlQ="
      , "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNULS0tLS0KRVAxOTEtREVDT1ktQ1NS"
      , "EP191-DECOY"
      , "BEGIN PRIVATE KEY"
      , "tls.key"
      ]
    assertHas label rendered needles =
      forM_ needles $ \needle -> assertBool (label <> ": missing " <> T.unpack needle <> " in\n" <> T.unpack rendered) (needle `T.isInfixOf` rendered)
    assertJson label report fields =
      case Aeson.toJSON (chainReportValue (renewDecision "labs" report) report) of
        Aeson.Object o -> do
          lookupField "schemaVersion" o @?= Just (Aeson.Number 1)
          forM_ fields $ \(key, expected) -> (label, lookupField key o) @?= (label, Just expected)
        other -> assertFailure (label <> ": not an object: " <> show other)
    lookupField key o = KeyMap.lookup (Key.fromText key) o
    findIndexOf p = fromMaybe maxBound . lookup True . flip zip [0 :: Int ..] . map p
    time :: Text -> UTCTime
    time t = fromMaybe (error ("bad time " <> T.unpack t)) (iso8601ParseM (T.unpack t))
