-- | Explicit-context kubectl transport for reviewed Kubernetes objects.
-- Create is a server-side create-only request. Ordinary updates are server-side
-- apply; an unnamed Service port transition uses a guarded JSON Patch.
-- Both include UID and resourceVersion checks. A forced transfer from the
-- create operation is allowed only after a live managed-fields check proves
-- there is no foreign owner of the object's non-status fields. A
-- transport failure is ambiguous until a new observation proves its outcome.
module Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (..)
  , mkKubernetesRuntimeOps
  , mkKubernetesRuntimeOpsWithCacheKey
  , desiredFieldsMatch
  , confirmInventoryFieldOwnership
  , confirmInventoryFieldOwnershipFor
  , jobCompleted
  , crdEstablished
  , certificateReady
  , knativeReady
  , materializeCredential
  , materializeLocalObjectStoreCredential
  , materializeLocalObjectStoreCredentialWith
  , minioSourceData
  , supportedUpdateAddress
  , credentialDataMatches
  , generatedCredentialTemplate
  , deploymentAvailable
  , materializeCacheKey
  , cacheClientDataMatches
  , withoutCacheClientData
  , observeCacheClientOutput
  ) where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Database.Secret (ConnectionParts (..), DbSecretInputs (..), b64decode, b64encode, dbHost, defaultDbUser, renderDbSecret, sanitizeDbName, secretKeysFor)
