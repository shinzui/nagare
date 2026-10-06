-- | Process responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Process
  ( runConfig
  , runConfigWith
  , runConfigUntil
  )
where

import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay, tryPutMVar)
import Control.Exception (IOException, onException, throwIO, try)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Nagare.Dsl.Load.Error
  ( ConfigTimeout (..)
  , LoadError (..)
  , defaultConfigTimeout
  )
import Nagare.Dsl.Prelude
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.IO (hClose, hGetContents')
import System.Posix.Signals (sigKILL, signalProcessGroup)
import System.Process (CreateProcess (..), StdStream (CreatePipe), getPid, proc, waitForProcess, withCreateProcess)

-- | Compile-and-run a config-as-program source file with @runghc@ and capture
-- the JSON it prints on stdout, mapping every failure mode to a 'LoadError'.
--
-- The file is run with @runghc@ (the house @GHC2024@ edition, the exact
-- @nagare-dsl@ package exposed by the caller's GHC environment, and the
-- config's directory on the include path). Do not add a name-only @-package
-- nagare-dsl@ flag here: it can expose a second installed version alongside the
-- package-id selected by @GHC_ENVIRONMENT@.
-- The config must print its JSON via one of the @Nagare.Dsl.Config.emit*@
-- helpers; empty output means it never called one ('MissingBinding'). The
-- decoder that reads the captured bytes is chosen by the caller
-- ('decodeDeployment' or 'decodeStaticSite').
--
-- The run is bounded by 'defaultConfigTimeout'; use 'runConfigWith' to choose a
-- different budget.
runConfig :: FilePath -> IO (Either LoadError ByteString)
runConfig = runConfigWith defaultConfigTimeout

-- | 'runConfig' with an explicit time budget. A config that has not finished
-- when the budget expires is killed and reported as 'LoadTimedOut' rather than
-- blocking the caller forever.
runConfigWith :: ConfigTimeout -> FilePath -> IO (Either LoadError ByteString)
runConfigWith budget =
  runConfigUntil (threadDelay (budget ^. #seconds * 1_000_000)) (budget ^. #seconds)

-- | 'runConfigWith' with the budget's expiry as an action; the run is killed
-- when the action returns. 'runConfigWith' passes a delay. Tests pass an
-- action that returns once the config has reached a known state, so the kill
-- lands there under any load.
--
-- @runghc@ runs in its own process group, and expiry kills the whole group
-- with SIGKILL before anything waits on it. A config can ignore or delay
-- SIGTERM (2026-10-06: under load a gate waited 51 minutes on one that
-- survived the old SIGTERM cleanup), and anything it spawned would keep the
-- output pipes open. The caller must use the threaded RTS: 'waitForProcess'
-- blocks every thread of the non-threaded one.
runConfigUntil :: IO () -> Int -> FilePath -> IO (Either LoadError ByteString)
runConfigUntil expiry seconds' path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left (FileNotFound path))
    else do
      result <- try @IOException (runBounded expiry path)
      pure $ case result of
        Left ioErr -> Left (CompileError path (Text.pack (show ioErr)))
        Right Nothing -> Left (LoadTimedOut path seconds')
        Right (Just (ExitFailure _, _out, err)) -> Left (CompileError path (Text.pack err))
        Right (Just (ExitSuccess, out, _err))
          | null out -> Left (MissingBinding path)
          | otherwise -> Right (BC.pack out)

-- | Run the config, collecting its exit code, stdout and stderr, unless the
-- expiry returns first ('Nothing').
runBounded :: IO () -> FilePath -> IO (Maybe (ExitCode, String, String))
runBounded expiry path =
  withCreateProcess command $ \stdin' stdout' stderr' process -> case (stdin', stdout', stderr') of
    (Just input, Just output, Just errors) -> do
      hClose input
      outVar <- newEmptyMVar
      errVar <- newEmptyMVar
      readers <- traverse (\(handle, var) -> forkIO (try @IOException (hGetContents' handle) >>= putMVar var)) [(output, outVar), (errors, errVar)]
      outcome <- newEmptyMVar
      timer <- forkIO (expiry >> void (tryPutMVar outcome Nothing))
      collector <- forkIO $ do
        collected <- try @IOException $ do
          out <- takeMVar outVar >>= either throwIO pure
          err <- takeMVar errVar >>= either throwIO pure
          exit <- waitForProcess process
          pure (exit, out, err)
        void (tryPutMVar outcome (Just collected))
      -- Kill first: the readers and the collector end when the pipes close. A
      -- group that already exited makes the signal fail, which is fine.
      let stop = do
            getPid process >>= traverse_ (void . try @IOException . signalProcessGroup sigKILL)
            traverse_ killThread (timer : collector : readers)
      finished <- takeMVar outcome `onException` stop
      killThread timer
      case finished of
        Nothing -> stop >> pure Nothing
        Just (Left ioErr) -> throwIO ioErr
        Just (Right collected) -> pure (Just collected)
    _ -> ioError (userError "runghc started without its pipes")
  where
    command =
      (proc "runghc" ["--ghc-arg=-XGHC2024", "-i" <> takeDirectory path, path])
        { std_in = CreatePipe
        , std_out = CreatePipe
        , std_err = CreatePipe
        , create_group = True
        }
