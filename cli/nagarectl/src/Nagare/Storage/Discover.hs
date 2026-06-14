-- | Shared persistent-volume discovery for the @nagarectl storage@ commands
-- (EP-35, MasterPlan Integration Point IP5).
--
-- This module owns the PVC label selector, the defensive @kubectl get pvc -o
-- json@ parse, the node-path enrichment, and the @storage list@ table
-- formatter. The pure parts ('appPVCLabelSelector', 'extractPVCStatus',
-- 'formatStorageTable') are separated from the @kubectl@ IO so they are
-- unit-testable without a cluster. EP-36
-- (@docs/plans/36-app-volume-backup-ownership-snapshot-to-gcs-and-retention.md@)
-- reuses 'listAppPVCs' / 'appPVCLabelSelector' to discover the same PVCs by the
-- same labels — it must extend, not fork, this module.
--
-- Per IP3 the PVC name and labels are owned by EP-34's renderer
-- (@Nagare.Dsl.Render@); this module re-exports 'pvcName' and queries by the
-- @nagare.dev/app@ label, never re-deriving the name by hand.
module Nagare.Storage.Discover
  ( -- * Label selector (pure)
    appPVCLabelSelector

    -- * PVC rows
  , PVCRow (..)
  , extractPVCStatus
  , listAppPVCs
  , readPVNodePath

    -- * Table formatting (pure)
  , formatStorageTable

    -- * Re-exports from the EP-34 renderer (IP3)
  , pvcName
  ) where

import Nagare.Dsl.Prelude

import Data.Generics.Labels ()

import Cradle
import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.List (find)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Dsl.Render (pvcName)
import Nagare.Dsl.Types (Volume, quantityText, volumeNameText)
import System.Exit (ExitCode (..))

-- | The label selector that finds an app's Nagare-managed PVCs (IP3):
-- @appPVCLabelSelector "myapp" == "nagare.dev/app=myapp"@. EP-35 and EP-36 query
-- by this, never by re-deriving the PVC name.
appPVCLabelSelector :: Text -> Text
appPVCLabelSelector app = "nagare.dev/app=" <> app

-- | One discovered PVC, joined back to its declared volume by the
-- @nagare.dev/volume@ label. 'prNodePath' is enriched from the bound PV in IO
-- ('listAppPVCs'); 'extractPVCStatus' leaves it empty (it is not in the PVC
-- JSON). 'prPvName' is the bound PV name (@""@ when still @Pending@).
data PVCRow = PVCRow
  { prVolume :: !Text
  , prName :: !Text
  , prSize :: !Text
  , prStatus :: !Text
  , prPvName :: !Text
  , prNodePath :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Parse a @kubectl get pvc -n <ns> -l nagare.dev/app=<app> -o json@ list
-- response into rows. Defensive (mirrors @Nagare.App.extractAppSummaries@): an
-- empty/absent @items@ array is @Right []@, a malformed top-level shape is a
-- 'Left', and a single odd item is skipped rather than crashing. 'prNodePath'
-- is left empty here and filled by 'listAppPVCs'.
extractPVCStatus :: ByteString -> Either Text [PVCRow]
extractPVCStatus bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode pvc list JSON: " <> T.pack e)
    Right v -> case lookupPath ["items"] v of
      Just (Aeson.Array items) -> Right (foldr step [] (V.toList items))
      _ -> Right []
  where
    step item acc = case rowFromItem item of
      Just r -> r : acc
      Nothing -> acc

-- | Build a 'PVCRow' from one decoded PVC object. Returns 'Nothing' for an item
-- with no @.metadata.name@ (so a malformed entry is skipped, not fatal).
rowFromItem :: Aeson.Value -> Maybe PVCRow
rowFromItem item = do
  name <- textAt ["metadata", "name"] item
  pure
    PVCRow
      { prVolume = fromMaybe "" (labelAt "nagare.dev/volume" item)
      , prName = name
      , prSize = fromMaybe "" (textAt ["spec", "resources", "requests", "storage"] item)
      , prStatus = fromMaybe "Pending" (textAt ["status", "phase"] item)
      , prPvName = fromMaybe "" (textAt ["spec", "volumeName"] item)
      , prNodePath = ""
      }

-- | List an app's PVCs in @ns@ via @kubectl get pvc -l <selector> -o json@, then
-- enrich each bound row's node path from its PV. A failed query (e.g. missing
-- namespace) is @Right []@; a present-but-malformed response is a 'Left'.
listAppPVCs :: Text -> Text -> IO (Either Text [PVCRow])
listAppPVCs ns app = do
  (code, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "get"
          , "pvc"
          , "-n"
          , T.unpack ns
          , "-l"
          , T.unpack (appPVCLabelSelector app)
          , "-o"
          , "json"
          ]
        & silenceStderr
  case code of
    ExitFailure _ -> pure (Right [])
    ExitSuccess -> case extractPVCStatus out of
      Left e -> pure (Left e)
      Right rows -> Right <$> traverse (enrich ns) rows

