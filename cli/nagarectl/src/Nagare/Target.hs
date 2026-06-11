{-# LANGUAGE OverloadedStrings #-}

-- | The single resolution point for the GCP "target profile" (MasterPlan 12,
-- EP-62; the variable contract is fixed by EP-60). Every value that used to be a
-- compile-time literal (the project, region, zone, Artifact Registry host/id, the
-- image/backup bucket names, the base domain, the VM instance name) is resolved
-- here, once, from the process environment with the EP-60 fallback defaults, so an
-- operator who sets @nagare.target.env@ (which EP-60's @.envrc@ exports) retargets
-- the whole CLI without editing Haskell. With nothing set, the defaults reproduce
-- the original tan-nb-exp / us-west1 / us-west1-a setup, so existing behavior is
-- unchanged. EP-63's @nagarectl init@ reuses this record.
module Nagare.Target
  ( TargetProfile (..)
  , resolveTargetProfile
  , registryPrefix
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (lookupEnv)

-- | The fully-resolved GCP target. Every field is the final value a consumer
-- should use; no further env lookups or literal fallbacks happen downstream.
data TargetProfile = TargetProfile
  { tpProject :: !Text
  -- ^ CLOUDSDK_CORE_PROJECT, e.g. @"tan-nb-exp"@
  , tpRegion :: !Text
  -- ^ CLOUDSDK_COMPUTE_REGION, e.g. @"us-west1"@
  , tpZone :: !Text
  -- ^ CLOUDSDK_COMPUTE_ZONE, e.g. @"us-west1-a"@
  , tpRegistryHost :: !Text
  -- ^ NAGARE_REGISTRY_HOST, default @"\<region>-docker.pkg.dev"@
  , tpArtifactRegistryId :: !Text
  -- ^ NAGARE_ARTIFACT_REGISTRY_ID, default @"nagare"@
  , tpImageBucket :: !Text
  -- ^ NAGARE_IMAGE_BUCKET, default @"\<project>-nagare-images"@
  , tpBackupBucket :: !Text
  -- ^ NAGARE_BACKUP_BUCKET, default @"\<project>-nagare-backups"@
  , tpBaseDomain :: !Text
  -- ^ NAGARE_BASE_DOMAIN, default @"apps.example.com"@
  , tpInstanceName :: !Text
  -- ^ NAGARE_INSTANCE_NAME, default @"nagare-01"@
  , tpTargetPlatform :: !Text
  -- ^ NAGARE_TARGET_PLATFORM, the Docker platform string the cluster node runs,
  -- default @"linux/amd64"@. Passed verbatim to @docker build --platform@ and
  -- @nixpacks build --platform@ (EP-3). The node is amd64; an operator whose
  -- node differs overrides this in @nagare.target.env@.
  }
  deriving stock (Eq, Show)

-- | The Artifact Registry image-name prefix: @"\<host>/\<project>/\<repo-id>"@. An
-- app's short image name is appended to this to form a full image ref (EP-62 M3,
-- MasterPlan 12 Integration Point 4).
registryPrefix :: TargetProfile -> Text
registryPrefix tp =
  tpRegistryHost tp <> "/" <> tpProject tp <> "/" <> tpArtifactRegistryId tp

-- | Resolve the profile from the process environment, applying the EP-60
-- precedence (environment > built-in default) and the EP-60 derivations for the
-- registry host and bucket names. An env var set to the empty string is treated
-- as unset (matching shell @${VAR:-default}@).
resolveTargetProfile :: IO TargetProfile
resolveTargetProfile = do
  project <- envOr "CLOUDSDK_CORE_PROJECT" "tan-nb-exp"
  region <- envOr "CLOUDSDK_COMPUTE_REGION" "us-west1"
  zone <- envOr "CLOUDSDK_COMPUTE_ZONE" "us-west1-a"
  registryHost <- envOr "NAGARE_REGISTRY_HOST" (region <> "-docker.pkg.dev")
  registryId <- envOr "NAGARE_ARTIFACT_REGISTRY_ID" "nagare"
  imageBucket <- envOr "NAGARE_IMAGE_BUCKET" (project <> "-nagare-images")
  backupBucket <- envOr "NAGARE_BACKUP_BUCKET" (project <> "-nagare-backups")
  baseDomain <- envOr "NAGARE_BASE_DOMAIN" "apps.example.com"
  instanceName <- envOr "NAGARE_INSTANCE_NAME" "nagare-01"
  targetPlatform <- envOr "NAGARE_TARGET_PLATFORM" "linux/amd64"
  pure
    TargetProfile
      { tpProject = project
      , tpRegion = region
      , tpZone = zone
      , tpRegistryHost = registryHost
      , tpArtifactRegistryId = registryId
      , tpImageBucket = imageBucket
      , tpBackupBucket = backupBucket
      , tpBaseDomain = baseDomain
      , tpInstanceName = instanceName
      , tpTargetPlatform = targetPlatform
      }

-- | Read an env var, falling back to @def@ when it is unset OR set to the empty
-- string. Returns 'Text' for direct use in the record.
envOr :: String -> Text -> IO Text
envOr name def = do
  m <- lookupEnv name
  pure $ case m of
    Just v | not (null v) -> T.pack v
    _ -> def
