{-# LANGUAGE OverloadedStrings #-}

-- | Immutable-payload identity and atomic, per-context writable workspaces.
module Nagare.Platform.Workspace
  ( PayloadManifest (..)
  , PlatformWorkspace (..)
  , WorkspaceError (..)
  , readPayloadManifest
  , payloadDigest
  , preparePlatformWorkspace
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
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
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
  { pmAssetSchemaVersion :: !Int
  , pmPayloadId :: !Text
  , pmPlatformVersion :: !Text
  , pmSourceRevision :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance Aeson.FromJSON PayloadManifest where
  parseJSON = Aeson.withObject "PayloadManifest" $ \o ->
    PayloadManifest
      <$> o .: "assetSchemaVersion"
      <*> o .: "payloadId"
      <*> o .: "platformVersion"
      <*> o .: "sourceRevision"

data PlatformWorkspace = PlatformWorkspace
  { pwRoot :: !FilePath
  , pwPayloadId :: !Text
  , pwPlatformVersion :: !Text
  , pwSourceRevision :: !(Maybe Text)
  , pwDigest :: !Text
  , pwPulumiDir :: !FilePath
  , pwScriptsDir :: !FilePath
  , pwClusterDir :: !FilePath
  , pwNixosDir :: !FilePath
  , pwJustfile :: !FilePath
  , pwDocsDir :: !FilePath
  }
  deriving stock (Eq, Show)

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
  , "infra/pulumi"
  , "cluster/bootstrap"
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
  result <- try (BS.readFile (ppManifest paths))
  pure $ case result of
    Left (err :: IOException) -> Left (WorkspaceIoError (ppManifest paths) (T.pack (show err)))
    Right bytes -> case Aeson.eitherDecodeStrict' bytes of
      Left err -> Left (InvalidPayloadManifest (ppManifest paths) (T.pack err))
      Right manifest -> Right manifest

payloadDigest :: PlatformPaths -> IO (Either WorkspaceError Text)
payloadDigest paths = do
  result <- try $ do
    files <- platformFiles paths
    context <- foldlHash (hashInit :: Context SHA256) files
    pure (T.pack (show (hashFinalize context :: Digest SHA256)))
  pure $ case result of
    Left (err :: IOException) -> Left (WorkspaceIoError (ppRoot paths) (T.pack (show err)))
    Right digest -> Right digest
  where
    foldlHash context [] = pure context
    foldlHash context (file : rest) = do
      bytes <- BS.readFile file
      let relative = TE.encodeUtf8 (T.pack (makeRelative (ppRoot paths) file))
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
      | not (validPayloadId (pmPayloadId manifest)) -> pure (Left (InvalidPayloadId (pmPayloadId manifest)))
      | otherwise -> materialize manifest digest
  where
    materialize manifest digest = do
      let parent = stateRoot </> T.unpack (contextNameText context) </> "platform"
          directoryName = T.unpack (pmPayloadId manifest <> "-" <> T.take 16 digest)
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

validPayloadId :: Text -> Bool
validPayloadId value =
  not (T.null value)
    && T.all (\c -> c == '-' || c == '_' || c == '.' || c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z') value

workspaceAt :: FilePath -> PayloadManifest -> Text -> PlatformWorkspace
workspaceAt root manifest digest =
  PlatformWorkspace
    { pwRoot = root
    , pwPayloadId = pmPayloadId manifest
    , pwPlatformVersion = pmPlatformVersion manifest
    , pwSourceRevision = pmSourceRevision manifest
    , pwDigest = digest
    , pwPulumiDir = root </> "infra" </> "pulumi"
    , pwScriptsDir = root </> "scripts"
    , pwClusterDir = root </> "cluster"
    , pwNixosDir = root </> "nixos"
    , pwJustfile = root </> "justfile"
    , pwDocsDir = root </> "docs" </> "user"
    }

validateExisting :: FilePath -> PayloadManifest -> Text -> IO (Either WorkspaceError PlatformWorkspace)
validateExisting root manifest digest = do
  result <- try (BS.readFile (root </> ".nagare-workspace.json"))
  pure $ case result of
    Left (_ :: IOException) -> Left (ExistingWorkspaceMismatch root)
    Right bytes -> case Aeson.decodeStrict' bytes of
      Just (Aeson.Object object)
        | KeyMap.lookup "payloadId" object == Just (Aeson.String (pmPayloadId manifest))
        , KeyMap.lookup "digest" object == Just (Aeson.String digest) ->
            Right (workspaceAt root manifest digest)
      _ -> Left (ExistingWorkspaceMismatch root)

writeWorkspaceManifest :: FilePath -> PayloadManifest -> Text -> IO ()
writeWorkspaceManifest root manifest digest =
  LBS.writeFile (root </> ".nagare-workspace.json") $
    Aeson.encode $
      Aeson.object
        [ "assetSchemaVersion" Aeson..= pmAssetSchemaVersion manifest
        , "payloadId" Aeson..= pmPayloadId manifest
        , "platformVersion" Aeson..= pmPlatformVersion manifest
        , "sourceRevision" Aeson..= pmSourceRevision manifest
        , "digest" Aeson..= digest
        ]

platformFiles :: PlatformPaths -> IO [FilePath]
platformFiles paths = sort . concat <$> traverse (filesBelow . (ppRoot paths </>)) workspaceAssets

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
    copyOne relative = copyTree (ppRoot paths </> relative) (destination </> relative)

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
