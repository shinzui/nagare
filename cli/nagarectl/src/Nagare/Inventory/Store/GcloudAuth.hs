-- | A command-local gcloud identity and expiring token cache. Credentials remain
-- owned by gcloud; neither ADC nor the credential database is inspected.
module Nagare.Inventory.Store.GcloudAuth
  ( GcloudSession
  , newGcloudSession
  , newGcloudSessionWith
  , sessionToken
  , sessionCapture
  , sessionStorageEndpoint
  )
where

import Control.Concurrent.MVar (modifyMVar, newMVar)
import Control.Exception (IOException, try)
import Data.Aeson qualified as A
import Data.Aeson.Types (Parser, parseEither, (.:), (.:?))
import Data.Char (isControl, isSpace)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Nagare.Dsl.Prelude
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)

-- Deliberately no Show instances: snapshots contain credentials.
data Snapshot = Snapshot !T.Text !UTCTime !T.Text !(Map.Map T.Text T.Text) !T.Text !T.Text

data GcloudSession = GcloudSession
  { sessionToken :: !(IO T.Text)
  , sessionStorageEndpoint :: !T.Text
  , sessionCapture :: !([String] -> IO (Maybe T.Text))
  }

type Runner = [(String, String)] -> [String] -> IO (Either T.Text T.Text)

newGcloudSession :: T.Text -> IO (Either T.Text GcloudSession)
newGcloudSession project = do
  variables <- getEnvironment
  newGcloudSessionWith getCurrentTime run variables project
  where
    run variables args = do
      result <- timeout 15000000 (try (readCreateProcessWithExitCode ((proc "gcloud" args) {env = Just variables}) ""))
      pure $ case result of
        Just (Right (ExitSuccess, output, _)) -> Right (T.pack output)
        Just (Left (_ :: IOException)) -> Left "gcloud credential or ownership command could not start"
        _ -> Left "gcloud credential or ownership command failed or timed out"

-- | Clock/process injection for identity-change and concurrent-refresh tests.
-- The helper contract is documented by `gcloud config config-helper --help`.
-- It is an internal gcloud interface: malformed/unsupported output fails closed.
newGcloudSessionWith :: IO UTCTime -> Runner -> [(String, String)] -> T.Text -> IO (Either T.Text GcloudSession)
newGcloudSessionWith clock run inherited project = do
  let base =
        replace
          inherited
          [ ("CLOUDSDK_CORE_PROJECT", T.unpack project)
          , ("CLOUDSDK_CORE_DISABLE_PROMPTS", "true")
          , ("CLOUDSDK_CORE_LOG_HTTP", "false")
          , ("CLOUDSDK_CORE_DISABLE_FILE_LOGGING", "true")
          ]
      helper = ["config", "config-helper", "--format=json", "--min-expiry=120s", "--quiet"]
      acquire variables = do
        output <- run variables helper
        now <- clock
        pure (output >>= parseSnapshot project now)
  initial <- acquire base
  case initial of
    Left reason -> pure (Left reason)
    Right (Snapshot _ _ account auth _ configuration)
      | any
          (\(key, actual) -> maybe False (\expected -> not (null expected) && T.pack expected /= actual) (lookup key inherited))
          [("CLOUDSDK_CORE_ACCOUNT", account), ("CLOUDSDK_ACTIVE_CONFIG_NAME", configuration), ("CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT", Map.findWithDefault "" "impersonate_service_account" auth)] ->
          pure (Left "inventory gcloud credential response disagrees with the explicitly selected identity")
    Right snapshot@(Snapshot _ _ account auth endpoint configuration) -> do
      let keys = ["impersonate_service_account", "credential_file_override", "access_token_file", "access_token", "disable_credentials"]
          frozen =
            replace
              base
              ( ("CLOUDSDK_CORE_ACCOUNT", T.unpack account)
                  : ("CLOUDSDK_ACTIVE_CONFIG_NAME", T.unpack configuration)
                  : ("CLOUDSDK_CORE_UNIVERSE_DOMAIN", "googleapis.com")
                  : ("CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE", T.unpack endpoint)
                  : [("CLOUDSDK_AUTH_" <> T.unpack (T.toUpper key), T.unpack (Map.findWithDefault (if key == "disable_credentials" then "false" else "") key auth)) | key <- keys]
              )
          identity (Snapshot _ _ selected settings endpointValue configValue) = (selected, settings, endpointValue, configValue)
      cache <- newMVar (Just snapshot)
      let token = do
            -- Commit failure before throwing: throwing inside modifyMVar would
            -- restore the expired snapshot and let every waiter spawn gcloud.
            result <- modifyMVar cache $ \case
              Nothing -> pure (Nothing, Nothing)
              Just old@(Snapshot access expiry _ _ _ _) -> do
                now <- clock
                if addUTCTime 60 now < expiry
                  then pure (Just old, Just access)
                  else do
                    updated <- try (acquire frozen)
                    case updated of
                      Right (Right next@(Snapshot value _ _ _ _ _)) | identity next == identity snapshot -> pure (Just next, Just value)
                      Left (_ :: IOException) -> pure (Nothing, Nothing)
                      _ -> pure (Nothing, Nothing)
            maybe (ioError (userError "inventory gcloud token refresh failed or changed identity; restart the command after checking the selected gcloud credentials")) pure result
          capture args = either (const Nothing) (Just . T.strip) <$> run frozen args
      pure (Right (GcloudSession token endpoint capture))

