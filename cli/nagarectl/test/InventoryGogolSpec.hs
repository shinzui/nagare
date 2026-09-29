{-# LANGUAGE OverloadedRecordDot #-}

module InventoryGogolSpec (inventoryGogolTests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (bracket_, finally)
import Control.Monad (forM_, join)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Gogol qualified as G
import Gogol.Auth qualified as Auth
import Gogol.Env qualified as Env
import Gogol.Storage qualified as S
import InventoryTransactionSpec (exerciseStore, fixtureBinding, preparedFixtureWith)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal (operationIdText)
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Gogol
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Text.Read (readMaybe)

-- The SDK performs actual HTTP against this loopback server. No gcloud, ADC,
-- Google endpoint, native provider, or operator credential is used.
data Mode = Normal | HoldFirst | Denied | Unauthorized | RevokedAfterWrite | ListDenied | BadMetadata | PartialMedia | LostAck | UnreadableAck | CasRace | LoopPages | ForeignPage | DuplicatePage | Redirect
  deriving stock (Eq, Show)

data Fixture = Fixture
  { objects :: !(IORef (Map.Map T.Text (Integer, BS.ByteString)))
  , mode :: !(IORef Mode)
  , requests :: !(IORef Int)
  , writes :: !(IORef Int)
  , inFlight :: !(IORef Int)
  , maximumFlight :: !(IORef Int)
  , mediaGets :: !(IORef Int)
  , releaseFirst :: !(MVar ())
  , ninthStarted :: !(MVar ())
  }

inventoryGogolTests :: TestTree
inventoryGogolTests =
  testGroup
    "Gogol inventory transport"
    [ testCase "expired credentials refresh with the originally selected identity" credentialRefreshTest
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
          StoppedAmbiguous value _ -> pure value
          other -> assertFailure (show other) >> error "unreachable"
        writeIORef (mode f) LostAck
        replay <- newObjectStore ops fixtureBinding "sdk-client" Nothing >>= either (assertFailure . show) pure
        resumeTransaction replay registry transaction >>= either (assertFailure . show) pure >>= (@?= Converged transaction)
        readIORef effects >>= (@?= 1)
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
              ("GET", Just _) | modeValue `elem` [Denied, UnreadableAck] -> bad status403
              ("GET", Just name) | modeValue == BadMetadata -> send status200 (object ["name" .= name])
              ("GET", Just name) -> do
                snapshot <- readIORef (objects f)
                case Map.lookup name snapshot of
                  Nothing -> bad status404
                  Just (gen, bytes)
                    | Just expected <- number "generation", expected /= gen -> bad status404
                    | query "alt" == Just "media", isNothing (number "generation" :: Maybe Integer) -> bad status400
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
                          respond (Wai.responseLBS status200 [] (LBS.fromStrict (if modeValue == PartialMedia then BS.take 1 bytes else bytes)))
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
newFixture = Fixture <$> newIORef Map.empty <*> newIORef Normal <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newEmptyMVar <*> newEmptyMVar

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
