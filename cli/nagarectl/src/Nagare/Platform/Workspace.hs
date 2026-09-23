{-# LANGUAGE OverloadedStrings #-}

-- | Immutable-payload identity and atomic, per-context writable workspaces.
module Nagare.Platform.Workspace
  ( PayloadManifest (..)
  , PlatformWorkspace (..)
  , WorkspaceError (..)
  , readPayloadManifest
  , payloadDigest
  , preparePlatformWorkspace
  , findPlatformWorkspace
  , renderWorkspaceError
  )
where

import Control.Exception (IOException, bracketOnError, try)
import Crypto.Hash (Context, Digest, SHA256, hashFinalize, hashInit, hashUpdate)
import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding (Context)
import Nagare.Platform.Paths (PlatformPaths (..))
import Nagare.Target (ContextName, contextNameText)
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , removeDirectoryRecursive
  , renameDirectory
  )
import System.FilePath (makeRelative, takeDirectory, (</>))
import System.IO.Temp (createTempDirectory)

data PayloadManifest = PayloadManifest
  { assetSchemaVersion :: !Int
  , payloadId :: !Text
  , platformVersion :: !Text
  , sourceRevision :: !(Maybe Text)
  , rollbackSupportedFrom :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

instance Aeson.FromJSON PayloadManifest where
  parseJSON = Aeson.withObject "PayloadManifest" $ \o ->
    PayloadManifest
      <$> o .: "assetSchemaVersion"
      <*> o .: "payloadId"
      <*> o .: "platformVersion"
      <*> o .: "sourceRevision"
      <*> o Aeson..:? "rollbackSupportedFrom" Aeson..!= []

data PlatformWorkspace = PlatformWorkspace
  { root :: !FilePath
  , payloadId :: !Text
  , platformVersion :: !Text
  , sourceRevision :: !(Maybe Text)
  , digest :: !Text
  , pulumiDir :: !FilePath
  , scriptsDir :: !FilePath
  , clusterDir :: !FilePath
  , nixosDir :: !FilePath
  , justfile :: !FilePath
  , docsDir :: !FilePath
  }
  deriving stock (Generic, Eq, Show)

data WorkspaceError
  = InvalidPayloadManifest !FilePath !Text
  | InvalidPayloadId !Text
  | WorkspaceIoError !FilePath !Text
  | ExistingWorkspaceMismatch !FilePath
  deriving stock (Eq, Show)

workspaceAssets :: [FilePath]
workspaceAssets =
  [ "release.json"
  , "justfile"
  , "cli/nagare-dsl"
  , "cli/nagare-access"
  , "infra/pulumi"
  , "cluster/bootstrap"
  , "cluster/examples"
  , "cluster/observability"
  , "cluster/local"
  , "scripts"
  , "nixos"
  , "docs/user"
  , "docs/runbooks"
  , "docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md"
  , "docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md"
  ]

ignoredNames :: [FilePath]
ignoredNames = [".direnv", ".git", ".pulumi-home", ".pulumi-state", "dist-newstyle", "node_modules", "result"]

readPayloadManifest :: PlatformPaths -> IO (Either WorkspaceError PayloadManifest)
readPayloadManifest paths = do
  result <- try (BS.readFile (paths ^. #manifest))
  pure $ case result of
    Left (err :: IOException) -> Left (WorkspaceIoError (paths ^. #manifest) (T.pack (show err)))
    Right bytes -> case Aeson.eitherDecodeStrict' bytes of
      Left err -> Left (InvalidPayloadManifest (paths ^. #manifest) (T.pack err))
      Right manifest -> Right manifest

payloadDigest :: PlatformPaths -> IO (Either WorkspaceError Text)
payloadDigest paths = do
  result <- try $ do
    files <- platformFiles paths
    context <- foldlHash (hashInit :: Context SHA256) files
    pure (T.pack (show (hashFinalize context :: Digest SHA256)))
  pure $ case result of
    Left (err :: IOException) -> Left (WorkspaceIoError (paths ^. #root) (T.pack (show err)))
    Right digest -> Right digest
  where
    foldlHash context [] = pure context
    foldlHash context (file : rest) = do
      bytes <- BS.readFile file
      let relative = TE.encodeUtf8 (T.pack (makeRelative (paths ^. #root) file))
          separator = BS.singleton 0
          next = hashUpdate (hashUpdate (hashUpdate context relative) separator) bytes
      foldlHash (hashUpdate next separator) rest

preparePlatformWorkspace :: FilePath -> ContextName -> PlatformPaths -> IO (Either WorkspaceError PlatformWorkspace)
preparePlatformWorkspace stateRoot context paths = do
  manifestResult <- readPayloadManifest paths
  digestResult <- payloadDigest paths
  case (manifestResult, digestResult) of
    (Left err, _) -> pure (Left err)
    (_, Left err) -> pure (Left err)
    (Right manifest, Right digest)
      | not (validPayloadId (manifest ^. #payloadId)) -> pure (Left (InvalidPayloadId (manifest ^. #payloadId)))
      | otherwise -> materialize manifest digest
  where
    materialize manifest digest = do
      let parent = stateRoot </> T.unpack (contextNameText context) </> "platform"
          directoryName = T.unpack (manifest ^. #payloadId <> "-" <> T.take 16 digest)
          destination = parent </> directoryName
      createDirectoryIfMissing True parent
      existing <- doesDirectoryExist destination
      if existing
        then validateExisting destination manifest digest
        else do
          result <-
            try $
              bracketOnError
                (createTempDirectory parent ".nagare-platform-")
                removeDirectoryRecursive
                ( \staging -> do
                    copyPlatformAssets paths staging
                    writeWorkspaceManifest staging manifest digest
                    renameDirectory staging destination
                )
          case result of
            Left (err :: IOException) -> do
              raced <- doesDirectoryExist destination
              if raced
                then validateExisting destination manifest digest
                else pure (Left (WorkspaceIoError destination (T.pack (show err))))
            Right () -> pure (Right (workspaceAt destination manifest digest))

-- | Locate a prepared payload without materializing or changing it. Status
-- uses this path so an observation cannot create a workspace as a side effect.
findPlatformWorkspace :: FilePath -> ContextName -> PlatformPaths -> IO (Either WorkspaceError PlatformWorkspace)
findPlatformWorkspace stateRoot context paths = do
  manifestResult <- readPayloadManifest paths
  digestResult <- payloadDigest paths
  case (manifestResult, digestResult) of
    (Left err, _) -> pure (Left err)
    (_, Left err) -> pure (Left err)
    (Right manifest, Right digest)
      | not (validPayloadId (manifest ^. #payloadId)) -> pure (Left (InvalidPayloadId (manifest ^. #payloadId)))
      | otherwise -> do
          let parent = stateRoot </> T.unpack (contextNameText context) </> "platform"
              directoryName = T.unpack (manifest ^. #payloadId <> "-" <> T.take 16 digest)
          validateExisting (parent </> directoryName) manifest digest

validPayloadId :: Text -> Bool
validPayloadId value =
  not (T.null value)
    && T.all (\c -> c == '-' || c == '_' || c == '.' || c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z') value

workspaceAt :: FilePath -> PayloadManifest -> Text -> PlatformWorkspace
workspaceAt root manifest digest =
  PlatformWorkspace
    { root = root
    , payloadId = manifest ^. #payloadId
    , platformVersion = manifest ^. #platformVersion
    , sourceRevision = manifest ^. #sourceRevision
    , digest = digest
    , pulumiDir = root </> "infra" </> "pulumi"
    , scriptsDir = root </> "scripts"
    , clusterDir = root </> "cluster"
    , nixosDir = root </> "nixos"
    , justfile = root </> "justfile"
    , docsDir = root </> "docs" </> "user"
    }

validateExisting :: FilePath -> PayloadManifest -> Text -> IO (Either WorkspaceError PlatformWorkspace)
validateExisting root manifest digest = do
  result <- try (BS.readFile (root </> ".nagare-workspace.json"))
  pure $ case result of
    Left (_ :: IOException) -> Left (ExistingWorkspaceMismatch root)
    Right bytes -> case Aeson.decodeStrict' bytes of
      Just (Aeson.Object object)
        | KeyMap.lookup "payloadId" object == Just (Aeson.String (manifest ^. #payloadId))
        , KeyMap.lookup "digest" object == Just (Aeson.String digest) ->
            Right (workspaceAt root manifest digest)
      _ -> Left (ExistingWorkspaceMismatch root)

writeWorkspaceManifest :: FilePath -> PayloadManifest -> Text -> IO ()
writeWorkspaceManifest root manifest digest =
  LBS.writeFile (root </> ".nagare-workspace.json") $
    Aeson.encode $
      Aeson.object
        [ "assetSchemaVersion" Aeson..= (manifest ^. #assetSchemaVersion)
        , "payloadId" Aeson..= (manifest ^. #payloadId)
        , "platformVersion" Aeson..= (manifest ^. #platformVersion)
        , "sourceRevision" Aeson..= (manifest ^. #sourceRevision)
        , "digest" Aeson..= digest
        ]

platformFiles :: PlatformPaths -> IO [FilePath]
platformFiles paths = sort . concat <$> traverse (filesBelow . (paths ^. #root </>)) workspaceAssets

filesBelow :: FilePath -> IO [FilePath]
filesBelow path = do
  isFile <- doesFileExist path
  if isFile
    then pure [path]
    else do
      isDirectory <- doesDirectoryExist path
      if not isDirectory
        then pure []
        else do
          names <- sort <$> listDirectory path
          concat <$> traverse (filesBelow . (path </>)) (filter (not . ignoredAssetName) names)

copyPlatformAssets :: PlatformPaths -> FilePath -> IO ()
copyPlatformAssets paths destination = traverse_ copyOne workspaceAssets
  where
    copyOne relative = copyTree (paths ^. #root </> relative) (destination </> relative)

copyTree :: FilePath -> FilePath -> IO ()
copyTree source destination = do
  isFile <- doesFileExist source
  if isFile
    then createDirectoryIfMissing True (takeDirectory destination) >> copyFile source destination
    else do
      isDirectory <- doesDirectoryExist source
      if not isDirectory
        then pure ()
        else do
          createDirectoryIfMissing True destination
          names <- sort <$> listDirectory source
          traverse_ (\name -> copyTree (source </> name) (destination </> name)) (filter (not . ignoredAssetName) names)

ignoredAssetName :: FilePath -> Bool
ignoredAssetName name =
  name `elem` ignoredNames
    || (name /= "Pulumi.yaml" && "Pulumi." `isPrefixOf` name && ".yaml" `isSuffixOf` name)

renderWorkspaceError :: WorkspaceError -> Text
renderWorkspaceError err = case err of
  InvalidPayloadManifest path detail -> "invalid Nagare payload manifest " <> T.pack path <> ": " <> detail
  InvalidPayloadId payloadId -> "invalid Nagare payload id: " <> payloadId
  WorkspaceIoError path detail -> "could not prepare Nagare platform workspace " <> T.pack path <> ": " <> detail
  ExistingWorkspaceMismatch path -> "existing Nagare platform workspace has a mismatched manifest: " <> T.pack path
