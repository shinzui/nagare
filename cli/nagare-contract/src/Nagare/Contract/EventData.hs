-- | The @data@ member of each lifecycle event type (EP-276). A
-- 'Nagare.Contract.Events.LifecycleEvent' carries its payload as an opaque
-- value so a reader of an older contract can still list a newer type; these
-- schemas say what each type's payload holds. Every one refuses an unknown
-- member, and the test suite decodes every payload the feed can publish
-- through them, so they cannot drift from what is published.
module Nagare.Contract.EventData
  ( EventScopeRevision (..)
  , EventStoredVersion (..)
  , EventActorKind (..)
  , EventActor (..)
  , EventSource (..)
  , DeploymentSubjectKind (..)
  , DeploymentActionKind (..)
  , AppDeployedData (..)
  , BackupOriginKind (..)
  , BackupCompletedData (..)
  , BackupAcceptedData (..)
  , ScopeChangeKind (..)
  , EventScopeChange (..)
  , OperationActionKind (..)
  , EventActionCount (..)
  , ChangeAppliedData (..)
  , FailureOutcomeKind (..)
  , NextStepKind (..)
  , ChangeFailedData (..)
  , ClosedDispositionKind (..)
  , EventClosedScope (..)
  , ChangeClosedData (..)
  , AppDeletedData (..)
  , AppStoppedData (..)
  , AppRestartedData (..)
  , RestoreTargetKindName (..)
  , DatabaseRestoredData (..)
  , BackupFailureReasonKind (..)
  , BackupFailedData (..)
  , FreshnessGradeKind (..)
  , ObjectiveKind (..)
  , BackupFreshnessChangedData (..)
  , PlatformUpgradedData (..)
  , eventDataSchemaName
  )
where

import Data.Aeson
  ( FromJSON (..)
  , Options (rejectUnknownFields, tagSingleConstructors)
  , ToJSON (..)
  , genericParseJSON
  , genericToJSON
  )
import Data.OpenApi (ToSchema (..), description, fromAesonOptions, genericDeclareNamedSchema, schema)
import Nagare.Contract.Events (LifecycleScope)
import Nagare.Contract.Prelude
import Nagare.Contract.Schema

-- | The schema in @components.schemas@ that describes the @data@ of an event
-- of this type, for every type the feed publishes.
eventDataSchemaName :: Text -> Maybe Text
eventDataSchemaName eventType =
  lookup
    eventType
    [ ("app.deployed", "AppDeployedData")
    , ("database.backup.completed", "BackupCompletedData")
    , ("database.backup.accepted", "BackupAcceptedData")
    , ("change.applied", "ChangeAppliedData")
    , ("change.failed", "ChangeFailedData")
    , ("change.closed", "ChangeClosedData")
    , ("app.deleted", "AppDeletedData")
    , ("app.stopped", "AppStoppedData")
    , ("app.restarted", "AppRestartedData")
    , ("database.restored", "DatabaseRestoredData")
    , ("database.backup.failed", "BackupFailedData")
    , ("database.backup.freshness.changed", "BackupFreshnessChangedData")
    , ("platform.upgraded", "PlatformUpgradedData")
    ]

strictRecord :: Options
strictRecord = recordOptions {rejectUnknownFields = True}

-- | An accepted scope revision: its declaration's digest and generation.
data EventScopeRevision = EventScopeRevision
  { digest :: !Text
  , generation :: !Integer
  }
  deriving stock (Eq, Show, Generic)

-- | An exact stored object version.
data EventStoredVersion = EventStoredVersion
  { name :: !Text
  , version :: !Text
  }
  deriving stock (Eq, Show, Generic)

data EventActorKind = ActorOperator | ActorDeployer
  deriving stock (Eq, Show, Generic)

