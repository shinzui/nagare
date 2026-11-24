-- | The release transition's preflight of the platform stage (EP-280).
module Nagare.Inventory.ForeignOwnerPreflight (afterForeignOwnerPreflight) where

import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Contract.Sink (withoutDocuments)
import Nagare.Dsl.Prelude
import Nagare.Inventory.KubernetesConfiguration (foreignOwnerRefusalMarker)
import System.Exit (ExitCode)
import System.IO (stderr)

-- | Plan a stage that precedes the platform stage only when the platform stage's own plan
-- would not refuse another writer's fields. A release transition plans one stage at a time and the
-- host stage comes first, so without this the refusal would land after the host changed. The
-- preflight returns the platform plan's refusal, if any. Only a foreign-owner refusal stops the
-- stage: the platform stage may not be plannable yet, so any other refusal, a command refusal
-- (which has printed its own line and exits) or a failure is left to that stage's own plan.
afterForeignOwnerPreflight :: IO (Maybe Text) -> IO a -> IO (Either Text a)
afterForeignOwnerPreflight platformRefusal stage = do
  outcome <- try (withoutDocuments platformRefusal)
  case outcome of
    Right (Just refusal) | foreignOwnerRefusalMarker `T.isInfixOf` refusal -> pure (Left refusal)
    Right Nothing -> Right <$> stage
    Right (Just refusal) -> skipped refusal >> Right <$> stage
    Left (failure :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException failure -> throwIO failure
      | Just (_ :: ExitCode) <- fromException failure -> skipped "its plan was refused (above)" >> Right <$> stage
      | otherwise -> skipped (T.pack (displayException failure)) >> Right <$> stage
  where
    skipped reason = TIO.hPutStrLn stderr ("note: the platform stage was not checked for other writers' fields ahead of this stage; its own plan checks it: " <> reason)
