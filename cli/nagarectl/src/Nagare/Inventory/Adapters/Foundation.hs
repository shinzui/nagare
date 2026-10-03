-- | Reviewed, receipt-backed effects that precede the Pulumi backend.
module Nagare.Inventory.Adapters.Foundation
  ( FoundationTarget (..)
  , FoundationNativePlan (..)
  , FoundationObservation (..)
  , FoundationAdapterOps (..)
  , foundationTargetDigest
  , mkFoundationAdapter
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Ops.PulumiBackend
  ( bucketCreateArgs
  , bucketIamArgs
  , bucketUpdateArgs
  )
import Nagare.Resource.Inventory (Executor (CloudFoundationExecutor))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data FoundationTarget
  = -- | Target project, bucket, location, optional bucket-scoped member.
    FoundationBucket !Name !Name !Name !(Maybe Text)
  | -- | Target project and API service.
    FoundationService !Name !Name
  | -- | Project, stack, backend URL, program directory, Pulumi home, optional
    -- GCS backend bucket, and the exact plain-text config to seed.
    FoundationStack !Name !Name !Text !FilePath !FilePath !(Maybe Name) ![(Text, Text)]
  deriving stock (Eq, Show, Generic)

data FoundationNativePlan = FoundationNativePlan
  { foundationPlanVersion :: !Int
  , foundationPlanOperation :: !OperationId
  , foundationPlanInputDigest :: !ContentDigest
  , foundationPlanAction :: !OperationAction
  , foundationPlanResource :: !ResourceId
  , foundationPlanTarget :: !FoundationTarget
  , foundationPlanCommands :: ![[Text]]
  }
  deriving stock (Eq, Show, Generic)

data FoundationObservation
  = FoundationAbsent !ContentDigest
  | FoundationPresent !PhysicalIdentity !ContentDigest
  | FoundationForeign !PhysicalIdentity !Text
  | FoundationUnavailable !Text
  deriving stock (Eq, Show, Generic)

data FoundationAdapterOps = FoundationAdapterOps
  { foundationInspect :: !(FoundationTarget -> IO FoundationObservation)
  , foundationMutate :: !(FoundationNativePlan -> IO AdapterExecution)
  }

foundationTargetDigest :: FoundationTarget -> ContentDigest
foundationTargetDigest target =
  contentDigest
    ( canonicalBytes
        ( case target of
            FoundationStack project stack backend _ _ bucket config ->
              object
                [ "kind" .= ("stack" :: Text)
                , "project" .= project
                , "stack" .= stack
                , "backend" .= backend
                , "bucket" .= bucket
                , "config" .= config
                ]
            _ -> toJSON target
        )
    )

mkFoundationAdapter :: Map ResourceId FoundationTarget -> FoundationAdapterOps -> Adapter
mkFoundationAdapter targets ops =
  Adapter
    { adapterExecutor = CloudFoundationExecutor
    , adapterIdentity = "gcloud-foundation"
    , adapterVersion = "1"
    , adapterObserve = observeResources
    , adapterPrepare = prepare
    , adapterPreflight = preflight
    , adapterExecute = executePlan
    , adapterVerify = verifyPlan
    , adapterRecover = recoverPlan
    }
  where
    observeResources resources = do
      observations <- traverse observeOne resources
      pure (observationSet observations)
    observeOne resource = case Map.lookup resource targets of
      Nothing -> pure (resource, ObservationUnavailable "foundation resource has no execution target")
      Just target -> do
        state <- foundationInspect ops target
        pure (resource, toResourceObservation target state)
    prepare operation = pure $ do
      plan <- makePlan targets operation
      bytes <-
        first
          (PrepareRefused (plannedOperationId operation))
          (canonicalValue (toJSON plan))
      pure (PreparedNative bytes (T.intercalate "; " (map T.unwords (foundationPlanCommands plan))))
    preflight operation prepared = case decodePlan targets operation (preparedNativeBytes prepared) of
      Left err -> pure (Left err)
      Right plan -> preflightState plan <$> foundationInspect ops (foundationPlanTarget plan)
    executePlan operation prepared = case decodePlan targets operation (preparedNativeBytes prepared) of
      Left err -> pure (AdapterEffectFailed (KnownNoEffect err))
      Right plan -> do
        state <- foundationInspect ops (foundationPlanTarget plan)
        case preflightState plan state of
          Left err -> pure (AdapterEffectFailed (KnownNoEffect err))
          Right () -> case state of
            FoundationPresent _ digest | digest == foundationTargetDigest (foundationPlanTarget plan) -> pure AdapterEffectCompleted
            _ -> foundationMutate ops plan
    verifyPlan operation prepared = case decodePlan targets operation (preparedNativeBytes prepared) of
      Left err -> pure (Left err)
      Right plan -> do
        state <- foundationInspect ops (foundationPlanTarget plan)
        pure $ case state of
          FoundationPresent physical digest
            | digest == foundationTargetDigest (foundationPlanTarget plan) ->
                Right (completionProof plan physical)
          _ -> Left "cloud foundation resource has not converged to the reviewed target"
    recoverPlan operation prepared = case decodePlan targets operation (preparedNativeBytes prepared) of
      Left err -> pure (RecoveryUnresolved err)
      Right plan -> do
        state <- foundationInspect ops (foundationPlanTarget plan)
        pure $ case state of
          FoundationPresent physical digest
            | digest == foundationTargetDigest (foundationPlanTarget plan) ->
                RecoveryProvedComplete (completionProof plan physical)
          FoundationAbsent _ | foundationPlanAction plan == CreateResource -> RecoverySafeToRetry
          FoundationForeign _ err -> RecoveryUnresolved err
          FoundationUnavailable err -> RecoveryUnresolved err
          _ -> RecoveryUnresolved "cloud foundation state differs from the reviewed target"

toResourceObservation :: FoundationTarget -> FoundationObservation -> ResourceObservation
toResourceObservation target state = case state of
  FoundationAbsent proof -> ConfirmedAbsent proof
  FoundationPresent physical digest
    | digest == foundationTargetDigest target -> ObservedPresent physical
    | otherwise -> ObservedDrifted physical digest
  FoundationForeign physical _ -> ObservedForeign physical
  FoundationUnavailable err -> ObservationUnavailable err

makePlan :: Map ResourceId FoundationTarget -> PlannedOperation -> Either PrepareError FoundationNativePlan
makePlan targets operation = do
  resource <- case NE.toList (plannedResources operation) of
    [single] -> Right single
    _ -> refusal "foundation operation must name exactly one resource"
  target <- maybe (refusal "foundation resource has no execution target") Right (Map.lookup resource targets)
  unless
    (plannedExecutor operation == CloudFoundationExecutor)
    (refusal "foundation executor changed")
  unless
    (plannedAction operation `elem` [CreateResource, UpdateResource, VerifyResource, AdoptResource])
    (refusal "foundation action requires a separate reviewed lifecycle contract")
  pure
    FoundationNativePlan
      { foundationPlanVersion = 1
      , foundationPlanOperation = plannedOperationId operation
      , foundationPlanInputDigest = plannedInputDigest operation
      , foundationPlanAction = plannedAction operation
      , foundationPlanResource = resource
      , foundationPlanTarget = target
      , foundationPlanCommands = commands target
      }
  where
    refusal :: Text -> Either PrepareError a
    refusal = Left . PrepareRefused (plannedOperationId operation)

decodePlan :: Map ResourceId FoundationTarget -> PlannedOperation -> ByteString -> Either Text FoundationNativePlan
decodePlan targets operation bytes = do
  retained <- first T.pack (eitherDecodeStrict bytes)
  expected <- first renderPrepare (makePlan targets operation)
  unless (retained == expected) (Left "retained foundation plan differs from the reviewed target")
  pure retained
  where
    renderPrepare (PrepareRefused _ err) = err
    renderPrepare (PreparationBlocked barrier) = barrierReason barrier

preflightState :: FoundationNativePlan -> FoundationObservation -> Either Text ()
preflightState plan state = case state of
  FoundationForeign _ err -> Left ("foreign cloud foundation resource: " <> err)
  FoundationUnavailable err -> Left ("cloud foundation observation unavailable: " <> err)
  FoundationPresent _ digest
    | digest == foundationTargetDigest (foundationPlanTarget plan) -> Right ()
    | foundationPlanAction plan == UpdateResource -> Right ()
    | otherwise -> Left "cloud foundation resource changed since review"
  FoundationAbsent _
    | foundationPlanAction plan == CreateResource -> Right ()
    | otherwise -> Left "cloud foundation resource is absent"

completionProof :: FoundationNativePlan -> PhysicalIdentity -> ContentDigest
completionProof plan physical =
  contentDigest
    ( canonicalBytes
        (object ["plan" .= plan, "physicalIdentity" .= physical])
    )

commands :: FoundationTarget -> [[Text]]
commands target = case target of
  FoundationBucket project bucket location member ->
    map
      (("gcloud" :) . map T.pack)
      ( [ bucketCreateArgs (nameText bucket) (nameText project) (nameText location)
        , bucketUpdateArgs (nameText bucket)
        ]
          <> maybe [] (\value -> [bucketIamArgs (nameText bucket) value]) member
      )
  FoundationService project service ->
    [["gcloud", "services", "enable", nameText service, "--project=" <> nameText project]]
  FoundationStack _ stack _ pulumiDir _ _ config ->
    [ "pulumi"
    , "-C"
    , T.pack pulumiDir
    , "stack"
    , "init"
    , nameText stack
    , "--yes"
    , "--no-select"
    ]
      : [ [ "pulumi"
          , "-C"
          , T.pack pulumiDir
          , "config"
          , "set"
          , "--stack"
          , nameText stack
          , key
          , value
          ]
        | (key, value) <- config
        ]

canonicalBytes :: Value -> ByteString
canonicalBytes = either (error . T.unpack) id . canonicalValue

instance ToJSON FoundationTarget where
  toJSON target = case target of
    FoundationBucket project bucket location member ->
      object
        [ "kind" .= ("bucket" :: Text)
        , "project" .= project
        , "bucket" .= bucket
        , "location" .= location
        , "member" .= member
        ]
    FoundationService project service ->
      object
        ["kind" .= ("service" :: Text), "project" .= project, "service" .= service]
    FoundationStack project stack backend pulumiDir pulumiHome bucket config ->
      object
        [ "kind" .= ("stack" :: Text)
        , "project" .= project
        , "stack" .= stack
        , "backend" .= backend
        , "pulumiDir" .= pulumiDir
        , "pulumiHome" .= pulumiHome
        , "bucket" .= bucket
        , "config" .= config
        ]

instance FromJSON FoundationTarget where
  parseJSON = withObject "foundation target" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "bucket" ->
        FoundationBucket
          <$> o .: "project"
          <*> o .: "bucket"
          <*> o .: "location"
          <*> o .:? "member"
      "service" -> FoundationService <$> o .: "project" <*> o .: "service"
      "stack" ->
        FoundationStack
          <$> o .: "project"
          <*> o .: "stack"
          <*> o .: "backend"
          <*> o .: "pulumiDir"
          <*> o .: "pulumiHome"
          <*> o .:? "bucket"
          <*> o .: "config"
      _ -> fail "unknown foundation target kind"

instance ToJSON FoundationNativePlan where
  toJSON plan =
    object
      [ "version" .= foundationPlanVersion plan
      , "operation" .= foundationPlanOperation plan
      , "inputDigest" .= foundationPlanInputDigest plan
      , "action" .= foundationPlanAction plan
      , "resource" .= foundationPlanResource plan
      , "target" .= foundationPlanTarget plan
      , "commands" .= foundationPlanCommands plan
      ]

instance FromJSON FoundationNativePlan where
  parseJSON = withObject "foundation native plan" $ \o ->
    FoundationNativePlan
      <$> o .: "version"
      <*> o .: "operation"
      <*> o .: "inputDigest"
      <*> o .: "action"
      <*> o .: "resource"
      <*> o .: "target"
      <*> o .: "commands"
