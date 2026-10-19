-- | Context-guarded transport for app-database members (EP-202). Every call
-- first checks the server StatefulSet and PVC against their recorded
-- incarnations (ADR 27), then runs SQL inside the exact server pod with the
-- container's own administrator env. SQL travels on stdin, never in argv,
-- and only hashes of passwords are sent.
module Nagare.Inventory.Adapters.AppDatabaseRuntime
  ( AppDatabaseRuntimeConfig (..)
  , appDatabaseRuntimeOps
  , credentialFromSecret
  , rotatedPatch
  )
where

import Control.Exception (IOException, try)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (..), eitherDecodeStrict, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Database.AppDatabase.Catalog (parseClickHouseCatalog, parsePostgresCatalog)
import Nagare.Database.AppDatabase.Sql
import Nagare.Database.Secret (b64decode, b64encode)
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.AppDatabase
import Nagare.Inventory.Identity (checkedPhysical, requireAccepted)
import Nagare.Resource.Types
import System.Exit (ExitCode (..))
import System.Process (proc, readCreateProcessWithExitCode)

data AppDatabaseRuntimeConfig = AppDatabaseRuntimeConfig
  { kubectlContext :: !Text
  , contextGuard :: !(IO (Either Text ()))
  , recordedIncarnations :: !(Map ResourceId PhysicalIdentity)
  }

