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
  , waitResult

    -- * Rendering + the shared-identity label
  , RolloutEnv (..)
  , renderAppObjects
  , renderServiceObjects
  , stampAppLabel

    -- * Machine-readable plan (EP-2 M3, the kotei contract)
  , RenderedObject (..)
  , AppDeployPlan (..)
  , renderPlan
  )
where

import Control.Monad (forM_, when)
import Cradle (StdoutUntrimmed (..), addArgs, cmd, run, run_, silenceStderr, (&))
import Data.Aeson (ToJSON (..), Value (Object, String), encode, object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Yaml qualified as Yaml
import Nagare.Access.Resolve (resolveDeploymentAccess)
import Nagare.Build (addBuildArgs, performBuild)
import Nagare.Cluster.Namespace (NamespacePurpose (..), ensureNamespace, renderNamespace)
import Nagare.Database.Create (DbCreateParams (..), runDbCreate)
import Nagare.Database.Backup (renderDbBackupCronJob)
import Nagare.Deploy (applyManifests, waitForReady, waitForWorkerRollout)
import Nagare.Deploy.Resolve (resolveBrokerEnv, resolveBuildSpec, resolveTag)
import Nagare.Dsl.Application (Application (..))
import Nagare.Dsl.Build (BuildSpec, requiresBuild, resolveImageTag)
import Nagare.Dsl.Database (Database (..), engineVersionText)
import Nagare.Dsl.Database.Render (databaseCredentialTemplate, renderDatabase)
import Nagare.Dsl.Load (loadApplication, renderLoadError)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Render (renderDomainMappings, renderService, renderVolumeClaims)
import Nagare.Dsl.Task (Task)
import Nagare.Dsl.Types
  ( Deployment
  , EnvName
  , ImageRef
  , ScopedEnvVar
  , RetentionPolicy (Delete)
  , databaseNameText
  , imageRefText
  , namespaceText
  , quantityText
  , serviceNameText
  )
import Nagare.Dsl.Worker (Worker)
import Nagare.Dsl.Worker.Render (renderWorker)
import Nagare.Env.BuildArgs (gatherBuildArgs, printBuildArgWarnings)
import Nagare.Env.Generated (mergeGenerated)
import Nagare.Image (configureDockerAuthFor, pushImage, qualifyImage, taggedImageRef)
import Nagare.Target (TargetProfile (..), storeBackendFor)
import Nagare.Task.Resolve (predefinedTaskEnv, renderResolvedTask)
import Nagare.Task.Run (oneOffJobName, runArgs)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (stderr)

-- | The deploy inputs, unpacked from @Main@'s @AppDeployOpts@ so the library does
-- not depend on the executable's option types. @GHC_ENVIRONMENT@ is provisioned
-- by @Main@ before this runs (mirroring @worker deploy@ / @db create --config@).
data AppDeployParams = AppDeployParams
  { configPath :: !FilePath
  , tag :: !(Maybe Text)
  , baseDomain :: !(Maybe Text)
  , contextOverride :: !(Maybe FilePath)
  , dockerfileOverride :: !(Maybe FilePath)
  , dryRun :: !Bool
  , json :: !Bool
  , source :: !(Maybe Text)
  , targetProfile :: !TargetProfile
  }
  deriving stock (Generic, Show)

-- | The resolved deploy-time context every workload renders against: the app's
-- shared identity, its qualified image, the resolved tags, the shared env to flow
-- down, and the namespace/base-domain. Built once in 'runAppDeploy' so every
-- workload renders the SAME image and tag.
data RolloutEnv = RolloutEnv
  { appName :: !Text
  -- ^ the @nagare.dev/app@ value (the 'Application' name).
  , qualifiedImage :: !ImageRef
  -- ^ the registry-qualified shared image, set on the service and every worker.
  , imageTag :: !Text
  -- ^ the bare deploy tag (per-workload renderers resolve their own effective tag
  -- from their build spec against this).
  , effectiveTag :: !Text
  -- ^ the resolved effective tag for the shared image (from the service's build
  -- spec); used to tag the image a hook Task inherits.
  , taggedAppImage :: !Text
  -- ^ @\<qualified-image\>:\<effTag\>@ — the exact image string an inheriting hook
  -- Task runs, so the migration runs the app's current code.
  , appEnv :: !(Map EnvName ScopedEnvVar)
  -- ^ the shared env declared once on the 'Application', flowed down onto every
  -- workload (a workload's own env wins on a key collision).
  , namespace :: !Text
  , baseDomain :: !Text
  , targetProfile :: !TargetProfile
  }
  deriving stock (Generic)

-- ---------------------------------------------------------------------------
-- Rollout phases

-- | One ordered step of a multi-workload rollout. The fixed order
-- ('planPhases') is the only ordering a single-node app needs: migrations and
-- databases must be ready before the serving workloads boot.
data Phase
  = -- | pre-deploy migration Tasks, each run to completion; a non-zero exit aborts.
    PhaseHooks ![Task]
  | -- | managed databases, ensured (idempotent) with their full specs.
    PhaseDatabases ![Database]
  | -- | the request-driven Knative Service (omitted when the app has none).
    PhaseService !Deployment
  | -- | the background workers.
    PhaseWorkers ![Worker]
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
  [PhaseHooks (app ^. #tasks), PhaseDatabases (app ^. #databases)]
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

-- | Convert a readiness wait's exit code into a phase result, mirroring how
-- 'runHooks' converts 'waitForJobComplete' exit codes.
waitResult :: Text -> ExitCode -> PhaseResult
waitResult _ ExitSuccess = PhaseOk
waitResult what (ExitFailure code) =
  PhaseFailed
    ( what
        <> " did not become Ready within the 300s timeout (kubectl wait exited "
        <> T.pack (show code)
        <> ")"
    )

-- ---------------------------------------------------------------------------
-- Rendering + the shared-identity label

-- | Render every object an 'Application' produces, in rollout-phase order, each
-- paired with its phase tag and stamped with the shared @nagare.dev/app@ label.
-- Pure (no cluster): the basis of both the human dry-run transcript and the
-- machine-readable @--json@ plan. The database phase includes a data-free
-- credential template and the retained database's scheduled backup.
renderAppObjects :: RolloutEnv -> Application -> Either Text [(Text, ByteString)]
renderAppObjects env app = do
  namespace <- renderNamespace ApplicationNamespace (env ^. #namespace)
  objects <- concat <$> traverse (renderPhaseObjects env) (planPhases app)
  pure (("namespace", namespace) : objects)

-- | The stamped, phase-tagged manifests for one phase.
renderPhaseObjects :: RolloutEnv -> Phase -> Either Text [(Text, ByteString)]
renderPhaseObjects env (PhaseHooks ts) = concat <$> traverse (renderTaskObjects env) ts
renderPhaseObjects env (PhaseDatabases dbs) = concat <$> traverse (renderDatabaseObjects env) dbs
renderPhaseObjects env (PhaseService svc) = renderServiceObjects env svc
renderPhaseObjects env (PhaseWorkers ws) = concat <$> traverse (renderWorkerObjects env) ws

-- | Present the full database membership used by the inventory builder. The
-- credential is a data-free template; real secret data is generated only at
-- guarded execution. Retained databases also declare their backup CronJob.
renderDatabaseObjects :: RolloutEnv -> Database -> Either Text [(Text, ByteString)]
renderDatabaseObjects env db = do
  let profile = env ^. #targetProfile
  backend <- storeBackendFor profile (profile ^. #backupBucket)
  let secret = Yaml.encode (databaseCredentialTemplate db)
      backup = renderDbBackupCronJob
        (namespaceText (db ^. #namespace))
        (databaseNameText (db ^. #name))
        (db ^. #engine)
        (engineVersionText (db ^. #version)) backend 7
      members = [secret] <> renderDatabase db
        <> [backup | db ^. #retention /= Delete]
  traverse (stamp env "database") members

-- | Apply the shared image + shared env to the web service, render its PVCs,
-- Knative Service, and DomainMappings, and stamp the app label on each.
renderServiceObjects :: RolloutEnv -> Deployment -> Either Text [(Text, ByteString)]
renderServiceObjects env svc0 =
  traverse
    (stamp env "service")
    (renderVolumeClaims svc <> [renderService svc (env ^. #imageTag)] <> renderDomainMappings svc)
  where
    svc = svc0 & #image .~ (env ^. #qualifiedImage) & #env %~ flowEnv env

-- | Apply the shared image + shared env to a worker, render its PVCs + Deployment,
-- and stamp the app label on each.
renderWorkerObjects :: RolloutEnv -> Worker -> Either Text [(Text, ByteString)]
renderWorkerObjects env w0 =
  traverse (stamp env "worker") (renderWorker w (env ^. #imageTag))
  where
    w = w0 & #image .~ (env ^. #qualifiedImage) & #env %~ flowEnv env

-- | Render a pre-deploy hook Task's CronJob with the shared env flowed in and the
-- app's resolved image substituted (an inheriting task runs the app's code), then
-- stamp the app label.
renderTaskObjects :: RolloutEnv -> Task -> Either Text [(Text, ByteString)]
renderTaskObjects env t0 =
  traverse
    (stamp env "hook")
    [renderResolvedTask (env ^. #taggedAppImage) (env ^. #effectiveTag) withPredef t]
  where
    t = t0 & #env %~ flowEnv env
    withPredef tk = tk & #env %~ mergeGenerated (predefinedTaskEnv tk)

-- | Merge the app's shared env under a workload's own env (the workload's own
-- entries win on a key collision; 'mergeGenerated' is left-biased).
flowEnv :: RolloutEnv -> Map EnvName ScopedEnvVar -> Map EnvName ScopedEnvVar
flowEnv env own = mergeGenerated own (env ^. #appEnv)

-- | Tag a rendered manifest with its phase and the app-identity label.
stamp :: RolloutEnv -> Text -> ByteString -> Either Text (Text, ByteString)
stamp env ph bs = (\stamped -> (ph, stamped)) <$> stampAppLabel (env ^. #appName) bs

-- | Insert @nagare.dev/app: \<name\>@ into a rendered manifest's top-level
-- @metadata.labels@, immediately after the @nagare.dev/managed-by: nagarectl@
-- line every Nagare object carries (so the inserted line shares its indentation
-- and the rest of the document's careful key ordering is preserved byte-for-byte).
-- Idempotent: a manifest that already carries a @nagare.dev/app@ label (e.g. a
-- volume PVC) is left unchanged. Only the FIRST @managed-by@ (the object's own
-- @metadata.labels@, not a nested pod-template) is matched.
stampAppLabel :: Text -> ByteString -> Either Text ByteString
stampAppLabel name bs
  | "nagare.dev/app:" `T.isInfixOf` text = verify bs
  | not ("nagare.dev/managed-by:" `T.isInfixOf` text) =
      Left
        ( describe bs
            <> " has no 'nagare.dev/managed-by:' anchor to stamp nagare.dev/app after"
        )
  | otherwise = verify (TE.encodeUtf8 (T.unlines (insertAfterFirst (T.lines text))))
  where
    text = TE.decodeUtf8 bs
    insertAfterFirst [] = []
    insertAfterFirst (l : ls)
      | "nagare.dev/managed-by:" `T.isInfixOf` l =
          l : (T.takeWhile (== ' ') l <> "nagare.dev/app: " <> name) : ls
      | otherwise = l : insertAfterFirst ls

    verify stamped
      | topLevelAppLabel stamped == Just name = Right stamped
      | otherwise =
          Left
            ( describe bs
                <> ": stamped nagare.dev/app label did not land in metadata.labels"
            )

    topLevelAppLabel stamped =
      case Yaml.decodeEither' stamped of
        Right (Object top) -> do
          Object metadata <- KM.lookup "metadata" top
          Object labels <- KM.lookup "labels" metadata
          String value <- KM.lookup "nagare.dev/app" labels
          pure value
        _ -> Nothing

    describe rendered =
      let obj = toRenderedObject "" rendered
       in case (obj ^. #kind, obj ^. #name) of
            ("", "") -> "rendered manifest"
            (kind, "") -> kind
            (kind, name) -> kind <> " '" <> name <> "'"

-- ---------------------------------------------------------------------------
-- Machine-readable plan (the kotei contract, EP-2 M3)

-- | One rendered object in a deploy plan. The flat shape (with an explicit
-- @phase@) lets the kotei backend enumerate an app's resources and read each
-- object's @nagare.dev/app@ label without parsing YAML or human prose. The
-- contract is additive: consumers ignore unknown keys.
data RenderedObject = RenderedObject
  { apiVersion :: !Text
  , kind :: !Text
  , name :: !Text
  , namespace :: !Text
  , phase :: !Text
  -- ^ @"hook" | "database" | "service" | "worker"@.
  , labels :: !(Map Text Text)
  , manifest :: !Text
  -- ^ the exact rendered YAML document.
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON RenderedObject where
  toJSON o =
    object
      [ "apiVersion" .= (o ^. #apiVersion)
      , "kind" .= (o ^. #kind)
      , "name" .= (o ^. #name)
      , "namespace" .= (o ^. #namespace)
      , "phase" .= (o ^. #phase)
      , "labels" .= (o ^. #labels)
      , "manifest" .= (o ^. #manifest)
      ]

-- | The whole rollout plan: the app identity, the resolved tagged image every
-- workload runs, and the ordered object list (rollout-phase order).
data AppDeployPlan = AppDeployPlan
  { app :: !Text
  , image :: !Text
  , objects :: ![RenderedObject]
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON AppDeployPlan where
  toJSON p =
    object
      [ "app" .= (p ^. #app)
      , "image" .= (p ^. #image)
      , "objects" .= (p ^. #objects)
      ]

-- | Build the machine-readable plan from the rendered, label-stamped objects.
-- Each 'RenderedObject'\'s metadata is parsed back from its stamped manifest, so
-- the JSON's labels and the YAML's labels cannot drift.
renderPlan :: RolloutEnv -> Application -> Either Text AppDeployPlan
renderPlan env app = do
  objects <- renderAppObjects env app
  pure
    AppDeployPlan
      { app = env ^. #appName
      , image = env ^. #taggedAppImage
      , objects = [toRenderedObject ph bs | (ph, bs) <- objects]
      }

-- | Parse a rendered manifest's identity (apiVersion/kind/name/namespace/labels)
-- back out of its YAML for the JSON plan. A manifest that fails to parse yields
-- empty fields rather than throwing (our own renderers always produce valid YAML).
toRenderedObject :: Text -> ByteString -> RenderedObject
toRenderedObject ph bs =
  RenderedObject
    { apiVersion = str "apiVersion" top
    , kind = str "kind" top
    , name = str "name" meta
    , namespace = str "namespace" meta
    , phase = ph
    , labels = labels
    , manifest = TE.decodeUtf8 bs
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
  eapp <- loadApplication (p ^. #configPath)
  let tp = p ^. #targetProfile
  app <- case eapp of
    Left err -> dieT (renderLoadError err)
    Right a -> pure a
  qImg <- case qualifyImage tp (app ^. #image) of
    Left e -> dieT ("nagarectl app deploy: " <> e)
    Right q -> pure q
  imageTag <- resolveTag (T.unpack <$> p ^. #tag)
  brokerEnv <- resolveBrokerEnv (app ^. #namespace) (app ^. #brokers)

  let effTag = maybe imageTag (\b -> resolveImageTag b imageTag) (buildForTag app)
      env =
        RolloutEnv
          { appName = serviceNameText (app ^. #name)
          , qualifiedImage = qImg
          , imageTag = imageTag
          , effectiveTag = effTag
          , taggedAppImage = imageRefText qImg <> ":" <> effTag
          , appEnv = mergeGenerated brokerEnv (app ^. #env)
          , namespace = namespaceText (app ^. #namespace)
          , baseDomain = fromMaybe (tp ^. #baseDomain) (p ^. #baseDomain)
          , targetProfile = tp
          }

  if p ^. #dryRun
    then
      if p ^. #json
        then do
          -- The machine-readable plan: a single JSON document on stdout, nothing else.
          plan <- requireRendered (renderPlan env app)
          LBS.putStr (encode plan) >> BC.putStrLn ""
        else do
          objects <- requireRendered (renderAppObjects env app)
          forM_ objects $ \(ph, bs) -> do
            TIO.putStrLn ("--- " <> ph <> " manifest ---")
            BC.putStr bs
          TIO.putStrLn (summaryLine app env)
    else liveDeploy p tp env app

-- | The live (non-dry-run) rollout (EP-2 M4): build and push the shared image
-- ONCE, then run the phases in order with the live executor. A failed pre-deploy
-- hook aborts the release before any Service or Worker is applied.
--
-- NOTE: live acceptance is deferred while @nagare-01@ is @TERMINATED@; this path
-- is exercised structurally by the 'runPhases' unit tests (sequencing + hook
-- gating). Per-database connection-env and the generated @NAGARE_*@ vars that the
-- single-Service @deploy@ injects are a documented follow-up for the live path
-- (they need a cluster to resolve); the dry-run and live paths render identically.
liveDeploy :: AppDeployParams -> TargetProfile -> RolloutEnv -> Application -> IO ()
liveDeploy p tp env app = do
  ensureNamespace ApplicationNamespace (env ^. #namespace) >>= requireRendered
  buildAndPushShared p tp env app
  result <- runPhases (livePhaseExec env) (planPhases app)
  case result of
    PhaseFailed msg -> dieT ("nagarectl app deploy: " <> msg)
    PhaseOk -> do
      reportPVCsNote
      TIO.putStrLn ("Deployed app '" <> env ^. #appName <> "' to namespace " <> env ^. #namespace <> ".")
  where
    reportPVCsNote = pure ()

-- | Build and push the shared image once (skipped for a prebuilt image), using
-- the same build half as @deploy@/@worker deploy@: the app's Build-scoped env
-- becomes @--build-arg@s. The image is built against the build spec of the
-- workload that owns it ('buildForTag').
buildAndPushShared :: AppDeployParams -> TargetProfile -> RolloutEnv -> Application -> IO ()
buildAndPushShared p tp env app =
  case buildForTag app of
    Nothing -> TIO.putStrLn "Skipping build/push: app declares a prebuilt image."
    Just b0 -> do
      spec <- resolveBuildSpec (p ^. #contextOverride) (p ^. #dockerfileOverride) b0
      if requiresBuild spec
        then do
          let ref = taggedImageRef (env ^. #qualifiedImage) (env ^. #effectiveTag)
          (bargs, warns) <- gatherBuildArgs (env ^. #appName) (env ^. #namespace) (app ^. #env)
          printBuildArgWarnings warns
          configureDockerAuthFor tp
          performBuild (tp ^. #targetPlatform) (addBuildArgs bargs spec) ref
          pushImage ref
        else TIO.putStrLn "Skipping build/push: app declares a prebuilt image."

-- | Execute one rollout phase against the cluster, returning 'PhaseFailed' on a
-- failed pre-deploy hook so 'runPhases' aborts before any later phase.
livePhaseExec :: RolloutEnv -> PhaseExec
livePhaseExec env = \case
  PhaseHooks ts -> runHooks env ts
  PhaseDatabases dbs -> mapM_ (ensureDatabase env) dbs >> pure PhaseOk
  PhaseService svc -> applyServicePhase env svc
  PhaseWorkers ws -> runWorkers ws
  where
    runWorkers [] = pure PhaseOk
    runWorkers (w : rest) = do
      result <- applyWorkerPhase env w
      case result of
        PhaseOk -> runWorkers rest
        failed -> pure failed

-- | Run each pre-deploy hook Task to completion. Apply its CronJob (so a Job can
-- be created from it), create a one-off Job, and wait for it to complete. The
-- FIRST non-zero exit returns 'PhaseFailed', so no database/service/worker phase
-- runs after a failed migration.
runHooks :: RolloutEnv -> [Task] -> IO PhaseResult
runHooks env = go
  where
    go [] = pure PhaseOk
    go (t : rest) = do
      objects <- requireRendered (renderTaskObjects env t)
      applyManifests (map snd objects)
      now <- getCurrentTime
      let task = serviceNameText (t ^. #name)
          ns = env ^. #namespace
          name = oneOffJobName task now
      TIO.putStrLn ("Running pre-deploy hook '" <> task <> "' (" <> name <> ") ...")
      run_ $ cmd "kubectl" & addArgs (runArgs ns task name)
      code <- waitForJobComplete ns name
      case code of
        ExitSuccess -> TIO.putStrLn ("Hook '" <> task <> "' completed.") >> go rest
        ExitFailure _ -> do
          run_ $ cmd "kubectl" & addArgs ["logs", "job/" <> T.unpack name, "-n", T.unpack ns, "--tail", "50"]
          pure (PhaseFailed ("pre-deploy hook '" <> task <> "' did not complete (" <> name <> ")"))

-- | Wait for a Job to reach @condition=complete@; returns its exit code.
waitForJobComplete :: Text -> Text -> IO ExitCode
waitForJobComplete ns name = do
  (code, _ :: StdoutUntrimmed) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "wait"
          , "--for=condition=complete"
          , "--timeout=600s"
          , "job/" <> T.unpack name
          , "-n"
          , T.unpack ns
          ]
        & silenceStderr
  pure code

-- | Ensure a managed database exists (idempotent), reconstructing the create
-- params from its full spec. @runDbCreate@ applies the PVC/StatefulSet/Service
-- and waits for the StatefulSet rollout.
ensureDatabase :: RolloutEnv -> Database -> IO ()
ensureDatabase env db =
  runDbCreate
    (db ^. #engine)
    (databaseNameText (db ^. #name))
    DbCreateParams
      { namespace = namespaceText (db ^. #namespace)
      , namespacePurpose = ApplicationNamespace
      , version = Just (engineVersionText (db ^. #version))
      , size = Just (quantityText (db ^. #size))
      , cpu = fmap quantityText (db ^. #resources >>= (^. #cpuLimit))
      , memory = fmap quantityText (db ^. #resources >>= (^. #memoryLimit))
      , config = Nothing
      , dryRun = False
      , targetProfile = env ^. #targetProfile
      }

-- | Apply the web Service (PVCs first, then the Service and DomainMappings) and
-- wait for it to become Ready.
applyServicePhase :: RolloutEnv -> Deployment -> IO PhaseResult
applyServicePhase env svc = do
  objects <- requireRendered (renderServiceObjects env svc)
  applyManifests (map snd objects)
  let name = serviceNameText (svc ^. #name)
  code <- waitForReady name (env ^. #namespace)
  case waitResult ("service '" <> name <> "'") code of
    PhaseOk -> resolveDeploymentAccess (env ^. #baseDomain) svc >> pure PhaseOk
    failed -> pure failed

-- | Apply one Worker (PVCs first, then the Deployment) and wait for the rollout.
applyWorkerPhase :: RolloutEnv -> Worker -> IO PhaseResult
applyWorkerPhase env w = do
  objects <- requireRendered (renderWorkerObjects env w)
  applyManifests (map snd objects)
  let name = serviceNameText (w ^. #name)
  code <- waitForWorkerRollout (env ^. #namespace) name
  pure (waitResult ("worker '" <> name <> "'") code)

-- | Turn a pure rendering/stamping failure into the command's normal one-line
-- error at the IO boundary.
requireRendered :: Either Text a -> IO a
requireRendered = either (dieT . ("nagarectl app deploy: " <>)) pure

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
    <> env ^. #appName
    <> "' ("
    <> count (length (maybe [] (: []) (app ^. #service))) "service"
    <> ", "
    <> count (length (app ^. #workers)) "worker"
    <> ", "
    <> count (length (app ^. #databases)) "database"
    <> ", "
    <> count (length (app ^. #tasks)) "hook"
    <> ") to namespace "
    <> env ^. #namespace
  where
    count n noun = T.pack (show n) <> " " <> noun <> (if n == 1 then "" else "s")

dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