import Nagare.Dsl.Database (Engine, dbSecretName, parseEngine)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (AdapterExecution (..), OperationAction (..))
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Resource.Inventory (ManagedResource (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data KubernetesRuntimeConfig = KubernetesRuntimeConfig
  { runtimeContext :: !ContextId
  , runtimeKubectlContext :: !Text
  , runtimeGuard :: !(IO (Either Text ()))
  }

mkKubernetesRuntimeOps
  :: KubernetesRuntimeConfig
  -> Map ResourceId (ManagedResource, ByteString)
  -> KubernetesAdapterOps
mkKubernetesRuntimeOps config = mkKubernetesRuntimeOpsWithCacheKey config (\_ -> pure (Left "cache public-key resolver is not installed"))

mkKubernetesRuntimeOpsWithCacheKey
  :: KubernetesRuntimeConfig
  -> (ResourceId -> IO (Either Text Text))
  -> Map ResourceId (ManagedResource, ByteString)
  -> KubernetesAdapterOps
mkKubernetesRuntimeOpsWithCacheKey config resolveCacheKey specs =
  KubernetesAdapterOps
    { kubernetesContext = runtimeContext config
    , kubernetesObserve = observe
    , kubernetesMutateConditional = mutate
    }
  where
    observe resource = case Map.lookup resource specs of
      Nothing -> pure (KubernetesUnknown "Kubernetes resource has no native binding")
      Just (declaration, native) -> do
        guarded <- runtimeGuard config
        case guarded of
          Left reason -> pure (KubernetesUnknown ("cluster guard refused: " <> reason))
          Right () -> case address declaration of
            Kubernetes _ group kind namespace name -> do
              result <- invoke config
                (["get", kindToken group kind, T.unpack (nameText name)]
                  <> namespaceArgs namespace <> ["-o", "json", "--ignore-not-found"])
                ""
              case result of
                Left reason -> pure (KubernetesUnknown reason)
                Right (ExitFailure _, _, _) -> pure (KubernetesUnknown "kubectl get failed")
                Right (ExitSuccess, output, _)
                  | null output -> pure (KubernetesAbsent (contentDigest (TE.encodeUtf8 (resourceIdText resource <> ":absent"))))
                  | otherwise -> case parseObserved config resource native (T.pack output) of
                      Left reason -> pure (KubernetesUnknown reason)
                      Right state -> observeCacheClientOutput resolveCacheKey native (T.pack output) state
            _ -> pure (KubernetesUnknown "bound resource has no Kubernetes address")
    mutate mutation = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (AdapterEffectAmbiguous ("cluster guard refused before Kubernetes write: " <> reason))
        Right () -> do
          materialized <- case mutationAction mutation of
            CreateResource -> materializeLocalObjectStoreCredential config (mutationNativeJson mutation)
            _ -> pure (Right (mutationNativeJson mutation))
          resolved <- case materialized of
            Left reason -> pure (Left reason)
            Right native -> materializeCacheKey resolveCacheKey native
          request <- case (mutationAction mutation, mutationBefore mutation) of
            (CreateResource, KubernetesAbsent _) ->
              pure ((["create", "--field-manager=nagare-inventory", "-f", "-"],) <$> resolved)
            (UpdateResource, KubernetesPresent _ _ _ _)
              | not (supportedUpdateAddress (mutationAddress mutation)) ->
                  pure (Left "Kubernetes update kind lacks a proved conditional mutation policy")
            (UpdateResource, KubernetesPresent uid revision _ _) -> do
              case generatedCredentialTemplate (mutationNativeJson mutation) of
                Left reason -> pure (Left reason)
                Right True -> pure (Left "generated credential updates require a dedicated data-preserving operation")
                Right False -> do
                  ownership <- verifyLiveOwnership config (mutationAddress mutation) uid revision
                  pure $ do
                    observed <- ownership
                    native <- resolved
                    case mutationAddress mutation of
                      Kubernetes _ "" kind namespace name | nameText kind == "service" ->
                        case servicePortPatch uid revision native observed of
                          Left reason -> Left reason
                          Right (Just patch) -> Right
                            (["patch", "service", T.unpack (nameText name)] <> namespaceArgs namespace
                              <> ["--type=json", "--field-manager=nagare-inventory", "-p", T.unpack patch], "")
                          Right Nothing -> applyRequest uid revision native
                      _ -> applyRequest uid revision native
            _ -> pure (Left "Kubernetes transport received an unsupported action or precondition")
          case request of
            Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
            Right (arguments, body) -> do
              result <- invoke config arguments (T.unpack body)
              case result of
                Right (ExitSuccess, _, _) -> waitForReadiness config (mutationAddress mutation)
                _ -> pure (AdapterEffectAmbiguous "Kubernetes write did not return success; reobserve before retry")

-- | Each admitted kind has disposable-cluster evidence for ownership checks,
-- UID/resourceVersion handling, and its normal update form. New kinds require
-- their own update proof before they can enter this list.
supportedUpdateAddress :: ProviderAddress -> Bool
supportedUpdateAddress (Kubernetes _ group kind _ _) =
  (group, nameText kind) `elem`
    [ ("", "namespace")
    , ("", "configmap")
    , ("", "service")
    , ("", "secret")
    , ("", "persistentvolumeclaim")
    , ("", "resourcequota")
    , ("apps", "deployment")
    , ("apps", "statefulset")
    , ("batch", "cronjob")
    , ("networking.k8s.io", "networkpolicy")
    ]
supportedUpdateAddress _ = False

waitForReadiness :: KubernetesRuntimeConfig -> ProviderAddress -> IO AdapterExecution
waitForReadiness config address = case address of
  Kubernetes _ "batch" kind namespace name | nameText kind == "job" ->
    waitCondition "complete" "job" namespace name "Job"
  Kubernetes _ "apiextensions.k8s.io" kind namespace name | nameText kind == "customresourcedefinition" ->
    waitCondition "established" "crd" namespace name "CustomResourceDefinition"
  Kubernetes _ "cert-manager.io" kind namespace name
    | nameText kind `elem` ["certificate", "clusterissuer"] ->
      waitCondition "ready" (T.unpack (nameText kind)) namespace name "cert-manager resource"
  Kubernetes _ "serving.knative.dev" kind namespace name | nameText kind == "service" ->
    waitCondition "ready" "ksvc" namespace name "Knative Service"
  Kubernetes _ "apps" kind namespace name | nameText kind == "deployment" -> do
    result <- invoke config
      (["rollout", "status", "deployment/" <> T.unpack (nameText name)]
        <> namespaceArgs namespace <> ["--timeout=300s"])
      ""
    pure $ case result of
      Right (ExitSuccess, _, _) -> AdapterEffectCompleted
      _ -> AdapterEffectAmbiguous "Kubernetes Deployment did not prove availability; reobserve before retry"
  _ -> pure AdapterEffectCompleted
  where
    waitCondition condition kind namespace name label = do
      result <- invoke config
        (["wait", "--for=condition=" <> condition, kind <> "/" <> T.unpack (nameText name)]
          <> namespaceArgs namespace <> ["--timeout=300s"])
        ""
      pure $ case result of
        Right (ExitSuccess, _, _) -> AdapterEffectCompleted
        _ -> AdapterEffectAmbiguous ("Kubernetes " <> label <> " did not prove readiness; reobserve before retry")

-- The client ConfigMap's data is delegated at review time, but observation
-- still compares it with the current output of the named logical cache.
observeCacheClientOutput
  :: (ResourceId -> IO (Either Text Text))
  -> ByteString
  -> Text
  -> KubernetesState
  -> IO KubernetesState
observeCacheClientOutput resolve native response state = case eitherDecodeStrict native of
  Left (_ :: String) -> pure (KubernetesUnknown "cache client review bytes are malformed")
  Right desired -> case cacheClientTemplate desired of
    Left reason -> pure (KubernetesUnknown reason)
    Right Nothing -> pure state
    Right (Just (producer, template)) -> do
      resolved <- resolve producer
      pure $ case resolved of
        Left reason -> KubernetesUnknown reason
        Right key | not (validCachePublicKey key) -> KubernetesUnknown "cache public key is invalid"
        Right key -> case eitherDecodeStrict (TE.encodeUtf8 response) of
          Left (_ :: String) -> KubernetesUnknown "cache client observation is malformed"
          Right observed
            | observedClientText observed == Just (T.replace "${ATTIC_PUBLIC_KEY}" key template) -> state
            | otherwise -> case state of
                KubernetesPresent physical revision owner _ ->
                  KubernetesPresent physical revision owner (contentDigest (TE.encodeUtf8 response))
                _ -> state
  where
    observedClientText (Object root) = case KM.lookup "data" root of
      Just (Object entries) -> case KM.lookup "nix.conf" entries of
        Just (String value) -> Just value
        _ -> Nothing
      _ -> Nothing
    observedClientText _ = Nothing

-- | Compare only fields present in the retained desired object. Server-added
-- metadata, defaults and status do not count as drift. Arrays stay ordered;
-- this deliberately reports uncertain associative-list reorderings as drift.
desiredFieldsMatch :: Value -> Value -> Bool
desiredFieldsMatch (Object desired) (Object observed) =
  all (\(key, value) -> maybe False (desiredFieldsMatch value) (KM.lookup key observed)) (KM.toList desired)
desiredFieldsMatch (Array desired) (Array observed) =
  length desired == length observed && and (zipWith desiredFieldsMatch (foldr (:) [] desired) (foldr (:) [] observed))
desiredFieldsMatch desired observed = desired == observed

parseObserved :: KubernetesRuntimeConfig -> ResourceId -> ByteString -> Text -> Either Text KubernetesState
parseObserved config resource native response = do
  observed <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 response))
  desired <- first (T.pack . show) (eitherDecodeStrict native)
  metadata <- metadataOf observed
  uid <- fieldText "uid" metadata >>= mkPhysicalIdentity
  revision <- fieldText "resourceVersion" metadata
  annotations <- case KM.lookup "annotations" metadata of
    Nothing -> Right KM.empty
    Just (Object value) -> Right value
    _ -> Left "Kubernetes annotations are malformed"
  let stampedContext = textAt "nagare.dev/context-id" annotations
      stampedOwner = textAt "nagare.dev/resource-id" annotations >>= either (const Nothing) Just . mkResourceId
      owner = if stampedContext == Just (contextIdText (runtimeContext config)) then stampedOwner else Nothing
      desiredDigest = contentDigest native
      desiredMatches = desiredFieldsMatch (withoutCacheClientData desired) observed
        && credentialDataMatches desired observed
        && cacheClientDataMatches desired observed
        && textAt "nagare.dev/spec-digest" annotations == Just (digestText desiredDigest)
  case observed of
    Object root -> case KM.lookup "kind" root of
      Just (String "Job") -> unless (jobCompleted observed) (Left "Kubernetes Job has not completed")
      Just (String "CustomResourceDefinition") ->
        unless (crdEstablished observed) (Left "Kubernetes CustomResourceDefinition is not established")
      Just (String "Certificate") ->
        unless (certificateReady observed) (Left "Kubernetes Certificate is not ready")
      Just (String "ClusterIssuer") ->
        unless (certificateReady observed) (Left "Kubernetes ClusterIssuer is not ready")
      Just (String "Service") | KM.lookup "apiVersion" root == Just (String "serving.knative.dev/v1") ->
        unless (knativeReady observed) (Left "Knative Service is not ready")
      Just (String "Deployment") ->
        unless (deploymentAvailable observed) (Left "Kubernetes Deployment is not available")
      _ -> pure ()
    _ -> pure ()
  driftDigest <- if desiredMatches then Right desiredDigest else contentDigest <$> canonicalValue observed
  pure (KubernetesPresent uid revision (if owner == Just resource then owner else Nothing) driftDigest)

