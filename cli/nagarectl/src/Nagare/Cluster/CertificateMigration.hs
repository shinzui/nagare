{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure planning and drift checks for the legacy namespace-wildcard
-- certificate migration. Kubernetes process execution intentionally stays in
-- @app/Main.hs@ so every destructive decision is fixture-testable here.
module Nagare.Cluster.CertificateMigration
  ( CertificateSelector (..)
  , ConfigNetworkObservation (..)
  , CertificateResource (..)
  , SecretObservation (..)
  , CertificateChain (..)
  , SelectorChange (..)
  , CertificateMigrationPlan (..)
  , KubernetesPlanMetadata (..)
  , CurrentKubernetesIdentity (..)
  , parseConfigNetworkObservation
  , parseKnativeCertificates
  , parseCertManagerCertificates
  , parseSecretObservations
  , planCertificateMigration
  , validateReviewedCleanup
  , verifyKubernetesPlanMetadata
  , renderTargetConfigNetworkManifest
  , renderCertificateMigrationReview
  )
where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), eitherDecodeStrict', withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (traverse_)
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as Vector
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude

data CertificateSelector
  = LegacyAllNamespaces
  | TargetAppNamespaces
  | UnsupportedSelector !Text
  deriving stock (Eq, Show)

data ConfigNetworkObservation = ConfigNetworkObservation
  { externalDomainTlsEnabled :: !Bool
  , certificateSelector :: !CertificateSelector
  }
  deriving stock (Generic, Eq, Show)

data CertificateResource = CertificateResource
  { apiGroup :: !Text
  , certificateNamespace :: !Text
  , certificateName :: !Text
  , certificateUid :: !Text
  , certificateOwnerUids :: ![Text]
  , issuerName :: !Text
  , dnsNames :: ![Text]
  , secretName :: !(Maybe Text)
  , namespaceWildcard :: !Bool
  , nagareManaged :: !Bool
  }
  deriving stock (Generic, Eq, Show)

data SecretObservation = SecretObservation
  { secretNamespace :: !Text
  , secretResourceName :: !Text
  , secretUid :: !Text
  , secretOwnerUids :: ![Text]
  , certificateNameAnnotation :: !(Maybe Text)
  , issuerNameAnnotation :: !(Maybe Text)
  , secretDigest :: !Text
  }
  deriving stock (Generic, Eq, Show)

data CertificateChain = CertificateChain
  { knativeCertificate :: !CertificateResource
  , certManagerCertificate :: !CertificateResource
  , generatedSecret :: !SecretObservation
  }
  deriving stock (Generic, Eq, Show)

data SelectorChange = SelectorChange
  { fromSelector :: !Text
  , toSelector :: !Text
  }
  deriving stock (Generic, Eq, Show)

data CertificateMigrationPlan = CertificateMigrationPlan
  { schemaVersion :: !Int
  , selectorChange :: !(Maybe SelectorChange)
  , preserve :: ![CertificateChain]
  , remove :: ![CertificateChain]
  }
  deriving stock (Generic, Eq, Show)

data KubernetesPlanMetadata = KubernetesPlanMetadata
  { metadataSchemaVersion :: !Int
  , transactionId :: !Text
  , context :: !Text
  , payloadId :: !Text
  , payloadDigest :: !Text
  , createdAt :: !Text
  , manifestDigest :: !Text
  , reviewDigest :: !Text
  }
  deriving stock (Generic, Eq, Show)

