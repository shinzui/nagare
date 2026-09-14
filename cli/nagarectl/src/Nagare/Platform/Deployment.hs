{-# LANGUAGE OverloadedStrings #-}

-- | Project-scoped evidence for whether a context's single GCE host exists.
module Nagare.Platform.Deployment
  ( DeploymentOps (..)
  , DeploymentState (..)
  , classifyHostDescribe
  , defaultDeploymentOps
  , deploymentStateToken
  , observeHostDeployment
  )
where

import Control.Exception (IOException, catch)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Target (TargetProfile (..))
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data DeploymentState
  = NotDeployed
  | Deployed
  | DeploymentUnknown !Text
  deriving stock (Eq, Show)

newtype DeploymentOps = DeploymentOps
  { describeInstance :: Text -> Text -> Text -> IO (Either Text (ExitCode, Text, Text))
  }

defaultDeploymentOps :: DeploymentOps
defaultDeploymentOps =
  DeploymentOps $ \project zone instanceName -> do
    executable <- findExecutable "gcloud"
    case executable of
      Nothing -> pure (Left "gcloud was not found on PATH")
      Just path ->
        ( do
            (exitCode, stdoutText, stderrText) <-
              readProcessWithExitCode
                path
                [ "--project=" <> T.unpack project
                , "compute"
                , "instances"
                , "describe"
                , T.unpack instanceName
                , "--zone=" <> T.unpack zone
                , "--format=json"
                ]
                ""
            pure (Right (exitCode, T.pack stdoutText, T.pack stderrText))
        )
          `catch` \(err :: IOException) -> pure (Left (T.pack (show err)))

observeHostDeployment :: DeploymentOps -> TargetProfile -> IO DeploymentState
observeHostDeployment ops profile = do
  result <-
    describeInstance
      ops
      (profile ^. #project)
      (profile ^. #zone)
      (profile ^. #instanceName)
  pure $ case result of
    Left err -> DeploymentUnknown err
    Right (exitCode, stdoutText, stderrText) -> classifyHostDescribe exitCode stdoutText stderrText

classifyHostDescribe :: ExitCode -> Text -> Text -> DeploymentState
classifyHostDescribe ExitSuccess stdoutText _ = case Aeson.eitherDecodeStrict' (TE.encodeUtf8 stdoutText) of
  Right (Aeson.Object _) -> Deployed
  _ -> DeploymentUnknown "gcloud compute instances describe returned invalid JSON"
classifyHostDescribe (ExitFailure exitCode) stdoutText stderrText
  | isNotFound diagnostic = NotDeployed
  | otherwise =
      DeploymentUnknown
        ( "gcloud compute instances describe exited with status "
            <> T.pack (show exitCode)
            <> ": "
            <> if T.null diagnostic then "no diagnostic output" else diagnostic
        )
  where
    diagnostic = T.strip (if T.null (T.strip stderrText) then stdoutText else stderrText)
    isNotFound message =
      let lowered = T.toLower message
       in "was not found" `T.isInfixOf` lowered
            || "resource not found" `T.isInfixOf` lowered

deploymentStateToken :: DeploymentState -> Text
deploymentStateToken = \case
  NotDeployed -> "not-deployed"
  Deployed -> "deployed"
  DeploymentUnknown _ -> "unknown"