jobCompleted :: Value -> Bool
jobCompleted = hasCondition "Complete"

crdEstablished :: Value -> Bool
crdEstablished = hasCondition "Established"

certificateReady :: Value -> Bool
certificateReady = hasCondition "Ready"

knativeReady :: Value -> Bool
knativeReady = hasCondition "Ready"

hasCondition :: Text -> Value -> Bool
hasCondition conditionType (Object root) = case KM.lookup "status" root of
  Just (Object status) -> case KM.lookup "conditions" status of
    Just (Array conditions) -> any completed (foldr (:) [] conditions)
    _ -> False
  _ -> False
  where
    completed (Object condition) = KM.lookup "type" condition == Just (String conditionType)
      && KM.lookup "status" condition == Just (String "True")
    completed _ = False
hasCondition _ _ = False

deploymentAvailable :: Value -> Bool
deploymentAvailable value@(Object root) = hasCondition "Available" value
  && case (KM.lookup "status" root, KM.lookup "metadata" root) of
    (Just (Object status), Just (Object metadata)) ->
      case (KM.lookup "observedGeneration" status, KM.lookup "generation" metadata) of
        (Just observed, Just desired) -> observed == desired
        _ -> False
    _ -> False
deploymentAvailable _ = False

metadataOf :: Value -> Either Text Object
metadataOf (Object root) = case KM.lookup "metadata" root of
  Just (Object value) -> Right value
  _ -> Left "Kubernetes observation has no metadata"
metadataOf _ = Left "Kubernetes observation is not an object"

