-- | A topic has a reviewed logical claim inside one broker. Existing topics
-- cannot be adopted by name, and a lost creation acknowledgement cannot prove
-- that the observed topic is the same incarnation.
module Nagare.Inventory.Adapters.Broker
  ( TopicBinding (..)
  , TopicMutationPlan (..)
  , TopicObservation (..)
  , TopicAdapterOps (..)
  , topicSpecsFromDeclarations
  , mkTopicAdapter
  ) where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (Durable), LifecyclePolicy (Retain))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data TopicBinding = TopicBinding
  { topicDeclaration :: !ManagedResource
  , topicNamespace :: !Name
  , topicBrokerName :: !Name
  } deriving stock (Eq, Show)

data TopicMutationPlan = TopicMutationPlan
  { topicPlanVersion :: !Int
  , topicPlanOperation :: !OperationId
  , topicPlanAction :: !OperationAction
  , topicPlanInputDigest :: !ContentDigest
  , topicPlanResource :: !ResourceId
  , topicPlanBroker :: !ResourceId
  , topicPlanName :: !Name
  , topicPlanPartitions :: !Int
  , topicPlanReplicas :: !Int
  , topicPlanRetentionMs :: !(Maybe Int)
  , topicPlanPreviousRetentionMs :: !(Maybe Int)
  } deriving stock (Eq, Show, Generic)

data TopicObservation
  = TopicMissing
  | TopicPresent !PhysicalIdentity !Int !Int !(Maybe Int)
  | TopicUnavailable !Text
  deriving stock (Eq, Show)

data TopicAdapterOps = TopicAdapterOps
  { topicInspect :: !(ResourceId -> IO TopicObservation)
  , topicCreate :: !(TopicMutationPlan -> IO AdapterExecution)
  , topicAlterRetention :: !(TopicMutationPlan -> IO AdapterExecution)
  }

