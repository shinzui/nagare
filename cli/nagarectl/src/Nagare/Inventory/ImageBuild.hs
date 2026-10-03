-- | Prepare a local Docker archive from exact accepted Build channel values.
-- Secret values are passed through private BuildKit mounts, never argv.
module Nagare.Inventory.ImageBuild
  ( buildDockerArchive
  , buildDockerArchiveWith
  , dockerBuildArguments
  , validateSecretMounts
  )
where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import System.Directory (doesPathExist, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process (createProcess, proc, waitForProcess)

-- | Keep the supported secret contract narrow: each secret key must be named
-- in a required BuildKit mount on a RUN instruction. BuildKit then fails if a
-- selected value is unavailable. A fresh build executes those instructions.
validateSecretMounts :: BS.ByteString -> [Text] -> Either Text ()
validateSecretMounts dockerfile secretIds = do
  contents <-
    either
      (const (Left "Dockerfile must be UTF-8"))
      Right
      (TE.decodeUtf8' dockerfile)
  let instructions = map T.stripStart (T.lines (T.replace "\\\n" " " contents))
      runMounts =
        [ mount
        | instruction <- instructions
        , let words' = T.words instruction
        , case words' of
            keyword : _ -> T.toUpper keyword == "RUN"
            _ -> False
        , mount <- words'
        , "--mount=" `T.isPrefixOf` mount
        ]
      requiredIds =
        [ identifier
        | mount <- runMounts
        , let fields = T.splitOn "," (T.drop (T.length "--mount=") mount)
        , "type=secret" `elem` fields
        , "required=true" `elem` fields
        , field <- fields
        , Just identifier <- [T.stripPrefix "id=" field]
        ]
  unless
    (all (`elem` requiredIds) secretIds)
    (Left "Dockerfile must use RUN --mount=type=secret,id=NAME,required=true for every accepted Build Secret key")

validKey :: Text -> Bool
validKey value = case T.uncons value of
  Just (initial, rest) ->
    (initial == '_' || asciiLetter initial)
      && T.all (\c -> c == '_' || asciiLetter c || ('0' <= c && c <= '9')) rest
  Nothing -> False
  where
    asciiLetter c = ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z')

dockerBuildArguments ::
  Text ->
  Text ->
  FilePath ->
  FilePath ->
  Map Text Text ->
  Map Text FilePath ->
  Either Text [String]
dockerBuildArguments platform destination dockerfile context buildArgs secretFiles = do
  unless
    (all validKey (Map.keys buildArgs <> Map.keys secretFiles))
    (Left "Build channel keys must be shell environment names")
  unless
    (Map.null (Map.intersection buildArgs secretFiles))
    (Left "Build environment and Secret channels use the same key")
  pure $
    [ "buildx"
    , "build"
    , "--load"
    , "--no-cache"
    , "--platform"
    , T.unpack platform
    , "-f"
    , dockerfile
    , "-t"
    , T.unpack destination
    ]
      <> concatMap
        (\(key, value) -> ["--build-arg", T.unpack (key <> "=" <> value)])
        (Map.toAscList buildArgs)
      <> concatMap
        ( \(key, path) ->
            ["--secret", "type=file,id=" <> T.unpack key <> ",src=" <> path]
        )
        (Map.toAscList secretFiles)
      <> [context]

-- | Build and save only to a previously absent archive path. The caller
-- inspects and hashes the completed archive before publication review.
buildDockerArchive ::
  Text ->
  Text ->
  FilePath ->
  FilePath ->
  FilePath ->
  Map Text Text ->
  Map Text Text ->
  IO (Either Text ())
buildDockerArchive = buildDockerArchiveWith runDocker

-- | Injecting the command runner lets the transport be checked without a
-- Docker daemon while preserving the real private-file lifecycle.
buildDockerArchiveWith ::
  ([String] -> IO Bool) ->
  Text ->
  Text ->
  FilePath ->
  FilePath ->
  FilePath ->
  Map Text Text ->
  Map Text Text ->
  IO (Either Text ())
buildDockerArchiveWith run platform destination dockerfile context archive buildArgs secrets = do
  result <- try $ do
    exists <- doesPathExist archive
    if exists
      then pure (Left "Docker archive path already exists")
      else do
        dockerfileBytes <- BS.readFile dockerfile
        case validateSecretMounts dockerfileBytes (Map.keys secrets) of
          Left message -> pure (Left message)
          Right () -> withSystemTempDirectory "nagare-build-secrets" $ \secretDir -> do
            setFileMode secretDir 0o700
            secretFiles <-
              traverse
                ( \(secretIndex, (key, value)) -> do
                    let path = secretDir </> show secretIndex
                    BS.writeFile path (TE.encodeUtf8 value)
                    setFileMode path 0o600
                    pure (key, path)
                )
                (zip [(0 :: Int) ..] (Map.toAscList secrets))
            case dockerBuildArguments
              platform
              destination
              dockerfile
              context
              buildArgs
              (Map.fromList secretFiles) of
              Left message -> pure (Left message)
              Right args -> do
                built <- run args
                if not built
                  then pure (Left "Docker BuildKit build failed")
                  else do
                    saved <-
                      run
                        [ "image"
                        , "save"
                        , "--output"
                        , archive
                        , T.unpack destination
                        ]
                    if saved
                      then pure (Right ())
                      else do
                        partial <- doesPathExist archive
                        if partial then removeFile archive else pure ()
                        pure (Left "Docker image save failed")
  pure (either (Left . T.pack . show) id (result :: Either IOException (Either Text ())))

runDocker :: [String] -> IO Bool
runDocker args = do
  (_, _, _, processHandle) <- createProcess (proc "docker" args)
  (== ExitSuccess) <$> waitForProcess processHandle
