-- | @nagarectl broker list@: print all managed brokers in a namespace.
module Nagare.Broker.List
  ( runBrokerList
  )
where

import Data.Text.IO qualified as TIO
import Nagare.Broker.Discover (formatBrokerTable, listBrokers)
import Nagare.Dsl.Prelude
import System.Exit (exitFailure)
import System.IO (stderr)

runBrokerList :: Text -> IO ()
runBrokerList ns = do
  erows <- listBrokers ns
  case erows of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right rows -> TIO.putStr (formatBrokerTable rows)
