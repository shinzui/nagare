module Main (main) where

import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Nagare.Access.App (appWithBackends)
import Nagare.Access.BackendMap (BackendMap, decodeBackendMap, emptyBackendMap)
import Nagare.Access.Config (RuntimeConfig (..), listenPort, parseRuntimeConfig)
import Network.Wai.Handler.Warp (run)
import System.Environment (getEnvironment)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  runtime <- either (fail . Text.unpack) pure . parseRuntimeConfig =<< getEnvironment
  backends <- loadBackends (backendMapPath runtime)
  let port = listenPort (runtimeListen runtime)
  putStrLn ("nagare-access listening on :" <> show port)
  run port (appWithBackends backends)

loadBackends :: Maybe FilePath -> IO BackendMap
loadBackends Nothing = pure emptyBackendMap
loadBackends (Just "") = pure emptyBackendMap
loadBackends (Just path) = do
  bytes <- BS.readFile path
  either (fail . Text.unpack) pure (decodeBackendMap bytes)
