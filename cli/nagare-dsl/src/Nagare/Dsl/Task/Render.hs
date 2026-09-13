-- | Render a 'Task' to its Kubernetes manifest (MasterPlan 10, IP2): a single
-- @batch/v1@ CronJob whose @spec.jobTemplate.spec@ is the Job template a one-off
-- run reuses. The shape reproduces the proven backup machinery in
-- @cli/nagarectl/src/Nagare/Database/Backup.hs@ (@renderBackupCronJob@,
-- @backupJobSpecValue@). Every rendered object carries the IP3 labels
-- @nagare.dev/managed-by@, @nagare.dev/task@, and — when the task references an
-- app — @nagare.dev/app@.
--
-- The bare Job @.spec@ is exposed as 'taskJobSpecValue' so EP-51's one-off run
-- and EP-52's env-injection reuse the exact same value. When 'app' is set,
-- the template includes an @envFrom@ block referencing the app's managed runtime
-- ConfigMap/Secret (@nagare-env-\<app\>-runtime@ / @nagare-secret-\<app\>-runtime@,
-- @optional: true@); EP-52 owns resolving the inherited image tag at deploy time.
module Nagare.Dsl.Task.Render
  ( renderTask
  , taskJobSpecValue
  , taskCronJobName
  , cronJobValue
  , encodeCronJob
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Batch.Render
  ( argvPairs
  , batchConfig
  , managedEnvFromPairs
  , resourcesPairs
  , runtimeEnvPairs
  )
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Task
import Nagare.Dsl.Types
  ( imageRefText
  , namespaceText
  , serviceNameText
  )

-- ---------------------------------------------------------------------------
-- Names (IP3)

-- | The CronJob (and one-off Job) name for a task: @nagare-task-\<name\>@.
taskCronJobName :: Task -> Text
taskCronJobName t = taskResourceName (serviceNameText (t ^. #name))

-- ---------------------------------------------------------------------------
-- Top-level: one CronJob document.

txt :: Text -> Text
txt = id

-- | Render the @batch/v1@ CronJob for a task. Deterministic key order via
-- 'taskConfig' makes the bytes golden-stable.
renderTask :: Task -> ByteString
renderTask = encodeCronJob . cronJobValue

-- | Encode a CronJob 'Value' to deterministic YAML bytes with the same ordered
-- comparator 'renderTask' uses. Exposed so EP-52's deploy-time resolver
-- ('Nagare.Task.Resolve') can patch the container 'Value' (injecting the resolved
-- image and the @NAGARE_RUN_ID@ Downward-API entry) and re-encode byte-stably,
-- keeping this module the single owner of the manifest shape and key order.
encodeCronJob :: Value -> ByteString
encodeCronJob = YP.encodePretty taskConfig

cronJobValue :: Task -> Value
cronJobValue t =
  object
    [ "apiVersion" .= txt "batch/v1"
    , "kind" .= txt "CronJob"
    , "metadata" .= metadataValue (taskCronJobName t) t
    , "spec"
        .= object
          ( [ "schedule" .= scheduleText (t ^. #schedule)
            , "concurrencyPolicy" .= concurrencyPolicyToken (t ^. #concurrencyPolicy)
            , "successfulJobsHistoryLimit" .= (t ^. #successfulJobsHistoryLimit)
            , "failedJobsHistoryLimit" .= (t ^. #failedJobsHistoryLimit)
            ]
              <> startingDeadlinePairs t
              <> ["jobTemplate" .= object ["spec" .= taskJobSpecValue t]]
          )
    ]

startingDeadlinePairs :: Task -> [Pair]
startingDeadlinePairs t = case t ^. #startingDeadlineSeconds of
  Just n -> ["startingDeadlineSeconds" .= n]
  Nothing -> []

-- | The Job @.spec@ body (backoffLimit + optional activeDeadlineSeconds + the
-- pod template with the single container). Reused verbatim as the CronJob's
-- @jobTemplate.spec@ AND exposed so a one-off run (EP-51) can wrap it in a bare
-- @batch/v1@ Job, and EP-52 can inject the resolved image and envFrom.
taskJobSpecValue :: Task -> Value
taskJobSpecValue t =
  object
    ( ["backoffLimit" .= (t ^. #backoffLimit)]
        <> activeDeadlinePairs t
        <> [ "template"
               .= object
                 [ "metadata" .= object ["labels" .= taskLabels t]
                 , "spec"
                     .= object
                       [ "restartPolicy" .= restartPolicyToken (t ^. #restartPolicy)
                       , "containers" .= toJSON [containerValue t]
                       ]
                 ]
           ]
    )

activeDeadlinePairs :: Task -> [Pair]
activeDeadlinePairs t = case t ^. #timeoutSeconds of
  Just n -> ["activeDeadlineSeconds" .= n]
  Nothing -> []

-- ---------------------------------------------------------------------------
-- Container.

containerValue :: Task -> Value
containerValue t =
  object
    ( ["name" .= serviceNameText (t ^. #name)]
        <> imagePairs t
        <> commandPairs t
        <> argsPairs t
        <> envFromPairs t
        <> envPairs t
        <> resourcesPairs (t ^. #resources)
    )

-- | The container @image@. When the task carries its own image it renders
-- verbatim (the deploy tag is appended by the CLI at apply time, mirroring how
-- the app renderer appends a tag — here the renderer emits the bare repo path,
-- and EP-52/EP-51 append the tag). When the task inherits an app's image, the
-- key is OMITTED here; EP-52 fills it at deploy time from the app's pushed tag.
imagePairs :: Task -> [Pair]
imagePairs t = case t ^. #image of
  Just img -> ["image" .= imageRefText img]
  Nothing -> []

commandPairs :: Task -> [Pair]
commandPairs = argvPairs . (^. #command)

argsPairs :: Task -> [Pair]
argsPairs t
  | null (t ^. #args) = []
  | otherwise = ["args" .= toJSON (t ^. #args)]

-- | The @envFrom@ block (IP5 shape). Present ONLY when the task references an
-- app: it pulls the app's managed runtime ConfigMap and Secret, each
-- @optional: true@ so a task can run before those resources exist. This mirrors
-- @Nagare.Dsl.Render.envFromField@ for app containers. EP-52 owns populating the
-- referenced resources at deploy time.
envFromPairs :: Task -> [Pair]
envFromPairs t = case t ^. #app of
  Nothing -> []
  Just app -> managedEnvFromPairs (serviceNameText app)

-- | The inline container @env@: only 'Runtime'-scoped entries render (matching
-- how the app renderer drops build-only vars). Sorted by name via
-- 'Map.toAscList' for determinism. Omitted entirely when no Runtime entries
-- remain.
envPairs :: Task -> [Pair]
envPairs = runtimeEnvPairs . (^. #env)

-- ---------------------------------------------------------------------------
-- Labels (IP3) and metadata.

-- | The IP3 labels stamped on every rendered object. @nagare.dev/app@ appears
-- only when the task references an app.
taskLabels :: Task -> Value
taskLabels t =
  object
    ( [ "nagare.dev/managed-by" .= txt "nagarectl"
      , "nagare.dev/task" .= serviceNameText (t ^. #name)
      ]
        <> case t ^. #app of
          Just app -> ["nagare.dev/app" .= serviceNameText app]
          Nothing -> []
    )

metadataValue :: Text -> Task -> Value
metadataValue n t =
  object
    [ "name" .= n
    , "namespace" .= namespaceText (t ^. #namespace)
    , "labels" .= taskLabels t
    ]

-- ---------------------------------------------------------------------------
-- YAML key ordering (mirrors Nagare.Dsl.Database.Render.dbConfig).

taskConfig :: YP.Config
taskConfig = batchConfig taskKeyRanks

taskKeyRanks :: [(Text, Int)]
taskKeyRanks =
  [ -- top-level document keys
    ("apiVersion", 0)
  , ("kind", 1)
  , ("metadata", 2)
  , ("spec", 3)
  , -- metadata
    ("name", 0)
  , ("namespace", 1)
  , ("labels", 2)
  , -- labels (non-alphabetical contract order)
    ("nagare.dev/managed-by", 0)
  , ("nagare.dev/task", 1)
  , ("nagare.dev/app", 2)
  , -- CronJob spec
    ("schedule", 0)
  , ("concurrencyPolicy", 1)
  , ("successfulJobsHistoryLimit", 2)
  , ("failedJobsHistoryLimit", 3)
  , ("startingDeadlineSeconds", 4)
  , ("jobTemplate", 5)
  , -- Job spec
    ("backoffLimit", 0)
  , ("activeDeadlineSeconds", 1)
  , ("template", 2)
  , -- pod spec
    ("restartPolicy", 0)
  , ("containers", 1)
  , -- container
    ("image", 1)
  , ("command", 2)
  , ("args", 3)
  , ("envFrom", 4)
  , ("env", 5)
  , ("resources", 6)
  , -- envFrom entry
    ("configMapRef", 0)
  , ("secretRef", 1)
  , ("optional", 1)
  , -- env entry
    ("value", 1)
  , ("valueFrom", 2)
  , ("secretKeyRef", 0)
  , ("key", 1)
  , -- resources
    ("requests", 0)
  , ("limits", 1)
  , ("cpu", 0)
  , ("memory", 1)
  ]
