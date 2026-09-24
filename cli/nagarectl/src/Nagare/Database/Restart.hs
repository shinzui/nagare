-- | @nagarectl db restart NAME@ (MasterPlan 9, EP-45): roll the database
-- StatefulSet's pod and wait for it to be Ready again. @--dry-run@ prints the
-- command and does nothing.
module Nagare.Database.Restart
  ( runDbRestart
  )
where

import Cradle
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Deploy (requireWait, waitForRollout)
import Nagare.Dsl.Prelude
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Roll the StatefulSet (namespace, name, dry-run).
runDbRestart :: Text -> Text -> Bool -> IO ()
runDbRestart ns name dryRun
  | dryRun =
      TIO.putStrLn
        ("Would run: kubectl rollout restart statefulset/" <> name <> " -n " <> ns)
  | otherwise = do
      transaction <- lookupEnv "NAGARE_INVENTORY_TRANSACTION"
      when (isJust transaction) $ do
        TIO.hPutStrLn stderr "nagarectl: db restart cannot run inside a reviewed inventory transaction"
        exitFailure
      run_ $
        cmd "kubectl"
          & addArgs ["rollout", "restart", "statefulset/" <> T.unpack name, "-n", T.unpack ns]
      waitForRollout ns name >>= requireWait ("database '" <> name <> "'")
      TIO.putStrLn ("Restarted: " <> name)