-- | Fill a row's node path from its bound PV's @.spec.local.path@ (best-effort;
-- @"-"@ when unbound or the lookup fails).
enrich :: Text -> PVCRow -> IO PVCRow
enrich ns r
  | T.null (prPvName r) = pure r {prNodePath = "-"}
  | otherwise = do
      p <- readPVNodePath (prPvName r)
      pure r {prNodePath = p}
  where
    _ = ns -- node path is cluster-scoped; ns kept for signature symmetry

-- | Read a PV's host directory from @.spec.local.path@ via
-- @kubectl get pv <name> -o jsonpath@. Returns @"-"@ on any failure.
readPVNodePath :: Text -> IO Text
readPVNodePath pv = do
  (code, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs ["get", "pv", T.unpack pv, "-o", "jsonpath={.spec.local.path}"]
        & silenceStderr
  pure $ case code of
    ExitFailure _ -> "-"
    ExitSuccess ->
      let p = T.strip (TE.decodeUtf8 out)
       in if T.null p then "-" else p

-- | Render the @storage list@ table by joining the declared volumes (from the
-- typed config — the source of truth for what /should/ exist) to the discovered
-- PVC rows. A declared volume with no matching PVC on the cluster renders
-- @STATUS = MISSING@ and @NODE-PATH = -@, so a never-deployed volume is visible.
-- The @app@ argument supplies the deterministic PVC name for such rows.
formatStorageTable :: Text -> [Volume] -> [PVCRow] -> Text
formatStorageTable app vols rows
  | null vols = "(no volumes declared)\n"
  | otherwise = T.unlines (header : map line vols)
  where
    header =
      "  "
        <> pad 12 "VOLUME"
        <> pad 26 "PVC"
        <> pad 8 "SIZE"
        <> pad 10 "STATUS"
        <> "NODE-PATH"
    line v =
      let vol = volumeNameText (v ^. #volName)
          sz = quantityText (v ^. #size)
          pn = pvcName app vol
          mrow = find (\r -> prVolume r == vol) rows
          status = maybe "MISSING" prStatus mrow
          nodePath = maybe "-" prNodePath mrow
       in T.concat ["  ", pad 12 vol, pad 26 pn, pad 8 sz, pad 10 status, nodePath]
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

-- ---------------------------------------------------------------------------
-- JSON walking (local copies; mirror Nagare.App's private helpers)

lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] v = Just v
lookupPath (k : ks) (Aeson.Object o) = KeyMap.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing

textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (Aeson.String s) -> Just s
  _ -> Nothing

-- | The value of one @.metadata.labels[key]@, if present and a string.
labelAt :: Text -> Aeson.Value -> Maybe Text
labelAt key = textAt ["metadata", "labels", key]
