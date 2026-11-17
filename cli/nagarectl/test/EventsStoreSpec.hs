-- | EP-231 M2: the lifecycle feed materializes committed sources into a
-- deduplicated, resumable event history with bounded reads, on the memory,
-- filesystem and conditional object-store interpreters alike.
module EventsStoreSpec (eventsStoreTests) where

import Control.Concurrent.Async (concurrently)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryObjectOpsSpec (fakeObjectOps)
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude
import Nagare.Events.Envelope
import Nagare.Events.Materialize
import Nagare.Events.Query
import Nagare.Events.Read
import Nagare.Events.Source
import Nagare.Events.Store
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Counters (Counter (RemoteGet, RemotePut), countOf, snapshotCounters)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

eventsStoreTests :: TestTree
eventsStoreTests =
  testGroup
    "Events"
    [ testGroup
        "Events.Store"
        ( concat
            [ interpreterCases name open
            | (name, open) <- [("memory", withMemory), ("filesystem", withFilesystem), ("object store", withObjectStore)]
            ]
            <> [ testCase "concurrent materializers publish each event once" $ withMemory $ \feed -> do
                   inventory <- inventoryWith [[candidate "a", candidate "b"], [candidate "c"]]
                   _ <- enable feed
                   (left, right) <- concurrently (materialize inventory feed) (materialize inventory feed)
                   assertBool "both cycles finish" (isRight left && isRight right)
                   page <- pageOf feed readRequest
                   map keyOf (page ^. #entries) @?= ["a", "b", "c"]
               , testCase "a source key published by two transactions is one event" $ withMemory $ \feed -> do
                   inventory <- inventoryWith [[candidate "a"], [candidate "a", candidate "b"]]
                   _ <- enable feed
                   outcome <- materialize inventory feed >>= either (assertFailure . show) pure
                   outcome ^. #published @?= 2
                   outcome ^. #repeated @?= 1
                   page <- pageOf feed readRequest
                   map keyOf (page ^. #entries) @?= ["a", "b"]
               , testCase "a source key repeated in a later cycle resolves in the ID index and is not published again" $ withMemory $ \feed -> do
                   (inventory, extend) <- growingInventory [[candidate "a"]]
                   _ <- enable feed
                   _ <- materialize inventory feed >>= either (assertFailure . show) pure
                   extend [candidate "a", candidate "b"]
                   outcome <- materialize inventory feed >>= either (assertFailure . show) pure
                   (outcome ^. #published, outcome ^. #repeated) @?= (1, 1)
                   page <- pageOf feed readRequest
                   map keyOf (page ^. #entries) @?= ["a", "b"]
               , testCase "a lost head acknowledgement is settled as written; nothing repeats" $ do
                   feed <- faultedFeed (\name -> name == "head.json") LandedLost
                   inventory <- inventoryWith [[candidate "a"], [candidate "b"]]
                   _ <- enable feed
                   _ <- materialize inventory feed >>= either (assertFailure . show) pure
                   again <- materialize inventory feed >>= either (assertFailure . show) pure
                   again ^. #wrote @?= False
                   page <- pageOf feed readRequest
                   map keyOf (page ^. #entries) @?= ["a", "b"]
               , testCase "a refused head write is retried; the sources become visible once" $ do
                   feed <- faultedFeed (\name -> name == "head.json") NotLanded
                   inventory <- inventoryWith [[candidate "a"], [candidate "b"]]
                   _ <- enable feed
                   _ <- materialize inventory feed >>= either (assertFailure . show) pure
                   page <- pageOf feed readRequest
                   map keyOf (page ^. #entries) @?= ["a", "b"]
               , testCase "a failed segment upload advances nothing; the next cycle publishes" $ do
                   feed <- faultedFeed ("segments/" `T.isPrefixOf`) NotLanded
                   inventory <- inventoryWith [[candidate "a"]]
                   _ <- enable feed
                   failed <- materialize inventory feed
                   assertBool "the cycle fails" (isLeft failed)
                   headValue <- readFeedHead feed fixtureBinding >>= either (assertFailure . show) pure
                   headValue ^. #count @?= 0
                   headValue ^. #journal @?= initialCheckpoint
                   _ <- materialize inventory feed >>= either (assertFailure . show) pure
                   page <- pageOf feed readRequest
                   map keyOf (page ^. #entries) @?= ["a"]
               , testCase "a transient inventory read error advances nothing; the next cycle publishes" $ withMemory $ \feed -> do
                   (inventory, failNextJournalRead) <- flakyInventory [[candidate "a"], [candidate "b"]]
                   _ <- enable feed
                   failNextJournalRead
                   failed <- materialize inventory feed
                   assertBool "the cycle fails with a source error" (either (\case MaterializeSource _ -> True; _ -> False) (const False) failed)
                   headValue <- readFeedHead feed fixtureBinding >>= either (assertFailure . show) pure
                   (headValue ^. #count, headValue ^. #journal) @?= (0, initialCheckpoint)
                   _ <- materialize inventory feed >>= either (assertFailure . show) pure
                   page <- pageOf feed readRequest
                   map keyOf (page ^. #entries) @?= ["a", "b"]
               , testCase "a budget publishes whole sources and resumes behind them" $ withMemory $ \feed -> do
                   inventory <- inventoryWith [[candidate (T.pack ("k" <> show n))] | n <- [1 .. 10 :: Int]]
                   _ <- enable feed
                   first' <- materializeOnce inventory feed fixtureBinding (defaultBudget & #events .~ 3) clock >>= either (assertFailure . show) pure
                   first' ^. #published @?= 3
                   first' ^. #behind @?= True
                   let loop = do
                         step <- materializeOnce inventory feed fixtureBinding (defaultBudget & #events .~ 3) clock >>= either (assertFailure . show) pure
                         when (step ^. #wrote) loop
                   loop
                   page <- pageOf feed readRequest
                   map keyOf (page ^. #entries) @?= [T.pack ("k" <> show n) | n <- [1 .. 10 :: Int]]
               , testCase "a missing committed segment and a wrong context are typed errors" $ do
                   ops <- memoryObjectOps
                   feed <- newFeedStore ops
                   inventory <- inventoryWith [[candidate "a"]]
                   _ <- enable feed
                   _ <- materialize inventory feed >>= either (assertFailure . show) pure
                   headValue <- readFeedHead feed fixtureBinding >>= either (assertFailure . show) pure
                   other <- readPage feed (ContextBinding (ok (mkContextId "context-2")) (ok (mkName "project"))) readRequest
                   other @?= Left FeedBindingMismatch
                   -- Replace the tail node with one naming a segment that does not exist.
                   broken <- publishFeedObject feed indexKey "{\"number\":0,\"segments\":[\"0000000000000000000000000000000000000000000000000000000000000000\"],\"version\":1}" >>= either (assertFailure . show) pure
                   observed <- observeFeed feed fixtureBinding >>= either (assertFailure . show) pure
                   _ <- replaceFeedHead feed observed (headValue & #generation .~ headValue ^. #generation + 1 & #tail .~ Just broken)
                   lost <- readPage feed fixtureBinding readRequest
                   assertBool "missing segment" (either (\case FeedInvalid _ _ -> True; _ -> False) (const False) lost)
               ]
        )
    , testGroup
        "Events.Read"
        [ testCase "a late page of 10,000 events reads the head, one index node and at most two segments" $ do
            ops <- fakeObjectOps
            feed <- newFeedStore ops
            inventory <- inventoryWith [[candidate (T.pack ("e" <> show s <> "-" <> show n)) | n <- [1 .. 100 :: Int]] | s <- [1 .. 100 :: Int]]
            _ <- enable feed
            _ <- materializeOnce inventory feed fixtureBinding (defaultBudget & #journal .~ 1000 & #events .~ 20000 & #bytes .~ 100000000) clock >>= either (assertFailure . show) pure
            headValue <- readFeedHead feed fixtureBinding >>= either (assertFailure . show) pure
            headValue ^. #count @?= 10000
            -- A reader with a cold cache, as the admin API starts.
            reader <- newFeedStore ops
            page <- pageOf reader (readRequest & #after .~ Just 9939)
            counts <- snapshotCounters (feedStoreCounters reader)
            map (^. #position) (page ^. #entries) @?= [9940 .. 9989]
            -- 9940..9983 and 9984..9989 lie in two segments.
            countOf RemoteGet counts @?= 4
        , testCase "one more source reads the inventory head, its journal event and facts, not the history" $ withObjectStore $ \feed -> do
            (inventory, extend) <- growingInventory [[candidate (T.pack ("e" <> show s <> "-" <> show n)) | n <- [1 .. 50 :: Int]] | s <- [1 .. 40 :: Int]]
            _ <- enable feed
            _ <- materializeOnce inventory feed fixtureBinding (defaultBudget & #journal .~ 1000 & #events .~ 5000 & #bytes .~ 100000000) clock >>= either (assertFailure . show) pure
            extend [candidate "late"]
            inventoryBefore <- snapshotCounters (storeCounters inventory)
            feedBefore <- snapshotCounters (feedStoreCounters feed)
            outcome <- materialize inventory feed >>= either (assertFailure . show) pure
            inventoryAfter <- snapshotCounters (storeCounters inventory)
            feedAfter <- snapshotCounters (feedStoreCounters feed)
            outcome ^. #published @?= 1
            countOf RemoteGet inventoryAfter - countOf RemoteGet inventoryBefore @?= 3
            -- The feed head, the tail node, the partial segment and the ID path.
            assertBool "the feed reads a bounded path" (countOf RemoteGet feedAfter - countOf RemoteGet feedBefore <= 8)
            assertBool "the feed writes a bounded path" (countOf RemotePut feedAfter - countOf RemotePut feedBefore <= 8)
        , testCase "two readers resume from different positions and see identical events" $ withMemory $ \feed -> do
            inventory <- inventoryWith [[candidate (T.pack ("r" <> show n))] | n <- [1 .. 120 :: Int]]
            _ <- enable feed
            _ <- materializeOnce inventory feed fixtureBinding (defaultBudget & #journal .~ 1000) clock >>= either (assertFailure . show) pure
            whole <- collect feed Nothing
            fromMiddle <- collect feed (Just 59)
            map (encodeEnvelope . (^. #envelope)) (drop 60 whole) @?= map (encodeEnvelope . (^. #envelope)) fromMiddle
            length whole @?= 120
            Set.size (Set.fromList (map (^. #envelope . #eventId) whole)) @?= 120
        , testCase "exact type and resource filters neither omit matches nor leak others" $ withMemory $ \feed -> do
            inventory <- inventoryWith [[candidateIn "web" "a", candidateIn "api" "b", candidateIn "web" "c"]]
            _ <- enable feed
            _ <- materialize inventory feed >>= either (assertFailure . show) pure
            web <- pageOf feed (readRequest & #resource .~ Just (ResourceFilter (scopeNamed "web") Nothing))
            map keyOf (web ^. #entries) @?= ["a", "c"]
            deployed <- pageOf feed (readRequest & #kinds .~ Set.singleton AppDeployed)
            length (deployed ^. #entries) @?= 3
            backups <- pageOf feed (readRequest & #kinds .~ Set.singleton DatabaseBackupCompleted)
            backups ^. #entries @?= []
        , testCase "a sparse filter returns a short page and a continuation, never the whole history" $ withMemory $ \feed -> do
            inventory <- inventoryWith [[candidateIn (if n == 300 then "rare" else "common") (T.pack ("s" <> show n)) | n <- [1 .. 300 :: Int]]]
            _ <- enable feed
            _ <- materializeOnce inventory feed fixtureBinding (defaultBudget & #events .~ 1000) clock >>= either (assertFailure . show) pure
            page <- pageOf feed (readRequest & #resource .~ Just (ResourceFilter (scopeNamed "rare") Nothing))
            page ^. #entries @?= []
            page ^. #more @?= True
            page ^. #scannedTo @?= Just 255
            rest <- pageOf feed (readRequest & #after .~ page ^. #scannedTo & #resource .~ Just (ResourceFilter (scopeNamed "rare") Nothing))
            map keyOf (rest ^. #entries) @?= ["s300"]
        , testCase "a pinned bound hides events published after it" $ withMemory $ \feed -> do
            (inventory, extend) <- growingInventory [[candidate "a"], [candidate "b"]]
            _ <- enable feed
            _ <- materialize inventory feed >>= either (assertFailure . show) pure
            extend [candidate "c"]
            _ <- materialize inventory feed >>= either (assertFailure . show) pure
            pinned <- pageOf feed (readRequest & #upper .~ Just 2)
            map keyOf (pinned ^. #entries) @?= ["a", "b"]
            pinned ^. #more @?= False
        , testCase "an event reads by ID, and an unknown ID is absent" $ withMemory $ \feed -> do
            inventory <- inventoryWith [[candidate (T.pack ("i" <> show n)) | n <- [1 .. 200 :: Int]]]
            _ <- enable feed
            _ <- materializeOnce inventory feed fixtureBinding (defaultBudget & #events .~ 1000) clock >>= either (assertFailure . show) pure
            let wanted = eventIdFor (fixtureBinding ^. #identity) (sourceKey "i137")
            (found, _) <- readEvent feed fixtureBinding wanted >>= either (assertFailure . show) pure
            fmap keyOf found @?= Just "i137"
            (missing, _) <- readEvent feed fixtureBinding (eventIdFor (fixtureBinding ^. #identity) (sourceKey "nope")) >>= either (assertFailure . show) pure
            missing @?= Nothing
        , testCase "a cursor finishes its traversal at its pinned bound; refresh reads what arrived since" $ withMemory $ \feed -> do
            (inventory, extend) <- growingInventory [[candidate "a"], [candidate "b"]]
            _ <- enable feed
            _ <- materialize inventory feed >>= either (assertFailure . show) pure
            first' <- queryEvents feed fixtureBinding (eventQuery & #size .~ Just 1) >>= either (assertFailure . show) pure
            map keyOf (first' ^. #entries) @?= ["a"]
            extend [candidate "c"]
            _ <- materialize inventory feed >>= either (assertFailure . show) pure
            pinned <- queryEvents feed fixtureBinding (eventQuery & #after .~ Just (first' ^. #endCursor)) >>= either (assertFailure . show) pure
            map keyOf (pinned ^. #entries) @?= ["b"]
            pinned ^. #hasNext @?= False
            stale <- queryEvents feed fixtureBinding (eventQuery & #after .~ Just (pinned ^. #endCursor)) >>= either (assertFailure . show) pure
            stale ^. #entries @?= []
            fresh <- queryEvents feed fixtureBinding (eventQuery & #after .~ Just (pinned ^. #endCursor) & #refresh .~ True) >>= either (assertFailure . show) pure
            map keyOf (fresh ^. #entries) @?= ["c"]
        , testCase "a cursor of another context, filter set or feed epoch, a malformed cursor and a bad size refuse" $ withMemory $ \feed -> do
            inventory <- inventoryWith [[candidate "a"], [candidate "b"]]
            _ <- enable feed
            _ <- materialize inventory feed >>= either (assertFailure . show) pure
            page <- queryEvents feed fixtureBinding (eventQuery & #size .~ Just 1) >>= either (assertFailure . show) pure
            let cursor = page ^. #endCursor
                refused query =
                  queryEvents feed fixtureBinding query >>= \case
                    Left (InvalidCursor _) -> pure ()
                    other -> assertFailure ("expected an invalid cursor, got " <> show (fmap (^. #entries) other))
            refused (eventQuery & #after .~ Just cursor & #kinds .~ Set.singleton DatabaseBackupCompleted)
            refused (eventQuery & #after .~ Just "not-a-cursor")
            other <- queryEvents feed (ContextBinding (ok (mkContextId "context-2")) (ok (mkName "project"))) (eventQuery & #after .~ Just cursor)
            assertBool "another context" (isLeft other)
            let reEpoched = encodeCursor (either (error . T.unpack) id (decodeCursor cursor) & #epoch .~ "epoch-2")
            refused (eventQuery & #after .~ Just reEpoched)
            for_ [0, 101] $ \size ->
              queryEvents feed fixtureBinding (eventQuery & #size .~ Just size) >>= \case
                Left (InvalidPage _) -> pure ()
                _ -> assertFailure "a page size outside 1 to 100 is refused"
            missing <- memoryObjectOps >>= newFeedStore >>= \empty -> queryEvents empty fixtureBinding eventQuery
            fmap (^. #entries) missing @?= Left (QueryFeed FeedNotEnabled)
        , testCase "an unenabled feed is not an empty history" $ withMemory $ \feed -> do
            page <- readPage feed fixtureBinding readRequest
            fmap (^. #entries) page @?= Left FeedNotEnabled
        ]
    ]

interpreterCases :: String -> ((FeedStore -> Assertion) -> Assertion) -> [TestTree]
interpreterCases name open =
  [ testCase (name <> ": committed sources become events in order, with stable IDs, once") $ open $ \feed -> do
      inventory <- inventoryWith [[candidate "a", candidate "b"], [candidate "c"]]
      _ <- enable feed
      outcome <- materialize inventory feed >>= either (assertFailure . show) pure
      outcome ^. #published @?= 3
      page <- pageOf feed readRequest
      map keyOf (page ^. #entries) @?= ["a", "b", "c"]
      map (^. #position) (page ^. #entries) @?= [0, 1, 2]
      map (^. #envelope . #eventId) (page ^. #entries) @?= [eventIdFor (fixtureBinding ^. #identity) (sourceKey k) | k <- ["a", "b", "c"]]
      again <- materialize inventory feed >>= either (assertFailure . show) pure
      again ^. #wrote @?= False
      page' <- pageOf feed readRequest
      page' ^. #entries @?= page ^. #entries
  , testCase (name <> ": the feed must be enabled, and enabling twice keeps it") $ open $ \feed -> do
      inventory <- inventoryWith [[candidate "a"]]
      unenabled <- materialize inventory feed
      unenabled @?= Left (MaterializeFeed FeedNotEnabled)
      first' <- enable feed
      second' <- enable feed
      second' @?= first'
  ]

-- * Feeds

withMemory :: (FeedStore -> Assertion) -> Assertion
withMemory action = memoryObjectOps >>= newFeedStore >>= action

withFilesystem :: (FeedStore -> Assertion) -> Assertion
withFilesystem action = withSystemTempDirectory "nagare-feed" $ \root -> filesystemObjectOps root >>= newFeedStore >>= action

withObjectStore :: (FeedStore -> Assertion) -> Assertion
withObjectStore action = fakeObjectOps >>= newFeedStore >>= action

data Landing = NotLanded | LandedLost

-- | A feed whose first put matching the name fails once.
faultedFeed :: (Text -> Bool) -> Landing -> IO FeedStore
faultedFeed matches landing = do
  base <- fakeObjectOps
  armed <- newIORef True
  newFeedStore
    base
      { putObject = \condition name@(ObjectName key) bytes -> do
          fire <- readIORef armed
          if fire && matches key
            then do
              writeIORef armed False
              case landing of
                NotLanded -> pure (PutUnknown "injected failure")
                LandedLost -> putObject base condition name bytes >> pure (PutUnknown "injected lost acknowledgement")
            else putObject base condition name bytes
      }

enable :: FeedStore -> IO FeedHead
enable feed = enableFeed feed fixtureBinding "epoch-1" initialCheckpoint >>= either (assertFailure . show) pure

materialize :: InventoryStore -> FeedStore -> IO (Either MaterializeError MaterializeOutcome)
materialize inventory feed = materializeOnce inventory feed fixtureBinding defaultBudget clock

clock :: IO Text
clock = pure "2026-11-17T00:00:00Z"

pageOf :: FeedStore -> ReadRequest -> IO FeedPage
pageOf feed request = readPage feed fixtureBinding request >>= either (assertFailure . show) pure

collect :: FeedStore -> Maybe Integer -> IO [FeedEntry]
collect feed from = do
  page <- pageOf feed (readRequest & #after .~ from)
  if page ^. #more
    then (page ^. #entries <>) <$> collect feed (page ^. #scannedTo)
    else pure (page ^. #entries)

keyOf :: FeedEntry -> Text
keyOf entry = case entry ^. #envelope . #evidence of
  evidence : _ -> evidence ^. #name
  [] -> ""

-- * Inventories of committed sources

-- | An inventory store whose journal commits one converged transaction per
-- list, each with those candidates as its facts.
inventoryWith :: [[EventCandidate]] -> IO InventoryStore
inventoryWith transactions = fst <$> growingInventory transactions

-- | As 'inventoryWith', and an action that makes the next journal read fail.
flakyInventory :: [[EventCandidate]] -> IO (InventoryStore, IO ())
flakyInventory transactions = do
  base <- fakeObjectOps
  armed <- newIORef False
  let ops =
        base
          { getObject = \name@(ObjectName key) -> do
              fire <- readIORef armed
              if fire && "journal/" `T.isPrefixOf` key
                then writeIORef armed False >> pure (GetUnknown "injected read failure")
                else getObject base name
          }
  (store, _) <- growingInventoryOn ops transactions
  pure (store, writeIORef armed True)

-- | As 'inventoryWith', and an action committing one more transaction.
growingInventory :: [[EventCandidate]] -> IO (InventoryStore, [EventCandidate] -> IO ())
growingInventory transactions = fakeObjectOps >>= (`growingInventoryOn` transactions)

growingInventoryOn :: ObjectOps -> [[EventCandidate]] -> IO (InventoryStore, [EventCandidate] -> IO ())
growingInventoryOn ops transactions = do
  store <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
  initial <- initializeStore store fixtureBinding "client-a" >>= either (assertFailure . show) pure
  state <- newIORef (initial, Nothing :: Maybe ContentDigest)
  let commit candidates = do
        (headValue, previous) <- readIORef state
        let sequenceNumber = headSequence headValue
            transaction = ok (mkTransactionId ("tx-" <> T.pack (show sequenceNumber)))
            review = contentDigest (encodeUtf8Text (T.pack (show sequenceNumber)))
            facts = SourceFacts factsSchemaVersion transaction review "2026-11-17T00:00:00Z" candidates []
        _ <- publishIfAbsent store (factsKey (factsDigest facts)) (encodeSourceFacts facts) >>= either (assertFailure . show) pure
        let event = JournalEvent convergenceSchemaVersion sequenceNumber previous transaction Nothing (Completed review) "2026-11-17T00:00:00Z" "test" Nothing (Just (Convergence review (Just (factsDigest facts))))
        _ <- appendAtSequence store sequenceNumber (encodeJournalEvent event) >>= either (assertFailure . show) pure
        let next = headValue {headGeneration = headGeneration headValue + 1, headSequence = sequenceNumber + 1, headSchemaVersion = 2}
        replaceHeadIfGenerationMatches store (Just (headGeneration headValue)) next >>= either (assertFailure . show) pure
        writeIORef state (next, Just (journalEventDigest event))
  mapM_ commit transactions
  pure (store, commit)

candidate :: Text -> EventCandidate
candidate = candidateIn "web"

candidateIn :: Text -> Text -> EventCandidate
candidateIn scopeName name =
  EventCandidate
    { key = sourceKey name
    , resource = ResourceRef (scopeNamed scopeName) Nothing Nothing Nothing
    , occurredAt = "2026-11-17T00:00:00Z"
    , evidence = [Evidence name (contentDigest (encodeUtf8Text name))]
    , payload =
        AppDeployedPayload
          AppDeployment
            { subject = ApplicationSubject
            , action = DeployAction
            , release = name
            , previousRelease = Nothing
            , scopeRevision = ScopeRevision (ok (mkScopeGeneration 1)) (contentDigest (encodeUtf8Text name))
            , transaction = ok (mkTransactionId "tx-test")
            , review = contentDigest "review"
            , readiness = contentDigest "ready"
            }
    }

scopeNamed :: Text -> ScopeId
scopeNamed = ok . mkScopeId Application

sourceKey :: Text -> SourceKey
sourceKey = ok . mkSourceKey

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

for_ :: (Monad m) => [a] -> (a -> m ()) -> m ()
for_ items step = mapM_ step items

isRight :: Either a b -> Bool
isRight = not . isLeft

encodeUtf8Text :: Text -> ByteString
encodeUtf8Text = TE.encodeUtf8
