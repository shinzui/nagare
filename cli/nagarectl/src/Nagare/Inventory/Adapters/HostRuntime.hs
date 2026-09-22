-- | Production subprocess boundary for guarded NixOS activation.
--
-- Preparation evaluates the immutable target closure and observes the current
-- physical instance. Execution passes the retained plan back to the narrow
-- host transport; verification only observes the remote running/boot state.
module Nagare.Inventory.Adapters.HostRuntime
  ( HostRuntimeConfig (..)
  , mkHostRuntimeOps
  )
where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Host
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), operationIdText)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)

data HostRuntimeConfig = HostRuntimeConfig
  { runtimeHostExecutable :: !FilePath
  , runtimeHostEnvironment :: ![(String, String)]
  , runtimeHostContext :: !ContextId
  , runtimeHostAttribute :: !Name
  , runtimeHostProject :: !Text
  , runtimeHostZone :: !Text
  , runtimeHostInstanceName :: !Text
  , runtimeHostDestination :: !Text
  , runtimeHostConfigurationDigest :: !ContentDigest
  , runtimeHostLockDigest :: !ContentDigest
  }
  deriving stock (Eq, Show)

data HostTransportRequest = HostTransportRequest
  { requestVersion :: !Int
  , requestContext :: !ContextId
  , requestHostAttribute :: !Name
  , requestProject :: !Text
  , requestZone :: !Text
  , requestInstanceName :: !Text
  , requestDestination :: !Text
  , requestConfigurationDigest :: !ContentDigest
  , requestLockDigest :: !ContentDigest
  , requestPlan :: !(Maybe HostActivationPlan)
  }
  deriving stock (Eq, Show, Generic)

data HostTransportResponse
  = HostTransportMissing !ContentDigest
  | HostTransportPrepared !PhysicalIdentity !Text !Text
  | HostTransportBefore !PhysicalIdentity !Text
  | HostTransportArmed !PhysicalIdentity !Text
  | HostTransportCommitted !PhysicalIdentity !Text !ContentDigest
  | HostTransportReverted !PhysicalIdentity !Text
  deriving stock (Eq, Show, Generic)

mkHostRuntimeOps :: HostRuntimeConfig -> HostAdapterOps
mkHostRuntimeOps config =
  HostAdapterOps
    { hostObserveResources = observeResources config
    , hostPreparePlan = preparePlan config
    , hostInspectActivation = inspectActivation config
    , hostRunActivation = runActivation config
    }

observeResources :: HostRuntimeConfig -> [ResourceId] -> IO (Either Text ObservationSet)
observeResources config resources = do
  response <- runTransport config "observe" Nothing
  pure $ do
    observation <- response
    value <- case observation of
      HostTransportMissing proof -> Right (ConfirmedAbsent proof)
      HostTransportPrepared physical _ _ -> Right (ObservedPresent physical)
      _ -> Left "host observe transport returned an activation state"
    observationSet [(resource, value) | resource <- resources]

preparePlan :: HostRuntimeConfig -> PlannedOperation -> IO (Either Text HostActivationPlan)
preparePlan config operation
  | plannedAction operation /= RunDeclaredOperation = pure (Left "host runtime only executes explicit activation operations")
  | null (NE.toList (plannedResources operation)) = pure (Left "host activation names no resources")
  | otherwise = do
      response <- runTransport config "prepare" Nothing
      pure $ do
        prepared <- response
        case prepared of
          HostTransportPrepared physical oldClosure newClosure ->
            Right
              HostActivationPlan
                { hostPlanVersion = 1
                , hostPlanOperation = plannedOperationId operation
                , hostPlanInputDigest = plannedInputDigest operation
                , hostPlanContext = runtimeHostContext config
                , hostPlanAttribute = runtimeHostAttribute config
                , hostPlanInstance = physical
                , hostPlanDestination = runtimeHostDestination config
                , hostPlanConfigurationDigest = runtimeHostConfigurationDigest config
                , hostPlanLockDigest = runtimeHostLockDigest config
                , hostPlanExpectedOldClosure = oldClosure
                , hostPlanNewClosure = newClosure
                , hostPlanActivationId = operationIdText (plannedOperationId operation)
                }
          HostTransportMissing {} -> Left "host physical instance is absent; reconcile its cloud dependency before activation"
          _ -> Left "host prepare transport returned an activation state"

