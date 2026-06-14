-- | The reusable, typed probe layer behind the @nagarectl server status@ /
-- @doctor@ / @domains@ / @cleanup@ operator commands (MasterPlan 8).
--
-- This module owns the Integration-Point types and helpers the sibling plans
-- build on:
--
--   * __IP1__ — the typed check/status model ('ProbeStatus', 'Probe') and the
--     pure 'renderInventory'/'statusLabel' formatters. @nagarectl doctor@
--     (@docs/plans/39-...@) re-grades the same 'Probe' values; @domains@/@cleanup@
--     reuse the formatting.
--   * __IP4__ — the external-tool wrappers ('captureTool', 'runMaybe') and the
--     graceful-degradation convention: a probe whose data source is unreachable
--     yields a 'StatusUnknown' line, never an uncaught exception.
--
-- The pure parsers ('parseNodeReady', 'parseDeploymentReady', 'parseKourierIp',
-- 'parseConfigDomain', 'parseClusterIssuerReady', 'parseNewestBackupAge',
-- 'parseDfUsage') are separated from the @kubectl@/@gcloud@/@gsutil@ IO so they
-- are unit-testable without a live cluster (see @test/Spec.hs@,
-- @testGroup "Nagare.Ops"@). The probes that call them live in
-- "Nagare.Ops.Status".
module Nagare.Ops.Probe
  ( -- * The typed probe model (Integration Point IP1)
    ProbeStatus (..)
  , Probe (..)
  , InventoryOpts (..)

    -- * Rendering
  , renderInventory
  , statusLabel

    -- * Tool wrappers (Integration Point IP4)
  , captureTool
  , runMaybe

    -- * Pure parsers (unit-tested)
  , parseNodeReady
  , parseDeploymentReady
  , parseKourierIp
  , parseConfigDomain
  , parseClusterIssuerReady
  , parseNewestBackupAge
  , parseDfUsage

    -- * EP-4 doctor-correctness helpers (unit-tested)
  , parseNodeExternalIp
  , KourierEvidence (..)
  , gradeKourier
  , parseSkipTagResolvingHosts
  , parseNodeArch
  , gradeArch
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Control.Exception (IOException, catch)
import Data.Aeson (decodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.List (find)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Vector qualified as V
import System.Exit (ExitCode (..))

-- ---------------------------------------------------------------------------
-- The typed probe model (Integration Point IP1)

-- | The grade of a single inspected platform facet. The field names here are
-- final and read back verbatim by EP-39/40/41.
data ProbeStatus = StatusOk | StatusWarn | StatusUnknown | StatusFail
  deriving stock (Eq, Show)

-- | One inspected platform facet and its observed state. @probeName@ is the
-- left-column label (e.g. @"VM"@, @"k3s node"@, @"Kourier ingress"@);
-- @probeDetail@ is the right-column human description (e.g. @"RUNNING"@,
-- @"EXTERNAL-IP 34.x = publicIp"@).
data Probe = Probe
  { probeName :: !Text
  , probeStatus :: !ProbeStatus
  , probeDetail :: !Text
  }
  deriving stock (Eq, Show)

-- | The knobs 'Nagare.Ops.Status.gatherInventory' reads. Kept a record so EP-39
-- can add fields without breaking callers.
data InventoryOpts = InventoryOpts
  { ioZone :: !Text
  -- ^ compute zone, e.g. @"us-west1-a"@
  , ioInstance :: !Text
  -- ^ VM instance name, e.g. @"nagare-01"@
  , ioPulumiDir :: !FilePath
  -- ^ Pulumi project dir, e.g. @"infra/pulumi"@
  , ioSkipVm :: !Bool
  -- ^ when 'True', skip the best-effort IAP-SSH disk probe
  }
  deriving stock (Show)

-- ---------------------------------------------------------------------------
-- Rendering

-- | The short uppercase label for a status, as it appears in the STATUS column.
statusLabel :: ProbeStatus -> Text
statusLabel = \case
  StatusOk -> "OK"
  StatusWarn -> "WARN"
  StatusUnknown -> "UNKNOWN"
  StatusFail -> "FAIL"

-- | Render probes as an aligned @STATUS / CHECK / DETAIL@ table. Pure and unit
-- tested. The @pad@ helper is copied verbatim from
-- 'Nagare.App.formatAppList' so the operator tables share one look.
renderInventory :: [Probe] -> Text
renderInventory ps = T.unlines (header : map row ps)
  where
    header = "  " <> pad 9 "STATUS" <> pad 25 "CHECK" <> "DETAIL"
    row p = "  " <> pad 9 (statusLabel (probeStatus p)) <> pad 25 (probeName p) <> probeDetail p
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

-- ---------------------------------------------------------------------------
-- Tool wrappers (Integration Point IP4)

-- | Run a tool, capturing stdout and tolerating a non-zero exit; a missing
-- binary (an 'IOException' from @cradle@) yields 'Nothing' rather than throwing.
-- The @cradle@ 'run' already avoids throwing on a non-zero exit, so we only
-- guard the 'IOException' case. This is the foundation of the IP4 degradation
-- convention every later plan inherits.
captureTool :: String -> [String] -> IO (Maybe ByteString)
captureTool exe args =
  capture `catch` \(_ :: IOException) -> pure Nothing
  where
    capture = do
      (code, StdoutRaw out) <- run $ cmd exe & addArgs args & silenceStderr
      pure $ case code of
        ExitSuccess -> Just out
        ExitFailure _ -> Nothing

-- | Lift "no data" into a 'StatusUnknown' 'Probe' carrying a short hint; when
-- data is present, grade it with the supplied continuation. The canonical way a
-- probe degrades gracefully.
runMaybe :: Text -> Text -> Maybe a -> (a -> Probe) -> IO Probe
runMaybe name hint m k = pure $ maybe (Probe name StatusUnknown hint) k m

-- ---------------------------------------------------------------------------
-- Pure JSON walk helpers (copied from Nagare.App so this module stays
-- self-contained)

-- | Walk a chain of object keys, returning the value at the end (or 'Nothing'
-- if any key is missing or a non-object is hit).
lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] v = Just v
lookupPath (k : ks) (Aeson.Object o) = KeyMap.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing

-- | The 'Text' at an object path, or 'Nothing'.
textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (Aeson.String s) -> Just s
  _ -> Nothing

-- | Whether @.status.conditions[]@ contains a condition of the given @type@
-- whose @status@ is @"True"@.
conditionTrue :: Text -> Aeson.Value -> Bool
conditionTrue ty v =
  case lookupPath ["status", "conditions"] v of
    Just (Aeson.Array conds) ->
      case find (\c -> textAt ["type"] c == Just ty) (V.toList conds) of
        Just c -> textAt ["status"] c == Just "True"
        Nothing -> False
    _ -> False

-- ---------------------------------------------------------------------------
-- Pure parsers (unit-tested)

-- | 'True' iff the first node's @Ready@ condition has @status=="True"@, from
-- @kubectl get nodes -o json@. 'Nothing' on a shape that is not a node list
-- (e.g. a non-k3s context that returns something unexpected) or malformed JSON.
parseNodeReady :: ByteString -> Maybe Bool
parseNodeReady bs = do
  v <- decodeStrict bs
  Aeson.Array items <- lookupPath ["items"] v
  node <- items V.!? 0
  Aeson.Array conds <- lookupPath ["status", "conditions"] node
  ready <- find (\c -> textAt ["type"] c == Just "Ready") (V.toList conds)
  pure (textAt ["status"] ready == Just "True")

-- | 'True' iff the named Deployment is rolled out: @.status.availableReplicas
-- >= 1@ and its @Available@ condition is @"True"@. Accepts either a single
-- Deployment object (@kubectl get deploy NAME -o json@) or a list response,
-- selecting by @.metadata.name@ in the list case. 'Nothing' on malformed JSON.
parseDeploymentReady :: ByteString -> Text -> Maybe Bool
parseDeploymentReady bs name = do
  v <- decodeStrict bs
  dep <- selectByName name v
  let available = case lookupPath ["status", "availableReplicas"] dep of
        Just (Aeson.Number n) -> n >= 1
        _ -> False
  pure (available && conditionTrue "Available" dep)

-- | Select the matching Deployment from either a list response (find the item
-- whose @.metadata.name@ equals @name@) or a single object (returned as-is).
selectByName :: Text -> Aeson.Value -> Maybe Aeson.Value
selectByName name v =
  case lookupPath ["items"] v of
    Just (Aeson.Array items) ->
      find (\it -> textAt ["metadata", "name"] it == Just name) (V.toList items)
    _ -> Just v

-- | The Kourier @LoadBalancer@ Service's @EXTERNAL-IP@, from
-- @.status.loadBalancer.ingress[0].ip@. 'Nothing' before the IP is assigned.
parseKourierIp :: ByteString -> Maybe Text
parseKourierIp bs = do
  v <- decodeStrict bs
  Aeson.Array ingress <- lookupPath ["status", "loadBalancer", "ingress"] v
  first <- ingress V.!? 0
  textAt ["ip"] first

-- | The configured base domain: the single non-comment top-level key under
-- @.data@ of the @config-domain@ ConfigMap (its value is conventionally empty;
-- the /key/ is the domain). Keys beginning with @_@ (e.g. @_example@) are
-- skipped. 'Nothing' when no real domain key is present.
parseConfigDomain :: ByteString -> Maybe Text
parseConfigDomain bs = do
  v <- decodeStrict bs
  Aeson.Object dat <- lookupPath ["data"] v
  let keys = [k | k <- map Key.toText (KeyMap.keys dat), not ("_" `T.isPrefixOf` k)]
  find (const True) keys

-- | 'True' iff the @letsencrypt-dns@ ClusterIssuer's @Ready@ condition is
-- @"True"@, from @kubectl get clusterissuer letsencrypt-dns -o json@.
parseClusterIssuerReady :: ByteString -> Maybe Bool
parseClusterIssuerReady bs = do
  v <- decodeStrict bs
  Aeson.Array _ <- lookupPath ["status", "conditions"] v
  pure (conditionTrue "Ready" v)

-- | The newest object's timestamp (as raw RFC3339 text) from @gsutil ls -l@
-- output, ignoring the trailing @TOTAL:@ line. 'Nothing' when the prefix is
-- empty. Clock-free (the caller turns the timestamp into a human age), so this
-- stays testable.
parseNewestBackupAge :: Text -> Maybe Text
parseNewestBackupAge out =
  let stamps =
        [ t
        | ln <- T.lines out
        , not ("TOTAL:" `T.isPrefixOf` T.stripStart ln)
        , (_size : t : _) <- [T.words ln]
        , "T" `T.isInfixOf` t -- crude RFC3339 filter
        ]
   in if null stamps then Nothing else Just (maximum stamps)

-- | Extract a @"<Use%> of <Size>"@ description for a given mountpoint from
-- @df -h@ output. The standard six columns are
-- @Filesystem Size Used Avail Use% MountedOn@, so we match the line whose final
-- word is the mountpoint and read columns 4 (Use%) and 1 (Size). 'Nothing' when
-- the mountpoint is absent.
parseDfUsage :: Text -> Text -> Maybe Text
parseDfUsage out mount = do
  let rows = [ws | ln <- T.lines out, let ws = T.words ln, length ws >= 6, last ws == mount]
  row <- find (const True) rows
  pure (row !! 4 <> " of " <> row !! 1)

-- ---------------------------------------------------------------------------
-- EP-4 (MasterPlan 13): doctor-correctness helpers

-- | The first node's @ExternalIP@ from @kubectl get nodes -o json@
-- (@.items[0].status.addresses[]@ where @type == "ExternalIP"@). 'Nothing' when
-- no ExternalIP is advertised — the normal k3s ServiceLB case.
parseNodeExternalIp :: ByteString -> Maybe Text
parseNodeExternalIp bs = do
  v <- decodeStrict bs
  Aeson.Array items <- lookupPath ["items"] v
  node <- items V.!? 0
  Aeson.Array addrs <- lookupPath ["status", "addresses"] node
  addr <- find (\a -> textAt ["type"] a == Just "ExternalIP") (V.toList addrs)
  textAt ["address"] addr

-- | The evidence the Kourier-ingress grader weighs (EP-4 M1). Gathered by the IO
-- probe in "Nagare.Ops.Status"; graded purely by 'gradeKourier' so every branch
-- is unit-testable without a cluster.
data KourierEvidence = KourierEvidence
  { keLbExternalIp :: !(Maybe Text)
  -- ^ the Kourier LoadBalancer EXTERNAL-IP ('parseKourierIp')
  , kePublicIp :: !(Maybe Text)
  -- ^ the Pulumi @publicIp@ output
  , keHttpCode :: !(Maybe Text)
  -- ^ a curl @%{http_code}@ against @http://\<publicIp>/@; 'Nothing' if curl is
  -- absent or returned @000@
  , keNodeExternalIp :: !(Maybe Text)
  -- ^ the node's advertised ExternalIP ('parseNodeExternalIp')
  }
  deriving stock (Eq, Show)

-- | Grade the Kourier ingress from gathered evidence (EP-4 M1). Reachability is
-- the ground truth: any HTTP response on the reserved public IP proves the
-- gateway serves (k3s ServiceLB assigns the NODE IP as the LB EXTERNAL-IP, so the
-- old @EXTERNAL-IP == publicIp@ equality false-FAILed a healthy cluster). When
-- curl is unavailable, fall back to confirming the node's ExternalIP equals the
-- public IP; if even that is inconclusive, WARN — never FAIL on a healthy
-- ServiceLB cluster.
gradeKourier :: KourierEvidence -> Probe
gradeKourier ev = case keLbExternalIp ev of
  Nothing -> Probe nm StatusFail "no EXTERNAL-IP assigned to the Kourier LoadBalancer"
  Just lbIp -> case keHttpCode ev of
    Just code ->
      Probe nm StatusOk ("serving on " <> publicIpStr <> " (HTTP " <> code <> "; LB EXTERNAL-IP " <> lbIp <> ")")
    Nothing -> case (kePublicIp ev, keNodeExternalIp ev) of
      (Just want, Just nodeExt)
        | nodeExt == want -> Probe nm StatusOk ("LB EXTERNAL-IP " <> lbIp <> " fronted by " <> want <> " (node ExternalIP)")
        | otherwise -> Probe nm StatusFail ("node ExternalIP " <> nodeExt <> " != publicIp " <> want)
      (Just want, Nothing) ->
        Probe nm StatusWarn ("LB EXTERNAL-IP " <> lbIp <> "; could not confirm it is fronted by publicIp " <> want <> " (curl unavailable, node ExternalIP not advertised)")
      (Nothing, _) ->
        Probe nm StatusWarn ("LB EXTERNAL-IP " <> lbIp <> " (publicIp unknown)")
  where
    nm = "Kourier ingress"
    publicIpStr = fromMaybe "the public IP" (kePublicIp ev)

-- | The registry hosts listed in @config-deployment@'s
-- @.data.registriesSkippingTagResolving@ (a comma-separated string), trimmed and
-- with empties dropped (EP-4 M2). @Just []@ when @.data@ is present but the key
-- is absent; 'Nothing' only on undecodable JSON.
parseSkipTagResolvingHosts :: ByteString -> Maybe [Text]
parseSkipTagResolvingHosts bs = do
  v <- decodeStrict bs
  pure $ case textAt ["data", "registriesSkippingTagResolving"] v of
    Just s -> filter (not . T.null) (map T.strip (T.splitOn "," s))
    Nothing -> []

-- | The first node's architecture from @kubectl get nodes -o json@
-- (@.items[0].status.nodeInfo.architecture@, e.g. @"amd64"@). 'Nothing' on
-- malformed JSON (EP-4 M3).
parseNodeArch :: ByteString -> Maybe Text
parseNodeArch bs = do
  v <- decodeStrict bs
  Aeson.Array items <- lookupPath ["items"] v
  node <- items V.!? 0
  textAt ["status", "nodeInfo", "architecture"] node

-- | Grade a Docker platform string (e.g. @"linux/arm64"@) against the node arch
-- (e.g. @"amd64"@), comparing the platform's arch token (segment after the first
-- @/@, ignoring any @/variant@) case-insensitively (EP-4 M3). OK on match, WARN
-- otherwise (a mismatch is advisory — it never gates @doctor@'s exit code).
gradeArch :: Text -> Text -> Probe
gradeArch platform nodeArch =
  if T.toLower archTok == T.toLower nodeArch
    then Probe nm StatusOk (platform <> " matches node " <> nodeArch)
    else Probe nm StatusWarn (platform <> " will not run on " <> nodeArch <> " node")
  where
    nm = "build platform"
    archTok = case T.splitOn "/" platform of
      (_os : arch : _) -> arch
      _ -> platform
