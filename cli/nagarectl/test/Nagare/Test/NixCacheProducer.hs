-- | EP-230 M1 and M2: the producer path to the context's Attic cache, over
-- fake kubectl, port-forward, HTTP, Nix and Attic client. The fakes record
-- every argument vector, the client's configuration home and the bytes of
-- its configuration, so a test can show where the token went and where it
-- did not.
module Nagare.Test.NixCacheProducer
  ( nixCacheProducerTests
  )
where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, bracket, finally, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Trace (withCommandTrace)
import Nagare.Ops.NixCacheProducer
import Nagare.Target (Mode (Cloud, Local))
import System.Directory (doesFileExist, listDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (AppendMode), hClose, hFlush, openFile, stderr, stdout)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, intersectFileModes, ownerReadMode, ownerWriteMode, unionFileModes)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

nixCacheProducerTests :: [TestTree]
nixCacheProducerTests =
  [ testGroup
      "NixCacheProducer (EP-230)"
      [ argumentTests
      , validationTests
      , tokenTests
      , forwardTests
      , pushTests
      , leakTests
      ]
  ]

session :: [String]
session = ["--kubeconfig", "/private/kubeconfig-1", "--context", "intranet"]

token :: ByteString
token = "eyJhbGciOiJSUzI1NiJ9.secret-claims.secret-signature"

storePathA, storePathB :: FilePath
storePathA = "/nix/store/1rp5453vmy2839v1frykkx9wa578gsam-nagare-attic-smoke"
storePathB = "/nix/store/0aqhh0n6fd8zpnx4kxw1qkhfr3kbsxd5-hello-2.12"

-- * Fake world

data Call
  = Connection
  | Kubectl ![String]
  | Spawn ![String]
  | Fetch !String
  | Attic !FilePath ![String]
  | StorePath !FilePath
  deriving stock (Eq, Show)

data World = World
  { calls :: !(IORef [Call])
  , busy :: !(IORef Bool)
  , readyAfter :: !(IORef Int)
  , childExit :: !(IORef (Maybe ExitCode))
  , stops :: !(IORef Int)
  , atticExit :: !(IORef ExitCode)
  , atticGate :: !(IORef (Maybe (MVar ())))
  , atticEntered :: !(MVar ())
  , configs :: !(IORef [ByteString])
  , scratchRoot :: !FilePath
  }
  deriving stock (Generic)

newWorld :: FilePath -> IO World
newWorld root =
  World
    <$> newIORef []
    <*> newIORef False
    <*> newIORef 0
    <*> newIORef Nothing
    <*> newIORef 0
    <*> newIORef ExitSuccess
    <*> newIORef Nothing
    <*> newEmptyMVar
    <*> newIORef []
    <*> pure root

record :: World -> Call -> IO ()
record world call = modifyIORef' (world ^. #calls) (<> [call])

