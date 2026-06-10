{-# LANGUAGE PackageImports #-}

-- | Deploy-time resolution of an app-associated task (MasterPlan 10, EP-52, IP5).
--
-- EP-50's pure renderer ('Nagare.Dsl.Task.Render') emits the *structure* of
-- inheritance: an absent @image:@ key for an inheriting task, the @envFrom@ block
-- referencing the app's managed runtime ConfigMap/Secret, and the
-- @nagare.dev/app@ label. This module fills the one *value* the pure renderer
-- cannot know — the app's resolved @image:tag@ for this deploy — and adds the
-- predefined @NAGARE_*@ task variables, following the generated-variable pattern
-- in "Nagare.Env.Generated". It is pure (no IO): the resolved tag is passed in,
-- exactly as @Nagare.Database.Backup@ takes a @now :: UTCTime@, so rendering is
-- testable without a cluster.
--
-- The render path patches EP-50's @cronJobValue@ in memory (injecting the image
-- and the @NAGARE_RUN_ID@ Downward-API entry into the single container) and
-- re-encodes with EP-50's @encodeCronJob@, so EP-50 stays the single owner of the
-- manifest shape and the deterministic key order.
module Nagare.Task.Resolve
  ( resolveTaskImage
  , predefinedTaskEnv
  , renderResolvedTask
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import Data.Aeson (Value (Array, Object, String), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Vector qualified as V
import Nagare.Dsl.Task
  ( Task
  , taskApp
  , taskImage
  , taskName
  , taskNamespace
  )
import Nagare.Dsl.Task.Render (cronJobValue, encodeCronJob)
import Nagare.Dsl.Types
  ( EnvName
  , EnvVar (EnvLiteral)
  , ScopedEnvVar
  , imageRefText
  , mkEnvName
  , namespaceText
  , runtimeScoped
  , serviceNameText
  )

-- | The fully resolved @image:tag@ string for a task's container at deploy time.
--
--   * When the task carries its own image (@taskImage = Just ref@), the tag the
--     app is deploying this run is appended: @imageRefText ref <> ":" <> tag@.
--     This pins an explicit-image task to the same release as the app (Decision
--     Log), rather than deploying an untagged @:latest@.
--   * When the task inherits (@taskImage = Nothing@), the app's full resolved
--     image reference is used verbatim — the SAME string the app's own container
--     gets this run — so the task runs the app's current code.
resolveTaskImage
  :: Text -- ^ the app's resolved image reference, @repo:tag@ (for inheritance)
  -> Text -- ^ the bare deploy tag, @tag@ (to pin an explicit task image)
  -> Task
  -> Text
resolveTaskImage appImageTagged deployTag t =
  case taskImage t of
    Just ref -> imageRefText ref <> ":" <> deployTag
    Nothing -> appImageTagged

-- | The predefined @NAGARE_*@ literal variables injected into every task run,
-- following the generated-variable pattern in "Nagare.Env.Generated".
-- @NAGARE_TASK_NAME@, @NAGARE_NAMESPACE@, and (when the task references an app)
-- @NAGARE_APP@ are inline literals. @NAGARE_RUN_ID@ is NOT here: a CronJob's
-- pod-template env is fixed at apply time, so a genuinely per-run value comes from
-- Kubernetes' Downward API reading the pod's own name; it is appended as a raw env
-- entry by 'renderResolvedTask'.
predefinedTaskEnv :: Task -> Map EnvName ScopedEnvVar
predefinedTaskEnv t =
  Map.fromList (fixed <> appEntry)
  where
    lit name v = (envName name, runtimeScoped (EnvLiteral v))
    fixed =
      [ lit "NAGARE_TASK_NAME" (serviceNameText (taskName t))
      , lit "NAGARE_NAMESPACE" (namespaceText (taskNamespace t))
      ]
    appEntry = case taskApp t of
      Just a -> [lit "NAGARE_APP" (serviceNameText a)]
      Nothing -> []

-- | The @NAGARE_RUN_ID@ container env entry, as a raw Kubernetes env object using
-- the Downward API to read the pod's own name (unique per Job run).
runIdEnvEntry :: Value
runIdEnvEntry =
  object
    [ "name" .= ("NAGARE_RUN_ID" :: Text)
    , "valueFrom" .= object ["fieldRef" .= object ["fieldPath" .= ("metadata.name" :: Text)]]
    ]

-- | Render a task to its CronJob bytes WITH the deploy-time values resolved: the
-- inherited (or explicit-and-tagged) image substituted into the container, the
-- predefined @NAGARE_*@ literals merged into the task's inline env (via the
-- caller-supplied @withPredefEnv@ setter, which unions 'predefinedTaskEnv' into
-- the task's @taskEnv@), and the @NAGARE_RUN_ID@ Downward-API entry appended.
renderResolvedTask
  :: Text -- ^ the app's resolved image reference, @repo:tag@
  -> Text -- ^ the bare deploy tag
  -> (Task -> Task)
  -- ^ how to augment the task's inline env with 'predefinedTaskEnv' (the caller
  -- supplies a setter that unions @predefinedTaskEnv t@ into @taskEnv t@, so this
  -- module needs no record-update knowledge of the Task field shape)
  -> Task
  -> ByteString
renderResolvedTask appImageTagged deployTag withPredefEnv t =
  encodeCronJob (patchContainer (injectImageAndRunId resolvedImage) (cronJobValue (withPredefEnv t)))
  where
    resolvedImage = resolveTaskImage appImageTagged deployTag t

-- | Set the container's @image@ to the resolved reference and append the
-- @NAGARE_RUN_ID@ Downward-API env entry to its @env@ list (creating the list if
-- the container has no inline env).
injectImageAndRunId :: Text -> Value -> Value
injectImageAndRunId img (Object o) =
  Object
    . KeyMap.insert (Key.fromText "image") (String img)
    . KeyMap.insert (Key.fromText "env") newEnv
    $ o
  where
    newEnv = appendRunId (KeyMap.lookup (Key.fromText "env") o)
    appendRunId Nothing = Array (V.singleton runIdEnvEntry)
    appendRunId (Just (Array a)) = Array (V.snoc a runIdEnvEntry)
    appendRunId (Just other) = other
injectImageAndRunId _ v = v

-- | Apply @f@ to the single container 'Value' inside a rendered task CronJob,
-- walking the fixed path @spec.jobTemplate.spec.template.spec.containers[0]@. EP-50
-- always renders exactly one container, so the head element is the task container.
patchContainer :: (Value -> Value) -> Value -> Value
patchContainer f =
  overKey "spec" $
    overKey "jobTemplate" $
      overKey "spec" $
        overKey "template" $
          overKey "spec" $
            overKey "containers" (overFirst f)

overKey :: Text -> (Value -> Value) -> Value -> Value
overKey k g (Object o) =
  case KeyMap.lookup key o of
    Just v -> Object (KeyMap.insert key (g v) o)
    Nothing -> Object o
  where
    key = Key.fromText k
overKey _ _ v = v

overFirst :: (Value -> Value) -> Value -> Value
overFirst g (Array a)
  | not (V.null a) = Array (a V.// [(0, g (V.head a))])
overFirst _ v = v

-- | Force a known-valid 'EnvName' for a predefined @NAGARE_*@ key. The keys are
-- compile-time constants that satisfy 'mkEnvName', so the failure branch is
-- unreachable (mirrors 'Nagare.Env.Generated.envName').
envName :: Text -> EnvName
envName t = either (\e -> error ("EP-52 task env name invalid: " <> show e)) id (mkEnvName t)
