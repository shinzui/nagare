{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Read-only, bounded SDK experiment. Never prints credentials or object content.
-- API source: mori://brendanhay/gogol/repos/gogol
module Main where

import Control.Exception (Exception, SomeException, catch, fromException, throwIO)
import Control.Lens ((?~))
import Control.Monad (replicateM, unless)
import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Data.Text.Lazy qualified as Lazy
import Data.Text.Lazy.Builder (toLazyText)
import Data.Time.Clock
import Gogol qualified as G
import Gogol.Auth qualified as Auth
import Gogol.Env qualified as Env
import Gogol.Storage qualified as S
import Gogol.Storage.Objects.Get qualified as Get
import Gogol.Storage.Objects.Insert qualified as Insert
import Gogol.Storage.Objects.List qualified as List
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (statusCode, urlEncode)
import System.Environment (getArgs)
import System.Exit (die)
import System.Timeout (timeout)

type StorageEnv = G.Env '[S.Devstorage'ReadOnly]

bucket, key, project :: Text
bucket = "tan-ng-labs-ep150-pmkjjpp-state"
key = "inventory/head.json"
project = "tan-ng-labs"

-- Gogol's Capture Text appends toQueryParam directly to the path. Encode once
-- here; query values and upload metadata remain unencoded logical names.
pathPiece :: Text -> Text
pathPiece = Text.decodeUtf8 . urlEncode False . Text.encodeUtf8

getRequest :: Get.StorageObjectsGet
getRequest = (S.newStorageObjectsGet bucket (pathPiece key)){Get.userProject = Just project}

statusOnly :: G.Error -> Int
statusOnly (G.ServiceError e) = statusCode (G._serviceStatus e)
statusOnly (G.SerializeError e) = statusCode (G._serializeStatus e)
statusOnly (G.TransportError _) = 0

data ProbeFailure = ProbeFailure String deriving (Show)
instance Exception ProbeFailure

require :: Bool -> String -> IO ()
require ok message = unless ok (throwIO (ProbeFailure message))

-- Project only non-secret request fields. No request is sent by these checks.
wireChecks :: IO Value
wireChecks = do
    let get = G.requestClient getRequest
        media = G.requestClient (G.MediaDownload (getRequest{Get.generation = Just 42}))
        create =
            G.requestClient
                ( G.MediaUpload
                    ((S.newStorageObjectsInsert bucket S.newObject){Insert.name = Just key, Insert.ifGenerationMatch = Just 0, Insert.userProject = Just project})
                    ("fixture" :: G.GBody)
                )
        cas =
            G.requestClient
                ( G.MediaUpload
                    ((S.newStorageObjectsInsert bucket S.newObject){Insert.name = Just key, Insert.ifGenerationMatch = Just 42, Insert.userProject = Just project})
                    ("fixture" :: G.GBody)
                )
        listing =
            G.requestClient
                ( (S.newStorageObjectsList bucket)
                    { List.prefix = Just "inventory/"
                    , List.pageToken = Just "page/2+token"
                    , List.maxResults = 1
                    , List.userProject = Just project
                    }
                )
        path c = Lazy.toStrict (toLazyText (G._rqPath (G._cliRequest c)))
        query c = toList (G._rqQuery (G._cliRequest c))
        has c k v = lookup k (query c) == Just (Just v)
    require (path get == "/storage/v1/b/tan-ng-labs-ep150-pmkjjpp-state/o/inventory%2Fhead.json") "object path not encoded"
    require (pathPiece "inventory/a b%?#λ.json" == "inventory%2Fa%20b%25%3F%23%CE%BB.json") "special path encoding"
    require (has media "generation" "42" && has media "alt" "media") "generation-bound media"
    require (has create "ifGenerationMatch" "0" && G._cliMethod create == "POST") "conditional create"
    require (has cas "ifGenerationMatch" "42" && has cas "name" "inventory/head.json") "conditional replacement"
    require (has listing "prefix" "inventory/" && has listing "pageToken" "page/2+token") "pagination query"
    require (has get "userProject" "tan-ng-labs" && has media "userProject" "tan-ng-labs") "project binding"
    require (has create "userProject" "tan-ng-labs" && has listing "userProject" "tan-ng-labs") "project binding on write/list"
    pure $ object ["checks" .= (8 :: Int), "status" .= ("passed" :: Text)]

