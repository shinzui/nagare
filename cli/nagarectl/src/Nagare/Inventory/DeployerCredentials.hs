-- | @deployer credentials@ (EP-248 D4, D7, D10): issue a delegated deployer
-- the private directory it deploys with, and retire every credential issued
-- before it. Running it again is rotation.
--
-- Nothing secret is reviewed. The reviewed delegation scope holds the
-- identities and their authority (Kubernetes ServiceAccounts and Roles, the
-- object store user and policy); this command issues handles to them:
-- ServiceAccount tokens bound to a per-issue handle Secret, so deleting the
-- handle refuses the token at once, and object store keys. New handles are
-- proved before the bundle is written, and earlier ones are retired only
-- after it is written, so a failed run leaves the previous bundle working
-- and a rerun completes it.
module Nagare.Inventory.DeployerCredentials
  ( CredentialRequest (..)
  , CredentialOps (..)
  , StoreKeyOps (..)
  , Kubectl
  , kubectlStoreKeyOps
  , randomHexIO
  , issueCredentials
  , refuseBundleDirectory
  , bundleContextText
  , renderKubeconfig
  , contextFilePathIn
  , kubeconfigPathIn
  , builderKubeconfigPathIn
  , storeCredentialsPathIn
  , handleLabel
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteArray.Encoding (Base (Base16, Base64), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Access.Resolve (backendConfigMapNamespace)
import Nagare.Contract.Delegation (DeployerCredentials (..))
import Nagare.Contract.Schema (ContractVersion (..), DocumentName (..), Nullable (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.DeployerAccess (builderAccountName, deployerAccountName)
import Nagare.Inventory.DeployerStoreAccess (StoreAccess, addKeyScript, keyPodOverrides, retireKeysScript)
import Nagare.Resource.Wire (canonicalValue)
import System.Directory (createDirectory, doesDirectoryExist, doesPathExist, listDirectory, makeAbsolute, pathIsSymbolicLink, removeDirectoryRecursive, renameDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Posix.Files (setFileMode)

-- | A kubectl request through the operator's guarded session: arguments and
-- standard input.
type Kubectl = [String] -> String -> IO (Either Text (ExitCode, String, String))

data CredentialRequest = CredentialRequest
  { deployer :: !Text
  , context :: !Text
  , out :: !FilePath
  , duration :: !Text
  -- ^ A token lifetime kubectl accepts, such as @720h@.
  , operatorContext :: !Text
  -- ^ The operator's context file, which the bundle copies with
  -- @NAGARE_DEPLOYER@ set.
  , buildNamespace :: !(Maybe Text)
  , issue :: !Text
  -- ^ A fresh lowercase identifier naming this issue's handles.
  }
  deriving stock (Eq, Show, Generic)

-- | The local object store's key administration (D10), or none on a
-- context without one.
data StoreKeyOps = StoreKeyOps
  { addKey :: !(Text -> Text -> IO (Either Text ()))
  -- ^ Add a key to the deployer's user and prove it lists the prefix.
  , retireKeysExcept :: !(Text -> IO (Either Text [Text]))
  -- ^ Remove every other key of the user, answering the removed ids.
  }
  deriving stock (Generic)

data CredentialOps = CredentialOps
  { kubectl :: !Kubectl
  , storeKeys :: !(Maybe StoreKeyOps)
  , randomHex :: !(Int -> IO Text)
  }
  deriving stock (Generic)

handleLabel :: Text
handleLabel = "nagare.dev/deployer-credential"

contextFilePathIn, kubeconfigPathIn, storeCredentialsPathIn :: Text -> FilePath
contextFilePathIn context = ".config/nagare/contexts" </> T.unpack context <> ".env"
kubeconfigPathIn context = ".config/nagare/kubeconfigs" </> T.unpack context <> ".yaml"
storeCredentialsPathIn context = ".config/nagare/credentials" </> T.unpack context <> "-s3.json"

builderKubeconfigPathIn :: FilePath
builderKubeconfigPathIn = "builder/kubeconfig.yaml"

-- | The bundle directory must be new or empty, not a symbolic link, and not
-- inside a Git repository (operator material never enters one, ADR 13).
refuseBundleDirectory :: FilePath -> IO (Either Text FilePath)
refuseBundleDirectory requested = do
  absolute <- makeAbsolute requested
  linked <- pathIsSymbolicLink' absolute
  exists <- doesPathExist absolute
  directory <- doesDirectoryExist absolute
  entries <- if directory then listDirectory absolute else pure []
  repository <- insideRepository (takeDirectory absolute)
  pure $ case () of
    _
      | linked -> Left ("refusing the bundle directory " <> T.pack absolute <> ": it is a symbolic link")
      | exists && not directory -> Left ("refusing the bundle directory " <> T.pack absolute <> ": it is not a directory")
      | not (null entries) -> Left ("refusing the bundle directory " <> T.pack absolute <> ": it is not empty")
      | Just root <- repository -> Left ("refusing the bundle directory " <> T.pack absolute <> ": it is inside the Git repository " <> T.pack root <> "; deployer credentials are operator material (ADR 13)")
      | otherwise -> Right absolute
  where
    pathIsSymbolicLink' path = either (const False) id <$> (try (pathIsSymbolicLink path) :: IO (Either IOException Bool))
    insideRepository path = do
      found <- doesPathExist (path </> ".git")
      let parent = takeDirectory path
      if found then pure (Just path) else if parent == path then pure Nothing else insideRepository parent

-- | The operator's context with the deployer named and any operator name
-- dropped. A context file holds no secret.
bundleContextText :: Text -> Text -> Text
bundleContextText deployer contents =
  T.unlines
    ( filter (not . names) (T.lines contents)
        <> ["export NAGARE_DEPLOYER=" <> deployer]
    )
  where
    names line = any (`T.isPrefixOf` T.stripStart line) ["export NAGARE_DEPLOYER=", "NAGARE_DEPLOYER=", "export NAGARE_OPERATOR=", "NAGARE_OPERATOR="]

-- | An in-cluster kubeconfig whose one user is a bound token. Its context is
-- named after the Nagare context, as nagarectl selects it.
renderKubeconfig :: Text -> Text -> Text -> Text -> Either Text ByteString
renderKubeconfig context user caData token =
  canonicalValue
    ( object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("Config" :: Text)
        , "clusters" .= [object ["name" .= context, "cluster" .= object ["server" .= ("https://kubernetes.default.svc" :: Text), "certificate-authority-data" .= caData]]]
        , "users" .= [object ["name" .= user, "user" .= object ["token" .= token]]]
        , "contexts" .= [object ["name" .= context, "context" .= object ["cluster" .= context, "user" .= user]]]
        , "current-context" .= context
        ]
    )

-- | Issue the bundle, then retire earlier credentials.
issueCredentials :: CredentialOps -> CredentialRequest -> IO (Either Text DeployerCredentials)
issueCredentials ops request = runExceptT $ do
  home <- ExceptT (refuseBundleDirectory (request ^. #out))
  caData <- ExceptT (rootCertificate ops)
  let system = backendConfigMapNamespace
      deployerAccount = deployerAccountName (request ^. #deployer)
      builderAccount = builderAccountName (request ^. #deployer)
      handleName account = account <> "-" <> request ^. #issue
  (token, expiry) <- ExceptT (boundToken ops request system deployerAccount (handleName deployerAccount))
  builder <- forM (request ^. #buildNamespace) $ \ns -> ExceptT (boundToken ops request ns builderAccount (handleName builderAccount))
  storeKey <- forM (ops ^. #storeKeys) $ \keys -> do
    key <- ("NGR" <>) . T.toUpper <$> liftIO ((ops ^. #randomHex) 8)
    secret <- liftIO ((ops ^. #randomHex) 20)
    ExceptT ((keys ^. #addKey) key secret)
    pure (key, secret)
  deployerConfig <- except (renderKubeconfig (request ^. #context) deployerAccount caData token)
  builderConfig <- forM builder $ \(builderToken, _) -> except (renderKubeconfig (request ^. #context) builderAccount caData builderToken)
  storeFile <- forM storeKey $ \(key, secret) -> except (canonicalValue (object ["accessKeyId" .= key, "secretAccessKey" .= secret]))
  let files =
        [ (contextFilePathIn (request ^. #context), TE.encodeUtf8 (bundleContextText (request ^. #deployer) (request ^. #operatorContext)))
        , (kubeconfigPathIn (request ^. #context), deployerConfig)
        ]
          <> [(builderKubeconfigPathIn, bytes) | Just bytes <- [builderConfig]]
          <> [(storeCredentialsPathIn (request ^. #context), bytes) | Just bytes <- [storeFile]]
  ExceptT (writeBundle home files)
  -- Only now, with the new bundle on disk, retire what was issued before.
  retiredHandles <- ExceptT (retireHandles ops system deployerAccount (handleName deployerAccount))
  retiredBuilders <- case request ^. #buildNamespace of
    Just ns -> ExceptT (retireHandles ops ns builderAccount (handleName builderAccount))
    Nothing -> pure []
  retiredKeys <- case (ops ^. #storeKeys, storeKey) of
    (Just keys, Just (key, _)) -> ExceptT ((keys ^. #retireKeysExcept) key)
    _ -> pure []
  pure
    DeployerCredentials
      { contractVersion = ContractVersion1
      , document = DocumentName
      , deployer = request ^. #deployer
      , context = request ^. #context
      , home = T.pack home
      , contextFile = T.pack (contextFilePathIn (request ^. #context))
      , kubeconfig = T.pack (kubeconfigPathIn (request ^. #context))
      , tokenExpiresAt = expiry
      , builderKubeconfig = Nullable (T.pack builderKubeconfigPathIn <$ builder)
      , builderTokenExpiresAt = Nullable (snd <$> builder)
      , storeCredentials = Nullable (T.pack (storeCredentialsPathIn (request ^. #context)) <$ storeKey)
      , storeKeyId = Nullable (fst <$> storeKey)
      , retired = sort (retiredHandles <> retiredBuilders <> map ("store-key/" <>) retiredKeys)
      }

-- | Key administration through one-shot Pods of the store's client image in
-- @nagare-system@. Keys travel on standard input, never in a Pod's
-- specification, arguments or output.
kubectlStoreKeyOps :: Kubectl -> Text -> StoreAccess -> Text -> StoreKeyOps
kubectlStoreKeyOps run deployer access issue =
  StoreKeyOps
    { addKey = \key secret -> do
        answer <- runPod "add" (addKeyScript deployer access) (key <> "\n" <> secret <> "\n")
        pure (answer >>= \output -> if "verified" `elem` T.lines output then Right () else Left "the new object store key did not list the inventory prefix")
    , retireKeysExcept = \keep -> do
        answer <- runPod "retire" (retireKeysScript deployer access) (keep <> "\n")
        pure $ do
          output <- answer
          unless ("done" `elem` T.lines output) (Left "retiring earlier object store keys did not finish")
          pure [key | line <- T.lines output, Just key <- [T.stripPrefix "retired " line]]
    }
  where
    runPod step script input = do
      let pod = "nagare-keys-" <> issue <> "-" <> step
      case canonicalValue (keyPodOverrides pod access script) of
        Left reason -> pure (Left reason)
        Right overrides -> do
          answer <-
            run
              ["-n", T.unpack backendConfigMapNamespace, "run", T.unpack pod, "--image", T.unpack (access ^. #clientImage), "--restart=Never", "--rm", "-i", "--quiet", "--pod-running-timeout=2m", "--overrides", BC.unpack overrides]
              (T.unpack input)
          pure $ case answer of
            Right (ExitSuccess, output, _) -> Right (T.pack output)
            other -> Left ("the object store key Pod " <> pod <> " failed: " <> failure other)

-- | The cluster CA every Pod trusts, from the root CA ConfigMap.
rootCertificate :: CredentialOps -> IO (Either Text Text)
rootCertificate ops = do
  answer <- (ops ^. #kubectl) ["-n", T.unpack backendConfigMapNamespace, "get", "configmap", "kube-root-ca.crt", "-o", "json"] ""
  pure $ do
    value <- jsonOutput "the cluster's root CA" answer
    case value of
      Object root
        | Just (Object fields) <- KM.lookup "data" root
        , Just (String pem) <- KM.lookup "ca.crt" fields ->
            Right (base64Text (TE.encodeUtf8 pem))
      _ -> Left "the cluster's root CA ConfigMap has no ca.crt"

-- | Create this issue's handle Secret, then a token bound to it.
boundToken :: CredentialOps -> CredentialRequest -> Text -> Text -> Text -> IO (Either Text (Text, Text))
boundToken ops request ns account handle = do
  manifest <-
    pure
      ( canonicalValue
          ( object
              [ "apiVersion" .= ("v1" :: Text)
              , "kind" .= ("Secret" :: Text)
              , "type" .= ("nagare.dev/deployer-credential" :: Text)
              , "metadata" .= object ["name" .= handle, "namespace" .= ns, "labels" .= object [Key.fromText handleLabel .= account, "app.kubernetes.io/part-of" .= ("nagare" :: Text)]]
              ]
          )
      )
  case manifest of
    Left reason -> pure (Left reason)
    Right bytes -> do
      created <- (ops ^. #kubectl) ["-n", T.unpack ns, "create", "-f", "-"] (BC.unpack bytes)
      case succeeded ("the credential handle " <> handle) created of
        Left reason -> pure (Left reason)
        Right () -> do
          answer <-
            (ops ^. #kubectl)
              ["-n", T.unpack ns, "create", "token", T.unpack account, "--duration", T.unpack (request ^. #duration), "--bound-object-kind", "Secret", "--bound-object-name", T.unpack handle, "-o", "json"]
              ""
          pure $ do
            value <- jsonOutput ("a token for " <> account) answer
            case value of
              Object root
                | Just (Object status) <- KM.lookup "status" root
                , Just (String token) <- KM.lookup "token" status
                , Just (String expiry) <- KM.lookup "expirationTimestamp" status ->
                    Right (token, expiry)
              _ -> Left ("the token request for " <> account <> " answered no token")

-- | Delete every handle of the account but this issue's, so every token
-- bound to them is refused.
retireHandles :: CredentialOps -> Text -> Text -> Text -> IO (Either Text [Text])
retireHandles ops ns account keep = do
  listed <- (ops ^. #kubectl) ["-n", T.unpack ns, "get", "secret", "-l", T.unpack (handleLabel <> "=" <> account), "-o", "jsonpath={.items[*].metadata.name}"] ""
  case listed of
    Right (ExitSuccess, names, _) -> do
      let earlier = [name | name <- T.words (T.pack names), name /= keep]
      results <- forM earlier $ \name -> do
        deleted <- (ops ^. #kubectl) ["-n", T.unpack ns, "delete", "secret", T.unpack name, "--wait=true"] ""
        pure (ns <> "/" <> name <$ succeeded ("retiring " <> name) deleted)
      pure (sequence results)
    other -> pure (Left ("cannot list the credential handles of " <> account <> ": " <> failure other))

writeBundle :: FilePath -> [(FilePath, ByteString)] -> IO (Either Text ())
writeBundle home files = do
  let staging = takeDirectory home </> ("." <> takeFileName home <> ".staging")
  result <- try $ do
    stale <- doesPathExist staging
    when stale (removeDirectoryRecursive staging)
    createDirectory staging
    setFileMode staging 0o700
    forM_ files $ \(relative, bytes) -> do
      let path = staging </> relative
      createPrivateParents staging (takeDirectory relative)
      BS.writeFile path bytes
      setFileMode path 0o600
    emptyTarget <- doesDirectoryExist home
    when emptyTarget (removeDirectoryRecursive home)
    renameDirectory staging home
  pure (either (\(err :: IOException) -> Left ("cannot write the bundle: " <> T.pack (show err))) Right result)
  where
    createPrivateParents root relative =
      forM_ (scanl1 (</>) (splitPath' relative)) $ \partial -> do
        let directory = root </> partial
        exists <- doesDirectoryExist directory
        unless exists (createDirectory directory >> setFileMode directory 0o700)
    splitPath' = filter (not . null) . map T.unpack . T.splitOn "/" . T.pack

jsonOutput :: Text -> Either Text (ExitCode, String, String) -> Either Text Value
jsonOutput what = \case
  Right (ExitSuccess, output, _) -> first (const (what <> " is not JSON")) (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)))
  other -> Left ("cannot read " <> what <> ": " <> failure other)

succeeded :: Text -> Either Text (ExitCode, String, String) -> Either Text ()
succeeded what = \case
  Right (ExitSuccess, _, _) -> Right ()
  other -> Left (what <> " failed: " <> failure other)

failure :: Either Text (ExitCode, String, String) -> Text
failure = \case
  Left reason -> reason
  Right (_, _, err) -> T.strip (T.pack err)

-- | @n@ random bytes as lowercase hexadecimal.
randomHexIO :: Int -> IO Text
randomHexIO n = TE.decodeUtf8 . convertToBase Base16 <$> (getRandomBytes n :: IO ByteString)

base64Text :: ByteString -> Text
base64Text = TE.decodeUtf8 . convertToBase Base64
