-- | EP-214: one access command reaches the context's en through one forward,
-- one passing cluster guard and one capability check, while the owner
-- objects are still read at every phase and before every write.
module InventoryAccessSessionSpec (inventoryAccessSessionTests) where

import Control.Exception (ErrorCall (..), bracket, throwIO, try)
import Control.Monad (forM_)
import Data.Aeson (Value (..), encode, object, (.:), (.=))
import Data.Aeson.Types (parseMaybe, withObject)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import InventoryAccessSpec (accessBinding, context, teamBindings)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Access
import Nagare.Inventory.AccessRuntime
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Inventory.Store.Counters (collectCommandTrace)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import System.Directory (getPermissions, setOwnerExecutable, setPermissions)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

inventoryAccessSessionTests :: TestTree
inventoryAccessSessionTests =
  testGroup
    "reviewed access en session (EP-214)"
    [ testCase "one tuple's five phases share one forward, one guard and one capability check; owners are read every phase" $
        forM_ (("user: ", accessBinding True) : teamBindings) $ \(label, binding) -> do
          world <- newWorld
          (_, traced) <- collectCommandTrace . withSession world $ \en -> do
            ops <- accessRuntimeOpsWith en context
            driveAll ops binding
            counted world "close" >>= (@?= 0)
          -- EP-221: the command trace attributes the same work by phase.
          counts <- readIORef (world ^. #counts)
          let requests = sum (map (\name -> Map.findWithDefault 0 name counts) ["capability", "schema", "query", "write"])
          Map.map fst (traced ^. #phases)
            @?= Map.fromList [("en forward", 1), ("cluster guard", 1), ("owner read", 6 * owners binding), ("en request", requests)]
          readIORef (world ^. #counts)
            >>= ( @?=
                    expected
                      [ ("open", 1)
                      , ("close", 1)
                      , ("guard", 1)
                      , ("capability", 1)
                      , ("schema", if teamRelationship binding then 1 else 0)
                      , -- Five inspects and the write's re-read, each of every owner.
                        ("owner", 6 * owners binding)
                      , ("query", 5)
                      , ("write", 1)
                      ]
                )
          readIORef (world ^. #tuple) >>= assertBool (label <> "the tuple was not written") . isJust
    , testCase "a forward that exits between phases is reopened once and the phase succeeds" $ do
        world <- newWorld
        let binding = accessBinding True
            adapter ops = mkAccessAdapter Map.empty (Map.singleton (identity binding) binding) ops
            create = operation binding
        withSession world $ \en -> do
          ops <- accessRuntimeOpsWith en context
          prepared <- adapterPrepare (adapter ops) create >>= either (fail . show) pure
          adapterPreflight (adapter ops) create prepared >>= (@?= Right ())
          writeIORef (world ^. #running) False
          adapterExecute (adapter ops) create prepared >>= (@?= AdapterEffectCompleted)
          adapterVerify (adapter ops) create prepared >>= assertBool "verify refused" . isRight'
        counted world "open" >>= (@?= 2)
        counted world "close" >>= (@?= 2)
        counted world "capability" >>= (@?= 1)
    , testCase "a refused capability or guard is not remembered: the next phase asks again" $ do
        world <- newWorld
        writeIORef (world ^. #capabilityRefusals) 1
        writeIORef (world ^. #guardRefusals) 1
        let binding = accessBinding True
            create = operation binding
        withSession world $ \en -> do
          ops <- accessRuntimeOpsWith en context
          let adapter = mkAccessAdapter Map.empty (Map.singleton (identity binding) binding) ops
          adapterPrepare adapter create >>= \case
            Left (PrepareRefused _ reason) -> reason @?= "access context guard refused"
            other -> assertFailure ("a refused guard prepared: " <> show other)
          adapterPrepare adapter create >>= \case
            Left (PrepareRefused _ reason) -> reason @?= "access API capability observation refused"
            other -> assertFailure ("a refused capability prepared: " <> show other)
          prepared <- adapterPrepare adapter create >>= either (fail . show) pure
          adapterPreflight adapter create prepared >>= (@?= Right ())
        counted world "guard" >>= (@?= 2)
        counted world "capability" >>= (@?= 2)
        counted world "open" >>= (@?= 1)
    , testCase "a forward that never becomes ready is reported and retried by the next phase" $ do
        world <- newWorld
        writeIORef (world ^. #ready) False
        let binding = accessBinding True
        withSession world $ \en -> do
          ops <- accessRuntimeOpsWith en context
          accessInspect ops binding >>= (@?= Left "en port-forward did not become ready")
          accessInspect ops binding >>= (@?= Left "en port-forward did not become ready")
        counted world "open" >>= (@?= 2)
        counted world "close" >>= (@?= 0)
    , testCase "a missing key refuses before any forward starts" $
        forM_ [Nothing, Just ""] $ \key -> do
          world <- newWorld
          writeIORef (world ^. #key) key
          withSession world $ \en -> do
            ops <- accessRuntimeOpsWith en context
            accessInspect ops (accessBinding True) >>= (@?= Left "reviewed access requires private NAGARE_EN_API_KEY")
          counted world "open" >>= (@?= 0)
    , testCase "a session whose action throws stops its forward" $ do
        world <- newWorld
        thrown <-
          try $ withSession world $ \en -> do
            reached <- withEn en (\_ -> pure ())
            reached @?= Right ()
            throwIO (ErrorCall "command failed")
        thrown @?= (Left (ErrorCall "command failed") :: Either ErrorCall ())
        counted world "open" >>= (@?= 1)
        counted world "close" >>= (@?= 1)
        readIORef (world ^. #running) >>= (@?= False)
    , testCase "kubectl's forward: a wrong first line is not ready; a thrown command terminates the process" $
        withSystemTempDirectory "en-forward" $ \root -> do
          let pidFile = root </> "pid"
          withKubectl root ["echo 'error: unable to forward'"] $ do
            result <- withEnSession "access-test" (pure (Right ())) (\en -> withEn en (\_ -> pure ()))
            result @?= Left "en port-forward did not become ready"
          withKubectl root ["echo $$ > '" <> pidFile <> "'", "echo 'Forwarding from 127.0.0.1:9 -> 8080'", "exec sleep 60"] $ do
            thrown <-
              try $ withEnSession "access-test" (pure (Right ())) $ \en -> do
                _ <- withEn en (\_ -> pure ())
                pid <- readFile pidFile
                alive pid >>= (@?= True)
                throwIO (ErrorCall "command failed")
            thrown @?= (Left (ErrorCall "command failed") :: Either ErrorCall ())
            pid <- readFile pidFile
            alive pid >>= (@?= False)
    ]
  where
    identity binding = accessResource binding ^. #identity
    owners binding = length (accessAuth binding : maybeToList (accessRoute binding))
    expected = Map.fromList . filter ((> 0) . snd)
    isRight' = either (const False) (const True)
    alive pid = (\(code, _, _) -> code == ExitSuccess) <$> readProcessWithExitCode "sh" ["-c", "kill -0 " <> T.unpack (T.strip (T.pack pid))] ""

-- | Observe, prepare, preflight, execute and verify one create of a tuple.
driveAll :: AccessOps -> AccessBinding -> IO ()
driveAll ops binding = do
  let resource = accessResource binding ^. #identity
      adapter = mkAccessAdapter Map.empty (Map.singleton resource binding) ops
      create = operation binding
  observed <- adapterObserve adapter [resource] >>= either (fail . T.unpack) pure
  Map.lookup resource (observationMap observed) @?= Just (ConfirmedAbsent (contentDigest "access:absent"))
  prepared <- adapterPrepare adapter create >>= either (fail . show) pure
  adapterPreflight adapter create prepared >>= (@?= Right ())
  adapterExecute adapter create prepared >>= (@?= AdapterEffectCompleted)
  adapterVerify adapter create prepared >>= either (fail . T.unpack) (const (pure ()))

operation :: AccessBinding -> PlannedOperation
operation binding =
  PlannedOperation
    (either (error . show) id (mkOperationId "op-access"))
    CreateResource
    AccessExecutor
    (accessResource binding ^. #identity :| [])
    (contentDigest "review")
    []
    VerifyBeforeRetry

-- | A counting fake of one context: its forward, its en and its owner objects.
data World = World
  { counts :: !(IORef (Map.Map Text Int))
  , key :: !(IORef (Maybe String))
  , ready :: !(IORef Bool)
  , running :: !(IORef Bool)
  , capabilityRefusals :: !(IORef Int)
  , guardRefusals :: !(IORef Int)
  , tuple :: !(IORef (Maybe Value))
  }
  deriving stock (Generic)

newWorld :: IO World
newWorld =
  World
    <$> newIORef Map.empty
    <*> newIORef (Just "test-en-key")
    <*> newIORef True
    <*> newIORef False
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef Nothing

tick :: World -> Text -> IO ()
tick world name = modifyIORef' (world ^. #counts) (Map.insertWith (+) name 1)

counted :: World -> Text -> IO Int
counted world name = Map.findWithDefault 0 name <$> readIORef (world ^. #counts)

withSession :: World -> (EnTransport -> IO a) -> IO a
withSession world = withEnSessionUsing (forwarder world) (ownerObject world) (guardOf world)

forwarder :: World -> EnForwarder ()
forwarder world =
  EnForwarder
    { forwardKey = readIORef (world ^. #key)
    , startForward = do
        tick world "open"
        isReady <- readIORef (world ^. #ready)
        if isReady
          then writeIORef (world ^. #running) True >> pure (Right ((), "fake://en"))
          else pure (Left "en port-forward did not become ready")
    , forwardRunning = \() -> readIORef (world ^. #running)
    , stopForward = \() -> tick world "close" >> writeIORef (world ^. #running) False
    , forwardRequest = \_ _ -> fakeEn world
    }

refusingOnce :: IORef Int -> IO Bool
refusingOnce cell = atomicModifyIORef' cell (\left -> (max 0 (left - 1), left > 0))

guardOf :: World -> IO (Either Text ())
guardOf world = do
  tick world "guard"
  refused <- refusingOnce (world ^. #guardRefusals)
  pure (if refused then Left "cluster guard refused" else Right ())

-- | en's four requests. The stored tuple is whatever the last write sent.
fakeEn :: World -> EnCall
fakeEn world verb path body = case (verb, path) of
  ("GET", "/v1/openapi.json") -> do
    tick world "capability"
    refused <- refusingOnce (world ^. #capabilityRefusals)
    pure (Right (if refused then (503, "") else (200, json capabilities)))
  ("GET", "/v1/schema") -> do
    tick world "schema"
    pure (Right (200, json (object ["source" .= T.unwords teamSchemaDeclarations])))
  ("POST", "/v1/relationships/query?first=2") -> do
    tick world "query"
    stored <- readIORef (world ^. #tuple)
    pure (Right (200, json (object ["edges" .= [object ["node" .= node] | node <- maybeToList stored], "pageInfo" .= object ["hasNextPage" .= False]])))
  ("POST", "/v1/relationships") -> do
    tick world "write"
    writeIORef (world ^. #tuple) (parseMaybe (withObject "mutation" (.: "tuples")) body >>= \case [written] -> Just written; _ -> Nothing)
    pure (Right (200, json (object ["token" .= ("consistency-token" :: Text)])))
  _ -> pure (Left "unexpected en request")
  where
    json = LBS.toStrict . encode
    capabilities =
      object
        [ "components"
            .= object
              ["schemas" .= object ["WriteTuplesRequestWire" .= object ["properties" .= object ["preconditions" .= object [], "deletes" .= object []]]]]
        ]

-- | An owner object bound to the fixture context, as kubectl would print it.
ownerObject :: World -> ManagedResource -> IO (Either Text Value)
ownerObject world resource = do
  tick world "owner"
  pure $ case resource ^. #spec of
    NativeObject digest -> Right (document digest)
    KnativeService digest -> Right (document digest)
    _ -> Left "unexpected owner specification"
  where
    document digest =
      object
        [ "metadata"
            .= object
              [ "uid" .= ("uid-" <> resourceIdText (resource ^. #identity))
              , "annotations"
                  .= object
                    [ "nagare.dev/context-id" .= contextIdText (context ^. #identity)
                    , "nagare.dev/resource-id" .= resourceIdText (resource ^. #identity)
                    , "nagare.dev/spec-digest" .= digestText digest
                    ]
              ]
        ]

-- | Run with a @kubectl@ shim first on PATH and a private key set; both are
-- restored afterwards.
withKubectl :: FilePath -> [String] -> IO a -> IO a
withKubectl root body action = do
  let shim = root </> "kubectl"
  writeFile shim (unlines ("#!/bin/sh" : body))
  getPermissions shim >>= setPermissions shim . setOwnerExecutable True
  bracket
    ((,) <$> lookupEnv "PATH" <*> lookupEnv "NAGARE_EN_API_KEY")
    ( \(path, credential) -> do
        maybe (unsetEnv "PATH") (setEnv "PATH") path
        maybe (unsetEnv "NAGARE_EN_API_KEY") (setEnv "NAGARE_EN_API_KEY") credential
    )
    ( \(path, _) -> do
        setEnv "PATH" (root <> maybe "" (":" <>) path)
        setEnv "NAGARE_EN_API_KEY" "test-en-key"
        action
    )
