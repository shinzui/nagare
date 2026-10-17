-- | The admin API's read-only GCS session (EP-196) against a loopback
-- Storage JSON API and token endpoint: the SDK performs real HTTP, signs a
-- real service-account JWT, and every request is recorded, so the tests
-- prove which calls the reader makes and that it never lists or writes.
module InventoryServiceStoreSpec (inventoryServiceStoreTests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently)
import Control.Monad (join)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft, isRight)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (diffUTCTime, getCurrentTime)
import Gogol qualified as G
import Gogol.Env qualified as Env
import Gogol.Storage qualified as S
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Gogol (inventoryManagerSettings)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Inventory.Store.Service
import Nagare.Test.World.ObjectStore (fakeObjectState)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcess)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Text.Read (readMaybe)

data Fake = Fake
  { objects :: !(IORef (Map.Map T.Text (Integer, BS.ByteString)))
  , owner :: !(IORef T.Text)
  , calls :: !(IORef [(Method, BS.ByteString, Query)])
  , exchanges :: !(IORef Int)
  , tokenLifetime :: !(IORef Int)
  , tokenDenied :: !(IORef Bool)
  , hung :: !(IORef Bool)
  }

inventoryServiceStoreTests :: TestTree
inventoryServiceStoreTests =
  testGroup
    "Admin API service store"
    [ testCase "an existing store is read through exact GETs, with one token for many reads" $ withService $ \fake config -> do
        service <- openServiceStore config >>= either (assertFailure . show) pure
        headValue <- freshHead service >>= either (assertFailure . show) pure
        assertBool "the head was not read" (isJust headValue)
        replicateM_' 3 (freshHead service >>= assertBool "a fresh head failed" . isRight)
        readObject (store service) "scopes/absent" >>= (@?= Right Nothing)
        recorded <- readIORef (calls fake)
        assertBool "the reader listed or wrote" (all allowed recorded)
        readIORef (exchanges fake) >>= (@?= 1)
    , testCase "a foreign owner, a missing format and a missing head fail closed" $ withService $ \fake config -> do
        service <- openServiceStore config >>= either (assertFailure . show) pure
        writeIORef (owner fake) "99999"
        freshHead service >>= assertBool "a foreign bucket was read" . isLeft
        writeIORef (owner fake) "12345"
        modifyIORef' (objects fake) (Map.delete "nagare/fixture/inventory/head.json")
        freshHead service >>= (@?= Right Nothing)
        modifyIORef' (objects fake) (Map.delete "nagare/fixture/inventory/format.json")
        reopened <- openServiceStore config
        assertBool "an uninitialized prefix opened" (isLeft reopened)
        recorded <- readIORef (calls fake)
        assertBool "absence was proved by listing" (all allowed recorded)
    , testCase "a write never leaves the reader" $ withService $ \fake config -> do
        service <- openServiceStore config >>= either (assertFailure . show) pure
        publishIfAbsent (store service) "scopes/new" "bytes" >>= assertBool "a write succeeded" . isLeft
        -- Its existence check is an exact GET; the write itself never leaves.
        recorded <- readIORef (calls fake)
        assertBool "the reader listed or wrote" (all allowed recorded)
    , testCase "a person's credential is refused" $ withService $ \_ config ->
        withSystemTempDirectory "nagare-service-user" $ \directory -> do
          let path = directory <> "/user.json"
          LBS.writeFile path (encode (object ["type" .= ("authorized_user" :: T.Text), "client_id" .= ("c" :: T.Text), "client_secret" .= ("s" :: T.Text), "refresh_token" .= ("r" :: T.Text)]))
          opened <- openServiceStore config {credentialsFile = path}
          case opened of
            Left (StoreCredentialsUnavailable _) -> pure ()
            _ -> assertFailure "an authorized user credential opened the reader"
    , testCase "an expired token is refreshed for concurrent reads without a refresh storm" $ withService $ \fake config -> do
        writeIORef (tokenLifetime fake) 0
        service <- openServiceStore config >>= either (assertFailure . show) pure
        writeIORef (tokenLifetime fake) 3600
        before <- readIORef (exchanges fake)
        results <- mapConcurrently (const (freshHead service)) [1 .. 8 :: Int]
        assertBool "a concurrent read failed" (all isRight results)
        count <- readIORef (exchanges fake)
        count - before @?= 1
        freshHead service >>= assertBool "a fresh head failed" . isRight
        readIORef (exchanges fake) >>= (@?= count)
    , testCase "an unavailable token service is a credential failure" $ withService $ \fake config -> do
        writeIORef (tokenDenied fake) True
        opened <- openServiceStore config
        case opened of
          Left (StoreCredentialsUnavailable _) -> pure ()
          Left other -> assertFailure ("expected a credential failure, got " <> show other)
          Right _ -> assertFailure "the reader opened without a token"
    , testCase "the caller's deadline cancels a hung read" $ withService $ \fake config -> do
        service <- openServiceStore config >>= either (assertFailure . show) pure
        writeIORef (hung fake) True
        started <- getCurrentTime
        outcome <- timeout 1000000 (freshHead service)
        finished <- getCurrentTime
        outcome @?= Nothing
        assertBool "the deadline was not honored" (diffUTCTime finished started < 1.5)
        writeIORef (hung fake) False
    ]
  where
    replicateM_' n action = mapM_ (const action) [1 .. n :: Int]

