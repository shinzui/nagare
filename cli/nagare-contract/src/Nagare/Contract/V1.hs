{-# LANGUAGE DataKinds #-}

-- | Version 1 of Nagare's public document contract.
--
-- Read documents ('InventoryStatusReport', 'PublicationList', 'SiteList',
-- 'VersionInfo') are printed by the CLI and their item types ('ScopeState',
-- 'Finding', 'Publication', 'SiteSummary') are served by the read-only admin
-- API. Operation documents
-- ('TransactionOutcome', 'SavedReview', 'ImagePublicationResult',
-- 'DeployPreview') describe a change and are printed only by the CLI.
--
-- Every type's codec and schema come from one aeson 'Options' value. Every
-- document except the discovery document 'VersionInfo' carries
-- @contractVersion@ and a constant @document@ member naming its kind.
-- Objects encode with sorted keys.
module Nagare.Contract.V1
  ( contractVersions
  , ContextRef (..)
  , Revision (..)

    -- * Operation documents
  , Outcome (..)
  , FailureClass (..)
  , TransactionOutcome (..)
  , ReviewLocation (..)
  , SavedReview (..)
  , PublishedReview (..)
  , ImagePublicationResult (..)
  , SitePublishResult (..)
  , NixCacheEndpoint (..)
  , NixCachePushResult (..)
  , PreviewScope (..)
  , DeployPreview (..)

    -- * Read documents and their items
  , ScopeState (..)
  , FindingCategory (..)
  , Health (..)
  , Finding (..)
  , InventoryStatusReport (..)
  , Publication (..)
  , PublicationList (..)
  , VersionInfo (..)
  , SiteKind (..)
  , RecordState (..)
  , SiteService (..)
  , SiteSummary (..)
  , SiteList (..)
  , ExecutorClaimSummary (..)
  , DataFenceSummary (..)
  , MigrationSummary (..)
  , TransitionSummary (..)
  , HeadSummary (..)
  , SubjectKind (..)
  , Grant (..)
  )
where

import Data.Aeson
  ( FromJSON (..)
  , Options (..)
  , ToJSON (..)
  , Value
  , genericParseJSON
  , genericToJSON
  )
import Data.Map.Strict (Map)
import Data.OpenApi (ToSchema (..), description, schema)
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (ProblemDetails)
import Nagare.Contract.Schema

-- | The contract versions this build can emit.
contractVersions :: [Int]
contractVersions = [1]

-- | The context a document describes: its identity and its GCP project.
data ContextRef = ContextRef
  { identity :: !Text
  , project :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | A recorded scope revision.
data Revision = Revision
  { generation :: !Integer
  , digest :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | How an @inventory apply@ or @inventory resume@ ended. @refused@ means no
-- provider was touched; @interrupted@ means execution had started, so the
-- transaction must be inspected or resumed.
data Outcome
  = OutcomeConverged
  | OutcomePaused
  | OutcomeStopped
  | OutcomeAmbiguous
  | OutcomeClosed
  | OutcomeRefused
  | OutcomeInterrupted
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

-- | Whether a stopped operation may have changed its provider.
data FailureClass
  = FailureKnownNoEffect
  | FailurePartialOrUnknown
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

data TransactionOutcome = TransactionOutcome
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "transaction-outcome")
  , outcome :: !Outcome
  , transaction :: !(Nullable Text)
  , operation :: !(Nullable Text)
  , failureClass :: !(Nullable FailureClass)
  , barriers :: ![Text]
  , detail :: !(Nullable Text)
  -- ^ The stop's reason for @stopped@, @ambiguous@ and @interrupted@.
  , problem :: !(Nullable ProblemDetails)
  -- ^ Set exactly when the outcome is @refused@.
  }
  deriving stock (Eq, Show, Generic)

data ReviewLocation = ReviewLocation
  { sha256 :: !Text
  , directory :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | A saved review bundle: its digest, directory, the scopes it changes and
-- the lineage lines planning reported.
data SavedReview = SavedReview
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "saved-review")
  , review :: !ReviewLocation
  , scopes :: ![Text]
  , rebinds :: ![Text]
  , rebuilds :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | A review that may have converged in-process, so it has no saved
-- directory.
data PublishedReview = PublishedReview
  { sha256 :: !Text
  , directory :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

data ImagePublicationResult = ImagePublicationResult
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "image-publication-result")
  , imageResource :: !Text
  , review :: !PublishedReview
  , transaction :: !(Nullable TransactionOutcome)
  -- ^ Present when the publication converged in-process.
  }
  deriving stock (Eq, Show, Generic)