-- | Who a review says applied it: an operator, named or not, or a named
-- deployer. It is asserted by the client, not proved.
data EventActor = EventActor
  { kind :: !EventActorKind
  , name :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | The repository, commit and CI run a change came from; each is null when
-- its review named none.
data EventSource = EventSource
  { repository :: !(Nullable Text)
  , revision :: !(Nullable Text)
  , run :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

data DeploymentSubjectKind = SubjectApplication | SubjectService | SubjectSite
  deriving stock (Eq, Show, Generic)

data DeploymentActionKind = ActionDeploy | ActionRollback
  deriving stock (Eq, Show, Generic)

-- | @app.deployed@: a changed production release passed its reviewed
-- readiness and its transaction converged.
data AppDeployedData = AppDeployedData
  { subject :: !DeploymentSubjectKind
  , action :: !DeploymentActionKind
  , release :: !Text
  , previousRelease :: !(Nullable Text)
  , scopeRevision :: !EventScopeRevision
  , transaction :: !Text
  , review :: !Text
  , readiness :: !Text
  }
  deriving stock (Eq, Show, Generic)

data BackupOriginKind = OriginScheduled | OriginManual
  deriving stock (Eq, Show, Generic)

-- | @database.backup.completed@: an archive and its authenticated receipt
-- were verified at exact versions.
data BackupCompletedData = BackupCompletedData
  { backup :: !Text
  , origin :: !BackupOriginKind
  , run :: !Text
  , archive :: !EventStoredVersion
  , receipt :: !EventStoredVersion
  , sha256 :: !Text
  , archiveBytes :: !Integer
  , scheduleRevision :: !(Nullable Text)
  , recoveryPoint :: !(Nullable Text)
  , completedAt :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | @database.backup.accepted@: a reviewed transaction admitted the backup
-- as a recovery point. @completion@ is its completion event's ID.
data BackupAcceptedData = BackupAcceptedData
  { backup :: !Text
  , completion :: !Text
  , receiptScope :: !LifecycleScope
  , receiptRevision :: !EventScopeRevision
  , transaction :: !Text
  , review :: !Text
  , recoveryPoint :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

data ScopeChangeKind = ChangeCreated | ChangeUpdated | ChangeRetired
  deriving stock (Eq, Show, Generic)

-- | One scope a converged change created, updated or retired, from the
-- revision converged before to the one it converged (null when retired).
data EventScopeChange = EventScopeChange
  { scope :: !LifecycleScope
  , change :: !ScopeChangeKind
  , from :: !(Nullable EventScopeRevision)
  , to :: !(Nullable EventScopeRevision)
  }
  deriving stock (Eq, Show, Generic)

data OperationActionKind
  = OperationCreate
  | OperationUpdate
  | OperationVerify
  | OperationAdopt
  | OperationRetire
  | OperationReplaceStuckPod
  | OperationRunDeclaredOperation
  | OperationOpenMaintenanceSession
  | OperationRestoreLiveDatabase
  | OperationMigrate
  deriving stock (Eq, Show, Generic)

-- | How many of a change's operations had this action.
data EventActionCount = EventActionCount
  { action :: !OperationActionKind
  , count :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | @change.applied@: a reviewed inventory transaction converged. Every
-- converged change has one; @transaction@ joins it to the change's other
-- events. @scopes@ is empty for a change that only verified.
data ChangeAppliedData = ChangeAppliedData
  { transaction :: !Text
  , review :: !Text
  , actor :: !EventActor
  , source :: !EventSource
  , scopes :: ![EventScopeChange]
  , operations :: ![EventActionCount]
  }
  deriving stock (Eq, Show, Generic)

data FailureOutcomeKind = OutcomeFailedNoEffect | OutcomeFailedPartialOrUnknown | OutcomeAmbiguous
  deriving stock (Eq, Show, Generic)

data NextStepKind = NextResumeOrClose
  deriving stock (Eq, Show, Generic)

-- | @change.failed@: the executor recorded that an operation of a change
-- failed or that its outcome is unknown; the change waits for a resume or a
-- close. A stop the executor did not record publishes no event.
data ChangeFailedData = ChangeFailedData
  { transaction :: !Text
  , review :: !Text
  , actor :: !EventActor
  , source :: !EventSource
  , operation :: !(Nullable Text)
  , action :: !(Nullable OperationActionKind)
  , resources :: ![Text]
  , scope :: !(Nullable LifecycleScope)
  , outcome :: !FailureOutcomeKind
  , reason :: !(Nullable Text)
  , detail :: !Text
  , next :: !NextStepKind
  }
  deriving stock (Eq, Show, Generic)

data ClosedDispositionKind = ClosedReverted | ClosedKept
  deriving stock (Eq, Show, Generic)

-- | One scope of a closed change, reverted to its base or kept at the
-- change's revision.
data EventClosedScope = EventClosedScope
  { scope :: !LifecycleScope
  , disposition :: !ClosedDispositionKind
  }
  deriving stock (Eq, Show, Generic)

-- | @change.closed@: a stopped change was closed by its committed close
-- record (an operator's close, an abandoned migration or a proved
-- rollback). @attested@ says the close accepted operations no adapter could
-- prove.
data ChangeClosedData = ChangeClosedData
  { transaction :: !Text
  , review :: !Text
  , record :: !Text
  , scopes :: ![EventClosedScope]
  , attested :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | @app.deleted@: a converged change retired an application, standalone
-- service or site.
data AppDeletedData = AppDeletedData
  { subject :: !DeploymentSubjectKind
  , transaction :: !Text
  , review :: !Text
  , scopeRevision :: !EventScopeRevision
  , retainedMembers :: !Int
  , lastRelease :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | @app.stopped@: a converged change took a release subject offline.
data AppStoppedData = AppStoppedData
  { subject :: !DeploymentSubjectKind
  , transaction :: !Text
  , review :: !Text
  , scopeRevision :: !EventScopeRevision
  }
  deriving stock (Eq, Show, Generic)

-- | @app.restarted@: a converged change rolled a release subject to a fresh
-- revision under a new restart stamp.
data AppRestartedData = AppRestartedData
  { subject :: !DeploymentSubjectKind
  , transaction :: !Text
  , review :: !Text
  , scopeRevision :: !EventScopeRevision
  , restartStamp :: !Text
  }
  deriving stock (Eq, Show, Generic)

data RestoreTargetKindName = TargetScratch | TargetRebuilt
  deriving stock (Eq, Show, Generic)

-- | @database.restored@: a reviewed restore of a backup converged, into a
-- scratch database or a rebuilt server.
data DatabaseRestoredData = DatabaseRestoredData
  { restore :: !Text
  , backup :: !(Nullable Text)
  , database :: !(Nullable Text)
  , appDatabase :: !(Nullable Text)
  , namespace :: !(Nullable Text)
  , targetDatabase :: !(Nullable Text)
  , targetKind :: !RestoreTargetKindName
  , transaction :: !Text
  , review :: !Text
  , scopeRevision :: !EventScopeRevision
  }
  deriving stock (Eq, Show, Generic)

data BackupFailureReasonKind = ReasonBadSignature | ReasonWrongSource | ReasonChangedBytes
  deriving stock (Eq, Show, Generic)

-- | @database.backup.failed@: a scheduled run failed verification for a
-- reason no later cycle clears on its own.
data BackupFailedData = BackupFailedData
  { schedule :: !Text
  , run :: !Text
  , receipt :: !EventStoredVersion
  , archive :: !(Nullable EventStoredVersion)
  , reason :: !BackupFailureReasonKind
  , detail :: !Text
  }
  deriving stock (Eq, Show, Generic)

data FreshnessGradeKind = GradeFresh | GradeDeteriorating | GradeBreached
  deriving stock (Eq, Show, Generic)

data ObjectiveKind = ObjectiveHourly | ObjectiveDaily
  deriving stock (Eq, Show, Generic)

-- | @database.backup.freshness.changed@: a backup schedule's grade against
-- its signed recovery-point objective moved.
data BackupFreshnessChangedData = BackupFreshnessChangedData
  { schedule :: !Text
  , from :: !FreshnessGradeKind
  , to :: !FreshnessGradeKind
  , objective :: !ObjectiveKind
  , newestRecoveryPoint :: !Text
  , ageSeconds :: !Integer
  }
  deriving stock (Eq, Show, Generic)

-- | @platform.upgraded@: the context finished moving from one Nagare
-- release to another.
data PlatformUpgradedData = PlatformUpgradedData
  { from :: !Text
  , to :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EventScopeRevision where toJSON = genericToJSON strictRecord

instance FromJSON EventScopeRevision where parseJSON = genericParseJSON strictRecord

instance ToSchema EventScopeRevision where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "An accepted scope revision: its declaration's digest and generation."

instance ToJSON EventStoredVersion where toJSON = genericToJSON strictRecord

instance FromJSON EventStoredVersion where parseJSON = genericParseJSON strictRecord

instance ToSchema EventStoredVersion where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "An exact stored object version."

instance ToJSON EventActorKind where toJSON = genericToJSON (enumOptions "Actor")

instance FromJSON EventActorKind where parseJSON = genericParseJSON (enumOptions "Actor")

instance ToSchema EventActorKind where declareNamedSchema = enumSchema "Actor"

instance ToJSON EventActor where toJSON = genericToJSON strictRecord

instance FromJSON EventActor where parseJSON = genericParseJSON strictRecord

instance ToSchema EventActor where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "Who a review says applied it; asserted by the client, not proved."

instance ToJSON EventSource where toJSON = genericToJSON strictRecord

instance FromJSON EventSource where parseJSON = genericParseJSON strictRecord

instance ToSchema EventSource where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The repository, commit and CI run a change came from, each null when not recorded."

instance ToJSON DeploymentSubjectKind where toJSON = genericToJSON (enumOptions "Subject")

instance FromJSON DeploymentSubjectKind where parseJSON = genericParseJSON (enumOptions "Subject")

instance ToSchema DeploymentSubjectKind where declareNamedSchema = enumSchema "Subject"

instance ToJSON DeploymentActionKind where toJSON = genericToJSON (enumOptions "Action")

instance FromJSON DeploymentActionKind where parseJSON = genericParseJSON (enumOptions "Action")

instance ToSchema DeploymentActionKind where declareNamedSchema = enumSchema "Action"

instance ToJSON AppDeployedData where toJSON = genericToJSON strictRecord

instance FromJSON AppDeployedData where parseJSON = genericParseJSON strictRecord

instance ToSchema AppDeployedData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of app.deployed: a changed production release passed its reviewed readiness and its transaction converged."

instance ToJSON BackupOriginKind where toJSON = genericToJSON (enumOptions "Origin")

instance FromJSON BackupOriginKind where parseJSON = genericParseJSON (enumOptions "Origin")

instance ToSchema BackupOriginKind where declareNamedSchema = enumSchema "Origin"

instance ToJSON BackupCompletedData where toJSON = genericToJSON strictRecord

instance FromJSON BackupCompletedData where parseJSON = genericParseJSON strictRecord

instance ToSchema BackupCompletedData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of database.backup.completed: an archive and its authenticated receipt were verified at exact versions."

instance ToJSON BackupAcceptedData where toJSON = genericToJSON strictRecord

instance FromJSON BackupAcceptedData where parseJSON = genericParseJSON strictRecord

instance ToSchema BackupAcceptedData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of database.backup.accepted: a reviewed transaction admitted the backup as a recovery point. It grants no restore authority."

instance ToJSON ScopeChangeKind where toJSON = genericToJSON (enumOptions "Change")

instance FromJSON ScopeChangeKind where parseJSON = genericParseJSON (enumOptions "Change")

instance ToSchema ScopeChangeKind where declareNamedSchema = enumSchema "Change"

instance ToJSON EventScopeChange where toJSON = genericToJSON strictRecord

instance FromJSON EventScopeChange where parseJSON = genericParseJSON strictRecord

instance ToSchema EventScopeChange where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "One scope a converged change created, updated or retired."

instance ToJSON OperationActionKind where toJSON = genericToJSON (enumOptions "Operation")

instance FromJSON OperationActionKind where parseJSON = genericParseJSON (enumOptions "Operation")

instance ToSchema OperationActionKind where declareNamedSchema = enumSchema "Operation"

instance ToJSON EventActionCount where toJSON = genericToJSON strictRecord

instance FromJSON EventActionCount where parseJSON = genericParseJSON strictRecord

instance ToSchema EventActionCount where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "How many of a change's operations had this action."

instance ToJSON ChangeAppliedData where toJSON = genericToJSON strictRecord

instance FromJSON ChangeAppliedData where parseJSON = genericParseJSON strictRecord

instance ToSchema ChangeAppliedData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of change.applied: a reviewed inventory transaction converged. Every converged change has one, joined to its other events by transaction; scopes is empty for a change that only verified. actor and source are what the review asserted, not proved."

instance ToJSON FailureOutcomeKind where toJSON = genericToJSON (enumOptions "Outcome")

instance FromJSON FailureOutcomeKind where parseJSON = genericParseJSON (enumOptions "Outcome")

instance ToSchema FailureOutcomeKind where declareNamedSchema = enumSchema "Outcome"

-- | A one-member enumeration is still a string.
nextOptions :: Options
nextOptions = (enumOptions "Next") {tagSingleConstructors = True}

instance ToJSON NextStepKind where toJSON = genericToJSON nextOptions

instance FromJSON NextStepKind where parseJSON = genericParseJSON nextOptions

instance ToSchema NextStepKind where declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions nextOptions)

instance ToJSON ChangeFailedData where toJSON = genericToJSON strictRecord

instance FromJSON ChangeFailedData where parseJSON = genericParseJSON strictRecord

instance ToSchema ChangeFailedData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of change.failed: the executor recorded that an operation failed (failed-no-effect: refused before any effect) or that its outcome is unknown (ambiguous), and the change waits for a resume or a close. Each recorded stop is one event; a stop the executor did not record publishes none."

instance ToJSON ClosedDispositionKind where toJSON = genericToJSON (enumOptions "Closed")

instance FromJSON ClosedDispositionKind where parseJSON = genericParseJSON (enumOptions "Closed")

instance ToSchema ClosedDispositionKind where declareNamedSchema = enumSchema "Closed"

instance ToJSON EventClosedScope where toJSON = genericToJSON strictRecord

instance FromJSON EventClosedScope where parseJSON = genericParseJSON strictRecord

instance ToSchema EventClosedScope where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "One scope of a closed change: reverted to its base, or kept at the change's revision."

instance ToJSON ChangeClosedData where toJSON = genericToJSON strictRecord

instance FromJSON ChangeClosedData where parseJSON = genericParseJSON strictRecord

instance ToSchema ChangeClosedData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of change.closed: a stopped change was closed by its committed close record, whether an operator closed it, abandoned its migration or a proved rollback ended it."

instance ToJSON AppDeletedData where toJSON = genericToJSON strictRecord

instance FromJSON AppDeletedData where parseJSON = genericParseJSON strictRecord

instance ToSchema AppDeletedData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of app.deleted: a converged change retired an application, standalone service or site. retainedMembers counts the members it kept rather than deleted; lastRelease is the release current before, when the change operated the release log."

instance ToJSON AppStoppedData where toJSON = genericToJSON strictRecord

instance FromJSON AppStoppedData where parseJSON = genericParseJSON strictRecord

instance ToSchema AppStoppedData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of app.stopped: a converged change took an application, standalone service or site offline."

instance ToJSON AppRestartedData where toJSON = genericToJSON strictRecord

instance FromJSON AppRestartedData where parseJSON = genericParseJSON strictRecord

instance ToSchema AppRestartedData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of app.restarted: a converged change rolled an application, standalone service or site to a fresh revision under a new restart stamp."

instance ToJSON RestoreTargetKindName where toJSON = genericToJSON (enumOptions "Target")

instance FromJSON RestoreTargetKindName where parseJSON = genericParseJSON (enumOptions "Target")

instance ToSchema RestoreTargetKindName where declareNamedSchema = enumSchema "Target"

instance ToJSON DatabaseRestoredData where toJSON = genericToJSON strictRecord

instance FromJSON DatabaseRestoredData where parseJSON = genericParseJSON strictRecord

instance ToSchema DatabaseRestoredData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of database.restored: a reviewed restore of a backup converged, into a scratch database or a rebuilt server. database or appDatabase names the source; a member the restore did not record is null."

instance ToJSON BackupFailureReasonKind where toJSON = genericToJSON (enumOptions "Reason")

instance FromJSON BackupFailureReasonKind where parseJSON = genericParseJSON (enumOptions "Reason")

instance ToSchema BackupFailureReasonKind where declareNamedSchema = enumSchema "Reason"

instance ToJSON BackupFailedData where toJSON = genericToJSON strictRecord

instance FromJSON BackupFailedData where parseJSON = genericParseJSON strictRecord

instance ToSchema BackupFailedData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of database.backup.failed: a scheduled run failed verification for good (bad-signature, wrong-source or changed-bytes). It may still verify later, for example after its signing Secret is rebound, and then publishes database.backup.completed."

instance ToJSON FreshnessGradeKind where toJSON = genericToJSON (enumOptions "Grade")

instance FromJSON FreshnessGradeKind where parseJSON = genericParseJSON (enumOptions "Grade")

instance ToSchema FreshnessGradeKind where declareNamedSchema = enumSchema "Grade"

instance ToJSON ObjectiveKind where toJSON = genericToJSON (enumOptions "Objective")

instance FromJSON ObjectiveKind where parseJSON = genericParseJSON (enumOptions "Objective")

instance ToSchema ObjectiveKind where declareNamedSchema = enumSchema "Objective"

instance ToJSON BackupFreshnessChangedData where toJSON = genericToJSON strictRecord

instance FromJSON BackupFreshnessChangedData where parseJSON = genericParseJSON strictRecord

instance ToSchema BackupFreshnessChangedData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of database.backup.freshness.changed: a backup schedule's grade (fresh, deteriorating or breached) against its signed hourly or daily recovery-point objective moved, graded from the newest recovery point the collector verified."

instance ToJSON PlatformUpgradedData where toJSON = genericToJSON strictRecord

instance FromJSON PlatformUpgradedData where parseJSON = genericParseJSON strictRecord

instance ToSchema PlatformUpgradedData where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The data of platform.upgraded: the context finished moving from the release from to the release to. A retargeted transition is one event, for the release it committed; a release that moved no scope publishes none."
