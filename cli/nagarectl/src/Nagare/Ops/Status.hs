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
  , parseHostAgeKeyProbe
  , probeCertificatePolicy
  , probeCertificatePolicyWith
  )
where

import Data.Aeson (decodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List (find)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time (NominalDiffTime, diffUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Nagare.Cluster.CertificatePolicy
  ( certificatePolicyViolations
  , parseCertificateObservations
  , parseLabeledNamespaces
  , renderCertificateViolations
  )
import Nagare.Database.Discover (DbRow (..), listDatabases)
import Nagare.Dsl.Prelude
import Nagare.Host.AgeKey (RemoteAgeKeyStatus (..), parseRemoteAgeKeyStatus)
import Nagare.Ops.Probe
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Target (TargetProfile (..), registryPrefix)

-- | The inventory knobs derived from a resolved 'TargetProfile' (EP-62): the zone
-- and instance come from the profile; the Pulumi project dir is fixed and the
-- disk probe is enabled.
inventoryOptsFor :: FilePath -> FilePath -> TargetProfile -> InventoryOpts
inventoryOptsFor pulumiDir iapSsh tp =
  InventoryOpts
    { zone = tp ^. #zone
    , instanceName = tp ^. #instanceName
    , pulumiDir = pulumiDir
    , iapSsh = iapSsh
    , skipVm = False
    }

-- | Run every probe in report order and assemble the inventory. The Pulumi
-- stack outputs (@publicIp@, @baseDomain@, @backupBucket@) are read once up
-- front and threaded into the probes that cross-check against them. The backup
-- bucket falls back to the resolved profile's bucket when Pulumi is unreachable.
gatherInventory :: TargetProfile -> InventoryOpts -> IO [Probe]
gatherInventory tp o = do
  publicIp <- stackOutput (o ^. #pulumiDir) "publicIp"
  baseDomain <- stackOutput (o ^. #pulumiDir) "baseDomain"
  bucket <- maybe (tp ^. #backupBucket) id <$> stackOutput (o ^. #pulumiDir) "backupBucket"
  dbNames <- either (const []) (map (^. #name)) <$> listDatabases "personal"
  core <-
    sequence
      ( [ probeVm o
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
        , probeCertificatePolicy
        , probeRegistryAuth tp
        , probePrivateImagePull tp
        , probeArch tp
        ]
          <> map (probeBackup bucket) (backupPrefixes dbNames)
      )
  host <- probeHost o
  pure (core <> host)

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
      , T.unpack (o ^. #instanceName)
      , "--zone"
      , T.unpack (o ^. #zone)
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

-- | The Kourier ingress (EP-4 M1). k3s ServiceLB assigns the NODE IP as the LB
-- EXTERNAL-IP while the reserved public IP fronts the node, so the old
-- @EXTERNAL-IP == publicIp@ equality false-FAILed a healthy cluster. Gather the
-- evidence — LB EXTERNAL-IP, the Pulumi @publicIp@, a curl reachability probe of
-- the public IP, and the node's advertised ExternalIP — and delegate to the pure
-- 'gradeKourier'. Signature unchanged so the 'gatherInventory' call site is too.
probeKourierIp :: Maybe Text -> IO Probe
probeKourierIp publicIp = do
  svcJson <- captureTool "kubectl" ["get", "svc", "kourier", "-n", "kourier-system", "-o", "json"]
  nodeJson <- captureTool "kubectl" ["get", "nodes", "-o", "json"]
  let lbIp = svcJson >>= parseKourierIp
      nodeExtIp = nodeJson >>= parseNodeExternalIp
  httpCode <- maybe (pure Nothing) curlHttpCode publicIp
  case lbIp of
    Nothing | svcJson == Nothing -> pure (Probe "Kourier ingress" StatusUnknown "no kubeconfig / not reachable")
    _ ->
      pure $
        gradeKourier
          KourierEvidence
            { loadBalancerExternalIp = lbIp
            , publicIp = publicIp
            , httpCode = httpCode
            , nodeExternalIp = nodeExtIp
            }

-- | Probe HTTP reachability of the gateway at @ip@: run @curl@ for the status
-- code. Returns 'Nothing' when curl is absent or yields @000@/empty (unreachable
-- or no curl); 'Just code' (e.g. @"404"@, which Kourier returns for an unknown
-- Host) proves the public IP routes to a listening gateway.
curlHttpCode :: Text -> IO (Maybe Text)
curlHttpCode ip = do
  m <- captureTool "curl" ["-sS", "-o", "/dev/null", "-m", "5", "-w", "%{http_code}", "http://" <> T.unpack ip <> "/"]
  pure $ case fmap (T.strip . decodeUtf8) m of
    Just code | not (T.null code) && code /= "000" -> Just code
    _ -> Nothing

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

-- | Knative @config-network@'s @external-domain-tls@ setting, surfaced as
-- informational (the platform is HTTP-first while the base domain is the
-- placeholder), never a failure.
probeTls :: IO Probe
probeTls = do
  m <- captureTool "kubectl" ["get", "configmap", "config-network", "-n", "knative-serving", "-o", "json"]
  runMaybe "external-domain-tls" "config-network not reachable" (m >>= \bs -> dataValue bs "external-domain-tls") $ \val ->
    if val == "Enabled"
      then Probe "external-domain-tls" StatusOk "Enabled"
      else Probe "external-domain-tls" StatusWarn (val <> " (HTTP-first until base domain is real)")

-- | Fail closed when a cert-manager Certificate routes an internal name to the
-- public ACME issuer, or when a public wildcard appears outside an opted-in app
-- namespace. Transport and parse failures remain UNKNOWN so doctor does not
-- claim a policy violation without evidence.
probeCertificatePolicy :: IO Probe
probeCertificatePolicy = probeCertificatePolicyWith (captureTool "kubectl")

-- | Probe through an injected kubectl capture function. Qualify cert-manager's
-- Certificate resource explicitly: clusters that also install Knative expose
-- another @Certificate@ kind, and kubectl's short-name resolution is not a
-- stable API contract.
probeCertificatePolicyWith :: ([String] -> IO (Maybe ByteString)) -> IO Probe
probeCertificatePolicyWith captureKubectl = do
  certificates <- captureKubectl ["get", "certificates.cert-manager.io", "-A", "-o", "json"]
  namespaces <-
    captureKubectl
      [ "get"
      , "namespaces"
      , "-l"
      , "nagare.dev/app-namespace=true"
      , "-o"
      , "json"
      ]
  pure $ case (certificates >>= parseCertificateObservations, namespaces >>= parseLabeledNamespaces) of
    (Just observations, Just labeled) ->
      case certificatePolicyViolations labeled observations of
        [] -> Probe "certificate policy" StatusOk "public ACME names are confined to labeled app namespaces"
        violations -> Probe "certificate policy" StatusFail (renderCertificateViolations violations)
    _ -> Probe "certificate policy" StatusUnknown "certificate or namespace inventory not reachable"

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
      , T.unpack (tp ^. #artifactRegistryId)
      , "--location=" <> T.unpack (tp ^. #region)
      ]
  pure $ case m of
    Just _ -> Probe "Artifact Registry" StatusOk (registryPrefix tp <> " reachable")
    Nothing -> Probe "Artifact Registry" StatusUnknown "gcloud unavailable or no access"

-- | Whether the cluster is configured to pull the project's PRIVATE images
-- (EP-4 M2): the registry host must appear in the Knative @config-deployment@
-- ConfigMap's @registriesSkippingTagResolving@ (the capability EP-2 makes
-- declarative). WARN — never FAIL — when absent, so it does not gate the exit
-- code; UNKNOWN when the ConfigMap is unreachable.
probePrivateImagePull :: TargetProfile -> IO Probe
probePrivateImagePull tp = do
  m <- captureTool "kubectl" ["get", "configmap", "config-deployment", "-n", "knative-serving", "-o", "json"]
  let host = tp ^. #registryHost
  runMaybe "private image pull" "config-deployment not reachable" (m >>= parseSkipTagResolvingHosts) $ \hosts ->
    if host `elem` hosts
      then Probe "private image pull" StatusOk (host <> " in registriesSkippingTagResolving")
      else Probe "private image pull" StatusWarn (host <> " not configured for private pull")

-- | Whether the configured build platform matches the node architecture
-- (EP-4 M3): compares @targetPlatform@ (EP-3) against the k3s node's reported
-- architecture. WARN on mismatch (an arm64 image cannot run on the amd64 node),
-- never FAIL; UNKNOWN when the node arch is unreadable.
probeArch :: TargetProfile -> IO Probe
probeArch tp = do
  m <- captureTool "kubectl" ["get", "nodes", "-o", "json"]
  runMaybe "build platform" "node arch not reachable" (m >>= parseNodeArch) $ \arch ->
    gradeArch (tp ^. #targetPlatform) arch

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

-- | Host age-key state plus boot- and data-disk usage through one IAP SSH call.
-- When @skipVm@ is set, or SSH is not configured, both facets degrade to
-- 'StatusUnknown' rather than making an unconfirmed missing-key claim. Requires
-- @SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519@ in the environment (see
-- @docs/runbooks/cluster-access.md@).
probeHost :: InventoryOpts -> IO [Probe]
probeHost o
  | o ^. #skipVm =
      pure
        [ Probe "host age key" StatusUnknown "skipped (--skip-vm)"
        , Probe "disk" StatusUnknown "skipped (--skip-vm)"
        ]
  | otherwise = do
      m <-
        captureTool
          (o ^. #iapSsh)
          [ "ssh"
          , T.unpack (o ^. #instanceName)
          , "--"
          , "if [ -x /run/current-system/sw/bin/nagare-host-age-key ]; then "
              <> "sudo -- /run/current-system/sw/bin/nagare-host-age-key status || "
              <> "printf 'age-key\\tunknown\\t-\\thost helper failed\\n'; "
              <> "else printf 'age-key\\tunknown\\t-\\thost helper is not installed\\n'; fi; "
              <> "df -h /var/lib/nagare /"
          ]
      pure $ case fmap decodeUtf8 m of
        Nothing ->
          [ Probe "host age key" StatusUnknown "iap-ssh unavailable (VM off? SSH key not set?)"
          , Probe "disk" StatusUnknown "iap-ssh unavailable (VM off? SSH key not set?)"
          ]
        Just out ->
          [ parseHostAgeKeyProbe (encodeUtf8 out)
          , mk "boot disk" (parseDfUsage out "/")
          , mk "data disk" (parseDfUsage out "/var/lib/nagare")
          ]
  where
    mk nm = maybe (Probe nm StatusUnknown "df parse failed") (Probe nm StatusOk)

-- | Grade the first tab-delimited age-key record in the combined host output.
-- The surrounding output may contain @df@ lines; malformed or absent records
-- stay UNKNOWN because transport success alone does not prove key absence.
parseHostAgeKeyProbe :: ByteString -> Probe
parseHostAgeKeyProbe output =
  case find ("age-key\t" `BS.isPrefixOf`) (BC.lines output) of
    Nothing -> Probe "host age key" StatusUnknown "host age-key status record is missing"
    Just record ->
      case parseRemoteAgeKeyStatus record of
        Left err -> Probe "host age key" StatusUnknown err
        Right status -> case status of
          AgeKeyReady keyPath digest ->
            Probe "host age key" StatusOk ("ready at " <> T.pack keyPath <> " (sha256 " <> digest <> ")")
          AgeKeyMissing _ detail -> Probe "host age key" StatusFail detail
          AgeKeyInvalid keyPath detail ->
            Probe "host age key" StatusFail ("age key invalid at " <> T.pack keyPath <> ": " <> detail)
          AgeKeyStatusUnsupported detail -> Probe "host age key" StatusUnknown detail

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