-- | The outcome of @site publish@. @stage@ is the last stage proved: @unchanged@
-- (nothing was built or released), @deployed@, or, when a later stage failed,
-- @packaged@ or @image-published@ with @failure@ and the @resume@ command.
data SitePublishResult = SitePublishResult
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "site-publish-result")
  , stage :: !Text
  , tag :: !Text
  , url :: !(Nullable Text)
  , imageResource :: !(Nullable Text)
  , releaseDirectory :: !(Nullable Text)
  , content :: !(Nullable Text)
  , failure :: !(Nullable Text)
  , resume :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | The cache @nix-cache forward@ serves while it runs: the loopback
-- endpoint, the cache name and the public signing key a client trusts.
data NixCacheEndpoint = NixCacheEndpoint
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "nix-cache-endpoint")
  , endpoint :: !Text
  , cache :: !Text
  , publicKey :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | The outcome of @nix-cache push@: @pushed@, or @failed@ with the Attic
-- client's exit code as the command's.
data NixCachePushResult = NixCachePushResult
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "nix-cache-push-result")
  , endpoint :: !Text
  , cache :: !Text
  , paths :: ![Text]
  , outcome :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | A scope a deploy would change.
data PreviewScope = PreviewScope
  { scope :: !Text
  , configDigest :: !(Nullable Text)
  -- ^ The SHA-256 of the canonical JSON of the typed configuration only.
  -- The tag, image resource, base domain, CDN fields, namespace request and
  -- hook effects are in @overrides@, not in this digest.
  , overrides :: !(Map Text Text)
  }
  deriving stock (Eq, Show, Generic)

data DeployPreview = DeployPreview
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "deploy-preview")
  , application :: !PreviewScope
  , hooks :: ![PreviewScope]
  , scopeDocuments :: ![Value]
  -- ^ The canonical scope documents, as opaque audit data. Their @bundles@
  -- are outside the contract.
  }
  deriving stock (Eq, Show, Generic)

-- | One accepted scope and whether its accepted revision has converged.
-- @convergedRevision@ is the last revision whose execution completed, which
-- differs from the accepted one while a change is pending or stopped.
data ScopeState = ScopeState
  { scope :: !Text
  , generation :: !Integer
  , digest :: !Text
  , converged :: !Bool
  , convergedRevision :: !(Nullable Revision)
  }
  deriving stock (Eq, Show, Generic)

data FindingCategory
  = CategoryConverged
  | CategoryConfigurationDrift
  | CategoryImmutableReplacementRequired
  | CategoryReplacedIncarnation
  | CategoryUnrecorded
  | CategoryStuckRollout
  | CategoryMissing
  | CategoryUnowned
  | CategoryForeignOwner
  | CategoryUnknown
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

data Health
  = HealthReady
  | HealthNotReady
  | HealthUnknown
  | HealthUnavailable
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

-- | What a provider observed for one accepted resource.
data Finding = Finding
  { scope :: !Text
  , resource :: !Text
  , category :: !FindingCategory
  , health :: !Health
  , reason :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | The recorded scopes and, separately, what providers observed.
-- @observationComplete: false@ means some provider could not be observed, so
-- @findings@ is partial.
data InventoryStatusReport = InventoryStatusReport
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "inventory-status")
  , context :: !ContextRef
  , observedAt :: !Text
  , observationComplete :: !Bool
  , activeTransaction :: !(Nullable Text)
  , scopes :: ![ScopeState]
  , findings :: ![Finding]
  }
  deriving stock (Eq, Show, Generic)

-- | One accepted artifact publication. Nagare records no acceptance time and
-- no owning application: @usedBy@ lists the scopes whose accepted
-- @imageResource@ names this publication.
data Publication = Publication
  { resourceId :: !Text
  , scope :: !Text
  , key :: !Text
  , kind :: !Text
  , destination :: !Text
  , manifestDigest :: !Text
  , archiveDigest :: !Text
  , generation :: !Integer
  , usedBy :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

data PublicationList = PublicationList
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "publication-list")
  , publications :: ![Publication]
  }
  deriving stock (Eq, Show, Generic)