topicSpecsFromDeclarations :: [Declaration] -> Either Text (Map ResourceId TopicBinding)
topicSpecsFromDeclarations declarations = Map.fromList <$> traverse bind topics
  where
    byId = Map.fromList [(declarationId declaration, declaration) | declaration <- declarations]
    topics = [resource | Managed resource <- declarations, resource ^. #executor == BrokerExecutor]
    bind resource = case (resource ^. #address, resource ^. #spec) of
      (BrokerTopic broker _, LogicalBrokerTopic _ _ _) -> case Map.lookup broker byId of
        Just (Managed target) -> case target ^. #address of
          Kubernetes _ "apps" kind (Just namespace) name
            | nameText kind == "statefulset"
            , target ^. #owner == resource ^. #owner
            , OrderedAfter broker `elem` (resource ^. #dependencies)
            , resource ^. #lifecycle == Retain
            , Durable _ <- resource ^. #dataPolicy
            , StatefulSet {} <- target ^. #spec ->
                Right (resource ^. #identity, TopicBinding resource namespace name)
          _ -> Left "topic broker dependency is not an owned retained Redpanda StatefulSet contract"
        _ -> Left "topic broker StatefulSet is absent from the inventory"
      _ -> Left "broker executor resource lacks a logical topic specification"

mkTopicAdapter :: Map ResourceId ManagedResource -> Map ResourceId TopicBinding -> TopicAdapterOps -> Adapter
mkTopicAdapter accepted specs ops = Adapter
  { adapterExecutor = BrokerExecutor
  , adapterIdentity = "reviewed-redpanda-topic"
  , adapterVersion = "1"
  , adapterObserve = \resources -> do
      entries <- traverse observe resources
      pure (sequence entries >>= observationSet)
  , adapterPrepare = \operation -> pure $ do
      plan <- first (PrepareRefused (plannedOperationId operation)) (planFor accepted specs operation)
      bytes <- first (PrepareRefused (plannedOperationId operation)) (canonicalValue (toJSON plan))
      pure (PreparedNative bytes (summary plan))
  , adapterPreflight = \operation prepared -> case decodePlan accepted specs operation (preparedNativeBytes prepared) of
      Left reason -> pure (Left reason)
      Right plan -> do
        fact <- topicInspect ops (topicPlanResource plan)
        pure (case (topicPlanAction plan, fact) of
          (CreateResource, TopicMissing) -> Right ()
          (VerifyResource, TopicPresent _ partitions replicas retention)
            | matches plan partitions replicas retention -> Right ()
          (UpdateResource, TopicPresent _ partitions replicas retention)
            | partitions == topicPlanPartitions plan
            , replicas == topicPlanReplicas plan
            , retention == topicPlanPreviousRetentionMs plan -> Right ()
          (_, TopicUnavailable reason) -> Left reason
          (CreateResource, TopicPresent {}) -> Left "topic already exists and has no reviewed ownership"
          _ -> Left "topic observation differs from the reviewed action")
  , adapterExecute = \operation prepared -> case decodePlan accepted specs operation (preparedNativeBytes prepared) of
      Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
      Right plan -> case topicPlanAction plan of
        VerifyResource -> pure AdapterEffectCompleted
        CreateResource -> do
          fact <- topicInspect ops (topicPlanResource plan)
          case fact of
            TopicMissing -> topicCreate ops plan
            TopicPresent {} -> pure (AdapterEffectFailed (KnownNoEffect "topic appeared before reviewed creation"))
            TopicUnavailable reason -> pure (AdapterEffectAmbiguous reason)
        UpdateResource -> do
          fact <- topicInspect ops (topicPlanResource plan)
          case fact of
            TopicPresent _ partitions replicas retention
              | partitions == topicPlanPartitions plan
              , replicas == topicPlanReplicas plan
              , retention == topicPlanPreviousRetentionMs plan -> topicAlterRetention ops plan
            TopicUnavailable reason -> pure (AdapterEffectAmbiguous reason)
            _ -> pure (AdapterEffectFailed (KnownNoEffect "topic no longer matches the reviewed previous retention"))
        _ -> pure (AdapterEffectFailed (KnownNoEffect "topic action is unsupported"))
  , adapterVerify = \operation prepared -> case decodePlan accepted specs operation (preparedNativeBytes prepared) of
      Left reason -> pure (Left reason)
      Right plan -> do
        fact <- topicInspect ops (topicPlanResource plan)
        pure (case fact of
          TopicPresent physical partitions replicas retention
            | matches plan partitions replicas retention ->
                Right (proof plan physical)
          TopicMissing -> Left "topic is absent after reviewed execution"
          TopicPresent {} -> Left "topic settings differ from review"
          TopicUnavailable reason -> Left reason)
  , adapterRecover = \operation prepared -> case decodePlan accepted specs operation (preparedNativeBytes prepared) of
      Left reason -> pure (RecoveryUnresolved reason)
      Right plan -> do
        fact <- topicInspect ops (topicPlanResource plan)
        pure (case fact of
          TopicMissing | topicPlanAction plan == CreateResource -> RecoverySafeToRetry
          _ | topicPlanAction plan == UpdateResource ->
            RecoveryUnresolved "topic retention update may have taken effect; inspect the journal and topic before recovery"
          TopicPresent physical partitions replicas retention
            | topicPlanAction plan == VerifyResource
            , matches plan partitions replicas retention -> RecoveryProvedComplete (proof plan physical)
          TopicPresent {} -> RecoveryUnresolved "topic is present but rpk cannot prove its creation incarnation"
          TopicUnavailable reason -> RecoveryUnresolved reason
          _ -> RecoveryUnresolved "topic action cannot be recovered")
  }
  where
    observe resource = case Map.lookup resource specs of
      Nothing -> pure (Left "topic resource is absent from the reviewed declarations")
      Just binding -> do
        fact <- topicInspect ops resource
        pure $ case fact of
          TopicMissing -> Right (resource, ConfirmedAbsent (contentDigest (TE.encodeUtf8 (resourceIdText resource <> ":absent"))))
          TopicPresent physical partitions replicas retention
            | Map.notMember resource accepted -> Right (resource, ObservedUnowned physical)
            | otherwise -> case topicDeclaration binding ^. #spec of
                LogicalBrokerTopic wantedPartitions wantedReplicas wantedRetention
                  | wantedPartitions == partitions && wantedReplicas == replicas
                    && maybe True (\wanted -> retention == Just wanted) wantedRetention ->
                      Right (resource, ObservedPresent physical)
                _ -> Right (resource, ObservedDrifted physical (contentDigest (TE.encodeUtf8 (T.pack (show (partitions, replicas, retention))))))
          TopicUnavailable reason -> Right (resource, ObservationUnavailable reason)
    summary plan = case topicPlanAction plan of
      UpdateResource -> "change broker topic " <> nameText (topicPlanName plan)
        <> " retention.ms from " <> renderRetention (topicPlanPreviousRetentionMs plan)
        <> " to " <> renderRetention (topicPlanRetentionMs plan)
      _ -> "review broker topic " <> nameText (topicPlanName plan)
    renderRetention = maybe "inherited" (T.pack . show)

planFor :: Map ResourceId ManagedResource -> Map ResourceId TopicBinding -> PlannedOperation -> Either Text TopicMutationPlan
planFor accepted specs operation = do
  resource <- case NE.toList (plannedResources operation) of
    [single] -> Right single
    _ -> Left "topic operation must affect exactly one topic"
  binding <- maybe (Left "topic declaration is absent") Right (Map.lookup resource specs)
  (broker, name, partitions, replicas, retention) <- case
      (topicDeclaration binding ^. #address, topicDeclaration binding ^. #spec) of
    (BrokerTopic target topicName, LogicalBrokerTopic p r ms) -> Right (target, topicName, p, r, ms)
    _ -> Left "topic declaration has an invalid address or specification"
  previousRetention <- case plannedAction operation of
    UpdateResource -> case Map.lookup resource accepted of
      Nothing -> Left "topic update lacks an accepted previous declaration"
      Just old -> case (old ^. #address, old ^. #spec, retention) of
        (BrokerTopic oldBroker oldName, LogicalBrokerTopic oldPartitions oldReplicas (Just oldRetention), Just newRetention)
          | oldBroker == broker && oldName == name
          , oldPartitions == partitions && oldReplicas == replicas
          , oldRetention /= newRetention -> Right (Just oldRetention)
        _ -> Left "reviewed topic update supports only an explicit retention change with unchanged broker, partitions, and replicas"
    CreateResource -> Right Nothing
    VerifyResource -> Right Nothing
    _ -> Left "topic replacement, adoption, and retirement need a separate reviewed capability"
  let wireVersion = if plannedAction operation == UpdateResource then 2 else 1
  pure (TopicMutationPlan wireVersion (plannedOperationId operation) (plannedAction operation)
    (plannedInputDigest operation) resource broker name partitions replicas retention previousRetention)

decodePlan :: Map ResourceId ManagedResource -> Map ResourceId TopicBinding -> PlannedOperation -> ByteString -> Either Text TopicMutationPlan
decodePlan accepted specs operation bytes = do
  plan <- first T.pack (eitherDecodeStrict bytes)
  expected <- planFor accepted specs operation
  unless (plan == expected) (Left "private topic mutation differs from the reviewed declaration")
  pure plan

matches :: TopicMutationPlan -> Int -> Int -> Maybe Int -> Bool
matches plan partitions replicas retention =
  topicPlanPartitions plan == partitions && topicPlanReplicas plan == replicas
    && maybe True (\wanted -> retention == Just wanted) (topicPlanRetentionMs plan)

proof :: TopicMutationPlan -> PhysicalIdentity -> ContentDigest
proof plan physical = contentDigest (either (error . T.unpack) id
  (canonicalValue (object ["plan" .= plan, "physical" .= physical])))

instance ToJSON TopicMutationPlan where
  toJSON plan = object
    [ "version" .= topicPlanVersion plan
    , "operation" .= topicPlanOperation plan
    , "action" .= topicPlanAction plan
    , "inputDigest" .= topicPlanInputDigest plan
    , "resource" .= topicPlanResource plan
    , "broker" .= topicPlanBroker plan
    , "name" .= topicPlanName plan
    , "partitions" .= topicPlanPartitions plan
    , "replicas" .= topicPlanReplicas plan
    , "retentionMs" .= topicPlanRetentionMs plan
    , "previousRetentionMs" .= topicPlanPreviousRetentionMs plan
    ]

instance FromJSON TopicMutationPlan where
  parseJSON = withObject "topic mutation plan" $ \o -> TopicMutationPlan
    <$> o .: "version" <*> o .: "operation" <*> o .: "action" <*> o .: "inputDigest"
    <*> o .: "resource" <*> o .: "broker" <*> o .: "name" <*> o .: "partitions"
    <*> o .: "replicas" <*> o .: "retentionMs" <*> o .:? "previousRetentionMs"
