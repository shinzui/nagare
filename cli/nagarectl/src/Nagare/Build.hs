-- | Build-mode dispatch for @nagarectl deploy@.
--
-- This module sits above 'Nagare.Image' (the Docker/registry primitives) and
-- turns a typed 'Nagare.Dsl.Build.BuildSpec' into an action:
--
--   * 'PrebuiltImage' — nothing is built or pushed; the caller skips the build
--     entirely (it checks 'Nagare.Dsl.Build.requiresBuild' first).
--   * 'DockerfileBuild' — @docker build@ with the configured Dockerfile path,
--     build context, and @--build-arg@s (via 'Nagare.Image.buildDockerfile').
--   * 'NixpacksBuild' — @nixpacks build@ on the (Dockerfile-free) context, with
--     build args passed as build-time env vars (via 'Nagare.Image.buildNixpacks',
--     EP-21). 'performBuild' first checks @nixpacks@ is on @PATH@ and fails with
--     an actionable message if not.
--
-- 'describeBuild' produces the one-line @--dry-run@ description, and
-- 'applyBuildOverrides' is the pure core of the @--context@/@--dockerfile@
-- override logic (overrides are valid only for build modes; using one with a
-- prebuilt image is a user error).
module Nagare.Build
  ( performBuild
  , describeBuild
  , applyBuildOverrides
  ) where

import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Build (BuildSpec (..), tagText)
import Nagare.Dsl.Path (FilePathText, filePathText, mkFilePathText)
import Nagare.Image (buildDockerfile, buildNixpacks)
import System.Directory (findExecutable)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Build the image for a build mode that requires building (Dockerfile or
-- Nixpacks). Precondition: 'Nagare.Dsl.Build.requiresBuild' is 'True' —
-- 'PrebuiltImage' is handled by the caller (no build). 'NixpacksBuild' is not
-- yet supported and exits with a clear message (implemented in EP-21).
performBuild :: BuildSpec -> Text -> IO ()
performBuild spec ref = case spec of
  PrebuiltImage _ -> pure () -- defensive; the caller skips via requiresBuild
  DockerfileBuild df ctx args ->
    buildDockerfile
      ref
      (T.unpack (filePathText df))
      (T.unpack (filePathText ctx))
      (Map.toList args)
  NixpacksBuild ctx args -> do
    ensureNixpacks
    buildNixpacks ref (T.unpack (filePathText ctx)) (Map.toList args)

-- | Fail with an actionable message if the @nixpacks@ CLI is not on @PATH@,
-- rather than letting the shell-out die with a raw "command not found".
ensureNixpacks :: IO ()
ensureNixpacks = do
  found <- findExecutable "nixpacks"
  case found of
    Just _ -> pure ()
    Nothing -> die "nixpacks not found on PATH; see docs/user/build-modes.md"

-- | A one-line, human-readable description of the build action, for @--dry-run@.
describeBuild :: BuildSpec -> Text
describeBuild = \case
  PrebuiltImage t ->
    "prebuilt image (no local build), tag " <> tagText t
  DockerfileBuild df ctx _ ->
    "docker build -f " <> filePathText df <> " " <> filePathText ctx
  NixpacksBuild ctx _ ->
    "nixpacks build " <> filePathText ctx

-- | Apply CLI overrides to the config's build spec. The first argument is a
-- @--context@ override, the second a @--dockerfile@ override; either may be
-- 'Nothing'. Overrides are valid only for build modes:
--
--   * 'DockerfileBuild' — either override re-validates its path and substitutes
--     the corresponding field.
--   * 'NixpacksBuild' — a @--context@ override applies; a @--dockerfile@ override
--     is an error (a Nixpacks build has no Dockerfile).
--   * 'PrebuiltImage' — any override is a user error (nothing is built).
--
-- With both overrides 'Nothing' the spec is returned unchanged.
applyBuildOverrides
  :: Maybe FilePath -> Maybe FilePath -> BuildSpec -> Either Text BuildSpec
applyBuildOverrides ctxOverride dfOverride spec = case spec of
  PrebuiltImage _
    | hasOverride -> Left prebuiltOverrideError
    | otherwise -> Right spec
  DockerfileBuild df ctx args -> do
    df' <- overridePath dfOverride df
    ctx' <- overridePath ctxOverride ctx
    Right (DockerfileBuild {dockerfile = df', context = ctx', buildArgs = args})
  NixpacksBuild ctx args -> do
    case dfOverride of
      Just _ -> Left "--dockerfile cannot be used with a Nixpacks build (it has no Dockerfile)"
      Nothing -> Right ()
    ctx' <- overridePath ctxOverride ctx
    Right (NixpacksBuild {context = ctx', buildArgs = args})
  where
    hasOverride = case (ctxOverride, dfOverride) of
      (Nothing, Nothing) -> False
      _ -> True
    prebuiltOverrideError =
      "--context/--dockerfile cannot be used with a prebuilt-image config"

-- | Re-validate an override path through 'mkFilePathText', or keep the current
-- value when the override is 'Nothing'.
overridePath :: Maybe FilePath -> FilePathText -> Either Text FilePathText
overridePath Nothing current = Right current
overridePath (Just p) _ = mkFilePathText (T.pack p)

-- | Print a one-line @nagare:@ error to stderr and exit non-zero.
die :: Text -> IO a
die msg = do
  TIO.hPutStrLn stderr ("nagare: " <> msg)
  exitFailure
