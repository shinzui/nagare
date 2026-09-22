-- | Production subprocess boundary for digest-addressed artifact publication.
--
-- The transport receives one canonical JSON document on stdin and emits one
-- canonical observation document on stdout. It cannot choose resource
-- identity, destination, or expected content independently of the reviewed
-- native plan.
module Nagare.Inventory.Adapters.ArtifactRuntime
  ( ArtifactRuntimeConfig (..)
  , mkArtifactRuntimeOps
  )
where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Artifact
import Nagare.Inventory.Artifact
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)

data ArtifactRuntimeConfig = ArtifactRuntimeConfig
  { runtimeArtifactExecutable :: !FilePath
  , runtimeArtifactEnvironment :: ![(String, String)]
  , runtimeArtifactSpecs :: !(Map ResourceId ArtifactExecutionSpec)
  }
  deriving stock (Eq, Show)

data TransportRequest = TransportRequest
  { requestVersion :: !Int
  , requestResource :: !ResourceId
  , requestKind :: !ArtifactKind
  , requestDestination :: !Text
  , requestExpectedDigest :: !ContentDigest
  , requestSpecDigest :: !ContentDigest
  , requestPlan :: !(Maybe ArtifactMutationPlan)
  }
  deriving stock (Eq, Show, Generic)

data TransportObservation
  = TransportMissing !ContentDigest
  | TransportPresent !PhysicalIdentity !ContentDigest
  | TransportOwnershipMismatch !PhysicalIdentity !Text
  deriving stock (Eq, Show, Generic)

mkArtifactRuntimeOps :: ArtifactRuntimeConfig -> ArtifactAdapterOps
mkArtifactRuntimeOps config =
  ArtifactAdapterOps
    { artifactObserveResources = observeResources config
    , artifactPrepareMutation = prepareMutation config
    , artifactInspectRemote = inspectRemote config
    , artifactPublish = publishArtifact config
    }

observeResources :: ArtifactRuntimeConfig -> [ResourceId] -> IO (Either Text ObservationSet)
observeResources config resources = do
  observations <- traverse observe resources
  pure (sequence observations >>= observationSet)
  where
    observe resource = case Map.lookup resource (runtimeArtifactSpecs config) of
      Nothing -> pure (Left ("artifact resource is absent from the execution specification: " <> resourceIdText resource))
      Just spec -> do
        result <- runTransport config "observe" (requestFor resource spec Nothing)
        pure ((resource,) . toResourceObservation <$> result)

prepareMutation :: ArtifactRuntimeConfig -> PlannedOperation -> IO (Either Text ArtifactMutationPlan)
prepareMutation config operation = pure $ do
  resource <- case NE.toList (plannedResources operation) of
    [single] -> Right single
    _ -> Left "artifact operations must name exactly one managed publication"
  spec <- maybe (Left ("artifact operation names an unknown resource: " <> resourceIdText resource)) Right (Map.lookup resource (runtimeArtifactSpecs config))
  unless (plannedAction operation == RunDeclaredOperation) (Left "artifact runtime only executes explicit publication operations")
  pure
    ArtifactMutationPlan
      { artifactPlanVersion = 1
      , artifactPlanOperation = plannedOperationId operation
      , artifactPlanInputDigest = plannedInputDigest operation
      , artifactPlanResource = resource
      , artifactPlanKind = executionArtifactKind spec
      , artifactPlanDestination = executionArtifactDestination spec
      , artifactPlanExpectedDigest = executionArtifactContentDigest spec
      , artifactPlanSourceDigest = executionArtifactSpecDigest spec
      , artifactPlanConfigurationDigest = Nothing
      }

inspectRemote :: ArtifactRuntimeConfig -> ArtifactMutationPlan -> IO ArtifactObservation
inspectRemote config plan = case Map.lookup (artifactPlanResource plan) (runtimeArtifactSpecs config) of
  Nothing -> pure (ArtifactObservationUnavailable "artifact resource is absent from the execution specification")
  Just spec -> do
    result <- runTransport config "observe" (requestFor (artifactPlanResource plan) spec (Just plan))
    pure $ case result of
      Left err -> ArtifactObservationUnavailable err
      Right observation -> toArtifactObservation observation

