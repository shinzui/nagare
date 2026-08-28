{-# LANGUAGE OverloadedStrings #-}

-- | Resolution and validation of Nagare's immutable platform payload.
-- Runtime code must enter the operational tree through this module rather
-- than interpreting paths relative to the caller's current directory.
module Nagare.Platform.Paths
  ( PlatformRootSource (..)
  , PlatformPaths (..)
  , PlatformPathError (..)
  , requiredPlatformAssets
  , pathsFromRoot
  , validatePlatformRoot
  , resolvePlatformPaths
  , renderPlatformPathError
  , platformRootSourceToken
  )
where

import Control.Exception (IOException, try)
import Data.List (intercalate)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (canonicalizePath, doesFileExist, getCurrentDirectory, makeAbsolute)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))

data PlatformRootSource = ExplicitRoot | InstalledRoot | SourceRoot
  deriving stock (Eq, Show)

data PlatformPaths = PlatformPaths
  { ppRootSource :: !PlatformRootSource
  , ppRoot :: !FilePath
  , ppManifest :: !FilePath
  , ppPulumiDir :: !FilePath
  , ppScriptsDir :: !FilePath
  , ppClusterDir :: !FilePath
  , ppNixosDir :: !FilePath
  , ppJustfile :: !FilePath
  , ppDocsDir :: !FilePath
  }
  deriving stock (Eq, Show)

data PlatformPathError
  = InvalidPlatformRoot !PlatformRootSource !FilePath ![FilePath]
  | PlatformRootNotFound !FilePath
  deriving stock (Eq, Show)

requiredPlatformAssets :: [FilePath]
requiredPlatformAssets =
  [ "release.json"
  , "cli/nagare-dsl/nagare-dsl.cabal"
  , "cli/nagare-access/nagare-access.cabal"
  , "cli/nagare-access/Dockerfile"
  , "infra/pulumi/Pulumi.yaml"
  , "cluster/bootstrap/render-context-template.sh"
  , "nixos/flake.nix"
  , "scripts/lib/target.sh"
  , "justfile"
  , "docs/user/reference.md"
  ]

pathsFromRoot :: PlatformRootSource -> FilePath -> PlatformPaths
pathsFromRoot source root =
  PlatformPaths
    { ppRootSource = source
    , ppRoot = root
    , ppManifest = root </> "release.json"
    , ppPulumiDir = root </> "infra" </> "pulumi"
    , ppScriptsDir = root </> "scripts"
    , ppClusterDir = root </> "cluster"
    , ppNixosDir = root </> "nixos"
    , ppJustfile = root </> "justfile"
    , ppDocsDir = root </> "docs" </> "user"
    }

validatePlatformRoot :: PlatformRootSource -> FilePath -> IO (Either PlatformPathError PlatformPaths)
validatePlatformRoot source candidate = do
  absolute <- makeAbsolute candidate
  canonical <- try (canonicalizePath absolute)
  let root = either (const absolute) id (canonical :: Either IOException FilePath)
  present <- traverse (doesFileExist . (root </>)) requiredPlatformAssets
  let missing = map fst (filter (not . snd) (zip requiredPlatformAssets present))
  pure $ if null missing then Right (pathsFromRoot source root) else Left (InvalidPlatformRoot source root missing)

-- | Resolve an explicit test/command override, then the wrapper-provided
-- @NAGARE_PLATFORM_ROOT@, then a validated source ancestor. An explicitly
-- named invalid root is terminal: it never falls back to a checkout.
resolvePlatformPaths :: Maybe FilePath -> IO (Either PlatformPathError PlatformPaths)
resolvePlatformPaths override = case nonEmpty =<< override of
  Just root -> validatePlatformRoot ExplicitRoot root
  Nothing -> do
    installed <- lookupEnv "NAGARE_PLATFORM_ROOT"
    case nonEmpty =<< installed of
      Just root -> validatePlatformRoot InstalledRoot root
      Nothing -> do
        cwd <- getCurrentDirectory >>= canonicalizePath
        findSourceRoot cwd cwd
  where
    nonEmpty value = if null value then Nothing else Just value

    findSourceRoot origin candidate = do
      result <- validatePlatformRoot SourceRoot candidate
      case result of
        Right paths -> pure (Right paths)
        Left _
          | parent == candidate -> pure (Left (PlatformRootNotFound origin))
          | otherwise -> findSourceRoot origin parent
          where
            parent = takeDirectory candidate

platformRootSourceToken :: PlatformRootSource -> Text
platformRootSourceToken ExplicitRoot = "explicit"
platformRootSourceToken InstalledRoot = "installed"
platformRootSourceToken SourceRoot = "source"

renderPlatformPathError :: PlatformPathError -> Text
renderPlatformPathError err = case err of
  InvalidPlatformRoot source root missing ->
    "invalid "
      <> platformRootSourceToken source
      <> " Nagare platform root "
      <> T.pack root
      <> "; missing required asset(s): "
      <> T.pack (intercalate ", " missing)
  PlatformRootNotFound origin ->
    "could not find a Nagare platform payload from "
      <> T.pack origin
      <> "; set NAGARE_PLATFORM_ROOT or run the packaged nagarectl"
