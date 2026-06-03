-- | Print 'renderLoadError' of each 'LoadError' variant, proving the module
-- builds and renders before the real loader runs (EP-10 M1.5).
module Main (main) where

import Data.Text.IO qualified as TIO
import Nagare.Dsl.Load

main :: IO ()
main = do
  TIO.putStrLn (renderLoadError (FileNotFound "/app/nagare/Config.hs"))
  TIO.putStrLn (renderLoadError (CompileError "/app/nagare/Config.hs" "Config.hs:5:1: error: parse error"))
  TIO.putStrLn (renderLoadError (MissingBinding "/app/nagare/Config.hs"))
  TIO.putStrLn (renderLoadError (MarshalError "port" "port must be >= 1, got: 0"))