fieldText :: Key -> Object -> Either Text Text
fieldText key metadata = case KM.lookup key metadata of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("Kubernetes observation lacks " <> T.pack (show key))

textAt :: Key -> Object -> Maybe Text
textAt key value = case KM.lookup key value of Just (String textValue) -> Just textValue; _ -> Nothing

-- | Database credential templates carry no Secret.data at review time. At
-- mutation time only, materialize their data from a newly generated password.
-- The template's identity, labels and inventory stamps remain unchanged.
materializeCredential :: Text -> IO (Either Text Text)
materializeCredential native = case eitherDecodeStrict (TE.encodeUtf8 native) of
  Left (_ :: String) -> pure (Left "reviewed Kubernetes object is malformed")
  Right value -> case authCredentialKind value of
    Left reason -> pure (Left reason)
    Right (Just keys) -> case databaseCredentialKind value of
      Left reason -> pure (Left reason)
      Right (Just _) -> pure (Left "Secret cannot carry both auth and database credential templates")
      Right Nothing -> do
        generated <- traverse generateAuthKey keys
        pure $ do
          entries <- sequence generated
          case value of
            Object root -> TE.decodeUtf8 <$> canonicalValue (Object
              (KM.insert "data" (Object (KM.fromList entries)) root))
            _ -> Left "auth credential template is malformed"
    Right Nothing -> case databaseCredentialKind value of
      Left reason -> pure (Left reason)
      Right Nothing -> pure (Right native)
      Right (Just (dbName, namespace, engine)) -> do
        generated <- try (readProcessWithExitCode "openssl" ["rand", "-hex", "24"] "")
        pure $ case generated of
          Left (_ :: IOException) -> Left "could not generate database credential"
          Right (ExitFailure _, _, _) -> Left "could not generate database credential"
          Right (ExitSuccess, output, _) -> do
            let password = T.strip (T.pack output)
            unless (T.length password == 48) (Left "database credential generator returned an invalid password")
            fillCredential value dbName namespace engine password

-- | The local object's first Secret gets fresh values only at create time.
-- The second namespace receives those exact values after its reviewed
-- prerequisite, without storing them in the review or a fixed manifest.
materializeLocalObjectStoreCredential :: KubernetesRuntimeConfig -> Text -> IO (Either Text Text)
materializeLocalObjectStoreCredential config = materializeLocalObjectStoreCredentialWith
  (invoke config ["get", "secret", "nagare-minio-credentials", "-n", "nagare-system", "-o", "json"] "") config

materializeLocalObjectStoreCredentialWith
  :: IO (Either Text (ExitCode, String, String))
  -> KubernetesRuntimeConfig -> Text -> IO (Either Text Text)
materializeLocalObjectStoreCredentialWith readSource config native =
  case eitherDecodeStrict (TE.encodeUtf8 native) of
    Left (_ :: String) -> pure (Left "reviewed Kubernetes object is malformed")
    Right value -> case minioCredentialKind value of
      Left reason -> pure (Left reason)
      Right Nothing -> materializeCredential native
      Right (Just False) -> do
        access <- generateAuthKey "AWS_ACCESS_KEY_ID"
        secret <- generateAuthKey "AWS_SECRET_ACCESS_KEY"
        pure (insertMinioData value =<< (KM.fromList <$> sequence [access, secret]))
      Right (Just True) -> do
        fetched <- readSource
        pure $ do
          (code, body, _) <- fetched
          unless (code == ExitSuccess) (Left "local object-store source credential is unavailable")
          source <- first (const "local object-store source credential is malformed")
            (eitherDecodeStrict (TE.encodeUtf8 (T.pack body)))
          expected <- minioCopySourceId value
          fields <- minioSourceData config expected source
          insertMinioData value fields

insertMinioData :: Value -> KM.KeyMap Value -> Either Text Text
insertMinioData (Object root) fields =
  TE.decodeUtf8 <$> canonicalValue (Object (KM.insert "data" (Object fields) root))
insertMinioData _ _ = Left "local object-store credential template is malformed"

minioCredentialKind :: Value -> Either Text (Maybe Bool)
minioCredentialKind value@(Object root) | KM.lookup "kind" root == Just (String "Secret") = do
  metadata <- metadataOf value
  annotations <- case KM.lookup "annotations" metadata of
    Just (Object fields) -> Right fields
    Nothing -> Right KM.empty
    _ -> Left "local object-store credential annotations are malformed"
  let primary = textAt "nagare.dev/minio-credential-template" annotations
      copy = textAt "nagare.dev/minio-credential-copy" annotations
  case (primary, copy) of
    (Nothing, Nothing) -> Right Nothing
    (Just "v1", Nothing) -> validate "nagare-system" False
    (Nothing, Just "v1") -> validate "personal" True
    _ -> Left "local object-store credential template is malformed"
  where
    validate expected copied = do
      metadata <- metadataOf value
      namespace <- fieldText "namespace" metadata
      name <- fieldText "name" metadata
      unless (namespace == expected && name == "nagare-minio-credentials"
          && not (KM.member "data" root) && not (KM.member "stringData" root))
        (Left "local object-store credential template has unexpected content")
      pure (Just copied)
