{-# LANGUAGE PackageImports #-}

-- | @nagarectl task logs APP TASK@ (MasterPlan 10, EP-51, Integration Point IP6):
-- show a task's most recent pod logs, following a running one with @--follow@. Pods
-- are selected by the IP3 label @nagare.dev/task=<task>@ (narrowed by app). After
-- streaming, prints a one-line Grafana/VictoriaLogs hint for run history (the cluster
-- logging stack already scrapes these pods; EP-53 documents the full walkthrough).
module Nagare.Task.Logs
  ( TaskLogTarget (..)
  , taskLogArgs
  , grafanaHint
  , runTaskLogs
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Task.Discover (AppScope (..))

data TaskLogTarget = TaskLogTarget
  { tltNamespace :: !Text
  , tltTask :: !Text
  , tltScope :: !AppScope
  , tltFollow :: !Bool
  , tltTail :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

-- | The @kubectl logs@ argument vector for a 'TaskLogTarget' (pure, unit-testable).
-- Selects pods by @nagare.dev/task=<task>@ (plus @,nagare.dev/app=<app>@ when scoped,
-- or @,!nagare.dev/app@ for the @-@ sentinel).
taskLogArgs :: TaskLogTarget -> [String]
taskLogArgs t =
  [ "logs"
  , "-l"
  , T.unpack (selector t)
  , "-n"
  , T.unpack (tltNamespace t)
  ]
    <> maybe [] (\n -> ["--tail", show n]) (tltTail t)
    <> ["--follow" | tltFollow t]
  where
    selector x = "nagare.dev/task=" <> tltTask x <> appTerm (tltScope x)
    appTerm AnyApp = ""
    appTerm NoApp = ",!nagare.dev/app"
    appTerm (App a) = ",nagare.dev/app=" <> a

-- | A one-line pointer into the cluster's Grafana/VictoriaLogs history for a task.
-- The label query mirrors the kubectl selector so the operator can paste it into the
-- VictoriaLogs Explore view for older runs (EP-53 documents the full walkthrough).
grafanaHint :: Text -> Text
grafanaHint task =
  "For older runs, query VictoriaLogs in Grafana with: {nagare_dev_task=\""
    <> task
    <> "\"}"

-- | Stream (or print) a task's pod logs, inheriting stdout/stderr so @--follow@ tails
-- live. Then print the Grafana history hint. (Mirrors
-- 'Nagare.App.streamServiceLogs'.)
runTaskLogs :: TaskLogTarget -> IO ()
runTaskLogs t = do
  run_ $ cmd "kubectl" & addArgs (taskLogArgs t)
  TIO.putStrLn (grafanaHint (tltTask t))
