-- | BackupRestore responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.BackupRestore
  ( backupRestoreTests
  )
where

import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Test.Backup.Escrow (signingKeyEscrowTests)
import Nagare.Test.Backup.Objective (backupObjectiveTests)
import Nagare.Test.Backup.Paths (backupPathTests)
import Nagare.Test.Backup.Prune (backupPruneTests)
import Nagare.Test.Backup.PruneWorld (pruneWorldTests)
import Nagare.Test.Backup.Rendering (backupRendererTests)
import Nagare.Test.Backup.Restore (restoreDownloadTests)
import Nagare.Test.Backup.Retention (backupRetentionTests)
import Nagare.Test.Backup.Scheduled (scheduledReceiptTests)
import Nagare.Test.Backup.Upload (backupUploadTests)
import Test.Tasty (TestTree, testGroup)

backupRestoreTests :: [TestTree]
backupRestoreTests =
  [ testGroup "pure path / extension / schedule" backupPathTests
  , testGroup "Job / CronJob renderers" (backupRendererTests <> scheduledReceiptTests <> signingKeyEscrowTests <> backupObjectiveTests <> backupUploadTests <> backupPruneTests <> backupRetentionTests <> pruneWorldTests)
  , testGroup "restore" restoreDownloadTests
  ]
