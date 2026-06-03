-- | Prototype 1 — config-as-program.
--
-- An imagined app author ships a real Haskell source file (@hello/Config.hs@)
-- that binds @deployment :: Deployment@. This harness compiles-and-runs that
-- file to obtain the value, renders it to Knative YAML, and diffs the bytes
-- against the golden target.
--
-- The mechanism: shell out (via @cradle@) to @cabal exec -- runghc@ on the tiny
-- driver @helper/RunConfig.hs@ (which imports @Config@ and the shared
-- 'Spike.Render.renderService'). Using @cabal exec@ gives the spawned @runghc@
-- the package environment that makes the @spike-lib@ DSL library and its
-- transitive deps (@aeson@, @yaml@, ...) visible — this is exactly the
-- operational requirement scored under criterion (e): GHC + cabal + the DSL
-- library must be present at deploy time.
--
-- Must be run from the spike workspace root so the relative @-i@ paths and the
-- golden path resolve.
module Main (main) where

import Cradle
import Data.ByteString qualified as BS
import System.Directory (getCurrentDirectory)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>))

main :: IO ()
main = do
  spikeDir <- getCurrentDirectory
  let srcDir = spikeDir </> "src"
      helloDir = spikeDir </> "hello"
      wrapper = spikeDir </> "helper" </> "RunConfig.hs"
  StdoutRaw got <-
    run $
      cmd "cabal"
        & addArgs
          [ "exec"
          , "--verbose=0"
          , "--"
          , "runghc"
          , "-i" <> srcDir
          , "-i" <> helloDir
          , "-XGHC2024"
          , "-XOverloadedStrings"
          , wrapper
          ]
  golden <- BS.readFile (helloDir </> "golden.yaml")
  if got == golden
    then do
      putStrLn "PASS: output matches golden target"
      exitSuccess
    else do
      putStrLn "FAIL: output does not match golden target"
      putStrLn "--- got ---"
      BS.putStr got
      putStrLn "--- expected ---"
      BS.putStr golden
      exitFailure
