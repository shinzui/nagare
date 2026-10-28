{-# LANGUAGE OverloadedRecordDot #-}

module InventoryGogolSpec (inventoryGogolTests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (bracket_, finally)
import Control.Monad (forM, forM_, join)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Gogol qualified as G
import Gogol.Auth qualified as Auth
import Gogol.Env qualified as Env
import Gogol.Storage qualified as S
import InventoryTransactionSpec (exerciseStore, fixtureBinding, modelScope, preparedFixtureWith)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal (operationIdText)
import Nagare.Inventory.Plan (InventoryHistory (historyAccepted), loadInventoryHistory)
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Gogol
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types
import Nagare.Resource.Wire (encodeCanonicalScope)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import System.Directory (listDirectory)
import System.IO (hClose)
import System.IO.Temp (withSystemTempDirectory, withSystemTempFile)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Text.Read (readMaybe)

-- The SDK performs actual HTTP against this loopback server. No gcloud, ADC,
-- Google endpoint, native provider, or operator credential is used.
data Mode = Normal | HoldFirst | Denied | Unauthorized | RevokedAfterWrite | ListDenied | BadMetadata | PartialMedia | LostAck | UnreadableAck | CasRace | LoopPages | ForeignPage | DuplicatePage | Redirect | BucketMissing | ForeignBucket
  deriving stock (Eq, Show)

data Fixture = Fixture
  { objects :: !(IORef (Map.Map T.Text (Integer, BS.ByteString)))
  , mode :: !(IORef Mode)
  , requests :: !(IORef Int)
  , writes :: !(IORef Int)
  , inFlight :: !(IORef Int)
  , maximumFlight :: !(IORef Int)
  , mediaGets :: !(IORef Int)
  , mediaNames :: !(IORef [T.Text])
  , mediaBytes :: !(IORef Int)
  , releaseFirst :: !(MVar ())
  , ninthStarted :: !(MVar ())
  }

inventoryGogolTests :: TestTree
inventoryGogolTests =
  testGroup
    "Gogol inventory transport"
    [ testCase "global bucket and bounded prefix discovery preserve absence and uncertainty" $ do
        f <- newFixture
        testWithApplication (pure (server f)) $ \port -> do
          let configure = Env.override (S.storageService & G.serviceHost .~ "127.0.0.1" & G.servicePort .~ port & G.serviceSecure .~ False)
          sdk <-
            newGogolDiscoveryWithToken (pure "fixture-token") configure "fixture-project" "gs://fixture-bucket/private/inventory"
              >>= either (assertFailure . T.unpack) pure
          discoveryBucket sdk >>= assertBool "valid bucket unavailable" . either (const False) isJust
          writeIORef (mode f) BucketMissing
          discoveryBucket sdk >>= (@?= Right Nothing)
          forM_ [Denied, Unauthorized, BadMetadata, Redirect] $ \value -> do
            writeIORef (mode f) value
            discoveryBucket sdk >>= assertBool "unavailable bucket became absent" . isLeft
          writeIORef (mode f) Normal
          discoveryPrefixEmpty sdk >>= (@?= Right True)
          writeIORef (objects f) (Map.singleton "private/inventory/head.json" (1, "head"))
          discoveryPrefixEmpty sdk >>= (@?= Right False)
          writeIORef (mode f) LoopPages
          discoveryPrefixEmpty sdk >>= assertBool "partial page became empty" . isLeft
          readIORef (writes f) >>= (@?= 0)
    , testCase "expired credentials refresh with the originally selected identity" credentialRefreshTest
    , testCase "SDK backend obeys the existing store transaction contract" $ fixture $ \_ ops -> do
        store <- newObjectStore ops fixtureBinding "sdk-client" Nothing >>= either (assertFailure . show) pure
        exerciseStore store
    , testCase "SDK-backed active resume recovers the original transaction without repeating its effect" $ fixture $ \f ops -> do
        firstStore <- newObjectStore ops fixtureBinding "sdk-client" Nothing >>= either (assertFailure . show) pure
        effects <- newIORef (0 :: Int)
        let executeOnce _ _ = modifyIORef' effects (+ 1) >> pure (AdapterEffectAmbiguous "effect completed; acknowledgement lost")
            recover operation _ = pure (RecoveryProvedComplete (contentDigest (TE.encodeUtf8 (operationIdText (plannedOperationId operation)))))
        (reviewed, registry) <- preparedFixtureWith firstStore executeOnce recover
        stopped <- applyReviewed firstStore registry reviewed >>= either (assertFailure . show) pure
        transaction <- case stopped of
          StoppedAmbiguous value _ _ -> pure value
          other -> assertFailure (show other) >> error "unreachable"
        writeIORef (mode f) LostAck
        replay <- newObjectStore ops fixtureBinding "sdk-client" Nothing >>= either (assertFailure . show) pure
        resumeTransaction replay registry transaction >>= either (assertFailure . show) pure >>= (@?= Converged transaction)
        readIORef effects >>= (@?= 1)
    , testCase "a 100-scope history reads each member with one media request, eight in flight, and none from a warm cache (EP-213)" $
        withSystemTempDirectory "inventory-gogol-cache" $ \cache -> fixture $ \f ops -> do
          store <- newObjectStore ops fixtureBinding "sdk-client" (Just cache) >>= either (assertFailure . show) pure
          initial <- initializeStore store fixtureBinding "sdk-client" >>= either (assertFailure . show) pure
          revisions <- fmap Map.fromList . forM [1 .. 100 :: Int] $ \n -> do
            let owner = either (error . T.unpack) id (mkScopeId Standalone ("scope-" <> T.pack (show n)))
                bytes = encodeCanonicalScope (modelScope owner "member" "v1")
            digest <- publishIfAbsent store (scopeKey (contentDigest bytes)) bytes >>= either (assertFailure . show) pure
            pure (owner, ScopeRevision (either (error . T.unpack) id (mkScopeGeneration 1)) digest)
          replaceHeadIfGenerationMatches store (Just (headGeneration initial)) initial {headGeneration = 1, headAccepted = revisions, headConverged = revisions}
            >>= either (assertFailure . show) pure
          let load = do
                writeIORef (requests f) 0
                writeIORef (mediaGets f) 0
                writeIORef (maximumFlight f) 0
                history <- loadInventoryHistory store >>= either (assertFailure . show) pure
                Map.size (historyAccepted history) @?= 100
                (,,) <$> readIORef (requests f) <*> readIORef (mediaGets f) <*> readIORef (maximumFlight f)
          -- The head is a metadata read and a pinned download; each member is
          -- one media request and nothing else.
          (requested, media, high) <- load
          (requested, media) @?= (102, 101)
          assertBool "member reads were serialized" (high > 1)
          assertBool "more than eight member reads in flight" (high <= 8)
          (warm, warmMedia, _) <- load
          (warm, warmMedia) @?= (2, 1)
    , testCase "an immutable member is one media request, its absence one 404, and a digest mismatch is never cached (EP-213)" $
        withSystemTempDirectory "inventory-gogol-mismatch" $ \cache -> fixture $ \f ops -> do
          store <- newObjectStore ops fixtureBinding "sdk-client" (Just cache) >>= either (assertFailure . show) pure
          _ <- initializeStore store fixtureBinding "sdk-client" >>= either (assertFailure . show) pure
          let bytes = "member bytes"
              key = scopeKey (contentDigest bytes)
              forged = scopeKey (contentDigest "other bytes")
              absent = scopeKey (contentDigest "never published")
              stored name = "private/inventory/" <> T.pack name
          modifyIORef' (objects f) (Map.insert (stored key) (1, bytes) . Map.insert (stored forged) (1, bytes))
          let counted action = do
                writeIORef (requests f) 0
                writeIORef (mediaGets f) 0
                result <- action
                (result,,) <$> readIORef (requests f) <*> readIORef (mediaGets f)
          counted (readObject store key) >>= (@?= (Right (Just bytes), 1, 1))
          counted (readObject store absent) >>= (@?= (Right Nothing, 1, 0))
          counted (readObject store forged) >>= (@?= (Left (StoreInvalidObject forged "remote immutable member digest mismatch"), 1, 1))
          listDirectory cache >>= (@?= [T.unpack (digestText (contentDigest bytes))])
          -- The head keeps its generation-bound read: metadata, then a pinned download.
          counted (readObject store "head.json") >>= \(_, requested, media) -> (requested, media) @?= (2, 1)
    , testCase "a publish creates first and reads back only when the create is refused (EP-213)" $ fixture $ \f ops -> do
        store <- newObjectStore ops fixtureBinding "sdk-client" Nothing >>= either (assertFailure . show) pure
        _ <- initializeStore store fixtureBinding "sdk-client" >>= either (assertFailure . show) pure
        let bytes = "published review"
            key = reviewKey (contentDigest bytes)
            counted action = do
              writeIORef (requests f) 0
              writeIORef (writes f) 0
              result <- action
              (result,,) <$> readIORef (requests f) <*> readIORef (writes f)
        -- Each publish first reads the head (two requests). A new object is
        -- then one create; an identical one a refused create and the
        -- transport's read-back (two); a different one a conflict.
        counted (publishIfAbsent store key bytes) >>= (@?= (Right (contentDigest bytes), 3, 1))
        counted (publishIfAbsent store key bytes) >>= (@?= (Right (contentDigest bytes), 5, 1))
        counted (publishIfAbsent store key "competing bytes") >>= \(result, _, written) -> (result, written) @?= (Left (StoreObjectConflict key), 1)
        readObject store key >>= (@?= Right (Just bytes))
    , testCase "generation-bound GET and private key encoding round trip" $ fixture $ \f ops -> do
        let key = ObjectName "native/a b%?#λ.json"
        putObject ops IfAbsent key "payload" >>= (@?= PutWritten (Generation 1))
        getObject ops key >>= (@?= ObjectFound (Generation 1) "payload")
        readIORef (writes f) >>= (@?= 1)
    , testCase "absence requires a successful complete listing; denial remains unknown" $ fixture $ \f ops -> do
        getObject ops (ObjectName "missing") >>= (@?= ObjectAbsent)
        forM_ [Denied, ListDenied, BadMetadata, Redirect] $ \modeValue -> do
          writeIORef (mode f) modeValue
          getObject ops (ObjectName "missing") >>= assertUnknown
    , testCase "partial generation downloads remain unknown" $ fixture $ \f ops -> do
        writeIORef (objects f) (Map.singleton "private/inventory/head.json" (3, "complete"))
        writeIORef (mode f) PartialMedia
        getObject ops (ObjectName "head.json") >>= assertUnknown
    , testCase "revoked credentials never prove absence or trigger a write retry" $ fixture $ \f ops -> do
        writeIORef (mode f) Unauthorized
        getObject ops (ObjectName "head.json") >>= assertUnknown
        readIORef (requests f) >>= (@?= 1)
        result <- putObject ops IfAbsent (ObjectName "head.json") "private-payload"
        case result of
          PutUnknown reason -> assertBool "private credential error leaked" (not ("private" `T.isInfixOf` reason))
          other -> assertFailure (show other)
        readIORef (requests f) >>= (@?= 3) -- one POST and one readback, no retry
        readIORef (objects f) >>= (@?= Map.empty)
    , testCase "revocation after a landed write preserves uncertainty and never repeats the write" $ fixture $ \f ops -> do
        writeIORef (mode f) RevokedAfterWrite
        putObject ops IfAbsent (ObjectName "head.json") "landed" >>= \case
          PutUnknown _ -> pure ()
          other -> assertFailure (show other)
        readIORef (writes f) >>= (@?= 1)
        readIORef (requests f) >>= (@?= 2)
        writeIORef (mode f) Normal
        getObject ops (ObjectName "head.json") >>= (@?= ObjectFound (Generation 1) "landed")
    , testCase "conditional create is idempotent and competing values conflict" $ fixture $ \_ ops -> do
        putObject ops IfAbsent (ObjectName "head.json") "one" >>= (@?= PutWritten (Generation 1))
        putObject ops IfAbsent (ObjectName "head.json") "one" >>= (@?= PutWritten (Generation 1))
        putObject ops IfAbsent (ObjectName "head.json") "two" >>= (@?= PutPreconditionFailed)
    , testCase "CAS uses the exact observed provider generation and refuses identical-byte ABA" $ fixture $ \f ops -> do
        putObject ops IfAbsent (ObjectName "head.json") "same" >>= (@?= PutWritten (Generation 1))
        writeIORef (mode f) CasRace
        putObject ops (IfGenerationMatches (Generation 1)) (ObjectName "head.json") "same" >>= (@?= PutPreconditionFailed)
        writeIORef (mode f) Normal
        getObject ops (ObjectName "head.json") >>= (@?= ObjectFound (Generation 2) "same")
    , testCase "landed write with failed acknowledgement is read back, never retried" $ fixture $ \f ops -> do
        writeIORef (mode f) LostAck
        putObject ops IfAbsent (ObjectName "head.json") "landed" >>= (@?= PutWritten (Generation 1))
        readIORef (writes f) >>= (@?= 1)
    , testCase "failed acknowledgement and unreadable readback remain unknown without leaking private bytes" $ fixture $ \f ops -> do
        writeIORef (mode f) UnreadableAck
        result <- putObject ops IfAbsent (ObjectName "head.json") "private-payload"
        case result of
          PutUnknown reason -> assertBool "private response leaked" (not ("private" `T.isInfixOf` reason))
          _ -> assertFailure (show result)
        readIORef (writes f) >>= (@?= 1)
    , testCase "pagination loads 50 and 500 journal generations with at most eight downloads in flight" $ fixture $ \f ops -> do
        forM_ [50, 500] $ \count -> do
          writeIORef (objects f) (Map.fromList [(journalName n, (toInteger (n + 1), "event")) | n <- [0 .. count - 1]])
          writeIORef (mediaGets f) 0
          writeIORef (maximumFlight f) 0
          writeIORef (requests f) 0
          result <- getObjects ops (ObjectName "journal") >>= either (assertFailure . T.unpack) pure
          Map.size result @?= count
          readIORef (mediaGets f) >>= (@?= count)
          readIORef (requests f) >>= (@?= count + (count + 6) `div` 7)
          high <- readIORef (maximumFlight f)
          assertBool "downloads serialized" (high > 1)
          assertBool "unbounded download concurrency" (high <= 8)
    , testCase "a 65-event journal tail is one anchor and 65 event downloads, never the cached prefix (EP-217 M4)" $
        withSystemTempDirectory "inventory-gogol-journal" $ \cache -> fixture $ \f ops -> do
          let event n = "event " <> BC.pack (show (n :: Int))
          writeIORef (objects f) (Map.fromList [(journalName n, (toInteger (n + 1), event n)) | n <- [0 .. 99]])
          store <- newObjectStore ops fixtureBinding "sdk-client" (Just cache) >>= either (assertFailure . show) pure
          _ <- readJournalPrefix store 100 >>= either (assertFailure . show) pure
          modifyIORef' (objects f) (<> Map.fromList [(journalName n, (toInteger (n + 1), event n)) | n <- [100 .. 164]])
          forM_ [requests f, mediaGets f, maximumFlight f, mediaBytes f] (`writeIORef` 0)
          writeIORef (mediaNames f) []
          readJournalPrefix store 165 >>= (@?= Right (map event [0 .. 164]))
          -- Every request is a media download of the anchor or a new event.
          (,) <$> readIORef (requests f) <*> readIORef (mediaGets f) >>= (@?= (66, 66))
          readIORef (mediaNames f) >>= (@?= map journalName [99 .. 164]) . sort
          readIORef (mediaBytes f) >>= (@?= sum (map (BS.length . event) [99 .. 164]))
          readIORef (maximumFlight f) >>= \high -> assertBool "unbounded download concurrency" (high > 1 && high <= 8)
    , testCase "looped, duplicate, and foreign listing pages refuse before downloading" $ fixture $ \f ops -> do
        forM_ [LoopPages, ForeignPage, DuplicatePage] $ \modeValue -> do
          writeIORef (objects f) (Map.fromList [(journalName n, (toInteger (n + 1), "event")) | n <- [0 .. 8]])
          writeIORef (mode f) modeValue
          result <- getObjects ops (ObjectName "journal")
          assertBool (show modeValue) (isLeft result)
          readIORef (mediaGets f) >>= (@?= 0)
    , testCase "one slow journal response does not idle the other seven workers" $ fixture $ \f ops -> do
        writeIORef (objects f) (Map.fromList [(journalName n, (toInteger (n + 1), "event")) | n <- [0 .. 15]])
        writeIORef (mode f) HoldFirst
        withAsync (getObjects ops (ObjectName "journal")) $ \fetching -> do
          ninth <- timeout 1000000 (takeMVar (ninthStarted f)) `finally` putMVar (releaseFirst f) ()
          result <- wait fetching >>= either (assertFailure . T.unpack) pure
          Map.size result @?= 16
          assertEqual "ninth request waited for the blocked first response" (Just ()) ninth
          readIORef (maximumFlight f) >>= \high -> assertBool "more than eight downloads" (high <= 8)
    , testCase "incomplete journal media never returns a successful partial prefix" $ fixture $ \f ops -> do
        writeIORef (objects f) (Map.fromList [(journalName n, (toInteger (n + 1), "event")) | n <- [0 .. 15]])
        writeIORef (mode f) PartialMedia
        getObjects ops (ObjectName "journal") >>= assertBool "partial prefix accepted" . isLeft
    , testCase "relative-key and generation guards refuse before HTTP" $ fixture $ \f ops -> do
        forM_ ["", "../outside", "/outside", "a//b", "a/../b", "a\n"] $ \name -> do
          getObject ops (ObjectName name) >>= assertUnknown
          putObject ops IfAbsent (ObjectName name) "x" >>= \case
            PutNoEffect _ -> pure ()
            value -> assertFailure (show value)
        forM_ [0, -1, 9223372036854775808] $ \gen -> do
          putObject ops (IfGenerationMatches (Generation gen)) (ObjectName "head.json") "x" >>= \case
            PutNoEffect _ -> pure ()
            value -> assertFailure (show value)
        readIORef (requests f) >>= (@?= 0)
    ]
  where
    assertUnknown (GetUnknown _) = pure ()
    assertUnknown value = assertFailure (show value)
    journalName n = "private/inventory/journal/" <> T.justifyRight 20 '0' (T.pack (show (n :: Int))) <> ".json"

fixture :: (Fixture -> ObjectOps -> IO ()) -> IO ()
fixture action = do
  f <- newFixture
  testWithApplication (pure (server f)) $ \port -> do
    let configure = Env.override (S.storageService & G.serviceHost .~ "127.0.0.1" & G.servicePort .~ port & G.serviceSecure .~ False)
    ops <- newGogolObjectOpsWithToken (pure "fixture-token") configure "fixture-project" "gs://fixture-bucket/private/inventory" >>= either (assertFailure . T.unpack) pure
    action f ops

server :: Fixture -> Wai.Application
server f req respond = do
  atomicModifyIORef' (requests f) (\n -> (n + 1, ()))
  modeValue <- readIORef (mode f)
  let query name = join (lookup name (Wai.queryString req))
      number :: (Read a) => BS.ByteString -> Maybe a
      number name = query name >>= readMaybe . BC.unpack
      send status value = respond (Wai.responseLBS status [(hContentType, "application/json")] (encode value))
      bad status = send status (object ["error" .= ("private-provider-diagnostic" :: T.Text)])
      listPath = "/storage/v1/b/fixture-bucket/o"
      uploadPath = "/upload/storage/v1/b/fixture-bucket/o"
      key = TE.decodeUtf8 . urlDecode False <$> BS.stripPrefix (listPath <> "/") (Wai.rawPathInfo req)
      metadata :: T.Text -> Integer -> BS.ByteString -> Value
      metadata name gen bytes = object ["kind" .= ("storage#object" :: T.Text), "bucket" .= ("fixture-bucket" :: T.Text), "name" .= name, "generation" .= show (gen :: Integer), "size" .= show (BS.length bytes)]
  if query "userProject" /= Just "fixture-project" || lookup hAuthorization (Wai.requestHeaders req) /= Just "Bearer fixture-token"
    then bad status403
    else
      if modeValue == Unauthorized || (modeValue == RevokedAfterWrite && Wai.requestMethod req == "GET")
        then bad status401
        else
          if modeValue == Redirect
            then respond (Wai.responseLBS status302 [(hLocation, "http://127.0.0.1:1/never")] "")
            else case (Wai.requestMethod req, key) of
              ("GET", Nothing) | Wai.rawPathInfo req == "/storage/v1/b/fixture-bucket" ->
                case modeValue of
                  BucketMissing -> bad status404
                  Denied -> bad status403
                  BadMetadata -> send status200 (object ["name" .= ("wrong" :: T.Text)])
                  _ ->
                    send
                      status200
                      ( object
                          [ "name" .= ("fixture-bucket" :: T.Text)
                          , "projectNumber" .= (if modeValue == ForeignBucket then "99999" else "12345" :: T.Text)
                          , "location" .= ("US-WEST1" :: T.Text)
                          , "versioning" .= object ["enabled" .= True]
                          , "iamConfiguration" .= object ["uniformBucketLevelAccess" .= object ["enabled" .= True], "publicAccessPrevention" .= ("enforced" :: T.Text)]
                          ]
                      )
              ("GET", Just _) | modeValue `elem` [Denied, UnreadableAck] -> bad status403
              ("GET", Just name) | modeValue == BadMetadata -> send status200 (object ["name" .= name])
              ("GET", Just name) -> do
                snapshot <- readIORef (objects f)
                case Map.lookup name snapshot of
                  Nothing -> bad status404
                  Just (gen, bytes)
                    | Just expected <- number "generation", expected /= gen -> bad status404
                    -- The mutable head and format are read only at a pinned
                    -- generation; a content-addressed member needs none (EP-213).
                    | query "alt" == Just "media"
                    , isNothing (number "generation" :: Maybe Integer)
                    , any (`T.isSuffixOf` name) ["/head.json", "/format.json"] ->
                        bad status400
                    | query "alt" == Just "media" -> bracket_
                        ( do
                            count <- atomicModifyIORef' (inFlight f) (\n -> (n + 1, n + 1))
                            atomicModifyIORef' (maximumFlight f) (\n -> (max count n, ()))
                            atomicModifyIORef' (mediaGets f) (\n -> (n + 1, ()))
                        )
                        (atomicModifyIORef' (inFlight f) (\n -> (n - 1, ())))
                        $ do
                          when (modeValue == HoldFirst) $ do
                            count <- readIORef (mediaGets f)
                            when (count >= 9) $ void (tryPutMVar (ninthStarted f) ())
                            when (name == "private/inventory/journal/00000000000000000000.json") (takeMVar (releaseFirst f))
                          threadDelay 2000
                          let body = if modeValue == PartialMedia then BS.take 1 bytes else bytes
                          atomicModifyIORef' (mediaNames f) (\seen -> (name : seen, ()))
                          atomicModifyIORef' (mediaBytes f) (\n -> (n + BS.length body, ()))
                          respond (Wai.responseLBS status200 [] (LBS.fromStrict body))
                    | otherwise -> send status200 (metadata name gen bytes)
              ("GET", Nothing) | Wai.rawPathInfo req == listPath -> do
                if modeValue == ListDenied
                  then bad status403
                  else do
                    snapshot <- readIORef (objects f)
                    let prefix = maybe "" TE.decodeUtf8 (query "prefix")
                        allEntries = filter (T.isPrefixOf prefix . fst) (Map.toAscList snapshot)
                        offset = fromMaybe 0 (number "pageToken" :: Maybe Int)
                        entries = take 7 (drop (if modeValue == DuplicatePage then 0 else offset) allEntries)
                        items =
                          if modeValue == LoopPages
                            then []
                            else
                              if modeValue == ForeignPage
                                then [metadata "foreign/head.json" 1 "bad"]
                                else [metadata name gen bytes | (name, (gen, bytes)) <- entries]
                        next =
                          if modeValue == LoopPages
                            then Just "repeat"
                            else if offset + 7 < length allEntries then Just (show (offset + 7)) else Nothing
                    send status200 (object (["items" .= items] <> maybe [] (\token -> ["nextPageToken" .= token]) next))
              ("POST", Nothing) | Wai.rawPathInfo req == uploadPath -> do
                atomicModifyIORef' (writes f) (\n -> (n + 1, ()))
                body <- LBS.toStrict <$> Wai.strictRequestBody req
                let name = maybe "" TE.decodeUtf8 (query "name")
                    -- Fixture-only extraction of the SDK multipart media part.
                    (_, afterType) = BS.breakSubstring "Content-Type: application/octet-stream" body
                    (_, afterHeaders) = BS.breakSubstring "\r\n\r\n" afterType
                    bytes = fst (BS.breakSubstring "\r\n--" (BS.drop 4 afterHeaders))
                if not ("private/inventory/" `T.isPrefixOf` name) || BS.null afterType || isNothing (number "ifGenerationMatch" :: Maybe Integer)
                  then bad status400
                  else do
                    if modeValue == CasRace then atomicModifyIORef' (objects f) (\values -> (Map.adjust (\(gen, value) -> (gen + 1, value)) name values, ())) else pure ()
                    written <- atomicModifyIORef' (objects f) $ \values ->
                      let previous = Map.lookup name values
                          matches = case previous of
                            Nothing -> number "ifGenerationMatch" == Just (0 :: Integer)
                            Just (gen, _) -> number "ifGenerationMatch" == Just gen
                          next = maybe 1 ((+ 1) . fst) previous
                       in if matches then (Map.insert name (next, bytes) values, Just next) else (values, Nothing)
                    case written of
                      Nothing -> bad status412
                      Just _ | modeValue `elem` [LostAck, UnreadableAck, RevokedAfterWrite] -> bad status500
                      Just gen -> send status200 (metadata name gen bytes)
              _ -> bad status404

newFixture :: IO Fixture
newFixture = Fixture <$> newIORef Map.empty <*> newIORef Normal <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef [] <*> newIORef 0 <*> newEmptyMVar <*> newEmptyMVar

-- An immediately expired first token exercises real SDK refresh without a sleep.
-- Replacing the source file must not silently select a different user on refresh.
credentialRefreshTest :: Assertion
credentialRefreshTest = do
  f <- newFixture
  exchanges <- newIORef (0 :: Int)
  let application req respond
        | Wai.rawPathInfo req == "/oauth2/v4/token" = do
            body <- LBS.toStrict <$> Wai.strictRequestBody req
            let fields = parseQuery body
            assertBool
              "credential identity changed during refresh"
              (lookup "client_id" fields == Just (Just "fixture-client") && lookup "client_secret" fields == Just (Just "fixture-secret") && lookup "refresh_token" fields == Just (Just "fixture-refresh"))
            count <- atomicModifyIORef' exchanges (\n -> (n + 1, n + 1))
            respond
              ( Wai.responseLBS
                  status200
                  [(hContentType, "application/json")]
                  ( encode
                      ( object
                          [ "access_token" .= (if count == 1 then "expired-token" else "fixture-token" :: T.Text)
                          , "expires_in" .= (if count == 1 then 0 else 3600 :: Int)
                          , "token_type" .= ("Bearer" :: T.Text)
                          ]
                      )
                  )
              )
        | otherwise = server f req respond
      credentials client = encode (object ["type" .= ("authorized_user" :: T.Text), "client_id" .= (client :: T.Text), "client_secret" .= ("fixture-secret" :: T.Text), "refresh_token" .= ("fixture-refresh" :: T.Text)])
  withSystemTempFile "nagare-sdk-test-user" $ \path handle -> do
    LBS.hPut handle (credentials "fixture-client")
    hClose handle
    testWithApplication (pure application) $ \port -> do
      let settings =
            inventoryManagerSettings
              { HTTP.managerModifyRequest = \request -> do
                  hardened <- HTTP.managerModifyRequest inventoryManagerSettings request
                  if HTTP.host hardened == "www.googleapis.com" && HTTP.path hardened == "/oauth2/v4/token"
                    then pure hardened {HTTP.host = "127.0.0.1", HTTP.port = port, HTTP.secure = False}
                    else
                      if HTTP.host hardened == "127.0.0.1" && HTTP.port hardened == port
                        then pure hardened
                        else ioError (userError "test refused a non-loopback endpoint")
              }
      manager <- HTTP.newManager settings
      selected <- Auth.fromFilePath path
      env <- G.newEnvWith selected (\_ _ -> pure ()) manager :: IO StorageEnv
      LBS.writeFile path (credentials "other-client")
      let local = Env.override (S.storageService & G.serviceHost .~ "127.0.0.1" & G.servicePort .~ port & G.serviceSecure .~ False) env
      ops <- either (assertFailure . T.unpack) pure (gogolObjectOpsWithEnv local "fixture-project" "gs://fixture-bucket/private/inventory")
      putObject ops IfAbsent (ObjectName "head.json") "after-refresh" >>= (@?= PutWritten (Generation 1))
      getObject ops (ObjectName "head.json") >>= (@?= ObjectFound (Generation 1) "after-refresh")
      readIORef exchanges >>= (@?= 2)