-- | Only bucket metadata and exact object GETs (and the token exchange).
allowed :: (Method, BS.ByteString, Query) -> Bool
allowed (method, path, _) =
  path == "/oauth2/v4/token"
    || (method == "GET" && (path == "/storage/v1/b/fixture-bucket" || "/storage/v1/b/fixture-bucket/o/" `BS.isPrefixOf` path))

withService :: (Fake -> ServiceStoreConfig -> IO ()) -> IO ()
withService action = do
  fake <- Fake <$> seededObjects <*> newIORef "12345" <*> newIORef [] <*> newIORef 0 <*> newIORef 3600 <*> newIORef False <*> newIORef False
  withSystemTempDirectory "nagare-service-store" $ \directory -> do
    keyPath <- serviceAccountKey directory
    testWithApplication (pure (server fake)) $ \port -> do
      let settings =
            inventoryManagerSettings
              { HTTP.managerModifyRequest = \request -> do
                  hardened <- HTTP.managerModifyRequest inventoryManagerSettings request
                  if HTTP.host hardened `elem` ["www.googleapis.com", "oauth2.googleapis.com"] && HTTP.path hardened == "/oauth2/v4/token"
                    then pure hardened {HTTP.host = "127.0.0.1", HTTP.port = port, HTTP.secure = False}
                    else
                      if HTTP.host hardened == "127.0.0.1" && HTTP.port hardened == port
                        then pure hardened
                        else ioError (userError "test refused a non-loopback endpoint")
              }
          configure = Env.override (S.storageService & G.serviceHost .~ "127.0.0.1" & G.servicePort .~ port & G.serviceSecure .~ False)
      action
        fake
        ServiceStoreConfig
          { binding = fixtureBinding
          , projectNumber = "12345"
          , storeUrl = "gs://fixture-bucket/nagare/fixture/inventory"
          , credentialsFile = keyPath
          , cacheDirectory = Nothing
          , managerSettings = settings
          , configureEnv = configure
          }

-- | A real RSA key in a service-account key file; the loopback token
-- endpoint accepts any signed assertion.
serviceAccountKey :: FilePath -> IO FilePath
serviceAccountKey directory = do
  pem <- readProcess "openssl" ["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"] ""
  let path = directory <> "/reader.json"
  LBS.writeFile
    path
    ( encode
        ( object
            [ "type" .= ("service_account" :: T.Text)
            , "private_key_id" .= ("fixture-key" :: T.Text)
            , "private_key" .= pem
            , "client_email" .= ("nagare-admin-api@fixture-project.iam.gserviceaccount.com" :: T.Text)
            , "client_id" .= ("1234567890" :: T.Text)
            ]
        )
    )
  pure path

-- | A store initialized and seeded through the ordinary writer, copied under
-- the bucket prefix.
seededObjects :: IO (IORef (Map.Map T.Text (Integer, BS.ByteString)))
seededObjects = do
  (ops, state) <- fakeObjectState
  writer <- newObjectStore ops fixtureBinding "client-writer" Nothing >>= either (assertFailure . show) pure
  _ <- initializeStore writer fixtureBinding "client-writer" >>= either (assertFailure . show) pure
  (_, written) <- readIORef state
  newIORef (Map.fromList [("nagare/fixture/inventory/" <> key, (generation, bytes)) | (ObjectName key, (Generation generation, bytes)) <- Map.toList written])

server :: Fake -> Wai.Application
server fake request respond = do
  let path = Wai.rawPathInfo request
      query name = join (lookup name (Wai.queryString request))
      send status value = respond (Wai.responseLBS status [(hContentType, "application/json")] (encode value))
      refuse status = send status (object ["error" .= ("private-provider-diagnostic" :: T.Text)])
      prefix = "/storage/v1/b/fixture-bucket/o/" :: BS.ByteString
  modifyIORef' (calls fake) ((Wai.requestMethod request, path, Wai.queryString request) :)
  if path == "/oauth2/v4/token"
    then do
      denied <- readIORef (tokenDenied fake)
      lifetime <- readIORef (tokenLifetime fake)
      atomicModifyIORef' (exchanges fake) (\count -> (count + 1, ()))
      if denied
        then refuse status400
        else send status200 (object ["access_token" .= ("reader-token" :: T.Text), "expires_in" .= lifetime, "token_type" .= ("Bearer" :: T.Text)])
    else
      if lookup hAuthorization (Wai.requestHeaders request) /= Just "Bearer reader-token" || isJust (query "userProject")
        then refuse status401
        else case Wai.requestMethod request of
          "GET" | path == "/storage/v1/b/fixture-bucket" -> do
            number <- readIORef (owner fake)
            send status200 (object ["name" .= ("fixture-bucket" :: T.Text), "projectNumber" .= number])
          "GET" | Just encoded <- BS.stripPrefix prefix path -> do
            let name = TE.decodeUtf8 (urlDecode False encoded)
            isHung <- readIORef (hung fake)
            when isHung (threadDelay 5000000)
            snapshot <- readIORef (objects fake)
            case Map.lookup name snapshot of
              Nothing -> refuse status404
              Just (generation, bytes)
                | query "alt" == Just "media"
                , (readMaybe . BC.unpack =<< query "generation") == Just generation ->
                    respond (Wai.responseLBS status200 [] (LBS.fromStrict bytes))
                | query "alt" == Just "media" -> refuse status404
                | otherwise ->
                    send status200 (object ["bucket" .= ("fixture-bucket" :: T.Text), "name" .= name, "generation" .= show generation, "size" .= show (BS.length bytes)])
          _ -> refuse status403
