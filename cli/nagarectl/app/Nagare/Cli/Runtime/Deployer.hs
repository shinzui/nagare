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
import Nagare.Cluster.Kubeconfig (kubeconfigPath)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Actor (Actor (..), ReviewSource, setReviewSource)
import Nagare.Inventory.DelegatedPlanning (profileActor)
import Nagare.Inventory.DeployerCommands (contextArgument, guardDeployerCommand)
import Nagare.Inventory.Store.ObjectTarget (withObjectStoreForwards)
import Nagare.Target (ActiveTarget, contextNameText, nagareConfigDir, resolveActiveTarget)
import System.Directory (doesFileExist)
import System.Environment (getArgs, lookupEnv, setEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (stderr)

-- | D3: a deployer context runs only the commands its delegation covers,
-- refused from the command words before the command reads any store. A
-- context that does not resolve is left to the command, which reports it.
guardDeployer :: IO ()
guardDeployer = do
  arguments <- map T.pack <$> getArgs
  resolved <- try (resolveActiveTarget (contextArgument arguments)) :: IO (Either IOException ActiveTarget)
  case (,) <$> resolved <*> (resolved >>= first (userError . T.unpack) . profileActor . (^. #profile)) of
    Left _ -> pure ()
    Right (target, actor) -> do
      either (\message -> TIO.hPutStrLn stderr message >> exitFailure) pure (guardDeployerCommand actor arguments)
      -- EP-249: the config loader refuses every program in this process.
      case actor of
        DeployerActor name -> do
          setEnv "NAGARE_DEPLOYER" (T.unpack name)
          bundleDefaults target
        OperatorActor _ -> pure ()

-- | EP-248 D4: a deployer's bundle is its whole configuration. With nothing
-- else set, its kubeconfig and object store key are the bundle's own files.
bundleDefaults :: ActiveTarget -> IO ()
bundleDefaults target = do
  let context = target ^. #contextName
  configRoot <- nagareConfigDir
  kubeconfig <- kubeconfigPath context
  defaultTo "KUBECONFIG" [] kubeconfig
  defaultTo
    "NAGARE_INVENTORY_STORE_CREDENTIALS_FILE"
    ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
    (configRoot </> "credentials" </> T.unpack (contextNameText context) <> "-s3.json")
  where
    defaultTo variable alternatives path = do
      given <- traverse lookupEnv (variable : alternatives)
      present <- doesFileExist path
      when (all (maybe True null) given && present) (setEnv variable path)

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
