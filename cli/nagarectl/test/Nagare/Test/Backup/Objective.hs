-- | Recovery-point objective transitions and signed schedule reporting for
-- compiled database bundles (MasterPlan 23, D6).
module Nagare.Test.Backup.Objective
  ( backupObjectiveTests
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database (Database (Database), Engine (Postgres), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (..))
import Nagare.Inventory.DataService (compileBackupPruneRemovalScope, compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.Status (signedScheduledBackups)
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Inventory (Declaration (Managed), declarations, scopeBundles)
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Types (ScopeKind (Standalone), SourceLocation (..), mkName, mkScopeId)
import Nagare.Test.Support.Kubernetes (cluster, ok)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

backupObjectiveTests :: [TestTree]
backupObjectiveTests =
  [ testCase "a context objective change is a bounded CronJob-only update in both directions" $ do
      let target objective = DatabaseBackupTarget (GcsBackend "project" "bucket") objective
          (hourlyScope, hourlyNative) = ok (compileStandaloneDatabase direct (target HourlyRecoveryPoint))
          (dailySafeScope, dailySafeNative) = ok (compileStandaloneDatabase direct (target DailyRecoveryPoint))
          (dailyScope, dailyNative) =
            ok (compileBackupPruneRemovalScope "pg-main" "personal" (target DailyRecoveryPoint) hourlyScope hourlyNative)
      Map.delete backupId dailyNative @?= Map.delete backupId hourlyNative
      Map.lookup backupId dailyNative @?= Map.lookup backupId dailySafeNative
      scopeBundles dailyScope @?= scopeBundles dailySafeScope
      assertBool "daily schedule lacks its signed objective" (BC.isInfixOf "recoveryPoint" (snd (dailyNative Map.! backupId)))
      compileBackupPruneRemovalScope "pg-main" "personal" (target HourlyRecoveryPoint) dailyScope dailyNative
        @?= Right (hourlyScope, hourlyNative)
  , testCase "inventory status reports retention for schedules with a signing Secret" $ do
      let (scope, _) = ok (compileStandaloneDatabase direct (DatabaseBackupTarget (GcsBackend "project" "bucket") HourlyRecoveryPoint))
          members = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]
      signedScheduledBackups members members @?= [backupId]
      signedScheduledBackups members (filter ((/= backupId) . (^. #identity)) members) @?= []
  ]
  where
    owner = ok (mkScopeId Standalone "database-pg-main")
    db =
      Database
        (ok (mkDatabaseName "pg-main"))
        Nothing
        Postgres
        (defaultEngineVersion Postgres)
        (ok (Dsl.mkNamespace "personal"))
        (ok (Dsl.mkQuantity "10Gi"))
        Nothing
        Dsl.Retain
    recovery = RecoveryIntent (ok (mkName "backup")) (mkSecretRef (ok (mkName "db-password")) (ok (mkName "v1")) :| [])
    direct = DatabaseDirectInput db owner cluster Nothing recovery (SourceLocation "database" "postgres")
    backupId = ok (databaseResourceId owner (ok (mkName "backup")) db)
