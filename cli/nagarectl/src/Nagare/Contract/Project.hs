-- | Pure projections from Nagare's internal values to the public document
-- contract (@nagare-contract@). The CLI and the admin API both project
-- through these functions, so a read document has one shape everywhere.
--
-- The contract types are only encoded here: per ADR 22, decoding JSON never
-- grants authority, so nothing in nagarectl reads a contract document back.
module Nagare.Contract.Project
  ( versionInfo
  , contextRef
  , scopeStates
  , scopeState
  , acceptedPublications
  , publicationList
  , siteSummary
  , siteList
  , headSummary
  , grants
  , savedReview
  , imagePublicationResult
  , deployPreview
  , inventoryStatusReport
  , storeRefusal
  , workspaceRefusal
  )
where

import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Contract.Problem (ProblemSpec, reauthenticationRequired, storeUnavailable, unclassified, workspaceNotPrepared)
import Nagare.Contract.Recorded
import Nagare.Contract.Schema (ContractVersion (..), DocumentName (..), nullable)
import Nagare.Contract.Sink (transactionOutcome)
import Nagare.Contract.V1
  ( ContextRef (..)
  , DataFenceSummary (..)
  , DeployPreview (..)
  , ExecutorClaimSummary (..)
  , Finding (..)
  , FindingCategory (..)
  , Grant (..)
  , HeadSummary (..)
  , Health (..)
  , ImagePublicationResult (..)
  , InventoryStatusReport (..)
  , MigrationSummary (..)
  , PreviewScope (..)
  , Publication (..)
  , PublicationList (..)
  , PublishedReview (..)
  , RecordState (..)
  , ReviewLocation (..)
  , Revision (..)
  , SavedReview (..)
  , ScopeState (..)
  , SiteKind (..)
  , SiteList (..)
  , SiteService (..)
  , SiteSummary (..)
  , SubjectKind (..)
  , TransitionSummary (..)
  , VersionInfo (..)
  , contractVersions
  )
import Nagare.Dsl.Prelude
import Nagare.Inventory.Execute.Types (TransactionResult)
import Nagare.Inventory.Lineage (renderRebuild)
import Nagare.Inventory.Plan.Types (ReviewBundle, ReviewDocument (..), renderRebind, reviewBundleDocument)
import Nagare.Inventory.Site.Recorded qualified as Recorded
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store (DataFenceRecord (..), ExecutorClaim (..), HeadManifest (..), MigrationTombstone (..), ScopeRevision (..), StoreError (..), TransitionMarker (..))
import Nagare.Inventory.Store qualified as Store
import Nagare.Inventory.Store.GcloudAuth (gcloudLoginRequired)
import Nagare.Platform.Workspace (WorkspaceError (..), renderWorkspaceError)
import Nagare.Resource.Access (teamKeyText)
import Nagare.Resource.Inventory
  ( Declaration (..)
  , DesiredSpec (..)
  , Executor (..)
  , ScopeDeclaration
  , declarations
  , scopeBundles
  , scopeConfigDigest
  , scopeId
  , scopeOverrides
  )
import Nagare.Resource.Types hiding (ScopeKind (..))
import Nagare.Resource.Types qualified as Types
import Nagare.Resource.Wire (scopeValue)
import Nagare.Version (BuildVersion (..))

-- | The discovery document for this build. With tools, each name maps to
-- the executable found on @PATH@, or @null@.
versionInfo :: BuildVersion -> Maybe [(Text, Maybe FilePath)] -> VersionInfo
versionInfo (BuildVersion buildVersion buildRevision) resolvedTools =
  VersionInfo
    { version = buildVersion
    , platformVersion = buildVersion
    , revision = buildRevision
    , tools = Map.fromList . map (fmap (nullable . fmap T.pack)) <$> resolvedTools
    , contracts = contractVersions
    }

