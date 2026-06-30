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
  , Mode (..)
  , parseMode
  , resolveTargetProfile
  , registryPrefix
  , minioCredentialsSecret
  , storeBackendFor
  ) where

import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T
import Nagare.Cluster.GcsJob
  ( MinioRef (..)
  , StoreBackend (..)
  , parseLocalObjectStore
  )
import System.Environment (lookupEnv)

-- | The deploy target's mode (MasterPlan 16, EP-83; this is Integration Point 2's
-- public type — EP-84 and EP-85 import it and must not re-derive the mode from the
-- environment themselves). 'Cloud' is the original GCP target; 'Local' selects the
-- local k3d cluster + local registry from EP-82. Resolved from @NAGARE_MODE@ in
-- 'resolveTargetProfile'; with the variable unset the mode is 'Cloud', so existing
-- behavior is unchanged.
data Mode = Cloud | Local
  deriving stock (Eq, Show)

-- | Parse the @NAGARE_MODE@ value. The string @"local"@ (case-insensitive) selects
-- 'Local'; anything else — including 'Nothing' (unset), @"cloud"@, and any
-- unrecognized value — is 'Cloud'. Defaulting unknown values to 'Cloud' keeps the
-- fail-safe direction: a typo never silently points a cloud operator at a
-- nonexistent local cluster.
parseMode :: Maybe String -> Mode
parseMode m = case fmap (map toLower) m of
  Just "local" -> Local
  _ -> Cloud

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
  , tpMode :: !Mode
  -- ^ NAGARE_MODE; 'Local' selects the EP-82 local cluster, default 'Cloud'
  -- (unset or any non-@local@ value). Drives conditional Docker auth in
  -- 'Nagare.Image.configureDockerAuth' (EP-83).
  , tpLocalObjectStore :: !Text
  -- ^ NAGARE_LOCAL_OBJECT_STORE, the in-cluster S3 endpoint + bucket used for
  -- backups/snapshots in local mode (form @"\<endpoint-url>/\<bucket>"@, e.g.
  -- @"http://minio.nagare-system.svc.cluster.local:9000/nagare-backups"@).
  -- Default @""@ (unset); only read in local mode, where EP-82's profile sets
  -- it. Consumed by EP-84's @StoreBackend@ in 'Nagare.Cluster.GcsJob'.
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
  -- 'parseMode' reads the raw 'Maybe String' from 'lookupEnv' (not 'envOr'): an
  -- empty NAGARE_MODE="" is "not local", which 'parseMode' already yields as 'Cloud'.
  mode <- parseMode <$> lookupEnv "NAGARE_MODE"
  localObjectStore <- envOr "NAGARE_LOCAL_OBJECT_STORE" ""
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
      , tpMode = mode
      , tpLocalObjectStore = localObjectStore
      }

-- | The Kubernetes Secret (in the data-movement Job's namespace) holding the
-- local MinIO credentials (@AWS_ACCESS_KEY_ID@ / @AWS_SECRET_ACCESS_KEY@). EP-84
-- creates it in @cluster/local/minio/minio.yaml@; the @secretKeyRef@ env in the
-- MinIO data-movement Jobs references it by this name.
minioCredentialsSecret :: Text
minioCredentialsSecret = "nagare-minio-credentials"

-- | The object-store backend for a profile and a resolved backup bucket (EP-84,
-- MasterPlan 16 Integration Point 3). This is the __one place__ the cloud-vs-local
-- backend is chosen, from 'tpMode': 'Cloud' yields a 'GcsBackend' (the cloud path
-- is byte-for-byte unchanged); 'Local' parses 'tpLocalObjectStore' into a MinIO
-- endpoint+bucket and yields a 'MinioBackend'. A 'Local' profile whose
-- @NAGARE_LOCAL_OBJECT_STORE@ is unset/malformed is a 'Left' so the caller can
-- fail loudly rather than silently target GCS from a laptop.
storeBackendFor :: TargetProfile -> Text -> Either Text StoreBackend
storeBackendFor tp bucket = case tpMode tp of
  Cloud -> Right (GcsBackend (tpProject tp) bucket)
  Local -> case parseLocalObjectStore (tpLocalObjectStore tp) of
    Just (endpoint, b) -> Right (MinioBackend (MinioRef endpoint b minioCredentialsSecret))
    Nothing ->
      Left
        ( "local mode (NAGARE_MODE=local) requires NAGARE_LOCAL_OBJECT_STORE to be set to "
            <> "\"<endpoint-url>/<bucket>\" (e.g. "
            <> "http://minio.nagare-system.svc.cluster.local:9000/nagare-backups); "
            <> "it is currently "
            <> (if T.null (tpLocalObjectStore tp) then "unset" else "malformed: " <> tpLocalObjectStore tp)
        )

-- | Read an env var, falling back to @def@ when it is unset OR set to the empty
-- string. Returns 'Text' for direct use in the record.
envOr :: String -> Text -> IO Text
envOr name def = do
  m <- lookupEnv name
  pure $ case m of
    Just v | not (null v) -> T.pack v
    _ -> def
