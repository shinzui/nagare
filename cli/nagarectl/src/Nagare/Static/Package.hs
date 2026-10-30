-- | Package a prepared static site as a local artifact.
--
-- Two outputs, chosen by a closed 'PackageTarget': the canonical build context
-- (@Dockerfile@, @nginx.conf@, @site/@) written by 'writeStaticContext', or a
-- Docker archive built from that same context on an explicit platform with
-- Docker's ordinary layer cache. Packaging reads local files only: it never
-- touches inventory, Kubernetes, gcloud or the target registry, and the
-- archive path needs a Docker daemon only. The result carries the context's
-- content digest, the identity 'site publish' compares to detect an unchanged
-- release.
module Nagare.Static.Package
  ( PackageTarget (..)
  , PackageResult (..)
  , PackageError (..)
  , renderPackageError
  , supportedPlatforms
  , validateTag
  , validatePlatform
  , derivedTag
  , packageStaticSite
  , packageStaticSiteWith
  )
where

import Data.Char (isAlphaNum)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Static.Types (StaticSite)
import Nagare.Inventory.ImageBuild (buildDockerArchiveWith)
import Nagare.Inventory.Store.Counters (tracePhase, traceProcess)
import Nagare.Static.Build (PreparedStaticOutput)
import Nagare.Static.ContentDigest (ContentDigest)
import Nagare.Static.Image
  ( StaticContextError
  , renderStaticContextError
  , writeStaticContext
  )
import System.Directory (createDirectoryIfMissing, doesPathExist, makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (createProcess, proc, waitForProcess)

-- | What to produce. An archive names the exact image it will contain.
data PackageTarget
  = ContextOut !FilePath
  | ArchiveOut
      { archive :: !FilePath
      , destination :: !Text
      -- ^ the full tagged image reference baked into the archive
      , tag :: !Text
      , platform :: !Text
      }
  deriving stock (Eq, Show)

data PackageResult = PackageResult
  { path :: !FilePath
  , digest :: !ContentDigest
  , image :: !(Maybe Text)
  , tag :: !(Maybe Text)
  , platform :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

data PackageError
  = PackageContext !StaticContextError
  | PackageInvalidTag !Text
  | PackageUnsupportedPlatform !Text
  | PackageArchiveExists !FilePath
  | PackageBuildFailed !Text
  deriving stock (Eq, Show)

renderPackageError :: PackageError -> Text
renderPackageError = \case
  PackageContext e -> renderStaticContextError e
  PackageInvalidTag t ->
    "invalid image tag " <> T.pack (show t) <> " (use letters, digits, '_', '.' or '-', starting with a letter, digit or '_', at most 128 characters)"
  PackageUnsupportedPlatform p ->
    "unsupported platform " <> T.pack (show p) <> " (supported: " <> T.intercalate ", " supportedPlatforms <> ")"
  PackageArchiveExists p ->
    "archive already exists: " <> T.pack p <> " (existing artifacts are never replaced; choose a new path)"
  PackageBuildFailed m -> m

supportedPlatforms :: [Text]
supportedPlatforms = ["linux/amd64", "linux/arm64"]

validatePlatform :: Text -> Either PackageError Text
validatePlatform p
  | p `elem` supportedPlatforms = Right p
  | otherwise = Left (PackageUnsupportedPlatform p)

-- | A Docker tag: @[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}@.
validateTag :: Text -> Either PackageError Text
validateTag t = case T.uncons t of
  Just (c, rest)
    | T.length t <= 128
    , c == '_' || (isAlphaNum c && c < '\x80')
    , T.all (\x -> x `elem` ("_.-" :: String) || (isAlphaNum x && x < '\x80')) rest ->
        Right t
  _ -> Left (PackageInvalidTag t)

-- | A collision-resistant tag from the wall clock (microsecond resolution), used
-- when the operator supplies none.
derivedTag :: UTCTime -> Text
derivedTag now =
  T.pack (formatTime defaultTimeLocale "%Y%m%d-%H%M%S-" now)
    <> T.pack (take 6 (formatTime defaultTimeLocale "%q" now))

packageStaticSite ::
  StaticSite -> PreparedStaticOutput -> PackageTarget -> IO (Either PackageError PackageResult)
packageStaticSite = packageStaticSiteWith runDockerProcess

runDockerProcess :: [String] -> IO Bool
runDockerProcess args = traceProcess "docker" $ do
  (_, _, _, handle) <- createProcess (proc "docker" args)
  (== ExitSuccess) <$> waitForProcess handle

-- | The Docker runner is injectable so packaging can be checked without a daemon.
packageStaticSiteWith ::
  ([String] -> IO Bool) ->
  StaticSite ->
  PreparedStaticOutput ->
  PackageTarget ->
  IO (Either PackageError PackageResult)
packageStaticSiteWith run site prepared = \case
  ContextOut out -> do
    absolute <- makeAbsolute out
    written <- tracePhase "package.context" (writeStaticContext site prepared absolute)
    pure $ case written of
      Left e -> Left (PackageContext e)
      Right d -> Right PackageResult {path = absolute, digest = d, image = Nothing, tag = Nothing, platform = Nothing}
  ArchiveOut {archive = out, destination = ref, tag = t, platform = p} ->
    case (,) <$> validateTag t <*> validatePlatform p of
      Left e -> pure (Left e)
      Right _ -> do
        absolute <- makeAbsolute out
        exists <- doesPathExist absolute
        if exists
          then pure (Left (PackageArchiveExists absolute))
          else do
            createDirectoryIfMissing True (takeDirectory absolute)
            withSystemTempDirectory "nagare-static-package" $ \scratch -> do
              let ctx = scratch </> "context"
              written <- tracePhase "package.context" (writeStaticContext site prepared ctx)
              case written of
                Left e -> pure (Left (PackageContext e))
                Right d -> do
                  built <-
                    tracePhase "package.build" $
                      buildDockerArchiveWith run p ref (ctx </> "Dockerfile") ctx absolute Map.empty Map.empty
                  pure $ case built of
                    Left m
                      | "already exists" `T.isInfixOf` m -> Left (PackageArchiveExists absolute)
                      | otherwise -> Left (PackageBuildFailed m)
                    Right () ->
                      Right PackageResult {path = absolute, digest = d, image = Just ref, tag = Just t, platform = Just p}
