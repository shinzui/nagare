-- | Read-only compatibility preview for @nagarectl db restart --dry-run@.
-- Live restart changes the accepted StatefulSet in a reviewed scope.
module Nagare.Database.Restart
  ( runDbRestart
  )
where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Prelude
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Roll the StatefulSet (namespace, name, dry-run).
runDbRestart :: Text -> Text -> Bool -> IO ()
runDbRestart ns name dryRun
  | dryRun = TIO.putStrLn
      ("Would run: kubectl rollout restart statefulset/" <> name <> " -n " <> ns)
  | otherwise = do
      TIO.hPutStrLn stderr "nagarectl: live db restart requires a reviewed StatefulSet scope"
      exitFailure
