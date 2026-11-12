-- | An app database's scheduled backup (EP-202): its key space, schedule
-- name and CronJob, the same signed, read-back producer as a server's, dumping
-- with the app's own migration credential.
module Nagare.Database.AppDatabase.Backup
  ( AppDatabaseBackup (..)
  , renderInventoryAppDatabaseBackupCronJob
  , appDatabaseBackupKeyPrefix
  , appDatabaseBackupScheduleName
  )
where

import Data.Aeson ((.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Cluster.GcsJob (StoreBackend, storePrefixUrl)
import Nagare.Database.Backup (BackupDest (..), BackupJobInputs (..), BackupSource (..), appDatabaseBackupExt, appOwnedBackupFormat, renderScheduledCronJob)
import Nagare.Dsl.Database (Engine)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective)

-- | App-database archives (EP-202) live in their own key space, one prefix
-- per app database: @app-databases/\<namespace\>/\<app database\>/@.
appDatabaseBackupKeyPrefix :: Text -> Text -> Text
appDatabaseBackupKeyPrefix namespaceName appDatabase = "app-databases/" <> namespaceName <> "/" <> appDatabase <> "/"

-- | The schedule, ServiceAccount and signing-Secret stem of an app database:
-- at most 49 characters for a 36-character name, and never a server's
-- @nagare-dbbackup-@ name.
appDatabaseBackupScheduleName :: Text -> Text
appDatabaseBackupScheduleName appDatabase = "nagare-appdb-" <> appDatabase

-- | What an app database's schedule dumps (EP-202): its logical databases on
-- its server, with the server's own engine image as the client, and the
-- digest of the accepted declaration whose users and grants a restore
-- re-applies.
data AppDatabaseBackup = AppDatabaseBackup
  { namespace :: !Text
  , appDatabase :: !Text
  , server :: !Text
  , engine :: !Engine
  , clientImage :: !Text
  , databases :: ![Text]
  , declaration :: !Text
  , appOwner :: !(Maybe Text)
  -- ^ an app-owned database's owner user (EP-257): it is dumped as the server
  -- administrator, so no grant the app manages can make its backup
  -- incomplete, with the app's role file (EP-258)
  }
  deriving stock (Generic, Eq, Show)

-- | An app database's reviewed schedule: the same signed, read-back producer
-- as a server's, dumping with the app's migration credential. Its receipts'
-- metadata names the app database, server, databases and declaration.
renderInventoryAppDatabaseBackupCronJob :: RecoveryPointObjective -> AppDatabaseBackup -> StoreBackend -> Int -> ByteString
renderInventoryAppDatabaseBackupCronJob objective backup backend keep =
  renderScheduledCronJob objective True True baseInputs $ \revision ->
    [ "appDatabase" .= (backup ^. #appDatabase)
    , "server" .= (backup ^. #server)
    , "databases" .= (backup ^. #databases)
    , "declaration" .= (backup ^. #declaration)
    , "namespace" .= (backup ^. #namespace)
    , "engine" .= T.toLower (T.pack (show (backup ^. #engine)))
    , "format" .= maybe (appDatabaseBackupExt (backup ^. #engine)) (const appOwnedBackupFormat) (backup ^. #appOwner)
    , "schedule" .= schedule
    , "scheduleRevision" .= revision
    , "keep" .= keep
    ]
  where
    schedule = appDatabaseBackupScheduleName (backup ^. #appDatabase)
    baseInputs =
      BackupJobInputs
        { namespace = backup ^. #namespace
        , jobName = schedule
        , source = AppDatabaseSource (backup ^. #engine) (backup ^. #databases) (backup ^. #appOwner)
        , clientImage = backup ^. #clientImage
        , unpinnedStoreImage = False
        , serviceHost = backup ^. #server
        , secretName = if isJust (backup ^. #appOwner) then "nagare-db-" <> backup ^. #server else backup ^. #appDatabase <> "-migration"
        , name = backup ^. #server
        , destination = BackupDestStamped
        , prefix = storePrefixUrl backend (appDatabaseBackupKeyPrefix (backup ^. #namespace) (backup ^. #appDatabase))
        , keep = keep
        , selfPrune = False
        , verifyStored = True
        , receipt = Nothing
        , backend = backend
        }
