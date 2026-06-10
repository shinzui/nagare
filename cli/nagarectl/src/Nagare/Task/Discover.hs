{-# LANGUAGE PackageImports #-}

-- | Shared scheduled-task discovery for the @nagarectl task@ commands
-- (MasterPlan 10, EP-51, Integration Point IP4).
--
-- This module owns the task label selector, the defensive
-- @kubectl get cronjob -o json@ parse, and the @task list@ table formatter. The
-- pure parts ('taskLabelSelector', 'extractTaskRows', 'formatTaskTable') are
-- separated from the @kubectl@ IO so they are unit-testable without a cluster,
-- exactly as 'Nagare.Database.Discover' separates 'dbLabelSelector' /
-- 'extractDbRows' / 'formatDbTable'. EP-52 narrows the same query to one app by
-- appending @,nagare.dev/app=<app>@ to the selector — it must extend, not fork,
-- this module.
module Nagare.Task.Discover
  ( taskLabelSelector
  , AppScope (..)
  , TaskRow (..)
  , extractTaskRows
  , listTasks
  , getTask
  , formatTaskTable
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.List (find)
import Data.Text qualified as T
import Data.Vector qualified as V
import System.Exit (ExitCode (..))

-- | How a command scopes discovery by the @nagare.dev/app@ label.
--
-- * 'AnyApp' — do not constrain by app (the @task list@ default; lists every task).
-- * 'NoApp' — only tasks with NO @nagare.dev/app@ label (the @-@ sentinel app).
-- * 'App name' — only tasks whose @nagare.dev/app@ equals @name@.
data AppScope = AnyApp | NoApp | App Text
  deriving stock (Eq, Show)

-- | The base label selector that finds every Nagare-managed task CronJob
-- (IP3/IP4): managed by nagarectl AND carrying the @nagare.dev/task@ label.
-- EP-52 narrows by 'AppScope'; it never re-derives names.
taskLabelSelector :: AppScope -> Text
taskLabelSelector scope = base <> appTerm scope
  where
    base = "nagare.dev/managed-by=nagarectl,nagare.dev/task"
    appTerm AnyApp = ""
    appTerm NoApp = ",!nagare.dev/app"
    appTerm (App a) = ",nagare.dev/app=" <> a

-- | One discovered scheduled task, read back from its CronJob.
data TaskRow = TaskRow
  { trName :: !Text
  -- ^ the task name (the @nagare.dev/task@ label, falling back to the object name
  -- with the @nagare-task-@ prefix stripped)
  , trApp :: !Text
  -- ^ the owning app (@nagare.dev/app@ label) or @"-"@ when app-less
  , trSchedule :: !Text
  -- ^ @.spec.schedule@ (the cron expression) or @"?"@
  , trLastRun :: !Text
  -- ^ @.status.lastScheduleTime@ or @"never"@
  , trLastSuccess :: !Text
  -- ^ @.status.lastSuccessfulTime@ or @"never"@
  , trActive :: !Int
  -- ^ number of currently-active Jobs (@length .status.active@)
  }
  deriving stock (Generic, Eq, Show)

-- | Parse a @kubectl get cronjob -n <ns> -l <selector> -o json@ list into rows.
-- Defensive (mirrors 'Nagare.Database.Discover.extractDbRows'): an empty/absent
-- @items@ array is @Right []@, a malformed top-level shape is a 'Left', and an
-- item with no @.metadata.name@ is skipped rather than fatal.
extractTaskRows :: ByteString -> Either Text [TaskRow]
extractTaskRows bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode cronjob list JSON: " <> T.pack e)
    Right v -> case lookupPath ["items"] v of
      Just (Aeson.Array items) -> Right (foldr step [] (V.toList items))
      _ -> Right []
  where
    step item acc = case rowFromItem item of
      Just r -> r : acc
      Nothing -> acc

rowFromItem :: Aeson.Value -> Maybe TaskRow
rowFromItem item = do
  objName <- textAt ["metadata", "name"] item
  let taskName =
        fromMaybe
          (stripTaskPrefix objName)
          (labelAt "nagare.dev/task" item)
  pure
    TaskRow
      { trName = taskName
      , trApp = fromMaybe "-" (labelAt "nagare.dev/app" item)
      , trSchedule = fromMaybe "?" (textAt ["spec", "schedule"] item)
      , trLastRun = fromMaybe "never" (textAt ["status", "lastScheduleTime"] item)
      , trLastSuccess = fromMaybe "never" (textAt ["status", "lastSuccessfulTime"] item)
      , trActive = activeCount item
      }

-- | Strip the @nagare-task-@ name prefix EP-50 stamps (IP3), if present.
stripTaskPrefix :: Text -> Text
stripTaskPrefix n = fromMaybe n (T.stripPrefix "nagare-task-" n)

activeCount :: Aeson.Value -> Int
activeCount item =
  case lookupPath ["status", "active"] item of
    Just (Aeson.Array a) -> V.length a
    _ -> 0

-- | List managed tasks in @ns@ matching @scope@ via @kubectl get cronjob -l
-- <selector> -o json@. A failed query (missing namespace, unreachable cluster) is
-- @Right []@; a present-but-malformed response is a 'Left'.
listTasks :: Text -> AppScope -> IO (Either Text [TaskRow])
listTasks ns scope = do
  (code, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "get"
          , "cronjob"
          , "-n"
          , T.unpack ns
          , "-l"
          , T.unpack (taskLabelSelector scope)
          , "-o"
          , "json"
          ]
        & silenceStderr
  pure $ case code of
    ExitFailure _ -> Right []
    ExitSuccess -> extractTaskRows out

-- | Look up a single task by name in @ns@, scoped by @scope@. @Left@ with a clear
-- message when no managed task of that name exists in that scope.
getTask :: Text -> AppScope -> Text -> IO (Either Text TaskRow)
getTask ns scope name = do
  rows <- listTasks ns scope
  pure $ case rows of
    Left e -> Left e
    Right rs -> case find ((== name) . trName) rs of
      Just r -> Right r
      Nothing -> Left ("no managed task named '" <> name <> "' in namespace " <> ns)

-- | Render the @task list@ table with @pad@-aligned columns.
formatTaskTable :: [TaskRow] -> Text
formatTaskTable [] = "(no scheduled tasks)\n"
formatTaskTable rows = T.unlines (header : map line rows)
  where
    header =
      "  "
        <> pad 18 "NAME"
        <> pad 12 "APP"
        <> pad 16 "SCHEDULE"
        <> pad 22 "LAST RUN"
        <> pad 22 "LAST SUCCESS"
        <> "ACTIVE"
    line r =
      T.concat
        [ "  "
        , pad 18 (trName r)
        , pad 12 (trApp r)
        , pad 16 (trSchedule r)
        , pad 22 (trLastRun r)
        , pad 22 (trLastSuccess r)
        , tShow (trActive r)
        ]
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

-- ---------------------------------------------------------------------------
-- JSON walking (local copies; mirror Nagare.Database.Discover's private helpers)

lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] v = Just v
lookupPath (k : ks) (Aeson.Object o) = KeyMap.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing

textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (Aeson.String s) -> Just s
  _ -> Nothing

labelAt :: Text -> Aeson.Value -> Maybe Text
labelAt key = textAt ["metadata", "labels", key]

-- | Show an Int as Text (local; the package-wide @tShow@ lives in @app/Main.hs@
-- and is not exported).
tShow :: (Show a) => a -> Text
tShow = T.pack . show
