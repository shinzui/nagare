-- | Versioned provider adapters. Adapters receive typed operations, never shell text.
module Nagare.Inventory.Adapter
  ( ResourceObservation (..)
  , ObservationSet
  , observationSet
  , observationMap
  , MigrationObservationSet
  , migrationObservationSet
  , migrationObservationMap
  , OperationAction (..)
  , MigrationStage (..)
  , PlannedOperation (..)
  , PreparedNative (..)
  , ReviewBarrier (..)
  , PrepareError (..)
  , AdapterExecution (..)
  , RecoveryDecision (..)
  , Adapter (..)
  , AdapterFence (..)
  , AdapterRegistry
  , AdapterRecovery (..)
  , withAdapterRecovery
  , lookupAdapterRecovery
  , mkAdapterRegistry
  , emptyAdapterRegistry
  , withAdapterFence
  , lookupAdapter
  , withPreparationGuard
  , lookupAdapterFences
  , lookupAdapterFenceByCapability
  , observeWithRegistry
  )
where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.DataFence (DataFenceControls)
import Nagare.Inventory.Journal
import Nagare.Inventory.Store (DataFenceRecord)
import Nagare.Resource.Inventory (Executor)
import Nagare.Resource.Policy (RecoveryClass)
import Nagare.Resource.Types
import Nagare.Resource.Wire ()

data ResourceObservation
  = ObservedPresent !PhysicalIdentity
  | ObservedDrifted !PhysicalIdentity !ContentDigest
  | ObservedReplacementRequired !PhysicalIdentity !ContentDigest
  | ObservedUnowned !PhysicalIdentity
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

-- | Two observations for one logical identity must remain separate. The
-- ordinary observation map can describe only the desired incarnation.
newtype MigrationObservationSet = MigrationObservationSet
  (Map ResourceId (ResourceObservation, ResourceObservation))
  deriving stock (Eq, Show)

migrationObservationSet
  :: Set ResourceId -> ObservationSet -> ObservationSet
  -> Either Text MigrationObservationSet
migrationObservationSet expected sources destinations
  | Map.keysSet sourceMap /= expected = Left "migration source observation coverage differs from the requested resources"
  | Map.keysSet destinationMap /= expected = Left "migration destination observation coverage differs from the requested resources"
  | otherwise = Right (MigrationObservationSet (Map.intersectionWith (,) sourceMap destinationMap))
  where
    sourceMap = observationMap sources
    destinationMap = observationMap destinations

migrationObservationMap :: MigrationObservationSet -> Map ResourceId (ResourceObservation, ResourceObservation)
migrationObservationMap (MigrationObservationSet values) = values

data MigrationStage
  = PrepareDestination
  | BackUpSource
  | FenceWriters
  | TransferState
  | VerifyDestination
  | SwitchConsumers
  | AdmitWrites
  | RetainSource
  deriving stock (Eq, Ord, Show, Generic)

data OperationAction
  = CreateResource | UpdateResource | VerifyResource | AdoptResource | RetireResource
  | RunDeclaredOperation | OpenMaintenanceSession | RestoreLiveDatabase
  | MigrateResource !MigrationStage
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
  -- The exact created workload exists, but readiness is not completion.
  | RecoveryAwaitingReadiness !PhysicalIdentity
  | RecoveryTerminalFailure !PhysicalIdentity
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

-- | Planning may read current provider facts to capture one private fence
-- record. Apply reconstructs controls from that exact saved record; it must
-- not recapture provider intent from a later observation. Native effects occur
-- only after admission.
data AdapterFence = AdapterFence
  { fenceCapability :: !Text
  , fenceForOperation :: !(PlannedOperation -> PreparedNative
      -> IO (Either Text (Maybe DataFenceRecord)))
  , fenceFromReviewedRecord :: !(DataFenceRecord -> PlannedOperation
      -> PreparedNative -> Either Text DataFenceControls)
  , fenceResolveUncertainEffect :: !(Maybe (DataFenceRecord -> PlannedOperation
      -> PreparedNative -> IO RecoveryDecision))
  , fenceRestoreRecoveryBackup :: !(Maybe (DataFenceRecord -> PlannedOperation
      -> PreparedNative -> IO (Either Text ContentDigest)))
  , fenceVerifyRecoveryBackup :: !(Maybe (DataFenceRecord -> PlannedOperation
      -> PreparedNative -> IO (Either Text ContentDigest)))
  }

