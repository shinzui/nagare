-- | The admin API's suite: its published document and its wire behavior.
module Main (main) where

import Control.Exception (evaluate)
import Data.ByteString.Lazy qualified as LBS
import Nagare.Api.OpenApi (renderAdminOpenApi)
import Nagare.Api.Server.Test.Client (clientTests)
import Nagare.Api.Server.Test.Document (documentTests)
import Nagare.Api.Server.Test.Fixture (sampleSnapshot, seedStore)
import Nagare.Api.Server.Test.Serve (serveTests)
import Nagare.Contract.Prelude
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
    Nothing -> tests

tests :: IO ()
tests = do
  -- Force the generated document once before tests run in parallel; see
  -- adminApplication.
  _ <- evaluate (LBS.length renderAdminOpenApi)
  defaultMain (testGroup "nagare-api-server" [documentTests, clientTests, serveTests])