appDatabaseRuntimeOps :: AppDatabaseRuntimeConfig -> AppDatabaseOps
appDatabaseRuntimeOps config =
  AppDatabaseOps
    { observeCatalog = observe
    , passwordMatches = matches
    , readCredential = credential
    , runCommand = run
    , rewriteCredential = rewrite
    , freshSalt = getRandomBytes 16
    , freshPassword = TE.decodeUtf8 . convertToBase Base16 <$> (getRandomBytes 24 :: IO ByteString)
    }
  where
    observe server users databases = guarded server $ case server ^. #engine of
      ClickHouse -> do
        output <- clickhouse server (renderObserveClickHouse users databases)
        pure (output >>= parseClickHouseCatalog users databases)
      _ -> do
        serverDocument <- psql server "postgres" (renderObserveServer users databases (server ^. #initialDatabase))
        case serverDocument >>= \bytes -> (bytes,) <$> parsePostgresCatalog bytes Map.empty of
          Left reason -> pure (Left reason)
          Right (bytes, shallow) -> do
            insides <- traverse (\db -> fmap (db,) <$> psql server db renderObserveDatabase) (Map.keys (shallow ^. #databases))
            pure (sequence insides >>= parsePostgresCatalog bytes . Map.fromList)
    matches server user password = guarded server $ case server ^. #engine of
      ClickHouse -> do
        -- The password reaches the pod on stdin; only the server pod sees it.
        result <-
          kubectl
            (execArgs server ["sh", "-c", "read -r P; clickhouse-client --user " <> user <> " --password \"$P\" --query 'SELECT 1'"])
            (password <> "\n")
        pure $ case result of
          Right (ExitSuccess, _, _) -> Right True
          Right (ExitFailure _, _, err) | "AUTHENTICATION_FAILED" `T.isInfixOf` T.pack err -> Right False
          Right _ -> Left "ClickHouse login check failed; inspect the server before retry"
          Left reason -> Left reason
      _ -> do
        stored <- psql server "postgres" (renderObservePassword user)
        pure (scramVerifierMatches password . T.strip . TE.decodeUtf8 <$> stored)
    credential namespace' secretName = do
      result <-
        guardedRaw
          (kubectl ["get", "secret", nameText secretName, "--namespace", nameText namespace', "-o", "json", "--ignore-not-found"] "")
      pure $ case result of
        Right (ExitSuccess, output, _)
          | all (`elem` (" \n" :: String)) output -> Right Nothing
          | otherwise -> Just <$> credentialFromSecret (TE.encodeUtf8 (T.pack output))
        Right _ -> Left "app-database credential Secret could not be read"
        Left reason -> Left reason
    -- The new password travels on stdin; the patch is the inventory's own
    -- field manager's, so the Secret keeps one owner, and the observed
    -- resourceVersion makes a concurrent writer fail the patch.
    rewrite namespace' secretName password' = do
      read' <- guardedRaw (kubectl ["get", "secret", nameText secretName, "--namespace", nameText namespace', "-o", "json"] "")
      case read' of
        Left reason -> pure (Left reason)
        Right (ExitFailure _, _, _) -> pure (Left "app-database credential Secret could not be read for rotation")
        Right (ExitSuccess, output, _) -> case rotatedPatch password' (TE.encodeUtf8 (T.pack output)) of
          Left reason -> pure (Left reason)
          Right patch -> do
            result <-
              guardedRaw
                ( kubectl
                    ["patch", "secret", nameText secretName, "--namespace", nameText namespace', "--type=merge", "--field-manager=nagare-inventory", "--patch-file=/dev/stdin"]
                    patch
                )
            pure $ case result of
              Right (ExitSuccess, _, _) -> Right ()
              Right _ -> Left "app-database credential Secret patch failed; it may have landed, so re-observe before retry"
              Left reason -> Left reason
    run server command = guarded server $ case server ^. #engine of
      ClickHouse -> void <$> clickhouse server (render ClickHouse command)
      engine' -> void <$> psql server "postgres" (render engine' command)
    render engine' = \case
      CreateUser user hash' db -> renderCreateUser engine' user hash' db
      SetUserAccess role user on -> renderUserAccess engine' role user on
      CreateDatabase db owner' -> renderCreateDatabase engine' db owner'
      SetDatabaseAccess access -> renderDatabaseAccess access
      SetPassword user hash' -> renderSetPassword user hash'
    psql server db sql =
      sqlOutput
        <$> kubectl
          (execArgs server ["sh", "-c", "psql -v ON_ERROR_STOP=1 -X -q -A -t -U \"$POSTGRES_USER\" -d " <> db])
          sql
    clickhouse server sql =
      sqlOutput
        <$> kubectl
          (execArgs server ["sh", "-c", "clickhouse-client --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\" --multiquery"])
          sql
    sqlOutput = \case
      Right (ExitSuccess, output, _) -> Right (TE.encodeUtf8 (T.pack output))
      Right (ExitFailure _, _, _) -> Left "app-database statement failed; it may have taken effect, so re-observe before retry"
      Left reason -> Left reason
    execArgs server command =
      ["exec", "-i", "--namespace", nameText (server ^. #namespace), "pod/" <> nameText (server ^. #name) <> "-0", "--"] <> command
    -- The guard and both incarnation checks precede every server call.
    guarded :: ServerRef -> IO (Either Text a) -> IO (Either Text a)
    guarded server action = do
      checked <- guardedRaw (incarnations server)
      case checked of
        Left reason -> pure (Left reason)
        Right () -> action
    guardedRaw :: IO (Either Text a) -> IO (Either Text a)
    guardedRaw action = do
      allowed <- contextGuard config
      case allowed of
        Left reason -> pure (Left ("app-database context guard refused: " <> reason))
        Right () -> action
    incarnations server = do
      stateful <- liveUid ["get", "statefulset", nameText (server ^. #name), "--namespace", nameText (server ^. #namespace), "-o", "json"]
      volume <- liveUid ["get", "persistentvolumeclaim", dbPvcName (nameText (server ^. #name)), "--namespace", nameText (server ^. #namespace), "-o", "json"]
      pure $ do
        statefulUid <- stateful
        volumeUid <- volume
        _ <- requireAccepted "the app-database server StatefulSet" (checkedPhysical (recordedIncarnations config) (server ^. #statefulSet) statefulUid)
        _ <- requireAccepted "the app-database server volume" (checkedPhysical (recordedIncarnations config) (server ^. #persistentVolume) volumeUid)
        pure ()
    liveUid args = do
      result <- kubectl args ""
      pure $ case result of
        Right (ExitSuccess, output, _) -> do
          value <- first (const "server object observation is malformed") (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)))
          case value of
            Object root
              | Just (Object metadata) <- KM.lookup "metadata" root
              , Just (String uid) <- KM.lookup "uid" metadata ->
                  mkPhysicalIdentity uid
            _ -> Left "server object has no UID"
        Right _ -> Left "server object could not be read"
        Left reason -> Left reason
    kubectl :: [Text] -> Text -> IO (Either Text (ExitCode, String, String))
    kubectl args input = do
      result <-
        try
          ( readCreateProcessWithExitCode
              (proc "kubectl" (map T.unpack (["--context", kubectlContext config] <> args)))
              (T.unpack input)
          )
      pure (first (\(_ :: IOException) -> "could not invoke the app-database transport") result)

-- | A merge patch that gives the Secret a new password and the same URL with
-- that password, guarded by the Secret's observed resourceVersion.
rotatedPatch :: Text -> ByteString -> Either Text Text
rotatedPatch password' bytes = do
  value <- first (const "app-database credential Secret is malformed") (eitherDecodeStrict bytes)
  (resourceVersion, fields) <- case value of
    Object root
      | Just (Object metadata) <- KM.lookup "metadata" root
      , Just (String version) <- KM.lookup "resourceVersion" metadata
      , Just (Object entries) <- KM.lookup "data" root ->
          Right (version, entries)
    _ -> Left "app-database credential Secret has no resourceVersion or data"
  current <- credentialFromSecret bytes
  let decoded key = case KM.lookup key fields of
        Just (String encoded) -> either (const Nothing) Just (b64decode encoded)
        _ -> Nothing
      (passwordKey, urlKey) = if KM.member "POSTGRES_PASSWORD" fields then ("POSTGRES_PASSWORD", "DATABASE_URL") else ("CLICKHOUSE_PASSWORD", "CLICKHOUSE_URL")
  url <- maybe (Left "app-database credential Secret has no URL") Right (decoded urlKey)
  let old = ":" <> current ^. #password <> "@"
  unless (T.count old url == 1) (Left "app-database credential URL does not carry its password exactly once")
  let rotatedUrl = T.replace old (":" <> password' <> "@") url
  pure
    ( TE.decodeUtf8
        ( LBS.toStrict
            ( encode
                ( object
                    [ "metadata" .= object ["resourceVersion" .= resourceVersion]
                    , "data" .= object [passwordKey .= b64encode password', urlKey .= b64encode rotatedUrl]
                    ]
                )
            )
        )
    )

-- | The password and logical database a credential Secret holds.
credentialFromSecret :: ByteString -> Either Text CredentialSecret
credentialFromSecret bytes = do
  value <- first (const "app-database credential Secret is malformed") (eitherDecodeStrict bytes)
  fields <- case value of
    Object root | Just (Object entries) <- KM.lookup "data" root -> Right entries
    _ -> Left "app-database credential Secret has no data"
  let decoded key = case KM.lookup key fields of
        Just (String encoded) -> either (const Nothing) Just (b64decode encoded)
        _ -> Nothing
  case (decoded "POSTGRES_PASSWORD", decoded "POSTGRES_DB", decoded "CLICKHOUSE_PASSWORD", decoded "CLICKHOUSE_DB") of
    (Just password', Just db, Nothing, Nothing) -> Right (CredentialSecret password' db)
    (Nothing, Nothing, Just password', Just db) -> Right (CredentialSecret password' db)
    _ -> Left "app-database credential Secret lacks its password or database"
