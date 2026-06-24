module Main (main) where

import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Nagare.Access.App (appWithBackends)
import Nagare.Access.BackendMap (BackendMap, decodeBackendMap, emptyBackendMap)
import Nagare.Access.Config (defaultListen, listenPort, parseListen)
import Network.Wai.Handler.Warp (run)
import System.Environment (lookupEnv)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  rawListen <- maybe "" Text.pack <$> lookupEnv "NAGARE_ACCESS_LISTEN"
  backends <- loadBackends =<< lookupEnv "NAGARE_ACCESS_BACKENDS"
  listen <- either (fail . Text.unpack) pure (parseListen rawListen)
  let port =
        if Text.null rawListen
          then listenPort defaultListen
          else listenPort listen
  putStrLn ("nagare-access listening on :" <> show port)
  run port (appWithBackends backends)

loadBackends :: Maybe FilePath -> IO BackendMap
loadBackends Nothing = pure emptyBackendMap
loadBackends (Just "") = pure emptyBackendMap
loadBackends (Just path) = do
  bytes <- BS.readFile path
  either (fail . Text.unpack) pure (decodeBackendMap bytes)
