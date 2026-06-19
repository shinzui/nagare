-- | @nagarectl app deploy@ (MasterPlan 14, EP-2): deploy a whole multi-workload
-- 'Application' — an optional web Service, background Workers, managed Databases,
-- and pre-deploy migration Tasks — with ONE command, in dependency order, under
-- one shared identity.
--
-- This module is the orchestration layer above the per-kind deploy paths. It
-- loads an 'Application' (EP-1's 'loadApplication'), qualifies the shared image
-- once, flows the shared env down onto every workload, renders each workload with
-- its EXISTING per-kind renderer, and stamps the shared @nagare.dev/app: \<name\>@
-- label onto every rendered object (the contract the kotei backend reconciles on).
-- The rollout is sequenced into fixed phases — pre-deploy hooks → databases →
-- service → workers — so "migrate before the new code boots" is enforced, not a
-- runbook step (see 'planPhases' / 'runPhases').
--
-- It is a /library/ module: it never imports the @nagarectl@ executable. The
-- deploy resolvers it needs were extracted into "Nagare.Deploy.Resolve" (EP-2 M0)
-- for exactly that reason; @Main@ provisions @GHC_ENVIRONMENT@ before calling
-- 'runAppDeploy'.
module Nagare.App.Deploy
  ( -- * Params and entry point
    AppDeployParams (..)
  , runAppDeploy

    -- * Rollout phases (EP-2 M2)
  , Phase (..)
  , phaseTag
  , planPhases
  , PhaseResult (..)
  , PhaseExec
  , runPhases

    -- * Rendering + the shared-identity label
  , RolloutEnv (..)
  , renderAppObjects
  , stampAppLabel
  ) where

import Nagare.Dsl.Prelude

import Data.Generics.Labels ()

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Map (Map)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Exit (exitFailure)
import System.IO (stderr)

import Nagare.Deploy.Resolve (resolveTag)
import Nagare.Dsl.Application (Application (..))
import Nagare.Dsl.Build (BuildSpec, resolveImageTag)
import Nagare.Dsl.Database (Database)
import Nagare.Dsl.Load (loadApplication, renderLoadError)
import Nagare.Dsl.Render (renderDomainMappings, renderService, renderVolumeClaims)
import Nagare.Dsl.Task (Task, taskName)
import Nagare.Dsl.Types
  ( Deployment
  , EnvName
  , ImageRef
  , ScopedEnvVar
  , imageRefText
  , namespaceText
  , serviceNameText
  )
import Nagare.Dsl.Worker (Worker)
import Nagare.Dsl.Worker.Render (renderWorker)
import Nagare.Env.Generated (mergeGenerated)
import Nagare.Image (qualifyImage)
import Nagare.Target (TargetProfile (..), resolveTargetProfile)
import Nagare.Task.Resolve (predefinedTaskEnv, renderResolvedTask)

-- | The deploy inputs, unpacked from @Main@'s @AppDeployOpts@ so the library does
-- not depend on the executable's option types. @GHC_ENVIRONMENT@ is provisioned
-- by @Main@ before this runs (mirroring @worker deploy@ / @db create --config@).
data AppDeployParams = AppDeployParams
  { adpConfigPath :: !FilePath
  , adpTag :: !(Maybe Text)
  , adpBaseDomain :: !(Maybe Text)
  , adpContextOverride :: !(Maybe FilePath)
  , adpDockerfileOverride :: !(Maybe FilePath)
  , adpDryRun :: !Bool
  , adpJson :: !Bool
  , adpSource :: !(Maybe Text)
  }
  deriving stock (Generic, Show)

-- | The resolved deploy-time context every workload renders against: the app's
-- shared identity, its qualified image, the resolved tags, the shared env to flow
-- down, and the namespace/base-domain. Built once in 'runAppDeploy' so every
-- workload renders the SAME image and tag.
data RolloutEnv = RolloutEnv
  { reAppName :: !Text
  -- ^ the @nagare.dev/app@ value (the 'Application' name).
  , reQualImage :: !ImageRef
  -- ^ the registry-qualified shared image, set on the service and every worker.
  , reImageTag :: !Text
  -- ^ the bare deploy tag (per-workload renderers resolve their own effective tag
  -- from their build spec against this).
  , reEffTag :: !Text
  -- ^ the resolved effective tag for the shared image (from the service's build
  -- spec); used to tag the image a hook Task inherits.
  , reAppImageTagged :: !Text
  -- ^ @\<qualified-image\>:\<effTag\>@ — the exact image string an inheriting hook
  -- Task runs, so the migration runs the app's current code.
  , reAppEnv :: !(Map EnvName ScopedEnvVar)
  -- ^ the shared env declared once on the 'Application', flowed down onto every
  -- workload (a workload's own env wins on a key collision).
  , reNamespace :: !Text
  , reBaseDomain :: !Text
  }
  deriving stock (Generic)

-- ---------------------------------------------------------------------------
-- Rollout phases

-- | One ordered step of a multi-workload rollout. The fixed order
-- ('planPhases') is the only ordering a single-node app needs: migrations and
-- databases must be ready before the serving workloads boot.
data Phase
  = PhaseHooks ![Task]
  -- ^ pre-deploy migration Tasks, each run to completion; a non-zero exit aborts.
  | PhaseDatabases ![Database]
  -- ^ managed databases, ensured (idempotent) with their full specs.
  | PhaseService !Deployment
  -- ^ the request-driven Knative Service (omitted when the app has none).
  | PhaseWorkers ![Worker]
  -- ^ the background workers.
  deriving stock (Generic, Show)

-- | The wire/log tag for a phase: @"hook" | "database" | "service" | "worker"@.
phaseTag :: Phase -> Text
phaseTag (PhaseHooks _) = "hook"
phaseTag (PhaseDatabases _) = "database"
phaseTag (PhaseService _) = "service"
phaseTag (PhaseWorkers _) = "worker"

-- | The fixed rollout plan for an 'Application': hooks, then databases, then the
-- service (when present), then the workers. Empty phases are kept (they are
-- no-ops at run time) so the order is total and easy to test.
planPhases :: Application -> [Phase]
planPhases app =
  [PhaseHooks (app ^. #tasks), PhaseDatabases (app ^. #appDatabases)]
    <> maybe [] (\svc -> [PhaseService svc]) (app ^. #service)
    <> [PhaseWorkers (app ^. #workers)]

-- | The outcome of executing one phase.
data PhaseResult
  = PhaseOk
  | PhaseFailed !Text
  deriving stock (Generic, Eq, Show)

-- | How a single phase is executed. Abstracted so the rollout sequencing
-- ('runPhases') can be unit-tested with a fake executor (no cluster), and so the
-- live executor (build/apply/wait) is the only IO-bearing part.
type PhaseExec = Phase -> IO PhaseResult

-- | Execute phases in order, **aborting on the first failure** so a failed
-- pre-deploy hook prevents any later phase (databases, service, workers) from
-- running. Returns the first failure, or 'PhaseOk' if every phase succeeded.
runPhases :: PhaseExec -> [Phase] -> IO PhaseResult
runPhases exec = go
  where
    go [] = pure PhaseOk
    go (p : ps) = do
      r <- exec p
      case r of
        PhaseOk -> go ps
        failed -> pure failed

-- ---------------------------------------------------------------------------
-- Rendering + the shared-identity label

-- | Render every object an 'Application' produces, in rollout-phase order, each
-- paired with its phase tag and stamped with the shared @nagare.dev/app@ label.
-- Pure (no cluster): the basis of both the human dry-run transcript and the
-- machine-readable @--json@ plan (EP-2 M3). Database manifests are rendered by
-- the database phase in M3; M1 renders hooks, service, and workers.
renderAppObjects :: RolloutEnv -> Application -> [(Text, ByteString)]
renderAppObjects env app =
  concatMap (renderPhaseObjects env) (planPhases app)

-- | The stamped, phase-tagged manifests for one phase.
renderPhaseObjects :: RolloutEnv -> Phase -> [(Text, ByteString)]
renderPhaseObjects env (PhaseHooks ts) = concatMap (renderTaskObjects env) ts
renderPhaseObjects _ (PhaseDatabases _) = [] -- rendered in M3
renderPhaseObjects env (PhaseService svc) = renderServiceObjects env svc
renderPhaseObjects env (PhaseWorkers ws) = concatMap (renderWorkerObjects env) ws

-- | Apply the shared image + shared env to the web service, render its PVCs,
-- Knative Service, and DomainMappings, and stamp the app label on each.
renderServiceObjects :: RolloutEnv -> Deployment -> [(Text, ByteString)]
renderServiceObjects env svc0 =
  map (stamp env "service") (renderVolumeClaims svc <> [renderService svc (reImageTag env)] <> renderDomainMappings svc)
  where
    svc = svc0 & #image .~ reQualImage env & #env %~ flowEnv env

-- | Apply the shared image + shared env to a worker, render its PVCs + Deployment,
-- and stamp the app label on each.
renderWorkerObjects :: RolloutEnv -> Worker -> [(Text, ByteString)]
renderWorkerObjects env w0 =
  map (stamp env "worker") (renderWorker w (reImageTag env))
  where
    w = w0 & #image .~ reQualImage env & #env %~ flowEnv env

-- | Render a pre-deploy hook Task's CronJob with the shared env flowed in and the
-- app's resolved image substituted (an inheriting task runs the app's code), then
-- stamp the app label.
renderTaskObjects :: RolloutEnv -> Task -> [(Text, ByteString)]
renderTaskObjects env t0 =
  [stamp env "hook" (renderResolvedTask (reAppImageTagged env) (reEffTag env) withPredef t)]
  where
    t = t0 & #taskEnv %~ flowEnv env
    withPredef tk = tk & #taskEnv %~ mergeGenerated (predefinedTaskEnv tk)

-- | Merge the app's shared env under a workload's own env (the workload's own
-- entries win on a key collision; 'mergeGenerated' is left-biased).
flowEnv :: RolloutEnv -> Map EnvName ScopedEnvVar -> Map EnvName ScopedEnvVar
flowEnv env own = mergeGenerated own (reAppEnv env)

-- | Tag a rendered manifest with its phase and the app-identity label.
stamp :: RolloutEnv -> Text -> ByteString -> (Text, ByteString)
stamp env ph bs = (ph, stampAppLabel (reAppName env) bs)

-- | Insert @nagare.dev/app: \<name\>@ into a rendered manifest's top-level
-- @metadata.labels@, immediately after the @nagare.dev/managed-by: nagarectl@
-- line every Nagare object carries (so the inserted line shares its indentation
-- and the rest of the document's careful key ordering is preserved byte-for-byte).
-- Idempotent: a manifest that already carries a @nagare.dev/app@ label (e.g. a
-- volume PVC) is left unchanged. Only the FIRST @managed-by@ (the object's own
-- @metadata.labels@, not a nested pod-template) is matched.
stampAppLabel :: Text -> ByteString -> ByteString
stampAppLabel appName bs
  | "nagare.dev/app:" `T.isInfixOf` text = bs
  | otherwise = TE.encodeUtf8 (T.unlines (insertAfterFirst (T.lines text)))
  where
    text = TE.decodeUtf8 bs
    insertAfterFirst [] = []
    insertAfterFirst (l : ls)
      | "nagare.dev/managed-by:" `T.isInfixOf` l =
          l : (T.takeWhile (== ' ') l <> "nagare.dev/app: " <> appName) : ls
      | otherwise = l : insertAfterFirst ls

-- ---------------------------------------------------------------------------
-- Entry point

-- | Run @app deploy@. M1: load the 'Application', qualify the shared image once,
-- and (on @--dry-run@) print every rendered object — each carrying the shared
-- @nagare.dev/app@ label — in rollout order. The live apply path lands in M2/M4.
runAppDeploy :: AppDeployParams -> IO ()
runAppDeploy p = do
  eapp <- loadApplication (adpConfigPath p)
  tp <- resolveTargetProfile
  app <- case eapp of
    Left err -> dieT (renderLoadError err)
    Right a -> pure a
  qImg <- case qualifyImage tp (app ^. #image) of
    Left e -> dieT ("nagarectl app deploy: " <> e)
    Right q -> pure q
  imageTag <- resolveTag (T.unpack <$> adpTag p)

  let effTag = maybe imageTag (\b -> resolveImageTag b imageTag) (buildForTag app)
      env =
        RolloutEnv
          { reAppName = serviceNameText (app ^. #appName)
          , reQualImage = qImg
          , reImageTag = imageTag
          , reEffTag = effTag
          , reAppImageTagged = imageRefText qImg <> ":" <> effTag
          , reAppEnv = app ^. #env
          , reNamespace = namespaceText (app ^. #namespace)
          , reBaseDomain = maybe (tpBaseDomain tp) id (adpBaseDomain p)
          }
      objs = renderAppObjects env app

  if adpDryRun p
    then do
      forM_ objs $ \(ph, bs) -> do
        TIO.putStrLn ("--- " <> ph <> " manifest ---")
        BC.putStr bs
      TIO.putStrLn (summaryLine app env)
    else dieT "nagarectl app deploy: live apply is not yet wired (use --dry-run); see EP-2 M2/M4"

-- | The build spec the shared image's effective tag is resolved against — the
-- service's when the app has a web service, else the first worker's, else
-- 'Nothing' (a prebuilt image, tagged with the bare deploy tag).
buildForTag :: Application -> Maybe BuildSpec
buildForTag app =
  case app ^. #service of
    Just svc -> Just (svc ^. #build)
    Nothing -> case app ^. #workers of
      (w : _) -> Just (w ^. #build)
      [] -> Nothing

-- | A one-line human summary of what would be deployed.
summaryLine :: Application -> RolloutEnv -> Text
summaryLine app env =
  "Would deploy app '"
    <> reAppName env
    <> "' ("
    <> count (length (maybe [] (: []) (app ^. #service))) "service"
    <> ", "
    <> count (length (app ^. #workers)) "worker"
    <> ", "
    <> count (length (app ^. #appDatabases)) "database"
    <> ", "
    <> count (length (app ^. #tasks)) "hook"
    <> ") to namespace "
    <> reNamespace env
  where
    count n noun = T.pack (show n) <> " " <> noun <> (if n == 1 then "" else "s")

dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
