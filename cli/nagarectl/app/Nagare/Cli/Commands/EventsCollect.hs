-- | @nagarectl events collect-backups --once@ (EP-233): one bounded backup
-- collection cycle, then one materialization, for disposable fixtures and
-- operator diagnostics. It reads accepted inventory and the backup bucket
-- and writes only the context's lifecycle prefix: it never ingests, prunes,
-- restores or runs a backup. @--activate@ enables the feed at the journal's
-- tip and collection with the backups present now as its baseline.
module Nagare.Cli.Commands.EventsCollect
  ( runEventsCollectBackups
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Nagare.Cli.Options.Events (EventsCollectBackupsOpts (..))
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Cluster.GcsJob (storeObjectUrl)
import Nagare.Dsl.Prelude
import Nagare.Events.BackupCollector
import Nagare.Events.BackupSources (loadBackupSchedules)
import Nagare.Events.Materialize (defaultBudget, enableFeed, materializeOnce)
import Nagare.Events.Source (tipCheckpoint)
import Nagare.Events.Target (openTargetFeed, targetBackupReader, targetBinding, targetSigningKey)
import Nagare.Inventory.Command (openTargetStoreReadOnly)

runEventsCollectBackups :: Maybe String -> EventsCollectBackupsOpts -> IO ()
runEventsCollectBackups mctx options = do
  unless (options ^. #once) (dieT "nagarectl: events collect-backups: pass --once; it runs one bounded cycle, and the lifecycle event service runs it continuously")
  target <- activeTarget mctx
  binding <- either dieT pure (targetBinding target)
  backend <- resolveStoreBackend mctx (options ^. #bucket)
  inventory <- openTargetStoreReadOnly target >>= either (dieT . showT) pure
  (schedules, unresolved) <- loadBackupSchedules inventory backend >>= either (dieT . ("nagarectl: events collect-backups: " <>)) pure
  feed <- openTargetFeed target >>= either dieT pure
  reader <- targetBackupReader target backend >>= either dieT pure
  let ops = CollectorOps reader (storeObjectUrl backend "") (targetSigningKey target) getCurrentTime
  when (options ^. #activate) $ do
    tip <- tipCheckpoint inventory >>= either (dieT . showT) pure
    epoch <- T.pack . formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" <$> getCurrentTime
    _ <- enableFeed feed binding epoch tip >>= either (dieT . showT) pure
    void (activateCollection feed binding ops schedules >>= either (dieT . showT) pure)
  outcome <-
    collectOnce feed binding ops defaultCollectBudget schedules >>= \case
      Left CollectNotActive -> dieT "nagarectl: events collect-backups: collection is not active for this context; pass --activate to start it"
      Left err -> dieT ("nagarectl: events collect-backups: " <> showT err)
      Right value -> pure value
  materialized <- materializeOnce inventory feed binding defaultBudget (stamp <$> getCurrentTime) >>= either (dieT . showT) pure
  TIO.putStr . T.unlines $
    [ "schedules: " <> showT (length schedules) <> " collected, " <> showT (length unresolved) <> " unresolved"
    ]
      <> ["  unresolved " <> label <> ": " <> reason | (label, reason) <- unresolved]
      <> [ "backups: "
             <> showT (outcome ^. #verified)
             <> " verified, "
             <> showT (outcome ^. #published)
             <> " observed, "
             <> showT (outcome ^. #known)
             <> " already known, "
             <> showT (outcome ^. #deferred)
             <> " deferred, "
             <> showT (outcome ^. #pendingRuns)
             <> " pending"
             <> maybe "" (\at -> " (oldest since " <> stamp at <> ")") (outcome ^. #oldestPending)
         ]
      <> ["  pending run " <> run <> ": " <> reason | (run, reason) <- outcome ^. #failures]
      <> ["feed: " <> showT (materialized ^. #published) <> " events published, " <> showT (materialized ^. #count) <> " in the feed"]
      <> ["  the feed waits at " <> reason | Just reason <- [materialized ^. #blocked]]
  where
    stamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
    showT :: (Show a) => a -> Text
    showT = T.pack . show
