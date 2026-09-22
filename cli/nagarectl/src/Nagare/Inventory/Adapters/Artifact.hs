-- | Digest- and ownership-verifying artifact publication adapter.
module Nagare.Inventory.Adapters.Artifact
  ( ArtifactMutationPlan (..)
  , ArtifactObservation (..)
  , ArtifactAdapterOps (..)
  , mkArtifactAdapter
  , artifactCompletionProof
  )
where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Artifact
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Resource.Inventory (Executor (ArtifactExecutor))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data ArtifactMutationPlan = ArtifactMutationPlan
  { artifactPlanVersion :: !Int
  , artifactPlanOperation :: !OperationId
  , artifactPlanInputDigest :: !ContentDigest
  , artifactPlanResource :: !ResourceId
  , artifactPlanKind :: !ArtifactKind
  , artifactPlanDestination :: !Text
  , artifactPlanExpectedDigest :: !ContentDigest
  , artifactPlanSourceDigest :: !ContentDigest
  , artifactPlanConfigurationDigest :: !(Maybe ContentDigest)
  }
  deriving stock (Eq, Show, Generic)

data ArtifactObservation
  = ArtifactMissing !ContentDigest
  | ArtifactPresent !PhysicalIdentity !ContentDigest
  | ArtifactOwnershipMismatch !PhysicalIdentity !Text
  | ArtifactObservationUnavailable !Text
  deriving stock (Eq, Show, Generic)

data ArtifactAdapterOps = ArtifactAdapterOps
  { artifactObserveResources :: !([ResourceId] -> IO (Either Text ObservationSet))
  , artifactPrepareMutation :: !(PlannedOperation -> IO (Either Text ArtifactMutationPlan))
  , artifactInspectRemote :: !(ArtifactMutationPlan -> IO ArtifactObservation)
  , artifactPublish :: !(ArtifactMutationPlan -> IO AdapterExecution)
  }

mkArtifactAdapter :: Map ResourceId ArtifactResourceSpec -> ArtifactAdapterOps -> Adapter
mkArtifactAdapter specs ops =
  Adapter
    { adapterExecutor = ArtifactExecutor
    , adapterIdentity = "digest-verified-artifact"
    , adapterVersion = "1"
    , adapterObserve = artifactObserveResources ops
    , adapterPrepare = prepare
    , adapterPreflight = preflight
    , adapterExecute = executePlan
    , adapterVerify = verifyPlan
    , adapterRecover = recoverPlan
    }
  where
    prepare operation = do
      result <- artifactPrepareMutation ops operation
      pure $ do
        plan <- first (PrepareRefused (plannedOperationId operation)) result
        validatePlan specs operation plan
        bytes <- first (PrepareRefused (plannedOperationId operation)) (canonicalValue (toJSON plan))
        pure (PreparedNative bytes (summary plan))
    preflight operation prepared = case decodePlan specs operation (preparedNativeBytes prepared) of
      Left err -> pure (Left err)
      Right plan -> preflightObservation plan <$> artifactInspectRemote ops plan
    executePlan operation prepared = case decodePlan specs operation (preparedNativeBytes prepared) of
      Left err -> pure (AdapterEffectFailed (KnownNoEffect err))
      Right plan -> do
        observation <- artifactInspectRemote ops plan
        case observation of
          ArtifactPresent _ digest | digest == artifactPlanExpectedDigest plan -> pure AdapterEffectCompleted
          ArtifactMissing _ -> artifactPublish ops plan
          ArtifactOwnershipMismatch _ reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
          ArtifactObservationUnavailable reason -> pure (AdapterEffectAmbiguous reason)
          ArtifactPresent _ _ -> pure (AdapterEffectFailed (KnownNoEffect "remote artifact digest disagrees with review"))
    verifyPlan operation prepared = case decodePlan specs operation (preparedNativeBytes prepared) of
      Left err -> pure (Left err)
      Right plan -> do
        observation <- artifactInspectRemote ops plan
        pure $ case observation of
          ArtifactPresent physical digest | digest == artifactPlanExpectedDigest plan -> Right (artifactCompletionProof plan physical)
          ArtifactPresent _ _ -> Left "remote artifact digest disagrees with review"
          ArtifactOwnershipMismatch _ reason -> Left reason
          ArtifactMissing _ -> Left "remote artifact is absent"
          ArtifactObservationUnavailable reason -> Left reason
    recoverPlan operation prepared = case decodePlan specs operation (preparedNativeBytes prepared) of
      Left err -> pure (RecoveryUnresolved err)
      Right plan -> recoveryObservation plan <$> artifactInspectRemote ops plan

