-- | The typed scheduled-task model (MasterPlan 10, IP1). A 'Task' names a unit
-- of work, a validated cron 'Schedule', the command to run, and the image and
-- environment to run it in. Every constrained field goes through a smart
-- constructor, so an illegal task (bad name, malformed cron, negative backoff,
-- a task with neither a command nor an inheriting app) cannot be written down.
--
-- Reuses 'ServiceName', 'Namespace', 'ImageRef', 'Quantity', 'Resources',
-- 'EnvName', 'ScopedEnvVar' from "Nagare.Dsl.Types"; it does not duplicate them.
--
-- The CronJob/Job shapes this model renders to (in "Nagare.Dsl.Task.Render")
-- reproduce the proven backup machinery in
-- @cli/nagarectl/src/Nagare/Database/Backup.hs@, verified on the live cluster
-- by the EP-49 spike
-- (@docs/plans/49-scheduled-task-substrate-spike-and-one-off-run-feasibility.md@).
module Nagare.Dsl.Task
  ( -- * Schedule
    Schedule
  , mkSchedule
  , scheduleText

    -- * Policies
  , ConcurrencyPolicy (..)
  , concurrencyPolicyToken
  , parseConcurrencyPolicy
  , RestartPolicy (..)
  , restartPolicyToken
  , parseRestartPolicy

    -- * Task
  , Task (..)
  , mkTask

    -- * Presets
  , scheduledTask

    -- * Naming (IP3)
  , taskResourceName
  ) where

import Nagare.Dsl.Prelude

import Data.Char (isDigit)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Types
  ( EnvName
  , ImageRef
  , Namespace
  , Resources
  , ScopedEnvVar
  , ServiceName
  , defaultNamespace
  , mkImageRef
  , mkServiceName
  )

-- ---------------------------------------------------------------------------
-- Schedule

-- | A validated 5-field cron expression: @minute hour day-of-month month
-- day-of-week@. The constructor is hidden; use 'mkSchedule'.
--
-- Each of the five fields independently accepts:
--
--   * @*@ — "every value in this field's range";
--   * a single number within the field's range (minute 0-59, hour 0-23,
--     day-of-month 1-31, month 1-12, day-of-week 0-6);
--   * a range @a-b@ where @a@ and @b@ are in range and @a <= b@;
--   * a comma list of any of the above, e.g. @1,15,30@;
--   * a step @*\/n@ or @a-b\/n@ where @n >= 1@.
--
-- This is a pragmatic subset of cron that covers every schedule Nagare needs
-- (Kubernetes itself accepts the same grammar). Named months/days
-- (@JAN@, @MON@) and the @\@daily@ macros are deliberately NOT accepted so the
-- one rendered form is unambiguous.
newtype Schedule = Schedule Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'Schedule'. Splits on spaces into exactly five
-- fields and validates each against its range, rejecting empty input and any
-- malformed field with a precise message.
mkSchedule :: Text -> Either Text Schedule
mkSchedule raw
  | Text.null trimmed = Left "schedule must not be empty"
  | length fields /= 5 =
      Left
        ( "schedule must have exactly 5 space-separated fields "
            <> "(minute hour day-of-month month day-of-week), got "
            <> tshow (length fields)
            <> ": "
            <> trimmed
        )
  | otherwise =
      case zipWithE validateField fieldRanges fields of
        Left err -> Left err
        Right _ -> Right (Schedule (Text.unwords fields))
  where
    trimmed = Text.strip raw
    fields = Text.words trimmed
    -- (field label, minimum, maximum) for the five cron positions.
    fieldRanges :: [(Text, Int, Int)]
    fieldRanges =
      [ ("minute", 0, 59)
      , ("hour", 0, 23)
      , ("day-of-month", 1, 31)
      , ("month", 1, 12)
      , ("day-of-week", 0, 6)
      ]

scheduleText :: Schedule -> Text
scheduleText (Schedule t) = t

-- | Validate one cron field (a comma list of terms) against its range.
validateField :: (Text, Int, Int) -> Text -> Either Text ()
validateField (label, lo, hi) field
  | Text.null field = Left ("cron " <> label <> " field is empty")
  | otherwise = mapM_ (validateTerm label lo hi) (Text.splitOn "," field)

