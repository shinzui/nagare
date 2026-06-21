-- | @nagarectl broker get NAME@: show one managed broker's current state.
module Nagare.Broker.Get
  ( runBrokerGet
  )
where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Broker.Discover (BrokerRow (..), getBroker)
import Nagare.Dsl.Broker.Render (brokerPvcName)
import Nagare.Dsl.Prelude
import System.Exit (exitFailure)
import System.IO (stderr)
import "generic-lens" Data.Generics.Labels ()

runBrokerGet :: Text -> Text -> IO ()
runBrokerGet ns brokerName = do
  erow <- getBroker ns brokerName
  case erow of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right r ->
      TIO.putStr $
        T.unlines
          [ "Name:      " <> r ^. #name
          , "Provider:  " <> r ^. #provider
          , "Version:   " <> r ^. #version
          , "Size:      " <> r ^. #size
          , "Bootstrap: " <> r ^. #bootstrap
          , "PVC:       " <> brokerPvcName brokerName
          , "Ready:     " <> (if r ^. #ready then "True" else "False")
          ]
