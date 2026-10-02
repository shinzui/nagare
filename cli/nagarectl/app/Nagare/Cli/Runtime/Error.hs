-- | Runtime / Error. Executable-private CLI boundary.
module Nagare.Cli.Runtime.Error
  ( dieT
  , orDie
  , printPreflightWarnings
  , renderVersionError
  )
where

import Data.Text.IO qualified as TIO
import Nagare.Dsl.Prelude
import Nagare.Version (VersionError (VersionError))
import System.Exit (exitFailure)
import System.IO (stderr)

printPreflightWarnings :: [Text] -> IO ()
printPreflightWarnings = mapM_ (TIO.putStrLn . ("  warning: " <>))

-- | Exit with a one-line error from a pure @Either Text@ validation.
orDie :: Either Text a -> IO a
orDie = either dieT pure

-- | Print a one-line @nagarectl:@ error to stderr and exit non-zero.
dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure

renderVersionError :: VersionError -> Text
renderVersionError (VersionError message) = message