-- | Validate one comma-separated term: @*@, @*\/n@, @a@, @a-b@, or @a-b\/n@.
validateTerm :: Text -> Int -> Int -> Text -> Either Text ()
validateTerm label lo hi term =
  case Text.splitOn "/" term of
    [base] -> validateBase base
    [base, stepT] -> validateBase base >> validateStep stepT
    _ -> Left ("cron " <> label <> " term has too many '/': " <> term)
  where
    validateBase "*" = Right ()
    validateBase b =
      case Text.splitOn "-" b of
        [oneT] -> validateNum oneT >> Right ()
        [aT, bT] -> do
          a <- validateNum aT
          c <- validateNum bT
          if a <= c
            then Right ()
            else Left ("cron " <> label <> " range start > end: " <> b)
        _ -> Left ("cron " <> label <> " term malformed: " <> b)
    validateNum t = case readInRange t of
      Just n -> Right n
      Nothing ->
        Left
          ( "cron " <> label <> " value out of range " <> tshow lo <> "-" <> tshow hi
              <> " (or not a number): " <> t
          )
    readInRange t = do
      n <- readIntT t
      if n >= lo && n <= hi then Just n else Nothing
    validateStep stepT = case readIntT stepT of
      Just n | n >= 1 -> Right ()
      _ -> Left ("cron " <> label <> " step must be >= 1: " <> stepT)

-- | Parse a non-negative decimal 'Int' from 'Text', or 'Nothing'.
readIntT :: Text -> Maybe Int
readIntT t
  | not (Text.null t) && Text.all isDigit t = Just (Text.foldl' step 0 t)
  | otherwise = Nothing
  where
    step acc c = acc * 10 + (fromEnum c - fromEnum '0')

-- | Like 'mapM' for the 'Either' monad over the two zipped lists, short-circuit
-- on the first 'Left'. (Defined locally to avoid pulling in extra imports.)
zipWithE :: (a -> b -> Either e c) -> [a] -> [b] -> Either e [c]
zipWithE f xs ys = sequence (zipWith f xs ys)

-- ---------------------------------------------------------------------------
-- Policies

-- | What Kubernetes does when a scheduled run would overlap a still-running one.
-- 'Forbid' (the safe default) skips the new run; 'Allow' runs both; 'Replace'
-- cancels the running one and starts the new one. Renders to
-- @spec.concurrencyPolicy@.
data ConcurrencyPolicy = Forbid | Allow | Replace
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

-- | The exact token Kubernetes expects in @concurrencyPolicy@ (and the JSON).
concurrencyPolicyToken :: ConcurrencyPolicy -> Text
concurrencyPolicyToken Forbid = "Forbid"
concurrencyPolicyToken Allow = "Allow"
concurrencyPolicyToken Replace = "Replace"

parseConcurrencyPolicy :: Text -> Maybe ConcurrencyPolicy
parseConcurrencyPolicy "Forbid" = Just Forbid
parseConcurrencyPolicy "Allow" = Just Allow
parseConcurrencyPolicy "Replace" = Just Replace
parseConcurrencyPolicy _ = Nothing

-- | The pod's restart policy. A batch task uses 'Never' (the default; each
-- failed pod is replaced by the Job controller per 'taskBackoffLimit') or
-- 'OnFailure' (the kubelet restarts the container in place). Renders to
-- @template.spec.restartPolicy@.
data RestartPolicy = Never | OnFailure
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

restartPolicyToken :: RestartPolicy -> Text
restartPolicyToken Never = "Never"
restartPolicyToken OnFailure = "OnFailure"

parseRestartPolicy :: Text -> Maybe RestartPolicy
parseRestartPolicy "Never" = Just Never
parseRestartPolicy "OnFailure" = Just OnFailure
parseRestartPolicy _ = Nothing

-- ---------------------------------------------------------------------------
-- Task

-- | A scheduled task. There is no hidden constructor for 'Task' — like
-- 'Nagare.Dsl.Types.Deployment' and 'Nagare.Dsl.Database.Database', the safety
-- guarantee comes from the field types and from 'mkTask' (which enforces the
-- one cross-field invariant a single field type cannot: a task must have either
-- a command or an inheriting app+image).
data Task = Task
  { taskName :: !ServiceName
  -- ^ DNS-1123 label; the CronJob is named @nagare-task-\<taskName\>@ (IP3).
  , taskNamespace :: !Namespace
  , taskSchedule :: !Schedule
  -- ^ Validated 5-field cron expression.
  , taskImage :: !(Maybe ImageRef)
  -- ^ The image to run in. 'Nothing' means "inherit the referenced app's
  -- image", which is only valid when 'taskApp' is 'Just' (enforced in 'mkTask'
  -- and re-checked at load). EP-52 resolves the inherited tag at deploy time.
  , taskApp :: !(Maybe ServiceName)
  -- ^ The app whose image/env this task may inherit (IP5 shape). When 'Just',
  -- the renderer stamps the @nagare.dev/app@ label and an @envFrom@ block; EP-52
  -- owns the deploy-time resolution of the inherited image and resource names.
  , taskCommand :: ![Text]
  -- ^ The container @command@ (the entrypoint to override). May be empty only
  -- when the task inherits an app's image (then the image's own entrypoint runs).
  , taskArgs :: ![Text]
  -- ^ The container @args@.
  , taskEnv :: !(Map EnvName ScopedEnvVar)
  -- ^ Inline env. Only 'Runtime'-scoped entries render into the container (the
  -- renderer filters, matching how the app renderer treats build-only vars).
  , taskResources :: !(Maybe Resources)
  , taskTimeoutSeconds :: !(Maybe Int)
  -- ^ Hard wall-clock limit; renders as @jobTemplate.spec.activeDeadlineSeconds@.
  -- Must be @> 0@ when present.
  , taskConcurrencyPolicy :: !ConcurrencyPolicy
  -- ^ Default 'Forbid'.
  , taskRestartPolicy :: !RestartPolicy
  -- ^ Default 'Never'.
  , taskBackoffLimit :: !Int
  -- ^ Retries before the Job is marked failed; @>= 0@; default 0.
  , taskSuccessfulJobsHistoryLimit :: !Int
  -- ^ Default 3.
  , taskFailedJobsHistoryLimit :: !Int
  -- ^ Default 1.
  , taskStartingDeadlineSeconds :: !(Maybe Int)
  -- ^ Optional; @> 0@ when present; renders as @spec.startingDeadlineSeconds@.
  }
  deriving stock (Generic, Eq, Show)

