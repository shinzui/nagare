-- | Runtime / Deployer (EP-247). Executable-private CLI boundary: the
-- deployer command guard and the review source a command carries.
module Nagare.Cli.Runtime.Deployer
  ( guardDeployer
  , withCommandSource
  , withObjectStoreForwards
  )
where

import Control.Exception (IOException, try)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Options (Command (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Actor (ReviewSource, setReviewSource)
import Nagare.Inventory.DelegatedPlanning (profileActor)
import Nagare.Inventory.DeployerCommands (contextArgument, guardDeployerCommand)
import Nagare.Inventory.Store.ObjectTarget (withObjectStoreForwards)
import Nagare.Target (ActiveTarget, resolveActiveTarget)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | D3: a deployer context runs only the commands its delegation covers,
-- refused from the command words before the command reads any store. A
-- context that does not resolve is left to the command, which reports it.
guardDeployer :: IO ()
guardDeployer = do
  arguments <- map T.pack <$> getArgs
  resolved <- try (resolveActiveTarget (contextArgument arguments)) :: IO (Either IOException ActiveTarget)
  case resolved >>= first (userError . T.unpack) . profileActor . (^. #profile) of
    Left _ -> pure ()
    Right actor -> either (\message -> TIO.hPutStrLn stderr message >> exitFailure) pure (guardDeployerCommand actor arguments)

-- | D6: record the command's source for the review it prepares. The
-- revision comes from a deploy's own @--source@ when it names one.
withCommandSource :: ReviewSource -> Command -> IO a -> IO a
withCommandSource source inner action = setReviewSource (source & #revision %~ (<|> revision)) >> action
  where
    revision = case inner of
      AppDeploy options -> T.pack <$> options ^. #source
      SiteDeploy options -> T.pack <$> options ^. #source
      SitePreviewDeploy options _ -> T.pack <$> options ^. #source
      _ -> Nothing
