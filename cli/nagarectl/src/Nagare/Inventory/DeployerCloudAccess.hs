-- | A delegated deployer's cloud principal (EP-248 D6).
--
-- On a cloud context each accepted, active delegation gets a service
-- account, an Artifact Registry repository it writes and a prefix-scoped
-- grant on the inventory bucket, declared by @infra/pulumi@'s
-- @NagareDelegatedDeployer@ from the derived Pulumi config key
-- @nagare:delegatedDeployers@. That key is computed here from the accepted
-- head; it is never hand-edited or copied into the context file.
--
-- @delegation credentials@ issues the account a key with the operator's
-- gcloud session. Every gcloud call here first passes the project assertion
-- every cloud-mutating path uses (ADR 9); a refusal stops before any call.
-- The key is never in Pulumi state or a review (ADR 13); it lives only in
-- the private bundle, beside a gcloud configuration whose project is the
-- context's.
module Nagare.Inventory.DeployerCloudAccess
  ( deployerCloudAccountId
  , deployerCloudAccountEmail
  , delegatedRepositoryId
  , cloudDelegatedDeployers
  , delegatedDeployerConfigKeys
  , CloudKey (..)
  , CloudKeyOps (..)
  , Gcloud
  , gcloudKeyOps
  , retireCloudKeysExcept
  , cloudBundleFiles
  , gcloudConfigPathIn
  , cloudKeyPathIn
  )
where

import Control.Concurrent.MVar (modifyMVar, newMVar)
import Control.Exception (IOException, try)
import Control.Monad (forM)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), eitherDecodeStrict, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isDigit)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (nub, sortOn)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Init (adminApiInventoryKeys)
import Nagare.Inventory.DeployerDelegation (DelegationState (..), DeployerDelegation, acceptedDelegations)
import Nagare.Resource.Inventory (ScopeDeclaration, scopeId)
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Target (InventoryStoreKind (InventoryStoreGcs), TargetProfile, defaultGcsInventoryStoreUrl, effectiveInventoryStore)
import System.Directory (removeDirectoryRecursive)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (createTempDirectory, getCanonicalTemporaryDirectory)
import System.Posix.Files (setFileMode)

-- | The deployer's service account ID: @nagare-deployer-NAME@ when that fits
-- the 30 characters an account ID may have, otherwise a prefix of the name
-- and a digest of all of it. @infra/pulumi@ takes the ID from the config, so
-- this is the one place it is derived.
deployerCloudAccountId :: Text -> Text
deployerCloudAccountId deployer
  | T.length full <= 30 = full
  | otherwise = "nagare-deployer-" <> T.dropWhileEnd (== '-') (T.take 7 deployer) <> "-" <> T.take 6 (T.pack (show digest))
  where
    full = "nagare-deployer-" <> deployer
    digest = hash (TE.encodeUtf8 deployer) :: Digest SHA256

deployerCloudAccountEmail :: Text -> Text -> Text
deployerCloudAccountEmail project deployer = deployerCloudAccountId deployer <> "@" <> project <> ".iam.gserviceaccount.com"