-- | Validate an assembled 'Task'. Re-checks the numeric bounds the field types
-- cannot ('taskBackoffLimit' >= 0, positive timeouts/deadlines) and the one
-- cross-field invariant: a task must have a non-empty 'taskCommand' OR inherit
-- an app's image ('taskImage' == Nothing AND 'taskApp' == Just). Also rejects
-- image inheritance with no app to inherit from.
mkTask :: Task -> Either Text Task
mkTask t
  | taskBackoffLimit t < 0 =
      Left ("backoffLimit must be >= 0, got: " <> tshow (taskBackoffLimit t))
  | taskSuccessfulJobsHistoryLimit t < 0 =
      Left "successfulJobsHistoryLimit must be >= 0"
  | taskFailedJobsHistoryLimit t < 0 =
      Left "failedJobsHistoryLimit must be >= 0"
  | maybe False (<= 0) (taskTimeoutSeconds t) =
      Left "timeoutSeconds must be > 0 when set"
  | maybe False (<= 0) (taskStartingDeadlineSeconds t) =
      Left "startingDeadlineSeconds must be > 0 when set"
  | isNothing (taskImage t) && isNothing (taskApp t) =
      Left "a task with no image must reference an app to inherit its image from"
  | null (taskCommand t) && isNothing (taskApp t) =
      Left "a task must have a command, or reference an app to inherit its entrypoint"
  | otherwise = Right t

-- ---------------------------------------------------------------------------
-- Preset

-- | Build a standalone scheduled task from a name, a cron schedule, an image,
-- and a single-word command, filling sensible defaults (namespace @personal@,
-- no app, no args, no env, no resources, 'Forbid'/'Never', backoff 0, history
-- 3/1). Every constrained field goes through its smart constructor, and the
-- result is validated by 'mkTask'. The @command@ is split on spaces into
-- 'taskCommand'.
scheduledTask :: Text -> Text -> Text -> Text -> Either Text Task
scheduledTask nameT scheduleT imageT commandT = do
  n <- mkServiceName nameT
  sched <- mkSchedule scheduleT
  img <- mkImageRef imageT
  mkTask
    Task
      { taskName = n
      , taskNamespace = defaultNamespace
      , taskSchedule = sched
      , taskImage = Just img
      , taskApp = Nothing
      , taskCommand = Text.words commandT
      , taskArgs = []
      , taskEnv = Map.empty
      , taskResources = Nothing
      , taskTimeoutSeconds = Nothing
      , taskConcurrencyPolicy = Forbid
      , taskRestartPolicy = Never
      , taskBackoffLimit = 0
      , taskSuccessfulJobsHistoryLimit = 3
      , taskFailedJobsHistoryLimit = 1
      , taskStartingDeadlineSeconds = Nothing
      }

-- ---------------------------------------------------------------------------
-- Naming (IP3)

-- | The deterministic CronJob/Job resource name for a task (IP3):
-- @taskResourceName "cleanup" == "nagare-task-cleanup"@. Mirrors the backup
-- CronJob's @nagare-dbbackup-\<name\>@ and the @nagare-\<kind\>-\<name\>@
-- convention used throughout the renderers. EP-51 discovers tasks by the IP3
-- labels, not this name, but uses this name for @kubectl create job --from@.
taskResourceName :: Text -> Text
taskResourceName n = "nagare-task-" <> n

-- Internal: show an Int as Text for error messages.
tshow :: (Show a) => a -> Text
tshow = Text.pack . show
