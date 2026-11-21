-- | EP-231 M3: the lifecycle event routes over a seeded feed: paging,
-- conditional reads, lookup by ID, cursor binding, tailing and the
-- not-enabled answer.
module Nagare.Api.Server.Test.Events
  ( eventsTests
  , seedFeed
  , seededKeys
  )
where

import Data.Aeson (FromJSON, ToJSON (toJSON), Value (String), eitherDecode)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Api.Response (Paged (..))
import Nagare.Api.Server.App (AppConfig (..), adminApplication)
import Nagare.Api.Server.Serve (Env (..), newEnv)
import Nagare.Api.Server.Test.Fixture (fixture, fixtureBinding, store)
import Nagare.Contract.Delivery (Delivery, DeliverySubscription)
import Nagare.Contract.Events (LifecycleEvent (..), LifecycleFeedEntry (..))
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (ProblemDetails (..))
import Nagare.Events.Delivery.Store
import Nagare.Events.Envelope (eventIdFor, eventIdText)
import Nagare.Events.Materialize (defaultBudget, enableFeed, materializeOnce)
import Nagare.Events.Source
import Nagare.Events.Store (FeedStore, memoryObjectOps, newFeedStore)
import Nagare.Events.Subscription
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal hiding (Pending)
import Nagare.Inventory.Recorded (defaultRecordedReaderConfig, newRecordedReader)
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps (ObjectOps)
import Nagare.Resource.Types
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (HeaderName, statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import Relay.Pagination (Connection (..), Edge (..), PageInfo (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

eventsTests :: TestTree
eventsTests =
  testGroup
    "events"
    [ testCase "the feed pages oldest first, with stable IDs and its own revision" $ withEvents (Just ["a", "b", "c"]) $ \server -> do
        response <- get server "/v1/events" []
        statusOf response @?= 200
        Paged (Connection edges info) <- decodeBody @(Paged LifecycleFeedEntry) response
        map (\(Edge entry _) -> (entry ^. #position, entry ^. #event . #eventId)) edges @?= zip [0 ..] (map idOf ["a", "b", "c"])
        map (\(Edge entry _) -> entry ^. #event . #eventType) edges @?= replicate 3 "app.deployed"
        hasNextPage info @?= False
        assertBool "no events revision" (isJust (header "Nagare-Events-Revision" response))
        header "Nagare-Head-Revision" response @?= Nothing
    , testCase "an unchanged feed answers 304 to its ETag" $ withEvents (Just ["a"]) $ \server -> do
        fresh <- get server "/v1/events" []
        let tag = fromMaybe "" (header "ETag" fresh)
        again <- get server "/v1/events" [("If-None-Match", tag)]
        statusOf again @?= 304
        header "Nagare-Events-Revision" again @?= header "Nagare-Events-Revision" fresh
    , testCase "first and after walk the feed; a cursor for other filters or a backward page is a problem" $ withEvents (Just ["a", "b", "c"]) $ \server -> do
        first' <- get server "/v1/events?first=1" []
        Paged (Connection [Edge one _] info) <- decodeBody @(Paged LifecycleFeedEntry) first'
        one ^. #position @?= 0
        hasNextPage info @?= True
        let cursor = maybe "" (TE.encodeUtf8 . cursorText) (endCursor info)
        rest <- get server ("/v1/events?after=" <> cursor) []
        Paged (Connection edges _) <- decodeBody @(Paged LifecycleFeedEntry) rest
        map (\(Edge entry _) -> entry ^. #position) edges @?= [1, 2]
        filtered <- get server ("/v1/events?type=database.backup.completed&after=" <> cursor) []
        (statusOf filtered,) <$> problemCode filtered >>= (@?= (400, "invalid_cursor"))
        backward <- get server "/v1/events?last=1" []
        (statusOf backward,) <$> problemCode backward >>= (@?= (400, "invalid_page"))
        unknownType <- get server "/v1/events?type=app.exploded" []
        statusOf unknownType @?= 400
    , testCase "an event reads by ID; an unknown ID is unknown_event" $ withEvents (Just ["a", "b"]) $ \server -> do
        found <- get server ("/v1/events/" <> TE.encodeUtf8 (idOf "b")) []
        statusOf found @?= 200
        entry <- decodeBody @LifecycleFeedEntry found
        (entry ^. #position, entry ^. #event . #eventId) @?= (1, idOf "b")
        missing <- get server ("/v1/events/" <> TE.encodeUtf8 (idOf "zzz")) []
        (statusOf missing,) <$> problemCode missing >>= (@?= (404, "unknown_event"))
    , testCase "delivery routes: not enabled, then the sender's subscriptions, a delivery page and one delivery (EP-234)" $ do
        withEvents (Just ["a"]) $ \server -> do
          response <- get server "/v1/events/subscriptions" []
          (statusOf response,) <$> problemCode response >>= (@?= (404, "delivery_not_enabled"))
        withEventsSeeded (Just ["a"]) seedDelivery $ \server -> do
          listed <- get server "/v1/events/subscriptions" []
          statusOf listed @?= 200
          documents <- decodeBody @[DeliverySubscription] listed
          map (\d -> (d ^. #subscription, d ^. #transport, d ^. #deliveries)) documents @?= [("deploys", "recording", 1)]
          page <- get server "/v1/events/deliveries?subscription=deploys" []
          statusOf page @?= 200
          Paged (Connection edges _) <- decodeBody @(Paged Delivery) page
          map (\(Edge d _) -> (d ^. #eventId, d ^. #state)) edges @?= [(idOf "a", "pending")]
          one <- get server ("/v1/events/deliveries/" <> TE.encodeUtf8 (deliveryIdText seededDelivery)) []
          statusOf one @?= 200
          missing <- get server "/v1/events/deliveries/dl-00000000000000000000000000000000" []
          (statusOf missing,) <$> problemCode missing >>= (@?= (404, "unknown_delivery"))
          other <- get server "/v1/events/deliveries?subscription=nope" []
          (statusOf other,) <$> problemCode other >>= (@?= (404, "unknown_subscription"))
          event <- get server ("/v1/events/" <> TE.encodeUtf8 (idOf "a")) []
          statusOf event @?= 200
    , testCase "a context without a feed answers events_not_enabled, not an empty list" $ withEvents Nothing $ \server -> do
        response <- get server "/v1/events" []
        (statusOf response,) <$> problemCode response >>= (@?= (404, "events_not_enabled"))
    ]

-- * The server

data EventsServer = EventsServer
  { port :: !Int
  , manager :: !HTTP.Manager
  }

-- | An admin API whose feed holds one event per key, or no feed at all.
withEvents :: Maybe [Text] -> (EventsServer -> IO ()) -> IO ()
withEvents keys = withEventsSeeded keys (\_ -> pure ())

-- | As 'withEvents', with more lifecycle state seeded beside the feed.
withEventsSeeded :: Maybe [Text] -> (FeedStore -> IO ()) -> (EventsServer -> IO ()) -> IO ()
withEventsSeeded keys more action = do
  recorded <- fixture 1
  reader <- newRecordedReader defaultRecordedReaderConfig (store recorded) fixtureBinding (readHead (store recorded))
  env <- newEnv reader "test-build" fixtureBinding (pure (Right Nothing))
  feed <- traverse seededFeed keys
  application <- adminApplication (AppConfig "fixture" Nothing 32 (const (pure ()))) env {feed}
  testWithApplication (pure application) $ \portNumber -> do
    httpManager <- HTTP.newManager HTTP.defaultManagerSettings
    action (EventsServer portNumber httpManager)
  where
    seededFeed names = do
      ops <- memoryObjectOps
      store' <- newFeedStore ops
      inventoryOps <- memoryObjectOps
      seedFeed inventoryOps store' names
      more store'
      pure store'

-- | Commit one converged transaction per key into a fresh inventory store
-- over @inventoryOps@, then enable and materialize @feed@ from it.
seedFeed :: ObjectOps -> FeedStore -> [Text] -> IO ()
seedFeed inventoryOps feed names = do
  inventory <- newObjectStore inventoryOps fixtureBinding "client-fixture" Nothing >>= either (fail . show) pure
  initial <- initializeStore inventory fixtureBinding "client-fixture" >>= either (fail . show) pure
  previous <- newIORef (initial, Nothing :: Maybe ContentDigest)
  for_ names $ \name -> do
    (headValue, prior) <- readIORef previous
    let sequenceNumber = headSequence headValue
        transaction = ok (mkTransactionId ("tx-" <> Text.pack (show sequenceNumber)))
        review = contentDigest (TE.encodeUtf8 name)
        facts = SourceFacts factsSchemaVersion transaction review [candidate name] []
    _ <- publishIfAbsent inventory (factsKey (factsDigest facts)) (encodeSourceFacts facts) >>= either (fail . show) pure
    let event = JournalEvent convergenceSchemaVersion sequenceNumber prior transaction Nothing (Completed review) "2026-11-17T00:00:00Z" "fixture" Nothing (Just (Convergence review (Just (factsDigest facts))))
    _ <- appendAtSequence inventory sequenceNumber (encodeJournalEvent event) >>= either (fail . show) pure
    let next = headValue {headGeneration = headGeneration headValue + 1, headSequence = sequenceNumber + 1, headSchemaVersion = 2}
    replaceHeadIfGenerationMatches inventory (Just (headGeneration headValue)) next >>= either (fail . show) pure
    writeIORef previous (next, Just (journalEventDigest event))
  _ <- enableFeed feed fixtureBinding "fixture-epoch" initialCheckpoint >>= either (fail . show) pure
  void (materializeOnce inventory feed fixtureBinding defaultBudget (pure "2026-11-17T00:00:00Z") >>= either (fail . show) pure)
  where
    for_ items step = mapM_ step items

-- | A sender that applies one recording subscription with one pending
-- delivery of event "a".
seedDelivery :: FeedStore -> IO ()
seedDelivery feed = do
  let sid = ok (mkSubscriptionId "deploys")
      record = Subscription 1 sid 1 Active (SubscriptionFilter (Set.fromList [AppDeployed]) Nothing Nothing) 0 (PolicyRef "recording" 1) (DestinationSpec "recording:deploys" "recording" 1 (toJSON ([] :: [Text])))
      at = UTCTime (fromGregorian 2026 11 17) 0
      eventId = eventIdFor (fixtureBinding ^. #identity) (ok (mkSourceKey "a"))
  pointer <- appendLog feed emptyLog [seededDelivery] >>= either (fail . show) pure
  _ <- createJson feed senderKey (SenderHead 1 fixtureBinding 0 initialCheckpoint [sid]) >>= either (fail . show) pure
  _ <- createJson feed (destinationKey sid) (DestinationHead 1 fixtureBinding sid 0 record 1 Nothing Nothing pointer Nothing Nothing) >>= either (fail . show) pure
  void (createJson feed (recordKey sid seededDelivery) (DeliveryRecord 1 seededDelivery sid "recording:deploys" "recording" 1 "recording/1" eventId 0 "initial" Pending [] at (Just at) Nothing) >>= either (fail . show) pure)

seededDelivery :: DeliveryId
seededDelivery = deliveryIdFor (ok (mkSubscriptionId "deploys")) "recording:deploys" (eventIdFor (fixtureBinding ^. #identity) (ok (mkSourceKey "a"))) "initial"

-- | The keys the black-box suite's feed holds.
seededKeys :: [Text]
seededKeys = ["fixture-a", "fixture-b", "fixture-c"]

candidate :: Text -> EventCandidate
candidate name =
  EventCandidate
    { key = ok (mkSourceKey name)
    , resource = ResourceRef (ok (mkScopeId Application "notes")) Nothing Nothing Nothing
    , occurredAt = Just "2026-11-17T00:00:00Z"
    , evidence = [Evidence "review" (contentDigest (TE.encodeUtf8 name))]
    , payload =
        AppDeployedPayload
          AppDeployment
            { subject = ApplicationSubject
            , action = DeployAction
            , release = name
            , previousRelease = Nothing
            , scopeRevision = ScopeRevision (ok (mkScopeGeneration 1)) (contentDigest (TE.encodeUtf8 name))
            , transaction = ok (mkTransactionId "tx-fixture")
            , review = contentDigest (TE.encodeUtf8 name)
            , readiness = contentDigest (TE.encodeUtf8 name)
            }
    }

idOf :: Text -> Text
idOf name = eventIdText (eventIdFor (fixtureBinding ^. #identity) (ok (mkSourceKey name)))

get :: EventsServer -> ByteString -> [(HeaderName, ByteString)] -> IO (HTTP.Response LBS.ByteString)
get server path headers = do
  initial <- HTTP.parseRequest ("http://127.0.0.1:" <> show (port server) <> BC.unpack path)
  HTTP.httpLbs initial {HTTP.requestHeaders = headers} (manager server)

statusOf :: HTTP.Response a -> Int
statusOf = statusCode . HTTP.responseStatus

header :: HeaderName -> HTTP.Response a -> Maybe ByteString
header name = lookup name . HTTP.responseHeaders

decodeBody :: forall a. (FromJSON a) => HTTP.Response LBS.ByteString -> IO a
decodeBody response = either (\failure -> assertFailure failure >> fail "decode") pure (eitherDecode (HTTP.responseBody response))

problemCode :: HTTP.Response LBS.ByteString -> IO Text
problemCode response = (^. #code) <$> decodeBody @ProblemDetails response

cursorText :: (ToJSON c) => c -> Text
cursorText cursor = case toJSON cursor of
  String text -> text
  _ -> ""

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
