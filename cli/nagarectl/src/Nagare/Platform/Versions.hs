-- | The platform-versions snapshot and document (EP-236), without IO.
--
-- @nagarectl platform versions refresh@ assembles a 'VersionSnapshot' from
-- recorded state and provider observations and publishes it to the
-- context's inventory store; the admin API reads it and renders the
-- 'PlatformVersions' document beside its own serving build. A snapshot is
-- historical evidence: its times say when each source was read.
module Nagare.Platform.Versions
  ( VersionSnapshot (..)
  , snapshotSchemaVersion
  , servingBuildOf
  , compareRelease
  , platformVersionsDocument

    -- * Facts
  , recordedFact
  , observedFact
  , missingFact
  , factValue

    -- * Reasons
  , reasonNotRecorded
  , reasonNotApplicable
  , reasonUnreadable
  , reasonDenied
  , reasonProbeFailed
  , reasonProbeUnsupported
  , reasonIdentityChanged
  , reasonCollectionDeadline
  , reasonInventoryChanged
  , reasonSnapshotMissing
  , reasonSnapshotInvalid
  , reasonSnapshotOversized
  , reasonSnapshotForeign
  , reasonSnapshotUnavailable
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Contract.Schema (ContractVersion (..), DocumentName (..), Nullable (..), recordOptions)
import Nagare.Contract.V1 (VersionInfo)
import Nagare.Contract.Versions
import Nagare.Dsl.Prelude

-- | The stored observation snapshot, @versions/latest.json@. Its schema is
-- versioned apart from the contract. A non-null @reason@ marks the whole
-- snapshot unavailable (for example @inventory_changed@); its sections are
-- then empty.
data VersionSnapshot = VersionSnapshot
  { snapshotSchema :: !Int
  , context :: !Text
  , project :: !Text
  , collectedAt :: !Text
  , completedAt :: !Text
  , inventoryRevision :: !(Nullable Text)
  , reason :: !(Nullable Text)
  , installed :: !(Nullable InstalledRelease)
  , pins :: !(Nullable Pins)
  , hosts :: ![HostVersions]
  , hostsReason :: !(Nullable Text)
  , components :: ![ComponentVersions]
  , componentsReason :: !(Nullable Text)
  , databases :: ![DatabaseVersions]
  , databasesReason :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON VersionSnapshot where toJSON = genericToJSON recordOptions

instance FromJSON VersionSnapshot where parseJSON = genericParseJSON recordOptions

snapshotSchemaVersion :: Int
snapshotSchemaVersion = 1

-- | The serving build as the document reports it.
servingBuildOf :: VersionInfo -> Text -> ServingBuild
servingBuildOf info startedAt =
  ServingBuild
    { version = info ^. #version
    , platformVersion = info ^. #platformVersion
    , revision = Nullable (info ^. #revision)
    , contracts = info ^. #contracts
    , readAt = startedAt
    }

-- | Compare the installed release with the serving build. A revision equal
-- to the other's prefix (a short and a full form of one commit, at least
-- seven characters) is the same revision.
compareRelease :: Maybe InstalledRelease -> Maybe ServingBuild -> Comparison
compareRelease installedRelease serving =
  Comparison
    { state = verdict
    , installedVersion = Nullable installedVersion'
    , servingVersion = Nullable servingVersion'
    , installedRevision = Nullable installedRevision'
    , servingRevision = Nullable servingRevision'
    }
  where
    installedVersion' = installedRelease >>= factValue . (^. #version)
    installedRevision' = installedRelease >>= factValue . (^. #revision)
    servingVersion' = (^. #platformVersion) <$> serving
    servingRevision' = serving >>= \build -> fromNullable' (build ^. #revision)
    verdict = case (installedVersion', servingVersion') of
      (Just installedText, Just servingText)
        | installedText /= servingText -> ComparisonDifferent
        | otherwise -> case (installedRevision', servingRevision') of
            (Just left, Just right)
              | sameRevision left right -> ComparisonMatch
              | otherwise -> ComparisonDifferent
            _ -> ComparisonUnknown
      _ -> ComparisonUnknown
    sameRevision left right =
      left == right
        || (min (T.length left) (T.length right) >= 7 && (left `T.isPrefixOf` right || right `T.isPrefixOf` left))

-- | The document for one context: the snapshot (or the reason it could not
-- be used) beside the serving build, if a server is answering.
platformVersionsDocument :: Text -> Text -> Maybe ServingBuild -> Either Text VersionSnapshot -> PlatformVersions
platformVersionsDocument contextName projectName serving = \case
  Left gap ->
    PlatformVersions
      { contractVersion = ContractVersion1
      , document = DocumentName
      , context = contextName
      , project = projectName
      , snapshot = SnapshotInfo (Nullable Nothing) (Nullable Nothing) (Nullable Nothing) False (Nullable (Just gap))
      , nagare = NagareVersions (Nullable Nothing) (Nullable serving) (Nullable Nothing) (compareRelease Nothing serving)
      , hosts = []
      , hostsReason = Nullable (Just gap)
      , components = []
      , componentsReason = Nullable (Just gap)
      , databases = []
      , databasesReason = Nullable (Just gap)
      }
  Right stored ->
    PlatformVersions
      { contractVersion = ContractVersion1
      , document = DocumentName
      , context = contextName
      , project = projectName
      , snapshot =
          SnapshotInfo
            { collectedAt = Nullable (Just (stored ^. #collectedAt))
            , completedAt = Nullable (Just (stored ^. #completedAt))
            , inventoryRevision = stored ^. #inventoryRevision
            , available = isNothing (fromNullable' (stored ^. #reason))
            , reason = stored ^. #reason
            }
      , nagare =
          NagareVersions
            { installed = stored ^. #installed
            , servingBuild = Nullable serving
            , pins = stored ^. #pins
            , comparison = compareRelease (fromNullable' (stored ^. #installed)) serving
            }
      , hosts = stored ^. #hosts
      , hostsReason = stored ^. #hostsReason
      , components = stored ^. #components
      , componentsReason = stored ^. #componentsReason
      , databases = stored ^. #databases
      , databasesReason = stored ^. #databasesReason
      }

recordedFact :: Text -> Text -> Maybe Text -> Fact
recordedFact = sourcedFact SourceRecorded

observedFact :: Text -> Text -> Maybe Text -> Fact
observedFact = sourcedFact SourceObserved

-- | A fact from @source@ read at @at@. An absent value is @not_recorded@.
sourcedFact :: SourceKind -> Text -> Text -> Maybe Text -> Fact
sourcedFact kind sourceText at = \case
  Just present | not (T.null (T.strip present)) -> Fact (Nullable (Just present)) kind sourceText at (Nullable Nothing)
  _ -> Fact (Nullable Nothing) kind sourceText at (Nullable (Just reasonNotRecorded))

-- | A null fact with its reason.
missingFact :: SourceKind -> Text -> Text -> Text -> Fact
missingFact kind sourceText at why = Fact (Nullable Nothing) kind sourceText at (Nullable (Just why))

factValue :: Fact -> Maybe Text
factValue fact = fromNullable' (fact ^. #value)

fromNullable' :: Nullable a -> Maybe a
fromNullable' (Nullable present) = present

reasonNotRecorded
  , reasonNotApplicable
  , reasonUnreadable
  , reasonDenied
  , reasonProbeFailed
  , reasonProbeUnsupported
  , reasonIdentityChanged
  , reasonCollectionDeadline
  , reasonInventoryChanged
  , reasonSnapshotMissing
  , reasonSnapshotInvalid
  , reasonSnapshotOversized
  , reasonSnapshotForeign
  , reasonSnapshotUnavailable ::
    Text
reasonNotRecorded = "not_recorded"
reasonNotApplicable = "not_applicable"
reasonUnreadable = "unreadable"
reasonDenied = "denied"
reasonProbeFailed = "probe_failed"
reasonProbeUnsupported = "probe_unsupported"
reasonIdentityChanged = "identity_changed"
reasonCollectionDeadline = "collection_deadline"
reasonInventoryChanged = "inventory_changed"
reasonSnapshotMissing = "snapshot_missing"
reasonSnapshotInvalid = "snapshot_invalid"
reasonSnapshotOversized = "snapshot_oversized"
reasonSnapshotForeign = "snapshot_foreign"
reasonSnapshotUnavailable = "snapshot_unavailable"