instance ToJSON ResourceObservation where toJSON = genericToJSON defaultOptions

instance FromJSON ResourceObservation where parseJSON = genericParseJSON defaultOptions

instance ToJSON OperationAction where toJSON = genericToJSON defaultOptions

instance FromJSON OperationAction where parseJSON = genericParseJSON defaultOptions

instance ToJSON MigrationStage where toJSON = genericToJSON defaultOptions

instance FromJSON MigrationStage where parseJSON = genericParseJSON defaultOptions

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

-- Recovery prerequisites have their own immutable native proof. They cannot
-- replace a reviewed operation or manufacture its completion evidence.
data AdapterRecovery = AdapterRecovery
  { recoveryCapability :: !Text
  , recoveryPrepare :: !(PlannedOperation -> PreparedNative -> IO (Either Text ByteString))
  , recoveryValidate :: !(PlannedOperation -> PreparedNative -> ByteString -> IO (Either Text ()))
  , recoveryExecute :: !(PlannedOperation -> PreparedNative -> ByteString -> IO (Either Text ContentDigest))
  }

data AdapterRegistry = AdapterRegistry
  (Map Executor Adapter) (Map Executor (Map Text AdapterFence))
  (Map Text AdapterRecovery)

mkAdapterRegistry :: [Adapter] -> Either Text AdapterRegistry
mkAdapterRegistry adapters
  | length adapters == Map.size registry = Right (AdapterRegistry registry Map.empty Map.empty)
  | otherwise = Left "adapter registry contains duplicate executors"
  where
    registry = Map.fromList [(adapterExecutor adapter, adapter) | adapter <- adapters]

emptyAdapterRegistry :: AdapterRegistry
emptyAdapterRegistry = AdapterRegistry Map.empty Map.empty Map.empty

withAdapterFence :: AdapterRegistry -> Executor -> AdapterFence
  -> Either Text AdapterRegistry
withAdapterFence (AdapterRegistry adapters fences recoveries) executor fence
  | Map.notMember executor adapters = Left "data fence has no registered adapter"
  | T.null (fenceCapability fence) = Left "data fence capability identity is empty"
  | Map.member (fenceCapability fence) (Map.findWithDefault Map.empty executor fences) =
      Left "adapter already has this data fence capability"
  | otherwise = Right (AdapterRegistry adapters (Map.insertWith Map.union executor
      (Map.singleton (fenceCapability fence) fence) fences) recoveries)

withAdapterRecovery :: AdapterRegistry -> AdapterRecovery -> Either Text AdapterRegistry
withAdapterRecovery (AdapterRegistry adapters fences recoveries) capability
  | T.null key = Left "adapter recovery capability identity is empty"
  | Map.member key recoveries = Left "adapter recovery capability is duplicated"
  | otherwise = Right (AdapterRegistry adapters fences (Map.insert key capability recoveries))
  where key = recoveryCapability capability

lookupAdapterRecovery :: AdapterRegistry -> Text -> Maybe AdapterRecovery
lookupAdapterRecovery (AdapterRegistry _ _ recoveries) key = Map.lookup key recoveries

lookupAdapter :: AdapterRegistry -> Executor -> Either Text Adapter
lookupAdapter (AdapterRegistry registry _ _) executor =
  maybe (Left ("no adapter registered for " <> showText executor)) Right (Map.lookup executor registry)
  where
    showText = T.pack . show

-- | Narrow a command's review before any native plan is prepared or published.
-- Provider capabilities, recovery handlers and fences remain unchanged.
withPreparationGuard :: (PlannedOperation -> Either Text ()) -> AdapterRegistry -> AdapterRegistry
withPreparationGuard check (AdapterRegistry adapters fences recoveries) =
  AdapterRegistry (Map.map guarded adapters) fences recoveries
  where
    guarded adapter = adapter
      { adapterPrepare = \operation -> case check operation of
          Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
          Right () -> adapterPrepare adapter operation
      }

lookupAdapterFences :: AdapterRegistry -> Executor -> [AdapterFence]
lookupAdapterFences (AdapterRegistry _ fences _) executor =
  maybe [] Map.elems (Map.lookup executor fences)

lookupAdapterFenceByCapability :: AdapterRegistry -> Executor -> Text
  -> Maybe AdapterFence
lookupAdapterFenceByCapability (AdapterRegistry _ fences _) executor capability =
  Map.lookup executor fences >>= Map.lookup capability

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
