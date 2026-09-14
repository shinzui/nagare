{-# LANGUAGE OverloadedStrings #-}

-- | Safe observation and policy for Google Application Default Credentials.
-- Credential secrets are parsed only as an untyped JSON object and are never
-- retained in the public observation or error types.
module Nagare.Gcp.Adc
  ( AdcEnv (..)
  , AdcError (..)
  , AdcObservation (..)
  , AdcSource (..)
  , adcEnvFromProcess
  , adcEvidenceValue
  , observeAdc
  , parseAdc
  , renderAdcError
  , resolveAdcSource
  , validateAdc
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)

data AdcEnv = AdcEnv
  { googleApplicationCredentials :: !(Maybe FilePath)
  , cloudSdkConfig :: !(Maybe FilePath)
  , homeDirectory :: !(Maybe FilePath)
  }
  deriving stock (Generic, Eq, Show)

data AdcSource
  = AdcEnvironmentFile !FilePath
  | AdcCloudSdkConfigFile !FilePath
  | AdcGcloudDefaultFile !FilePath
  deriving stock (Eq, Show)

data AdcObservation = AdcObservation
  { source :: !AdcSource
  , credentialKind :: !Text
  , principal :: !(Maybe Text)
  , quotaProject :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data AdcError
  = AdcPathUnavailable
  | AdcFileMissing !AdcSource
  | AdcFileUnreadable !AdcSource !Text
  | AdcInvalidJson !AdcSource
  | AdcInvalidShape !AdcSource !Text
  deriving stock (Eq, Show)

adcEnvFromProcess :: IO AdcEnv
adcEnvFromProcess =
  AdcEnv
    <$> lookupEnv "GOOGLE_APPLICATION_CREDENTIALS"
    <*> lookupEnv "CLOUDSDK_CONFIG"
    <*> lookupEnv "HOME"

resolveAdcSource :: AdcEnv -> Either AdcError AdcSource
resolveAdcSource env =
  case nonBlank (env ^. #googleApplicationCredentials) of
    Just path -> Right (AdcEnvironmentFile path)
    Nothing -> case nonBlank (env ^. #cloudSdkConfig) of
      Just root -> Right (AdcCloudSdkConfigFile (root </> adcFileName))
      Nothing -> case nonBlank (env ^. #homeDirectory) of
        Just home -> Right (AdcGcloudDefaultFile (home </> ".config" </> "gcloud" </> adcFileName))
        Nothing -> Left AdcPathUnavailable
  where
    adcFileName = "application_default_credentials.json"
    nonBlank = (>>= \value -> if null value then Nothing else Just value)

observeAdc :: AdcEnv -> IO (Either AdcError AdcObservation)
observeAdc env = case resolveAdcSource env of
  Left err -> pure (Left err)
  Right source -> do
    result <- try (BS.readFile (sourcePath source))
    pure $ case result of
      Left (err :: IOException)
        | isDoesNotExistError err -> Left (AdcFileMissing source)
        | otherwise -> Left (AdcFileUnreadable source (T.pack (show err)))
      Right bytes -> parseAdc source bytes

parseAdc :: AdcSource -> ByteString -> Either AdcError AdcObservation
parseAdc source bytes = do
  root <- case Aeson.eitherDecodeStrict' bytes of
    Left _ -> Left (AdcInvalidJson source)
    Right (Object object) -> Right object
    Right _ -> Left (AdcInvalidShape source "credential root is not an object")
  kind <- requiredText source "type" root
  quota <- optionalText source "quota_project_id" root
  principal <- case kind of
    "service_account" -> optionalText source "client_email" root
    "authorized_user" -> optionalText source "account" root
    _ -> pure Nothing
  Right
    AdcObservation
      { source = source
      , credentialKind = kind
      , principal = principal
      , quotaProject = quota
      }

validateAdc :: Text -> Maybe Text -> Either AdcError AdcObservation -> Either Text [Text]
validateAdc selectedProject gcloudAccount observation = case observation of
  Left err ->
    Left
      ( "refusing to run: Application Default Credentials could not be inspected: "
          <> renderAdcError err
          <> ".\nfix: run 'gcloud auth application-default login', then 'gcloud auth application-default set-quota-project "
          <> selectedProject
          <> "'."
      )
  Right observed -> case observed ^. #quotaProject of
    Just quota
      | quota /= selectedProject ->
          Left
            ( "refusing to run: Application Default Credentials attribute API quota to project '"
                <> quota
                <> "', not the selected context's project '"
                <> selectedProject
                <> "'.\nfix: run 'gcloud auth application-default set-quota-project "
                <> selectedProject
                <> "'."
            )
    _ -> Right (adcWarnings selectedProject gcloudAccount observed)

adcEvidenceValue :: Text -> Maybe Text -> Either AdcError AdcObservation -> Aeson.Value
adcEvidenceValue selectedProject gcloudAccount observation = case observation of
  Left err ->
    Aeson.object
      [ "status" Aeson..= adcErrorStatus err
      , "source" Aeson..= fmap sourceValue (adcErrorSource err)
      , "credentialKind" Aeson..= (Nothing :: Maybe Text)
      , "principal" Aeson..= (Nothing :: Maybe Text)
      , "quotaProject" Aeson..= (Nothing :: Maybe Text)
      , "warnings" Aeson..= ([] :: [Text])
      , "error" Aeson..= renderAdcError err
      ]
  Right observed ->
    Aeson.object
      [ "status" Aeson..= ("found" :: Text)
      , "source" Aeson..= sourceValue (observed ^. #source)
      , "credentialKind" Aeson..= (observed ^. #credentialKind)
      , "principal" Aeson..= (observed ^. #principal)
      , "quotaProject" Aeson..= (observed ^. #quotaProject)
      , "warnings" Aeson..= adcWarnings selectedProject gcloudAccount observed
      , "error" Aeson..= (Nothing :: Maybe Text)
      ]

renderAdcError :: AdcError -> Text
renderAdcError = \case
  AdcPathUnavailable ->
    "no credential path is available because GOOGLE_APPLICATION_CREDENTIALS, CLOUDSDK_CONFIG, and HOME are unset"
  AdcFileMissing source -> "credential file is missing at " <> T.pack (sourcePath source)
  AdcFileUnreadable source err ->
    "credential file at " <> T.pack (sourcePath source) <> " could not be read: " <> err
  AdcInvalidJson source -> "credential file at " <> T.pack (sourcePath source) <> " is not valid JSON"
  AdcInvalidShape source err ->
    "credential file at " <> T.pack (sourcePath source) <> " has an invalid shape: " <> err

adcWarnings :: Text -> Maybe Text -> AdcObservation -> [Text]
adcWarnings selectedProject gcloudAccount observed =
  catMaybes
    [ case observed ^. #quotaProject of
        Nothing ->
          Just
            ( "Application Default Credentials have no quota_project_id; run 'gcloud auth application-default set-quota-project "
                <> selectedProject
                <> "' to pin API quota attribution"
            )
        Just _ -> Nothing
    , case observed ^. #principal of
        Nothing -> Just "Application Default Credentials do not expose a principal; the gcloud account comparison is unavailable"
        Just principal -> case gcloudAccount of
          Just active
            | principal /= active ->
                Just
                  ( "Application Default Credentials principal '"
                      <> principal
                      <> "' differs from gcloud's active account '"
                      <> active
                      <> "'"
                  )
          _ -> Nothing
    ]

requiredText :: AdcSource -> Key -> KeyMap.KeyMap Value -> Either AdcError Text
requiredText source key object = case KeyMap.lookup key object of
  Just (String value)
    | not (T.null (T.strip value)) -> Right (T.strip value)
    | otherwise -> Left (AdcInvalidShape source (AesonKey.toText key <> " is blank"))
  Just _ -> Left (AdcInvalidShape source (AesonKey.toText key <> " is not text"))
  Nothing -> Left (AdcInvalidShape source ("missing " <> AesonKey.toText key))

optionalText :: AdcSource -> Key -> KeyMap.KeyMap Value -> Either AdcError (Maybe Text)
optionalText source key object = case KeyMap.lookup key object of
  Nothing -> Right Nothing
  Just Null -> Right Nothing
  Just (String value)
    | T.null (T.strip value) -> Right Nothing
    | otherwise -> Right (Just (T.strip value))
  Just _ -> Left (AdcInvalidShape source (AesonKey.toText key <> " is not text"))

sourcePath :: AdcSource -> FilePath
sourcePath = \case
  AdcEnvironmentFile path -> path
  AdcCloudSdkConfigFile path -> path
  AdcGcloudDefaultFile path -> path

sourceValue :: AdcSource -> Aeson.Value
sourceValue source =
  Aeson.object
    [ "kind" Aeson..= sourceKind source
    , "path" Aeson..= sourcePath source
    ]

sourceKind :: AdcSource -> Text
sourceKind = \case
  AdcEnvironmentFile _ -> "environment"
  AdcCloudSdkConfigFile _ -> "cloud-sdk-config"
  AdcGcloudDefaultFile _ -> "gcloud-default"

adcErrorSource :: AdcError -> Maybe AdcSource
adcErrorSource = \case
  AdcPathUnavailable -> Nothing
  AdcFileMissing source -> Just source
  AdcFileUnreadable source _ -> Just source
  AdcInvalidJson source -> Just source
  AdcInvalidShape source _ -> Just source

adcErrorStatus :: AdcError -> Text
adcErrorStatus = \case
  AdcPathUnavailable -> "path-unavailable"
  AdcFileMissing _ -> "missing"
  AdcFileUnreadable _ _ -> "unreadable"
  AdcInvalidJson _ -> "invalid-json"
  AdcInvalidShape _ _ -> "invalid-shape"
