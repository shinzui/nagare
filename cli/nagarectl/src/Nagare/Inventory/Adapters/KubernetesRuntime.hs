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
  , desiredFieldsMatch
  , confirmInventoryFieldOwnership
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
import Nagare.Database.Secret (ConnectionParts (..), DbSecretInputs (..), b64decode, dbHost, defaultDbUser, renderDbSecret, sanitizeDbName, secretKeysFor)
import Nagare.Dsl.Database (Engine, dbSecretName, parseEngine)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (AdapterExecution (..), OperationAction (..))
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest (contentDigest)
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
mkKubernetesRuntimeOps config specs =
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
              pure $ case result of
                Left reason -> KubernetesUnknown reason
                Right (ExitFailure _, _, _) -> KubernetesUnknown "kubectl get failed"
                Right (ExitSuccess, output, _)
                  | null output -> KubernetesAbsent (contentDigest (TE.encodeUtf8 (resourceIdText resource <> ":absent")))
                  | otherwise -> either KubernetesUnknown id (parseObserved config resource native (T.pack output))
            _ -> pure (KubernetesUnknown "bound resource has no Kubernetes address")
    mutate mutation = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (AdapterEffectAmbiguous ("cluster guard refused before Kubernetes write: " <> reason))
        Right () -> do
          let native = mutationNativeJson mutation
          request <- case (mutationAction mutation, mutationBefore mutation) of
            (CreateResource, KubernetesAbsent _) -> do
              materialized <- materializeCredential native
              pure ((["create", "--field-manager=nagare-inventory", "-f", "-"],) <$> materialized)
            (UpdateResource, KubernetesPresent uid revision _ _) -> do
              ownership <- verifyLiveOwnership config (mutationAddress mutation) uid revision
              pure $ do
                observed <- ownership
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
            Left reason -> pure (AdapterEffectAmbiguous reason)
            Right (arguments, body) -> do
              result <- invoke config arguments (T.unpack body)
              pure $ case result of
                Right (ExitSuccess, _, _) -> AdapterEffectCompleted
                _ -> AdapterEffectAmbiguous "Kubernetes write did not return success; reobserve before retry"

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
      desiredMatches = desiredFieldsMatch desired observed
        && credentialDataMatches desired observed
        && textAt "nagare.dev/spec-digest" annotations == Just (digestText desiredDigest)
  driftDigest <- if desiredMatches then Right desiredDigest else contentDigest <$> canonicalValue observed
  pure (KubernetesPresent uid revision (if owner == Just resource then owner else Nothing) driftDigest)

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
  Right value -> case databaseCredentialKind value of
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
credentialDataMatches desired observed = case databaseCredentialKind desired of
  Right Nothing -> True
  Left _ -> False
  Right (Just (_, _, engine)) -> case observed of
    Object root -> case KM.lookup "data" root of
      Just (Object entries) ->
        let connection = ConnectionParts defaultDbUser "example" "example" "example"
            expected = Set.fromList (map (Key.fromText . fst) (secretKeysFor engine connection))
         in Set.fromList (KM.keys entries) == expected
              && all (\case String encoded -> either (const False) (not . T.null) (b64decode encoded); _ -> False) (KM.elems entries)
      _ -> False
    _ -> False

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
confirmInventoryFieldOwnership uid revision observed = do
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
      unless (manager == "nagare-inventory" || statusOnly fieldSet)
        (Left "Kubernetes object has fields managed by another writer")
    checkEntry _ = Left "Kubernetes managed-field entry is malformed"
    isInventoryOwner (Object entry) = textAt "manager" entry == Just "nagare-inventory"
    isInventoryOwner _ = False
    statusOnly fields = all (== "f:status") (KM.keys fields)

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
        confirmInventoryFieldOwnership uid revision observed
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
