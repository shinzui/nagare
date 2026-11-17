-- | EP-235 M1: the lifecycle worker's loops over a memory context — one
-- cycle of each, no inventory write, one loop's failure isolated and
-- reported by readiness and metrics, and a prompt stop.
module Nagare.Api.Server.Test.Worker
  ( workerTests
  )
where

import Control.Concurrent.MVar (newEmptyMVar, readMVar, tryPutMVar)
import Data.Aeson (object, toJSON, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Api.Events.Worker
import Nagare.Api.Server.Test.Fixture (fixtureBinding)
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (..))
import Nagare.Contract.Prelude hiding ((.=))
import Nagare.Events.Delivery (DeliveryEnv (..), defaultDeliveryBudget)
import Nagare.Events.Delivery.Transport
import Nagare.Events.Source
import Nagare.Events.Store (FeedStore, memoryObjectOps, newFeedStore, readFeedHead)
import Nagare.Events.Subscription
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal hiding (Pending)
import Nagare.Inventory.ScheduledStore (VersionedReader (..))
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

workerTests :: TestTree
workerTests =
  testGroup
    "Events.Worker"
    [ testCase "one cycle of each loop publishes, delivers and writes nothing to the inventory" $ do
        world <- newWorld
        commit world [] [revisionOf recordingSub]
        config <- configOf world Nothing
        activate config >>= either (assertFailure . Text.unpack) pure
        commit world [deploy "a"] []
        source <- sourceCycle config >>= either (assertFailure . Text.unpack) pure
        Map.lookup "feed_events" source @?= Just 1
        status <- newWorkerStatus
        receipts <- receiptCycle config status
        receipts @?= Right Map.empty
        delivered <- deliveryCycle config >>= either (assertFailure . Text.unpack) pure
        Map.lookup "acknowledged{subscription=\"rec\"}" delivered @?= Just 1
        published <- readIORef (world ^. #published)
        length published @?= 1
        writes <- readIORef (world ^. #inventoryWrites)
        -- Only the test's own two commits wrote: facts, journal event and head each.
        writes @?= 6
    , testCase "a failing loop is its own: readiness and metrics name it while the others run" $ do
        world <- newWorld
        commit world [deploy "a"] []
        stopping <- newEmptyMVar
        let failingBackups = BackupAccess (MinioBackend (MinioRef "http://minio:9000" "b" "s")) (VersionedReader (\_ -> pure (Left "injected listing failure")) (\_ _ _ -> pure (Left "unused"))) "s3://b/" (\_ -> pure (Left "unused"))
        config <- (\c -> c & #backups ?~ failingBackups & #stopping .~ stopping) <$> configOf world Nothing
        -- Collection was never activated: every receipt cycle fails.
        _ <- activate (config & #backups .~ Nothing)
        status <- newWorkerStatus
        -- One iteration of each loop, then stop.
        counter <- newIORef (0 :: Int)
        -- Each loop runs one cycle, then waits; the third to wait stops them all.
        let config' =
              config & #sleep .~ \_ -> do
                n <- atomicModifyIORef' counter (\c -> (c + 1, c + 1))
                when (n >= 3) (void (tryPutMVar stopping ()))
                readMVar stopping
        stopped <- timeout 10000000 (runWorker config' status)
        assertBool "the worker stops when asked" (isJust stopped)
        verdict <- ready status
        case verdict of
          Left why -> assertBool (Text.unpack why) ("receipts" `Text.isInfixOf` why && not ("source" `Text.isInfixOf` why))
          Right () -> assertFailure "a failing receipt loop must not be ready"
        sourceLoop <- readIORef (status ^. #sourceStatus)
        assertBool "the source loop succeeded" (isJust (sourceLoop ^. #lastSuccess))
        metrics <- TE.decodeUtf8 . LBS.toStrict <$> renderMetrics status
        assertBool (Text.unpack metrics) ("nagare_events_cycle_failing{loop=\"receipts\"} 1" `Text.isInfixOf` metrics && "nagare_events_cycle_failing{loop=\"source\"} 0" `Text.isInfixOf` metrics)
    , testCase "activation enables the feed at the journal's tip: earlier history is not announced" $ do
        world <- newWorld
        commit world [deploy "old"] []
        config <- configOf world Nothing
        activate config >>= either (assertFailure . Text.unpack) pure
        commit world [deploy "new"] []
        _ <- sourceCycle config
        headValue <- readFeedHead (world ^. #feed) fixtureBinding >>= either (assertFailure . show) pure
        headValue ^. #count @?= 1
    ]

-- * The world

data World = World
  { inventory :: !InventoryStore
  , feed :: !FeedStore
  , journal :: !(IORef (HeadManifest, Maybe ContentDigest))
  , inventoryWrites :: !(IORef Int)
  , published :: !(IORef [PublicationRequest])
  }
  deriving stock (Generic)

newWorld :: IO World
newWorld = do
  base <- memoryObjectOps
  writes <- newIORef 0
  let counted = base {putObject = \c n b -> modifyIORef' writes (+ 1) >> putObject base c n b}
  store <- newObjectStore counted fixtureBinding "client-a" Nothing >>= either (fail . show) pure
  initial <- initializeStore store fixtureBinding "client-a" >>= either (fail . show) pure
  writeIORef writes 0
  feedOps <- memoryObjectOps
  feed' <- newFeedStore feedOps
  journal' <- newIORef (initial, Nothing)
  published' <- newIORef []
  pure (World store feed' journal' writes published')

at0 :: UTCTime
at0 = UTCTime (fromGregorian 2026 11 17) 0

configOf :: World -> Maybe BackupAccess -> IO WorkerConfig
configOf world access = do
  stopping' <- newEmptyMVar
  pure $
    WorkerConfig
      { binding = fixtureBinding
      , inventory = world ^. #inventory
      , feed = world ^. #feed
      , backups = access
      , delivery =
          Just
            DeliveryEnv
              { inventory = world ^. #inventory
              , feed = world ^. #feed
              , binding = fixtureBinding
              , registry = adapterRegistry [("recording", AdapterFactory (\_ -> pure (Right (Adapter "recording" policy publish))) (\_ _ -> False))]
              , clock = pure at0
              , random = pure 0
              , token = pure "token"
              , budget = defaultDeliveryBudget
              }
      , intervals = defaultIntervals
      , clock = pure at0
      , sleep = \_ -> pure ()
      , stopping = stopping'
      }
  where
    policy = RetryPolicy (PolicyRef "recording" 1) 3 3600 1 10 0 1
    publish request = do
      modifyIORef' (world ^. #published) (<> [request])
      pure (Acknowledged (Receipt "recording" 1 (object [])))

commit :: World -> [EventCandidate] -> [ControlFact] -> IO ()
commit world candidates controls' = do
  let store = world ^. #inventory
  (headValue, previous) <- readIORef (world ^. #journal)
  let sequenceNumber = headSequence headValue
      transaction = ok (mkTransactionId ("tx-" <> Text.pack (show sequenceNumber)))
      review = contentDigest (TE.encodeUtf8 (Text.pack (show sequenceNumber)))
      facts = SourceFacts factsSchemaVersion transaction review candidates controls'
  _ <- publishIfAbsent store (factsKey (factsDigest facts)) (encodeSourceFacts facts) >>= either (fail . show) pure
  let event = JournalEvent convergenceSchemaVersion sequenceNumber previous transaction Nothing (Completed review) "2026-11-17T00:00:00Z" "test" Nothing (Just (Convergence review (Just (factsDigest facts))))
  _ <- appendAtSequence store sequenceNumber (encodeJournalEvent event) >>= either (fail . show) pure
  let next = headValue {headGeneration = headGeneration headValue + 1, headSequence = sequenceNumber + 1, headSchemaVersion = 2}
  replaceHeadIfGenerationMatches store (Just (headGeneration headValue)) next >>= either (fail . show) pure
  writeIORef (world ^. #journal) (next, Just (journalEventDigest event))

recordingSub :: Subscription
recordingSub = Subscription 1 (ok (mkSubscriptionId "rec")) 1 Active (SubscriptionFilter (Set.fromList [AppDeployed]) Nothing Nothing) 0 (PolicyRef "recording" 1) (DestinationSpec "recording:rec" "recording" 1 (object ["name" .= ("rec" :: Text)]))

revisionOf :: Subscription -> ControlFact
revisionOf record = ControlFact (ok (mkSourceKey ("event-subscription:revision:rec:" <> Text.pack (show (record ^. #revision))))) subscriptionChannel 1 (toJSON (RevisionControl record))

deploy :: Text -> EventCandidate
deploy name =
  EventCandidate
    { key = ok (mkSourceKey name)
    , resource = ResourceRef (ok (mkScopeId Application "web")) Nothing Nothing Nothing
    , occurredAt = Just "2026-11-17T00:00:00Z"
    , evidence = [Evidence name (contentDigest (TE.encodeUtf8 name))]
    , payload = AppDeployedPayload (AppDeployment ApplicationSubject DeployAction name Nothing (ScopeRevision (ok (mkScopeGeneration 1)) (contentDigest (TE.encodeUtf8 name))) (ok (mkTransactionId "tx-test")) (contentDigest "review") (contentDigest "ready"))
    }

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