-- | The discovery document: the serving build and the contract versions it
-- emits. It describes the binary, not what a context has installed.
data VersionInfo = VersionInfo
  { version :: !Text
  , platformVersion :: !Text
  , revision :: !(Maybe Text)
  , tools :: !(Maybe (Map Text (Nullable Text)))
  , contracts :: ![Int]
  }
  deriving stock (Eq, Show, Generic)

-- | What kind of user-facing Knative Service a site row is.
data SiteKind
  = SiteKindSite
  | SiteKindService
  | SiteKindPreview
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

-- | The scope record of a site, not its health: the accepted revision
-- converged, an earlier revision of this Service converged, or none did.
data RecordState
  = RecordConverged
  | RecordPending
  | RecordNeverConverged
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

-- | A Service's recorded name, origin namespace and declared hostnames.
data SiteService = SiteService
  { name :: !Text
  , namespace :: !Text
  , hostnames :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | One recorded site. @lastConverged@ is the Service as its last converged
-- scope revision declared it, which differs while an update is pending.
data SiteSummary = SiteSummary
  { scope :: !Text
  , resourceId :: !Text
  , kind :: !SiteKind
  , state :: !RecordState
  , name :: !Text
  , namespace :: !Text
  , hostnames :: ![Text]
  , acceptedRevision :: !Revision
  , convergedRevision :: !(Nullable Revision)
  , lastConverged :: !(Nullable SiteService)
  }
  deriving stock (Eq, Show, Generic)

-- | Recorded sites, from the inventory store only: @liveObserved@ is always
-- false, because no workload, DNS or certificate was inspected.
data SiteList = SiteList
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "site-list")
  , context :: !ContextRef
  , headGeneration :: !Integer
  , activeTransaction :: !(Nullable Text)
  , liveObserved :: !Bool
  , sites :: ![SiteSummary]
  }
  deriving stock (Eq, Show, Generic)

