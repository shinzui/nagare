-- | EP-226 M1: one guarded cluster session per command and Kubernetes context.
--
-- Admission reads the ambient kubeconfig once: it refuses a current context
-- other than the selected one (a mismatch is detected, never corrected), then
-- flattens the selected context into a private kubeconfig, so merged
-- @KUBECONFIG@ lists and referenced CA, certificate and key files become the
-- bytes the guard checked. The guard lists server nodes through that private
-- file and requires the sole server node to be the context's host. Every
-- request of the command then names the private file: a kubeconfig swapped
-- after admission cannot redirect it.
--
-- A session reuses its admission for 60 seconds. Renewal reads the ambient
-- kubeconfig again: changed bytes start a new generation, admitted afresh; the
-- same bytes behind a server node with another UID refuse, since the cluster
-- was replaced under its name. A refused admission is never kept, and leaves
-- the session unbound until an admission passes. An exec credential plugin
-- stays configuration: its tokens refresh as kubectl runs it.
--
-- A local context has no host to guard: its session binds the flattened
-- kubeconfig only.
module Nagare.Inventory.ClusterSession
  ( ClusterSession
  , SessionOps (..)
  , defaultSessionOps
  , renewalNanos
  , newClusterSession
  , closeClusterSession
  , sessionGuard
  , sessionConnection
  , sessionGeneration
  , invalidateClusterSession
  , withCommandClusterSessions
  , commandClusterSession
  , invalidateCommandClusterSessions
  , kubectlConnectionArguments
  , sessionKubeconfigArguments
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (IOException, bracket, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Nagare.Contract.Trace (CountCategory (CategoryGuard))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store.Counters (traceCount, tracePhase, traceProcess)
import Nagare.Ops.ClusterGuard (ClusterGuardInputs (..), clusterGuardVerdict, parseServerNodeIdentities)
import Nagare.Resource.Types (ContentDigest)
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files (ownerModes, ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
import System.Process (proc, readCreateProcessWithExitCode)

-- | How a session reaches kubectl and the clock; tests inject both.
data SessionOps = SessionOps
  { kubectl :: !([String] -> IO (Either Text ByteString))
  , clock :: !(IO Word64)
  }
  deriving stock (Generic)

defaultSessionOps :: SessionOps
defaultSessionOps = SessionOps runKubectl getMonotonicTimeNSec

-- | An admission is reused for at most this long.
renewalNanos :: Word64
renewalNanos = 60 * 1000000000

data ClusterSession = ClusterSession
  { kubeContext :: !Text
  , expectedNode :: !(Maybe Text)
  , ops :: !SessionOps
  , directory :: !FilePath
  , state :: !(MVar SessionState)
  }
  deriving stock (Generic)

-- | The last admitted binding outlives a refusal, so the identity it pinned
-- still judges the next admission; only invalidation clears it.
data SessionState = SessionState
  { generation :: !Int
  , binding :: !(Maybe Binding)
  , admitted :: !Bool
  }
  deriving stock (Generic)

data Binding = Binding
  { configDigest :: !ContentDigest
  , kubeconfig :: !FilePath
  , servers :: ![(Text, Text)]
  , admittedAt :: !Word64
  }
  deriving stock (Generic)

-- | A session for one context, unadmitted. @expected@ is the host whose node
-- must be the sole server node; 'Nothing' for a local context.
newClusterSession :: SessionOps -> Text -> Maybe Text -> IO ClusterSession
newClusterSession sessionOps context expected = do
  temporary <- getTemporaryDirectory
  path <- privateDirectory temporary (0 :: Int)
  ClusterSession context expected sessionOps path <$> newMVar (SessionState 0 Nothing False)
  where
    privateDirectory temporary attempt = do
      now <- getMonotonicTimeNSec
      let candidate = temporary </> ("nagare-session-" <> show now <> "-" <> show attempt)
      created <- try @IOException (createDirectory candidate)
      case created of
        Right () -> candidate <$ setFileMode candidate ownerModes
        Left failure
          | attempt < 8 -> privateDirectory temporary (attempt + 1)
          | otherwise -> ioError failure

-- | Remove the session's private kubeconfigs.
closeClusterSession :: ClusterSession -> IO ()
closeClusterSession session = void (try @IOException (removeDirectoryRecursive (session ^. #directory)))

-- | Admit the session, or reuse an admission younger than 'renewalNanos'.
-- Concurrent callers wait for one admission.
sessionGuard :: ClusterSession -> IO (Either Text ())
sessionGuard session = void <$> sessionConnection session

-- | The private kubeconfig the guard checked, admitting first when needed.
sessionConnection :: ClusterSession -> IO (Either Text FilePath)
sessionConnection session = modifyMVar (session ^. #state) $ \current -> do
  now <- session ^. #ops . #clock
  case current ^. #binding of
    Just bound
      | current ^. #admitted
      , now - bound ^. #admittedAt < renewalNanos -> do
          traceCount CategoryGuard "reused" 0
          pure (current, Right (bound ^. #kubeconfig))
    previous -> do
      outcome <- tracePhase "cluster guard" (admit session (current ^. #generation) previous)
      case outcome of
        Left reason -> do
          traceCount CategoryGuard "refused" 0
          -- Nothing refused is kept as admitted; whatever was observed under
          -- the old binding belongs to a generation that has ended.
          pure (SessionState (current ^. #generation + 1) previous False, Left reason)
        Right (next, bound) -> do
          traceCount CategoryGuard (maybe "admitted" (const "renewed") previous) 0
          pure (SessionState next (Just bound) True, Right (bound ^. #kubeconfig))

-- | The identity generation: it changes whenever the bound configuration
-- changes or the binding is dropped, so evidence keyed by an older one is stale.
sessionGeneration :: ClusterSession -> IO Int
sessionGeneration session = (^. #generation) <$> readMVar (session ^. #state)

-- | Drop the binding: the next request admits afresh, in a new generation.
-- For a command that activated a host or projected a kubeconfig.
invalidateClusterSession :: ClusterSession -> IO ()
invalidateClusterSession session =
  modifyMVar_ (session ^. #state) (\current -> pure (SessionState (current ^. #generation + 1) Nothing False))

admit :: ClusterSession -> Int -> Maybe Binding -> IO (Either Text (Int, Binding))
admit session current previous = do
  ambient <- if isJust expected then ambientContext else pure (Right context)
  case ambient of
    Left reason -> pure (Left reason)
    Right observed
      | observed /= context -> pure (Left (refusal observed []))
      | otherwise -> do
          flattened <- run ["config", "view", "--flatten", "--minify", "--context", T.unpack context]
          case flattened of
            Left reason -> pure (Left (failure "flatten the selected Kubernetes context" reason))
            Right bytes -> do
              let digest = contentDigest bytes
                  sameConfig = fmap (^. #configDigest) previous == Just digest
                  next = if sameConfig then current else current + 1
                  path = maybe (session ^. #directory </> ("kubeconfig-" <> show next)) (^. #kubeconfig) (if sameConfig then previous else Nothing)
              written <- if sameConfig then pure (Right ()) else writePrivate path bytes
              case written of
                Left reason -> pure (Left (failure "write the private kubeconfig" reason))
                Right () -> do
                  observedServers <- maybe (pure (Right [])) (const (serverNodes path)) expected
                  now <- session ^. #ops . #clock
                  pure $ do
                    found <- observedServers
                    traverse_ (\host -> clusterGuardVerdict (ClusterGuardInputs context observed host (sort (map fst found)))) expected
                    when
                      (sameConfig && fmap (^. #servers) previous /= Just (sort found))
                      (Left (refusal observed (map fst found) <> "\nthe server node was replaced under the same kubeconfig"))
                    Right (next, Binding digest path (sort found) now)
  where
    context = session ^. #kubeContext
    expected = session ^. #expectedNode
    run = session ^. #ops . #kubectl
    ambientContext = do
      result <- run ["config", "current-context"]
      pure $ case T.strip . T.pack . BC.unpack <$> result of
        Left reason -> Left (failure "read the current Kubernetes context" reason)
        Right current'
          | T.null current' -> Left (failure "read the current Kubernetes context" "kubectl returned an empty context")
          | otherwise -> Right current'
    serverNodes path = do
      listed <- run ["--kubeconfig", path, "--context", T.unpack context, "get", "nodes", "-o", "json", "--request-timeout=10s"]
      pure (either (Left . failure "list Kubernetes nodes") (either (Left . failure "interpret Kubernetes nodes") Right . parseServerNodeIdentities) listed)
    refusal observed nodes =
      either id (const "cluster guard: refusing Kubernetes access") (clusterGuardVerdict (ClusterGuardInputs context observed (fromMaybe "" expected) nodes))
    failure action reason =
      "cluster guard: could not "
        <> action
        <> ": "
        <> reason
        <> ". Selected context '"
        <> context
        <> "'"
        <> maybe "" (\host -> " expects server node '" <> host <> "'") expected
        <> ".\nfix: run 'nagarectl kubeconfig fetch --context "
        <> context
        <> "', export that file as KUBECONFIG, and retry"

writePrivate :: FilePath -> ByteString -> IO (Either Text ())
writePrivate path bytes = first (T.pack . show) <$> try @IOException (BS.writeFile path bytes >> setFileMode path (ownerReadMode `unionFileModes` ownerWriteMode))

runKubectl :: [String] -> IO (Either Text ByteString)
runKubectl arguments = do
  result <- traceProcess "kubectl" (try @IOException (readCreateProcessWithExitCode (proc "kubectl" arguments) ""))
  pure $ case result of
    Left err -> Left ("could not start kubectl: " <> T.pack (show err))
    Right (ExitSuccess, output, _) -> Right (BC.pack output)
    Right (ExitFailure code, _, errors) ->
      Left ("kubectl " <> T.pack (unwords (take 2 arguments)) <> " exited " <> T.pack (show code) <> diagnostic errors)
  where
    diagnostic errors
      | T.null (T.strip (T.pack errors)) = ""
      | otherwise = ": " <> T.strip (T.pack errors)

-- * The command's sessions

-- | The sessions of the running command, by Kubernetes context; 'Nothing'
-- outside 'withCommandClusterSessions'. Like the command trace, the command
-- installs it once at dispatch.
commandSessions :: IORef (Maybe (MVar (Map Text ClusterSession)))
commandSessions = unsafePerformIO (newIORef Nothing)
{-# NOINLINE commandSessions #-}

-- | Run a command with its own sessions, removing their private files at the
-- end. A nested call shares the outer command's sessions.
withCommandClusterSessions :: IO a -> IO a
withCommandClusterSessions body =
  readIORef commandSessions >>= \case
    Just _ -> body
    Nothing ->
      bracket
        (newMVar Map.empty >>= \sessions -> sessions <$ writeIORef commandSessions (Just sessions))
        (\sessions -> writeIORef commandSessions Nothing >> readMVar sessions >>= mapM_ closeClusterSession)
        (const body)

-- | The command's session for a context, created on first use; 'Nothing'
-- outside a command. A context guarded against another host is refused rather
-- than shared.
commandClusterSession :: SessionOps -> Text -> Maybe Text -> IO (Maybe (Either Text ClusterSession))
commandClusterSession sessionOps context expected =
  readIORef commandSessions >>= \case
    Nothing -> pure Nothing
    Just sessions -> fmap Just . modifyMVar sessions $ \known -> case Map.lookup context known of
      Just session
        | session ^. #expectedNode == expected -> pure (known, Right session)
        | otherwise -> pure (known, Left ("cluster guard: context '" <> context <> "' is already guarded against another host in this command"))
      Nothing -> do
        session <- newClusterSession sessionOps context expected
        pure (Map.insert context session known, Right session)

-- | Drop every binding of the running command: after a host activation or a
-- kubeconfig projection, the next request admits afresh.
invalidateCommandClusterSessions :: IO ()
invalidateCommandClusterSessions =
  readIORef commandSessions >>= \case
    Nothing -> pure ()
    Just sessions -> readMVar sessions >>= mapM_ invalidateClusterSession

-- | The connection arguments of a request to @context@: the command session's
-- private kubeconfig when it has one, admitted or renewed first, or the bare
-- context outside a session. A session that cannot admit refuses the request.
kubectlConnectionArguments :: Text -> IO (Either Text [String])
kubectlConnectionArguments context = fmap (<> ["--context", T.unpack context]) <$> sessionKubeconfigArguments context

-- | Only the @--kubeconfig@ arguments, for a program (Helm, a port-forward)
-- that names its context itself: none outside a session.
sessionKubeconfigArguments :: Text -> IO (Either Text [String])
sessionKubeconfigArguments context =
  readIORef commandSessions >>= \case
    Nothing -> pure (Right [])
    Just sessions ->
      Map.lookup context <$> readMVar sessions >>= \case
        Nothing -> pure (Right [])
        Just session -> fmap (\path -> ["--kubeconfig", path]) <$> sessionConnection session
