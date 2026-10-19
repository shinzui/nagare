-- | Credential templates: reviewed Secrets (and the cache client ConfigMap)
-- that carry no data at review time. At the create-only mutation the runtime
-- fills them from freshly generated values; observation compares only the key
-- set, so a re-plan never rotates a credential.
module Nagare.Inventory.Adapters.CredentialTemplate
  ( metadataOf
  , fieldText
  , textAt
  , materializeCredential
  , materializeLocalObjectStoreCredentialWith
  , minioSourceData
  , generatedCredentialTemplate
  , databaseCredentialKind
  , AppDatabaseCredential (..)
  , appDatabaseCredentialKind
  , credentialDataMatches
  , cacheClientTemplate
  , withoutCacheClientData
  , cacheClientDataMatches
  , materializeCacheKey
  , validCachePublicKey
  )
where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Database.Secret (ConnectionParts (..), DbSecretInputs (..), appDatabaseSecretKeys, b64decode, b64encode, dbHost, defaultDbUser, renderDbSecret, sanitizeDbName, secretKeysFor)
import Nagare.Dsl.Database (Engine (..), dbSecretName, parseEngine)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

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
            Object root ->
              TE.decodeUtf8
                <$> canonicalValue
                  ( Object
                      (KM.insert "data" (Object (KM.fromList entries)) root)
                  )
            _ -> Left "auth credential template is malformed"
    Right Nothing -> case backupSigningCredentialKind value of
      Left reason -> pure (Left reason)
      Right (Just ()) -> do
        generated <- generateAuthKey "HMAC_KEY"
        pure $ do
          entry <- generated
          case value of
            Object root ->
              TE.decodeUtf8
                <$> canonicalValue
                  ( Object
                      (KM.insert "data" (Object (KM.fromList [entry])) root)
                  )
            _ -> Left "backup signing credential template is malformed"
      Right Nothing -> case databaseCredentialKind value of
        Left reason -> pure (Left reason)
        Right Nothing -> case appDatabaseCredentialKind value of
          Left reason -> pure (Left reason)
          Right Nothing -> pure (Right native)
          Right (Just credential) -> do
            generated <- generateDatabasePassword
            pure (generated >>= fillAppDatabaseCredential value credential)
        Right (Just (dbName, namespace, engine)) -> do
          generated <- generateDatabasePassword
          pure (generated >>= fillCredential value dbName namespace engine)

generateDatabasePassword :: IO (Either Text Text)
generateDatabasePassword = do
  generated <- try (readProcessWithExitCode "openssl" ["rand", "-hex", "24"] "")
  pure $ case generated of
    Left (_ :: IOException) -> Left "could not generate database credential"
    Right (ExitFailure _, _, _) -> Left "could not generate database credential"
    Right (ExitSuccess, output, _) -> do
      let password = T.strip (T.pack output)
      unless (T.length password == 48) (Left "database credential generator returned an invalid password")
      pure password

materializeLocalObjectStoreCredentialWith ::
  IO (Either Text (ExitCode, String, String)) ->
  KubernetesRuntimeConfig ->
  Text ->
  IO (Either Text Text)
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
          source <-
            first
              (const "local object-store source credential is malformed")
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
      unless
        ( namespace == expected
            && name == "nagare-minio-credentials"
            && not (KM.member "data" root)
            && not (KM.member "stringData" root)
        )
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
  unless
    ( name == "nagare-minio-credentials"
        && namespace == "nagare-system"
        && textAt "nagare.dev/context-id" annotations == Just (contextIdText (runtimeContext config))
        && textAt "nagare.dev/minio-credential-template" annotations == Just "v1"
        && textAt "nagare.dev/resource-id" annotations == Just expected
    )
    (Left "local object-store source credential is not owned by this context")
  case source of
    Object root -> case KM.lookup "data" root of
      Just (Object fields) | validMinioData fields -> Right fields
      _ -> Left "local object-store source credential lacks required data"
    _ -> Left "local object-store source credential is malformed"

validMinioData :: KM.KeyMap Value -> Bool
validMinioData fields =
  Set.fromList (KM.keys fields)
    == Set.fromList
      ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
    && all
      (\case String encoded -> either (const False) (not . T.null) (b64decode encoded); _ -> False)
      (KM.elems fields)

