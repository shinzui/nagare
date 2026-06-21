-- | @nagarectl broker restart NAME@: roll the broker StatefulSet and wait.
module Nagare.Broker.Restart
  ( runBrokerRestart
  )
where

import Cradle
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Broker.Discover (getBroker)
import Nagare.Deploy (waitForRollout)
import Nagare.Dsl.Prelude
import System.Exit (exitFailure)
import System.IO (stderr)

runBrokerRestart :: Text -> Text -> Bool -> IO ()
runBrokerRestart ns name dryRun = do
  erow <- getBroker ns name
  case erow of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right _
      | dryRun ->
          TIO.putStrLn
            ("Would run: kubectl rollout restart statefulset/" <> name <> " -n " <> ns)
      | otherwise -> do
          run_ $
            cmd "kubectl"
              & addArgs ["rollout", "restart", "statefulset/" <> T.unpack name, "-n", T.unpack ns]
          waitForRollout ns name
          TIO.putStrLn ("Restarted broker: " <> name)
