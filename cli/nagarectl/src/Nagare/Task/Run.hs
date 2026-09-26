-- | Read-only legacy task-run preview and pure command helpers (EP-51).
-- Live manual runs use stable reviewed Job scopes from accepted CronJob bytes.
module Nagare.Task.Run
  ( oneOffJobName
  , runArgs
  , previewTaskRun
  )
where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Dsl.Prelude

-- | The legacy timestamped Job name, retained for offline preview output.
oneOffJobName :: Text -> UTCTime -> Text
oneOffJobName task now =
  T.take 63 (T.toLower ("nagare-task-" <> task <> "-manual-" <> stamp))
  where
    stamp = T.pack (formatTime defaultTimeLocale "%Y%m%d%H%M%S" now)

-- | The legacy kubectl argument vector, printed but never executed here.
runArgs :: Text -> Text -> Text -> [String]
runArgs ns task name =
  [ "create"
  , "job"
  , T.unpack name
  , "--from=cronjob/nagare-task-" <> T.unpack task
  , "-n"
  , T.unpack ns
  ]

-- | Show what the older timestamped command would have run. The reviewed
-- command uses an accepted CronJob and stable run ID instead.
previewTaskRun :: Text -> Text -> IO ()
previewTaskRun ns task = do
  now <- getCurrentTime
  let name = oneOffJobName task now
      args = runArgs ns task name
  TIO.putStrLn "--- task run (dry-run) ---"
  TIO.putStrLn ("kubectl " <> T.unwords (map T.pack args))
  TIO.putStrLn
    ( "Then: kubectl wait --for=condition=complete --timeout=600s job/"
        <> name
        <> " -n "
        <> ns
    )
