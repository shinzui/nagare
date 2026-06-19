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

    -- * Machine-readable plan (EP-2 M3, the kotei contract)
  , RenderedObject (..)
  , AppDeployPlan (..)
  , renderPlan
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import Data.Generics.Labels ()

import Control.Monad (forM_)
import Data.Aeson (ToJSON (..), Value (Object, String), encode, object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Yaml qualified as Yaml
import System.Exit (exitFailure)
import System.IO (stderr)

import Nagare.Deploy.Resolve (resolveTag)
import Nagare.Dsl.Application (Application (..))
import Nagare.Dsl.Build (BuildSpec, resolveImageTag)
import Nagare.Dsl.Database (Database)
import Nagare.Dsl.Database.Render (renderDatabase)
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
renderPhaseObjects env (PhaseDatabases dbs) = concatMap (renderDatabaseObjects env) dbs
renderPhaseObjects env (PhaseService svc) = renderServiceObjects env svc
renderPhaseObjects env (PhaseWorkers ws) = concatMap (renderWorkerObjects env) ws

-- | Render a managed database's manifests (PVC, optional ConfigMap, Service,
-- StatefulSet) and stamp the app label. The database keeps its OWN engine image
-- (it is not the shared app image), so no image/env flow-down applies.
renderDatabaseObjects :: RolloutEnv -> Database -> [(Text, ByteString)]
renderDatabaseObjects env db = map (stamp env "database") (renderDatabase db)

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
-- Machine-readable plan (the kotei contract, EP-2 M3)

-- | One rendered object in a deploy plan. The flat shape (with an explicit
-- @phase@) lets the kotei backend enumerate an app's resources and read each
-- object's @nagare.dev/app@ label without parsing YAML or human prose. The
-- contract is additive: consumers ignore unknown keys.
data RenderedObject = RenderedObject
  { roApiVersion :: !Text
  , roKind :: !Text
  , roName :: !Text
  , roNamespace :: !Text
  , roPhase :: !Text
  -- ^ @"hook" | "database" | "service" | "worker"@.
  , roLabels :: !(Map Text Text)
  , roManifest :: !Text
  -- ^ the exact rendered YAML document.
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON RenderedObject where
  toJSON o =
    object
      [ "apiVersion" .= roApiVersion o
      , "kind" .= roKind o
      , "name" .= roName o
      , "namespace" .= roNamespace o
      , "phase" .= roPhase o
      , "labels" .= roLabels o
      , "manifest" .= roManifest o
      ]

-- | The whole rollout plan: the app identity, the resolved tagged image every
-- workload runs, and the ordered object list (rollout-phase order).
data AppDeployPlan = AppDeployPlan
  { adpApp :: !Text
  , adpImage :: !Text
  , adpObjects :: ![RenderedObject]
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON AppDeployPlan where
  toJSON p =
    object
      [ "app" .= adpApp p
      , "image" .= adpImage p
      , "objects" .= adpObjects p
      ]

-- | Build the machine-readable plan from the rendered, label-stamped objects.
-- Each 'RenderedObject'\'s metadata is parsed back from its stamped manifest, so
-- the JSON's labels and the YAML's labels cannot drift.
renderPlan :: RolloutEnv -> Application -> AppDeployPlan
renderPlan env app =
  AppDeployPlan
    { adpApp = reAppName env
    , adpImage = reAppImageTagged env
    , adpObjects = [toRenderedObject ph bs | (ph, bs) <- renderAppObjects env app]
    }

-- | Parse a rendered manifest's identity (apiVersion/kind/name/namespace/labels)
-- back out of its YAML for the JSON plan. A manifest that fails to parse yields
-- empty fields rather than throwing (our own renderers always produce valid YAML).
toRenderedObject :: Text -> ByteString -> RenderedObject
toRenderedObject ph bs =
  RenderedObject
    { roApiVersion = str "apiVersion" top
    , roKind = str "kind" top
    , roName = str "name" meta
    , roNamespace = str "namespace" meta
    , roPhase = ph
    , roLabels = labels
    , roManifest = TE.decodeUtf8 bs
    }
  where
    top = case Yaml.decodeEither' bs of
      Right (Object o) -> o
      _ -> KM.empty
    meta = case KM.lookup "metadata" top of
      Just (Object o) -> o
      _ -> KM.empty
    labels = case KM.lookup "labels" meta of
      Just (Object o) -> Map.fromList [(K.toText k, v) | (k, String v) <- KM.toList o]
      _ -> Map.empty
    str k o = case KM.lookup (K.fromText k) o of
      Just (String s) -> s
      _ -> ""

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

  if adpDryRun p
    then
      if adpJson p
        then -- the machine-readable plan: a single JSON document on stdout, nothing else.
          LBS.putStr (encode (renderPlan env app)) >> BC.putStrLn ""
        else do
          forM_ (renderAppObjects env app) $ \(ph, bs) -> do
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