validatePlan :: Map ResourceId ArtifactResourceSpec -> PlannedOperation -> ArtifactMutationPlan -> Either PrepareError ()
validatePlan specs operation plan
  | artifactPlanVersion plan /= 1 = refusal "unsupported artifact plan version"
  | artifactPlanOperation plan /= plannedOperationId operation = refusal "artifact operation identity changed"
  | artifactPlanInputDigest plan /= plannedInputDigest operation = refusal "artifact operation input digest changed"
  | artifactPlanResource plan `notElem` plannedResources operation = refusal "artifact plan names a resource outside the common operation"
  | otherwise = case Map.lookup (artifactPlanResource plan) specs of
      Nothing -> refusal "artifact resource is absent from the declaration bundle"
      Just spec
        | artifactKind spec /= artifactPlanKind plan -> refusal "artifact kind changed"
        | artifactContentDigest spec /= artifactPlanExpectedDigest plan -> refusal "artifact content digest changed"
        | plannedAction operation == RetireResource && artifactConsumers spec == ConsumerCompletenessUnknown -> refusal "artifact consumer completeness is unknown; automatic collection is forbidden"
        | otherwise -> Right ()
  where
    refusal = Left . PrepareRefused (plannedOperationId operation)

decodePlan :: Map ResourceId ArtifactResourceSpec -> PlannedOperation -> ByteString -> Either Text ArtifactMutationPlan
decodePlan specs operation bytes = do
  plan <- first T.pack (eitherDecodeStrict bytes)
  first renderPrepare (validatePlan specs operation plan)
  pure plan
  where
    renderPrepare (PrepareRefused _ message) = message
    renderPrepare (PreparationBlocked barrier) = barrierReason barrier

preflightObservation :: ArtifactMutationPlan -> ArtifactObservation -> Either Text ()
preflightObservation plan observation = case observation of
  ArtifactMissing _ -> Right ()
  ArtifactPresent _ digest
    | digest == artifactPlanExpectedDigest plan -> Right ()
    | otherwise -> Left "a named remote artifact exists with a different digest"
  ArtifactOwnershipMismatch _ reason -> Left ("remote artifact ownership mismatch: " <> reason)
  ArtifactObservationUnavailable reason -> Left ("artifact observation unavailable: " <> reason)

recoveryObservation :: ArtifactMutationPlan -> ArtifactObservation -> RecoveryDecision
recoveryObservation plan observation = case observation of
  ArtifactPresent physical digest
    | digest == artifactPlanExpectedDigest plan -> RecoveryProvedComplete (artifactCompletionProof plan physical)
  ArtifactMissing _ -> RecoverySafeToRetry
  ArtifactPresent _ _ -> RecoveryUnresolved "named remote artifact has a different digest"
  ArtifactOwnershipMismatch _ reason -> RecoveryUnresolved reason
  ArtifactObservationUnavailable reason -> RecoveryUnresolved reason

artifactCompletionProof :: ArtifactMutationPlan -> PhysicalIdentity -> ContentDigest
artifactCompletionProof plan physical =
  contentDigest (either (error . T.unpack) id (canonicalValue (object ["plan" .= plan, "physicalIdentity" .= physical])))

summary :: ArtifactMutationPlan -> Text
summary plan =
  "publish "
    <> T.pack (show (artifactPlanKind plan))
    <> " to "
    <> artifactPlanDestination plan
    <> " at "
    <> digestText (artifactPlanExpectedDigest plan)

instance ToJSON ArtifactMutationPlan where
  toJSON plan =
    object
      [ "version" .= artifactPlanVersion plan
      , "operation" .= artifactPlanOperation plan
      , "inputDigest" .= artifactPlanInputDigest plan
      , "resource" .= artifactPlanResource plan
      , "kind" .= artifactPlanKind plan
      , "destination" .= artifactPlanDestination plan
      , "expectedDigest" .= artifactPlanExpectedDigest plan
      , "sourceDigest" .= artifactPlanSourceDigest plan
      , "configurationDigest" .= artifactPlanConfigurationDigest plan
      ]

instance FromJSON ArtifactMutationPlan where
  parseJSON = withObject "artifact mutation plan" $ \o ->
    ArtifactMutationPlan <$> o .: "version" <*> o .: "operation" <*> o .: "inputDigest" <*> o .: "resource" <*> o .: "kind" <*> o .: "destination" <*> o .: "expectedDigest" <*> o .: "sourceDigest" <*> o .:? "configurationDigest"
