{-# LANGUAGE OverloadedStrings #-}

module CertificateMigrationSpec (certificateMigrationTests) where

import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.List (reverse)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cluster.CertificateMigration
import Nagare.Dsl.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

certificateMigrationTests :: TestTree
certificateMigrationTests =
  testGroup
    "Nagare.Cluster.CertificateMigration"
    [ testCase "parses legacy, target, and disabled config-network observations" $ do
        parseConfigNetworkObservation legacyConfig @?= Right (ConfigNetworkObservation True LegacyAllNamespaces)
        parseConfigNetworkObservation targetConfig @?= Right (ConfigNetworkObservation True TargetAppNamespaces)
        parseConfigNetworkObservation disabledConfig @?= Right (ConfigNetworkObservation False (UnsupportedSelector "<missing>"))
    , testCase "parses Kubernetes identity and secret evidence without resourceVersion" $ do
        parseKnativeCertificates knativeList @?= Right [personalKnative]
        parseCertManagerCertificates managerList @?= Right [personalManager]
        parsed <- either (assertFailure . T.unpack) pure (parseSecretObservations secretList)
        case parsed of
          [secret] -> do
            secretUid secret @?= "secret-personal"
            secretResourceName secret @?= "personal-tls"
          _ -> assertFailure "expected exactly one parsed Secret"
    , testCase "legacy plan preserves opted-in wildcard and removes only system chain" $ do
        migration <- fixturePlan
        selectorChange migration @?= Just (SelectorChange "{}" "matchLabels:\n  nagare.dev/app-namespace: \"true\"\n")
        map (certificateNamespace . certManagerCertificate) (preserve migration) @?= ["personal"]
        map (certificateNamespace . certManagerCertificate) (remove migration) @?= ["kube-system"]
        assertBool "review names selector and exact removals" ("delete secret: kube-system/system-tls" `T.isInfixOf` renderCertificateMigrationReview migration)
    , testCase "planning is deterministic across inventory order" $ do
        first <- fixturePlan
        second <- either (assertFailure . T.unpack) pure (planCertificateMigration legacyObservation (Set.singleton "personal") (reverse fixtureKnative) (reverse fixtureManagers) (reverse fixtureSecrets))
        Aeson.encode first @?= Aeson.encode second
    , testCase "disabled TLS and a target selector require no migration" $ do
        planCertificateMigration (ConfigNetworkObservation False LegacyAllNamespaces) Set.empty fixtureKnative fixtureManagers fixtureSecrets
          @?= Right (CertificateMigrationPlan 1 Nothing [] [])
        planCertificateMigration (ConfigNetworkObservation True TargetAppNamespaces) Set.empty fixtureKnative fixtureManagers fixtureSecrets
          @?= Right (CertificateMigrationPlan 1 Nothing [] [])
    , testCase "unsupported selector refuses while TLS is enabled" $
        assertLeftContains
          "unsupported namespace-wildcard-cert-selector"
          (planCertificateMigration (ConfigNetworkObservation True (UnsupportedSelector "matchExpressions: []")) Set.empty fixtureKnative fixtureManagers fixtureSecrets)
    , testCase "ambiguous shared Secret target refuses" $ do
        let secondKnative = systemKnative {certificateName = "system-two", certificateUid = "knative-two"}
            secondManager = systemManager {certificateName = "manager-two", certificateUid = "manager-two", certificateOwnerUids = ["knative-two"]}
            sharedSecrets = systemSecret {secretOwnerUids = ["manager-system", "manager-two"]} : [personalSecret]
        assertLeftContains
          "same Secret"
          (planCertificateMigration legacyObservation (Set.singleton "personal") (fixtureKnative <> [secondKnative]) (fixtureManagers <> [secondManager]) sharedSecrets)
    , testCase "changed UID, content, and a new Secret reference all fail closed" $ do
        migration <- fixturePlan
        assertLeftContains "UID changed" (validateReviewedCleanup migration fixtureKnative (replaceSystemManagerUid fixtureManagers) fixtureSecrets)
        assertLeftContains "content or ownership changed" (validateReviewedCleanup migration fixtureKnative fixtureManagers (replaceSystemSecretDigest fixtureSecrets))
        let newReference = personalManager {certificateNamespace = "kube-system", certificateName = "new-reference", certificateUid = "new-reference", secretName = Just "system-tls"}
        assertLeftContains "another live Certificate" (validateReviewedCleanup migration fixtureKnative (fixtureManagers <> [newReference]) fixtureSecrets)
    , testCase "already-absent reviewed artifacts are idempotent success" $ do
        migration <- fixturePlan
        validateReviewedCleanup migration [personalKnative] [personalManager] [personalSecret] @?= Right ()
    , testCase "metadata binds transaction, context, and payload" $ do
        let current = CurrentKubernetesIdentity "tx-1" "labs" "payload-1" "digest-1"
            metadata = KubernetesPlanMetadata 1 "tx-1" "labs" "payload-1" "digest-1" "2026-09-15T00:00:00Z" "manifest" "review"
        verifyKubernetesPlanMetadata current metadata @?= Right ()
        assertLeftContains "context" (verifyKubernetesPlanMetadata (current {currentContext = "other"}) metadata)
    ]

fixturePlan :: IO CertificateMigrationPlan
fixturePlan =
  either (assertFailure . T.unpack) pure $
    planCertificateMigration legacyObservation (Set.singleton "personal") fixtureKnative fixtureManagers fixtureSecrets

legacyObservation :: ConfigNetworkObservation
legacyObservation = ConfigNetworkObservation True LegacyAllNamespaces

fixtureKnative :: [CertificateResource]
fixtureKnative = [systemKnative, personalKnative]

fixtureManagers :: [CertificateResource]
fixtureManagers = [systemManager, personalManager]

fixtureSecrets :: [SecretObservation]
fixtureSecrets = [systemSecret, personalSecret]

systemKnative, personalKnative, systemManager, personalManager :: CertificateResource
systemKnative = mkKnativeCertificate "kube-system" "system-wildcard" "knative-system" "system-tls"
personalKnative = mkKnativeCertificate "personal" "personal-wildcard" "knative-personal" "personal-tls"
systemManager = managerCertificate "kube-system" "system-wildcard" "manager-system" "knative-system" "system-tls"
personalManager = managerCertificate "personal" "personal-wildcard" "manager-personal" "knative-personal" "personal-tls"

systemSecret, personalSecret :: SecretObservation
systemSecret = generatedSecretObservation "kube-system" "system-tls" "secret-system" "manager-system" "system-wildcard" "digest-system"
personalSecret = generatedSecretObservation "personal" "personal-tls" "secret-personal" "manager-personal" "personal-wildcard" "digest-personal"

mkKnativeCertificate :: T.Text -> T.Text -> T.Text -> T.Text -> CertificateResource
mkKnativeCertificate resourceNamespace resourceName uid generatedName =
  CertificateResource
    "networking.internal.knative.dev"
    resourceNamespace
    resourceName
    uid
    []
    ""
    ["*." <> resourceNamespace <> ".apps.example.com"]
    (Just generatedName)
    True
    True

managerCertificate :: T.Text -> T.Text -> T.Text -> T.Text -> T.Text -> CertificateResource
managerCertificate resourceNamespace resourceName uid owner generatedName =
  CertificateResource
    "cert-manager.io"
    resourceNamespace
    resourceName
    uid
    [owner]
    "letsencrypt-dns"
    ["*." <> resourceNamespace <> ".apps.example.com"]
    (Just generatedName)
    True
    False

generatedSecretObservation :: T.Text -> T.Text -> T.Text -> T.Text -> T.Text -> T.Text -> SecretObservation
generatedSecretObservation resourceNamespace resourceName uid owner certificateName digest =
  SecretObservation resourceNamespace resourceName uid [owner] (Just certificateName) (Just "letsencrypt-dns") digest

replaceSystemManagerUid :: [CertificateResource] -> [CertificateResource]
replaceSystemManagerUid = map (\resource -> if certificateNamespace resource == "kube-system" then resource {certificateUid = "replaced"} else resource)

replaceSystemSecretDigest :: [SecretObservation] -> [SecretObservation]
replaceSystemSecretDigest = map (\secret -> if secretNamespace secret == "kube-system" then secret {secretDigest = "changed"} else secret)

assertLeftContains :: T.Text -> Either T.Text a -> Assertion
assertLeftContains expected result = case result of
  Left actual -> assertBool ("expected '" <> T.unpack expected <> "' in '" <> T.unpack actual <> "'") (expected `T.isInfixOf` actual)
  Right _ -> assertFailure ("expected refusal containing " <> T.unpack expected)

legacyConfig, targetConfig, disabledConfig, knativeList, managerList, secretList :: ByteString
legacyConfig = "{\"data\":{\"external-domain-tls\":\"Enabled\",\"namespace-wildcard-cert-selector\":\"{}\\n\"}}"
targetConfig = "{\"data\":{\"external-domain-tls\":\"Enabled\",\"namespace-wildcard-cert-selector\":\"matchLabels:\\n  nagare.dev/app-namespace: \\\"true\\\"\\n\"}}"
disabledConfig = "{\"data\":{}}"
knativeList =
  "{\"items\":[{\"metadata\":{\"name\":\"personal-wildcard\",\"namespace\":\"personal\",\"uid\":\"knative-personal\",\"annotations\":{\"networking.knative.dev/certificate.class\":\"cert-manager.certificate.networking.knative.dev\"},\"labels\":{\"networking.knative.dev/wildcardDomain\":\"apps.example.com\"}},\"spec\":{\"secretName\":\"personal-tls\",\"dnsNames\":[\"*.personal.apps.example.com\"]}}]}"
managerList =
  "{\"items\":[{\"metadata\":{\"name\":\"personal-wildcard\",\"namespace\":\"personal\",\"uid\":\"manager-personal\",\"ownerReferences\":[{\"uid\":\"knative-personal\"}]},\"spec\":{\"secretName\":\"personal-tls\",\"issuerRef\":{\"name\":\"letsencrypt-dns\"},\"dnsNames\":[\"*.personal.apps.example.com\"]}}]}"
secretList =
  "{\"items\":[{\"metadata\":{\"name\":\"personal-tls\",\"namespace\":\"personal\",\"uid\":\"secret-personal\",\"resourceVersion\":\"9\",\"ownerReferences\":[{\"uid\":\"manager-personal\"}],\"annotations\":{\"cert-manager.io/certificate-name\":\"personal-wildcard\",\"cert-manager.io/issuer-name\":\"letsencrypt-dns\"}},\"type\":\"kubernetes.io/tls\",\"data\":{\"tls.crt\":\"Y2VydA==\",\"tls.key\":\"a2V5\"}}]}"
