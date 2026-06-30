-- | Container image operations for a deployment: tag computation, the full
-- image reference, building, Docker auth, and pushing to Artifact Registry.
--
-- All shell-outs go through the @cradle@ process library. The image repository
-- path comes from the 'Deployment' value (EP-9's 'Nagare.Dsl.Types.ImageRef');
-- the tag is appended here so the renderer and the pushed image agree.
module Nagare.Image
  ( computeTag
  , buildImage
  , dockerBuildArgs
  , buildDockerfile
  , nixpacksBuildArgs
  , buildNixpacks
  , configureDockerAuth
  , dockerAuthPlan
  , DockerAuth (..)
  , pushImage
  , imageRef
  , taggedImageRef
  , qualifyImage
  ) where

import Nagare.Dsl.Prelude

import Data.Generics.Labels ()

import Cradle
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Dsl.Types (Deployment, ImageRef, imageRefText, mkImageRef)
import Nagare.Target (Mode (..), TargetProfile, registryPrefix, resolveTargetProfile, tpMode, tpRegistryHost)

-- | Compute a deploy tag: UTC timestamp in @YYYYMMDD-HHMMSS@ format.
computeTag :: IO Text
computeTag = do
  now <- getCurrentTime
  pure (T.pack (formatTime defaultTimeLocale "%Y%m%d-%H%M%S" now))

-- | The full image reference for a deployment, e.g.
-- @"gcr.io/knative-samples/helloworld-go:20260602-120000"@. The repository
-- path is read from the deployment's 'Nagare.Dsl.Types.ImageRef'; the @tag@ is
-- the value 'computeTag' (or @--tag@) produced.
imageRef :: Deployment -> Text -> Text
imageRef dep tag = taggedImageRef (dep ^. #image) tag

-- | The full image reference for any 'ImageRef' and tag, e.g.
-- @"gcr.io/foo/bar" + "20260607-120000" -> "gcr.io/foo/bar:20260607-120000"@.
-- The runtime-agnostic form used by both the app deploy ('imageRef') and the
-- static/server site deploy paths.
taggedImageRef :: ImageRef -> Text -> Text
taggedImageRef ref tag = imageRefText ref <> ":" <> tag

-- | Run @docker build -t \<image:tag\> \<context\>@.
-- The @context@ argument is the build-context directory (typically @"."@).
-- Retained for the static/server site deploy paths; the app deploy uses
-- 'buildDockerfile' so it can honor a configured Dockerfile path and build args.
buildImage :: Text -> FilePath -> IO ()
buildImage ref context =
  run_ $ cmd "docker" & addArgs ["build", "-t", T.unpack ref, context]

-- | The argument vector for @docker build@ with an explicit target platform,
-- Dockerfile, build args, tag, and context. Pure so it can be unit-tested without
-- Docker. The explicit @--platform@ (EP-3) places the built image on the cluster
-- node's architecture and overrides any stale @DOCKER_DEFAULT_PLATFORM@. Build
-- args are emitted in the given order, each as @--build-arg KEY=VALUE@.
dockerBuildArgs :: Text -> Text -> FilePath -> FilePath -> [(Text, Text)] -> [String]
dockerBuildArgs platform ref dockerfile context args =
  ["build", "--platform", T.unpack platform, "-f", dockerfile, "-t", T.unpack ref]
    <> concatMap (\(k, v) -> ["--build-arg", T.unpack (k <> "=" <> v)]) args
    <> [context]

-- | Run @docker build@ with an explicit target platform, Dockerfile path, build
-- args, and context (see 'dockerBuildArgs' for the exact argument vector).
buildDockerfile :: Text -> Text -> FilePath -> FilePath -> [(Text, Text)] -> IO ()
buildDockerfile platform ref dockerfile context args =
  run_ $ cmd "docker" & addArgs (dockerBuildArgs platform ref dockerfile context args)

-- | The argument vector for @nixpacks build@: build the @context@ directory and
-- locally tag the result @ref@, passing each build arg as a Nixpacks build-time
-- environment variable (@--env KEY=VALUE@ — Nixpacks has no @--build-arg@). Pure
-- so it can be unit-tested without Nixpacks. The exact flags (@--name@/@--env@)
-- were validated by the EP-21 feasibility spike (see
-- @docs/spikes/ep21-nixpacks-spike.md@). @nixpacks build@ builds and tags but
-- does not push — the caller pushes @ref@ afterward, exactly like the Dockerfile
-- path.
nixpacksBuildArgs :: Text -> Text -> FilePath -> [(Text, Text)] -> [String]
nixpacksBuildArgs platform ref context args =
  ["build", context, "--platform", T.unpack platform, "--name", T.unpack ref]
    <> concatMap (\(k, v) -> ["--env", T.unpack (k <> "=" <> v)]) args

-- | Run @nixpacks build@ to produce and locally tag the image @ref@ from a
-- Dockerfile-free source tree (see 'nixpacksBuildArgs'). The single-platform
-- @--platform@ (EP-3) needs no buildx driver.
buildNixpacks :: Text -> Text -> FilePath -> [(Text, Text)] -> IO ()
buildNixpacks platform ref context args =
  run_ $ cmd "nixpacks" & addArgs (nixpacksBuildArgs platform ref context args)

-- | The Docker-credential action for a given mode and registry host (EP-83,
-- MasterPlan 16 Integration Point 2). In 'Cloud' mode it is the
-- @gcloud auth configure-docker \<host> --quiet@ argv that teaches Docker to
-- authenticate to Google Artifact Registry. In 'Local' mode it is 'SkipDockerAuth':
-- the EP-82 local registry is unauthenticated, so no credential helper — and in
-- particular no @gcloud@ — is invoked. Pure so a test can assert the argv is built
-- in cloud mode and never built in local mode, with neither Docker nor gcloud
-- installed.
data DockerAuth
  = SkipDockerAuth
  | GcloudConfigureDocker [String]
  deriving stock (Eq, Show)

dockerAuthPlan :: Mode -> Text -> DockerAuth
dockerAuthPlan Local _ = SkipDockerAuth
dockerAuthPlan Cloud host =
  GcloudConfigureDocker ["auth", "configure-docker", T.unpack host, "--quiet"]

-- | Configure Docker auth for the resolved target (EP-62, EP-83). In cloud mode this
-- runs @gcloud auth configure-docker \<host> --quiet@ so a subsequent @docker push@
-- authenticates to Artifact Registry. In local mode (@NAGARE_MODE=local@, EP-82) it
-- is a no-op: the local k3d registry needs no credential helper and no @gcloud@ is
-- invoked. Resolves the profile internally so all call sites are unchanged.
configureDockerAuth :: IO ()
configureDockerAuth = do
  tp <- resolveTargetProfile
  case dockerAuthPlan (tpMode tp) (tpRegistryHost tp) of
    SkipDockerAuth -> pure ()
    GcloudConfigureDocker args -> run_ $ cmd "gcloud" & addArgs args

-- | Run @docker push \<image:tag\>@.
pushImage :: Text -> IO ()
pushImage ref =
  run_ $ cmd "docker" & addArgs ["push", T.unpack ref]

-- | Qualify a loaded image reference against the resolved target profile (EP-62
-- M3, MasterPlan 12 Integration Point 4). A bare NAME (no @\/@) — what a
-- name-only @Config.hs@ emits — is prefixed with @registryPrefix tp@
-- (@\<host>/\<project>/\<repo-id>@). An already-qualified ref (one containing a
-- @\/@, e.g. a public @gcr.io/...@ image or a pre-prefixed Artifact Registry
-- path) is returned unchanged, preserving back-compat. Apply this once at the
-- deploy load boundary so the build/push/render sites see the qualified ref.
qualifyImage :: TargetProfile -> ImageRef -> Either Text ImageRef
qualifyImage tp ref =
  let t = imageRefText ref
   in if T.any (== '/') t
        then Right ref
        else mkImageRef (registryPrefix tp <> "/" <> t)
