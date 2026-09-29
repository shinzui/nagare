-- Synthetic accepted history, real prepared native envelopes; no provider IO.
module Main where
import Prelude
import Control.Monad (void)
import InventoryObservationSpec (prepare, binding)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import System.Environment (getArgs)

must :: Show e => IO (Either e a) -> IO a
must action = either (error . show) id <$> action

main :: IO ()
main = do
  [directory, width] <- getArgs
  store <- must (openFilesystemStore directory)
  initial <- must (initializeStore store binding "fixture")
  bundle <- prepare store (read width)
  let accepted = reviewDesiredRevisions (reviewBundleDocument bundle)
  void (must (replaceHeadIfGenerationMatches store (Just (headGeneration initial))
    initial {headGeneration = headGeneration initial + 1,
      headAccepted = accepted, headConverged = accepted}))