minioCredentialKind _ = Right Nothing

minioCopySourceId :: Value -> Either Text Text
minioCopySourceId value = do
  metadata <- metadataOf value
  annotations <- case KM.lookup "annotations" metadata of
    Just (Object fields) -> Right fields
    _ -> Left "local object-store copy lacks source identity"
  fieldText "nagare.dev/minio-source-resource-id" annotations

minioSourceData :: KubernetesRuntimeConfig -> Text -> Value -> Either Text (KM.KeyMap Value)
minioSourceData config expected source = do
  metadata <- metadataOf source
  name <- fieldText "name" metadata
  namespace <- fieldText "namespace" metadata
  annotations <- case KM.lookup "annotations" metadata of
    Just (Object fields) -> Right fields
    _ -> Left "local object-store source credential has no ownership stamps"
  unless (name == "nagare-minio-credentials" && namespace == "nagare-system"
      && textAt "nagare.dev/context-id" annotations == Just (contextIdText (runtimeContext config))
      && textAt "nagare.dev/minio-credential-template" annotations == Just "v1"
      && textAt "nagare.dev/resource-id" annotations == Just expected)
    (Left "local object-store source credential is not owned by this context")
  case source of
    Object root -> case KM.lookup "data" root of
      Just (Object fields) | validMinioData fields -> Right fields
      _ -> Left "local object-store source credential lacks required data"
    _ -> Left "local object-store source credential is malformed"

validMinioData :: KM.KeyMap Value -> Bool
validMinioData fields = Set.fromList (KM.keys fields) == Set.fromList
  ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
  && all (\case String encoded -> either (const False) (not . T.null) (b64decode encoded); _ -> False)
    (KM.elems fields)

generateAuthKey :: Text -> IO (Either Text (Key, Value))
generateAuthKey key = do
  generated <- try (readProcessWithExitCode "openssl" ["rand", "-hex", "32"] "")
  pure $ case generated of
    Left (_ :: IOException) -> Left "could not generate auth credential"
    Right (ExitFailure _, _, _) -> Left "could not generate auth credential"
    Right (ExitSuccess, output, _) ->
      let secret = T.strip (T.pack output)
       in if T.length secret == 64
            then Right (Key.fromText key, String (b64encode secret))
            else Left "auth credential generator returned an invalid value"

authCredentialKind :: Value -> Either Text (Maybe [Text])
authCredentialKind (Object root) | KM.lookup "kind" root == Just (String "Secret") = do
  metadata <- metadataOf (Object root)
  annotations <- case KM.lookup "annotations" metadata of
    Just (Object fields) -> Right fields
    Nothing -> Right KM.empty
    _ -> Left "auth credential annotations are malformed"
  case textAt "nagare.dev/auth-credential-template" annotations of
    Nothing -> Right Nothing
    Just "v1" -> do
      namespace <- fieldText "namespace" metadata
      name <- fieldText "name" metadata
      unless (namespace == "nagare-system" && not (KM.member "data" root) && not (KM.member "stringData" root))
        (Left "auth credential template has an invalid namespace or includes data")
      case name of
        "nagare-en-api-keys" -> Right (Just ["read-write", "read-only"])
        "nagare-shomei-keys" -> Right (Just ["key-encryption-key"])
        "nagare-access" -> Right (Just ["cookie-key"])
        _ -> Left "auth credential template has an unexpected Secret name"
    Just _ -> Left "unknown auth credential template"
authCredentialKind _ = Right Nothing

generatedCredentialTemplate :: Text -> Either Text Bool
generatedCredentialTemplate native = do
  value <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 native))
  auth <- authCredentialKind value
  database <- databaseCredentialKind value
  minio <- minioCredentialKind value
  pure (isJust auth || isJust database || isJust minio)

databaseCredentialKind :: Value -> Either Text (Maybe (Text, Text, Engine))
databaseCredentialKind value = case value of
  Object root | KM.lookup "kind" root == Just (String "Secret") -> do
    metadata <- metadataOf value
    annotations <- case KM.lookup "annotations" metadata of
      Just (Object fields) -> Right fields
      Nothing -> Right KM.empty
      _ -> Left "reviewed Secret annotations are malformed"
    case textAt "nagare.dev/credential-template" annotations of
      Nothing -> Right Nothing
      Just "database-v1" -> do
        unless (not (KM.member "data" root) && not (KM.member "stringData" root))
          (Left "database credential template may not include Secret data")
        labels <- case KM.lookup "labels" metadata of
          Just (Object fields) -> Right fields
          _ -> Left "database credential template lacks labels"
        dbName <- fieldText "nagare.dev/database" labels
        namespace <- fieldText "namespace" metadata
        secretName <- fieldText "name" metadata
        unless (secretName == dbSecretName dbName) (Left "database credential template has the wrong Secret name")
        engineName <- fieldText "nagare.dev/engine" labels
        engine <- maybe (Left "database credential template has an unknown engine") Right (parseEngine engineName)
        pure (Just (dbName, namespace, engine))
      Just _ -> Left "unknown Kubernetes credential template"
  _ -> Right Nothing

