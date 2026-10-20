-- | App-database command options (EP-202). Executable-private CLI boundary:
-- every option type the @db app-database@ subcommands parse.
module Nagare.Cli.Options.AppDatabase
  ( AppDatabaseCommand (..)
  , AppDatabasePlanOpts (..)
  , AppDatabaseNameOpts (..)
  , AppDatabaseReceiptsOpts (..)
  , AppDatabaseRestoreOpts (..)
  , AppDatabasePruneOpts (..)
  , AppDatabaseRecoverPruneOpts (..)
  )
where

import Nagare.Dsl.Prelude

data AppDatabaseCommand
  = AppDatabasePlan AppDatabasePlanOpts
  | AppDatabaseRotate AppDatabaseNameOpts String
  | AppDatabaseRetire AppDatabaseNameOpts
  | -- | EP-205: the users to quiesce, as @runtime@ or @runtime,migration@
    AppDatabaseQuiesce AppDatabaseNameOpts String
  | AppDatabaseResume AppDatabaseNameOpts
  | AppDatabaseList (Maybe String)
  | AppDatabaseBackupReceipts AppDatabaseReceiptsOpts
  | AppDatabaseRestore AppDatabaseRestoreOpts
  | AppDatabasePruneScheduledBackups AppDatabasePruneOpts
  | AppDatabaseRecoverScheduledPrune AppDatabaseRecoverPruneOpts
  deriving stock (Generic, Show)

-- | Review an app database's accepted scheduled runs past the retention
-- policy (F132), as @db prune-scheduled-backups@ reviews a database's.
data AppDatabasePruneOpts = AppDatabasePruneOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , bucket :: !(Maybe String)
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)

-- | Review deletion of the receipt an abandoned partial prune left.
data AppDatabaseRecoverPruneOpts = AppDatabaseRecoverPruneOpts
  { name :: !String
  , backupId :: !String
  , namespace :: !(Maybe String)
  , bucket :: !(Maybe String)
  , failedReview :: !FilePath
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)

-- | Restore one ingested scheduled run into scratch names.
data AppDatabaseRestoreOpts = AppDatabaseRestoreOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , bucket :: !(Maybe String)
  , backupId :: !String
  , restoreId :: !String
  , rebuilt :: !Bool
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)

-- | Ingest an app database's verified scheduled runs: one by its Job UID, or
-- every verified run not yet ingested.
data AppDatabaseReceiptsOpts = AppDatabaseReceiptsOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , bucket :: !(Maybe String)
  , backupId :: !(Maybe String)
  , allVerified :: !Bool
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)

data AppDatabasePlanOpts = AppDatabasePlanOpts
  { config :: !FilePath
  , recoveryBackup :: !(Maybe String)
  , recoveryKeyVersion :: !(Maybe String)
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

data AppDatabaseNameOpts = AppDatabaseNameOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , scopeKey :: !(Maybe String)
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)
