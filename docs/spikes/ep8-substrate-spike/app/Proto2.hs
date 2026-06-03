-- | Prototype 2 — embedded interpreter.
--
-- Same app-side input as Prototype 1 (@hello/Config.hs@ binding
-- @deployment :: Deployment@), but evaluated at runtime through an embedded
-- Haskell interpreter (the @hint@ package, a wrapper over the GHC API) with no
-- per-app compile step visible to the user.
--
-- Wiring note (this is itself criterion-(e) evidence). The obvious approach —
-- @interpret "deployment" (as :: Deployment)@ against the compiled @spike-lib@
-- package — fails: hint's GHC session does not pick up cabal's in-place
-- @spike-lib@ package db, so @Config@'s @import Spike.Types@ cannot be
-- resolved. Loading @Spike.Types@/@Spike.Render@ as /source/ on the search path
-- would then make the interpreted @Deployment@ a different type from the host's
-- compiled one, so a @Deployment@ value cannot cross the boundary. The working
-- shape is therefore: load @Config@, @Spike.Types@ and @Spike.Render@ all from
-- source, render /inside/ the interpreter, and return only the resulting
-- 'BS.ByteString' (a type shared via the single @bytestring@ package). Because
-- the loaded sources carry no LANGUAGE pragmas (they rely on the cabal
-- @common@ stanza), every extension they use must be supplied to hint
-- explicitly.
module Main (main) where

import Data.ByteString qualified as BS
import Language.Haskell.Interpreter
  ( OptionVal ((:=))
  , as
  , interpret
  , loadModules
  , runInterpreter
  , searchPath
  , set
  , setImportsQ
  , setTopLevelModules
  )
import Language.Haskell.Interpreter.Unsafe (unsafeSetGhcOption)
import System.Directory (getCurrentDirectory)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>))

main :: IO ()
main = do
  spikeDir <- getCurrentDirectory
  let srcDir = spikeDir </> "src"
      helloDir = spikeDir </> "hello"
      configPath = helloDir </> "Config.hs"
      renderPath = srcDir </> "Spike" </> "Render.hs"
      goldenPath = helloDir </> "golden.yaml"
  result <- runInterpreter $ do
    set [searchPath := [srcDir, helloDir]]
    -- hint 0.9's typed Extension enum predates DerivingStrategies and
    -- ImportQualifiedPost (used by the loaded sources), so enable the whole
    -- GHC2024 edition (matching the cabal `common` stanza) plus
    -- OverloadedStrings via the raw-flag escape hatch.
    unsafeSetGhcOption "-XGHC2024"
    unsafeSetGhcOption "-XOverloadedStrings"
    loadModules [configPath, renderPath]
    setTopLevelModules ["Config", "Spike.Render"]
    -- Bring the result type's name (ByteString) into the interpreter's scope;
    -- hint renders the `as :: BS.ByteString` annotation using the unqualified
    -- name, and Spike.Render imports it only qualified.
    setImportsQ [("Prelude", Nothing), ("Data.ByteString", Nothing)]
    interpret "renderService deployment \"20260602-120000\"" (as :: BS.ByteString)
  case result of
    Left err -> do
      putStrLn "FAIL: interpreter path produced an error"
      print err
      exitFailure
    Right got -> do
      want <- BS.readFile goldenPath
      if got == want
        then do
          putStrLn "PASS: output matches golden target"
          exitSuccess
        else do
          putStrLn "FAIL: output does not match golden target"
          BS.putStr got
          exitFailure