readOnce :: StorageEnv -> IO Value
readOnce env = do
    started <- getCurrentTime
    (generation, body) <- G.runResourceT $ do
        meta <- G.send env getRequest
        gen <- maybe (fail "missing object generation") pure meta.generation
        unless (meta.name == Just key && meta.bucket == Just bucket && gen > 0) (fail "wrong object metadata")
        stream <- G.download env (getRequest{Get.generation = Just gen})
        bytes <- G.sinkLBS stream
        pure (gen, bytes)
    stopped <- getCurrentTime
    pure $
        object
            [ "generation" .= generation
            , "bytes" .= LBS.length body
            , "sha256" .= show (hashlazy body :: Digest SHA256)
            , "seconds" .= (realToFrac (diffUTCTime stopped started) :: Double)
            ]

liveRead :: IO Value
liveRead = do
    hookCount <- newIORef (0 :: Int)
    responseCount <- newIORef (0 :: Int)
    let expectedPath = "/storage/v1/b/tan-ng-labs-ep150-pmkjjpp-state/o/inventory%2Fhead.json"
        settings =
            tlsManagerSettings
                { HTTP.managerModifyRequest = \r -> do
                    -- Hard boundary: this executable cannot send a provider mutation,
                    -- access another object/origin, or follow a redirect with the token.
                    require (HTTP.method r == "GET" && HTTP.host r == "storage.googleapis.com" && HTTP.secure r && HTTP.port r == 443 && HTTP.path r == expectedPath) "request outside read-only target"
                    modifyIORef' hookCount (+ 1)
                    pure r{HTTP.redirectCount = 0, HTTP.responseTimeout = HTTP.responseTimeoutMicro 5000000}
                , HTTP.managerModifyResponse = \r -> modifyIORef' responseCount (+ 1) >> pure r
                , HTTP.managerRetryableException = const False
                }
    manager <- HTTP.newManager settings
    -- The runner supplies one gcloud token through stdin. Gogol reads it once;
    -- the 25-second whole-process bound expires before its 60-second file refresh.
    -- No ADC fallback, token file on disk, token log, or global configuration edit.
    env <- G.newEnvWith (Auth.FromTokenFile "/dev/stdin") (\_ _ -> pure ()) manager :: IO StorageEnv
    let bounded = Env.configure (G.serviceTimeout ?~ 5) env
    samples <- replicateM 3 (readOnce bounded)
    mismatch <- G.runResourceT $ G.sendEither bounded (getRequest{Get.ifGenerationMatch = Just (1 :: Int64)})
    require (either ((== 412) . statusOnly) (const False) mismatch) "generation mismatch did not refuse"
    responses <- readIORef responseCount
    hooks <- readIORef hookCount
    require (responses == 7) "unexpected response count"
    pure $ object ["reads" .= samples, "http_responses" .= responses, "request_guard_invocations" .= hooks, "mismatched_generation_status" .= (412 :: Int)]

main :: IO ()
main =
    ( do
        args <- getArgs
        result <- timeout 25000000 $ case args of
            ["wire"] -> wireChecks
            ["read"] -> wireChecks >> liveRead
            _ -> fail "expected wire or read"
        maybe (die "probe exceeded 25 seconds; no mutation was possible") (LBS.putStr . encode) result
    )
        `catch` \(err :: SomeException) -> case fromException err of
            Just (ProbeFailure message) -> die ("probe assertion: " <> message)
            Nothing -> case fromException err of
                Just sdkError -> die ("probe SDK status: " <> show (statusOnly sdkError))
                Nothing -> die "probe failed; details suppressed to protect credentials"
