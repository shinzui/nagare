-- | EP-226 M1: a command's guarded cluster session, over a fake kubectl and
-- clock. The fake answers the ambient kubeconfig's current context and
-- flattened view, and lists server nodes only through the private file it was
-- given, as the bytes in that file name them.
module ClusterSessionSpec (clusterSessionTests) where

import Control.Concurrent.Async (replicateConcurrently)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Data.Word (Word64)
import Nagare.Dsl.Prelude
import Nagare.Inventory.ClusterSession
import System.Directory (doesDirectoryExist)
import System.FilePath (takeDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

clusterSessionTests :: TestTree
clusterSessionTests =
  testGroup
    "ClusterSession (EP-226 M1)"
    [ testCase "concurrent callers share one admission: one context read, one flatten, one node list" $ do
        world <- newWorld
        session <- newClusterSession (fakeOps world) "intranet" (Just "nagare-01")
        results <- replicateConcurrently 16 (sessionGuard session)
        assertBool "a caller was refused" (all isRight results)
        verbs world >>= (@?= [["config", "current-context"], ["config", "view"], ["get", "nodes"]])
        closeClusterSession session
    , testCase "a request names the bytes that passed the guard, whatever the ambient kubeconfig becomes" $ do
        world <- newWorld
        session <- newClusterSession (fakeOps world) "intranet" (Just "nagare-01")
        path <- sessionConnection session >>= either (fail . T.unpack) pure
        writeIORef (world ^. #ambient) (kubeconfigFor "https://elsewhere:6443")
        again <- sessionConnection session >>= either (fail . T.unpack) pure
        again @?= path
        BS.readFile path >>= (@?= kubeconfigFor "https://10.0.0.1:6443")
        length <$> verbs world >>= (@?= 3)
        closeClusterSession session
    , testCase "after 60 seconds the same bytes renew in place; changed bytes are a new generation, admitted afresh" $ do
        world <- newWorld
        session <- newClusterSession (fakeOps world) "intranet" (Just "nagare-01")
        first' <- sessionConnection session >>= either (fail . T.unpack) pure
        generation <- sessionGeneration session
        advance world 61
        renewed <- sessionConnection session >>= either (fail . T.unpack) pure
        renewed @?= first'
        sessionGeneration session >>= (@?= generation)
        length <$> verbs world >>= (@?= 6)
        writeIORef (world ^. #ambient) (kubeconfigFor "https://10.0.0.9:6443")
        advance world 61
        moved <- sessionConnection session >>= either (fail . T.unpack) pure
        assertBool "a changed kubeconfig reused the old file" (moved /= first')
        BS.readFile moved >>= (@?= kubeconfigFor "https://10.0.0.9:6443")
        sessionGeneration session >>= (@?= generation + 1)
        closeClusterSession session
    , testCase "a server node replaced under the same kubeconfig refuses, and keeps refusing in the command" $ do
        world <- newWorld
        session <- newClusterSession (fakeOps world) "intranet" (Just "nagare-01")
        _ <- sessionConnection session >>= either (fail . T.unpack) pure
        writeIORef (world ^. #nodes) [("nagare-01", "uid-2")]
        advance world 61
        refused <- sessionGuard session
        assertBool "a replaced node was admitted" (either ("replaced" `T.isInfixOf`) (const False) refused)
        retried <- sessionGuard session
        assertBool "a retry admitted the replaced node" (either ("replaced" `T.isInfixOf`) (const False) retried)
        -- A host activation legitimately replaces it: invalidation clears the
        -- pinned identity, and the next admission is a new generation.
        before <- sessionGeneration session
        invalidateClusterSession session
        sessionGuard session >>= (@?= Right ())
        sessionGeneration session >>= assertBool "invalidation kept the generation" . (> before)
        closeClusterSession session
    , testCase "an ambient context other than the selected one refuses before any flatten" $ do
        world <- newWorld
        writeIORef (world ^. #current) "staging"
        session <- newClusterSession (fakeOps world) "intranet" (Just "nagare-01")
        refused <- sessionGuard session
        assertBool "a mismatched context was admitted" (either ("'staging', not the selected Nagare context 'intranet'" `T.isInfixOf`) (const False) refused)
        verbs world >>= (@?= [["config", "current-context"]])
        closeClusterSession session
    , testCase "a refused admission is not kept: the next request is guarded again" $ do
        world <- newWorld
        writeIORef (world ^. #nodes) [("impostor", "uid-9")]
        session <- newClusterSession (fakeOps world) "intranet" (Just "nagare-01")
        refused <- sessionConnection session
        assertBool "an impostor node was admitted" (either ("impostor" `T.isInfixOf`) (const False) refused)
        writeIORef (world ^. #nodes) [("nagare-01", "uid-1")]
        sessionGuard session >>= (@?= Right ())
        length <$> verbs world >>= (@?= 6)
        closeClusterSession session
    , testCase "a local session binds the flattened kubeconfig and guards no host" $ do
        world <- newWorld
        session <- newClusterSession (fakeOps world) "local" Nothing
        sessionGuard session >>= (@?= Right ())
        verbs world >>= (@?= [["config", "view"]])
        closeClusterSession session
    , testCase "outside a command a request names its context; inside, the session's file, removed at the end" $ do
        world <- newWorld
        kubectlConnectionArguments "intranet" >>= (@?= Right ["--context", "intranet"])
        directory <- withCommandClusterSessions $ do
          created <- commandClusterSession (fakeOps world) "intranet" (Just "nagare-01")
          session <- maybe (assertFailure "no command session" >> fail "") (either (fail . T.unpack) pure) created
          arguments <- kubectlConnectionArguments "intranet"
          path <- sessionConnection session >>= either (fail . T.unpack) pure
          arguments @?= Right ["--kubeconfig", path, "--context", "intranet"]
          sessionKubeconfigArguments "intranet" >>= (@?= Right ["--kubeconfig", path])
          -- Another host for the same context in one command is refused.
          other <- commandClusterSession (fakeOps world) "intranet" (Just "nagare-02")
          assertBool "a second host shared the session" (maybe False (either ("another host" `T.isInfixOf`) (const False)) other)
          pure (takeDirectory path)
        doesDirectoryExist directory >>= assertBool "the private kubeconfig outlived the command" . not
        kubectlConnectionArguments "intranet" >>= (@?= Right ["--context", "intranet"])
    , testCase "a request inside a command whose session refuses is refused, not sent with the ambient kubeconfig" $ do
        world <- newWorld
        writeIORef (world ^. #nodes) [("impostor", "uid-9")]
        withCommandClusterSessions $ do
          _ <- commandClusterSession (fakeOps world) "intranet" (Just "nagare-01")
          refused <- kubectlConnectionArguments "intranet"
          assertBool "a refused session yielded connection arguments" (either ("impostor" `T.isInfixOf`) (const False) refused)
    ]

-- * The fake kubectl and clock

data World = World
  { current :: !(IORef Text)
  , ambient :: !(IORef ByteString)
  , nodes :: !(IORef [(Text, Text)])
  , calls :: !(IORef [[String]])
  , now :: !(IORef Word64)
  }
  deriving stock (Generic)

newWorld :: IO World
newWorld =
  World
    <$> newIORef "intranet"
    <*> newIORef (kubeconfigFor "https://10.0.0.1:6443")
    <*> newIORef [("nagare-01", "uid-1")]
    <*> newIORef []
    <*> newIORef 1

fakeOps :: World -> SessionOps
fakeOps world = SessionOps answer (readIORef (world ^. #now))
  where
    answer arguments = do
      atomicModifyIORef' (world ^. #calls) (\seen -> (seen <> [arguments], ()))
      case arguments of
        ["config", "current-context"] -> Right . BC.pack . T.unpack <$> readIORef (world ^. #current)
        "config" : "view" : _ -> Right <$> readIORef (world ^. #ambient)
        "--kubeconfig" : path : "--context" : _ : "get" : "nodes" : _ -> do
          -- The private file must exist and hold a flattened kubeconfig.
          bytes <- BS.readFile path
          if "clusters" `BS.isInfixOf` bytes
            then Right . nodeList <$> readIORef (world ^. #nodes)
            else pure (Left "the private kubeconfig is not one")
        other -> pure (Left ("unexpected kubectl " <> T.pack (unwords other)))

-- | The verbs the fake answered, without paths or contexts.
verbs :: World -> IO [[String]]
verbs world = map verb <$> readIORef (world ^. #calls)
  where
    verb = \case
      "--kubeconfig" : _ : "--context" : _ : rest -> take 2 rest
      other -> take 2 other

advance :: World -> Word64 -> IO ()
advance world seconds = modifyIORef' (world ^. #now) (+ seconds * 1000000000)

kubeconfigFor :: Text -> ByteString
kubeconfigFor server = BC.pack ("apiVersion: v1\nclusters:\n- cluster:\n    server: " <> T.unpack server <> "\n  name: c\n")

nodeList :: [(Text, Text)] -> ByteString
nodeList servers =
  LBS.toStrict
    ( Aeson.encode
        ( Aeson.object
            [ "items"
                Aeson..= [ Aeson.object
                             [ "metadata"
                                 Aeson..= Aeson.object
                                   [ "name" Aeson..= name
                                   , "uid" Aeson..= uid
                                   , "labels" Aeson..= Aeson.object ["node-role.kubernetes.io/control-plane" Aeson..= ("true" :: Text)]
                                   ]
                             ]
                         | (name, uid) <- servers
                         ]
            ]
        )
    )