data CurrentKubernetesIdentity = CurrentKubernetesIdentity
  { currentTransactionId :: !Text
  , currentContext :: !Text
  , currentPayloadId :: !Text
  , currentPayloadDigest :: !Text
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON CertificateResource where
  toJSON resource =
    Aeson.object
      [ "apiGroup" Aeson..= apiGroup resource
      , "namespace" Aeson..= certificateNamespace resource
      , "name" Aeson..= certificateName resource
      , "uid" Aeson..= certificateUid resource
      , "ownerUids" Aeson..= certificateOwnerUids resource
      , "issuerName" Aeson..= issuerName resource
      , "dnsNames" Aeson..= dnsNames resource
      , "secretName" Aeson..= secretName resource
      , "namespaceWildcard" Aeson..= namespaceWildcard resource
      , "nagareManaged" Aeson..= nagareManaged resource
      ]

instance FromJSON CertificateResource where
  parseJSON = withObject "CertificateResource" $ \o ->
    CertificateResource
      <$> o .: "apiGroup"
      <*> o .: "namespace"
      <*> o .: "name"
      <*> o .: "uid"
      <*> o .: "ownerUids"
      <*> o .: "issuerName"
      <*> o .: "dnsNames"
      <*> o .:? "secretName"
      <*> o .: "namespaceWildcard"
      <*> o .: "nagareManaged"

instance ToJSON SecretObservation where
  toJSON secret =
    Aeson.object
      [ "namespace" Aeson..= secretNamespace secret
      , "name" Aeson..= secretResourceName secret
      , "uid" Aeson..= secretUid secret
      , "ownerUids" Aeson..= secretOwnerUids secret
      , "certificateNameAnnotation" Aeson..= certificateNameAnnotation secret
      , "issuerNameAnnotation" Aeson..= issuerNameAnnotation secret
      , "digest" Aeson..= secretDigest secret
      ]

instance FromJSON SecretObservation where
  parseJSON = withObject "SecretObservation" $ \o ->
    SecretObservation
      <$> o .: "namespace"
      <*> o .: "name"
      <*> o .: "uid"
      <*> o .: "ownerUids"
      <*> o .:? "certificateNameAnnotation"
      <*> o .:? "issuerNameAnnotation"
      <*> o .: "digest"

instance ToJSON CertificateChain where
  toJSON chain =
    Aeson.object
      [ "knativeCertificate" Aeson..= knativeCertificate chain
      , "certManagerCertificate" Aeson..= certManagerCertificate chain
      , "generatedSecret" Aeson..= generatedSecret chain
      ]

instance FromJSON CertificateChain where
  parseJSON = withObject "CertificateChain" $ \o ->
    CertificateChain <$> o .: "knativeCertificate" <*> o .: "certManagerCertificate" <*> o .: "generatedSecret"

instance ToJSON SelectorChange where
  toJSON change = Aeson.object ["from" Aeson..= fromSelector change, "to" Aeson..= toSelector change]

instance FromJSON SelectorChange where
  parseJSON = withObject "SelectorChange" $ \o -> SelectorChange <$> o .: "from" <*> o .: "to"

instance ToJSON CertificateMigrationPlan where
  toJSON migration =
    Aeson.object
      [ "schemaVersion" Aeson..= schemaVersion migration
      , "selectorChange" Aeson..= selectorChange migration
      , "preserve" Aeson..= preserve migration
      , "remove" Aeson..= remove migration
      ]

instance FromJSON CertificateMigrationPlan where
  parseJSON = withObject "CertificateMigrationPlan" $ \o ->
    CertificateMigrationPlan <$> o .: "schemaVersion" <*> o .:? "selectorChange" <*> o .: "preserve" <*> o .: "remove"

instance ToJSON KubernetesPlanMetadata where
  toJSON metadata =
    Aeson.object
      [ "schemaVersion" Aeson..= metadataSchemaVersion metadata
      , "transactionId" Aeson..= transactionId metadata
      , "context" Aeson..= context metadata
      , "payloadId" Aeson..= payloadId metadata
      , "payloadDigest" Aeson..= payloadDigest metadata
      , "createdAt" Aeson..= createdAt metadata
      , "manifestDigest" Aeson..= manifestDigest metadata
      , "reviewDigest" Aeson..= reviewDigest metadata
      ]

instance FromJSON KubernetesPlanMetadata where
  parseJSON = withObject "KubernetesPlanMetadata" $ \o ->
    KubernetesPlanMetadata
      <$> o .: "schemaVersion"
      <*> o .: "transactionId"
      <*> o .: "context"
      <*> o .: "payloadId"
      <*> o .: "payloadDigest"
      <*> o .: "createdAt"
      <*> o .: "manifestDigest"
      <*> o .: "reviewDigest"

parseConfigNetworkObservation :: ByteString -> Either Text ConfigNetworkObservation
parseConfigNetworkObservation bytes = do
  root <- firstText (eitherDecodeStrict' bytes)
  AesonTypes.parseEither parseConfig root & firstText
  where
    parseConfig = withObject "config-network ConfigMap" $ \root -> do
      dataObject <- root .: "data"
      externalTls <- dataObject .:? "external-domain-tls"
      rawSelector <- dataObject .:? "namespace-wildcard-cert-selector"
      selector <- traverse parseSelector rawSelector
      pure
        ConfigNetworkObservation
          { externalDomainTlsEnabled = externalTls == Just ("Enabled" :: Text)
          , certificateSelector = fromMaybe (UnsupportedSelector "<missing>") selector
          }
    parseSelector raw = case Yaml.decodeEither' (TE.encodeUtf8 raw) of
      Left err -> fail (Yaml.prettyPrintParseException err)
      Right (Object object)
        | KeyMap.null object -> pure LegacyAllNamespaces
        | object == targetSelectorObject -> pure TargetAppNamespaces
        | otherwise -> pure (UnsupportedSelector raw)
      Right _ -> pure (UnsupportedSelector raw)
    targetSelectorObject =
      KeyMap.singleton
        "matchLabels"
        (Object (KeyMap.singleton "nagare.dev/app-namespace" (String "true")))

parseKnativeCertificates :: ByteString -> Either Text [CertificateResource]
parseKnativeCertificates = parseCertificateList "networking.internal.knative.dev"

parseCertManagerCertificates :: ByteString -> Either Text [CertificateResource]
parseCertManagerCertificates = parseCertificateList "cert-manager.io"

parseCertificateList :: Text -> ByteString -> Either Text [CertificateResource]
parseCertificateList group bytes = do
  root <- firstText (eitherDecodeStrict' bytes)
  AesonTypes.parseEither (withObject "CertificateList" (\o -> o .: "items" >>= traverse (parseCertificate group))) root & firstText

parseCertificate :: Text -> Value -> AesonTypes.Parser CertificateResource
parseCertificate group = withObject "Certificate" $ \item -> do
  metadata <- item .: "metadata"
  spec <- item .: "spec"
  resourceNamespace <- metadata .: "namespace"
  resourceName <- metadata .: "name"
  resourceUid <- metadata .: "uid"
  owners <- sort <$> parseOwnerUids metadata
  resourceDnsNames <- sort <$> (spec .:? "dnsNames" Aeson..!= [])
  resourceSecretName <- spec .:? "secretName"
  labels <- (metadata .:? "labels" Aeson..!= KeyMap.empty) :: AesonTypes.Parser (KeyMap.KeyMap Value)
  annotations <- (metadata .:? "annotations" Aeson..!= KeyMap.empty) :: AesonTypes.Parser (KeyMap.KeyMap Value)
  resourceIssuer <- case group of
    "cert-manager.io" -> spec .: "issuerRef" >>= (.: "name")
    _ -> pure ""
  let isWildcard = KeyMap.member "networking.knative.dev/wildcardDomain" labels || any ("*." `T.isPrefixOf`) resourceDnsNames
      isManaged = case KeyMap.lookup "networking.knative.dev/certificate.class" annotations of
        Just (String "cert-manager.certificate.networking.knative.dev") -> True
        _ -> False
  pure
    CertificateResource
      { apiGroup = group
      , certificateNamespace = resourceNamespace
      , certificateName = resourceName
      , certificateUid = resourceUid
      , certificateOwnerUids = owners
      , issuerName = resourceIssuer
      , dnsNames = resourceDnsNames
      , secretName = resourceSecretName
      , namespaceWildcard = isWildcard
      , nagareManaged = isManaged
      }

parseSecretObservations :: ByteString -> Either Text [SecretObservation]
parseSecretObservations bytes = do
  root <- firstText (eitherDecodeStrict' bytes)
  AesonTypes.parseEither (withObject "SecretList" (\o -> o .: "items" >>= traverse parseSecret)) root & firstText
  where
    parseSecret = withObject "Secret" $ \item -> do
      metadata <- item .: "metadata"
      secretNamespace <- metadata .: "namespace"
      name <- metadata .: "name"
      uid <- metadata .: "uid"
      owners <- sort <$> parseOwnerUids metadata
      annotations <- (metadata .:? "annotations" Aeson..!= KeyMap.empty) :: AesonTypes.Parser (KeyMap.KeyMap Value)
      labels <- (metadata .:? "labels" Aeson..!= KeyMap.empty) :: AesonTypes.Parser (KeyMap.KeyMap Value)
      secretType <- item .:? "type" Aeson..!= ("" :: Text)
      secretData <- (item .:? "data" Aeson..!= KeyMap.empty) :: AesonTypes.Parser (KeyMap.KeyMap Value)
      let annotationText key = case KeyMap.lookup key annotations of
            Just (String value) -> Just value
            _ -> Nothing
          stableValue =
            Aeson.object
              [ "namespace" Aeson..= secretNamespace
              , "name" Aeson..= name
              , "uid" Aeson..= uid
              , "ownerUids" Aeson..= owners
              , "annotations" Aeson..= Object annotations
              , "labels" Aeson..= Object labels
              , "type" Aeson..= secretType
              , "data" Aeson..= Object secretData
              ]
          digest = T.pack (show (hash (LBS.toStrict (Aeson.encode stableValue)) :: Digest SHA256))
      pure
        SecretObservation
          { secretNamespace = secretNamespace
          , secretResourceName = name
          , secretUid = uid
          , secretOwnerUids = owners
          , certificateNameAnnotation = annotationText "cert-manager.io/certificate-name"
          , issuerNameAnnotation = annotationText "cert-manager.io/issuer-name"
          , secretDigest = digest
          }

parseOwnerUids :: KeyMap.KeyMap Value -> AesonTypes.Parser [Text]
parseOwnerUids metadata = do
  references <- metadata .:? "ownerReferences" Aeson..!= []
  traverse (withObject "OwnerReference" (.: "uid")) references

planCertificateMigration ::
  ConfigNetworkObservation ->
  Set Text ->
  [CertificateResource] ->
  [CertificateResource] ->
  [SecretObservation] ->
  Either Text CertificateMigrationPlan
planCertificateMigration config optedIn knativeCertificates certManagerCertificates secrets
  | not (externalDomainTlsEnabled config) = Right emptyPlan
  | certificateSelector config == TargetAppNamespaces = Right emptyPlan
  | certificateSelector config /= LegacyAllNamespaces =
      Left "external TLS is enabled with an unsupported namespace-wildcard-cert-selector; refusing migration"
  | otherwise = do
      chains <- traverse buildChain managedWildcards
      rejectDuplicateTargets chains
      let sortedChains = sortOn chainKey chains
          (preserved, removed) = partitionChains sortedChains
      pure
        CertificateMigrationPlan
          { schemaVersion = 1
          , selectorChange = Just (SelectorChange "{}" targetSelectorText)
          , preserve = preserved
          , remove = removed
          }
  where
    emptyPlan = CertificateMigrationPlan 1 Nothing [] []
    managedWildcards = filter (\certificate -> namespaceWildcard certificate && nagareManaged certificate) knativeCertificates
    buildChain knative = do
      knativeSecret <- maybe (Left (resourceKey knative <> " has no spec.secretName")) Right (secretName knative)
      let managers =
            filter
              ( \certificate ->
                  certificateNamespace certificate == certificateNamespace knative
                    && certificateUid knative `elem` certificateOwnerUids certificate
                    && secretName certificate == Just knativeSecret
              )
              certManagerCertificates
      manager <- exactlyOne (resourceKey knative <> " has an ambiguous or missing cert-manager Certificate") managers
      managerSecret <- maybe (Left (resourceKey manager <> " has no spec.secretName")) Right (secretName manager)
      when (managerSecret /= knativeSecret) (Left (resourceKey manager <> " does not use the Knative Certificate's Secret"))
      let candidates = filter (\secret -> secretNamespace secret == certificateNamespace manager && secretResourceName secret == managerSecret) secrets
      generated <- exactlyOne (resourceKey manager <> " has an ambiguous or missing generated Secret") candidates
      unless (secretManagedBy manager generated) $
        Left (resourceKey manager <> " Secret annotations/ownership do not establish cert-manager management")
      pure (CertificateChain knative manager generated)
    partitionChains = foldr classify ([], [])
    classify chain (kept, removed)
      | certificateNamespace (certManagerCertificate chain) `Set.member` optedIn
          && issuerName (certManagerCertificate chain) == "letsencrypt-dns" =
          (chain : kept, removed)
      | otherwise = (kept, chain : removed)
    chainKey chain =
      ( certificateNamespace (certManagerCertificate chain)
      , certificateName (certManagerCertificate chain)
      , secretResourceName (generatedSecret chain)
      )

validateReviewedCleanup ::
  CertificateMigrationPlan ->
  [CertificateResource] ->
  [CertificateResource] ->
  [SecretObservation] ->
  Either Text ()
validateReviewedCleanup reviewed currentKnative currentManagers currentSecrets = do
  when (schemaVersion reviewed /= 1) (Left "unsupported certificate migration review schema")
  traverse_ validateChain (remove reviewed)
  where
    validateChain chain = do
      matchesOrAbsent "Knative Certificate" resourceKey certificateUid (knativeCertificate chain) currentKnative
      matchesOrAbsent "cert-manager Certificate" resourceKey certificateUid (certManagerCertificate chain) currentManagers
      matchesOrAbsent "Secret" secretKey secretUid (generatedSecret chain) currentSecrets
      let reviewedSecret = generatedSecret chain
          liveReferences =
            [ resourceKey certificate
            | certificate <- currentManagers
            , certificateNamespace certificate == secretNamespace reviewedSecret
            , secretName certificate == Just (secretResourceName reviewedSecret)
            , certificateUid certificate /= certificateUid (certManagerCertificate chain)
            ]
      unless (null liveReferences) $
        Left
          ( secretKey reviewedSecret
              <> " is now referenced by another live Certificate: "
              <> T.intercalate ", " liveReferences
          )

verifyKubernetesPlanMetadata :: CurrentKubernetesIdentity -> KubernetesPlanMetadata -> Either Text ()
verifyKubernetesPlanMetadata current metadata
  | metadataSchemaVersion metadata /= 1 = Left "saved Kubernetes plan uses an unsupported metadata schema"
  | currentTransactionId current /= transactionId metadata = mismatch "transactionId" (transactionId metadata) (currentTransactionId current)
  | currentContext current /= context metadata = mismatch "context" (context metadata) (currentContext current)
  | currentPayloadId current /= payloadId metadata = mismatch "payloadId" (payloadId metadata) (currentPayloadId current)
  | currentPayloadDigest current /= payloadDigest metadata = mismatch "payloadDigest" (payloadDigest metadata) (currentPayloadDigest current)
  | otherwise = Right ()
  where
    mismatch field saved observed = Left ("saved Kubernetes plan " <> field <> " is '" <> saved <> "', but the current value is '" <> observed <> "'")

renderTargetConfigNetworkManifest :: ByteString
renderTargetConfigNetworkManifest =
  LBS.toStrict
    ( Aeson.encode
        ( Aeson.object
            [ "apiVersion" Aeson..= ("v1" :: Text)
            , "kind" Aeson..= ("ConfigMap" :: Text)
            , "metadata"
                Aeson..= Aeson.object
                  [ "name" Aeson..= ("config-network" :: Text)
                  , "namespace" Aeson..= ("knative-serving" :: Text)
                  ]
            , "data"
                Aeson..= Aeson.object
                  [ "external-domain-tls" Aeson..= ("Enabled" :: Text)
                  , "namespace-wildcard-cert-selector" Aeson..= targetSelectorText
                  ]
            ]
        )
    )
    <> "\n"

renderCertificateMigrationReview :: CertificateMigrationPlan -> Text
renderCertificateMigrationReview migration =
  T.unlines
    ( selectorLine
        <> map (renderChain "preserve") (preserve migration)
        <> map (renderChain "delete certificate") (remove migration)
        <> map (renderSecret "delete secret") (remove migration)
    )
  where
    selectorLine = case selectorChange migration of
      Nothing -> ["selector: no migration"]
      Just _ -> ["selector: {} -> matchLabels[nagare.dev/app-namespace=true]"]
    renderChain action chain = action <> ": " <> resourceKey (certManagerCertificate chain)
    renderSecret action chain = action <> ": " <> secretKey (generatedSecret chain)

targetSelectorText :: Text
targetSelectorText = "matchLabels:\n  nagare.dev/app-namespace: \"true\"\n"

secretManagedBy :: CertificateResource -> SecretObservation -> Bool
secretManagedBy manager secret =
  certificateUid manager `elem` secretOwnerUids secret
    || ( certificateNameAnnotation secret == Just (certificateName manager)
           && issuerNameAnnotation secret == Just (issuerName manager)
       )

rejectDuplicateTargets :: [CertificateChain] -> Either Text ()
rejectDuplicateTargets chains =
  case [key | (key, count) <- Map.toList counts, count > (1 :: Int)] of
    [] -> Right ()
    duplicates -> Left ("multiple Certificate chains target the same Secret: " <> T.intercalate ", " duplicates)
  where
    counts :: Map Text Int
    counts = Map.fromListWith (+) [(secretKey (generatedSecret chain), 1) | chain <- chains]

exactlyOne :: Text -> [a] -> Either Text a
exactlyOne _ [value] = Right value
exactlyOne message _ = Left message

matchesOrAbsent :: (Eq a) => Text -> (a -> Text) -> (a -> Text) -> a -> [a] -> Either Text ()
matchesOrAbsent kind key uid expected observed =
  case filter ((== key expected) . key) observed of
    [] -> Right ()
    [actual]
      | uid actual /= uid expected -> Left (kind <> " " <> key expected <> " UID changed after review")
      | actual /= expected -> Left (kind <> " " <> key expected <> " content or ownership changed after review")
      | otherwise -> Right ()
    _ -> Left (kind <> " " <> key expected <> " is duplicated in the live inventory")

resourceKey :: CertificateResource -> Text
resourceKey resource = certificateNamespace resource <> "/" <> certificateName resource

secretKey :: SecretObservation -> Text
secretKey secret = secretNamespace secret <> "/" <> secretResourceName secret

firstText :: Either String a -> Either Text a
firstText = either (Left . T.pack) Right
