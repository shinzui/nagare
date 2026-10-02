-- | Cluster responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Cluster
  ( certificatePolicyTests
  , clusterGuardTests
  , namespaceTests
  )
where

import Control.Monad (forM_)
import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Cluster.CertificatePolicy
  ( CertificateObservation (..)
  , CertificateViolation (..)
  , certificatePolicyViolations
  , parseCertificateObservations
  , parseLabeledNamespaces
  , renderCertificateViolations
  )
import Nagare.Cluster.Namespace
  ( NamespacePurpose (..)
  , applicationNamespaceLabel
  , renderNamespace
  )
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Ops.ClusterGuard
  ( ClusterGuardInputs (..)
  , ClusterGuardOps (..)
  , clusterGuardVerdict
  , observeClusterGuard
  , parseServerNodes
  , renderClusterGuard
  )
import Nagare.Ops.Probe (ProbeStatus (StatusOk))
import Nagare.Ops.Status (probeCertificatePolicyWith)
import Nagare.Test.Support.Environment (withTestEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

clusterGuardTests :: TestTree
clusterGuardTests =
  testGroup
    "Nagare.Ops.ClusterGuard (EP-134)"
    [ testCase "matching context and sole server node are accepted" $ do
        clusterGuardVerdict (inputs "labs" ["labs-nagare"]) @?= Right ()
        assertBool "success evidence names every identity" $
          all (`T.isInfixOf` renderClusterGuard (inputs "labs" ["labs-nagare"])) ["labs", "labs-nagare"]
    , testCase "wrong kube context refuses with the fetch remedy" $
        assertClusterRefusal "active Kubernetes context" (inputs "prod" ["labs-nagare"])
    , testCase "wrong, empty, and ambiguous server-node observations refuse" $ do
        assertClusterRefusal "prod-nagare" (inputs "labs" ["prod-nagare"])
        assertClusterRefusal "no server nodes" (inputs "labs" [])
        assertClusterRefusal "[labs-nagare, old-nagare]" (inputs "labs" ["labs-nagare", "old-nagare"])
    , testCase "node-list parser selects only Kubernetes server roles" $ do
        parseServerNodes clusterNodeFixture @?= Right ["labs-nagare"]
        assertBool "malformed JSON fails closed" (isLeft (parseServerNodes "{"))
        assertBool "missing items fails closed" (isLeft (parseServerNodes "{}"))
    , testCase "fake kubectl integration records both read-only observations and reports outages" $
        withSystemTempDirectory "nagare-cluster-guard" $ \root -> do
          let fakeKubectl = root </> "kubectl"
              nodesPath = root </> "nodes.json"
              callsPath = root </> "calls.log"
              ops = ClusterGuardOps fakeKubectl
          BS.writeFile nodesPath clusterNodeFixture
          BS.writeFile callsPath ""
          writeFile
            fakeKubectl
            ( unlines
                [ "#!/bin/sh"
                , "printf '%s\\n' \"$*\" >> \"$NAGARE_CLUSTER_GUARD_CALLS\""
                , "if [ \"$1 $2\" = 'config current-context' ]; then printf '%s\\n' labs; exit 0; fi"
                , "if [ \"${NAGARE_CLUSTER_GUARD_FAIL:-0}\" = 1 ]; then echo 'fixture API unavailable' >&2; exit 23; fi"
                , "cat \"$NAGARE_CLUSTER_GUARD_NODES\""
                ]
            )
          setFileMode fakeKubectl 0o755
          withTestEnv
            [("NAGARE_CLUSTER_GUARD_CALLS", Just callsPath), ("NAGARE_CLUSTER_GUARD_NODES", Just nodesPath)]
            $ do
              observed <- observeClusterGuard ops "labs" "labs-nagare" >>= either (assertFailure . T.unpack) pure
              observed @?= inputs "labs" ["labs-nagare"]
              calls <- TIO.readFile callsPath
              assertBool "reads current context" ("config current-context" `T.isInfixOf` calls)
              assertBool "lists nodes with a deadline" ("get nodes -o json --request-timeout=10s" `T.isInfixOf` calls)
              withTestEnv [("NAGARE_CLUSTER_GUARD_FAIL", Just "1")] $ do
                failed <- observeClusterGuard ops "labs" "labs-nagare"
                case failed of
                  Right _ -> assertFailure "expected fake Kubernetes outage to fail closed"
                  Left err -> do
                    assertBool "preserves command diagnostic" ("fixture API unavailable" `T.isInfixOf` err)
                    assertBool "names remediation" ("nagarectl kubeconfig fetch --context labs" `T.isInfixOf` err)
    ]
  where
    inputs kube servers =
      ClusterGuardInputs
        { nagareContext = "labs"
        , kubeContext = kube
        , expectedNode = "labs-nagare"
        , observedNodes = servers
        }
    assertClusterRefusal needle value = case clusterGuardVerdict value of
      Right () -> assertFailure ("expected cluster guard refusal mentioning " <> T.unpack needle)
      Left err -> do
        assertBool ("refusal should mention " <> T.unpack needle) (needle `T.isInfixOf` err)
        assertBool "refusal should name the expected node" ("labs-nagare" `T.isInfixOf` err)
        assertBool "refusal should name the fetch remedy" ("nagarectl kubeconfig fetch --context labs" `T.isInfixOf` err)

clusterNodeFixture :: ByteString
clusterNodeFixture =
  "{\"items\":[{\"metadata\":{\"name\":\"labs-nagare\",\"labels\":{\"node-role.kubernetes.io/control-plane\":\"true\"}}},{\"metadata\":{\"name\":\"worker-1\",\"labels\":{}}}]}"

-- ---------------------------------------------------------------------------
-- Nagare.Cluster.Namespace (EP-138): only application namespaces opt into
-- public Knative wildcard certificates.

namespaceTests :: [TestTree]
namespaceTests =
  [ testCase "renders a managed application namespace with the opt-in label" $ do
      manifest <- either (assertFailure . T.unpack) pure (renderNamespace ApplicationNamespace "personal")
      case eitherDecodeStrict manifest of
        Left err -> assertFailure err
        Right (Aeson.Object root) -> do
          case KeyMap.lookup "metadata" root of
            Just (Aeson.Object metadata) -> do
              KeyMap.lookup "name" metadata @?= Just (Aeson.String "personal")
              case KeyMap.lookup "labels" metadata of
                Just (Aeson.Object labels) ->
                  KeyMap.lookup (Key.fromText applicationNamespaceLabel) labels
                    @?= Just (Aeson.String "true")
                _ -> assertFailure "namespace metadata has no labels object"
            _ -> assertFailure "namespace manifest has no metadata object"
        Right _ -> assertFailure "namespace manifest is not an object"
  , testCase "render is idempotent" $
      renderNamespace ApplicationNamespace "team-a"
        @?= renderNamespace ApplicationNamespace "team-a"
  , testCase "refuses Kubernetes, platform, and observability namespaces" $
      forM_
        [ "default"
        , "kube-system"
        , "kube-public"
        , "kube-node-lease"
        , "cert-manager"
        , "knative-serving"
        , "kourier-system"
        , "nagare-system"
        , "monitoring"
        , "observability"
        , "logging"
        ]
        (assertBool "reserved namespace was accepted" . isLeft . renderNamespace ApplicationNamespace)
  , testCase "renders a reserved platform namespace without the public-certificate label" $ do
      manifest <- either (assertFailure . T.unpack) pure (renderNamespace PlatformNamespace "nagare-system")
      assertBool
        "platform namespace gained the app opt-in label"
        (not (applicationNamespaceLabel `T.isInfixOf` TE.decodeUtf8 manifest))
      assertBool
        "non-reserved namespace was accepted as platform-owned"
        (isLeft (renderNamespace PlatformNamespace "personal"))
  ]

certificatePolicyTests :: [TestTree]
certificatePolicyTests =
  [ testCase "parses certificate and selected-namespace inventories" $ do
      let certificates =
            "{\"items\":[{\"metadata\":{\"name\":\"wildcard\",\"namespace\":\"personal\",\"labels\":{\"networking.knative.dev/wildcardDomain\":\"apps.example.com\"}},\"spec\":{\"issuerRef\":{\"name\":\"letsencrypt-dns\"},\"dnsNames\":[\"*.personal.apps.example.com\"]}}]}"
          namespaces = "{\"items\":[{\"metadata\":{\"name\":\"personal\"}}]}"
      parseCertificateObservations certificates
        @?= Just [namespaceWildcardCert "personal" "wildcard" "letsencrypt-dns" ["*.personal.apps.example.com"]]
      parseLabeledNamespaces namespaces @?= Just (Set.singleton "personal")
  , testCase "queries the fully qualified cert-manager Certificate API" $ do
      calls <- newIORef []
      let certificates =
            "{\"items\":[{\"metadata\":{\"name\":\"wildcard\",\"namespace\":\"personal\",\"labels\":{\"networking.knative.dev/wildcardDomain\":\"apps.example.com\"}},\"spec\":{\"issuerRef\":{\"name\":\"letsencrypt-dns\"},\"dnsNames\":[\"*.personal.apps.example.com\"]}}]}"
          namespaces = "{\"items\":[{\"metadata\":{\"name\":\"personal\"}}]}"
          capture arguments = do
            modifyIORef' calls (<> [arguments])
            pure $ case arguments of
              ["get", "certificates.cert-manager.io", "-A", "-o", "json"] -> Just certificates
              ["get", "namespaces", "-l", "nagare.dev/app-namespace=true", "-o", "json"] -> Just namespaces
              _ -> Nothing
      probe <- probeCertificatePolicyWith capture
      probe ^. #status @?= StatusOk
      readIORef calls
        >>= (@?=)
          [ ["get", "certificates.cert-manager.io", "-A", "-o", "json"]
          , ["get", "namespaces", "-l", "nagare.dev/app-namespace=true", "-o", "json"]
          ]
  , testCase "accepts CA certificates that omit dnsNames" $
      parseCertificateObservations
        "{\"items\":[{\"metadata\":{\"name\":\"root-ca\",\"namespace\":\"cert-manager\"},\"spec\":{\"issuerRef\":{\"name\":\"selfsigned-cluster-issuer\"}}}]}"
        @?= Just [cert "cert-manager" "root-ca" "selfsigned-cluster-issuer" []]
  , testCase "accepts a public wildcard in a labeled app namespace" $
      certificatePolicyViolations
        (Set.singleton "personal")
        [namespaceWildcardCert "personal" "wildcard" "letsencrypt-dns" ["*.personal.apps.example.com"]]
        @?= []
  , testCase "ignores internal names on the self-signed issuer" $
      certificatePolicyViolations
        Set.empty
        [cert "knative-serving" "routing-serving-certs" "knative-selfsigned-issuer" ["kn-routing", "data-plane.knative.dev"]]
        @?= []
  , testCase "rejects short and cluster-local names on public ACME" $ do
      let violations =
            certificatePolicyViolations
              (Set.singleton "knative-serving")
              [cert "knative-serving" "routing-serving-certs" "letsencrypt-dns" ["kn-routing", "api.personal.svc", "api.personal.svc.cluster.local"]]
          details = renderCertificateViolations violations
      length violations @?= 3
      assertBool "short name" ("kn-routing" `T.isInfixOf` details)
      assertBool ".svc name" ("api.personal.svc" `T.isInfixOf` details)
      assertBool "cluster-local name" ("api.personal.svc.cluster.local" `T.isInfixOf` details)
  , testCase "rejects a public wildcard in an unlabeled namespace" $
      certificatePolicyViolations
        Set.empty
        [namespaceWildcardCert "kube-system" "wildcard" "letsencrypt-dns" ["*.kube-system.apps.example.com"]]
        @?= [CertificateViolation "kube-system" "wildcard" "namespace wildcard is in an unlabeled namespace"]
  , testCase "rejects a self-signed public namespace wildcard" $
      certificatePolicyViolations
        (Set.singleton "personal")
        [namespaceWildcardCert "personal" "wildcard" "knative-selfsigned-issuer" ["*.personal.apps.example.com"]]
        @?= [CertificateViolation "personal" "wildcard" "public namespace wildcard is not using letsencrypt-dns"]
  ]
  where
    cert namespace name issuerName dnsNames =
      CertificateObservation
        { namespace = namespace
        , name = name
        , issuerName = issuerName
        , dnsNames = dnsNames
        , isNamespaceWildcard = False
        }
    namespaceWildcardCert namespace name issuerName dnsNames =
      (cert namespace name issuerName dnsNames) {isNamespaceWildcard = True}