replace :: [(String, String)] -> [(String, String)] -> [(String, String)]
replace previous values = values <> filter (\(key, _) -> key `notElem` map fst values) previous

parseSnapshot :: T.Text -> UTCTime -> T.Text -> Either T.Text Snapshot
parseSnapshot project now output = do
  value <- either (const invalid) Right (A.eitherDecodeStrict' (TE.encodeUtf8 output))
  (access, expiry, account, auth, universe, selectedProject, endpoint, configuration) <- either (const invalid) Right (parseEither parser value)
  unless (selectedProject == project) (Left "inventory gcloud credential project differs from the selected context")
  unless (valid access && valid account && valid configuration && addUTCTime 60 now < expiry) invalid
  unless (universe == "" || universe == "googleapis.com") (Left "inventory SDK requires the googleapis.com universe")
  unless
    (all (T.null . (\key -> Map.findWithDefault "" key auth)) ["credential_file_override", "access_token_file", "access_token"])
    (Left "inventory SDK does not yet support gcloud credential/token file overrides; set NAGARE_INVENTORY_GCS_TRANSPORT=gcloud")
  when
    (Map.findWithDefault "false" "disable_credentials" auth `notElem` ["", "false", "False"])
    (Left "inventory SDK requires authenticated gcloud credentials")
  let canonical = Map.fromList [(key, Map.findWithDefault "" key auth) | key <- ["impersonate_service_account", "credential_file_override", "access_token_file", "access_token"]]
  pure (Snapshot access expiry account canonical (if T.null endpoint then "https://storage.googleapis.com/storage/v1/" else endpoint) configuration)
  where
    invalid :: Either T.Text a
    invalid = Left "inventory gcloud credential response is missing a valid account, token, or expiry"
    valid value = not (T.null value) && not (T.any (\c -> isControl c || isSpace c) value)
    parser :: A.Value -> Parser (T.Text, UTCTime, T.Text, Map.Map T.Text T.Text, T.Text, T.Text, T.Text, T.Text)
    parser = A.withObject "gcloud helper" $ \o -> do
      credential <- o .: "credential"
      access <- credential .: "access_token"
      expiry <- credential .: "token_expiry"
      configuration <- o .: "configuration"
      configurationName <- configuration .: "active_configuration"
      properties <- configuration .: "properties"
      core <- properties .: "core"
      account <- core .: "account"
      selectedProject <- core .: "project"
      endpoints <- properties .:? "api_endpoint_overrides"
      endpoint <- maybe (pure Nothing) (.:? "storage") endpoints
      universe <- core .:? "universe_domain"
      auth <- properties .:? "auth"
      pure (access, expiry, account, fromMaybe Map.empty auth, fromMaybe "" universe, selectedProject, fromMaybe "" endpoint, configurationName)
