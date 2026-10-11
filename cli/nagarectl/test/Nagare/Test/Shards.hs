-- | The suite as parallel processes (EP-184). The test binary runs itself once
-- per processor. Each copy runs every n-th test in tree order, one thread at
-- a time, so no test observes another's process-global state: environment
-- variables, the working directory, or the executor's transaction variables.
-- A copy is selected by @NAGARE_SUITE_SHARD=i/n@. @NAGARE_SUITE_SHARDS@ sets
-- the number of copies; @1@ runs the whole suite in this process.
module Nagare.Test.Shards
  ( runSharded
  , shard
  )
where

import Control.Concurrent.Async (forConcurrently)
import Control.Monad (forM_)
import Data.List (mapAccumL)
import GHC.Conc (getNumProcessors)
import Nagare.Dsl.Prelude
import System.Environment (getArgs, getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStr, stderr)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import Test.Tasty (TestTree, defaultMain)
import Test.Tasty.Runners (TestTree (..))
import Text.Read (readMaybe)

-- | Run the suite: as one shard when selected, otherwise as every shard in
-- parallel processes. Listing tests, asking for help, or one requested shard
-- runs the whole tree in this process.
runSharded :: TestTree -> IO ()
runSharded tree = do
  selected <- lookupEnv "NAGARE_SUITE_SHARD"
  case selected >>= parseShard of
    Just (slot, count) -> defaultMain (shard slot count tree)
    Nothing -> do
      requested <- lookupEnv "NAGARE_SUITE_SHARDS"
      buildCores <- lookupEnv "NIX_BUILD_CORES"
      processors <- getNumProcessors
      args <- getArgs
      let count = fromMaybe processors ((requested >>= positive) <|> (buildCores >>= positive))
          listing = any (`elem` ["-l", "--list-tests", "-h", "--help"]) args
      if count <= 1 || listing
        then defaultMain tree
        else runShards count args
  where
    positive text = readMaybe text >>= \n -> if n > 0 then Just n else Nothing

runShards :: Int -> [String] -> IO ()
runShards count args = do
  executable <- getExecutablePath
  environment <- getEnvironment
  let inherited = filter ((/= "NAGARE_SUITE_SHARD") . fst) environment
  results <- forConcurrently [0 .. count - 1] $ \slot -> do
    let child = (proc executable args) {env = Just (("NAGARE_SUITE_SHARD", show slot <> "/" <> show count) : inherited)}
    (code, out, err) <- readCreateProcessWithExitCode child ""
    pure (slot, code, out, err)
  forM_ results $ \(slot, code, out, err) -> do
    putStrLn ("suite shard " <> show slot <> " of " <> show count <> ": " <> show code)
    putStr out
    hPutStr stderr err
  case [slot | (slot, code, _, _) <- results, code /= ExitSuccess] of
    [] -> putStrLn ("suite: all " <> show count <> " shards passed")
    failed -> do
      putStrLn ("suite: shards failed: " <> show failed)
      exitWith (ExitFailure 1)

parseShard :: String -> Maybe (Int, Int)
parseShard text = case break (== '/') text of
  (indexText, '/' : countText) -> do
    slot <- readMaybe indexText
    count <- readMaybe countText
    if count >= 1 && slot >= 0 && slot < count then Just (slot, count) else Nothing
  _ -> Nothing

-- | Every @count@-th test in tree order, starting at @slot@. A subtree that
-- depends on a resource or on options counts as one test.
shard :: Int -> Int -> TestTree -> TestTree
shard slot count tree = case snd (go 0 tree) of
  [kept] -> kept
  kept -> TestGroup "shard" kept
  where
    go :: Int -> TestTree -> (Int, [TestTree])
    go position subtree = case subtree of
      SingleTest name test -> (position + 1, [SingleTest name test | selected position])
      TestGroup name trees ->
        let (next, kept) = mapAccumL go position trees
         in (next, [TestGroup name (concat kept)])
      PlusTestOptions options inner -> map (PlusTestOptions options) <$> go position inner
      After depType expr inner -> map (After depType expr) <$> go position inner
      opaque -> (position + 1, [opaque | selected position])
    selected position = position `mod` count == slot
