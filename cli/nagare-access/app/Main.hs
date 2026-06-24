module Main (main) where

import Data.Text qualified as Text
import Nagare.Access.App (app)
import Nagare.Access.Config (defaultListen, listenPort, parseListen)
import Network.Wai.Handler.Warp (run)
import System.Environment (lookupEnv)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  rawListen <- maybe "" Text.pack <$> lookupEnv "NAGARE_ACCESS_LISTEN"
  listen <- either (fail . Text.unpack) pure (parseListen rawListen)
  let port =
        if Text.null rawListen
          then listenPort defaultListen
          else listenPort listen
  putStrLn ("nagare-access listening on :" <> show port)
  run port app
