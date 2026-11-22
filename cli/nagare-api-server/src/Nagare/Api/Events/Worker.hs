{-# LANGUAGE OverloadedStrings #-}

-- | The lifecycle event worker (EP-235): three independent bounded loops —
-- source materialization, backup receipt collection and transport-neutral
-- delivery — over the facades EP-231, EP-233 and EP-234 own. The worker
-- holds no inventory claim: its inventory store is read-only, and it writes
-- only the lifecycle prefix. Each loop records its last iteration, which
-- the probes and metrics report; a probe never touches a store. One loop's
-- failure is its own: it is reported and retried on the loop's next cycle,
-- and the others keep running.
module Nagare.Api.Events.Worker
  ( WorkerConfig (..)
  , Intervals (..)
  , defaultIntervals
  , BackupAccess (..)
  , LoopStatus (..)
  , WorkerStatus (..)
  , newWorkerStatus
  , activate
  , sourceCycle
  , receiptCycle
  , deliveryCycle
  , runWorker
  , ready
  , renderMetrics
  )
where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Concurrent.MVar (MVar, isEmptyMVar)
import Control.Exception (SomeException, try)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, diffUTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.Contract.Prelude
import Nagare.Events.Backup (BackupSchedule, SigningRef)
import Nagare.Events.BackupCollector
import Nagare.Events.BackupSources (loadBackupSchedules)
import Nagare.Events.Delivery
import Nagare.Events.Delivery.Transport (AdapterRegistry)
import Nagare.Events.Materialize (defaultBudget, enableFeed, materializeOnce)
import Nagare.Events.Source (tipCheckpoint)
import Nagare.Events.Store (FeedError (FeedNotEnabled), FeedStore, readFeedHead)
import Nagare.Events.Subscription (subscriptionIdText)
import Nagare.Inventory.ScheduledStore (VersionedReader)
import Nagare.Inventory.Store (HeadManifest (headSequence), InventoryStore, readHead)
import Nagare.Resource.Types (ContextBinding, PhysicalIdentity)

-- | How the worker reads the backup bucket.
data BackupAccess = BackupAccess
  { backend :: !StoreBackend
  , objects :: !VersionedReader
  , bucketAddress :: !Text
  , signingKey :: !(SigningRef -> IO (Either Text (Text, PhysicalIdentity)))
  }
  deriving stock (Generic)

-- | Seconds between cycles: 30 for sources, five minutes for receipts.
data Intervals = Intervals
  { source :: !Int
  , receipts :: !Int
  , delivery :: !Int
  }
  deriving stock (Eq, Show, Generic)

defaultIntervals :: Intervals
defaultIntervals = Intervals 30 300 10

data WorkerConfig = WorkerConfig
  { binding :: !ContextBinding
  , inventory :: !InventoryStore
  , feed :: !FeedStore
  , backups :: !(Maybe BackupAccess)
  , delivery :: !(Maybe DeliveryEnv)
  -- ^ 'Nothing' sends nothing: a candidate or rehearsal context.
  , intervals :: !Intervals
  , clock :: !(IO UTCTime)
  , sleep :: !(Int -> IO ())
  , stopping :: !(MVar ())
  -- ^ Full when the process is asked to stop: no new cycle starts.
  }
  deriving stock (Generic)

-- | One loop's last iteration.
data LoopStatus = LoopStatus
  { cycles :: !Integer
  , lastRun :: !(Maybe UTCTime)
  , lastSuccess :: !(Maybe UTCTime)
  , lastError :: !(Maybe Text)
  , gauges :: !(Map Text Integer)
  }
  deriving stock (Eq, Show, Generic)

data WorkerStatus = WorkerStatus
  { sourceStatus :: !(IORef LoopStatus)
  , receiptStatus :: !(IORef LoopStatus)
  , deliveryStatus :: !(IORef LoopStatus)
  , schedules :: !(IORef (Maybe (Integer, [BackupSchedule])))
  -- ^ The schedules resolved at an inventory head sequence.
  }
  deriving stock (Generic)

newWorkerStatus :: IO WorkerStatus
newWorkerStatus = WorkerStatus <$> fresh <*> fresh <*> fresh <*> newIORef Nothing
  where
    fresh = newIORef (LoopStatus 0 Nothing Nothing Nothing Map.empty)

-- | Enable the feed at the journal's tip, collection with the backups
-- present now as its baseline, and delivery from the journal's start (so
-- no converged subscription is missed). Each is unchanged if enabled.
activate :: WorkerConfig -> IO (Either Text ())
activate config = do
  existing <- readFeedHead (config ^. #feed) (config ^. #binding)
  feedReady <- case existing of
    Right _ -> pure (Right ())
    Left FeedNotEnabled -> do
      tip <- tipCheckpoint (config ^. #inventory)
      case tip of
        Left err -> pure (Left ("the journal tip cannot be read: " <> showText err))
        Right checkpoint' -> do
          now <- config ^. #clock
          first showText . void <$> enableFeed (config ^. #feed) (config ^. #binding) (Text.pack (show (floor (utcTimeToPOSIXSeconds now) :: Integer))) checkpoint'
    Left err -> pure (Left (showText err))
  collection <- case config ^. #backups of
    Nothing -> pure (Right ())
    Just access -> do
      loaded <- currentSchedules config access Nothing
      case loaded of
        Left err -> pure (Left err)
        Right (_, schedules') -> first showText . void <$> activateCollection (config ^. #feed) (config ^. #binding) (collectorOps config access) schedules'
  sending <- maybe (pure (Right ())) (fmap (first showText . void) . enableDelivery) (config ^. #delivery)
  pure (feedReady >> collection >> sending)

collectorOps :: WorkerConfig -> BackupAccess -> CollectorOps
collectorOps config access = CollectorOps (access ^. #objects) (access ^. #bucketAddress) (access ^. #signingKey) (config ^. #clock)

-- | The schedules at the inventory's current head, resolved again only when
-- the head moved.
currentSchedules :: WorkerConfig -> BackupAccess -> Maybe WorkerStatus -> IO (Either Text (Integer, [BackupSchedule]))
currentSchedules config access status = do
  loadedHead <- readHead (config ^. #inventory)
  case loadedHead of
    Left err -> pure (Left (showText err))
    Right Nothing -> pure (Left "accepted inventory history is absent")
    Right (Just headValue) -> do
      cached <- maybe (pure Nothing) (readIORef . (^. #schedules)) status
      case cached of
        Just (sequence', schedules') | sequence' == headSequence headValue -> pure (Right (sequence', schedules'))
        _ -> do
          resolved <- loadBackupSchedules (config ^. #inventory) (access ^. #backend)
          case resolved of
            Left err -> pure (Left err)
            Right (schedules', _) -> do
              traverse_ (\s -> writeIORef (s ^. #schedules) (Just (headSequence headValue, schedules'))) status
              pure (Right (headSequence headValue, schedules'))

-- | One materialization cycle.
sourceCycle :: WorkerConfig -> IO (Either Text (Map Text Integer))
sourceCycle config = do
  outcome <- materializeOnce (config ^. #inventory) (config ^. #feed) (config ^. #binding) defaultBudget (stamp <$> config ^. #clock)
  pure $ case outcome of
    Left err -> Left (showText err)
    -- EP-276: the events before the stop are published; the stop waits.
    Right o | Just reason <- o ^. #blocked -> Left ("the feed waits at " <> reason)
    Right o -> Right (Map.fromList [("published", toInteger (o ^. #published)), ("feed_events", o ^. #count), ("behind", if o ^. #behind then 1 else 0)])

-- | One receipt collection cycle, if the worker reads backups.
receiptCycle :: WorkerConfig -> WorkerStatus -> IO (Either Text (Map Text Integer))
receiptCycle config status = case config ^. #backups of
  Nothing -> pure (Right Map.empty)
  Just access -> do
    loaded <- currentSchedules config access (Just status)
    case loaded of
      Left err -> pure (Left err)
      Right (_, schedules') -> do
        outcome <- collectOnce (config ^. #feed) (config ^. #binding) (collectorOps config access) defaultCollectBudget schedules'
        now <- config ^. #clock
        pure $ case outcome of
          Left err -> Left (showText err)
          Right o ->
            Right
              ( Map.fromList
                  [ ("schedules", toInteger (length schedules'))
                  , ("verified", toInteger (o ^. #verified))
                  , ("observed", toInteger (o ^. #published))
                  , ("deferred", toInteger (o ^. #deferred))
                  , ("pending", toInteger (o ^. #pendingRuns))
                  , ("oldest_pending_seconds", maybe 0 (\at -> floor (diffUTCTime now at)) (o ^. #oldestPending))
                  ]
              )

-- | One delivery cycle, if the worker sends.
deliveryCycle :: WorkerConfig -> IO (Either Text (Map Text Integer))
deliveryCycle config = case config ^. #delivery of
  Nothing -> pure (Right Map.empty)
  Just env -> do
    outcome <- deliverOnce env
    pure $ case outcome of
      Left err -> Left (showText err)
      Right (_, destinations) ->
        Right
          ( Map.fromList
              ( [("destinations", toInteger (length destinations)), ("destination_errors", toInteger (length [() | Left _ <- destinations]))]
                  <> concat
                    [ [ ("pending{subscription=\"" <> subscriptionText d <> "\"}", toInteger (d ^. #pendingCount))
                      , ("attempted{subscription=\"" <> subscriptionText d <> "\"}", toInteger (d ^. #attempted))
                      , ("acknowledged{subscription=\"" <> subscriptionText d <> "\"}", toInteger (d ^. #acknowledged))
                      , ("paused{subscription=\"" <> subscriptionText d <> "\"}", if isJust (d ^. #diagnostic) then 1 else 0)
                      ]
                    | Right d <- destinations
                    ]
              )
          )
  where
    subscriptionText d = subscriptionIdText (d ^. #subscription)

-- | Run the three loops until the process is asked to stop; the cycle in
-- progress finishes, so no attempt is left between its intent and its
-- outcome by the shutdown itself.
runWorker :: WorkerConfig -> WorkerStatus -> IO ()
runWorker config status =
  mapConcurrently_
    id
    [ loop (config ^. #intervals . #source) (status ^. #sourceStatus) (sourceCycle config)
    , loop (config ^. #intervals . #receipts) (status ^. #receiptStatus) (receiptCycle config status)
    , loop (config ^. #intervals . #delivery) (status ^. #deliveryStatus) (deliveryCycle config)
    ]
  where
    loop seconds ref step = do
      running <- isEmptyMVar (config ^. #stopping)
      when running $ do
        started <- config ^. #clock
        result <- try step
        done <- config ^. #clock
        modifyIORef' ref $ \s -> case result of
          Right (Right gauges') -> s & #cycles %~ (+ 1) & #lastRun ?~ started & #lastSuccess ?~ done & #lastError .~ Nothing & #gauges .~ gauges'
          Right (Left err) -> s & #cycles %~ (+ 1) & #lastRun ?~ started & #lastError ?~ err
          Left (e :: SomeException) -> s & #cycles %~ (+ 1) & #lastRun ?~ started & #lastError ?~ ("the cycle failed: " <> Text.pack (takeWhile (/= '\n') (show e)))
        (config ^. #sleep) seconds
        loop seconds ref step

-- | Ready when every loop's last cycle succeeded. A receiver's failure is a
-- delivery outcome, never a readiness failure: it would only restart the
-- worker.
ready :: WorkerStatus -> IO (Either Text ())
ready status = do
  loops <- traverse readIORef [status ^. #sourceStatus, status ^. #receiptStatus, status ^. #deliveryStatus]
  pure $ case [(name, err) | (name, s) <- zip ["source", "receipts", "delivery"] loops, Just err <- [s ^. #lastError]] of
    [] -> Right ()
    failures -> Left (Text.intercalate "; " [name <> ": " <> err | (name, err) <- failures])

-- | The worker's metrics in Prometheus text format.
renderMetrics :: WorkerStatus -> IO LBS.ByteString
renderMetrics status = do
  loops <- traverse (\(name, ref) -> (,) name <$> readIORef ref) [("source", status ^. #sourceStatus), ("receipts", status ^. #receiptStatus), ("delivery", status ^. #deliveryStatus)]
  pure . LBS.fromStrict . TE.encodeUtf8 . Text.unlines . concat $
    [ [ "nagare_events_cycles_total{loop=\"" <> name <> "\"} " <> showText (s ^. #cycles)
      , "nagare_events_cycle_failing{loop=\"" <> name <> "\"} " <> (if isJust (s ^. #lastError) then "1" else "0")
      , "nagare_events_last_success_seconds{loop=\"" <> name <> "\"} " <> maybe "0" (showText . (floor :: Double -> Integer) . realToFrac . utcTimeToPOSIXSeconds) (s ^. #lastSuccess)
      ]
        <> [ "nagare_events_" <> name <> "_" <> labelled gauge <> " " <> showText value
           | (gauge, value) <- Map.toAscList (s ^. #gauges)
           ]
    | (name, s) <- loops
    ]
  where
    labelled gauge = gauge

stamp :: UTCTime -> Text
stamp = Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

showText :: (Show a) => a -> Text
showText = Text.pack . show
