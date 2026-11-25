-- | Task responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Task
  ( JsonTask (..)
  , decodeTask
  , toTask
  )
where

import Data.Aeson
  ( FromJSON (..)
  , eitherDecodeStrict
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  )
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields
  ( JsonAppDatabaseBinding
  , JsonBucketBinding
  , JsonEnvEntry (..)
  , JsonKeySetBinding
  , JsonKindEnvelope (..)
  , toAppDatabaseBinding
  , toBucketBinding
  , toEnvEntry
  , toKeySetBinding
  , toManagedEnv
  )
import Nagare.Dsl.Prelude
import Nagare.Dsl.Task
  ( Task (..)
  , TaskTrigger (..)
  , mkSchedule
  , mkTask
  , parseConcurrencyPolicy
  , parseRestartPolicy
  , requireScheduled
  )
import Nagare.Dsl.Types
  ( Resources (..)
  , mkImageRef
  , mkNamespace
  , mkQuantity
  , mkServiceAccountName
  , mkServiceName
  )
import Nagare.Resource.Types (mkLogicalKey)

-- ---------------------------------------------------------------------------
-- JSON intermediate for tasks (mirrors Nagare.Dsl.Config's emitted shape)

-- | The intermediate decode shape for a 'Task' (mirrors 'Nagare.Dsl.Config'\'s
-- @taskJSON@). Optional fields carry their model defaults so a partial object
-- is a precise 'MarshalError', not an aeson parse error.
data JsonTask = JsonTask
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , namespace :: !Text
  , schedule :: !(Maybe Text)
  , trigger :: !(Maybe Text)
  , image :: !(Maybe Text)
  , app :: !(Maybe Text)
  , command :: ![Text]
  , args :: ![Text]
  , env :: ![JsonEnvEntry]
  , cpuRequest :: !(Maybe Text)
  , memoryRequest :: !(Maybe Text)
  , cpuLimit :: !(Maybe Text)
  , memoryLimit :: !(Maybe Text)
  , timeoutSeconds :: !(Maybe Int)
  , concurrencyPolicy :: !(Maybe Text)
  , restartPolicy :: !(Maybe Text)
  , backoffLimit :: !(Maybe Int)
  , successfulJobsHistoryLimit :: !(Maybe Int)
  , failedJobsHistoryLimit :: !(Maybe Int)
  , startingDeadlineSeconds :: !(Maybe Int)
  , serviceAccount :: !(Maybe Text)
  , managedEnv :: !(Maybe Text)
  , appDatabases :: ![JsonAppDatabaseBinding]
  , buckets :: ![JsonBucketBinding]
  , keySets :: ![JsonKeySetBinding]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonTask where
  parseJSON = withObject "Task" $ \o ->
    JsonTask
      <$> o .: "name"
      <*> o .:? "logicalKey"
      <*> o .: "namespace"
      <*> o .:? "schedule"
      <*> o .:? "trigger"
      <*> o .:? "image"
      <*> o .:? "app"
      <*> o .:? "command" .!= []
      <*> o .:? "args" .!= []
      <*> o .:? "env" .!= []
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "cpuLimit"
      <*> o .:? "memoryLimit"
      <*> o .:? "timeoutSeconds"
      <*> o .:? "concurrencyPolicy"
      <*> o .:? "restartPolicy"
      <*> o .:? "backoffLimit"
      <*> o .:? "successfulJobsHistoryLimit"
      <*> o .:? "failedJobsHistoryLimit"
      <*> o .:? "startingDeadlineSeconds"
      <*> o .:? "serviceAccount"
      <*> o .:? "managedEnv"
      <*> o .:? "appDatabases" .!= []
      <*> o .:? "buckets" .!= []
      <*> o .:? "keySets" .!= []

-- | Re-validate a decoded task: re-run every smart constructor, decode the
-- enum tokens, default the numeric fields, and finally re-check the assembled
-- record with 'mkTask' (which enforces the bounds and the command-or-app
-- cross-field invariant). Any failure is a precise 'MarshalError' keyed by the
-- field.
toTask :: JsonTask -> Either LoadError Task
toTask j = do
  name' <- first (MarshalError "name") $ mkServiceName (j ^. #name)
  logicalKey' <- traverse (first (MarshalError "logicalKey") . mkLogicalKey) (j ^. #logicalKey)
  ns' <- first (MarshalError "namespace") $ mkNamespace (j ^. #namespace)
  trigger' <- toTaskTrigger (j ^. #schedule) (j ^. #trigger)
  img' <- traverse (first (MarshalError "image") . mkImageRef) (j ^. #image)
  app' <- traverse (first (MarshalError "app") . mkServiceName) (j ^. #app)
  env' <- mapM toEnvEntry (j ^. #env)
  res' <- toTaskResources j
  cp' <- case parseConcurrencyPolicy (fromMaybe "Forbid" (j ^. #concurrencyPolicy)) of
    Just p -> Right p
    Nothing ->
      Left
        ( MarshalError
            "concurrencyPolicy"
            ("unknown concurrency policy: " <> fromMaybe "" (j ^. #concurrencyPolicy))
        )
  rp' <- case parseRestartPolicy (fromMaybe "Never" (j ^. #restartPolicy)) of
    Just p -> Right p
    Nothing ->
      Left
        ( MarshalError
            "restartPolicy"
            ("unknown restart policy: " <> fromMaybe "" (j ^. #restartPolicy))
        )
  serviceAccount' <- traverse (first (MarshalError "serviceAccount") . mkServiceAccountName) (j ^. #serviceAccount)
  managedEnv' <- toManagedEnv (j ^. #managedEnv)
  appDbRefs' <- traverse toAppDatabaseBinding (j ^. #appDatabases)
  buckets' <- traverse toBucketBinding (j ^. #buckets)
  keySets' <- traverse toKeySetBinding (j ^. #keySets)
  first (MarshalError "task") $
    mkTask
      Task
        { name = name'
        , logicalKey = logicalKey'
        , namespace = ns'
        , trigger = trigger'
        , image = img'
        , app = app'
        , command = j ^. #command
        , args = j ^. #args
        , env = Map.fromList env'
        , resources = res'
        , timeoutSeconds = j ^. #timeoutSeconds
        , concurrencyPolicy = cp'
        , restartPolicy = rp'
        , backoffLimit = fromMaybe 0 (j ^. #backoffLimit)
        , successfulJobsHistoryLimit = fromMaybe 3 (j ^. #successfulJobsHistoryLimit)
        , failedJobsHistoryLimit = fromMaybe 1 (j ^. #failedJobsHistoryLimit)
        , startingDeadlineSeconds = j ^. #startingDeadlineSeconds
        , serviceAccount = serviceAccount'
        , managedEnv = managedEnv'
        , appDatabases = appDbRefs'
        , buckets = buckets'
        , keySets = keySets'
        }

-- | A task names exactly one of a cron @schedule@ or @trigger: release-only@.
toTaskTrigger :: Maybe Text -> Maybe Text -> Either LoadError TaskTrigger
toTaskTrigger sched trig = case (sched, trig) of
  (Just s, Nothing) -> OnSchedule <$> first (MarshalError "schedule") (mkSchedule s)
  (Nothing, Just "release-only") -> Right ReleaseOnly
  (Nothing, Just other) ->
    Left (MarshalError "trigger" ("unknown task trigger: " <> other <> "; expected release-only"))
  (Just _, Just _) ->
    Left (MarshalError "trigger" "a task names either a schedule or trigger release-only, not both")
  (Nothing, Nothing) ->
    Left (MarshalError "trigger" "a task needs a schedule or trigger release-only")

toTaskResources :: JsonTask -> Either LoadError (Maybe Resources)
toTaskResources j =
  case (j ^. #cpuRequest, j ^. #memoryRequest, j ^. #cpuLimit, j ^. #memoryLimit) of
    (Nothing, Nothing, Nothing, Nothing) -> Right Nothing
    (c, m, cl, ml) -> do
      c' <- traverse (first (MarshalError "cpuRequest") . mkQuantity) c
      m' <- traverse (first (MarshalError "memoryRequest") . mkQuantity) m
      cl' <- traverse (first (MarshalError "cpuLimit") . mkQuantity) cl
      ml' <- traverse (first (MarshalError "memoryLimit") . mkQuantity) ml
      Right (Just Resources {cpu = c', memory = m', cpuLimit = cl', memoryLimit = ml'})

-- | Decode the JSON a task config emits (via 'Nagare.Dsl.Config.emitTask') into
-- a validated 'Task'. The top-level @kind@ is checked first: a missing or
-- non-@Task@ kind is 'UnexpectedKind'.
decodeTask :: ByteString -> Either LoadError Task
decodeTask bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "Task" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode task: " <> Text.pack perr))
        -- A standalone task is never a pre-deploy hook (EP-269).
        Right jt -> toTask jt >>= \t -> t <$ first (MarshalError "trigger") (requireScheduled t)
      Just other -> Left (UnexpectedKind "Task" other)
      Nothing -> Left (UnexpectedKind "Task" "<none>")