-- | The executor claim on a head: which transaction holds the writer and
-- since when. The claiming client identity is not part of the contract.
data ExecutorClaimSummary = ExecutorClaimSummary
  { transaction :: !Text
  , epoch :: !Integer
  , claimedAt :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | An open data fence: its phase, transaction and when it was acquired.
data DataFenceSummary = DataFenceSummary
  { phase :: !Text
  , transaction :: !(Nullable Text)
  , acquiredAt :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | A store migration recorded on the head: where the history moved.
newtype MigrationSummary = MigrationSummary
  { destination :: Text
  }
  deriving stock (Eq, Show, Generic)

-- | An open release transition: the pinned source release, the target
-- payload and when its first review was admitted.
data TransitionSummary = TransitionSummary
  { source :: !Text
  , target :: !Text
  , startedAt :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | One checked inventory head, read without any scope object. @revision@
-- identifies the snapshot: equal revisions are the same head, and
-- @journalSequence@ is the next journal position. The head
-- records no installed release version; rollout state is the transition and
-- the scope revisions.
data HeadSummary = HeadSummary
  { context :: !ContextRef
  , generation :: !Integer
  , journalSequence :: !Integer
  , revision :: !Text
  , acceptedScopes :: !Int
  , convergedScopes :: !Int
  , activeTransaction :: !(Nullable Text)
  , executorClaim :: !(Nullable ExecutorClaimSummary)
  , dataFence :: !(Nullable DataFenceSummary)
  , migration :: !(Nullable MigrationSummary)
  , transition :: !(Nullable TransitionSummary)
  }
  deriving stock (Eq, Show, Generic)

data SubjectKind
  = SubjectUser
  | SubjectTeam
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

-- | One recorded viewer relationship on a hostname: a user, or the members
-- of a team (@subjectRelation@ is @member@). It is what the inventory
-- accepted, not an effective-access check; a grant may outlive its route.
data Grant = Grant
  { resourceId :: !Text
  , scope :: !Text
  , host :: !Text
  , subjectKind :: !SubjectKind
  , subject :: !Text
  , subjectRelation :: !(Nullable Text)
  , acceptedRevision :: !Revision
  , convergedRevision :: !(Nullable Revision)
  }
  deriving stock (Eq, Show, Generic)

-- Records: one shared options value per type, via 'recordOptions'.
-- 'VersionInfo' omits an absent revision or tool map, as it always has.

instance ToJSON ContextRef where toJSON = genericToJSON recordOptions

instance FromJSON ContextRef where parseJSON = genericParseJSON recordOptions

instance ToSchema ContextRef where declareNamedSchema = recordSchema

instance ToJSON Revision where toJSON = genericToJSON recordOptions

instance FromJSON Revision where parseJSON = genericParseJSON recordOptions

instance ToSchema Revision where declareNamedSchema = recordSchema

instance ToJSON TransactionOutcome where toJSON = genericToJSON recordOptions

instance FromJSON TransactionOutcome where parseJSON = genericParseJSON recordOptions

instance ToSchema TransactionOutcome where declareNamedSchema = recordSchema

instance ToJSON ReviewLocation where toJSON = genericToJSON recordOptions

instance FromJSON ReviewLocation where parseJSON = genericParseJSON recordOptions

instance ToSchema ReviewLocation where declareNamedSchema = recordSchema

instance ToJSON SavedReview where toJSON = genericToJSON recordOptions

instance FromJSON SavedReview where parseJSON = genericParseJSON recordOptions

instance ToSchema SavedReview where declareNamedSchema = recordSchema

instance ToJSON PublishedReview where toJSON = genericToJSON recordOptions

instance FromJSON PublishedReview where parseJSON = genericParseJSON recordOptions

instance ToSchema PublishedReview where declareNamedSchema = recordSchema

instance ToJSON ImagePublicationResult where toJSON = genericToJSON recordOptions

instance FromJSON ImagePublicationResult where parseJSON = genericParseJSON recordOptions

instance ToSchema ImagePublicationResult where declareNamedSchema = recordSchema

instance ToJSON SitePublishResult where toJSON = genericToJSON recordOptions

instance FromJSON SitePublishResult where parseJSON = genericParseJSON recordOptions

instance ToSchema SitePublishResult where declareNamedSchema = recordSchema

instance ToJSON NixCacheEndpoint where toJSON = genericToJSON recordOptions

instance FromJSON NixCacheEndpoint where parseJSON = genericParseJSON recordOptions

instance ToSchema NixCacheEndpoint where declareNamedSchema = recordSchema

instance ToJSON NixCachePushResult where toJSON = genericToJSON recordOptions

instance FromJSON NixCachePushResult where parseJSON = genericParseJSON recordOptions

instance ToSchema NixCachePushResult where declareNamedSchema = recordSchema

instance ToJSON PreviewScope where toJSON = genericToJSON recordOptions

instance FromJSON PreviewScope where parseJSON = genericParseJSON recordOptions

instance ToSchema PreviewScope where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "configDigest is the SHA-256 of the canonical JSON of the typed configuration only; the tag, image resource, base domain, CDN fields, namespace request and hook effects are in overrides."

instance ToJSON DeployPreview where toJSON = genericToJSON recordOptions

instance FromJSON DeployPreview where parseJSON = genericParseJSON recordOptions

instance ToSchema DeployPreview where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "scopeDocuments are the canonical scope documents as opaque audit data; their bundles are outside the contract."

instance ToJSON ScopeState where toJSON = genericToJSON recordOptions

instance FromJSON ScopeState where parseJSON = genericParseJSON recordOptions

instance ToSchema ScopeState where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "A recorded scope revision. converged means the accepted revision's execution completed; it is not a live health check."

instance ToJSON Finding where toJSON = genericToJSON recordOptions

instance FromJSON Finding where parseJSON = genericParseJSON recordOptions

instance ToSchema Finding where declareNamedSchema = recordSchema

instance ToJSON InventoryStatusReport where toJSON = genericToJSON recordOptions

instance FromJSON InventoryStatusReport where parseJSON = genericParseJSON recordOptions

instance ToSchema InventoryStatusReport where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "Recorded scopes and observed findings are separate; observationComplete false means findings are partial."

instance ToJSON Publication where toJSON = genericToJSON recordOptions

instance FromJSON Publication where parseJSON = genericParseJSON recordOptions

instance ToSchema Publication where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "An accepted artifact publication. usedBy lists the scopes whose accepted imageResource names it."

instance ToJSON PublicationList where toJSON = genericToJSON recordOptions

instance FromJSON PublicationList where parseJSON = genericParseJSON recordOptions

instance ToSchema PublicationList where declareNamedSchema = recordSchema

instance ToJSON VersionInfo where toJSON = genericToJSON versionOptions

instance FromJSON VersionInfo where parseJSON = genericParseJSON versionOptions

instance ToSchema VersionInfo where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "The serving build and the contract versions it emits; not the version a context has installed."

versionOptions :: Options
versionOptions = recordOptions {omitNothingFields = True}

-- Enumerations: kebab case without the constructor prefix.

instance ToJSON Outcome where toJSON = genericToJSON (enumOptions "Outcome")

instance FromJSON Outcome where parseJSON = genericParseJSON (enumOptions "Outcome")

instance ToSchema Outcome where declareNamedSchema = enumSchema "Outcome"

instance ToJSON FailureClass where toJSON = genericToJSON (enumOptions "Failure")

instance FromJSON FailureClass where parseJSON = genericParseJSON (enumOptions "Failure")

instance ToSchema FailureClass where declareNamedSchema = enumSchema "Failure"

instance ToJSON FindingCategory where toJSON = genericToJSON (enumOptions "Category")

instance FromJSON FindingCategory where parseJSON = genericParseJSON (enumOptions "Category")

instance ToSchema FindingCategory where declareNamedSchema = enumSchema "Category"

instance ToJSON Health where toJSON = genericToJSON (enumOptions "Health")

instance FromJSON Health where parseJSON = genericParseJSON (enumOptions "Health")

instance ToSchema Health where declareNamedSchema = enumSchema "Health"

instance ToJSON SiteKind where toJSON = genericToJSON (enumOptions "SiteKind")

instance FromJSON SiteKind where parseJSON = genericParseJSON (enumOptions "SiteKind")

instance ToSchema SiteKind where declareNamedSchema = enumSchema "SiteKind"

instance ToJSON RecordState where toJSON = genericToJSON (enumOptions "Record")

instance FromJSON RecordState where parseJSON = genericParseJSON (enumOptions "Record")

instance ToSchema RecordState where declareNamedSchema = enumSchema "Record"

instance ToJSON SiteService where toJSON = genericToJSON recordOptions

instance FromJSON SiteService where parseJSON = genericParseJSON recordOptions

instance ToSchema SiteService where declareNamedSchema = recordSchema

instance ToJSON SiteSummary where toJSON = genericToJSON recordOptions

instance FromJSON SiteSummary where parseJSON = genericParseJSON recordOptions

instance ToSchema SiteSummary where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "A recorded site. state describes scope records, not workload health: converged means the accepted revision's execution completed."

instance ToJSON SiteList where toJSON = genericToJSON recordOptions

instance FromJSON SiteList where parseJSON = genericParseJSON recordOptions

instance ToSchema SiteList where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "Recorded sites from the inventory store only; liveObserved is false because no workload, DNS or certificate was inspected."

instance ToJSON ExecutorClaimSummary where toJSON = genericToJSON recordOptions

instance FromJSON ExecutorClaimSummary where parseJSON = genericParseJSON recordOptions

instance ToSchema ExecutorClaimSummary where declareNamedSchema = recordSchema

instance ToJSON DataFenceSummary where toJSON = genericToJSON recordOptions

instance FromJSON DataFenceSummary where parseJSON = genericParseJSON recordOptions

instance ToSchema DataFenceSummary where declareNamedSchema = recordSchema

instance ToJSON MigrationSummary where toJSON = genericToJSON recordOptions

instance FromJSON MigrationSummary where parseJSON = genericParseJSON recordOptions

instance ToSchema MigrationSummary where declareNamedSchema = recordSchema

instance ToJSON TransitionSummary where toJSON = genericToJSON recordOptions

instance FromJSON TransitionSummary where parseJSON = genericParseJSON recordOptions

instance ToSchema TransitionSummary where declareNamedSchema = recordSchema

instance ToJSON HeadSummary where toJSON = genericToJSON recordOptions

instance FromJSON HeadSummary where parseJSON = genericParseJSON recordOptions

instance ToSchema HeadSummary where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "A checked inventory head and its open execution state; revision identifies the snapshot. It records no installed release version."

instance ToJSON SubjectKind where toJSON = genericToJSON (enumOptions "Subject")

instance FromJSON SubjectKind where parseJSON = genericParseJSON (enumOptions "Subject")

instance ToSchema SubjectKind where declareNamedSchema = enumSchema "Subject"

instance ToJSON Grant where toJSON = genericToJSON recordOptions

instance FromJSON Grant where parseJSON = genericParseJSON recordOptions

instance ToSchema Grant where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "A recorded viewer relationship on a hostname; not an effective-access check, and it may outlive its route."
