-- | Gate slots (EP-200). Every gate run builds and tests its commit in a kept,
-- detached worktree that only gates use, so another session's edits, builds
-- and commits in the shared checkout cannot turn it red or cost it its
-- record. The worktree and its @dist-newstyle@ directories stay between runs,
-- so a run compiles only what changed since the slot's previous run. There
-- are 'slotCount' slots; a gate that finds them all taken waits.
module Nagare.Harness.Slot
  ( Slot (..)
  , runningRevisions
  , slotCount
  , slotsDirectory
  , withRunMarker
  , withSlot
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, bracket_, throwIO, try)
import Control.Monad (void)
import Data.Generics.Labels ()
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Nagare.Harness.Prelude
import System.Directory (XdgDirectory (XdgState), createDirectory, createDirectoryIfMissing, doesDirectoryExist, getXdgDirectory, listDirectory, removeDirectoryRecursive, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hFlush, readFile', stdout)
import System.Process (getCurrentPid, readProcessWithExitCode)
import Text.Read (readMaybe)

-- | A slot this run holds: its number and the worktree the gate runs in.
data Slot = Slot
  { number :: !Int
  , tree :: !FilePath
  }
  deriving stock (Eq, Show, Generic)

-- | Both suites run one process per core (EP-184), so a third concurrent gate
-- would only slow the other two down.
slotCount :: Int
slotCount = 2

-- | @$XDG_STATE_HOME/nagare/gates/gate-slots@: @<n>/lock@ (a directory made
-- with @mkdir@, holding @pid@), @<n>/tree@ (the worktree) and @runs/<commit>@
-- (the pid of a full gate of that commit, waiting or running).
slotsDirectory :: IO FilePath
slotsDirectory = getXdgDirectory XdgState "nagare/gates/gate-slots"

-- | Take a free slot, check @commit@ out in its tree, run the action there,
-- and free the slot, also when the action throws. @checkout@ is any checkout
-- of the repository; only its git objects are used.
withSlot :: FilePath -> Text -> (Slot -> IO a) -> IO a
withSlot checkout commitId action = do
  base <- slotsDirectory
  bracket (acquire base) (release base) $ \slot -> do
    prepareTree checkout commitId slot
    action slot
  where
    acquire base = go (0 :: Int)
      where
        go waited = do
          taken <- firstFree base [1 .. slotCount]
          case taken of
            Just n -> pure Slot {number = n, tree = base </> show n </> "tree"}
            Nothing -> do
              when (waited `mod` 4 == 0) $ do
                putStrLn ("gate: all " <> show slotCount <> " gate slots are busy; waiting for one to finish")
                hFlush stdout
              threadDelay 15000000
              go (waited + 1)
    release base slot = void (try @IOException (removeDirectoryRecursive (base </> show (slot ^. #number) </> "lock")))

-- | The first slot whose lock this process could take. A lock whose holder is
-- gone (the gate was killed) is cleared and taken; a lock with no pid yet is
-- being taken by another gate.
firstFree :: FilePath -> [Int] -> IO (Maybe Int)
firstFree base = \case
  [] -> pure Nothing
  n : rest -> do
    let lock = base </> show n </> "lock"
    createDirectoryIfMissing True (base </> show n)
    took <- takeLock lock
    if took
      then pure (Just n)
      else do
        holder <- readPid (lock </> "pid")
        stale <- maybe (pure False) (fmap not . alive) holder
        if stale
          then do
            void (try @IOException (removeDirectoryRecursive lock))
            retook <- takeLock lock
            if retook then pure (Just n) else firstFree base rest
          else firstFree base rest
  where
    takeLock lock = do
      made <- try @IOException (createDirectory lock)
      case made of
        Left _ -> pure False
        Right () -> do
          pid <- getCurrentPid
          writeFile (lock </> "pid") (show pid)
          pure True

-- | Check @commit@ out in the slot's tree: a new detached worktree the first
-- time, otherwise a forced checkout and a clean that keeps the build output.
prepareTree :: FilePath -> Text -> Slot -> IO ()
prepareTree checkout commitId slot = do
  let path = slot ^. #tree
  exists <- doesDirectoryExist path
  reused <-
    if exists
      then do
        checkedOut <- git path ["checkout", "--quiet", "--detach", "--force", T.unpack commitId]
        case checkedOut of
          Right () -> do
            either (throwIO . userError) pure =<< git path ["clean", "-ffdxq", "-e", "dist-newstyle", "-e", ".ghc.environment.*"]
            pure True
          Left _ -> do
            -- Not a worktree any more (pruned or damaged): start it again.
            removeDirectoryRecursive path
            void (git checkout ["worktree", "prune"])
            pure False
      else pure False
  unless reused $
    either (throwIO . userError) pure =<< git checkout ["worktree", "add", "--quiet", "--detach", path, T.unpack commitId]
  where
    git directory arguments = do
      (code, _, err) <- readProcessWithExitCode "git" (["-C", directory] <> arguments) ""
      pure $ case code of
        ExitSuccess -> Right ()
        ExitFailure _ -> Left ("git " <> unwords arguments <> ": " <> err)

-- | Mark a full gate of @commit@ as waiting or running for the length of the
-- action, so a documentation commit landed meanwhile is covered by it
-- ('runningRevisions').
withRunMarker :: Text -> IO a -> IO a
withRunMarker commitId action = do
  base <- slotsDirectory
  let runs = base </> "runs"
      marker = runs </> T.unpack commitId
  createDirectoryIfMissing True runs
  pid <- getCurrentPid
  bracket_ (writeFile marker (show pid)) (void (try @IOException (removeFile marker))) action

-- | The commits whose full gate is waiting for a slot or running.
runningRevisions :: IO [Text]
runningRevisions = do
  base <- slotsDirectory
  let runs = base </> "runs"
  present <- doesDirectoryExist runs
  names <- if present then listDirectory runs else pure []
  fmap catMaybes . forM names $ \name -> do
    holder <- readPid (runs </> name)
    live <- maybe (pure False) alive holder
    pure (if live then Just (T.pack name) else Nothing)

readPid :: FilePath -> IO (Maybe Int)
readPid path = either (const Nothing) readMaybe <$> try @IOException (readFile' path)

-- | Whether a process is alive (@kill -0@).
alive :: Int -> IO Bool
alive pid = do
  (code, _, _) <- readProcessWithExitCode "kill" ["-0", show pid] ""
  pure (code == ExitSuccess)