fillCredential :: Value -> Text -> Text -> Engine -> Text -> Either Text Text
fillCredential template dbName namespace engine password = do
  let connection = ConnectionParts defaultDbUser password (dbHost dbName namespace) (sanitizeDbName dbName)
      generated = renderDbSecret (DbSecretInputs dbName namespace engine (secretKeysFor engine connection))
  generatedValue <- first (T.pack . show) (eitherDecodeStrict generated)
  secretData <- case generatedValue of
    Object root -> maybe (Left "generated credential has no data") Right (KM.lookup "data" root)
    _ -> Left "generated credential is malformed"
  case template of
    Object root -> TE.decodeUtf8 <$> canonicalValue (Object (KM.insert "data" secretData root))
    _ -> Left "credential template is malformed"

credentialDataMatches :: Value -> Value -> Bool
credentialDataMatches desired observed = case authCredentialKind desired of
  Right (Just keys) -> databaseCredentialKind desired == Right Nothing
    && dataMatches (Set.fromList (map Key.fromText keys)) observed
  Left _ -> False
  Right Nothing -> case minioCredentialKind desired of
    Right (Just _) -> case observed of
      Object root -> case KM.lookup "data" root of
        Just (Object fields) -> validMinioData fields
        _ -> False
      _ -> False
    Left _ -> False
    Right Nothing -> databaseDataMatches desired observed

databaseDataMatches :: Value -> Value -> Bool
databaseDataMatches desired observed = case databaseCredentialKind desired of
  Right Nothing -> True
  Left _ -> False
  Right (Just (_, _, engine)) ->
    let connection = ConnectionParts defaultDbUser "example" "example" "example"
        expected = Set.fromList (map (Key.fromText . fst) (secretKeysFor engine connection))
     in dataMatches expected observed

dataMatches :: Set.Set Key -> Value -> Bool
dataMatches expected (Object root) = case KM.lookup "data" root of
  Just (Object entries) -> Set.fromList (KM.keys entries) == expected
    && all (\case String encoded -> either (const False) (not . T.null) (b64decode encoded); _ -> False) (KM.elems entries)
  _ -> False
dataMatches _ _ = False

cacheClientTemplate :: Value -> Either Text (Maybe (ResourceId, Text))
cacheClientTemplate value = case value of
  Object root | KM.lookup "kind" root == Just (String "ConfigMap") -> do
    metadata <- metadataOf value
    annotations <- case KM.lookup "annotations" metadata of
      Just (Object fields) -> Right fields
      Nothing -> Right KM.empty
      _ -> Left "cache client annotations are malformed"
    case textAt "nagare.dev/cache-client-template" annotations of
      Nothing -> Right Nothing
      Just "v1" -> do
        name <- fieldText "name" metadata
        namespace <- fieldText "namespace" metadata
        unless (name == "nagare-nix-cache-client" && namespace == "personal")
          (Left "cache client template has an unexpected address")
        producerText <- fieldText "nagare.dev/cache-key-producer" annotations
        producer <- mkResourceId producerText
        entries <- case KM.lookup "data" root of
          Just (Object fields) -> Right fields
          _ -> Left "cache client template has no data"
        template <- case KM.toList entries of
          [("nix.conf", String textValue)] -> Right textValue
          _ -> Left "cache client template must contain only nix.conf"
        unless (T.count "${ATTIC_PUBLIC_KEY}" template == 1)
          (Left "cache client template has no unique public-key slot")
        pure (Just (producer, template))
      Just _ -> Left "unknown cache client template"
  _ -> Right Nothing

withoutCacheClientData :: Value -> Value
withoutCacheClientData value@(Object root) = case cacheClientTemplate value of
  Right (Just _) -> Object (KM.delete "data" root)
  _ -> value
withoutCacheClientData value = value

cacheClientDataMatches :: Value -> Value -> Bool
cacheClientDataMatches desired observed = case cacheClientTemplate desired of
  Right Nothing -> True
  Left _ -> False
  Right (Just (_, template)) -> case observed of
    Object root -> case KM.lookup "data" root of
      Just (Object entries) -> case KM.toList entries of
        [("nix.conf", String actual)] ->
          let (prefix, markerAndSuffix) = T.breakOn "${ATTIC_PUBLIC_KEY}" template
              suffix = T.drop (T.length "${ATTIC_PUBLIC_KEY}") markerAndSuffix
           in case T.stripPrefix prefix actual >>= T.stripSuffix suffix of
                Just key -> validCachePublicKey key
                Nothing -> False
        _ -> False
      _ -> False
    _ -> False

