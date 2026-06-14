-- | @nagarectl cleanup@ — reclaim disk across three categories: unused
-- containerd images, stale static-site previews, and old release-history
-- entries (MasterPlan 8, EP-41).
--
-- This is the /only/ mutating command in MasterPlan 8, so it is safe-by-default:
-- with no @--confirm@ it is a dry run that only reports what /would/ be removed.
--
-- The pure layer — the option/report types, the three selectors
-- ('pruneReleases', 'selectStalePreviews', 'parseCrictlImages' /
-- 'sumReclaimableBytes'), and 'formatCleanupReport' — is separated from the
-- small IO layer ('executeCleanup') so every selector is unit-testable with a
-- fixed @now@ and no cluster. The IO reuses EP-38's 'captureTool' (IP4) for
-- read-only listing, EP-15's release-log helpers for trimming, and @kubectl@/
-- IAP-SSH for the confirmed deletions.
module Nagare.Ops.Cleanup
  ( CleanupOpts (..)
  , CleanupReport (..)
  , ImagePlan (..)
  , PreviewInfo (..)
  , defaultPreviewTtlDays
  , defaultKeepReleases
  , pruneReleases
  , selectStalePreviews
  , parseCrictlImages
  , sumReclaimableBytes
  , formatCleanupReport
  , executeCleanup
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Control.Monad (forM, forM_)
import Data.Aeson (decodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Char (isDigit)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Vector qualified as V
import Numeric (showFFloat)
import Text.Read (readMaybe)

import Nagare.Ops.Probe (captureTool)
import Nagare.Static.Release qualified as Rel

-- ---------------------------------------------------------------------------
-- Types

-- | Parsed options for the cleanup command.
data CleanupOpts = CleanupOpts
  { doImages :: !Bool
  -- ^ act on the containerd image store
  , doPreviews :: !Bool
  -- ^ act on stale static previews
  , doReleases :: !Bool
  -- ^ act on old release-log entries
  , confirm :: !Bool
  -- ^ REQUIRED to mutate; absent => dry run
  , previewTtlDays :: !Int
  -- ^ previews older than this are stale (default 7)
  , keepReleases :: !Int
  -- ^ releases kept per log (default 10)
  , namespace :: !(Maybe Text)
  }
  deriving stock (Generic, Show)

-- | One static preview Service and its age inputs.
data PreviewInfo = PreviewInfo
  { previewName :: !Text
  , previewNamespace :: !Text
  , previewCreatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

-- | A parsed containerd image row from @crictl images@.
data ImagePlan = ImagePlan
  { imageRepo :: !Text
  , imageSizeBytes :: !Integer
  }
  deriving stock (Generic, Eq, Show)

-- | What a dry run would do / what a confirmed run did.
data CleanupReport = CleanupReport
  { reportImages :: !(Maybe (Int, Integer))
  -- ^ (count, reclaimable bytes), or 'Nothing' if images were not scanned
  , reportStalePreviews :: ![PreviewInfo]
  , reportTrimmedReleases :: ![(Text, [Rel.StaticRelease])]
  -- ^ (logSubject, removed entries)
  , reportConfirmed :: !Bool
  }
  deriving stock (Generic, Show)

defaultPreviewTtlDays :: Int
defaultPreviewTtlDays = 7

defaultKeepReleases :: Int
defaultKeepReleases = 10

-- ---------------------------------------------------------------------------
-- Pure selectors

-- | Trim a release log to the most recent @keep@ entries, NEVER removing the
-- @current@ release. Records are already newest-first; we keep the first @keep@
-- plus the @current@ record wherever it sits, and report the rest as removed.
pruneReleases :: Int -> Rel.StaticReleaseLog -> (Rel.StaticReleaseLog, [Rel.StaticRelease])
pruneReleases keep logv =
  let rs = Rel.releases logv
      kept = take keep rs
      keptIds = map Rel.releaseId kept
      curExtra = case Rel.current logv of
        Just cid | cid `notElem` keptIds -> filter ((== cid) . Rel.releaseId) rs
        _ -> []
      keptAll = kept <> curExtra
      keptAllIds = map Rel.releaseId keptAll
      removed = filter ((`notElem` keptAllIds) . Rel.releaseId) rs
   in (logv {Rel.releases = keptAll}, removed)

-- | Given the wall-clock @now@, a TTL, and the previews discovered in-cluster,
-- return those whose age exceeds the TTL (should be deleted). Pure in @now@.
selectStalePreviews :: UTCTime -> NominalDiffTime -> [PreviewInfo] -> [PreviewInfo]
selectStalePreviews now ttl = filter (\p -> diffUTCTime now (previewCreatedAt p) > ttl)

-- | Parse @crictl images@ table output into rows, tolerating the header and
-- blank lines. The columns are @IMAGE TAG IMAGE-ID SIZE@; SIZE is a
-- human-readable quantity (e.g. @142MB@, @744kB@, @1.2GiB@).
parseCrictlImages :: ByteString -> [ImagePlan]
parseCrictlImages bs =
  [ ImagePlan (head ws) (parseSize (last ws))
  | ln <- T.lines (decodeUtf8 bs)
  , let ws = T.words ln
  , length ws >= 4
  , head ws /= "IMAGE"
  ]

-- | Parse a human-readable size (@142MB@, @744kB@, @1.2GiB@) into bytes.
-- Decimal units use base 1000; @*iB@ units use base 1024. Unknown/blank → 0.
parseSize :: Text -> Integer
parseSize t =
  let (numTxt, unit) = T.span (\c -> isDigit c || c == '.') t
      n = maybe 0 id (readMaybe (T.unpack numTxt)) :: Double
      mult = case T.toLower unit of
        "b" -> 1
        "kb" -> 1000
        "mb" -> 1000000
        "gb" -> 1000000000
        "kib" -> 1024
        "mib" -> 1048576
        "gib" -> 1073741824
        _ -> 1
   in round (n * fromIntegral (mult :: Integer))

-- | Total reclaimable bytes across parsed image rows.
sumReclaimableBytes :: [ImagePlan] -> Integer
sumReclaimableBytes = sum . map imageSizeBytes

-- ---------------------------------------------------------------------------
-- Pure formatter

-- | Render the cleanup report as an aligned, human-readable block. The closing
-- line is the dry-run notice unless @reportConfirmed@ is 'True'.
formatCleanupReport :: CleanupReport -> Text
formatCleanupReport rep =
  T.unlines $ [headerLine, ""] <> body <> ["", lastLine]
  where
    confirmed = reportConfirmed rep
    headerLine = "cleanup " <> (if confirmed then "(applied)" else "(dry run)")
    body = imagesPart <> previewsPart <> releasesPart
    imagesPart = case reportImages rep of
      Nothing -> []
      Just (n, bytes)
        | confirmed -> ["  IMAGES     pruned via crictl rmi --prune (~" <> humanBytes bytes <> " reclaimable)"]
        | otherwise -> ["  IMAGES     " <> tshow n <> " unused images (~" <> humanBytes bytes <> " reclaimable)"]
    previewsPart =
      let ps = reportStalePreviews rep
       in if null ps
            then ["  PREVIEWS   none stale"]
            else
              ("  PREVIEWS   " <> tshow (length ps) <> (if confirmed then " deleted:" else " stale:"))
                : ["               " <> previewName p | p <- ps]
    releasesPart =
      let trs = reportTrimmedReleases rep
       in if null trs
            then ["  RELEASES   none to trim"]
            else
              [ "  RELEASES   "
                <> subj
                <> ": "
                <> tshow (length removed)
                <> ( if confirmed
                       then " entries trimmed (current kept)"
                       else " entries beyond keep would be trimmed (current kept)"
                   )
              | (subj, removed) <- trs
              ]
    lastLine =
      if confirmed
        then "done."
        else "(dry run — nothing removed; re-run with --confirm to apply)"
    tshow = T.pack . show

-- | A coarse human byte count (@~3.4 GiB@, @142.0 MiB@).
humanBytes :: Integer -> Text
humanBytes b
  | b >= gib = fmt (d b / d gib) <> " GiB"
  | b >= mib = fmt (d b / d mib) <> " MiB"
  | b >= kib = fmt (d b / d kib) <> " KiB"
  | otherwise = T.pack (show b) <> " B"
  where
    kib = 1024
    mib = 1024 * 1024
    gib = 1024 * 1024 * 1024
    d = fromIntegral :: Integer -> Double
    fmt x = T.pack (showFFloat (Just 1) x "")

-- ---------------------------------------------------------------------------
-- IO execution (dry-run / confirm)

-- | Gather inputs across the selected categories and, under @--confirm@, perform
-- the deletions; return the assembled report. When no category flag is set, all
-- three are acted on. Read-only sources degrade gracefully (a missing tool or
-- unreachable VM yields an empty category, not a crash).
executeCleanup :: CleanupOpts -> IO CleanupReport
executeCleanup o = do
  let allCats = not (doImages o || doPreviews o || doReleases o)
      wantImages = doImages o || allCats
      wantPreviews = doPreviews o || allCats
      wantReleases = doReleases o || allCats
      ns = fromMaybe "default" (namespace o)
  imagesR <- if wantImages then Just <$> imageStep o else pure Nothing
  previewsR <- if wantPreviews then previewStep o ns else pure []
  releasesR <- if wantReleases then releaseStep o ns else pure []
  pure
    CleanupReport
      { reportImages = imagesR
      , reportStalePreviews = previewsR
      , reportTrimmedReleases = releasesR
      , reportConfirmed = confirm o
      }

-- | Images: list the containerd store over IAP-SSH (read-only), and under
-- @--confirm@ run @crictl rmi --prune@. A missing/unreachable VM yields (0, 0).
imageStep :: CleanupOpts -> IO (Int, Integer)
imageStep o = do
  m <- captureTool "scripts/iap-ssh.sh" ["ssh", "nagare-01", "--", "sudo k3s crictl images"]
  let imgs = maybe [] parseCrictlImages m
  when (confirm o) $
    void $ captureTool "scripts/iap-ssh.sh" ["ssh", "nagare-01", "--", "sudo k3s crictl rmi --prune"]
  pure (length imgs, sumReclaimableBytes imgs)

-- | Previews: list the namespace's Knative Services, keep those matching the
-- preview naming pattern (@\<site\>-pr-\<name\>@), select the stale ones, and
-- under @--confirm@ delete each (with @--ignore-not-found@, so a repeat is a
-- clean no-op).
previewStep :: CleanupOpts -> Text -> IO [PreviewInfo]
previewStep o ns = do
  now <- getCurrentTime
  m <- captureTool "kubectl" ["get", "ksvc", "-n", T.unpack ns, "-o", "json"]
  let previews = maybe [] (parsePreviewInfos ns) m
      ttl = fromIntegral (previewTtlDays o) * 86400 :: NominalDiffTime
      stale = selectStalePreviews now ttl previews
  when (confirm o) $
    forM_ stale $ \p ->
      run_ $
        cmd "kubectl"
          & addArgs ["delete", "ksvc", T.unpack (previewName p), "-n", T.unpack (previewNamespace p), "--ignore-not-found"]
  pure stale

-- | Releases: enumerate the namespace's static-release ConfigMaps, trim each to
-- the retention count, and under @--confirm@ write the trimmed log back. Reports
-- only logs that actually had entries beyond the retention count.
releaseStep :: CleanupOpts -> Text -> IO [(Text, [Rel.StaticRelease])]
releaseStep o ns = do
  let prefix = "nagare-static-releases-"
  m <- captureTool "kubectl" ["get", "configmap", "-n", T.unpack ns, "-o", "name"]
  let subjects =
        [ T.drop (T.length prefix) nm
        | raw <- maybe [] (T.lines . decodeUtf8) m
        , let nm = T.strip (snd (T.breakOnEnd "/" raw))
        , prefix `T.isPrefixOf` nm
        ]
  results <- forM subjects $ \subj -> do
    elog <- Rel.readReleaseLogWith prefix subj ns
    case elog of
      Left _ -> pure Nothing
      Right logv -> do
        let (trimmed, removed) = pruneReleases (keepReleases o) logv
        if null removed
          then pure Nothing
          else do
            when (confirm o) $ Rel.writeReleaseLogWith prefix subj ns trimmed
            pure (Just (subj, removed))
  pure [r | Just r <- results]

-- | Parse @kubectl get ksvc -o json@ into 'PreviewInfo' for Services whose name
-- matches the preview pattern (@\<site\>-pr-\<name\>@) and whose
-- @.metadata.creationTimestamp@ parses. Pure.
parsePreviewInfos :: Text -> ByteString -> [PreviewInfo]
parsePreviewInfos ns bs =
  case decodeStrict bs >>= itemsOf of
    Nothing -> []
    Just items ->
      [ PreviewInfo name ns created
      | item <- items
      , Just name <- [textAt ["metadata", "name"] item]
      , "-pr-" `T.isInfixOf` name
      , Just ts <- [textAt ["metadata", "creationTimestamp"] item]
      , Just created <- [iso8601ParseM (T.unpack ts)]
      ]
  where
    itemsOf v = case lookupPath ["items"] v of
      Just (Aeson.Array arr) -> Just (V.toList arr)
      _ -> Nothing

-- Local JSON walk helpers (mirroring Nagare.App / Nagare.Ops.Probe).
lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] v = Just v
lookupPath (k : ks) (Aeson.Object obj) = KeyMap.lookup (Key.fromText k) obj >>= lookupPath ks
lookupPath _ _ = Nothing

textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (Aeson.String s) -> Just s
  _ -> Nothing
