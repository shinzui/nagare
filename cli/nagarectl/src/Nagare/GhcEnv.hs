-- | Auto-discovery of the GHC package-environment file the config loader needs
-- (MasterPlan 13, EP-6 M1).
--
-- @nagarectl@'s deploy-class commands load an app's @nagare/Config.hs@ by shelling
-- out to @runghc@ (see @Nagare.Dsl.Load.runConfig@). For the @import Nagare.Dsl.*@
-- lines to resolve, @runghc@ must see the @nagare-dsl@ package database, which it
-- learns from a GHC /package-environment file/ named
-- @.ghc.environment.\<arch>-\<os>-\<ghcver>@ — the file @cabal@ writes next to a
-- project (this repo sets @write-ghc-environment-files: always@). When an operator
-- runs @nagarectl@ from an app directory, no such file is on @runghc@'s search
-- path and the load fails. The 2026-06-10 audit worked around this by hand-capturing
-- the file and passing @--ghc-env@ to every command.
--
-- This module lets @nagarectl@ find that file itself: 'resolveProjectGhcEnv'
-- locates the checked-out @cli\/nagarectl@ and @cli\/nagare-dsl@ package directories
-- (by walking up from the cwd and the executable's path to the repo root) and
-- returns the first @.ghc.environment.*@ it finds, falling back to asking @cabal@.
-- 'provisionGhcEnv' (in the executables) calls this only when neither @--ghc-env@
-- nor @NAGARE_GHC_ENVIRONMENT@ is set, so explicit overrides still win.
module Nagare.GhcEnv
  ( findGhcEnvIn
  , resolveProjectGhcEnv
  ) where

import Control.Exception (SomeException, try)
import Data.List (isPrefixOf, nub, sort)
import Data.Maybe (catMaybes, listToMaybe)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , getCurrentDirectory
  , listDirectory
  , makeAbsolute
  )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (readProcessWithExitCode)

-- | The first existing @.ghc.environment.*@ file across the given directories,
-- as an absolute path, or 'Nothing'. Directories that do not exist (or cannot be
-- listed) are skipped. This is the testable core of 'resolveProjectGhcEnv'.
findGhcEnvIn :: [FilePath] -> IO (Maybe FilePath)
findGhcEnvIn [] = pure Nothing
findGhcEnvIn (dir : rest) = do
  exists <- doesDirectoryExist dir
  if not exists
    then findGhcEnvIn rest
    else do
      eentries <- try (listDirectory dir) :: IO (Either SomeException [FilePath])
      let entries = either (const []) id eentries
          hits = sort [e | e <- entries, ".ghc.environment." `isPrefixOf` e]
      case hits of
        (h : _) -> Just <$> makeAbsolute (dir </> h)
        [] -> findGhcEnvIn rest

-- | Discover the project's GHC package-environment file. Searches the checked-out
-- @cli\/nagarectl@ and @cli\/nagare-dsl@ package directories (found by locating the
-- repo root from both the current directory and the executable's location), plus
-- the current directory and a few of its ancestors (covering the case where
-- @nagarectl@ is run from inside @cli\/nagarectl@). If nothing is found on disk,
-- asks @cabal@ as a last resort. 'Nothing' if none is found — callers preserve the
-- prior behavior (the loader then fails with its existing, clear compile error).
resolveProjectGhcEnv :: IO (Maybe FilePath)
resolveProjectGhcEnv = do
  cwd <- getCurrentDirectory
  exeDir <- takeDirectory <$> getExecutablePath
  rootFromCwd <- findRepoRoot cwd
  rootFromExe <- findRepoRoot exeDir
  let roots = nub (catMaybes [rootFromCwd, rootFromExe])
      pkgDirs = concatMap (\r -> [r </> "cli" </> "nagarectl", r </> "cli" </> "nagare-dsl"]) roots
      cwdAncestors = take 6 (ancestors cwd)
  found <- findGhcEnvIn (pkgDirs ++ cwdAncestors)
  case found of
    Just f -> pure (Just f)
    Nothing -> cabalFallback roots

-- | Walk up from @start@ (inclusive), returning the first ancestor that contains
-- @cli\/nagarectl\/cabal.project@ — i.e. the repository root — or 'Nothing'.
findRepoRoot :: FilePath -> IO (Maybe FilePath)
findRepoRoot start = makeAbsolute start >>= go
  where
    go dir = do
      here <- doesFileExist (dir </> "cli" </> "nagarectl" </> "cabal.project")
      if here
        then pure (Just dir)
        else
          let up = takeDirectory dir
           in if up == dir then pure Nothing else go up

-- | A path and all its ancestors, root-ward.
ancestors :: FilePath -> [FilePath]
ancestors p
  | takeDirectory p == p = [p]
  | otherwise = p : ancestors (takeDirectory p)

-- | Last resort: ask @cabal@ for the env file it would use for the @cli\/nagarectl@
-- project. Regenerates the file on demand for a fresh checkout that has never built.
-- Degrades gracefully (missing @cabal@, non-zero exit, or a @-@/empty/non-file
-- answer) to 'Nothing'.
cabalFallback :: [FilePath] -> IO (Maybe FilePath)
cabalFallback roots = case listToMaybe roots of
  Nothing -> pure Nothing
  Just root -> do
    let projDir = root </> "cli" </> "nagarectl"
    res <-
      try
        ( readProcessWithExitCode
            "cabal"
            ["exec", "--project-dir", projDir, "--", "sh", "-c", "printf %s \"$GHC_ENVIRONMENT\""]
            ""
        ) ::
        IO (Either SomeException (ExitCode, String, String))
    case res of
      Right (ExitSuccess, out, _) -> do
        let p = trim out
        if null p || p == "-"
          then pure Nothing
          else do
            ok <- doesFileExist p
            if ok then Just <$> makeAbsolute p else pure Nothing
      _ -> pure Nothing
  where
    trim = f . f where f = reverse . dropWhile (`elem` (" \t\r\n" :: String))
