-- | EP-231 M1: a converged inventory transaction commits its lifecycle
-- source facts in the head replacement that releases it, and consumers read
-- exactly the committed ones back.
module EventsSourceSpec (eventsSourceTests) where

import Data.Aeson (Value (Null, Object), toJSON)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryObjectOpsSpec (fakeObjectOps)
import InventoryTransactionSpec (fixtureBinding, preparedFixtureWith)
import Nagare.Dsl.Prelude
import Nagare.Events.Source
import Nagare.Inventory.Actor (anonymousOperator)
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Counters (Counter (RemoteGet, RemotePut), countOf, snapshotCounters)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty
import Test.Tasty.HUnit

eventsSourceTests :: TestTree
eventsSourceTests =
  testGroup
    "Events.Source"
    [ testGroup
        "executor"
        [ testCase "a converged transaction with facts commits one source and a version 2 head" $ do
            run <- runFixture [] (Just testProducer)
            assertConverged (outcome run)
            headValue <- readHeadOf run
            headSchemaVersion headValue @?= 2
            events <- journalOf run
            let conv = [event | event <- events, isJust (eventConvergence event)]
            length conv @?= 1
            map eventSequence conv @?= [headSequence headValue - 1]
            batch <- readAll run
            map (^. #transaction) (batch ^. #sources) @?= [transactionOf run]
            [candidate ^. #key | source <- batch ^. #sources, candidate <- source ^. #facts . #events] @?= [changeAppliedKey (transactionOf run), candidateKey (transactionOf run)]
            batch ^. #checkpoint . #next @?= headSequence headValue
            batch ^. #waiting @?= False
        , testCase "every converged transaction commits one source; it costs a fact-less change two writes and a deploy none (EP-276)" $ do
            without <- runFixture [] Nothing
            with <- runFixture [] (Just testProducer)
            assertConverged (outcome without)
            headValue <- readHeadOf without
            headSchemaVersion headValue @?= 2
            events <- journalOf without
            length [event | event <- events, isJust (eventConvergence event)] @?= 1
            batch <- readAll without
            map (^. #transaction) (batch ^. #sources) @?= [transactionOf without]
            [candidate ^. #key | source <- batch ^. #sources, candidate <- source ^. #facts . #events] @?= [changeAppliedKey (transactionOf without)]
            -- Before EP-276 the fixture transaction wrote 10 objects without
            -- facts and 12 with them, 6 of them heads. change.applied adds
            -- the facts object and its convergence event to the first and
            -- joins the second's facts object, with no further head write.
            (puts without, puts with) @?= (12, 12)
            (headPuts without, headPuts with) @?= (6, 6)
        , testCase "a lost facts upload stops the release; resume commits exactly one source" $ do
            run <- runFixture [FailOnce (keyPrefixed "facts/") NotLanded] (Just testProducer)
            assertNotConverged (outcome run)
            (readAll run >>= \batch -> batch ^. #sources @?= [])
            resumed <- resumeFixture run
            assertConverged resumed
            assertOneSource run
        , testCase "a refused convergence journal write stops the release; resume commits exactly one source" $ do
            run <- runFixture [FailOnce convergenceEvent NotLanded] (Just testProducer)
            assertNotConverged (outcome run)
            (readAll run >>= \batch -> batch ^. #sources @?= [])
            resumed <- resumeFixture run
            assertConverged resumed
            assertOneSource run
        , testCase "a refused release head write is retried and commits one source" $ do
            run <- runFixture [FailAfterConvergence 1 NotLanded] (Just testProducer)
            assertConverged (outcome run)
            assertOneSource run
        , testCase "a release head write whose acknowledgement was lost is read back as committed" $ do
            run <- runFixture [FailAfterConvergence 1 LandedLost] (Just testProducer)
            assertConverged (outcome run)
            assertOneSource run
        , testCase "a persistent release failure leaves an orphan no reader sees; resume adopts it and commits one source" $ do
            run <- runFixture [FailAfterConvergence 4 NotLanded] (Just testProducer)
            assertNotConverged (outcome run)
            headValue <- readHeadOf run
            orphan <- readObject (inspect run) (journalKey (headSequence headValue))
            assertBool "the convergence event was published but not committed" (isRightJust orphan)
            (readAll run >>= \batch -> batch ^. #sources @?= [])
            resumed <- resumeFixture run
            assertConverged resumed
            events <- journalOf run
            -- The adopted orphan is ordinary history followed by its own
            -- transaction; only the release that committed is a source.
            length [event | event <- events, isJust (eventConvergence event)] @?= 2
            assertOneSource run
        ]
    , testGroup
        "wire"
        [ testCase "the head reads at wire versions 1 and 2 and refuses 3" $ do
            ops <- fakeObjectOps
            store <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
            initial <- initializeStore store fixtureBinding "client-a" >>= either (assertFailure . show) pure
            let encoded version = either (error . T.unpack) id (canonicalValue (toJSON initial {headSchemaVersion = version}))
            fmap headSchemaVersion (decodeHead (encoded 1)) @?= Right 1
            fmap headSchemaVersion (decodeHead (encoded 2)) @?= Right 2
            assertBool "version 3 is refused" (isLeft (decodeHead (encoded 3)))
        , testCase "a convergence event has version 2, completes its review, and no other event has version 2" $ do
            let review = contentDigest "review"
                base = JournalEvent 1 0 Nothing tx1 Nothing (Completed review) "2026-11-17T00:00:00Z" "transaction converged" Nothing Nothing
                conv = base {eventSchemaVersion = 2, eventConvergence = Just (Convergence review Nothing)}
                roundTrip event = decodeJournalEvent (encodeJournalEvent event)
            roundTrip base @?= Right base
            roundTrip conv @?= Right conv
            assertBool "a version 1 convergence event" (isLeft (roundTrip conv {eventSchemaVersion = 1}))
            assertBool "a version 2 event without convergence" (isLeft (roundTrip base {eventSchemaVersion = 2}))
            assertBool "a convergence of another review" (isLeft (roundTrip conv {eventState = Completed (contentDigest "other")}))
            assertBool "an operation's convergence" (isLeft (roundTrip conv {eventOperation = Just (either (error . T.unpack) id (mkOperationId "op-one"))}))
        , testCase "facts round-trip canonically and refuse unknown fields" $ do
            let facts = SourceFacts factsSchemaVersion tx1 (contentDigest "review") [] [control "rev-1" 1]
                bytes = encodeSourceFacts facts
            decodeSourceFacts bytes @?= Right facts
            assertBool "an unknown field is refused" (isLeft (decodeSourceFacts (either (error . T.unpack) id (canonicalValue (addField (toJSON facts))))))
        , testCase "producers' items assemble once per key and refuse a key naming two facts" $ do
            let input = SourceInput (fixtureBinding ^. #identity) tx1 (contentDigest "review") "operator-cli" Map.empty Map.empty Map.empty Map.empty [] anonymousOperator Nothing Map.empty Map.empty [] Map.empty Map.empty
                producing items = sourceProducer (const items)
            assembleFacts input [] @?= Right Nothing
            fmap (fmap (^. #controls)) (assembleFacts input [producing [Control (control "a" 1)], producing [Control (control "a" 1)]]) @?= Right (Just [control "a" 1])
            assertBool "a key naming two facts" (isLeft (assembleFacts input [producing [Control (control "a" 1), Control (control "a" 2)]]))
        , testCase "source keys are bounded lowercase tokens" $ do
            fmap sourceKeyText (mkSourceKey "app:tx-1/web") @?= Right "app:tx-1/web"
            assertBool "empty" (isLeft (mkSourceKey ""))
            assertBool "uppercase" (isLeft (mkSourceKey "App"))
            assertBool "leading digit" (isLeft (mkSourceKey "1app"))
            assertBool "too long" (isLeft (mkSourceKey (T.replicate 257 "a")))
        ]
    , testGroup
        "chain"
        [ testCase "the last convergence is a source once its transaction is inactive" $ do
            chain <- buildChain [Conv tx1 (Just [])] Nothing
            batch <- readFrom chain initialCheckpoint 10
            map (^. #transaction) (batch ^. #sources) @?= [tx1]
        , testCase "the last convergence of a still-active transaction waits at its sequence" $ do
            chain <- buildChain [Plain tx1, Conv tx1 (Just [])] (Just tx1)
            batch <- readFrom chain initialCheckpoint 10
            batch ^. #sources @?= []
            batch ^. #waiting @?= True
            batch ^. #checkpoint . #next @?= 1
        , testCase "a convergence followed by its own transaction's event is not a source" $ do
            chain <- buildChain [Conv tx1 (Just []), Plain tx1, Conv tx1 (Just []), Plain tx2] Nothing
            batch <- readFrom chain initialCheckpoint 10
            map (^. #journalSequence) (batch ^. #sources) @?= [2]
        , testCase "a convergence without facts is passed over" $ do
            chain <- buildChain [Conv tx1 Nothing, Plain tx2] Nothing
            batch <- readFrom chain initialCheckpoint 10
            batch ^. #sources @?= []
            batch ^. #checkpoint . #next @?= 2
        , testCase "a convergence at the end of a batch is decided by one event beyond it" $ do
            chain <- buildChain [Plain tx1, Conv tx1 (Just []), Plain tx1, Conv tx1 (Just []), Plain tx2] Nothing
            first2 <- readFrom chain initialCheckpoint 2
            map (^. #journalSequence) (first2 ^. #sources) @?= []
            first2 ^. #checkpoint . #next @?= 2
            rest <- readFrom chain (first2 ^. #checkpoint) 2
            map (^. #journalSequence) (rest ^. #sources) @?= [3]
            rest ^. #checkpoint . #next @?= 4
        , testCase "a newer transaction does not hide an earlier committed source" $ do
            chain <- buildChain [Conv tx1 (Just []), Plain tx2, Plain tx2, Conv tx2 (Just [])] Nothing
            batch <- readFrom chain initialCheckpoint 10
            map (^. #transaction) (batch ^. #sources) @?= [tx1, tx2]
        , testCase "a broken link at the checkpoint, a missing facts object and a checkpoint ahead are typed errors" $ do
            chain <- buildChain [Plain tx1, Conv tx1 (Just [])] Nothing
            linked <- readSourceChain (chainStore chain) (SourceCheckpoint 1 (Just (contentDigest "other"))) 10
            assertBool "broken link" (isChainBroken linked)
            ahead <- readSourceChain (chainStore chain) (SourceCheckpoint 5 (Just (contentDigest "other"))) 10
            assertBool "checkpoint ahead" (either (\case SourceCheckpointAhead _ _ -> True; _ -> False) (const False) ahead)
            missing <- buildChainWith False [Conv tx1 (Just [])] Nothing
            lost <- readSourceChain (chainStore missing) initialCheckpoint 10
            assertBool "missing facts object" (either (const True) (const False) lost)
        , testCase "a late batch reads only the suffix after its checkpoint" $ do
            chain <- buildChain (replicate 40 (Plain tx2) <> [Conv tx1 (Just [])]) Nothing
            early <- readFrom chain initialCheckpoint 40
            early ^. #checkpoint . #next @?= 40
            before <- snapshotCounters (storeCounters (chainStore chain))
            late <- readFrom chain (early ^. #checkpoint) 40
            after <- snapshotCounters (storeCounters (chainStore chain))
            map (^. #transaction) (late ^. #sources) @?= [tx1]
            -- The head, the one new journal event and its facts object; no
            -- earlier event and no write.
            countOf RemoteGet after - countOf RemoteGet before @?= 3
            countOf RemotePut after - countOf RemotePut before @?= 0
        ]
    , testGroup
        "controls"
        [ testCase "two committed control revisions stay reachable in order for a late consumer" $ do
            chain <- buildChain [Conv tx1 (Just [control "rev-1" 1]), Plain tx2, Conv tx2 (Just [control "rev-2" 1])] Nothing
            batch <- readFrom chain initialCheckpoint 10
            let step = consumeControls subscriptions version1 batch
            step ^. #accepted @?= ["rev-1", "rev-2"]
            step ^. #refused @?= Nothing
            step ^. #checkpoint @?= batch ^. #checkpoint
        , testCase "an unsupported control version stops its consumer before that source, every time" $ do
            chain <- buildChain [Conv tx1 (Just [control "rev-1" 1]), Plain tx2, Conv tx2 (Just [control "rev-2" 2])] Nothing
            batch <- readFrom chain initialCheckpoint 10
            let step = consumeControls subscriptions version1 batch
            step ^. #accepted @?= ["rev-1"]
            fmap fst (step ^. #refused) @?= Just (sourceKey "rev-2")
            step ^. #checkpoint . #next @?= 2
            again <- readFrom chain (step ^. #checkpoint) 10
            fmap fst (consumeControls subscriptions version1 again ^. #refused) @?= Just (sourceKey "rev-2")
            -- Another consumer's checkpoint is its own: event publication
            -- went past the refused control without acknowledging it.
            batch ^. #checkpoint . #next @?= 3
        ]
    ]

-- * Executor runs

data Landing = NotLanded | LandedLost

-- | A fault on one put: the first matching put fails once, or the head
-- writes after the convergence event was published fail @n@ times.
data Fault
  = FailOnce !(Text -> ByteString -> Bool) !Landing
  | FailAfterConvergence !Int !Landing

data FixtureRun = FixtureRun
  { base :: !ObjectOps
  , inspect :: !InventoryStore
  , registry :: !AdapterRegistry
  , outcome :: !TransactionResult
  , counters :: !(Int, Int)
  }
  deriving stock (Generic)

runFixture :: [Fault] -> Maybe SourceProducer -> IO FixtureRun
runFixture faults producer = do
  base <- fakeObjectOps
  armed <- newIORef False
  remaining <- newIORef faults
  headPutCount <- newIORef (0 :: Int)
  let ops =
        base
          { putObject = \condition name@(ObjectName key) bytes -> do
              when (key == "head.json") (modifyIORef' headPutCount (+ 1))
              pending <- readIORef remaining
              isArmed <- readIORef armed
              case pick key bytes isArmed pending of
                Just (landing, rest) -> do
                  writeIORef remaining rest
                  case landing of
                    NotLanded -> pure (PutUnknown "injected failure")
                    LandedLost -> putObject base condition name bytes >> writeIORef armed False >> pure (PutUnknown "injected lost acknowledgement")
                Nothing -> do
                  result <- putObject base condition name bytes
                  case result of
                    PutWritten _
                      | "journal/" `T.isPrefixOf` key && "\"convergence\"" `T.isInfixOf` TE.decodeUtf8 bytes -> writeIORef armed True
                      | key == "head.json" -> writeIORef armed False
                    _ -> pure ()
                  pure result
          , pauseBeforeRetry = \_ -> pure ()
          }
  store <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
  (reviewed, fixtureRegistry) <-
    preparedFixtureWith
      store
      (\_ _ -> pure AdapterEffectCompleted)
      (\_ _ -> pure RecoverySafeToRetry)
  let registered = maybe fixtureRegistry (`withSourceProducer` fixtureRegistry) producer
  before <- snapshotCounters (storeCounters store)
  headsBefore <- readIORef headPutCount
  applied <- applyReviewed store registered reviewed >>= either (assertFailure . show) pure
  after <- snapshotCounters (storeCounters store)
  headsAfter <- readIORef headPutCount
  inspection <- newObjectStore base fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
  pure (FixtureRun base inspection registered applied (countOf RemotePut after - countOf RemotePut before, headsAfter - headsBefore))
  where
    pick _ _ _ [] = Nothing
    pick key bytes isArmed (fault : rest) = case fault of
      FailOnce matches landing | matches key bytes -> Just (landing, rest)
      FailAfterConvergence n landing
        | isArmed && key == "head.json" && n > 0 ->
            Just (landing, if n > 1 then FailAfterConvergence (n - 1) landing : rest else rest)
      _ -> fmap (fmap (fault :)) (pick key bytes isArmed rest)

puts :: FixtureRun -> Int
puts run = fst (run ^. #counters)

headPuts :: FixtureRun -> Int
headPuts run = snd (run ^. #counters)

resumeFixture :: FixtureRun -> IO TransactionResult
resumeFixture run = do
  store <- newObjectStore (run ^. #base) fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
  resumeTransaction store (run ^. #registry) (transactionOf run) >>= either (assertFailure . show) pure

transactionOf :: FixtureRun -> TransactionId
transactionOf run = case run ^. #outcome of
  Converged transaction -> transaction
  PausedAtBarrier transaction _ -> transaction
  StoppedFailed transaction _ _ -> transaction
  StoppedAmbiguous transaction _ _ -> transaction
  Closed transaction -> transaction

readHeadOf :: FixtureRun -> IO HeadManifest
readHeadOf run = readHead (run ^. #inspect) >>= either (assertFailure . show) (maybe (assertFailure "no head") pure)

journalOf :: FixtureRun -> IO [JournalEvent]
journalOf run = do
  headValue <- readHeadOf run
  loaded <- readJournalPrefix (run ^. #inspect) (headSequence headValue) >>= either (assertFailure . show) pure
  traverse (either (assertFailure . T.unpack) pure . decodeJournalEvent) loaded

readAll :: FixtureRun -> IO SourceBatch
readAll run = readSourceChain (run ^. #inspect) initialCheckpoint 1000 >>= either (assertFailure . show) pure

assertOneSource :: FixtureRun -> Assertion
assertOneSource run = do
  batch <- readAll run
  map (^. #transaction) (batch ^. #sources) @?= [transactionOf run]
  headValue <- readHeadOf run
  headSchemaVersion headValue @?= 2
  isNothing (headActiveTransaction headValue) @?= True

assertConverged :: TransactionResult -> Assertion
assertConverged = \case
  Converged _ -> pure ()
  other -> assertFailure ("expected convergence, got " <> show other)

assertNotConverged :: TransactionResult -> Assertion
assertNotConverged = \case
  Converged _ -> assertFailure "expected the release to stop"
  _ -> pure ()

keyPrefixed :: Text -> Text -> ByteString -> Bool
keyPrefixed prefix key _ = prefix `T.isPrefixOf` key

convergenceEvent :: Text -> ByteString -> Bool
convergenceEvent key bytes = "journal/" `T.isPrefixOf` key && "\"convergence\"" `T.isInfixOf` TE.decodeUtf8 bytes

isRightJust :: Either e (Maybe a) -> Bool
isRightJust = \case
  Right (Just _) -> True
  _ -> False

-- | One public candidate per converging transaction, keyed by it.
testProducer :: SourceProducer
testProducer = sourceProducer $ \input ->
  case Map.toList (input ^. #desiredRevisions) of
    (scope, revision) : _ ->
      [ PublicCandidate
          EventCandidate
            { key = candidateKey (input ^. #transaction)
            , resource = ResourceRef scope Nothing Nothing Nothing
            , occurredAt = Just "2026-11-17T00:00:00Z"
            , evidence = [Evidence "review" (input ^. #review)]
            , payload =
                AppDeployedPayload
                  AppDeployment
                    { subject = ApplicationSubject
                    , action = DeployAction
                    , release = "release-1"
                    , previousRelease = Nothing
                    , scopeRevision = revision
                    , transaction = input ^. #transaction
                    , review = input ^. #review
                    , readiness = input ^. #review
                    }
            }
      ]
    [] -> []

changeAppliedKey :: TransactionId -> SourceKey
changeAppliedKey transaction = sourceKey ("change.applied:" <> transactionIdText transaction)

candidateKey :: TransactionId -> SourceKey
candidateKey transaction = sourceKey ("test:" <> transactionIdText transaction)

sourceKey :: Text -> SourceKey
sourceKey = either (error . T.unpack) id . mkSourceKey

-- * Handcrafted journals

data Entry = Plain !TransactionId | Conv !TransactionId !(Maybe [ControlFact])

data Chain = Chain {chainStore :: !InventoryStore}

tx1, tx2 :: TransactionId
tx1 = either (error . T.unpack) id (mkTransactionId "tx-one")
tx2 = either (error . T.unpack) id (mkTransactionId "tx-two")

buildChain :: [Entry] -> Maybe TransactionId -> IO Chain
buildChain = buildChainWith True

-- | A memory store whose journal holds the entries, every convergence naming
-- a facts object (published unless @publishFacts@ is off), and whose head
-- commits them with @active@ as its active transaction.
buildChainWith :: Bool -> [Entry] -> Maybe TransactionId -> IO Chain
buildChainWith publishFacts entries active = do
  ops <- fakeObjectOps
  store <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
  initial <- initializeStore store fixtureBinding "client-a" >>= either (assertFailure . show) pure
  let review = contentDigest "review"
      go _ _ [] = pure ()
      go sequenceNumber previous (entry : rest) = do
        (transaction, convergence) <- case entry of
          Plain transaction -> pure (transaction, Nothing)
          Conv transaction Nothing -> pure (transaction, Just (Convergence review Nothing))
          Conv transaction (Just controlFacts) -> do
            let facts = SourceFacts factsSchemaVersion transaction review [] controlFacts
            when publishFacts (void (publishIfAbsent store (factsKey (factsDigest facts)) (encodeSourceFacts facts) >>= either (assertFailure . show) pure))
            pure (transaction, Just (Convergence review (Just (factsDigest facts))))
        let event =
              JournalEvent
                (if isJust convergence then convergenceSchemaVersion else 1)
                sequenceNumber
                previous
                transaction
                Nothing
                (if isJust convergence then Completed review else Pending)
                "2026-11-17T00:00:00Z"
                "test"
                Nothing
                convergence
        _ <- appendAtSequence store sequenceNumber (encodeJournalEvent event) >>= either (assertFailure . show) pure
        go (sequenceNumber + 1) (Just (journalEventDigest event)) rest
  go 0 Nothing entries
  let committed =
        initial
          { headGeneration = headGeneration initial + 1
          , headSequence = fromIntegral (length entries)
          , headSchemaVersion = 2
          , headActiveTransaction = transactionIdText <$> active
          }
  replaceHeadIfGenerationMatches store (Just (headGeneration initial)) committed >>= either (assertFailure . show) pure
  pure (Chain store)

readFrom :: Chain -> SourceCheckpoint -> Int -> IO SourceBatch
readFrom chain from budget = readSourceChain (chainStore chain) from budget >>= either (assertFailure . show) pure

isChainBroken :: Either SourceChainError a -> Bool
isChainBroken = \case
  Left (SourceChainBroken _ _) -> True
  _ -> False

subscriptions :: ControlChannel
subscriptions = either (error . T.unpack) id (mkControlChannel "subscriptions")

control :: Text -> Int -> ControlFact
control name revision = ControlFact (sourceKey name) subscriptions revision Null

addField :: Value -> Value
addField = \case
  Object fields -> Object (KM.insert "extra" Null fields)
  other -> other

version1 :: ControlFact -> Either Text Text
version1 fact
  | fact ^. #version == 1 = Right (sourceKeyText (fact ^. #key))
  | otherwise = Left "unsupported control version"
