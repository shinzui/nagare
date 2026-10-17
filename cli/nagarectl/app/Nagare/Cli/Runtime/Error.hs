-- | Runtime / Error. Executable-private CLI boundary.
module Nagare.Cli.Runtime.Error
  ( dieT
  , orDie
  , printPreflightWarnings
  , renderVersionError
  )
where

import Data.Text.IO qualified as TIO
import Nagare.Contract.Problem (unclassified)
import Nagare.Contract.Sink (refuseWith)
import Nagare.Dsl.Prelude
import Nagare.Version (VersionError (VersionError))
import System.Exit (exitFailure)
import System.IO (stderr)

printPreflightWarnings :: [Text] -> IO ()
printPreflightWarnings = mapM_ (TIO.putStrLn . ("  warning: " <>))

-- | Exit with a one-line error from a pure @Either Text@ validation.
orDie :: Either Text a -> IO a
orDie = either dieT pure

-- | Print a one-line @nagarectl:@ error to stderr and exit non-zero, or,
-- under @--contract 1@, the refusal's outcome document (EP-192).
dieT :: Text -> IO a
dieT msg = refuseWith ("nagarectl: " <> msg) unclassified msg

renderVersionError :: VersionError -> Text
renderVersionError (VersionError message) = message
