{-# LANGUAGE OverloadedStrings #-}

-- | Fetch, normalize, validate, and atomically install a context kubeconfig.
module Nagare.Cluster.Kubeconfig
  ( FetchOps (..)
  , KubeconfigIdentity (..)
  , defaultFetchOps
  , fetchKubeconfig
  , kubeconfigPath
  , normalizeKubeconfig
  )
where

import Control.Exception (IOException, try)
import Control.Monad (foldM, unless)
import Data.Aeson (Value (..))
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude
import Nagare.Target (ContextName, TargetProfile (..), contextNameText, nagareConfigDir)
import System.Directory
  ( createDirectoryIfMissing
  , pathIsSymbolicLink
  , removePathForcibly
  , renameFile
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (createTempDirectory)
import System.Posix.Files
  ( fileMode
  , getFileStatus
  , groupWriteMode
  , intersectFileModes
  , otherWriteMode
  , setFileMode
  , unionFileModes
  )
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)

data KubeconfigIdentity = KubeconfigIdentity
  { contextName :: !Text
  , hostName :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Executable paths are explicit so tests can substitute recording fakes.
data FetchOps = FetchOps
  { iapSshExecutable :: !FilePath
  , kubectlExecutable :: !FilePath
  }
  deriving stock (Generic, Eq, Show)

defaultFetchOps :: FilePath -> FetchOps
defaultFetchOps iapSsh = FetchOps iapSsh "kubectl"

kubeconfigPath :: ContextName -> IO FilePath
kubeconfigPath context = do
  configRoot <- nagareConfigDir
  pure (configRoot </> "kubeconfigs" </> T.unpack (contextNameText context) <> ".yaml")

-- | Fetch through the existing project-confined IAP helper, normalize the
-- single-cluster k3s file, validate it with kubectl, and replace the destination
-- only after every step succeeds.
fetchKubeconfig :: FetchOps -> KubeconfigIdentity -> TargetProfile -> FilePath -> IO (Either Text ())
fetchKubeconfig ops identity profile destination = do
  prepared <- prepareDestination destination
  case prepared of
    Left err -> pure (Left err)
    Right parent -> do
      temporaryDirectoryResult <- try (createTempDirectory parent (takeFileName destination <> ".tmp"))
      case temporaryDirectoryResult of
        Left (err :: IOException) -> pure (Left (ioFailure "create a kubeconfig staging directory" err))
        Right temporaryDirectory -> do
          let temporary = temporaryDirectory </> "kubeconfig"
              cleanup = removePathForcibly temporaryDirectory
          result <- try (fetchAndNormalize temporaryDirectory temporary) :: IO (Either IOException (Either Text ()))
          case result of
            Left err -> cleanup >> pure (Left (ioFailure "install the kubeconfig" err))
            Right (Left err) -> cleanup >> pure (Left err)
            Right (Right ()) -> do
              renamed <- try (renameFile temporary destination)
              case renamed of
                Left (err :: IOException) -> cleanup >> pure (Left (ioFailure "replace the kubeconfig" err))
                Right () -> cleanup >> pure (Right ())
  where
    fetchAndNormalize temporaryDirectory temporary = do
      setFileMode temporaryDirectory 0o700
      received <-
        runCommand
          [("NAGARE_CONTEXT", T.unpack (identity ^. #contextName))]
          (ops ^. #iapSshExecutable)
          [ "recv-file"
          , T.unpack (profile ^. #instanceName)
          , "/etc/rancher/k3s/k3s.yaml"
          , temporary
          ]
      case received of
        Left err -> pure (Left err)
        Right _ -> do
          setFileMode temporary 0o600
          source <- BS.readFile temporary
          case normalizeKubeconfig identity source of
            Left err -> pure (Left err)
            Right normalized -> do
              BS.writeFile temporary normalized
              setFileMode temporary 0o600
              normalizedByKubectl <- runKubectlNormalization temporary
              case normalizedByKubectl of
                Left err -> pure (Left err)
                Right () -> do
                  finalBytes <- BS.readFile temporary
                  case validateNormalizedKubeconfig identity finalBytes of
                    Left err -> pure (Left err)
                    Right () -> do
                      current <- runCommand [("KUBECONFIG", temporary)] (ops ^. #kubectlExecutable) ["config", "current-context"]
                      pure $ case current of
                        Left err -> Left err
                        Right observed
                          | T.strip observed == identity ^. #contextName -> Right ()
                          | otherwise -> Left ("kubectl reported current context '" <> T.strip observed <> "', expected '" <> identity ^. #contextName <> "'")

    runKubectlNormalization temporary =
      foldM
        ( \result arguments -> case result of
            Left err -> pure (Left err)
            Right () -> fmap (const ()) <$> runCommand [("KUBECONFIG", temporary)] (ops ^. #kubectlExecutable) arguments
        )
        (Right ())
        [ ["config", "set-cluster", T.unpack (identity ^. #contextName), "--server=https://" <> T.unpack (identity ^. #hostName) <> ":6443"]
        , ["config", "set-context", T.unpack (identity ^. #contextName), "--cluster=" <> T.unpack (identity ^. #contextName), "--user=" <> T.unpack (identity ^. #contextName)]
        , ["config", "use-context", T.unpack (identity ^. #contextName)]
        ]

prepareDestination :: FilePath -> IO (Either Text FilePath)
prepareDestination destination = do
  let parent = takeDirectory destination
  created <- try (createDirectoryIfMissing True parent)
  case created of
    Left (err :: IOException) -> pure (Left (ioFailure "create the kubeconfig directory" err))
    Right () -> do
      linkedResult <- try (pathIsSymbolicLink destination)
      case linkedResult of
        Left (err :: IOException)
          | isDoesNotExistError err -> checkParent parent
          | otherwise -> pure (Left (ioFailure "inspect the kubeconfig destination" err))
        Right True -> pure (Left ("refusing symlink kubeconfig destination: " <> T.pack destination))
        Right False -> checkParent parent
  where
    checkParent parent = do
      statusResult <- try (getFileStatus parent)
      pure $ case statusResult of
        Left (err :: IOException) -> Left (ioFailure "inspect the kubeconfig directory" err)
        Right status ->
          let writableByOthers = unionFileModes groupWriteMode otherWriteMode
           in if fileMode status `intersectFileModes` writableByOthers /= 0
                then Left ("refusing kubeconfig directory writable by group or others: " <> T.pack parent)
                else Right parent

runCommand :: [(String, String)] -> FilePath -> [String] -> IO (Either Text Text)
runCommand overrides executable arguments = do
  inherited <- getEnvironment
  let overriddenNames = map fst overrides
      environment = overrides <> filter (\(name, _) -> name `notElem` overriddenNames) inherited
      process = (proc executable arguments) {env = Just environment}
  result <- try (readCreateProcessWithExitCode process "")
  pure $ case result of
    Left (err :: IOException) -> Left (ioFailure ("run " <> T.pack executable) err)
    Right (ExitSuccess, stdoutText, _) -> Right (T.pack stdoutText)
    Right (ExitFailure code, _, stderrText) ->
      Left
        ( T.pack executable
            <> " exited "
            <> T.pack (show code)
            <> diagnostic stderrText
        )
  where
    diagnostic stderrText
      | T.null (T.strip (T.pack stderrText)) = ""
      | otherwise = ": " <> T.strip (T.pack stderrText)

normalizeKubeconfig :: KubeconfigIdentity -> ByteString -> Either Text ByteString
normalizeKubeconfig identity input = do
  root <- decodeRoot input
  (clusterName, cluster) <- singletonNamedEntry "clusters" root
  (userName, user) <- singletonNamedEntry "users" root
  (oldContextName, context) <- singletonNamedEntry "contexts" root
  current <- textAt "current-context" root
  contextBody <- objectAt "context" context
  contextCluster <- textAt "cluster" contextBody
  contextUser <- textAt "user" contextBody
  unless (current == oldContextName) (Left "kubeconfig current-context does not name its sole context")
  unless (contextCluster == clusterName) (Left "kubeconfig context does not reference its sole cluster")
  unless (contextUser == userName) (Left "kubeconfig context does not reference its sole user")
  clusterBody <- objectAt "cluster" cluster
  let target = identity ^. #contextName
      endpoint = "https://" <> identity ^. #hostName <> ":6443"
      renamedCluster = Object (KeyMap.insert "name" (String target) (KeyMap.insert "cluster" (Object (KeyMap.insert "server" (String endpoint) clusterBody)) cluster))
      renamedUser = Object (KeyMap.insert "name" (String target) user)
      renamedContextBody = KeyMap.insert "user" (String target) (KeyMap.insert "cluster" (String target) contextBody)
      renamedContext = Object (KeyMap.insert "name" (String target) (KeyMap.insert "context" (Object renamedContextBody) context))
      normalizedRoot =
        KeyMap.insert "current-context" (String target)
          . KeyMap.insert "contexts" (Array (V.singleton renamedContext))
          . KeyMap.insert "users" (Array (V.singleton renamedUser))
          . KeyMap.insert "clusters" (Array (V.singleton renamedCluster))
          $ root
  let output = Yaml.encode (Object normalizedRoot)
  validateNormalizedKubeconfig identity output
  pure output

validateNormalizedKubeconfig :: KubeconfigIdentity -> ByteString -> Either Text ()
validateNormalizedKubeconfig identity input = do
  root <- decodeRoot input
  (clusterName, cluster) <- singletonNamedEntry "clusters" root
  (userName, _) <- singletonNamedEntry "users" root
  (contextName, context) <- singletonNamedEntry "contexts" root
  current <- textAt "current-context" root
  clusterBody <- objectAt "cluster" cluster
  endpoint <- textAt "server" clusterBody
  contextBody <- objectAt "context" context
  contextCluster <- textAt "cluster" contextBody
  contextUser <- textAt "user" contextBody
  let expectedName = identity ^. #contextName
      expectedEndpoint = "https://" <> identity ^. #hostName <> ":6443"
  unless
    (all (== expectedName) [clusterName, userName, contextName, current, contextCluster, contextUser])
    (Left "normalized kubeconfig does not consistently use the selected Nagare context name")
  unless
    (endpoint == expectedEndpoint)
    (Left ("normalized kubeconfig server is '" <> endpoint <> "', expected '" <> expectedEndpoint <> "'"))

decodeRoot :: ByteString -> Either Text (KeyMap.KeyMap Value)
decodeRoot input =
  case Yaml.decodeEither' input of
    Left err -> Left ("could not parse fetched kubeconfig: " <> T.pack (Yaml.prettyPrintParseException err))
    Right (Object root) -> Right root
    Right _ -> Left "fetched kubeconfig root is not an object"

singletonNamedEntry :: Key -> KeyMap.KeyMap Value -> Either Text (Text, KeyMap.KeyMap Value)
singletonNamedEntry key root = do
  value <- required key root
  entry <- case value of
    Array values
      | V.length values == 1 -> expectObject ("entry in " <> keyText key) (V.head values)
      | otherwise -> Left ("fetched kubeconfig must contain exactly one " <> keyText key <> " entry")
    _ -> Left ("fetched kubeconfig field " <> keyText key <> " is not an array")
  name <- textAt "name" entry
  pure (name, entry)

objectAt :: Key -> KeyMap.KeyMap Value -> Either Text (KeyMap.KeyMap Value)
objectAt key object = required key object >>= expectObject (keyText key)

textAt :: Key -> KeyMap.KeyMap Value -> Either Text Text
textAt key object = do
  value <- required key object
  case value of
    String textValue | not (T.null (T.strip textValue)) -> Right textValue
    _ -> Left ("fetched kubeconfig field " <> keyText key <> " is not a non-empty string")

required :: Key -> KeyMap.KeyMap Value -> Either Text Value
required key object = maybe (Left ("fetched kubeconfig is missing " <> keyText key)) Right (KeyMap.lookup key object)

expectObject :: Text -> Value -> Either Text (KeyMap.KeyMap Value)
expectObject _ (Object object) = Right object
expectObject label _ = Left ("fetched kubeconfig " <> label <> " is not an object")

keyText :: Key -> Text
keyText = AesonKey.toText

ioFailure :: Text -> IOException -> Text
ioFailure action err = "could not " <> action <> ": " <> T.pack (show err)
