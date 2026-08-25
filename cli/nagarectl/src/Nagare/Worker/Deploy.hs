-- | @nagarectl worker deploy@ (EP-71): build, push, and run a long-running
-- worker from the current directory. A worker is an @apps/v1@ Deployment, not a
-- Knative Service, so this path renders no Service/DomainMapping and gates on a
-- Deployment rollout ('waitForWorkerRollout'), not a @ksvc@ readiness wait. It
-- has no URL, so it never calls 'Nagare.Deploy.serviceUrl'.
--
-- The build/push half reuses the /same/ machinery the request-driven app deploy
-- uses — 'qualifyImage' (registry-prefix a bare image name), the @--context@/
-- @--dockerfile@ overrides ('applyBuildOverrides'), 'gatherBuildArgs' (Build-
-- scoped env → @--build-arg@), 'performBuild'/'pushImage' — because a worker
-- reuses 'Nagare.Dsl.Build.BuildSpec' verbatim. Rendering and applying reuse
-- 'renderWorker', 'applyPVCs', and 'applyManifests'.
module Nagare.Worker.Deploy
  ( WorkerDeployParams (..)
  , runWorkerDeploy
  )
where

import Control.Monad (forM_)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Build (addBuildArgs, applyBuildOverrides, describeBuild, performBuild)
import Nagare.Deploy (applyManifests, applyPVCs, requireWait, waitForWorkerRollout)
import Nagare.Deploy.Resolve (resolveBrokerEnv)
import Nagare.Dsl.Build (BuildSpec, requiresBuild, resolveImageTag)
import Nagare.Dsl.Load (loadWorker, renderLoadError)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (imageRefText, namespaceText, serviceNameText)
import Nagare.Dsl.Worker (Worker, replicasInt)
import Nagare.Dsl.Worker.Render (renderWorker, workerDeploymentName)
import Nagare.Env.BuildArgs (gatherBuildArgs, printBuildArgWarnings)
import Nagare.Env.Generated (mergeGenerated)
import Nagare.Image (computeTag, configureDockerAuthFor, pushImage, qualifyImage, taggedImageRef)
import Nagare.Target (TargetProfile (..))
import System.Exit (exitFailure)
import System.IO (stderr)

-- | The deploy inputs, unpacked from @Main@'s @WorkerDeployOpts@ so the library
-- does not depend on the executable's option types. The GHC environment is
-- provisioned by @Main@ before this runs (mirroring @db create --config@).
data WorkerDeployParams = WorkerDeployParams
  { wdpConfigPath :: !FilePath
  -- ^ path to the worker's @Config.hs@ (default @nagare/Config.hs@).
  , wdpTag :: !(Maybe Text)
  -- ^ explicit deploy tag; 'Nothing' computes a UTC timestamp.
  , wdpContextOverride :: !(Maybe FilePath)
  , wdpDockerfileOverride :: !(Maybe FilePath)
  , wdpDryRun :: !Bool
  -- ^ print the manifests and the build mode; apply nothing.
  , wdpTargetProfile :: !TargetProfile
  }
  deriving stock (Generic, Show)

-- | Run @worker deploy@.
runWorkerDeploy :: WorkerDeployParams -> IO ()
runWorkerDeploy params = do
  eWorker <- loadWorker (wdpConfigPath params)
  let tp = wdpTargetProfile params
  worker <- case eWorker of
    Left err -> dieT (renderLoadError err)
    -- EP-62 M3: a name-only image (no '/') is qualified with the resolved
    -- registry prefix; a fully-qualified ref is left untouched.
    Right w -> case qualifyImage tp (w ^. #image) of
      Left e -> dieT ("nagarectl worker deploy: " <> e)
      Right qimg -> pure (w & #image %~ const qimg)

  imageTag <- maybe computeTag pure (wdpTag params)
  spec <- orDie (applyBuildOverrides (wdpContextOverride params) (wdpDockerfileOverride params) (worker ^. #build))
  brokerEnv <- resolveBrokerEnv (worker ^. #namespace) (worker ^. #brokers)

  let worker' = worker & #env %~ mergeGenerated brokerEnv
      effTag = resolveImageTag spec imageTag
      ref = taggedImageRef (worker' ^. #image) effTag
      name = serviceNameText (worker' ^. #name)
      ns = namespaceText (worker' ^. #namespace)
      replicaCount = replicasInt (worker ^. #replicas)
      -- renderWorker resolves the tag itself; the PVCs (if any) head the list and
      -- the Deployment is its last element (mirrors how the app deploy splits
      -- renderVolumeClaims from renderService).
      manifests = renderWorker worker' imageTag
      (pvcBytes, depBytes) = splitLast manifests

  if wdpDryRun params
    then do
      forM_ pvcBytes $ \pvc -> do
        TIO.putStrLn "--- PersistentVolumeClaim manifest ---"
        TIO.putStr (TE.decodeUtf8 pvc)
      TIO.putStrLn "--- Deployment manifest ---"
      mapM_ (TIO.putStr . TE.decodeUtf8) depBytes
      TIO.putStrLn ("Build mode: " <> describeBuild (tpTargetPlatform tp) spec)
      TIO.putStrLn
        ( "Would apply apps/v1 Deployment "
            <> workerDeploymentName name
            <> " to namespace "
            <> ns
            <> " ("
            <> T.pack (show replicaCount)
            <> " replicas)"
        )
    else do
      if requiresBuild spec
        then buildAndPush tp worker' name ns spec ref
        else TIO.putStrLn "Skipping build/push: deploying prebuilt image."
      -- PVCs first (no-op when empty; local-path is WaitForFirstConsumer), then
      -- the Deployment.
      applyPVCs pvcBytes
      applyManifests depBytes
      waitForWorkerRollout ns name >>= requireWait ("worker '" <> name <> "'")
      TIO.putStrLn
        ( "Worker "
            <> name
            <> " is running ("
            <> T.pack (show replicaCount)
            <> " replicas requested) in namespace "
            <> ns
            <> "."
        )
      TIO.putStrLn ("Inspect: kubectl get deployment " <> name <> " -n " <> ns)

-- | Build the worker image with the app deploy's Build-scoped env as
-- @--build-arg@s, then push it. Identical to the request-driven deploy's build
-- half (the worker reuses 'BuildSpec'), so it is the same code path.
buildAndPush :: TargetProfile -> Worker -> Text -> Text -> BuildSpec -> Text -> IO ()
buildAndPush tp worker name ns spec ref = do
  (bargs, warns) <- gatherBuildArgs name ns (worker ^. #env)
  printBuildArgWarnings warns
  configureDockerAuthFor tp
  performBuild (tpTargetPlatform tp) (addBuildArgs bargs spec) ref
  pushImage ref

-- | Split a non-empty manifest list into (all-but-last, [last]). For a
-- volume-free worker @manifests@ is just @[deployment]@, so this is
-- @([], [deployment])@. Defensive on the (impossible) empty list.
splitLast :: [a] -> ([a], [a])
splitLast [] = ([], [])
splitLast xs = (init xs, [last xs])

dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure

orDie :: Either Text a -> IO a
orDie = either dieT pure
