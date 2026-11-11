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
  , IngressMode (..)
  , parseIngressMode
  , ingressModeToken
  , checkIngressMode
  , hostShapeFor
  , directIngressNotice
  )
where

import Data.Char (toLower)
import Data.Text (Text, pack)
import Nagare.Deploy.Host (HostShape (..))
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

-- | Where a context keeps its inventory: a workstation directory, GCS for a
-- cloud context, or a local context's in-cluster object store (EP-251).
data InventoryStoreKind = InventoryStoreLocal | InventoryStoreGcs | InventoryStoreObject
  deriving stock (Eq, Show)

parseInventoryStoreKind :: Maybe String -> InventoryStoreKind
parseInventoryStoreKind raw = case fmap (map toLower) raw of
  Just "gcs" -> InventoryStoreGcs
  Just "object" -> InventoryStoreObject
  _ -> InventoryStoreLocal

inventoryStoreToken :: InventoryStoreKind -> Text
inventoryStoreToken InventoryStoreLocal = "local"
inventoryStoreToken InventoryStoreGcs = "gcs"
inventoryStoreToken InventoryStoreObject = "object"

-- | How web traffic reaches a context's gateway (MasterPlan 32, ADR 34). 'IngressDirect'
-- is the VM's public address and the default; 'IngressCloudflareTunnel' is one tunnel
-- on a full Cloudflare zone.
data IngressMode = IngressDirect | IngressCloudflareTunnel
  deriving stock (Eq, Show)

-- | Parse @NAGARE_INGRESS@. Unlike the other kinds this one refuses an unknown value
-- instead of defaulting: a typo must not silently leave a context on the ingress the
-- operator meant to close.
parseIngressMode :: Maybe String -> Either Text IngressMode
parseIngressMode raw = case raw of
  Nothing -> Right IngressDirect
  Just "" -> Right IngressDirect
  Just "direct" -> Right IngressDirect
  Just "cloudflare-tunnel" -> Right IngressCloudflareTunnel
  Just other -> Left ("NAGARE_INGRESS must be direct or cloudflare-tunnel, not " <> pack other)

-- | One informational line on a direct cloud context (EP-244). @NAGARE_INGRESS_NOTICE=off@ in the context
-- silences it; it is never a check, so it makes no call and changes no exit code.
directIngressNotice :: Mode -> IngressMode -> Maybe Text -> Maybe Text
directIngressNotice Cloud IngressDirect setting
  | setting /= Just "off" =
      Just "Note: this context's web ports are open to the internet. docs/user/choosing-ingress.md explains the alternative."
directIngressNotice _ _ _ = Nothing

hostShapeFor :: IngressMode -> HostShape
hostShapeFor IngressDirect = NestedHosts
hostShapeFor IngressCloudflareTunnel = FlatHosts

ingressModeToken :: IngressMode -> Text
ingressModeToken IngressDirect = "direct"
ingressModeToken IngressCloudflareTunnel = "cloudflare-tunnel"

-- | A tunnel needs a Cloudflare zone and a cloud VM, and a local context has neither. It also
-- replaces the DNS-01 issuer, so reviewed cloud-domain TLS cannot be on (ADR 34).
checkIngressMode :: IngressMode -> Bool -> Bool -> Either Text ()
checkIngressMode IngressDirect _ _ = Right ()
checkIngressMode IngressCloudflareTunnel isLocal externalDomainTls
  | isLocal = Left "NAGARE_INGRESS=cloudflare-tunnel is cloud-only; local contexts use their loopback ingress"
  | externalDomainTls =
      Left "NAGARE_INGRESS=cloudflare-tunnel requires NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED=0: Cloudflare's edge certificate serves the zone"
  | otherwise = Right ()

-- | NAGARE_BACKUP_RECOVERY_POINT (MasterPlan 23, D6). Only an explicit
-- @daily@ relaxes the objective; any other value keeps the stricter hourly
-- preset. @scripts/lib/target.sh@ rejects unknown values before this point.
parseBackupRecoveryPoint :: Maybe String -> RecoveryPointObjective
parseBackupRecoveryPoint raw = case fmap (map toLower) raw of
  Just "daily" -> DailyRecoveryPoint
  _ -> HourlyRecoveryPoint
