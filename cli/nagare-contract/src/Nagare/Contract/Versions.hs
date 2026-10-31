{-# LANGUAGE DataKinds #-}

-- | The @platform-versions@ read document (EP-236): what one context has
-- installed and runs, beside the build that serves it.
--
-- Every reported value is a 'Fact': a nullable string, whether it is
-- recorded state or a provider observation, where it came from, when that
-- source was read, and when the value is null a reason from the catalog in
-- @docs/api/README.md@. Reasons are strings, not an enumeration, so a new
-- reason is an additive catalog entry. Identity keys and structural fields
-- carry no envelope.
module Nagare.Contract.Versions
  ( SourceKind (..)
  , Fact (..)
  , SnapshotInfo (..)
  , InstalledRelease (..)
  , ServingBuild (..)
  , Pins (..)
  , ComparisonState (..)
  , Comparison (..)
  , NagareVersions (..)
  , NixosIdentity (..)
  , HostVersions (..)
  , DeclaredImage (..)
  , ObservedContainer (..)
  , Workload (..)
  , ComponentVersions (..)
  , DatabaseInstance (..)
  , DatabaseVersions (..)
  , PlatformVersions (..)
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.OpenApi (ToSchema (..), description, schema)
import Nagare.Contract.Prelude
import Nagare.Contract.Schema

-- | @recorded@: state Nagare or the host wrote down (the stamp, an accepted
-- declaration, the host identity ConfigMap). @observed@: what a running
-- provider reported when it was asked.
data SourceKind
  = SourceRecorded
  | SourceObserved
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

-- | One reported value. @observedAt@ is when its source was read, or when
-- the read was attempted; never the HTTP request time.
data Fact = Fact
  { value :: !(Nullable Text)
  , sourceKind :: !SourceKind
  , source :: !Text
  , observedAt :: !Text
  , reason :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | The observation snapshot the document was assembled from. When
-- @available@ is false the sections are empty and @reason@ says why.
data SnapshotInfo = SnapshotInfo
  { collectedAt :: !(Nullable Text)
  , completedAt :: !(Nullable Text)
  , inventoryRevision :: !(Nullable Text)
  , available :: !Bool
  , reason :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | The release the context's cluster stamp records.
data InstalledRelease = InstalledRelease
  { version :: !Fact
  , revision :: !Fact
  , payloadId :: !Fact
  , installedAt :: !Fact
  }
  deriving stock (Eq, Show, Generic)

-- | The binary serving this document, read once at process start.
data ServingBuild = ServingBuild
  { version :: !Text
  , platformVersion :: !Text
  , revision :: !(Nullable Text)
  , contracts :: ![Int]
  , readAt :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | The releases the operator's context and generated host flake pin.
data Pins = Pins
  { context :: !Fact
  , hostVersion :: !Fact
  , hostRevision :: !Fact
  }
  deriving stock (Eq, Show, Generic)

data ComparisonState
  = ComparisonMatch
  | ComparisonDifferent
  | ComparisonUnknown
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

-- | The installed release against the serving build. Unequal known fields
-- are @different@; equal versions without revision evidence on both sides
-- are @unknown@; complete equal evidence is @match@.
data Comparison = Comparison
  { state :: !ComparisonState
  , installedVersion :: !(Nullable Text)
  , servingVersion :: !(Nullable Text)
  , installedRevision :: !(Nullable Text)
  , servingRevision :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

data NagareVersions = NagareVersions
  { installed :: !(Nullable InstalledRelease)
  , servingBuild :: !(Nullable ServingBuild)
  , pins :: !(Nullable Pins)
  , comparison :: !Comparison
  }
  deriving stock (Eq, Show, Generic)

-- | The NixOS identity the host module records at activation.
data NixosIdentity = NixosIdentity
  { release :: !Fact
  , codename :: !Fact
  , version :: !Fact
  , nixpkgsRevision :: !Fact
  }
  deriving stock (Eq, Show, Generic)

-- | One cluster node, keyed by name and UID.
data HostVersions = HostVersions
  { node :: !Text
  , uid :: !Text
  , osImage :: !Fact
  , kernel :: !Fact
  , kubernetes :: !Fact
  , nixos :: !NixosIdentity
  }
  deriving stock (Eq, Show, Generic)

data DeclaredImage = DeclaredImage
  { container :: !Text
  , image :: !Fact
  }
  deriving stock (Eq, Show, Generic)

data ObservedContainer = ObservedContainer
  { container :: !Text
  , image :: !Fact
  , imageDigest :: !Fact
  }
  deriving stock (Eq, Show, Generic)

-- | One running pod of a component.
data Workload = Workload
  { pod :: !Text
  , podUid :: !Text
  , containers :: ![ObservedContainer]
  }
  deriving stock (Eq, Show, Generic)

-- | One accepted platform component, keyed by owner scope and resource.
-- @workloads@ lists every running pod, so a rollout shows each version;
-- @workloadsReason@ is set when the pods could not be listed.
data ComponentVersions = ComponentVersions
  { scope :: !Text
  , resource :: !Text
  , kind :: !Text
  , namespace :: !Text
  , name :: !Text
  , declaredVersion :: !Fact
  , declaredChartVersion :: !Fact
  , declaredImages :: ![DeclaredImage]
  , workloads :: ![Workload]
  , workloadsReason :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | One running pod of a database server and the version it reported.
data DatabaseInstance = DatabaseInstance
  { pod :: !Text
  , podUid :: !Text
  , image :: !Fact
  , imageDigest :: !Fact
  , reportedVersion :: !Fact
  }
  deriving stock (Eq, Show, Generic)

-- | One managed database server (never a tenant database), keyed by scope,
-- namespace and server name. A stopped server has no instances.
data DatabaseVersions = DatabaseVersions
  { scope :: !Text
  , namespace :: !Text
  , server :: !Text
  , engine :: !Text
  , declaredVersion :: !Fact
  , declaredImage :: !Fact
  , instances :: ![DatabaseInstance]
  , instancesReason :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | Installed, serving, host, component and database versions of one
-- context. A section's reason is set when the whole section could not be
-- read, which differs from an available empty list.
data PlatformVersions = PlatformVersions
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "platform-versions")
  , context :: !Text
  , project :: !Text
  , snapshot :: !SnapshotInfo
  , nagare :: !NagareVersions
  , hosts :: ![HostVersions]
  , hostsReason :: !(Nullable Text)
  , components :: ![ComponentVersions]
  , componentsReason :: !(Nullable Text)
  , databases :: ![DatabaseVersions]
  , databasesReason :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SourceKind where toJSON = genericToJSON (enumOptions "Source")

instance FromJSON SourceKind where parseJSON = genericParseJSON (enumOptions "Source")

instance ToSchema SourceKind where declareNamedSchema = enumSchema "Source"

instance ToJSON ComparisonState where toJSON = genericToJSON (enumOptions "Comparison")

instance FromJSON ComparisonState where parseJSON = genericParseJSON (enumOptions "Comparison")

instance ToSchema ComparisonState where declareNamedSchema = enumSchema "Comparison"

instance ToJSON Fact where toJSON = genericToJSON recordOptions

instance FromJSON Fact where parseJSON = genericParseJSON recordOptions

instance ToSchema Fact where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "One reported value. sourceKind recorded is written-down state, observed is what a running provider reported; observedAt is when the source was read, never the request time; reason is set exactly when value is null."

instance ToJSON SnapshotInfo where toJSON = genericToJSON recordOptions

instance FromJSON SnapshotInfo where parseJSON = genericParseJSON recordOptions

instance ToSchema SnapshotInfo where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "The observation snapshot the document was assembled from; observations are as of completedAt, not the request time."

instance ToJSON InstalledRelease where toJSON = genericToJSON recordOptions

instance FromJSON InstalledRelease where parseJSON = genericParseJSON recordOptions

instance ToSchema InstalledRelease where declareNamedSchema = recordSchema

instance ToJSON ServingBuild where toJSON = genericToJSON recordOptions

instance FromJSON ServingBuild where parseJSON = genericParseJSON recordOptions

instance ToSchema ServingBuild where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "The binary serving this document, as GET /v1/platform/version reports it; readAt is the process start."

instance ToJSON Pins where toJSON = genericToJSON recordOptions

instance FromJSON Pins where parseJSON = genericParseJSON recordOptions

instance ToSchema Pins where declareNamedSchema = recordSchema

instance ToJSON Comparison where toJSON = genericToJSON recordOptions

instance FromJSON Comparison where parseJSON = genericParseJSON recordOptions

instance ToSchema Comparison where declareNamedSchema = recordSchema

instance ToJSON NagareVersions where toJSON = genericToJSON recordOptions

instance FromJSON NagareVersions where parseJSON = genericParseJSON recordOptions

instance ToSchema NagareVersions where declareNamedSchema = recordSchema

instance ToJSON NixosIdentity where toJSON = genericToJSON recordOptions

instance FromJSON NixosIdentity where parseJSON = genericParseJSON recordOptions

instance ToSchema NixosIdentity where declareNamedSchema = recordSchema

instance ToJSON HostVersions where toJSON = genericToJSON recordOptions

instance FromJSON HostVersions where parseJSON = genericParseJSON recordOptions

instance ToSchema HostVersions where declareNamedSchema = recordSchema

instance ToJSON DeclaredImage where toJSON = genericToJSON recordOptions

instance FromJSON DeclaredImage where parseJSON = genericParseJSON recordOptions

instance ToSchema DeclaredImage where declareNamedSchema = recordSchema

instance ToJSON ObservedContainer where toJSON = genericToJSON recordOptions

instance FromJSON ObservedContainer where parseJSON = genericParseJSON recordOptions

instance ToSchema ObservedContainer where declareNamedSchema = recordSchema

instance ToJSON Workload where toJSON = genericToJSON recordOptions

instance FromJSON Workload where parseJSON = genericParseJSON recordOptions

instance ToSchema Workload where declareNamedSchema = recordSchema

instance ToJSON ComponentVersions where toJSON = genericToJSON recordOptions

instance FromJSON ComponentVersions where parseJSON = genericParseJSON recordOptions

instance ToSchema ComponentVersions where declareNamedSchema = recordSchema

instance ToJSON DatabaseInstance where toJSON = genericToJSON recordOptions

instance FromJSON DatabaseInstance where parseJSON = genericParseJSON recordOptions

instance ToSchema DatabaseInstance where declareNamedSchema = recordSchema

instance ToJSON DatabaseVersions where toJSON = genericToJSON recordOptions

instance FromJSON DatabaseVersions where parseJSON = genericParseJSON recordOptions

instance ToSchema DatabaseVersions where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "One managed database server, never a tenant database. declaredVersion keeps the declared literal, such as a moving major tag."

instance ToJSON PlatformVersions where toJSON = genericToJSON recordOptions

instance FromJSON PlatformVersions where parseJSON = genericParseJSON recordOptions

instance ToSchema PlatformVersions where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "Installed, serving, host, component and database versions of one context. Recorded facts and observations are assembled by nagarectl into a snapshot; the API never runs a provider."