materializeCacheKey :: (ResourceId -> IO (Either Text Text)) -> Text -> IO (Either Text Text)
materializeCacheKey resolve native = case eitherDecodeStrict (TE.encodeUtf8 native) of
  Left (_ :: String) -> pure (Left "reviewed cache client object is malformed")
  Right value -> case cacheClientTemplate value of
    Left reason -> pure (Left reason)
    Right Nothing -> pure (Right native)
    Right (Just (producer, template)) -> do
      resolved <- resolve producer
      pure $ do
        key <- resolved
        unless (validCachePublicKey key) (Left "cache resolver returned an invalid public key")
        case value of
          Object root -> do
            let dataValue = object ["nix.conf" .= T.replace "${ATTIC_PUBLIC_KEY}" key template]
            TE.decodeUtf8 <$> canonicalValue (Object (KM.insert "data" dataValue root))
          _ -> Left "cache client object is malformed"

validCachePublicKey :: Text -> Bool
validCachePublicKey key =
  not (T.null key) && T.count ":" key == 1
    && T.all (\character -> character > ' ' && character /= '\DEL') key

addPreconditions :: PhysicalIdentity -> Text -> Text -> Either Text Text
addPreconditions uid revision native = do
  value <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 native))
  metadata <- metadataOf value
  let guarded = KM.insert "uid" (String (physicalIdentityText uid))
        (KM.insert "resourceVersion" (String revision) metadata)
  case value of
    Object root -> TE.decodeUtf8 <$> canonicalValue (Object (KM.insert "metadata" (Object guarded) root))
    _ -> Left "Kubernetes native object is not an object"

applyRequest :: PhysicalIdentity -> Text -> Text -> Either Text ([String], Text)
applyRequest uid revision native = do
  body <- addPreconditions uid revision native
  pure (["apply", "--server-side", "--force-conflicts", "--field-manager=nagare-inventory", "-f", "-"], body)

-- | Service ports use a merge key that includes the port number. SSA can
-- temporarily retain both unnamed entries while changing that number, which
-- fails Service validation. For a port-only transition, replace the entire
-- reviewed port list atomically after testing UID and resourceVersion. Refuse
-- if any other desired field differs, so the patch cannot silently omit it.
servicePortPatch :: PhysicalIdentity -> Text -> Text -> Value -> Either Text (Maybe Text)
servicePortPatch uid revision native observed = do
  desired <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 native))
  desiredSpec <- specOf desired
  observedSpec <- specOf observed
  ports <- maybe (Left "reviewed Service lacks spec.ports") Right (KM.lookup "ports" desiredSpec)
  oldPorts <- maybe (Left "observed Service lacks spec.ports") Right (KM.lookup "ports" observedSpec)
  if desiredFieldsMatch ports oldPorts then Right Nothing else do
    desiredMetadata <- metadataOf desired
    observedMetadata <- metadataOf observed
    desiredAnnotations <- annotationsOf desiredMetadata
    observedAnnotations <- annotationsOf observedMetadata
    newDigest <- maybe (Left "reviewed Service lacks spec digest") Right (KM.lookup "nagare.dev/spec-digest" desiredAnnotations)
    let projectedSpec = KM.insert "ports" ports observedSpec
        projectedAnnotations = KM.insert "nagare.dev/spec-digest" newDigest observedAnnotations
        projectedMetadata = KM.insert "annotations" (Object projectedAnnotations) observedMetadata
        projected = case observed of
          Object root -> Object (KM.insert "metadata" (Object projectedMetadata) (KM.insert "spec" (Object projectedSpec) root))
          _ -> observed
    unless (desiredFieldsMatch desired projected)
      (Left "Service port transition also changes other fields; a guarded per-kind patch is required")
    patch <- canonicalValue (toJSON
      [ object ["op" .= ("test" :: Text), "path" .= ("/metadata/uid" :: Text), "value" .= physicalIdentityText uid]
      , object ["op" .= ("test" :: Text), "path" .= ("/metadata/resourceVersion" :: Text), "value" .= revision]
      , object ["op" .= ("replace" :: Text), "path" .= ("/spec/ports" :: Text), "value" .= ports]
      , object ["op" .= ("replace" :: Text), "path" .= ("/metadata/annotations/nagare.dev~1spec-digest" :: Text), "value" .= newDigest]
      ])
    pure (Just (TE.decodeUtf8 patch))
  where
    specOf (Object root) = case KM.lookup "spec" root of
      Just (Object value) -> Right value
      _ -> Left "Service lacks spec object"
    specOf _ = Left "Service is not an object"
    annotationsOf metadata = case KM.lookup "annotations" metadata of
      Just (Object value) -> Right value
      _ -> Left "Service inventory annotations are missing"

-- | A create is recorded as an Update field manager even when it uses the
-- same manager name as later server-side apply. Force is safe only while all
-- non-status fields still belong exclusively to that manager. The subsequent
-- apply includes the observed UID/resourceVersion, so a change after this
-- read makes the API server reject the write.
confirmInventoryFieldOwnership :: PhysicalIdentity -> Text -> Value -> Either Text ()
confirmInventoryFieldOwnership = confirmInventoryFieldOwnershipFor Nothing

