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
      Array dns <- KeyMap.lookup "dnsNames" spec
      dnsNames <- traverse textValue (Vector.toList dns)
      pure CertificateObservation {namespace, name, issuerName, dnsNames}
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

certificatePolicyViolations :: Set Text -> [CertificateObservation] -> [CertificateViolation]
certificatePolicyViolations labeledNamespaces = concatMap inspect
  where
    inspect observation@CertificateObservation {namespace = observationNamespace, issuerName = observationIssuer, dnsNames = observationDnsNames}
      | observationIssuer /= "letsencrypt-dns" = []
      | otherwise = nameViolations <> wildcardViolation
      where
        nameViolations =
          [ violation observation ("non-public ACME DNS name " <> dnsName)
          | dnsName <- observationDnsNames
          , not (isPublicDnsName dnsName)
          ]
        wildcardViolation
          | any ("*." `T.isPrefixOf`) observationDnsNames
              && observationNamespace `Set.notMember` labeledNamespaces =
              [violation observation "public wildcard is in an unlabeled namespace"]
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