generateAuthKey :: Text -> IO (Either Text (Key, Value))
generateAuthKey key = do
  let base64Key = key == "key-encryption-key"
      args = if base64Key then ["rand", "-base64", "32"] else ["rand", "-hex", "32"]
  generated <- try (readProcessWithExitCode "openssl" args "")
  pure $ case generated of
    Left (_ :: IOException) -> Left "could not generate auth credential"
    Right (ExitFailure _, _, _) -> Left "could not generate auth credential"
    Right (ExitSuccess, output, _) ->
      let secret = T.strip (T.pack output)
       in if (base64Key && T.length secret == 44 && T.isSuffixOf "=" secret)
            || (not base64Key && T.length secret == 64)
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
      unless
        (namespace == "nagare-system" && not (KM.member "data" root) && not (KM.member "stringData" root))
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
  signing <- backupSigningCredentialKind value
  appDatabase <- appDatabaseCredentialKind value
  pure (isJust auth || isJust database || isJust minio || isJust signing || isJust appDatabase)

backupSigningCredentialKind :: Value -> Either Text (Maybe ())
backupSigningCredentialKind value@(Object root) | KM.lookup "kind" root == Just (String "Secret") = do
  metadata <- metadataOf value
  annotations <- case KM.lookup "annotations" metadata of
    Just (Object fields) -> Right fields
    Nothing -> Right KM.empty
    _ -> Left "backup signing credential annotations are malformed"
  case textAt "nagare.dev/backup-signing-template" annotations of
    Nothing -> Right Nothing
    Just "v1" -> do
      -- A database's schedule, or a volume's (EP-183 M3), names its own key.
      schedule <- case KM.lookup "labels" metadata of
        Just (Object labels)
          | KM.member "nagare.dev/volume-backup" labels -> fieldText "nagare.dev/volume-backup" labels
          -- EP-202: an app database's schedule is nagare-appdb-<app database>.
          | KM.member "nagare.dev/app-database" labels -> ("nagare-appdb-" <>) <$> fieldText "nagare.dev/app-database" labels
          | otherwise -> ("nagare-dbbackup-" <>) <$> fieldText "nagare.dev/database" labels
        _ -> Left "backup signing credential lacks database label"
      name <- fieldText "name" metadata
      _ <- fieldText "namespace" metadata
      unless
        ( name == schedule <> "-signing"
            && any (`T.isPrefixOf` name) ["nagare-dbbackup-", "nagare-volbackup-", "nagare-appdb-"]
            && not (KM.member "data" root)
            && not (KM.member "stringData" root)
        )
        (Left "backup signing credential template has unexpected content")
      pure (Just ())
    Just _ -> Left "unknown backup signing credential template"
backupSigningCredentialKind _ = Right Nothing

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
        unless
          (not (KM.member "data" root) && not (KM.member "stringData" root))
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
      Just "app-database-v1" -> Right Nothing
      Just _ -> Left "unknown Kubernetes credential template"
  _ -> Right Nothing

-- | What an app-database credential template names (EP-202). Its user and
-- database are carried as annotations and checked against the names the
-- app database derives, so a template cannot point at another user.
data AppDatabaseCredential = AppDatabaseCredential
  { appDatabase :: !Text
  , server :: !Text
  , namespace :: !Text
  , engine :: !Engine
  , role :: !Text
  , user :: !Text
  , database :: !Text
  }
  deriving stock (Generic, Eq, Show)

