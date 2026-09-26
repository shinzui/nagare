-- | Read-only compatibility preview for @nagarectl broker restart --dry-run@.
-- Live restart changes the accepted StatefulSet in a reviewed scope.
module Nagare.Broker.Restart
  ( runBrokerRestart
  )
where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Broker.Discover (getBroker)
import Nagare.Dsl.Prelude
import System.Exit (exitFailure)
import System.IO (stderr)

runBrokerRestart :: Text -> Text -> Bool -> IO ()
runBrokerRestart ns name dryRun = do
  unless dryRun $ do
    TIO.hPutStrLn stderr "nagarectl: live broker restart requires a reviewed StatefulSet scope"
    exitFailure
  erow <- getBroker ns name
  case erow of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right _ -> TIO.putStrLn
      ("Would run: kubectl rollout restart statefulset/" <> name <> " -n " <> ns)
