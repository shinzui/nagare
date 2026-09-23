-- | Versioned provider adapters. Adapters receive typed operations, never shell text.
module Nagare.Inventory.Adapter
  ( ResourceObservation (..)
  , ObservationSet
  , observationSet
  , observationMap
  , OperationAction (..)
  , PlannedOperation (..)
  , PreparedNative (..)
  , ReviewBarrier (..)
  , PrepareError (..)
  , AdapterExecution (..)
  , RecoveryDecision (..)
  , Adapter (..)
  , AdapterRegistry
  , mkAdapterRegistry
  , emptyAdapterRegistry
  , lookupAdapter
  , observeWithRegistry
  )
where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Journal
import Nagare.Resource.Inventory (Executor)
import Nagare.Resource.Policy (RecoveryClass)
import Nagare.Resource.Types
import Nagare.Resource.Wire ()

data ResourceObservation
  = ObservedPresent !PhysicalIdentity
  | ObservedDrifted !PhysicalIdentity !ContentDigest
  | ObservedForeign !PhysicalIdentity
  | ConfirmedAbsent !ContentDigest
  | ObservationUnavailable !Text
  deriving stock (Eq, Show, Generic)

newtype ObservationSet = ObservationSet (Map ResourceId ResourceObservation)
  deriving stock (Eq, Show)

observationSet :: [(ResourceId, ResourceObservation)] -> Either Text ObservationSet
observationSet entries
  | length entries == Map.size values = Right (ObservationSet values)
  | otherwise = Left "duplicate resource observation"
  where
    values = Map.fromList entries

observationMap :: ObservationSet -> Map ResourceId ResourceObservation
observationMap (ObservationSet values) = values

data OperationAction = CreateResource | UpdateResource | AdoptResource | RetireResource | RunDeclaredOperation
  deriving stock (Eq, Ord, Show, Generic)

data PlannedOperation = PlannedOperation
  { plannedOperationId :: !OperationId
  , plannedAction :: !OperationAction
  , plannedExecutor :: !Executor
  , plannedResources :: !(NonEmpty ResourceId)
  , plannedInputDigest :: !ContentDigest
  , plannedDependencies :: ![OperationId]
  , plannedRecovery :: !RecoveryClass
  }
  deriving stock (Eq, Show, Generic)

data PreparedNative = PreparedNative
  { preparedNativeBytes :: !ByteString
  , preparedPublicSummary :: !Text
  }
  deriving stock (Eq, Show, Generic)

data ReviewBarrier = ReviewBarrier
  { barrierOperation :: !OperationId
  , barrierReason :: !Text
  }
  deriving stock (Eq, Show, Generic)

data PrepareError
  = PrepareRefused !OperationId !Text
  | PreparationBlocked !ReviewBarrier
  deriving stock (Eq, Show, Generic)

data AdapterExecution
  = AdapterEffectCompleted
  | AdapterEffectFailed !FailureClass
  | AdapterEffectAmbiguous !Text
  deriving stock (Eq, Show, Generic)

data RecoveryDecision
  = RecoveryProvedComplete !ContentDigest
  | RecoverySafeToRetry
  | RecoveryUnresolved !Text
  deriving stock (Eq, Show, Generic)

data Adapter = Adapter
  { adapterExecutor :: !Executor
  , adapterIdentity :: !Text
  , adapterVersion :: !Text
  , adapterObserve :: !([ResourceId] -> IO (Either Text ObservationSet))
  , adapterPrepare :: !(PlannedOperation -> IO (Either PrepareError PreparedNative))
  , adapterPreflight :: !(PlannedOperation -> PreparedNative -> IO (Either Text ()))
  , adapterExecute :: !(PlannedOperation -> PreparedNative -> IO AdapterExecution)
  , adapterVerify :: !(PlannedOperation -> PreparedNative -> IO (Either Text ContentDigest))
  , adapterRecover :: !(PlannedOperation -> PreparedNative -> IO RecoveryDecision)
  }

instance ToJSON ResourceObservation where toJSON = genericToJSON defaultOptions

instance FromJSON ResourceObservation where parseJSON = genericParseJSON defaultOptions

instance ToJSON OperationAction where toJSON = genericToJSON defaultOptions

instance FromJSON OperationAction where parseJSON = genericParseJSON defaultOptions

instance ToJSON PlannedOperation where
  toJSON operation =
    object
      [ "id" .= plannedOperationId operation
      , "action" .= plannedAction operation
      , "executor" .= plannedExecutor operation
      , "resources" .= plannedResources operation
      , "inputDigest" .= plannedInputDigest operation
      , "dependencies" .= plannedDependencies operation
      , "recovery" .= plannedRecovery operation
      ]

instance FromJSON PlannedOperation where
  parseJSON = withObject "PlannedOperation" $ \o ->
    PlannedOperation
      <$> o .: "id"
      <*> o .: "action"
      <*> o .: "executor"
      <*> o .: "resources"
      <*> o .: "inputDigest"
      <*> o .: "dependencies"
      <*> o .: "recovery"

instance ToJSON ReviewBarrier where toJSON = genericToJSON defaultOptions

instance FromJSON ReviewBarrier where parseJSON = genericParseJSON defaultOptions

newtype AdapterRegistry = AdapterRegistry (Map Executor Adapter)

mkAdapterRegistry :: [Adapter] -> Either Text AdapterRegistry
mkAdapterRegistry adapters
  | length adapters == Map.size registry = Right (AdapterRegistry registry)
  | otherwise = Left "adapter registry contains duplicate executors"
  where
    registry = Map.fromList [(adapterExecutor adapter, adapter) | adapter <- adapters]

emptyAdapterRegistry :: AdapterRegistry
emptyAdapterRegistry = AdapterRegistry Map.empty

lookupAdapter :: AdapterRegistry -> Executor -> Either Text Adapter
lookupAdapter (AdapterRegistry registry) executor =
  maybe (Left ("no adapter registered for " <> showText executor)) Right (Map.lookup executor registry)
  where
    showText = T.pack . show

observeWithRegistry :: AdapterRegistry -> Map Executor [ResourceId] -> IO (Either Text ObservationSet)
observeWithRegistry registry requests = do
  results <- traverse observeOne (Map.toAscList requests)
  pure $ do
    observedSets <- sequence results
    observationSet (concatMap (Map.toList . observationMap) observedSets)
  where
    observeOne (executor, resources) = case lookupAdapter registry executor of
      Left err -> pure (Left err)
      Right adapter -> adapterObserve adapter resources
