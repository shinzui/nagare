{-# LANGUAGE PackageImports #-}

-- | @nagarectl task run APP TASK@ (MasterPlan 10, EP-51, Integration Point IP6):
-- run a scheduled task once, now. Creates a single Job from the deployed CronJob
-- via @kubectl create job <name> --from=cronjob/nagare-task-<task>@, waits for it
-- with @kubectl wait --for=condition=complete@, tails its logs on failure, and
-- reports. With @--dry-run@, prints the exact @kubectl@ command and runs nothing.
--
-- This reuses Kubernetes' native @--from=cronjob@ so a manual run is byte-for-byte
-- identical to a scheduled run — no separate Job rendering, no drift. It mirrors the
-- apply -> wait -> log-on-failure flow of 'Nagare.Database.Backup.waitForJob'.
module Nagare.Task.Run
  ( TaskRunParams (..)
  , oneOffJobName
  , runArgs
  , runTaskRun
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Task.Discover (AppScope, getTask)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (stderr)

data TaskRunParams = TaskRunParams
  { trpApp :: !Text
  , trpTask :: !Text
  , trpNamespace :: !Text
  , trpScope :: !AppScope
  , trpDryRun :: !Bool
  }
  deriving stock (Generic, Show)

-- | The deterministic one-off Job name: @nagare-task-<task>-manual-<YYYYmmddHHMMSS>@,
-- lower-cased and truncated to Kubernetes' 63-character name limit (as
-- 'Nagare.Database.Backup' does for its backup Job). Pure in @now@ so it is testable.
oneOffJobName :: Text -> UTCTime -> Text
oneOffJobName task now =
  T.take 63 (T.toLower ("nagare-task-" <> task <> "-manual-" <> stamp))
  where
    stamp = T.pack (formatTime defaultTimeLocale "%Y%m%d%H%M%S" now)

-- | The @kubectl@ argument vector for the one-off run (pure, unit-testable):
-- @create job <jobName> --from=cronjob/nagare-task-<task> -n <ns>@.
runArgs :: Text -> Text -> Text -> [String]
runArgs ns task jobName =
  [ "create"
  , "job"
  , T.unpack jobName
  , "--from=cronjob/nagare-task-" <> T.unpack task
  , "-n"
  , T.unpack ns
  ]

-- | Run a task once. In @--dry-run@ mode this only prints the exact @kubectl@
-- commands and contacts no cluster. Otherwise it verifies the task exists (scoped
-- by @scope@) so a typo fails before touching the cluster, then creates the Job,
-- waits, and reports.
runTaskRun :: TaskRunParams -> IO ()
runTaskRun p
  | trpDryRun p = do
      now <- getCurrentTime
      let ns = trpNamespace p
          task = trpTask p
          jobName = oneOffJobName task now
          args = runArgs ns task jobName
      TIO.putStrLn "--- task run (dry-run) ---"
      TIO.putStrLn ("kubectl " <> T.unwords (map T.pack args))
      TIO.putStrLn
        ( "Then: kubectl wait --for=condition=complete --timeout=600s job/"
            <> jobName
            <> " -n "
            <> ns
        )
  | otherwise = do
      erow <- getTask (trpNamespace p) (trpScope p) (trpTask p)
      case erow of
        Left err -> do
          TIO.hPutStrLn stderr ("nagarectl: " <> err)
          exitFailure
        Right _ -> do
          now <- getCurrentTime
          let ns = trpNamespace p
              task = trpTask p
              jobName = oneOffJobName task now
              args = runArgs ns task jobName
          TIO.putStrLn ("Starting one-off run " <> jobName <> " ...")
          run_ $ cmd "kubectl" & addArgs args
          waitForTaskJob ns jobName task
          TIO.putStrLn ("Task " <> task <> " completed (" <> jobName <> ").")

-- | Wait for the one-off Job to reach @condition=complete@; on timeout/failure,
-- tail its logs and exit non-zero. Mirrors 'Nagare.Database.Backup.waitForJob'.
waitForTaskJob :: Text -> Text -> Text -> IO ()
waitForTaskJob ns jobName task = do
  (code, _ :: StdoutUntrimmed) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "wait"
          , "--for=condition=complete"
          , "--timeout=600s"
          , "job/" <> T.unpack jobName
          , "-n"
          , T.unpack ns
          ]
        & silenceStderr
  case code of
    ExitSuccess -> pure ()
    ExitFailure _ -> do
      TIO.hPutStrLn stderr ("nagarectl: task " <> task <> " run " <> jobName <> " did not complete; recent logs:")
      run_ $ cmd "kubectl" & addArgs ["logs", "job/" <> T.unpack jobName, "-n", T.unpack ns, "--tail", "50"]
      exitFailure
