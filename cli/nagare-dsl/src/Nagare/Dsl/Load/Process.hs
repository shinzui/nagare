-- | Process responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Process
  ( runConfig
  , runConfigWith
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
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
import System.Process (readProcessWithExitCode)
import System.Timeout qualified as Timeout

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
--
-- 'readProcessWithExitCode' is built on @withCreateProcess@, whose cleanup
-- terminates the child when the waiting thread is interrupted — which is exactly
-- what 'System.Timeout.timeout' does — so the @runghc@ process dies with the
-- budget rather than being orphaned.
runConfigWith :: ConfigTimeout -> FilePath -> IO (Either LoadError ByteString)
runConfigWith budget path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left (FileNotFound path))
    else do
      let configDir = takeDirectory path
          seconds' = budget ^. #seconds
      result <-
        Timeout.timeout (seconds' * 1_000_000) . try @IOException $
          readProcessWithExitCode
            "runghc"
            ["--ghc-arg=-XGHC2024", "-i" <> configDir, path]
            ""
      pure $ case result of
        Nothing -> Left (LoadTimedOut path seconds')
        Just (Left ioErr) -> Left (CompileError path (Text.pack (show ioErr)))
        Just (Right (ExitFailure _, _out, err)) -> Left (CompileError path (Text.pack err))
        Just (Right (ExitSuccess, out, _err))
          | null out -> Left (MissingBinding path)
          | otherwise -> Right (BC.pack out)
