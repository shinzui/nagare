-- | Pure inspection of cert-manager Certificates. Public ACME issuance must
-- contain only public DNS names, and namespace wildcards require Nagare's
-- explicit application-namespace opt-in.
module Nagare.Cluster.CertificatePolicy
  ( CertificateObservation (..)
  , CertificateViolation (..)
  , parseCertificateObservations
  , parseLabeledNamespaces
  , certificatePolicyViolations
  , renderCertificateViolations
  )
where

import Data.Aeson (Value (..), decodeStrict)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Vector qualified as Vector
import Nagare.Dsl.Prelude

data CertificateObservation = CertificateObservation
  { namespace :: !Text
  , name :: !Text
  , issuerName :: !Text
  , dnsNames :: ![Text]
  , isNamespaceWildcard :: !Bool
  , contentDomain :: !(Maybe Text)
  -- ^ the @nagare.dev/content-domain@ label of a content route's certificate (EP-285)
  }
  deriving stock (Generic, Eq, Show)

data CertificateViolation = CertificateViolation
  { namespace :: !Text
  , certificate :: !Text
  , reason :: !Text
  }
  deriving stock (Generic, Eq, Show)

parseCertificateObservations :: ByteString -> Maybe [CertificateObservation]
parseCertificateObservations bytes = do
  Object root <- decodeStrict bytes
  Array items <- KeyMap.lookup "items" root
  traverse parseCertificate (Vector.toList items)
  where
    parseCertificate (Object item) = do
      Object metadata <- KeyMap.lookup "metadata" item
      Object spec <- KeyMap.lookup "spec" item
      Object issuer <- KeyMap.lookup "issuerRef" spec
      String namespace <- KeyMap.lookup "namespace" metadata
      String name <- KeyMap.lookup "name" metadata
      String issuerName <- KeyMap.lookup "name" issuer
      let labels = case KeyMap.lookup "labels" metadata of
            Just (Object found) -> found
            _ -> KeyMap.empty
          isNamespaceWildcard = KeyMap.member "networking.knative.dev/wildcardDomain" labels
          contentDomain = case KeyMap.lookup "nagare.dev/content-domain" labels of
            Just (String domain) -> Just domain
            _ -> Nothing
      dnsNames <- case KeyMap.lookup "dnsNames" spec of
        Nothing -> Just []
        Just (Array dns) -> traverse textValue (Vector.toList dns)
        Just _ -> Nothing
      pure CertificateObservation {namespace, name, issuerName, dnsNames, isNamespaceWildcard, contentDomain}
    parseCertificate _ = Nothing
    textValue (String value) = Just value
    textValue _ = Nothing

parseLabeledNamespaces :: ByteString -> Maybe (Set Text)
parseLabeledNamespaces bytes = do
  Object root <- decodeStrict bytes
  Array items <- KeyMap.lookup "items" root
  Set.fromList <$> traverse namespaceName (Vector.toList items)
  where
    namespaceName (Object item) = do
      Object metadata <- KeyMap.lookup "metadata" item
      String name <- KeyMap.lookup "name" metadata
      pure name
    namespaceName _ = Nothing

-- | The first set is the labeled application namespaces; the second, the
-- content domains the context lists (EP-285). A content route's certificate is
-- the one public wildcard expected outside Knative's namespace wildcards: it
-- must name a listed domain, cover exactly @*.D@ and @D@, and live in an
-- application namespace.
certificatePolicyViolations :: Set Text -> Set Text -> [CertificateObservation] -> [CertificateViolation]
certificatePolicyViolations labeledNamespaces contentDomains = concatMap inspect
  where
    inspect observation@CertificateObservation {namespace = observationNamespace, issuerName = observationIssuer, dnsNames = observationDnsNames, isNamespaceWildcard = observationIsNamespaceWildcard, contentDomain = observationContentDomain}
      | Just domain <- observationContentDomain = contentViolations domain <> nameViolations
      | observationIsNamespaceWildcard = namespaceWildcardViolations <> nameViolations
      | observationIssuer == "letsencrypt-dns" = nameViolations
      | otherwise = []
      where
        nameViolations =
          [ violation observation ("non-public ACME DNS name " <> dnsName)
          | dnsName <- observationDnsNames
          , observationIssuer == "letsencrypt-dns"
          , not (isPublicDnsName dnsName)
          ]
        contentViolations domain =
          [violation observation ("content domain " <> domain <> " is not listed by the context") | domain `Set.notMember` contentDomains]
            <> [violation observation "content certificate names hosts other than its domain and wildcard" | observationDnsNames /= ["*." <> domain, domain]]
            <> [violation observation "content certificate is in an unlabeled namespace" | observationNamespace `Set.notMember` labeledNamespaces]
        namespaceWildcardViolations
          | observationNamespace `Set.notMember` labeledNamespaces =
              [violation observation "namespace wildcard is in an unlabeled namespace"]
          | observationIssuer /= "letsencrypt-dns" =
              [violation observation "public namespace wildcard is not using letsencrypt-dns"]
          | otherwise = []

    violation CertificateObservation {namespace = observationNamespace, name = observationName} reason =
      CertificateViolation
        { namespace = observationNamespace
        , certificate = observationName
        , reason
        }

isPublicDnsName :: Text -> Bool
isPublicDnsName raw =
  let dnsName = fromMaybe raw (T.stripPrefix "*." raw)
   in T.count "." dnsName >= 1
        && not (dnsName == "svc" || ".svc" `T.isSuffixOf` dnsName || ".svc.cluster.local" `T.isSuffixOf` dnsName)

renderCertificateViolations :: [CertificateViolation] -> Text
renderCertificateViolations =
  T.intercalate "; "
    . map
      ( \CertificateViolation {namespace = violationNamespace, certificate = violationCertificate, reason = violationReason} ->
          violationNamespace
            <> "/"
            <> violationCertificate
            <> ": "
            <> violationReason
      )