-- | A saved review: its digest and absolute directory, the scopes whose
-- revision it changes, and its lineage lines.
savedReview :: FilePath -> ReviewBundle -> ContentDigest -> SavedReview
savedReview directory bundle digest =
  SavedReview
    { contractVersion = ContractVersion1
    , document = DocumentName
    , review = ReviewLocation {sha256 = digestText digest, directory = T.pack directory}
    , scopes = [scopeIdText scope | scope <- Map.keys (Map.union base desired), Map.lookup scope base /= Map.lookup scope desired]
    , rebinds = map (uncurry renderRebind) (Map.toAscList (reviewRebinds reviewed))
    , rebuilds = map (uncurry renderRebuild) (Map.toAscList (reviewRebuilds reviewed))
    , effects = case reviewEffects reviewed of
        [] -> Nothing
        lost -> Just [resourceIdText (effect ^. #resource) <> ": " <> (effect ^. #loses) | effect <- lost]
    }
  where
    reviewed = reviewBundleDocument bundle
    base = reviewBaseRevisions reviewed
    desired = reviewDesiredRevisions reviewed

-- | An image publication: saved (with its directory) or converged in-process
-- (with its transaction outcome).
imagePublicationResult :: ResourceId -> ContentDigest -> Maybe FilePath -> Maybe TransactionResult -> ImagePublicationResult
imagePublicationResult image digest directory result =
  ImagePublicationResult
    { contractVersion = ContractVersion1
    , document = DocumentName
    , imageResource = resourceIdText image
    , review = PublishedReview {sha256 = digestText digest, directory = nullable (T.pack <$> directory)}
    , transaction = nullable (transactionOutcome <$> result)
    }

-- | A deploy preview with the same keys for every configuration.
deployPreview :: ScopeDeclaration -> [ScopeDeclaration] -> DeployPreview
deployPreview application hookScopes =
  DeployPreview
    { contractVersion = ContractVersion1
    , document = DocumentName
    , application = previewScope application
    , hooks = map previewScope hookScopes
    , scopeDocuments = map scopeValue (application : hookScopes)
    }
  where
    previewScope declared =
      PreviewScope
        { scope = scopeIdText (scopeId declared)
        , configDigest = nullable (digestText <$> scopeConfigDigest declared)
        , overrides = scopeOverrides declared
        }

-- | The status of a context's accepted scopes, or of one, with what the
-- providers observed. @complete@ is false when some provider could not be
-- observed.
inventoryStatusReport :: ContextBinding -> Text -> Bool -> HeadManifest -> Maybe ScopeId -> [Status.DriftFinding] -> InventoryStatusReport
inventoryStatusReport binding observed complete headValue selected drift =
  InventoryStatusReport
    { contractVersion = ContractVersion1
    , document = DocumentName
    , context = contextRef binding
    , observedAt = observed
    , observationComplete = complete
    , activeTransaction = nullable (headActiveTransaction headValue)
    , scopes = maybe (scopeStates headValue) (foldMap pure . scopeState headValue) selected
    , findings = [projectFinding finding | finding <- drift, maybe True (== Status.findingOwner finding) selected]
    }
  where
    projectFinding finding =
      Finding
        { scope = scopeIdText (Status.findingOwner finding)
        , resource = resourceIdText (Status.findingResource finding)
        , category = categoryOf (Status.findingCategory finding)
        , health = healthOf (Status.findingHealth finding)
        , reason = nullable (Status.findingReason finding)
        }
    categoryOf = \case
      Status.Converged -> CategoryConverged
      Status.ConfigurationDrift -> CategoryConfigurationDrift
      Status.ImmutableReplacementRequired -> CategoryImmutableReplacementRequired
      Status.MissingResource -> CategoryMissing
      Status.UnownedResource -> CategoryUnowned
      Status.ForeignOwner -> CategoryForeignOwner
      Status.ReplacedIncarnation -> CategoryReplacedIncarnation
      Status.UnrecordedIncarnation -> CategoryUnrecorded
      Status.StuckRollout -> CategoryStuckRollout
      Status.UnknownObservation -> CategoryUnknown
    healthOf = \case
      Status.HealthReady -> HealthReady
      Status.HealthNotReady -> HealthNotReady
      Status.HealthUnknown -> HealthUnknown
      Status.HealthUnavailable -> HealthUnavailable

-- | A store failure as a coded refusal: an expired login (F107) or an
-- unavailable store.
storeRefusal :: StoreError -> (ProblemSpec, Text)
storeRefusal = \case
  StoreAuthRequired -> (reauthenticationRequired, gcloudLoginRequired)
  failure -> (storeUnavailable, "the inventory store could not be read: " <> T.pack (show failure))

-- | A workspace failure as a coded refusal (F118).
workspaceRefusal :: WorkspaceError -> (ProblemSpec, Text)
workspaceRefusal failure = (case failure of WorkspaceNotPrepared _ -> workspaceNotPrepared; _ -> unclassified, renderWorkspaceError failure)
