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
  , eventDataSchemaName
  )
where

import Data.Aeson
  ( FromJSON (..)
  , Options (rejectUnknownFields)
  , ToJSON (..)
  , genericParseJSON
  , genericToJSON
  )
import Data.OpenApi (ToSchema (..), description, schema)
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
