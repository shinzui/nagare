-- | A typed, bounded, one-shot workload. A 'Job' renders to Kubernetes
-- @batch/v1@ plus the ServiceAccount and NetworkPolicy that confine its Pod.
-- The public record constructor composes existing validated field types; call
-- 'mkJob' after record construction to enforce numeric and resource invariants.
module Nagare.Dsl.Job
  ( ConfigMapName
  , mkConfigMapName
  , configMapNameText
  , Job (..)
  , mkJob
  , oneShotJob
  , jobResourceName
  )
where

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Build (BuildSpec (..), mkTag)
import Nagare.Dsl.Command (Command)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( EnvName
  , ImageRef
  , Namespace
  , Quantity
  , Resources (..)
  , ScopedEnvVar
  , ServiceName
  , defaultNamespace
  , mkImageRef
  , mkQuantity
  , mkServiceName
  , serviceNameText
  )

-- | A Kubernetes ConfigMap name. The v1 implementation deliberately uses the
-- repository's existing DNS-label validation, which accepts the intended
-- @nagare-nix-cache-client@ name and keeps names within 63 characters.
newtype ConfigMapName = ConfigMapName ServiceName
  deriving stock (Generic, Eq, Ord, Show)

mkConfigMapName :: Text -> Either Text ConfigMapName
mkConfigMapName = fmap ConfigMapName . mkServiceName

configMapNameText :: ConfigMapName -> Text
configMapNameText (ConfigMapName n) = serviceNameText n

-- | A single bounded execution. A missing deadline is valid for general Jobs,
-- but such a Pod does not match Nagare's @Terminating@ ResourceQuota and must
-- not be used for agent runs.
data Job = Job
  { jobName :: !ServiceName
  , jobNamespace :: !Namespace
  , jobImage :: !ImageRef
  , jobBuild :: !BuildSpec
  , jobCommand :: !(Maybe Command)
  , jobEnv :: !(Map EnvName ScopedEnvVar)
  , jobResources :: !(Maybe Resources)
  , jobBackoffLimit :: !Int
  , jobActiveDeadlineSeconds :: !(Maybe Int)
  , jobTtlSecondsAfterFinished :: !(Maybe Int)
  , jobScratchSize :: !Quantity
  , jobNixConfigMap :: !(Maybe ConfigMapName)
  }
  deriving stock (Generic, Eq, Show)

-- | Re-check the invariants that span plain numeric fields or the optional
-- 'Resources' record. An explicit resource block must specify all four values;
-- 'Nothing' asks the renderer for the hardened preset defaults.
mkJob :: Job -> Either Text Job
mkJob job
  | jobBackoffLimit job < 0 =
      Left ("backoffLimit must be >= 0, got: " <> tshow (jobBackoffLimit job))
  | maybe False (<= 0) (jobActiveDeadlineSeconds job) =
      Left "activeDeadlineSeconds must be > 0 when set"
  | maybe False (<= 0) (jobTtlSecondsAfterFinished job) =
      Left "ttlSecondsAfterFinished must be > 0 when set"
  | otherwise = validateResources (jobResources job) >> Right job
  where
    validateResources Nothing = Right ()
    validateResources (Just Resources {cpu = Nothing}) = Left "resources.cpuRequest must be set"
    validateResources (Just Resources {memory = Nothing}) = Left "resources.memoryRequest must be set"
    validateResources (Just Resources {cpuLimit = Nothing}) = Left "resources.cpuLimit must be set"
    validateResources (Just Resources {memoryLimit = Nothing}) = Left "resources.memoryLimit must be set"
    validateResources (Just _) = Right ()

-- | Construct a runnable one-shot Job using Nagare's hardened defaults.
oneShotJob :: Text -> Text -> Either String Job
oneShotJob nameText imageText = do
  name <- toStringError (mkServiceName nameText)
  image <- toStringError (mkImageRef imageText)
  tag <- toStringError (mkTag "latest")
  scratch <- toStringError (mkQuantity "2Gi")
  toStringError . mkJob $
    Job
      { jobName = name
      , jobNamespace = defaultNamespace
      , jobImage = image
      , jobBuild = PrebuiltImage tag
      , jobCommand = Nothing
      , jobEnv = Map.empty
      , jobResources = Nothing
      , jobBackoffLimit = 0
      , jobActiveDeadlineSeconds = Just 1800
      , jobTtlSecondsAfterFinished = Just 3600
      , jobScratchSize = scratch
      , jobNixConfigMap = Nothing
      }
  where
    toStringError = either (Left . Text.unpack) Right

-- | Deterministic Kubernetes resource name for a logical Job name.
jobResourceName :: Text -> Text
jobResourceName name = "nagare-job-" <> name

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
