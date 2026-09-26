-- | Shared rendering and rollout identity for a reviewed multi-workload
-- 'Application'. The inventory compiler owns execution and journals its effects.
--
-- This module qualifies the shared image, flows the shared env down onto every
-- workload, renders each workload with its per-kind renderer, and stamps the
-- shared @nagare.dev/app: \<name\>@ label. The inventory compiler consumes
-- these per-member renders and supplies reviewed dependency ordering.
--
-- It is a /library/ module: it never imports the @nagarectl@ executable. The
-- deploy resolvers it needs were extracted into "Nagare.Deploy.Resolve" (EP-2 M0).
module Nagare.App.Deploy
  ( -- * Reviewed rollout inputs
    AppDeployParams (..)
  , resolveAppRolloutWithBrokerEnv

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
  , renderWorkerObjects
  , renderTaskObjects
  , stampAppLabel

    -- * Machine-readable plan (EP-2 M3, the kotei contract)
  , RenderedObject (..)
  , AppDeployPlan (..)
  , renderPlan
  )
where

import Data.Aeson (ToJSON (..), Value (Object, String), object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Yaml qualified as Yaml
import Nagare.Cluster.Namespace (NamespacePurpose (..), renderNamespace)
import Nagare.Database.Backup (renderDbBackupCronJob)
import Nagare.Deploy.Resolve (resolveTag)
import Nagare.Dsl.Application (Application (..))
import Nagare.Dsl.Build (BuildSpec, resolveImageTag)
import Nagare.Dsl.Database (Database (..), engineVersionText)
import Nagare.Dsl.Database.Render (databaseCredentialTemplate, renderDatabase)
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
  , serviceNameText
  )
import Nagare.Dsl.Worker (Worker)
import Nagare.Dsl.Worker.Render (renderWorker)
import Nagare.Env.Generated (mergeGenerated)
import Nagare.Image (qualifyImage)
import Nagare.Target (TargetProfile (..), storeBackendFor)
import Nagare.Task.Resolve (predefinedTaskEnv, renderResolvedTask)
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
-- shared identity, qualified image, resolved tags, shared env, and namespace.
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
-- A matching top-level label is left unchanged. A rendered volume PVC can carry
-- its service name there; replace that value with the aggregate app name while
-- preserving every other field. Only the FIRST @managed-by@ is used for insertion
-- when the top-level app label is absent.
stampAppLabel :: Text -> ByteString -> Either Text ByteString
stampAppLabel name bs
  | topLevelAppLabel bs == Just name = Right bs
  | isJust (topLevelAppLabel bs) = replaceExisting
  | not ("nagare.dev/managed-by:" `T.isInfixOf` text) =
      Left
        ( describe bs
            <> " has no 'nagare.dev/managed-by:' anchor to stamp nagare.dev/app after"
        )
  | otherwise = verify (TE.encodeUtf8 (T.unlines (insertAfterFirst (T.lines text))))
  where
    text = TE.decodeUtf8 bs
    replaceExisting = case Yaml.decodeEither' bs of
      Right (Object top) -> case KM.lookup "metadata" top of
        Just (Object metadata) -> case KM.lookup "labels" metadata of
          Just (Object labels) ->
            let updated = Object (KM.insert "metadata"
                  (Object (KM.insert "labels"
                    (Object (KM.insert "nagare.dev/app" (String name) labels)) metadata)) top)
             in verify (Yaml.encode updated)
          _ -> Left "rendered object has no metadata.labels object"
        _ -> Left "rendered object has no metadata object"
      _ -> Left "rendered object is not valid YAML"
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
-- Reviewed rollout resolution

-- | Reviewed planning supplies broker environment derived from accepted
-- inventory history, avoiding a live discovery result outside the review.
resolveAppRolloutWithBrokerEnv
  :: AppDeployParams -> Application -> Map EnvName ScopedEnvVar -> IO RolloutEnv
resolveAppRolloutWithBrokerEnv p app brokerEnv = do
  qImg <- case qualifyImage tp (app ^. #image) of
    Left e -> dieT ("nagarectl app deploy: " <> e)
    Right q -> pure q
  imageTag <- resolveTag (T.unpack <$> p ^. #tag)
  let effTag = maybe imageTag (\b -> resolveImageTag b imageTag) (buildForTag app)
  pure RolloutEnv
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
  where
    tp = p ^. #targetProfile

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

dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
