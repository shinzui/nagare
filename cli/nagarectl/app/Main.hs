-- | Process setup and typed command dispatch for nagarectl.
module Main (main) where

import GHC.IO.Encoding (setLocaleEncoding)
import Nagare.Cli.Dispatch (dispatch)
import Nagare.Cli.Parser (opts)
import Nagare.Dsl.Prelude
import Options.Applicative (execParser)
import System.IO (hSetEncoding, stderr, stdout, utf8)

main :: IO ()
main = do
  setLocaleEncoding utf8
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  execParser opts >>= dispatch
