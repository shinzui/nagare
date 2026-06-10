{-# LANGUAGE PackageImports #-}

-- | Assemble the full platform inventory for @nagarectl server status@
-- (MasterPlan 8, EP-38).
--
-- 'gatherInventory' runs every probe in report order and returns a @['Probe']@.
-- Each probe is a small @IO Probe@ that reaches exactly one ground-truth source
-- (@gcloud@, @kubectl@, @pulumi@, @gsutil@, or IAP-tunnelled SSH) through the
-- "Nagare.Ops.Probe" wrappers, so a failed or missing source degrades to a
-- 'StatusUnknown'/'StatusWarn' line rather than crashing the command (the IP4
-- convention). All clock access (turning a backup timestamp into a human age)
-- is confined to the IO probes here; the parsers in "Nagare.Ops.Probe" stay
-- pure and unit-tested.
module Nagare.Ops.Status
  ( gatherInventory
  , inventoryOptsFor
  ) where

import Nagare.Dsl.Prelude

import Data.Aeson (decodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time (NominalDiffTime, diffUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)

import Nagare.Ops.Probe
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Target (TargetProfile (..), registryPrefix)

-- | The inventory knobs derived from a resolved 'TargetProfile' (EP-62): the zone
-- and instance come from the profile; the Pulumi project dir is fixed and the
-- disk probe is enabled.
inventoryOptsFor :: TargetProfile -> InventoryOpts
inventoryOptsFor tp =
  InventoryOpts
    { ioZone = tpZone tp
    , ioInstance = tpInstanceName tp
    , ioPulumiDir = "infra/pulumi"
    , ioSkipVm = False
    }

-- | Run every probe in report order and assemble the inventory. The Pulumi
-- stack outputs (@publicIp@, @baseDomain@, @backupBucket@) are read once up
-- front and threaded into the probes that cross-check against them. The backup
-- bucket falls back to the resolved profile's bucket when Pulumi is unreachable.
gatherInventory :: TargetProfile -> InventoryOpts -> IO [Probe]
gatherInventory tp o = do
  publicIp <- stackOutput (ioPulumiDir o) "publicIp"
  baseDomain <- stackOutput (ioPulumiDir o) "baseDomain"
  bucket <- maybe (tpBackupBucket tp) id <$> stackOutput (ioPulumiDir o) "backupBucket"
  core <-
    sequence
      [ probeVm o
      , probeNode
      , probeDeploy "knative-serving" "controller" "Knative controller"
      , probeDeploy "knative-serving" "webhook" "Knative webhook"
      , probeDeploy "kourier-system" "3scale-kourier-gateway" "Kourier gateway"
      , probeDeploy "cert-manager" "cert-manager" "cert-manager"
      , probeDeploy "cert-manager" "cert-manager-webhook" "cert-manager-webhook"
      , probeDeploy "cert-manager" "cert-manager-cainjector" "cert-manager-cainjector"
      , probeDeploy "knative-serving" "net-certmanager-controller" "net-certmanager"
      , probeClusterIssuer
      , probeKourierIp publicIp
      , probeBaseDomain baseDomain
      , probeTls
      , probeRegistryAuth tp
      , probeBackup bucket "postgres"
      , probeBackup bucket "litestream"
      , probeBackup bucket "volumes"
      ]
  disk <- probeDisk o
  pure (core <> disk)

-- ---------------------------------------------------------------------------
-- Individual probes

-- | VM power state via @gcloud … describe … --format=value(status)@.
probeVm :: InventoryOpts -> IO Probe
probeVm o = do
  m <-
    captureTool
      "gcloud"
      [ "compute"
      , "instances"
      , "describe"
      , T.unpack (ioInstance o)
      , "--zone"
      , T.unpack (ioZone o)
      , "--format=value(status)"
      ]
  pure $ case fmap (T.strip . decodeUtf8) m of
    Just "RUNNING" -> Probe "VM" StatusOk "RUNNING"
    Just "TERMINATED" -> Probe "VM" StatusFail "TERMINATED (start: gcloud compute instances start)"
    Just other -> Probe "VM" StatusWarn other
    Nothing -> Probe "VM" StatusUnknown "gcloud unavailable or no access"

-- | k3s node readiness via @kubectl get nodes -o json@.
probeNode :: IO Probe
probeNode = do
  m <- captureTool "kubectl" ["get", "nodes", "-o", "json"]
  runMaybe "k3s node" "no kubeconfig / not reachable" (m >>= parseNodeReady) $ \ready ->
    if ready
      then Probe "k3s node" StatusOk "Ready"
      else Probe "k3s node" StatusFail "NotReady"

-- | A control-plane Deployment rollout via @kubectl get deploy NAME -n NS -o json@.
probeDeploy :: Text -> Text -> Text -> IO Probe
probeDeploy ns dep label = do
  m <- captureTool "kubectl" ["get", "deploy", T.unpack dep, "-n", T.unpack ns, "-o", "json"]
  runMaybe label "no kubeconfig / not reachable" (m >>= \bs -> parseDeploymentReady bs dep) $ \ready ->
    if ready
      then Probe label StatusOk "rolled out"
      else Probe label StatusFail "not rolled out"

-- | The cert-manager @letsencrypt-dns@ ClusterIssuer readiness.
probeClusterIssuer :: IO Probe
probeClusterIssuer = do
  m <- captureTool "kubectl" ["get", "clusterissuer", "letsencrypt-dns", "-o", "json"]
  runMaybe "ClusterIssuer" "letsencrypt-dns not reachable" (m >>= parseClusterIssuerReady) $ \ready ->
    if ready
      then Probe "ClusterIssuer" StatusOk "letsencrypt-dns Ready"
      else Probe "ClusterIssuer" StatusWarn "letsencrypt-dns not Ready"

-- | The Kourier @EXTERNAL-IP@ must equal the Pulumi @publicIp@.
probeKourierIp :: Maybe Text -> IO Probe
probeKourierIp publicIp = do
  m <- captureTool "kubectl" ["get", "svc", "kourier", "-n", "kourier-system", "-o", "json"]
  runMaybe "Kourier ingress" "no kubeconfig / not reachable" (m >>= parseKourierIp) $ \ip ->
    case publicIp of
      Just want
        | want == ip -> Probe "Kourier ingress" StatusOk ("EXTERNAL-IP " <> ip <> " = publicIp")
        | otherwise -> Probe "Kourier ingress" StatusFail ("EXTERNAL-IP " <> ip <> " != publicIp " <> want)
      Nothing -> Probe "Kourier ingress" StatusWarn ("EXTERNAL-IP " <> ip <> " (publicIp unknown)")

-- | The in-cluster @config-domain@ key vs the Pulumi @baseDomain@ output.
probeBaseDomain :: Maybe Text -> IO Probe
probeBaseDomain baseDomain = do
  m <- captureTool "kubectl" ["get", "configmap", "config-domain", "-n", "knative-serving", "-o", "json"]
  runMaybe "base domain" "config-domain not reachable" (m >>= parseConfigDomain) $ \live ->
    case baseDomain of
      Just want
        | want == live -> Probe "base domain" StatusOk (live <> " (= Pulumi baseDomain)")
        | otherwise -> Probe "base domain" StatusWarn (live <> " != Pulumi " <> want)
      Nothing -> Probe "base domain" StatusWarn (live <> " (Pulumi baseDomain unknown)")

-- | Knative @config-network-tls@'s @external-domain-tls@ setting, surfaced as
-- informational (the platform is HTTP-first while the base domain is the
-- placeholder), never a failure.
probeTls :: IO Probe
probeTls = do
  m <- captureTool "kubectl" ["get", "configmap", "config-network-tls", "-n", "knative-serving", "-o", "json"]
  runMaybe "external-domain-tls" "config-network-tls not reachable" (m >>= \bs -> dataValue bs "external-domain-tls") $ \val ->
    if val == "Enabled"
      then Probe "external-domain-tls" StatusOk "Enabled"
      else Probe "external-domain-tls" StatusWarn (val <> " (HTTP-first until base domain is real)")

-- | Artifact Registry push auth via @gcloud artifacts repositories describe@,
-- against the resolved profile's registry id and region (EP-62).
probeRegistryAuth :: TargetProfile -> IO Probe
probeRegistryAuth tp = do
  m <-
    captureTool
      "gcloud"
      [ "artifacts"
      , "repositories"
      , "describe"
      , T.unpack (tpArtifactRegistryId tp)
      , "--location=" <> T.unpack (tpRegion tp)
      ]
  pure $ case m of
    Just _ -> Probe "Artifact Registry" StatusOk (registryPrefix tp <> " reachable")
    Nothing -> Probe "Artifact Registry" StatusUnknown "gcloud unavailable or no access"

-- | The age of the newest object in a backup prefix via @gsutil ls -l@.
probeBackup :: Text -> Text -> IO Probe
probeBackup bucket prefix = do
  let name = "backup " <> prefix
  m <- captureTool "gsutil" ["ls", "-l", "gs://" <> T.unpack bucket <> "/" <> T.unpack prefix <> "/"]
  case m of
    Nothing -> pure (Probe name StatusUnknown "gsutil unavailable or prefix empty")
    Just out ->
      case parseNewestBackupAge (decodeUtf8 out) of
        Nothing -> pure (Probe name StatusWarn "no objects (empty prefix)")
        Just stamp -> do
          now <- getCurrentTime
          case iso8601ParseM (T.unpack stamp) of
            Nothing -> pure (Probe name StatusWarn ("newest object " <> stamp))
            Just t -> do
              let age = diffUTCTime now t
              pure (Probe name (gradeAge age) ("newest object " <> formatAge age))

-- | Boot- and data-disk usage via IAP-tunnelled SSH (best-effort). When
-- @ioSkipVm@ is set, or SSH is not configured, this degrades to a single
-- 'StatusUnknown' line rather than failing the whole report. Requires
-- @SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519@ in the environment (see
-- @docs/runbooks/cluster-access.md@).
probeDisk :: InventoryOpts -> IO [Probe]
probeDisk o
  | ioSkipVm o = pure [Probe "disk" StatusUnknown "skipped (--skip-vm)"]
  | otherwise = do
      m <-
        captureTool
          "scripts/iap-ssh.sh"
          ["ssh", T.unpack (ioInstance o), "--", "df -h /var/lib/nagare /"]
      pure $ case fmap decodeUtf8 m of
        Nothing -> [Probe "disk" StatusUnknown "iap-ssh unavailable (VM off? key not set?)"]
        Just out ->
          [ mk "boot disk" (parseDfUsage out "/")
          , mk "data disk" (parseDfUsage out "/var/lib/nagare")
          ]
  where
    mk nm = maybe (Probe nm StatusUnknown "df parse failed") (Probe nm StatusOk)

-- ---------------------------------------------------------------------------
-- Local helpers

-- | A @.data.<key>@ string value from a ConfigMap JSON; 'Nothing' if absent.
dataValue :: ByteString -> Text -> Maybe Text
dataValue bs key = do
  Aeson.Object root <- decodeStrict bs
  Aeson.Object dat <- KeyMap.lookup "data" root
  Aeson.String s <- KeyMap.lookup (Key.fromText key) dat
  pure s

-- | Grade a backup age: 'StatusOk' under a day old, else 'StatusWarn'.
gradeAge :: NominalDiffTime -> ProbeStatus
gradeAge age = if age < 86400 then StatusOk else StatusWarn

-- | A coarse human age: @\"6h ago\"@, @\"5d ago\"@, @\"12m ago\"@. Negative
-- ages (clock skew) read as @\"just now\"@.
formatAge :: NominalDiffTime -> Text
formatAge d
  | secs < 0 = "just now"
  | days >= 1 = num days <> "d ago"
  | hours >= 1 = num hours <> "h ago"
  | mins >= 1 = num mins <> "m ago"
  | otherwise = num secs <> "s ago"
  where
    secs = realToFrac d :: Double
    mins = secs / 60
    hours = mins / 60
    days = hours / 24
    num x = T.pack (show (floor x :: Int))