publishArtifact :: ArtifactRuntimeConfig -> ArtifactMutationPlan -> IO AdapterExecution
publishArtifact config plan = case Map.lookup (artifactPlanResource plan) (runtimeArtifactSpecs config) of
  Nothing -> pure (AdapterEffectFailed (KnownNoEffect "artifact resource is absent from the execution specification"))
  Just spec -> do
    result <- runTransport config "publish" (requestFor (artifactPlanResource plan) spec (Just plan))
    pure $ case result of
      Left err -> AdapterEffectAmbiguous err
      Right (TransportPresent physical digest)
        | digest == artifactPlanExpectedDigest plan
        , physicalIdentityText physical == expectedPhysical spec ->
            AdapterEffectCompleted
        | otherwise -> AdapterEffectAmbiguous "artifact transport returned an identity or digest outside the reviewed plan"
      Right TransportMissing {} -> AdapterEffectAmbiguous "artifact transport returned success but the publication is absent"
      Right TransportOwnershipMismatch {} -> AdapterEffectAmbiguous "artifact transport returned success with an ownership mismatch"

requestFor :: ResourceId -> ArtifactExecutionSpec -> Maybe ArtifactMutationPlan -> TransportRequest
requestFor resource spec plan =
  TransportRequest
    { requestVersion = 1
    , requestResource = resource
    , requestKind = executionArtifactKind spec
    , requestDestination = executionArtifactDestination spec
    , requestExpectedDigest = executionArtifactContentDigest spec
    , requestSpecDigest = executionArtifactSpecDigest spec
    , requestPlan = plan
    }

runTransport :: ArtifactRuntimeConfig -> String -> TransportRequest -> IO (Either Text TransportObservation)
runTransport config action request = do
  environment <- getEnvironment
  let additions = runtimeArtifactEnvironment config
      names = map fst additions
      childEnvironment = additions <> filter ((`notElem` names) . fst) environment
      command = (proc (runtimeArtifactExecutable config) [action]) {env = Just childEnvironment}
  case canonicalValue (toJSON request) of
    Left err -> pure (Left err)
    Right bytes -> do
      result <- try (readCreateProcessWithExitCode command (T.unpack (TE.decodeUtf8 bytes)))
      pure $ case result of
        Left (err :: IOException) -> Left ("could not run artifact transport: " <> T.pack (show err))
        Right (ExitFailure code, output, errors) -> Left ("artifact transport exited " <> T.pack (show code) <> ": " <> T.strip (T.pack (errors <> "\n" <> output)))
        Right (ExitSuccess, output, _) -> first (("invalid artifact transport response: " <>) . T.pack) (eitherDecodeStrict (TE.encodeUtf8 (T.strip (T.pack output))))

toResourceObservation :: TransportObservation -> ResourceObservation
toResourceObservation = \case
  TransportMissing proof -> ConfirmedAbsent proof
  TransportPresent physical _ -> ObservedPresent physical
  TransportOwnershipMismatch _ reason -> ObservationUnavailable reason

toArtifactObservation :: TransportObservation -> ArtifactObservation
toArtifactObservation = \case
  TransportMissing proof -> ArtifactMissing proof
  TransportPresent physical digest -> ArtifactPresent physical digest
  TransportOwnershipMismatch physical reason -> ArtifactOwnershipMismatch physical reason

expectedPhysical :: ArtifactExecutionSpec -> Text
expectedPhysical spec = case executionArtifactKind spec of
  GcsImageObjectArtifact -> "gcs://" <> fromMaybe (executionArtifactDestination spec) (T.stripPrefix "gs://" (executionArtifactDestination spec))
  kind -> physicalPrefix kind <> executionArtifactDestination spec
  where
    physicalPrefix = \case
      OciImageArtifact -> "oci://"
      GcsImageObjectArtifact -> "gcs://"
      GceImageArtifact -> "gce://"
      BuildJobArtifact -> "build-job://"
      TemporaryBuilderArtifact -> "builder://"
      ReleasePayloadArtifact -> "release://"
      ControlMetadataArtifact -> "control://"

instance ToJSON TransportRequest where
  toJSON request =
    object
      [ "version" .= requestVersion request
      , "resource" .= requestResource request
      , "kind" .= requestKind request
      , "destination" .= requestDestination request
      , "expectedDigest" .= requestExpectedDigest request
      , "specDigest" .= requestSpecDigest request
      , "plan" .= requestPlan request
      ]

instance FromJSON TransportObservation where
  parseJSON = genericParseJSON defaultOptions