confirmInventoryFieldOwnershipFor :: Maybe ProviderAddress -> PhysicalIdentity -> Text -> Value -> Either Text ()
confirmInventoryFieldOwnershipFor target uid revision observed = do
  metadata <- metadataOf observed
  actualUid <- fieldText "uid" metadata
  actualRevision <- fieldText "resourceVersion" metadata
  unless (actualUid == physicalIdentityText uid && actualRevision == revision)
    (Left "Kubernetes object changed after the reviewed observation")
  fields <- case KM.lookup "managedFields" metadata of
    Just (Array entries) | not (null entries) -> Right (foldr (:) [] entries)
    _ -> Left "Kubernetes managed fields are missing; update ownership is unknown"
  mapM_ checkEntry fields
  unless (any isInventoryOwner fields)
    (Left "Kubernetes object has no inventory-managed fields to update")
  where
    checkEntry (Object entry) = do
      manager <- fieldText "manager" entry
      fieldSet <- case KM.lookup "fieldsV1" entry of
        Just (Object value) -> Right value
        _ -> Left "Kubernetes managed-field entry is malformed"
      unless (manager == "nagare-inventory" || statusOnly fieldSet || expectedControllerFields target manager fieldSet)
        (Left ("Kubernetes object has fields managed by another writer: " <> manager))
    checkEntry _ = Left "Kubernetes managed-field entry is malformed"
    isInventoryOwner (Object entry) = textAt "manager" entry == Just "nagare-inventory"
    isInventoryOwner _ = False
    statusOnly fields = all (== "f:status") (KM.keys fields)

-- PVC provisioners add these annotations after the create-only write. They
-- do not intersect inventory's desired fields. Any other controller field is
-- still a refusal until its specific owner and path have been established.
expectedControllerFields :: Maybe ProviderAddress -> Text -> Object -> Bool
expectedControllerFields (Just (Kubernetes _ "" kind _ _)) "k3s" fields
  | nameText kind == "persistentvolumeclaim" =
      not (null paths) && all (`elem` allowed) paths
  where
    paths = managedPaths [] fields
    allowed =
      [ ["f:metadata", "f:annotations", "f:volume.beta.kubernetes.io/storage-provisioner"]
      , ["f:metadata", "f:annotations", "f:volume.kubernetes.io/selected-node"]
      , ["f:metadata", "f:annotations", "f:volume.kubernetes.io/storage-provisioner"]
      , ["f:spec", "f:volumeName"]
      ]
expectedControllerFields (Just (Kubernetes _ "apps" kind _ _)) "k3s" fields
  | nameText kind == "deployment" =
      ["f:metadata", "f:annotations", "f:deployment.kubernetes.io/revision"] `elem` paths
        && all permitted paths
  where
    paths = managedPaths [] fields
    permitted ["f:metadata", "f:annotations", "."] = True
    permitted ["f:metadata", "f:annotations", "f:deployment.kubernetes.io/revision"] = True
    permitted ("f:status" : _) = True
    permitted _ = False
expectedControllerFields _ _ _ = False

managedPaths :: [Text] -> Object -> [[Text]]
managedPaths prefix fields = concatMap one (KM.toList fields)
  where
    one (key, Object nested)
      | KM.null nested = [prefix <> [Key.toText key]]
      | otherwise = managedPaths (prefix <> [Key.toText key]) nested
    one (key, _) = [prefix <> [Key.toText key]]

verifyLiveOwnership :: KubernetesRuntimeConfig -> ProviderAddress -> PhysicalIdentity -> Text -> IO (Either Text Value)
verifyLiveOwnership config target uid revision = case target of
  Kubernetes _ group kind namespace name -> do
    result <- invoke config
      (["get", kindToken group kind, T.unpack (nameText name)]
        <> namespaceArgs namespace <> ["-o", "json", "--show-managed-fields"])
      ""
    pure $ case result of
      Right (ExitSuccess, output, _) -> do
        observed <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)))
        confirmInventoryFieldOwnershipFor (Just target) uid revision observed
        pure observed
      _ -> Left "could not verify Kubernetes field ownership before update"
  _ -> pure (Left "Kubernetes mutation has no Kubernetes address")

kindToken :: Text -> Name -> String
kindToken group kind = T.unpack (nameText kind <> if T.null group then "" else "." <> group)

namespaceArgs :: Maybe Name -> [String]
namespaceArgs = maybe [] (\namespace -> ["--namespace", T.unpack (nameText namespace)])

invoke :: KubernetesRuntimeConfig -> [String] -> String -> IO (Either Text (ExitCode, String, String))
invoke config arguments input = do
  result <- try (readProcessWithExitCode "kubectl"
    (["--context", T.unpack (runtimeKubectlContext config), "--request-timeout=10s"] <> arguments) input)
  pure $ case result of
    Left (_ :: IOException) -> Left "could not invoke kubectl"
    Right output -> Right output