recorded :: World -> IO [Call]
recorded world = readIORef (world ^. #calls)

fakeOps :: World -> ProducerOps
fakeOps world =
  ProducerOps
    { connection = record world Connection >> pure (Right session)
    , kubectl = \arguments -> record world (Kubectl arguments) >> pure (Right ("  " <> token <> "\n"))
    , spawn = \arguments -> do
        record world (Spawn arguments)
        pure . Right $
          Child
            { exited = readIORef (world ^. #childExit)
            , waitExit = let wait = readIORef (world ^. #childExit) >>= maybe (threadDelay 1000 >> wait) pure in wait
            , lastError = pure "error: lost connection to pod"
            , stop = modifyIORef' (world ^. #stops) (+ 1) >> writeIORef (world ^. #childExit) (Just (ExitFailure 137))
            }
    , listening = readIORef (world ^. #busy)
    , fetch = \url -> do
        record world (Fetch url)
        if url == cacheConfigUrl forwardEndpoint cacheName
          then pure (Right "{\"is_public\":true,\"public_key\":\"nagare-cache:5VtCsl3sx0Vs1Wl1ZbkWWRkn8yBIsK8Ex5uT3NEWbis=\"}")
          else
            atomicModifyIORef' (world ^. #readyAfter) (\n -> (n - 1, n)) <&> \remaining ->
              if remaining <= 0 then Right "<html><title>Attic Binary Cache</title></html>" else Left "connection refused"
    , attic = \home arguments -> do
        record world (Attic home arguments)
        BS.readFile (home </> "attic" </> "config.toml") >>= \bytes -> modifyIORef' (world ^. #configs) (<> [bytes])
        void (tryPutMVar (world ^. #atticEntered) ())
        readIORef (world ^. #atticGate) >>= traverse_ readMVar
        readIORef (world ^. #atticExit)
    , storePath = \path -> do
        record world (StorePath path)
        pure (if path `elem` [storePathA, storePathB] then Right () else Left "error: path is not valid")
    , pause = pure ()
    , scratch = pure (world ^. #scratchRoot)
    }

withWorld :: (World -> IO a) -> IO a
withWorld body = withSystemTempDirectory "nix-cache-producer" (\root -> newWorld root >>= body)

isKubectl, isSpawn, isCluster :: Call -> Bool
isKubectl = \case Kubectl _ -> True; _ -> False
isSpawn = \case Spawn _ -> True; _ -> False
isCluster call = call == Connection || isKubectl call || isSpawn call

-- * Arguments

argumentTests :: TestTree
argumentTests =
  testGroup
    "argument vectors"
    [ testCase "token minting execs atticadm in deployment/nix-cache through the session" $
        makeTokenArguments session defaultTokenRequest
          @?= session
            <> ["--request-timeout=10s", "-n", "nagare-system", "exec", "deployment/nix-cache", "--"]
            <> ["atticadm", "-f", "/config/server.toml", "make-token", "--sub", "operator-push", "--validity", "1h", "--pull", "nagare-cache", "--push", "nagare-cache"]
    , testCase "the forward binds 127.0.0.1:18080, the one loopback host the server admits" $
        portForwardArguments session
          @?= session <> ["-n", "nagare-system", "port-forward", "--address", "127.0.0.1", "service/nix-cache", "18080:80"]
    , testCase "push names the private configuration's server" $
        pushArguments "nagare-cache" [storePathA, storePathB] @?= ["push", "nagare:nagare-cache", storePathA, storePathB]
    , testCase "the cache configuration URL and the client configuration bytes" $ do
        cacheConfigUrl forwardEndpoint cacheName @?= "http://127.0.0.1:18080/_api/v1/cache-config/nagare-cache"
        renderClientConfig forwardEndpoint "/tmp/p\"q/token"
          @?= "default-server = \"nagare\"\n\n[servers.nagare]\nendpoint = \"http://127.0.0.1:18080/\"\ntoken-file = \"/tmp/p\\\"q/token\"\n"
    , testCase "an external endpoint gains a trailing slash and refuses spaces and quotes" $ do
        normalizeEndpoint "https://cache.example.com/team" @?= Right "https://cache.example.com/team/"
        normalizeEndpoint "http://127.0.0.1:18080/" @?= Right "http://127.0.0.1:18080/"
        normalizeEndpoint "ftp://cache" @?= Left (InvalidEndpoint "ftp://cache")
        normalizeEndpoint "https://a b/" @?= Left (InvalidEndpoint "https://a b/")
    ]

-- * Validation

validationTests :: TestTree
validationTests =
  testGroup
    "subject, validity and context"
    [ testCase "validity accepts Attic durations up to 24h" $ do
        validitySeconds "15m" @?= Right 900
        validitySeconds "1h" @?= Right 3600
        validitySeconds "1h 30m" @?= Right 5400
        validitySeconds "2h30m" @?= Right 9000
        validateTokenRequest (TokenRequest "operator-push" "24h") @?= Right ()
    , testCase "validity over 24h, zero, empty or with an unknown unit is refused" $ do
        validateTokenRequest (TokenRequest "operator-push" "25h") @?= Left (InvalidValidity "25h" "exceeds 24h")
        validateTokenRequest (TokenRequest "operator-push" "1d 1s") @?= Left (InvalidValidity "1d 1s" "exceeds 24h")
        validateTokenRequest (TokenRequest "operator-push" "0s") @?= Left (InvalidValidity "0s" "must be positive")
        assertLeft (validateTokenRequest (TokenRequest "operator-push" ""))
        assertLeft (validateTokenRequest (TokenRequest "operator-push" "1y"))
        assertLeft (validateTokenRequest (TokenRequest "operator-push" "h"))
    , testCase "a subject outside [A-Za-z0-9._-] is refused" $ do
        validateTokenRequest (TokenRequest "kotei.build-1_x" "1h") @?= Right ()
        validateTokenRequest (TokenRequest "a b" "1h") @?= Left (InvalidSubject "a b")
        validateTokenRequest (TokenRequest "" "1h") @?= Left (InvalidSubject "")
        validateTokenRequest (TokenRequest "x;rm" "1h") @?= Left (InvalidSubject "x;rm")
    , testCase "a local context is refused: the cache is cloud-only" $ do
        requireCloudContext Local @?= Left LocalContext
        requireCloudContext Cloud @?= Right ()
        renderProducerError LocalContext @?= "the Nix cache is a cloud-only component and is unavailable for local contexts"
    ]

assertLeft :: (Show b) => Either a b -> IO ()
assertLeft = either (const (pure ())) (\value -> assertFailure ("expected a refusal, got " <> show value))

-- * Token

tokenTests :: TestTree
tokenTests =
  testGroup
    "nix-cache token"
    [ testCase "the token lands trimmed in a new mode-0600 file" $ withWorld $ \world -> do
        let destination = world ^. #scratchRoot </> "token"
        mintToken (fakeOps world) defaultTokenRequest destination >>= (@?= Right ())
        BS.readFile destination >>= (@?= token)
        mode <- fileMode <$> getFileStatus destination
        intersectFileModes mode 0o777 @?= ownerReadMode `unionFileModes` ownerWriteMode
        recorded world >>= (@?= [Connection, Kubectl (makeTokenArguments session defaultTokenRequest)])
    , testCase "an existing destination is refused untouched, before anything is minted" $ withWorld $ \world -> do
        let destination = world ^. #scratchRoot </> "token"
        BS.writeFile destination "keep"
        mintToken (fakeOps world) defaultTokenRequest destination >>= (@?= Left (TokenDestinationExists destination))
        BS.readFile destination >>= (@?= "keep")
        recorded world >>= (@?= [])
    , testCase "an invalid request contacts no cluster" $ withWorld $ \world -> do
        mintToken (fakeOps world) (TokenRequest "a b" "1h") (world ^. #scratchRoot </> "token") >>= (@?= Left (InvalidSubject "a b"))
        recorded world >>= (@?= [])
    ]

-- * Forward

forwardTests :: TestTree
forwardTests =
  testGroup
    "nix-cache forward"
    [ testCase "a bound 127.0.0.1:18080 is refused before kubectl starts" $ withWorld $ \world -> do
        writeIORef (world ^. #busy) True
        result <- withForward (fakeOps world) (const (pure ()))
        void result @?= Left PortBusy
        recorded world >>= (@?= [])
    , testCase "readiness waits for Attic's page, then reads the public key; the child is stopped on success" $ withWorld $ \world -> do
        writeIORef (world ^. #readyAfter) 3
        result <- withForward (fakeOps world) (\forwarded -> pure (forwarded ^. #endpoint, forwarded ^. #cache, forwarded ^. #publicKey))
        result @?= Right (forwardEndpoint, cacheName, "nagare-cache:5VtCsl3sx0Vs1Wl1ZbkWWRkn8yBIsK8Ex5uT3NEWbis=")
        calls' <- recorded world
        calls'
          @?= [Connection, Spawn (portForwardArguments session)]
            <> replicate 4 (Fetch "http://127.0.0.1:18080/")
            <> [Fetch (cacheConfigUrl forwardEndpoint cacheName)]
        readIORef (world ^. #stops) >>= (@?= 1)
    , testCase "readiness gives up after 30 attempts and stops the child" $ withWorld $ \world -> do
        writeIORef (world ^. #readyAfter) 1000
        result <- withForward (fakeOps world) (const (pure ()))
        void result @?= Left (ForwardNotReady "error: lost connection to pod")
        fetches <- length . filter (== Fetch "http://127.0.0.1:18080/") <$> recorded world
        fetches @?= 30
        readIORef (world ^. #stops) >>= (@?= 1)
    , testCase "a port-forward that dies names its last stderr line and is stopped" $ withWorld $ \world -> do
        writeIORef (world ^. #childExit) (Just (ExitFailure 1))
        result <- withForward (fakeOps world) (const (pure ()))
        void result @?= Left (ForwardDied "error: lost connection to pod")
        readIORef (world ^. #stops) >>= (@?= 1)
    , testCase "an asynchronous exception in the caller stops the child" $ withWorld $ \world -> do
        entered <- newEmptyMVar
        finished <- newEmptyMVar
        thread <- forkIO (void (withForward (fakeOps world) (\_ -> putMVar entered () >> threadDelay 10000000)) `finally` putMVar finished ())
        takeMVar entered
        killThread thread
        takeMVar finished
        readIORef (world ^. #stops) >>= (@?= 1)
    ]

-- * Push

pushTests :: TestTree
pushTests =
  testGroup
    "nix-cache push"
    [ testCase "a relative, a non-store and a missing path are refused with no cluster contact" $ withWorld $ \world -> do
        let ops = fakeOps world
        pushPaths ops ContextCache ("nix/store/x-y" :| []) >>= (@?= Left (NotAStorePath "nix/store/x-y")) . void'
        pushPaths ops ContextCache ("/tmp/result" :| []) >>= (@?= Left (NotAStorePath "/tmp/result")) . void'
        pushPaths ops ContextCache (storePathA <> "/bin/hello" :| []) >>= (@?= Left (NotAStorePath (storePathA <> "/bin/hello"))) . void'
        let missing = "/nix/store/00000000000000000000000000000000-missing"
        pushPaths ops ContextCache (storePathA :| [missing]) >>= (@?= Left (MissingStorePath missing "error: path is not valid")) . void'
        calls' <- recorded world
        filter isCluster calls' @?= []
        listDirectory (world ^. #scratchRoot) >>= (@?= [])
    , testCase "context mode mints, forwards and pushes, in that order, and removes its private directory" $ withWorld $ \world -> do
        result <- pushPaths (fakeOps world) ContextCache (storePathA :| [storePathB])
        result @?= Right (Pushed forwardEndpoint cacheName [storePathA, storePathB] ExitSuccess)
        calls' <- recorded world
        let kinds = [kind | call <- calls', Just kind <- [classify call]]
        kinds @?= ["mint", "forward", "push"]
        [arguments | Attic _ arguments <- calls'] @?= [pushArguments cacheName [storePathA, storePathB]]
        [arguments | Kubectl arguments <- calls'] @?= [makeTokenArguments session pushTokenRequest]
        pushTokenRequest @?= TokenRequest "operator-push" "15m"
        [config] <- readIORef (world ^. #configs)
        [home] <- pure [home | Attic home _ <- calls']
        let directory = take (length home - length ("/config" :: String)) home
        config @?= TE.encodeUtf8 (renderClientConfig forwardEndpoint (directory </> "token"))
        readIORef (world ^. #stops) >>= (@?= 1)
        listDirectory (world ^. #scratchRoot) >>= (@?= [])
    , testCase "external mode contacts no cluster and reads the token only through the client" $ withWorld $ \world -> do
        let tokenFile = world ^. #scratchRoot </> "operator.token"
        BS.writeFile tokenFile token
        result <- pushPaths (fakeOps world) (ExternalCache "https://cache.example.com/team" tokenFile "team") (storePathA :| [])
        result @?= Right (Pushed "https://cache.example.com/team/" "team" [storePathA] ExitSuccess)
        calls' <- recorded world
        filter isCluster calls' @?= []
        readIORef (world ^. #configs) >>= (@?= [TE.encodeUtf8 (renderClientConfig "https://cache.example.com/team/" tokenFile)])
        listDirectory (world ^. #scratchRoot) >>= (@?= ["operator.token"])
    , testCase "external mode refuses a missing token file and a bad cache name" $ withWorld $ \world -> do
        let tokenFile = world ^. #scratchRoot </> "absent.token"
        pushPaths (fakeOps world) (ExternalCache "https://cache.example.com/" tokenFile "team") (storePathA :| []) >>= (@?= Left (TokenFileMissing tokenFile)) . void'
        pushPaths (fakeOps world) (ExternalCache "https://cache.example.com/" tokenFile "-team") (storePathA :| []) >>= (@?= Left (InvalidCacheName "-team")) . void'
    , testCase "a failed push keeps the client's exit code and removes the private directory" $ withWorld $ \world -> do
        writeIORef (world ^. #atticExit) (ExitFailure 1)
        result <- pushPaths (fakeOps world) ContextCache (storePathA :| [])
        fmap (^. #exit) result @?= Right (ExitFailure 1)
        readIORef (world ^. #stops) >>= (@?= 1)
        listDirectory (world ^. #scratchRoot) >>= (@?= [])
    , testCase "an interruption during the push removes the private directory and stops the forward" $ withWorld $ \world -> do
        gate <- newEmptyMVar
        writeIORef (world ^. #atticGate) (Just gate)
        finished <- newEmptyMVar
        thread <- forkIO (void (pushPaths (fakeOps world) ContextCache (storePathA :| [])) `finally` putMVar finished ())
        takeMVar (world ^. #atticEntered)
        entries <- listDirectory (world ^. #scratchRoot)
        assertBool "the private directory exists during the push" (length entries == 1)
        killThread thread
        takeMVar finished
        readIORef (world ^. #stops) >>= (@?= 1)
        listDirectory (world ^. #scratchRoot) >>= (@?= [])
    ]
  where
    classify = \case
      Kubectl _ -> Just ("mint" :: Text)
      Spawn _ -> Just "forward"
      Attic _ _ -> Just "push"
      _ -> Nothing

void' :: Either ProducerError Pushed -> Either ProducerError ()
void' = fmap (const ())

-- * No token leak

leakTests :: TestTree
leakTests =
  testGroup
    "the token stays in its file"
    [ testCase "no argv, client environment, stdout, stderr or trace document carries the token" $ withWorld $ \world -> do
        let traceFile = world ^. #scratchRoot </> "trace.json"
            outFile = world ^. #scratchRoot </> "stdout"
            errFile = world ^. #scratchRoot </> "stderr"
            tokenFile = world ^. #scratchRoot </> "minted.token"
        (minted, pushed) <-
          captured outFile errFile . traced traceFile $ do
            minted <- mintToken (fakeOps world) defaultTokenRequest tokenFile
            pushed <- pushPaths (fakeOps world) ContextCache (storePathA :| [])
            pure (minted, pushed)
        minted @?= Right ()
        void' pushed @?= Right ()
        BS.readFile tokenFile >>= (@?= token)
        calls' <- recorded world
        let argv = concat ([arguments | Kubectl arguments <- calls'] <> [arguments | Spawn arguments <- calls'] <> [arguments | Attic _ arguments <- calls'])
            homes = [home | Attic home _ <- calls']
        assertBool "a token in argv" (not (any (BS.isInfixOf token . BC.pack) argv))
        assertBool "a token in the client environment" (not (any (BS.isInfixOf token . BC.pack) homes))
        readIORef (world ^. #configs) >>= assertBool "a token in the client configuration" . not . any (BS.isInfixOf token)
        BS.readFile outFile >>= assertBool "a token on stdout" . not . BS.isInfixOf token
        BS.readFile errFile >>= assertBool "a token on stderr" . not . BS.isInfixOf token
        doesFileExist traceFile >>= assertBool "no trace document was written"
        BS.readFile traceFile >>= assertBool "a token in the trace document" . not . BS.isInfixOf token
    ]

-- | The action under 'withCommandTrace' with only @NAGARE_TRACE_FILE@.
traced :: FilePath -> IO a -> IO a
traced path action = do
  previous <- lookupEnv "NAGARE_TRACE_FILE"
  setEnv "NAGARE_TRACE_FILE" path
  withCommandTrace "NixCachePush" action `finally` maybe (unsetEnv "NAGARE_TRACE_FILE") (setEnv "NAGARE_TRACE_FILE") previous

-- | The process's stdout and stderr redirected into files while @action@ runs.
captured :: FilePath -> FilePath -> IO a -> IO a
captured outFile errFile action =
  bracket
    (hFlush stdout >> hFlush stderr >> (,) <$> hDuplicate stdout <*> hDuplicate stderr)
    (\(out, err) -> hFlush stdout >> hFlush stderr >> hDuplicateTo out stdout >> hDuplicateTo err stderr)
    ( \_ ->
        withFile' outFile $ \outHandle -> withFile' errFile $ \errHandle -> do
          hDuplicateTo outHandle stdout
          hDuplicateTo errHandle stderr
          result <- try @SomeException action
          hFlush stdout >> hFlush stderr
          either (fail . show) pure result
    )
  where
    withFile' path = bracket (openFile path AppendMode) hClose