-- | The delegation's Artifact Registry repository ID. The image repository
-- must be @REGION-docker.pkg.dev/PROJECT/REPO[/...]@ in the context's region
-- and project, and @REPO@ is never the platform's shared repository, so the
-- deployer is never its writer. @infra/pulumi@ refuses the same.
delegatedRepositoryId :: TargetProfile -> DeployerDelegation -> Either Text Text
delegatedRepositoryId profile delegation = case T.splitOn "/" repository of
  host : project : repo : rest
    | host == profile ^. #region <> "-docker.pkg.dev"
    , project == profile ^. #project
    , not (any T.null (repo : rest)) ->
        if not (validRepositoryId repo)
          then refuse (repo <> " is not an Artifact Registry repository ID")
          else
            if repo == profile ^. #artifactRegistryId
              then refuse ("it is the platform's shared repository " <> repo)
              else Right repo
  _ -> refuse ("it is not under " <> profile ^. #region <> "-docker.pkg.dev/" <> profile ^. #project <> "/")
  where
    repository = delegation ^. #imageRepository
    refuse reason = Left ("delegation " <> delegation ^. #name <> ": image repository " <> repository <> " cannot have a cloud principal: " <> reason)
    validRepositoryId repo =
      T.length repo <= 63
        && maybe False (isAsciiLower . fst) (T.uncons repo)
        && T.all (\c -> isAsciiLower c || isDigit c || c == '-') repo
        && not ("-" `T.isSuffixOf` repo)

-- | The accepted, active delegations among a composition's scopes.
-- | Every accepted delegation, revoked ones included: a revoked delegation
-- keeps its cloud principal with the account disabled (D7), so revoking
-- changes resources in place and retires nothing.
cloudDelegatedDeployers :: [ScopeDeclaration] -> [DeployerDelegation]
cloudDelegatedDeployers scopes =
  Map.elems (acceptedDelegations (Map.fromList [(scopeId scope, scope) | scope <- scopes]))

-- | The derived Pulumi config for the delegations' cloud principals: none
-- without a delegation, so an existing stack previews unchanged; otherwise
-- @nagare:delegatedDeployers@ and the inventory's bucket and prefix, which
-- the deployers' store grant names.
delegatedDeployerConfigKeys :: Text -> TargetProfile -> [DeployerDelegation] -> Either Text [(Text, Text)]
delegatedDeployerConfigKeys context profile delegations = case sortOn (^. #name) delegations of
  [] -> Right []
  sorted -> do
    unless
      (effectiveInventoryStore profile == InventoryStoreGcs)
      (Left "a delegated deployer on a cloud context needs the context's inventory in GCS")
    repositories <- traverse (delegatedRepositoryId profile) sorted
    unless (length (nub repositories) == length repositories) (Left "two delegations name the same Artifact Registry repository")
    let accounts = map (deployerCloudAccountId . (^. #name)) sorted
    unless (length (nub accounts) == length accounts) (Left "two delegations derive the same service account ID")
    entries <-
      canonicalValue
        ( toJSON
            [ object
                ( ["name" .= (delegation ^. #name), "accountId" .= account, "imageRepository" .= (delegation ^. #imageRepository)]
                    <> ["disabled" .= True | delegation ^. #state == DelegationRevoked]
                )
            | (delegation, account) <- zip sorted accounts
            ]
        )
    let url = if T.null (profile ^. #inventoryStoreUrl) then defaultGcsInventoryStoreUrl context profile else profile ^. #inventoryStoreUrl
    pure (("nagare:delegatedDeployers", TE.decodeUtf8 entries) : adminApiInventoryKeys url)

-- ---------------------------------------------------------------------------
-- Key issuance

-- | A new user-managed key: its ID and the key file gcloud wrote.
data CloudKey = CloudKey
  { keyId :: !Text
  , keyFile :: !ByteString
  }
  deriving stock (Generic)

-- | The deployer account's key administration and the facts its bundle
-- needs, all through the operator's session.
data CloudKeyOps = CloudKeyOps
  { project :: !Text
  , account :: !Text
  -- ^ The deployer's service account email.
  , projectNumber :: !(IO (Either Text Text))
  -- ^ The project's number, so the bundle's store needs no project read.
  , createKey :: !(IO (Either Text CloudKey))
  , listKeys :: !(IO (Either Text [Text]))
  -- ^ The account's user-managed key IDs.
  , deleteKey :: !(Text -> IO (Either Text ()))
  }
  deriving stock (Generic)

-- | A gcloud request through the operator's session: its arguments.
type Gcloud = [String] -> IO (Either Text (ExitCode, String, String))

-- | Key administration over @gcloud iam service-accounts keys@. The project
-- assertion runs once, before the first gcloud call; its refusal answers
-- every call without running gcloud.
gcloudKeyOps :: IO (Either Text ()) -> Gcloud -> Text -> Text -> IO CloudKeyOps
gcloudKeyOps assertProject run project deployer = do
  verdict <- newMVar Nothing
  let account = deployerCloudAccountEmail project deployer
      asserted = modifyMVar verdict $ \case
        Just known -> pure (Just known, known)
        Nothing -> (\answer -> (Just answer, answer)) <$> assertProject
      gcloud arguments = asserted >>= either (pure . Left) (const (run (arguments <> ["--project", T.unpack project])))
      keys arguments = ["iam", "service-accounts", "keys"] <> arguments <> ["--iam-account", T.unpack account]
  pure
    CloudKeyOps
      { project = project
      , account = account
      , projectNumber = do
          answer <- gcloud ["projects", "describe", T.unpack project, "--format=value(projectNumber)"]
          pure $ do
            output <- outputOf "the project's number" answer
            let number = T.strip output
            unless (not (T.null number) && T.all isDigit number) (Left "the project's number is not numeric")
            pure number
      , createKey = do
          scratch <- try (getCanonicalTemporaryDirectory >>= \root -> createTempDirectory root "nagare-deployer-key") :: IO (Either IOException FilePath)
          case scratch of
            Left err -> pure (Left ("cannot create a private directory for the key: " <> T.pack (show err)))
            Right directory -> do
              let path = directory </> "key.json"
              result <- try $ do
                setFileMode directory 0o700
                created <- gcloud (keys ["create", path])
                case outputOf ("a key for " <> account) created of
                  Left reason -> pure (Left reason)
                  Right _ -> do
                    bytes <- BS.readFile path
                    pure (CloudKey <$> keyIdOf bytes <*> pure bytes)
              _ <- try (removeDirectoryRecursive directory) :: IO (Either IOException ())
              pure (either (\(err :: IOException) -> Left ("cannot read the new key: " <> T.pack (show err))) id result)
      , listKeys = do
          answer <- gcloud (keys ["list", "--managed-by=user", "--format=json"])
          pure (outputOf ("the keys of " <> account) answer >>= keyIdsOf)
      , deleteKey = \key -> do
          answer <- gcloud (keys ["delete", T.unpack key, "--quiet"])
          pure (() <$ outputOf ("deleting key " <> key) answer)
      }
  where
    keyIdOf bytes = case eitherDecodeStrict bytes of
      Right (Object o) | Just (String key) <- KM.lookup "private_key_id" o, not (T.null key) -> Right key
      _ -> Left "the new key file has no private_key_id"
    keyIdsOf output = case eitherDecodeStrict (TE.encodeUtf8 output) of
      Right (Array listed) -> forM (toList listed) $ \case
        Object o | Just (String name) <- KM.lookup "name" o, Just key <- lastSegment name -> Right key
        _ -> Left "a listed key has no name"
      _ -> Left "the key list is not JSON"
    lastSegment name = case T.splitOn "/" name of
      segments | key <- last segments, not (T.null key) -> Just key
      _ -> Nothing

-- | Delete every user-managed key of the account but the new one, answering
-- the deleted IDs.
retireCloudKeysExcept :: CloudKeyOps -> Text -> IO (Either Text [Text])
retireCloudKeysExcept ops keep = do
  listed <- ops ^. #listKeys
  case listed of
    Left reason -> pure (Left reason)
    Right keys -> do
      let earlier = filter (/= keep) keys
      results <- forM earlier $ \key -> (key <$) <$> (ops ^. #deleteKey) key
      pure (sequence results)

-- | The bundle's gcloud directory, as @HOME=DIR@ gcloud finds it.
gcloudConfigPathIn :: FilePath
gcloudConfigPathIn = ".config/gcloud"

cloudKeyPathIn :: FilePath
cloudKeyPathIn = gcloudConfigPathIn </> "deployer-key.json"

-- | The key, a gcloud configuration whose project is the context's, and the
-- project's number where the store's ownership check remembers it, so the
-- deployer needs no project-level read. The key is selected by
-- @CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE@, which a deployer context sets to
-- the bundle's own file: the bundle has no fixed absolute path.
cloudBundleFiles :: CloudKeyOps -> Text -> CloudKey -> [(FilePath, ByteString)]
cloudBundleFiles ops number key =
  [ (cloudKeyPathIn, key ^. #keyFile)
  , (gcloudConfigPathIn </> "active_config", "default")
  , (gcloudConfigPathIn </> "configurations" </> "config_default", TE.encodeUtf8 (T.unlines ["[core]", "project = " <> ops ^. #project, "account = " <> ops ^. #account]))
  , (".cache/nagare/project-numbers" </> T.unpack (ops ^. #project), TE.encodeUtf8 number)
  ]

outputOf :: Text -> Either Text (ExitCode, String, String) -> Either Text Text
outputOf what = \case
  Right (ExitSuccess, output, _) -> Right (T.pack output)
  Right (_, _, err) -> Left (what <> " failed: " <> T.strip (T.pack err))
  Left reason -> Left reason
