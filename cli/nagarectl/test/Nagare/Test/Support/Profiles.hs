-- | Support.Profiles responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Support.Profiles
  ( initProfile
  , tnbProfile
  , hourlyGcsBackup
  )
where

import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (..))
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Target
  ( InventoryStoreKind (InventoryStoreLocal)
  , Mode (Cloud)
  , PulumiBackendKind (PulumiBackendLocal)
  , TargetProfile (..)
  )

-- ---------------------------------------------------------------------------
-- Nagare.Init (MasterPlan 12, EP-63): the pure pieces of `nagarectl init` — the
-- env-file rendering, the twelve Pulumi seed keys, the config-set argv, the
-- operator-role list, and the next-steps text.

initProfile :: TargetProfile
initProfile =
  TargetProfile
    { project = "acme-prod"
    , region = "us-west1"
    , zone = "us-west1-a"
    , registryHost = "us-west1-docker.pkg.dev"
    , artifactRegistryId = "nagare"
    , imageBucket = "acme-prod-nagare-images"
    , backupBucket = "acme-prod-nagare-backups"
    , nixCacheEnabled = False
    , cdnEnabled = False
    , nixCacheBucket = "acme-prod-nagare-nix-cache"
    , baseDomain = "apps.acme.com"
    , externalDomainTlsEnabled = False
    , instanceName = "nagare-01"
    , serviceAccountId = "nagare-node"
    , machineType = "e2-standard-2"
    , bootDiskType = "pd-balanced"
    , bootDiskSizeGb = "100"
    , dataDiskSizeGb = "100"
    , targetPlatform = "linux/amd64"
    , mode = Cloud
    , localObjectStore = ""
    , pulumiBackend = PulumiBackendLocal
    , pulumiBackendUrl = ""
    , pulumiBackendMember = Nothing
    , inventoryStore = InventoryStoreLocal
    , inventoryStoreUrl = ""
    , backupRecoveryPoint = HourlyRecoveryPoint
    , acmeEmail = "ops@acme.example"
    , acmeDirectory = "production"
    , platformVersion = Just "0.1.0"
    }

-- ---------------------------------------------------------------------------
-- Nagare.Target (MasterPlan 12, EP-62): the single GCP-target resolution layer.
-- These assertions mutate the process environment, so they run as ONE sequential
-- testCase (tasty runs cases in parallel) and restore the original environment at
-- the end so no other group observes the mutation.

-- | A fixed 'TargetProfile' carrying the tan-nb-exp worked-example values, for
-- tests that need a profile but assert against the historic defaults (EP-62).
tnbProfile :: TargetProfile
tnbProfile =
  TargetProfile
    { project = "tan-nb-exp"
    , region = "us-west1"
    , zone = "us-west1-a"
    , registryHost = "us-west1-docker.pkg.dev"
    , artifactRegistryId = "nagare"
    , imageBucket = "tan-nb-exp-nagare-images"
    , backupBucket = "tan-nb-exp-nagare-backups"
    , nixCacheEnabled = False
    , cdnEnabled = False
    , nixCacheBucket = "tan-nb-exp-nagare-nix-cache"
    , baseDomain = "apps.example.com"
    , externalDomainTlsEnabled = False
    , instanceName = "nagare-01"
    , serviceAccountId = "nagare-node"
    , machineType = "e2-standard-2"
    , bootDiskType = "pd-balanced"
    , bootDiskSizeGb = "100"
    , dataDiskSizeGb = "100"
    , targetPlatform = "linux/amd64"
    , mode = Cloud
    , localObjectStore = ""
    , pulumiBackend = PulumiBackendLocal
    , pulumiBackendUrl = ""
    , pulumiBackendMember = Nothing
    , inventoryStore = InventoryStoreLocal
    , inventoryStoreUrl = ""
    , backupRecoveryPoint = HourlyRecoveryPoint
    , acmeEmail = ""
    , acmeDirectory = "production"
    , platformVersion = Nothing
    }

-- | The default scheduled backup target used by database compiler fixtures.
hourlyGcsBackup :: DatabaseBackupTarget
hourlyGcsBackup = DatabaseBackupTarget (GcsBackend "project" "bucket") HourlyRecoveryPoint
