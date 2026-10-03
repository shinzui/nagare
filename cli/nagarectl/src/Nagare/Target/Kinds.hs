-- | Context-setting value kinds read from the target profile. Each parser
-- defaults unknown values to the fail-safe choice; "Nagare.Target" re-exports
-- them, so callers keep importing from there.
module Nagare.Target.Kinds
  ( Mode (..)
  , parseMode
  , PulumiBackendKind (..)
  , parsePulumiBackendKind
  , pulumiBackendToken
  , InventoryStoreKind (..)
  , parseInventoryStoreKind
  , inventoryStoreToken
  , parseBackupRecoveryPoint
  )
where

import Data.Char (toLower)
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (..))

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

-- | Which backend Pulumi stores stack state in for a context (EP-93). 'PulumiBackendLocal'
-- is EP-90's per-context @file://@ backend and is the default and the only local-mode
-- option; 'PulumiBackendGcs' is an opt-in remote Google Cloud Storage backend for
-- @mode=cloud@ contexts. Resolved from @NAGARE_PULUMI_BACKEND@; unset is 'PulumiBackendLocal',
-- so existing contexts keep their local file state.
data PulumiBackendKind = PulumiBackendLocal | PulumiBackendGcs
  deriving stock (Eq, Show)

-- | Parse @NAGARE_PULUMI_BACKEND@. Only @"gcs"@ (case-insensitive) selects GCS; anything
-- else — including 'Nothing' (unset), @"local"@, and any typo — is 'PulumiBackendLocal'.
-- Defaulting the unknown case to local keeps the fail-safe direction: a misspelling never
-- silently points state at a remote bucket.
parsePulumiBackendKind :: Maybe String -> PulumiBackendKind
parsePulumiBackendKind m = case fmap (map toLower) m of
  Just "gcs" -> PulumiBackendGcs
  _ -> PulumiBackendLocal

-- | The @NAGARE_PULUMI_BACKEND@ token for a backend kind (the inverse of
-- 'parsePulumiBackendKind'), used by the context-file renderer.
pulumiBackendToken :: PulumiBackendKind -> Text
pulumiBackendToken PulumiBackendLocal = "local"
pulumiBackendToken PulumiBackendGcs = "gcs"

data InventoryStoreKind = InventoryStoreLocal | InventoryStoreGcs
  deriving stock (Eq, Show)

parseInventoryStoreKind :: Maybe String -> InventoryStoreKind
parseInventoryStoreKind raw = case fmap (map toLower) raw of
  Just "gcs" -> InventoryStoreGcs
  _ -> InventoryStoreLocal

inventoryStoreToken :: InventoryStoreKind -> Text
inventoryStoreToken InventoryStoreLocal = "local"
inventoryStoreToken InventoryStoreGcs = "gcs"

-- | NAGARE_BACKUP_RECOVERY_POINT (MasterPlan 23, D6). Only an explicit
-- @daily@ relaxes the objective; any other value keeps the stricter hourly
-- preset. @scripts/lib/target.sh@ rejects unknown values before this point.
parseBackupRecoveryPoint :: Maybe String -> RecoveryPointObjective
parseBackupRecoveryPoint raw = case fmap (map toLower) raw of
  Just "daily" -> DailyRecoveryPoint
  _ -> HourlyRecoveryPoint
