{-# LANGUAGE PackageImports #-}

-- | Static-site release history (EP-15).
--
-- Every successful production @nagarectl site deploy@ records a 'StaticRelease'
-- — the image tag it activated plus enough metadata to show a human and to roll
-- back to. The history is a 'StaticReleaseLog' stored as compact JSON inside a
-- per-site Kubernetes ConfigMap (MasterPlan Integration Point 4), newest record
-- first and capped at 'historyCap'. The @current@ field names the release the
-- production Service currently points at.
--
-- The pure layer (types, JSON, 'addRelease', 'findRelease', table formatting,
-- ConfigMap rendering/extraction) is separated from the small @kubectl@ IO layer
-- ('readReleaseLog' / 'writeReleaseLog') so the schema is unit-testable without
-- a cluster.
module Nagare.Static.Release
  ( StaticRelease (..)
  , StaticReleaseLog (..)
  , emptyReleaseLog
  , historyCap
  , addRelease
  , findRelease
  , configMapName
  , releaseDataKey
  , renderReleaseConfigMap
  , extractReleaseLog
  , formatReleasesTable
  , readReleaseLog
  , writeReleaseLog
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import Cradle
import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , eitherDecodeStrict
  , encode
  , object
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List (find, sortOn)
import Data.Ord (Down (..))
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Nagare.Deploy (applyManifests)
import System.Exit (ExitCode (..))

-- ---------------------------------------------------------------------------
-- Types

-- | One successful production deploy.
data StaticRelease = StaticRelease
  { releaseId :: !Text
  , siteName :: !Text
  , namespace :: !Text
  , image :: !Text
  , imageTag :: !Text
  , url :: !Text
  , source :: !(Maybe Text)
  , createdAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON StaticRelease where
  toJSON r =
    object
      [ "releaseId" .= releaseId r
      , "siteName" .= siteName r
      , "namespace" .= namespace r
      , "image" .= image r
      , "imageTag" .= imageTag r
      , "url" .= url r
      , "source" .= source r
      , "createdAt" .= createdAt r
      ]

instance FromJSON StaticRelease where
  parseJSON = withObject "StaticRelease" $ \o ->
    StaticRelease
      <$> o .: "releaseId"
      <*> o .: "siteName"
      <*> o .: "namespace"
      <*> o .: "image"
      <*> o .: "imageTag"
      <*> o .: "url"
      <*> o .:? "source"
      <*> o .: "createdAt"

-- | The release history for one site: which release is live and the records,
-- newest first.
data StaticReleaseLog = StaticReleaseLog
  { current :: !(Maybe Text)
  , releases :: ![StaticRelease]
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON StaticReleaseLog where
  toJSON l = object ["current" .= current l, "releases" .= releases l]

instance FromJSON StaticReleaseLog where
  parseJSON = withObject "StaticReleaseLog" $ \o ->
    StaticReleaseLog <$> o .:? "current" <*> o .:? "releases" .!= []

-- | The empty history (used when no ConfigMap exists yet).
emptyReleaseLog :: StaticReleaseLog
emptyReleaseLog = StaticReleaseLog {current = Nothing, releases = []}

-- | Maximum number of release records kept per site; older records are dropped.
historyCap :: Int
historyCap = 50

-- ---------------------------------------------------------------------------
-- Pure log operations

-- | Record a release: make it @current@, place it at the front, drop any prior
-- record with the same @releaseId@ (idempotent re-deploy of the same tag), and
-- cap the history at 'historyCap'. Records are kept newest-first by @createdAt@.
addRelease :: StaticRelease -> StaticReleaseLog -> StaticReleaseLog
addRelease rel logv =
  StaticReleaseLog
    { current = Just (releaseId rel)
    , releases = take historyCap ordered
    }
  where
    deduped = filter ((/= releaseId rel) . releaseId) (releases logv)
    ordered = sortOn (Down . createdAt) (rel : deduped)

-- | Find a release by id.
findRelease :: Text -> StaticReleaseLog -> Maybe StaticRelease
findRelease rid = find ((== rid) . releaseId) . releases

-- ---------------------------------------------------------------------------
-- ConfigMap shape

-- | The ConfigMap name holding a site's release history, e.g.
-- @"nagare-static-releases-notes"@.
configMapName :: Text -> Text
configMapName site = "nagare-static-releases-" <> site

-- | The ConfigMap data key the release-log JSON is stored under.
releaseDataKey :: Text
releaseDataKey = "releases.json"

-- | Render the ConfigMap (as JSON bytes, which @kubectl apply -f@ accepts) that
-- stores @logv@ for @site@ in @ns@.
renderReleaseConfigMap :: Text -> Text -> StaticReleaseLog -> ByteString
renderReleaseConfigMap site ns logv =
  LBS.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("ConfigMap" :: Text)
      , "metadata"
          .= object
            [ "name" .= configMapName site
            , "namespace" .= ns
            ]
      , "data"
          .= object
            [ Key.fromText releaseDataKey .= TE.decodeUtf8 (LBS.toStrict (encode logv))
            ]
      ]

-- | Extract the release log from the JSON @kubectl get configmap -o json@ prints.
-- A ConfigMap with no @data@ or no @releases.json@ key yields an empty log;
-- malformed inner JSON is a 'Left' error (never silent data loss).
extractReleaseLog :: ByteString -> Either Text StaticReleaseLog
extractReleaseLog bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode ConfigMap JSON: " <> T.pack e)
    Right cm -> case lookupData cm of
      Nothing -> Right emptyReleaseLog
      Just inner -> case eitherDecodeStrict (TE.encodeUtf8 inner) of
        Left e -> Left ("could not decode release log JSON: " <> T.pack e)
        Right logv -> Right logv
  where
    lookupData :: Aeson.Value -> Maybe Text
    lookupData v = do
      Aeson.Object o <- Just v
      Aeson.Object d <- keyLookup "data" o
      inner <- keyLookup releaseDataKey d
      case inner of
        Aeson.String s -> Just s
        _ -> Nothing

keyLookup :: Text -> Aeson.Object -> Maybe Aeson.Value
keyLookup k = KeyMap.lookup (Key.fromText k)

-- ---------------------------------------------------------------------------
-- Table formatting

-- | Format a release log as a compact aligned table for the terminal. The live
-- release (per @current@) is marked with @*@.
formatReleasesTable :: StaticReleaseLog -> Text
formatReleasesTable logv
  | null (releases logv) = "(no releases recorded)"
  | otherwise = T.unlines (header : map row (releases logv))
  where
    header = "  RELEASE ID        CREATED                SOURCE      URL"
    row r =
      T.concat
        [ if current logv == Just (releaseId r) then "* " else "  "
        , pad 18 (releaseId r)
        , pad 23 (T.pack (show (createdAt r)))
        , pad 12 (fromMaybe "-" (source r))
        , url r
        ]
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

-- ---------------------------------------------------------------------------
-- kubectl IO

-- | Read the release log for @site@ in @ns@ via
-- @kubectl get configmap <name> -n <ns> -o json@. A missing ConfigMap (non-zero
-- exit) is an empty log; a present-but-malformed one is a 'Left' error.
readReleaseLog :: Text -> Text -> IO (Either Text StaticReleaseLog)
readReleaseLog site ns = do
  (exitCode, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "get"
          , "configmap"
          , T.unpack (configMapName site)
          , "-n"
          , T.unpack ns
          , "-o"
          , "json"
          ]
        & silenceStderr
  pure $ case exitCode of
    ExitFailure _ -> Right emptyReleaseLog
    ExitSuccess -> extractReleaseLog out

-- | Persist the release log for @site@ in @ns@ by @kubectl apply@-ing the
-- rendered ConfigMap (reusing 'Nagare.Deploy.applyManifests').
writeReleaseLog :: Text -> Text -> StaticReleaseLog -> IO ()
writeReleaseLog site ns logv =
  applyManifests [renderReleaseConfigMap site ns logv]
