-- | The admin API's suite: its published document and its wire behavior.
module Main (main) where

import Control.Exception (evaluate)
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Nagare.Api.OpenApi (renderAdminOpenApi)
import Nagare.Api.Server.Test.Client (clientTests)
import Nagare.Api.Server.Test.Document (documentTests)
import Nagare.Api.Server.Test.Events (eventsTests, seedFeed, seededKeys)
import Nagare.Api.Server.Test.Fixture (sampleSnapshot, seedStore)
import Nagare.Api.Server.Test.Serve (serveTests)
import Nagare.Api.Server.Test.Worker (workerTests)
import Nagare.Contract.Prelude
import Nagare.Events.Store (filesystemObjectOps, memoryObjectOps, newFeedStore)
import Nagare.Events.Target (feedLocation)
import Nagare.Inventory.Store (openFilesystemStore)
import Nagare.Platform.Versions.Store (publishVersionSnapshot)
import System.Environment (lookupEnv)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  lookupEnv "NAGARE_API_FIXTURE" >>= \case
    -- `just api-hurl` seeds the black-box suite's store with this fixture and
    -- does not run the tests.
    -- NAGARE_API_FIXTURE_SITES sizes it for a latency measurement.
    Just directory -> do
      sites <- maybe 12 read <$> lookupEnv "NAGARE_API_FIXTURE_SITES"
      store <- openFilesystemStore directory >>= either (fail . show) pure
      void (seedStore store sites)
      -- The platform-versions snapshot the black-box suite asserts (EP-236).
      void (publishVersionSnapshot store sampleSnapshot >>= either (fail . show) pure)
      -- EP-231: a feed beside it, from its own fixture inventory, so the
      -- black-box suite's events are known without a real producer.
      feedOps <- filesystemObjectOps (Text.unpack (feedLocation (Text.pack directory)))
      feed <- newFeedStore feedOps
      inventoryOps <- memoryObjectOps
      seedFeed inventoryOps feed seededKeys
    Nothing -> tests

tests :: IO ()
tests = do
  -- Force the generated document once before tests run in parallel; see
  -- adminApplication.
  _ <- evaluate (LBS.length renderAdminOpenApi)
  defaultMain (testGroup "nagare-api-server" [documentTests, clientTests, serveTests, eventsTests, workerTests])