inspectActivation :: HostRuntimeConfig -> HostActivationPlan -> IO HostActivationState
inspectActivation config plan = do
  response <- runTransport config "inspect" (Just plan)
  pure $ case response of
    Left err -> HostUnreachable err
    Right (HostTransportBefore physical closure) -> HostBeforeActivation physical closure
    Right (HostTransportArmed physical closure) -> HostTimerArmed physical closure
    Right (HostTransportCommitted physical closure acknowledgement) -> HostCommitted physical closure acknowledgement
    Right (HostTransportReverted physical closure) -> HostReverted physical closure
    Right HostTransportMissing {} -> HostUnreachable "host physical instance is absent"
    Right HostTransportPrepared {} -> HostUnreachable "host inspect transport returned preparation evidence"

runActivation :: HostRuntimeConfig -> HostActivationPlan -> IO AdapterExecution
runActivation config plan = do
  response <- runTransport config "activate" (Just plan)
  pure $ case response of
    Left err -> AdapterEffectAmbiguous err
    Right (HostTransportCommitted physical closure _)
      | physical == hostPlanInstance plan
      , closure == hostPlanNewClosure plan ->
          AdapterEffectCompleted
      | otherwise -> AdapterEffectAmbiguous "host activation returned identity outside the reviewed plan"
    Right _ -> AdapterEffectFailed (KnownNoEffect "host activation did not return committed fresh-login evidence")

runTransport :: HostRuntimeConfig -> String -> Maybe HostActivationPlan -> IO (Either Text HostTransportResponse)
runTransport config action plan = case canonicalValue (toJSON (request config plan)) of
  Left err -> pure (Left err)
  Right bytes -> do
    environment <- getEnvironment
    let additions = runtimeHostEnvironment config
        names = map fst additions
        childEnvironment = additions <> filter ((`notElem` names) . fst) environment
        command = (proc (runtimeHostExecutable config) [action]) {env = Just childEnvironment}
    result <- try (readCreateProcessWithExitCode command (T.unpack (TE.decodeUtf8 bytes)))
    pure $ case result of
      Left (err :: IOException) -> Left ("could not run host transport: " <> T.pack (show err))
      Right (ExitFailure code, output, errors) -> Left ("host transport exited " <> T.pack (show code) <> ": " <> T.strip (T.pack (errors <> "\n" <> output)))
      Right (ExitSuccess, output, _) -> first (("invalid host transport response: " <>) . T.pack) (eitherDecodeStrict (TE.encodeUtf8 (T.strip (T.pack output))))

request :: HostRuntimeConfig -> Maybe HostActivationPlan -> HostTransportRequest
request config plan =
  HostTransportRequest
    { requestVersion = 1
    , requestContext = runtimeHostContext config
    , requestHostAttribute = runtimeHostAttribute config
    , requestProject = runtimeHostProject config
    , requestZone = runtimeHostZone config
    , requestInstanceName = runtimeHostInstanceName config
    , requestDestination = runtimeHostDestination config
    , requestConfigurationDigest = runtimeHostConfigurationDigest config
    , requestLockDigest = runtimeHostLockDigest config
    , requestPlan = plan
    }

instance ToJSON HostTransportRequest where
  toJSON value =
    object
      [ "version" .= requestVersion value
      , "context" .= requestContext value
      , "hostAttribute" .= requestHostAttribute value
      , "project" .= requestProject value
      , "zone" .= requestZone value
      , "instanceName" .= requestInstanceName value
      , "destination" .= requestDestination value
      , "configurationDigest" .= requestConfigurationDigest value
      , "lockDigest" .= requestLockDigest value
      , "plan" .= requestPlan value
      ]

instance FromJSON HostTransportResponse where
  parseJSON = genericParseJSON defaultOptions
