-- | Bind context-owned encrypted observability Secrets to private native
-- review members. Plaintext never enters the public review directory.
module Nagare.Inventory.Components.ObservabilitySecrets
  ( compileObservabilitySecrets
  , loadObservabilitySecretObjects
  , loadObservabilitySecretObjectsFromDirectory
  , readAlertmanagerEnabled
  ) where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
import Nagare.Inventory.Components.Upstream
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (parseKubernetesManifest)
import Nagare.Resource.Types
import Nagare.Target (nagareConfigDir)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)

readAlertmanagerEnabled :: FilePath -> ContentDigest -> IO (Either Text Bool)
readAlertmanagerEnabled path expected = do
  loaded <- try (BS.readFile path) :: IO (Either IOException ByteString)
  pure $ do
    bytes <- first (const "observability values are unavailable") loaded
    unless (contentDigest bytes == expected)
      (Left "observability values differ from their pinned digest")
    value <- first (const "observability values are malformed") (Yaml.decodeEither' bytes)
    root <- objectFields value
    alertmanager <- maybe (Left "observability values lack alertmanager policy") objectFields
      (KM.lookup "alertmanager" root)
    case KM.lookup "enabled" alertmanager of
      Just (Bool enabled) -> Right enabled
      _ -> Left "observability alertmanager.enabled is missing or malformed"

loadObservabilitySecretObjects
  :: FilePath -> Text -> Bool
  -> IO (Either Text [(SourceLocation, Value)])
loadObservabilitySecretObjects root context alertmanagerEnabled = do
  directory <- resolveDirectory root context
  loadObservabilitySecretObjectsFromDirectory "sops" directory alertmanagerEnabled

loadObservabilitySecretObjectsFromDirectory
  :: FilePath -> FilePath -> Bool
  -> IO (Either Text [(SourceLocation, Value)])
loadObservabilitySecretObjectsFromDirectory executable directory alertmanagerEnabled = do
  grafana <- decryptSecret executable directory "grafana-admin.yaml" True
  alertmanager <- decryptSecret executable directory "alertmanager-config.yaml" alertmanagerEnabled
  pure ((<>) <$> grafana <*> alertmanager)

compileObservabilitySecrets
  :: FoundationInput -> [(SourceLocation, Value)]
  -> IO (Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString), [ResourceId]))
compileObservabilitySecrets foundation objects = case traverse validate objects of
  Left reason -> pure (Left (invalid reason :| []))
  Right names -> do
    let input = UpstreamInput
          { upstreamOwner = owner
          , upstreamCluster = foundationCluster foundation
          , upstreamKey = known (mkLogicalKey "observability-secrets")
          , upstreamRoot = ""
          , upstreamFiles = []
          , upstreamNamespaces = Map.singleton (known (mkName "monitoring")) monitoringNamespace
          , upstreamTransferred = Set.empty
          , upstreamConfigMapData = Map.empty
          , upstreamImageOverrides = Map.empty
          , upstreamGenerated = objects
          , upstreamAfter = Map.empty
          , upstreamExternalAfter = Map.empty
          , upstreamOrderDeployments = False
          }
    result <- compileUpstream input
    pure $ do
      unless ("grafana-admin" `elem` names)
        (Left (invalid "Grafana admin Secret is missing" :| []))
      unless (length names == Set.size (Set.fromList names))
        (Left (invalid "observability Secret names must be unique" :| []))
      (bundle, native) <- result
      scope <- mkScopeDeclaration owner [bundle]
      pure (scope, native, Map.keys native)
  where
    owner = known (mkScopeId Platform "observability-secrets")
    known = either (error . T.unpack) id
    invalid = inventoryError "invalid-observability-secret"
    monitoringNamespace = mintResourceId (foundationOwner foundation)
      (known (mkLogicalKey "monitoring")) (known (mkName "namespace"))
    validate (_, value) = do
      root <- objectFields value
      unless (KM.lookup "kind" root == Just (String "Secret"))
        (Left "context-owned observability input is not a Kubernetes Secret")
      metadata <- maybe (Left "observability Secret has no metadata") objectFields
        (KM.lookup "metadata" root)
      name <- textField "name" metadata
      namespace <- textField "namespace" metadata
      unless (namespace == "monitoring" && name `elem` ["grafana-admin", "alertmanager-config"])
        (Left "observability Secret has an unexpected name or namespace")
      let keys = concat [KM.keys fields | field <- ["data", "stringData"],
            Just (Object fields) <- [KM.lookup field root]]
      when (name == "grafana-admin" &&
          not (all (`elem` keys) [Key.fromText "admin-user", Key.fromText "admin-password"]))
        (Left "Grafana admin Secret lacks required keys")
      pure name

resolveDirectory :: FilePath -> Text -> IO FilePath
resolveDirectory root context = do
  override <- lookupEnv "NAGARE_CLUSTER_SECRETS_DIR"
  config <- nagareConfigDir
  let contextOwned = config </> "cluster-secrets" </> T.unpack context
      sourceCompat = root </> "cluster/secrets"
  case override of
    Just path | not (null path) -> pure path
    _ -> do
      contextExists <- doesDirectoryExist contextOwned
      sourceExists <- doesDirectoryExist sourceCompat
      pure (if contextExists then contextOwned else if sourceExists then sourceCompat else contextOwned)

decryptSecret :: FilePath -> FilePath -> FilePath -> Bool -> IO (Either Text [(SourceLocation, Value)])
decryptSecret executable directory filename required = do
  let path = directory </> filename
  exists <- doesFileExist path
  if not exists then pure (if required
      then Left ("required encrypted observability Secret is missing: " <> T.pack filename)
      else Right [])
    else do
      environment <- getEnvironment
      age <- lookupEnv "SOPS_AGE_KEY_FILE"
      configured <- case age of
        Just value | not (null value) -> pure environment
        _ -> do
          config <- nagareConfigDir
          let conventional = config </> ".." </> "sops/age/keys.txt"
          found <- doesFileExist conventional
          pure (if found then ("SOPS_AGE_KEY_FILE", conventional) : environment else environment)
      decrypted <- try (readCreateProcessWithExitCode
        (proc executable ["-d", path]) {env = Just configured} "")
        :: IO (Either IOException (ExitCode, String, String))
      pure $ do
        (code, plaintext, _) <- first (const "could not run sops for observability Secret") decrypted
        unless (code == ExitSuccess)
          (Left ("could not decrypt observability Secret: " <> T.pack filename))
        parsed <- first (const "decrypted observability Secret is malformed")
          (parseKubernetesManifest (SourceLocation (T.pack filename) "encrypted-observability-secret")
            (TE.encodeUtf8 (T.pack plaintext)))
        case parsed of
          [one] -> Right [one]
          _ -> Left "decrypted observability input must contain exactly one Secret"

objectFields :: Value -> Either Text (KM.KeyMap Value)
objectFields (Object fields) = Right fields
objectFields _ = Left "observability input is not an object"

textField :: Key.Key -> KM.KeyMap Value -> Either Text Text
textField key fields = case KM.lookup key fields of
  Just (String value) -> Right value
  _ -> Left "observability input lacks a required text field"
