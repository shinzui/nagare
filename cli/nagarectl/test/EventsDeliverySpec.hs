{-# LANGUAGE OverloadedStrings #-}

-- | EP-234: the shared delivery engine publishes committed lifecycle events
-- to a real HTTP receiver through the webhook adapter and to a test-only,
-- non-HTTP recording adapter, from independent checkpoints, over a
-- faultable store and a virtual clock.
module EventsDeliverySpec (eventsDeliveryTests) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (foldM)
import Data.Aeson (object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Data.Vector qualified as V
import InventoryObjectOpsSpec (fakeObjectOps)
import InventoryTransactionSpec (fixtureBinding, preparedFixtureFrom)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Delivery
import Nagare.Events.Delivery.Store
import Nagare.Events.Delivery.Transport
import Nagare.Events.Envelope (Envelope, encodeEnvelope, eventIdFor, eventIdText)
import Nagare.Events.Materialize (defaultBudget, enableFeed, materializeOnce)
import Nagare.Events.Read
import Nagare.Events.Source
import Nagare.Events.Store
import Nagare.Events.Subscription
import Nagare.Events.Webhook.Policy (HttpResult (..), classify, parseRetryAfter, webhookPolicy)
import Nagare.Events.Webhook.Signature
import Nagare.Events.Webhook.Subscription
import Nagare.Events.Webhook.Transport
import Nagare.Inventory.Adapter (AdapterExecution (AdapterEffectCompleted), RecoveryDecision (RecoverySafeToRetry))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (Converged), applyReviewed)
import Nagare.Inventory.Journal hiding (Failed, Pending)
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Counters (Counter (RemoteGet), countOf, snapshotCounters)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types
import Nagare.Resource.Wire (scopeValue)
import Network.HTTP.Types (hContentType, mkStatus)
import Network.Socket qualified as NS
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

eventsDeliveryTests :: TestTree
eventsDeliveryTests =
  testGroup
    "Events.Delivery"
    [ testCase "one event reaches a real HTTP receiver and a non-HTTP adapter with identical bytes and IDs, under separate deliveries" $ withReceiver $ \receiver -> do
        world <- newWorld receiver
        commit world [deploy "a"] [revisionOf (webhookSub receiver 1), revisionOf (recordingSub 1)]
        outcomes <- cycleOnce world
        map (fmap (^. #acknowledged)) outcomes @?= [Right 1, Right 1]
        received <- readIORef (receiver ^. #received)
        recorded <- readIORef (world ^. #recorded)
        case (received, recorded) of
          ([viaHttp], [viaRecording]) -> do
            viaHttp ^. #body @?= viaRecording ^. #body
            viaHttp ^. #eventId @?= viaRecording ^. #eventId
            assertBool "separate delivery IDs" (viaHttp ^. #deliveryId /= viaRecording ^. #deliveryId)
            viaHttp ^. #verified @?= True
            event <- onlyEvent world
            viaHttp ^. #body @?= encodeEnvelope event
          other -> assertFailure ("expected one delivery to each, got " <> show (length (fst other), length (snd other)))
        heads <- traverse (destinationHead world) [webId, recordingId]
        map (^. #cursor) heads @?= [1, 1]
        records <- deliveriesOf world webId
        map (^. #state) records @?= [Delivered]
        case records of
          [record] -> map (fmap (^. #kind) . (^. #receipt)) (record ^. #attempts) @?= [Just "http"]
          _ -> pure ()
        recordingRecords <- deliveriesOf world recordingId
        map (fmap (^. #kind) . (^. #receipt)) (concatMap (^. #attempts) recordingRecords) @?= [Just "recording"]
    , testCase "a failing destination does not hold back another, and keeps its own cursor and attempts" $ withReceiver $ \receiver -> do
        world <- newWorld receiver
        writeIORef (receiver ^. #status) 503
        commit world [deploy "a", deploy "b"] [revisionOf (webhookSub receiver 1), revisionOf (recordingSub 1)]
        outcomes <- cycleOnce world
        map (fmap (\o -> (o ^. #attempted, o ^. #acknowledged))) outcomes @?= [Right (2, 0), Right (2, 2)]
        records <- deliveriesOf world webId
        map (^. #state) records @?= [Pending, Pending]
        recorded <- readIORef (world ^. #recorded)
        length recorded @?= 2
        -- Only the failing destination retries; the other is done.
        advance world 30
        writeIORef (receiver ^. #status) 200
        again <- cycleOnce world
        map (fmap (^. #acknowledged)) again @?= [Right 2, Right 0]
        after <- deliveriesOf world webId
        map (length . (^. #attempts)) after @?= [2, 2]
    , testCase "a response lost after the receiver processed it is retried with the same IDs, after a restart; the receiver deduplicates" $ withReceiver $ \receiver -> do
        world <- newWorld receiver
        writeIORef (world ^. #loseResponses) True
        commit world [deploy "a"] [revisionOf (webhookSub receiver 1)]
        _ <- cycleOnce world
        first' <- deliveriesOf world webId
        map (^. #state) first' @?= [Pending]
        writeIORef (world ^. #loseResponses) False
        restarted <- restart world
        advance restarted 30
        _ <- cycleOnce restarted
        received <- readIORef (receiver ^. #received)
        length received @?= 2
        case received of
          [one, two] -> do
            (one ^. #eventId, one ^. #deliveryId) @?= (two ^. #eventId, two ^. #deliveryId)
            assertBool "a retry is signed afresh" (one ^. #timestamp /= two ^. #timestamp && one ^. #signature /= two ^. #signature)
            (one ^. #verified, two ^. #verified) @?= (True, True)
          _ -> pure ()
        effects <- readIORef (receiver ^. #effects)
        Set.size effects @?= 1
        final <- deliveriesOf restarted webId
        map (^. #state) final @?= [Delivered]
        map (map (^. #outcome) . (^. #attempts)) final @?= [[Just "unknown", Just "acknowledged"]]
    , testCase "a worker that dies between its intent and its outcome leaves an unknown attempt that a later cycle retries" $ withReceiver $ \receiver -> do
        world <- newWorld receiver
        commit world [deploy "a"] [revisionOf (recordingSub 1)]
        delivery' <- pure (deliveryIdFor recordingId "recording:rec" (eventIdFor (fixtureBinding ^. #identity) (sourceKey "a")) "initial")
        -- Its intent lands, its outcome does not: the worker "dies".
        writeIORef (world ^. #failWrites) (Just ("delivery/destinations/rec/deliveries/" <> deliveryIdText delivery' <> ".json"))
        _ <- cycleOnce world
        stuck <- deliveriesOf world recordingId
        map (isInFlightState . (^. #state)) stuck @?= [True]
        writeIORef (world ^. #failWrites) Nothing
        advance world 300
        _ <- cycleOnce world
        final <- deliveriesOf world recordingId
        map (^. #state) final @?= [Delivered]
        map (map (^. #outcome) . (^. #attempts)) final @?= [[Just "unknown", Just "acknowledged"]]
        recorded <- readIORef (world ^. #recorded)
        map (^. #deliveryId) recorded @?= map (const (deliveryIdText delivery')) recorded
    , testCase "events before a subscription's start and events it filters out are not delivered" $ withReceiver $ \receiver -> do
        world <- newWorld receiver
        commit world [deploy "old"] []
        commit world [deploy "new", backupEvent "b"] [revisionOf ((recordingSub 1) & #startAfter .~ 1)]
        _ <- cycleOnce world
        recorded <- readIORef (world ^. #recorded)
        map (^. #eventId) recorded @?= [eventIdText (eventIdFor (fixtureBinding ^. #identity) (sourceKey "new"))]
        heads <- destinationHead world recordingId
        heads ^. #cursor @?= 3
    , testCase "a reviewed subscription scope converges with no provider member, and its control reaches the sender" $ withReceiver $ \receiver -> withSystemTempDirectory "nagare-subscription" $ \dir -> do
        scope' <- either (assertFailure . T.unpack) pure (subscriptionScope (recordingSub 1) Nothing)
        base <- BS.readFile "test/fixtures/inventory/valid.json"
        fixture <- case Aeson.decodeStrict base of
          Just (Aeson.Object o) | Just (Aeson.Array changes) <- KeyMap.lookup "changes" o -> pure (Aeson.Object (KeyMap.insert "changes" (Aeson.Array (changes <> V.singleton (object ["replace" .= scopeValue scope']))) o))
          _ -> assertFailure "the fixture has no changes"
        let path = dir <> "/subscription.json"
        LBS.writeFile path (Aeson.encode fixture)
        inventoryOps' <- fakeObjectOps
        store <- newObjectStore inventoryOps' fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
        (reviewed, registry') <- preparedFixtureFrom path "operator-cli" id store (\_ _ -> pure AdapterEffectCompleted) (\_ _ -> pure RecoverySafeToRetry) (\_ r -> r)
        applied <- applyReviewed store registry' reviewed >>= either (assertFailure . show) pure
        case applied of
          Converged _ -> pure ()
          other -> assertFailure ("the subscription review did not converge: " <> show other)
        world <- newWorld receiver
        let env = envOf world & #inventory .~ store
        _ <- enableDelivery env >>= either (assertFailure . show) pure
        controlled <- applyControls env >>= either (assertFailure . show) pure
        controlled ^. #applied @?= 1
        headValue <- destinationHead world recordingId
        headValue ^. #record @?= recordingSub 1
        again <- applyControls env >>= either (assertFailure . show) pure
        again ^. #applied @?= 0
    , testCase "automatic attempts stop at the policy's limit; a permanent refusal is never retried" $ withReceiver $ \receiver -> do
        world <- newWorld receiver
        writeIORef (world ^. #script) (replicate 10 (Retryable Nothing "busy"))
        commit world [deploy "a"] [revisionOf (recordingSub 1)]
        for_ [1 .. 7 :: Int] $ \_ -> cycleOnce world >> advance world 60
        exhausted <- deliveriesOf world recordingId
        map (^. #state) exhausted @?= [Exhausted]
        map (length . (^. #attempts)) exhausted @?= [5]
        world' <- newWorld receiver
        writeIORef (world' ^. #script) [Permanent "no such route"]
        commit world' [deploy "a"] [revisionOf (recordingSub 1)]
        for_ [1 .. 3 :: Int] $ \_ -> cycleOnce world' >> advance world' 60
        failed <- deliveriesOf world' recordingId
        map (\r -> (r ^. #state, length (r ^. #attempts), r ^. #reason)) failed @?= [(Failed, 1, Just "no such route")]
    , testCase "the webhook policy classifies HTTP results and backs off from ten seconds to an hour" $ do
        let now = UTCTime (fromGregorian 2026 11 17) 0
            label = outcomeLabel . classify now
        map label [Responded 204 [] "", Responded 503 [] "", Responded 429 [] "", Responded 408 [] "", Responded 404 [] "", Responded 301 [] "", NotConnected "x", Uncertain "y"]
          @?= ["acknowledged", "retryable", "retryable", "retryable", "permanent", "permanent", "retryable", "unknown"]
        case classify now (Responded 503 [("retry-after", "120")] "") of
          Retryable delay _ -> delay @?= Just 120
          other -> assertFailure (show other)
        parseRetryAfter now "Tue, 17 Nov 2026 00:05:00 GMT" @?= Just 300
        map (\n -> retryDelay webhookPolicy n 0 Nothing) [1, 2, 3, 10] @?= [10, 20, 40, 3600]
        retryDelay webhookPolicy 1 0 (Just 900) @?= 900
        retryDelay webhookPolicy 1 1 Nothing @?= 12.5
    , testCase "disabling pauses sends and keeps pending work; reactivating resumes the same delivery" $ withReceiver $ \receiver -> do
        world <- newWorld receiver
        writeIORef (receiver ^. #status) 503
        commit world [deploy "a"] [revisionOf (webhookSub receiver 1)]
        _ <- cycleOnce world
        commit world [] [revisionOf (webhookSub receiver 2 & #status .~ Disabled)]
        writeIORef (receiver ^. #status) 200
        advance world 60
        paused <- cycleOnce world
        map (fmap (\o -> (o ^. #attempted, o ^. #pendingCount))) paused @?= [Right (0, 1)]
        commit world [] [revisionOf (webhookSub receiver 3)]
        resumed <- cycleOnce world
        map (fmap (^. #acknowledged)) resumed @?= [Right 1]
        records <- deliveriesOf world webId
        map (\r -> (r ^. #state, r ^. #revision, length (r ^. #attempts))) records @?= [(Delivered, 1, 2)]
    , testCase "a changed endpoint cancels the old revision's unsent work at a boundary; a key rotation keeps it and signs with both keys" $ withReceiver $ \receiver -> do
        world <- newWorld receiver
        writeIORef (receiver ^. #status) 503
        commit world [deploy "a"] [revisionOf (webhookSub receiver 1)]
        _ <- cycleOnce world
        -- Rotation: a second key, same receiver.
        commit world [] [revisionOf (rotated (webhookSub receiver 2))]
        writeIORef (receiver ^. #status) 200
        advance world 60
        _ <- cycleOnce world
        signatures <- map (^. #signature) <$> readIORef (receiver ^. #received)
        map (length . T.splitOn ",") signatures @?= [1, 2]
        kept <- deliveriesOf world webId
        map (^. #state) kept @?= [Delivered]
        -- Redirect: pending work of the old URL is cancelled, later events use the new one.
        writeIORef (receiver ^. #status) 503
        commit world [deploy "b"] []
        _ <- cycleOnce world
        commit world [deploy "c"] [revisionOf (redirected (webhookSub receiver 3))]
        writeIORef (receiver ^. #status) 200
        advance world 60
        _ <- cycleOnce world
        records <- deliveriesOf world webId
        -- "b" was matched under the rotation's revision 2, then cancelled by revision 3.
        map (\r -> (r ^. #state, r ^. #revision)) records @?= [(Delivered, 1), (Cancelled, 2)]
        headValue <- destinationHead world webId
        (headValue ^. #cancelledThrough, headValue ^. #cursor) @?= (Just 3, 3)
        commit world [deploy "d"] []
        _ <- cycleOnce world
        after <- deliveriesOf world webId
        map (\r -> (r ^. #state, r ^. #revision)) after @?= [(Delivered, 1), (Cancelled, 2), (Delivered, 3)]
    , testCase "a reviewed replay is one new cycle under the same event ID; reapplying it creates no other; a replay of another revision waits for review" $ withReceiver $ \receiver -> do
        world <- newWorld receiver
        writeIORef (world ^. #script) [Permanent "refused"]
        commit world [deploy "a"] [revisionOf (recordingSub 1)]
        _ <- cycleOnce world
        let event = eventIdFor (fixtureBinding ^. #identity) (sourceKey "a")
            replay = Replay recordingId 1 event "replay-1"
        commit world [] [replayOf replay]
        _ <- cycleOnce world
        commit world [] [replayOf replay]
        _ <- cycleOnce world
        records <- deliveriesOf world recordingId
        map (\r -> (r ^. #state, r ^. #deliveryCycle)) records @?= [(Failed, "initial"), (Delivered, "replay-1")]
        recorded <- readIORef (world ^. #recorded)
        map (^. #eventId) recorded @?= replicate 2 (eventIdText event)
        commit world [] [replayOf (Replay recordingId 7 event "replay-2")]
        _ <- cycleOnce world
        headValue <- destinationHead world recordingId
        assertBool "the stale replay is reported" (maybe False ("replay-2" `T.isInfixOf`) (headValue ^. #refusedReplay))
    , testCase "overlapping workers publish a delivery once and record one outcome" $ withReceiver $ \receiver -> do
        world <- newWorld receiver
        commit world [deploy "a"] [revisionOf (recordingSub 1)]
        let env = envOf world
        _ <- enableDelivery env >>= either (assertFailure . show) pure
        _ <- applyControls env >>= either (assertFailure . show) pure
        (left, right) <- concurrently (deliverDestination env recordingId) (deliverDestination env recordingId)
        assertBool "both workers finish" (isRight' left && isRight' right)
        recorded <- readIORef (world ^. #recorded)
        length recorded @?= 1
        records <- deliveriesOf world recordingId
        map (\r -> (r ^. #state, length (r ^. #attempts))) records @?= [(Delivered, 1)]
    , testCase "with ten thousand logged deliveries a page of fifty reads the index and at most two segments, and the head does not grow" $ do
        ops' <- fakeObjectOps
        feed' <- newFeedStore ops'
        let ids n = [deliveryIdFor webId "d" (eventIdFor (fixtureBinding ^. #identity) (sourceKey ("e" <> T.pack (show i)))) "initial" | i <- [n .. n + 999 :: Int]]
        pointer <- foldM (\p n -> appendLog feed' p (ids n) >>= either (assertFailure . show) pure) emptyLog [0, 1000 .. 9000]
        pointer ^. #count @?= 10000
        fresh <- newFeedStore ops'
        page <- readLog fresh pointer 9950 50 >>= either (assertFailure . show) pure
        map fst page @?= [9950 .. 9999]
        reads <- countOf RemoteGet <$> snapshotCounters (feedStoreCounters fresh)
        assertBool ("bounded reads: " <> show reads) (reads <= 3)
        small <- foldM (\p n -> appendLog feed' p (take 10 (ids n)) >>= either (assertFailure . show) pure) emptyLog [0]
        let sizeOf p = BS.length (LBS.toStrict (Aeson.encode (toJSON p)))
        -- Two digests and a count, whatever the history's length.
        assertBool ("the log pointer is constant-size: " <> show (sizeOf pointer, sizeOf small)) (sizeOf pointer <= 200 && sizeOf small <= 200)
    , testCase "the signature input and digest match the published vector" $ do
        let input = signingInput 1700000000 "ev-00000000000000000000000000000001" "dl-00000000000000000000000000000002" "{\"a\":1}"
        input @?= "v1\n1700000000\nev-00000000000000000000000000000001\ndl-00000000000000000000000000000002\n{\"a\":1}"
        key <- either (assertFailure . T.unpack) pure (mkKeyId "k1")
        let signing = [SigningKey key "0123456789abcdef0123456789abcdef"]
            header = signatureHeader signing 1700000000 "ev-00000000000000000000000000000001" "dl-00000000000000000000000000000002" "{\"a\":1}"
        assertBool "one v1 entry" ("v1;kid=k1;sig=" `T.isPrefixOf` header && T.length header == T.length "v1;kid=k1;sig=" + 64)
        verifyRequest signing 1700000100 (SignedHeaders "ev-00000000000000000000000000000001" "dl-00000000000000000000000000000002" 1700000000 header) "{\"a\":1}" @?= Verified key
        verifyRequest signing 1700000400 (SignedHeaders "ev-00000000000000000000000000000001" "dl-00000000000000000000000000000002" 1700000000 header) "{\"a\":1}" @?= Stale
        verifyRequest signing 1700000000 (SignedHeaders "ev-00000000000000000000000000000001" "dl-00000000000000000000000000000002" 1700000000 header) "{\"a\":2}" @?= Forged
    , testCase "a receiver URL refuses user information, fragments, credentials in its query and loopback or metadata hosts" $ do
        let refused = map (parseReceiverUrl []) ["http://hooks.example.test/x", "https://user@hooks.example.test/", "https://hooks.example.test/#a", "https://hooks.example.test/?token=1", "https://127.0.0.1/", "https://localhost/", "https://169.254.169.254/latest", "https://metadata.google.internal/"]
        map isLeftResult refused @?= replicate 8 True
        fmap (^. #host) (parseReceiverUrl [] "https://Hooks.Example.test:8443/events?team=a") @?= Right "hooks.example.test"
        fmap (^. #secure) (parseReceiverUrl ["hooks.svc"] "http://hooks.svc/events") @?= Right False
    , testCase "a connection uses only policy-allowed addresses" $ do
        let v4 t = NS.SockAddrInet 443 (NS.tupleToHostAddress t)
            v6 t = NS.SockAddrInet6 443 0 (NS.tupleToHostAddress6 t) 0
            allowed private' = map (addressAllowed productionAddressPolicy private')
        allowed False [v4 (8, 8, 8, 8), v4 (10, 0, 0, 1), v4 (127, 0, 0, 1), v4 (169, 254, 169, 254), v4 (0, 0, 0, 0)] @?= [True, False, False, False, False]
        allowed True [v4 (10, 0, 0, 1), v4 (192, 168, 1, 1), v4 (169, 254, 169, 254)] @?= [True, True, False]
        allowed True [v6 (0, 0, 0, 0, 0, 0, 0, 1), v6 (0xfe80, 0, 0, 0, 0, 0, 0, 1), v6 (0, 0, 0, 0, 0, 0xffff, 0xa9fe, 0xa9fe), v6 (0x2001, 0xdb8, 0, 0, 0, 0, 0, 1)] @?= [False, False, False, True]
        addressAllowed (AddressPolicy True) False (v4 (127, 0, 0, 1)) @?= True
    ]

-- * The world

data Received = Received
  { eventId :: !Text
  , deliveryId :: !Text
  , timestamp :: !Text
  , signature :: !Text
  , body :: !ByteString
  , verified :: !Bool
  }
  deriving stock (Show, Generic)

data Receiver = Receiver
  { port :: !Int
  , status :: !(IORef Int)
  , received :: !(IORef [Received])
  , effects :: !(IORef (Set.Set Text))
  }
  deriving stock (Generic)

data World = World
  { ops :: !ObjectOps
  , inventoryOps :: !ObjectOps
  , inventory :: !InventoryStore
  , feed :: !FeedStore
  , journal :: !(IORef (HeadManifest, Maybe ContentDigest))
  , now :: !(IORef UTCTime)
  , tokens :: !(IORef Int)
  , recorded :: !(IORef [PublicationRequest])
  , script :: !(IORef [Outcome])
  -- ^ The recording adapter's next outcomes; acknowledged when empty.
  , loseResponses :: !(IORef Bool)
  , failWrites :: !(IORef (Maybe Text))
  -- ^ Puts to this name that would record an acknowledgement do not land.
  , receiver :: !Receiver
  }
  deriving stock (Generic)

signingSecret :: ByteString
signingSecret = "0123456789abcdef0123456789abcdef"

-- | A real HTTP server on a loopback port: it verifies each request with
-- the documented algorithm, records it, and performs one side effect per
-- event ID.
withReceiver :: (Receiver -> IO ()) -> IO ()
withReceiver action = do
  status' <- newIORef 200
  received' <- newIORef []
  effects' <- newIORef Set.empty
  key <- either (assertFailure . T.unpack) pure (mkKeyId "k1")
  let app request respond = do
        body' <- LBS.toStrict <$> Wai.strictRequestBody request
        let header name = maybe "" TE.decodeUtf8 (lookup name (Wai.requestHeaders request))
            stamp = header "nagare-webhook-timestamp"
            headers' = SignedHeaders (header "nagare-event-id") (header "nagare-delivery-id") (read (T.unpack (if T.null stamp then "0" else stamp))) (header "nagare-webhook-signature")
            verdict = verifyRequest [SigningKey key signingSecret] (headers' ^. #timestamp) headers' body'
        modifyIORef' received' (<> [Received (headers' ^. #eventId) (headers' ^. #deliveryId) stamp (headers' ^. #signature) body' (verdict == Verified key)])
        current <- readIORef status'
        when (current == 200 && verdict == Verified key) (modifyIORef' effects' (Set.insert (headers' ^. #eventId)))
        respond (Wai.responseLBS (mkStatus current "test") [(hContentType, "text/plain")] "ok")
  Warp.testWithApplication (pure app) $ \port' -> action (Receiver port' status' received' effects')

newWorld :: Receiver -> IO World
newWorld receiver' = do
  base <- fakeObjectOps
  failWrites' <- newIORef Nothing
  let ops' =
        base
          { putObject = \condition name@(ObjectName key) bytes -> do
              armed <- readIORef failWrites'
              if armed == Just key && "acknowledged" `BS.isInfixOf` bytes
                then pure (PutUnknown "injected failure")
                else putObject base condition name bytes
          , pauseBeforeRetry = \_ -> pure ()
          }
  inventoryOps' <- fakeObjectOps
  store <- newObjectStore inventoryOps' fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
  initial <- initializeStore store fixtureBinding "client-a" >>= either (assertFailure . show) pure
  feed' <- newFeedStore ops'
  _ <- enableFeed feed' fixtureBinding "epoch-1" initialCheckpoint >>= either (assertFailure . show) pure
  journal' <- newIORef (initial, Nothing)
  now' <- newIORef (UTCTime (fromGregorian 2026 11 17) 0)
  tokens' <- newIORef 0
  recorded' <- newIORef []
  script' <- newIORef []
  lose <- newIORef False
  pure (World ops' inventoryOps' store feed' journal' now' tokens' recorded' script' lose failWrites' receiver')

restart :: World -> IO World
restart world = do
  feed' <- newFeedStore (world ^. #ops)
  store <- newObjectStore (world ^. #inventoryOps) fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
  pure (world & #feed .~ feed' & #inventory .~ store)

advance :: World -> Integer -> IO ()
advance world seconds = modifyIORef' (world ^. #now) (addUTCTime (fromIntegral seconds))

-- | Commit one converged transaction with these events and controls, then
-- materialize it into the feed.
commit :: World -> [EventCandidate] -> [ControlFact] -> IO ()
commit world candidates controls' = do
  let store = world ^. #inventory
  (headValue, previous) <- readIORef (world ^. #journal)
  let sequenceNumber = headSequence headValue
      transaction = ok (mkTransactionId ("tx-" <> T.pack (show sequenceNumber)))
      review = contentDigest (TE.encodeUtf8 (T.pack (show sequenceNumber)))
      facts = SourceFacts factsSchemaVersion transaction review candidates controls'
  _ <- publishIfAbsent store (factsKey (factsDigest facts)) (encodeSourceFacts facts) >>= either (assertFailure . show) pure
  let event = JournalEvent convergenceSchemaVersion sequenceNumber previous transaction Nothing (Completed review) "2026-11-17T00:00:00Z" "test" Nothing (Just (Convergence review (Just (factsDigest facts))))
  _ <- appendAtSequence store sequenceNumber (encodeJournalEvent event) >>= either (assertFailure . show) pure
  let next = headValue {headGeneration = headGeneration headValue + 1, headSequence = sequenceNumber + 1, headSchemaVersion = 2}
  replaceHeadIfGenerationMatches store (Just (headGeneration headValue)) next >>= either (assertFailure . show) pure
  writeIORef (world ^. #journal) (next, Just (journalEventDigest event))
  _ <- materializeOnce store (world ^. #feed) fixtureBinding defaultBudget (pure "2026-11-17T00:00:00Z") >>= either (assertFailure . show) pure
  pure ()

envOf :: World -> DeliveryEnv
envOf world =
  DeliveryEnv
    { inventory = world ^. #inventory
    , feed = world ^. #feed
    , binding = fixtureBinding
    , registry =
        adapterRegistry
          [ (webhookTransport, webhookFactory (\_ -> pure (Right signingSecret)) testSend (readIORef (world ^. #now)))
          , ("recording", recordingFactory world)
          ]
    , clock = readIORef (world ^. #now)
    , random = pure 0
    , token = atomicModifyIORef' (world ^. #tokens) (\n -> (n + 1, "token-" <> T.pack (show n)))
    , budget = defaultDeliveryBudget
    }
  where
    -- The real socket path, aimed at the loopback receiver under a policy
    -- that allows loopback; a lost response is a test switch.
    testSend _ = do
      real <- httpSend (AddressPolicy True) True
      pure $ \request -> do
        result <- real (request & #url . #host .~ "127.0.0.1")
        lose <- readIORef (world ^. #loseResponses)
        pure (if lose then Uncertain "the response was lost" else result)

recordingPolicy :: RetryPolicy
recordingPolicy = RetryPolicy (PolicyRef "recording" 1) 5 3600 1 10 0 1

-- | The test-only, non-HTTP adapter: settings and receipts of its own shape.
recordingFactory :: World -> AdapterFactory
recordingFactory world = AdapterFactory bind' (\_ _ -> False)
  where
    bind' spec
      | spec ^. #transport /= "recording" = pure (Left "not a recording destination")
      | otherwise = pure (Right (Adapter "recording" recordingPolicy publish))
    publish request = do
      modifyIORef' (world ^. #recorded) (<> [request])
      scripted <- atomicModifyIORef' (world ^. #script) (\case [] -> ([], Nothing); next : rest -> (rest, Just next))
      pure (fromMaybe (Acknowledged (Receipt "recording" 1 (object ["sequence" .= (request ^. #position)]))) scripted)

cycleOnce :: World -> IO [Either DeliveryError DestinationOutcome]
cycleOnce world = do
  let env = envOf world
  _ <- enableDelivery env >>= either (assertFailure . show) pure
  result <- deliverOnce env >>= either (assertFailure . show) pure
  pure (snd result)

destinationHead :: World -> SubscriptionId -> IO DestinationHead
destinationHead world subscription' = do
  observed <- observeDestination (world ^. #feed) subscription' >>= either (assertFailure . show) pure
  maybe (assertFailure "no destination head") pure (observed ^. #value)

deliveriesOf :: World -> SubscriptionId -> IO [DeliveryRecord]
deliveriesOf world subscription' = do
  headValue <- destinationHead world subscription'
  ids <- readLog (world ^. #feed) (headValue ^. #history) 0 100 >>= either (assertFailure . show) pure
  traverse (\(_, delivery') -> observeRecordAt (world ^. #feed) (recordKeyOf subscription' delivery') >>= either (assertFailure . show) pure >>= maybe (assertFailure "missing record") pure . (^. #value)) ids
  where
    recordKeyOf = recordKey

onlyEvent :: World -> IO Envelope
onlyEvent world = do
  page <- readPage (world ^. #feed) fixtureBinding readRequest >>= either (assertFailure . show) pure
  case page ^. #entries of
    [entry] -> pure (entry ^. #envelope)
    _ -> assertFailure "expected one event"

isInFlightState :: DeliveryState -> Bool
isInFlightState = \case
  InFlight _ -> True
  _ -> False

isLeftResult :: Either a b -> Bool
isLeftResult = either (const True) (const False)

-- * Subscriptions and events

webId, recordingId :: SubscriptionId
webId = ok (mkSubscriptionId "web")
recordingId = ok (mkSubscriptionId "rec")

webhookSub :: Receiver -> Int -> Subscription
webhookSub receiver' revision' =
  Subscription 1 webId revision' Active (SubscriptionFilter (Set.fromList [AppDeployed]) Nothing Nothing) 0 (PolicyRef "webhook" 1) $
    ok (webhookDestination webId (WebhookSettings ("http://receiver.test:" <> T.pack (show (receiver' ^. #port)) <> "/events") ["receiver.test"] [SecretKeyRef "k1" "events" "hook" "key"]))

recordingSub :: Int -> Subscription
recordingSub revision' = Subscription 1 recordingId revision' Active (SubscriptionFilter (Set.fromList [AppDeployed]) Nothing Nothing) 0 (PolicyRef "recording" 1) (DestinationSpec "recording:rec" "recording" 1 (object ["name" .= ("rec" :: Text)]))

replayOf :: Replay -> ControlFact
replayOf replay = ControlFact (sourceKey ("event-subscription:replay:" <> subscriptionIdText (replay ^. #subscription) <> ":" <> replay ^. #cycleId)) subscriptionChannel 1 (toJSON (ReplayControl replay))

-- | The same receiver, signed with a second key during a rotation.
rotated :: Subscription -> Subscription
rotated record = record & #destination . #settings .~ toJSON (settingsOf record & #signing %~ (<> [SecretKeyRef "k2" "events" "hook-next" "key"]))

-- | Another receiver path: a new endpoint.
redirected :: Subscription -> Subscription
redirected record = record & #destination . #settings .~ toJSON (settingsOf record & #url %~ (<> "/v2"))

settingsOf :: Subscription -> WebhookSettings
settingsOf record = either (error . T.unpack) id (decodeWebhookSettings (record ^. #destination))

isRight' :: Either a b -> Bool
isRight' = either (const False) (const True)

revisionOf :: Subscription -> ControlFact
revisionOf record = ControlFact (sourceKey ("event-subscription:revision:" <> subscriptionIdText (record ^. #subscription) <> ":" <> T.pack (show (record ^. #revision)))) subscriptionChannel 1 (toJSON (RevisionControl record))

deploy :: Text -> EventCandidate
deploy name =
  EventCandidate
    { key = sourceKey name
    , resource = ResourceRef (ok (mkScopeId Application "web")) Nothing Nothing Nothing
    , occurredAt = Just "2026-11-17T00:00:00Z"
    , evidence = [Evidence name (contentDigest (TE.encodeUtf8 name))]
    , payload = AppDeployedPayload (AppDeployment ApplicationSubject DeployAction name Nothing (ScopeRevision (ok (mkScopeGeneration 1)) (contentDigest (TE.encodeUtf8 name))) (ok (mkTransactionId "tx-test")) (contentDigest "review") (contentDigest "ready"))
    }

backupEvent :: Text -> EventCandidate
backupEvent name =
  (deploy name)
    { payload = BackupCompletedPayload (BackupCompletion name ScheduledBackup name (StoredVersion "s3://b/a" "1") (StoredVersion "s3://b/a.receipt.json" "2") (T.replicate 64 "a") 1 Nothing Nothing Nothing)
    }

sourceKey :: Text -> SourceKey
sourceKey = ok . mkSourceKey

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