appDatabaseCredentialKind :: Value -> Either Text (Maybe AppDatabaseCredential)
appDatabaseCredentialKind value = case value of
  Object root | KM.lookup "kind" root == Just (String "Secret") -> do
    metadata <- metadataOf value
    annotations <- case KM.lookup "annotations" metadata of
      Just (Object fields) -> Right fields
      Nothing -> Right KM.empty
      _ -> Left "reviewed Secret annotations are malformed"
    case textAt "nagare.dev/credential-template" annotations of
      Just "app-database-v1" -> do
        unless
          (not (KM.member "data" root) && not (KM.member "stringData" root))
          (Left "app-database credential template may not include Secret data")
        labels <- case KM.lookup "labels" metadata of
          Just (Object fields) -> Right fields
          _ -> Left "app-database credential template lacks labels"
        appDatabase <- fieldText "nagare.dev/app-database" labels
        server <- fieldText "nagare.dev/app-database-server" labels
        role <- fieldText "nagare.dev/app-database-role" labels
        engineName <- fieldText "nagare.dev/engine" labels
        engine <- case parseEngine engineName of
          Just parsed | parsed /= Redis -> Right parsed
          _ -> Left "app-database credential template has an unsupported engine"
        user <- fieldText "nagare.dev/app-database-user" annotations
        database <- fieldText "nagare.dev/app-database-db" annotations
        namespace <- fieldText "namespace" metadata
        secretName <- fieldText "name" metadata
        unless (role `elem` ["runtime", "migration"]) (Left "app-database credential template has an unknown role")
        unless
          (secretName == appDatabase <> "-" <> role && user == sanitizeDbName appDatabase <> "_" <> role)
          (Left "app-database credential template names another Secret or user")
        pure (Just (AppDatabaseCredential appDatabase server namespace engine role user database))
      _ -> Right Nothing
  _ -> Right Nothing

fillAppDatabaseCredential :: Value -> AppDatabaseCredential -> Text -> Either Text Text
fillAppDatabaseCredential template credential password = do
  let connection =
        ConnectionParts
          (credential ^. #user)
          password
          (dbHost (credential ^. #server) (credential ^. #namespace))
          (credential ^. #database)
      secretData =
        object
          [ Key.fromText key .= b64encode keyValue
          | (key, keyValue) <- sortOn fst (appDatabaseSecretKeys (credential ^. #engine) connection)
          ]
  case template of
    Object root -> TE.decodeUtf8 <$> canonicalValue (Object (KM.insert "data" secretData root))
    _ -> Left "app-database credential template is malformed"

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
  Right (Just keys) ->
    databaseCredentialKind desired == Right Nothing
      && dataMatches (Set.fromList (map Key.fromText keys)) observed
  Left _ -> False
  Right Nothing -> case backupSigningCredentialKind desired of
    Right (Just ()) -> backupSigningDataMatches observed
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
  Right Nothing -> case appDatabaseCredentialKind desired of
    Right Nothing -> True
    Left _ -> False
    Right (Just credential) ->
      let connection = ConnectionParts "example" "example" "example" "example"
          expected = Set.fromList (map (Key.fromText . fst) (appDatabaseSecretKeys (credential ^. #engine) connection))
       in dataMatches expected observed
  Left _ -> False
  Right (Just (_, _, engine)) ->
    let connection = ConnectionParts defaultDbUser "example" "example" "example"
        expected = Set.fromList (map (Key.fromText . fst) (secretKeysFor engine connection))
     in dataMatches expected observed

backupSigningDataMatches :: Value -> Bool
backupSigningDataMatches (Object root) = case KM.lookup "data" root of
  Just (Object fields) | Set.fromList (KM.keys fields) == Set.singleton "HMAC_KEY" ->
    case KM.lookup "HMAC_KEY" fields of
      Just (String encoded) -> case b64decode encoded of
        Right key -> T.length key == 64 && T.all lowerHex key
        Left _ -> False
      _ -> False
  _ -> False
  where
    lowerHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
backupSigningDataMatches _ = False

dataMatches :: Set.Set Key -> Value -> Bool
dataMatches expected (Object root) = case KM.lookup "data" root of
  Just (Object entries) ->
    Set.fromList (KM.keys entries) == expected
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
        unless
          (name == "nagare-nix-cache-client" && namespace == "personal")
          (Left "cache client template has an unexpected address")
        producerText <- fieldText "nagare.dev/cache-key-producer" annotations
        producer <- mkResourceId producerText
        entries <- case KM.lookup "data" root of
          Just (Object fields) -> Right fields
          _ -> Left "cache client template has no data"
        template <- case KM.toList entries of
          [("nix.conf", String textValue)] -> Right textValue
          _ -> Left "cache client template must contain only nix.conf"
        unless
          (T.count "${ATTIC_PUBLIC_KEY}" template == 1)
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
  not (T.null key)
    && T.count ":" key == 1
    && T.all (\character -> character > ' ' && character /= '\DEL') key
