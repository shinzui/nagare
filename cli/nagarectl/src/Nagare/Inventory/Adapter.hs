-- | Versioned provider adapters. Adapters receive typed operations, never shell text.
module Nagare.Inventory.Adapter
  ( ResourceObservation (..)
  , ObservationSet
  , observationSet
  , observationMap
  , observationStuck
  , observationNotes
  , withObservationNotes
  , withStuckRollouts
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
  , EffectOutcome (..)
  , effectIdentity
  , RecoveryDecision (..)
  , Settlement (..)
  , settleOperationWith
  , settleFromRecovery
  , fencedSettle
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
  , withOverlapCapability
  , overlapAddress
  , wrapRegisteredAdapter
  , withPreparationGuard
  , lookupAdapterFences
  , lookupAdapterFenceByCapability
  , observeWithRegistry
  )
where

import Control.Concurrent.Async (mapConcurrently)
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

-- | What the provider observed for each member, and, beside it, the members
-- whose rollout is stuck behind a pod that is not Ready (EP-181, RES-4 G3),
-- each with a description of that pod. A stuck member is still observed as
-- it is (present), so no consumer of the observations changes meaning; a set
-- rebuilt without the stuck members only proposes no replacement.
--
-- A third map holds informational notes about a member, such as an app
-- database reader's objects that do not exist yet (EP-206). Notes never change
-- planning.
data ObservationSet = ObservationSet !(Map ResourceId ResourceObservation) !(Map ResourceId Text) !(Map ResourceId Text)
  deriving stock (Eq, Show)

observationSet :: [(ResourceId, ResourceObservation)] -> Either Text ObservationSet
observationSet entries
  | length entries == Map.size values = Right (ObservationSet values Map.empty Map.empty)
  | otherwise = Left "duplicate resource observation"
  where
    values = Map.fromList entries

observationMap :: ObservationSet -> Map ResourceId ResourceObservation
observationMap (ObservationSet values _ _) = values

-- | Members whose rollout is stuck, with a description of the blocking pod.
observationStuck :: ObservationSet -> Map ResourceId Text
observationStuck (ObservationSet _ stuck _) = stuck

-- | Record stuck rollouts for members this set observes.
withStuckRollouts :: Map ResourceId Text -> ObservationSet -> ObservationSet
withStuckRollouts stuck (ObservationSet values previous notes) =
  ObservationSet values (Map.union (Map.restrictKeys stuck (Map.keysSet values)) previous) notes

-- | Informational notes about members this set observes.
observationNotes :: ObservationSet -> Map ResourceId Text
observationNotes (ObservationSet _ _ notes) = notes

-- | Record notes for members this set observes.
withObservationNotes :: Map ResourceId Text -> ObservationSet -> ObservationSet
withObservationNotes notes (ObservationSet values stuck previous) =
  ObservationSet values stuck (Map.union (Map.restrictKeys notes (Map.keysSet values)) previous)

-- | Two observations for one logical identity must remain separate. The
-- ordinary observation map can describe only the desired incarnation.
newtype MigrationObservationSet
  = MigrationObservationSet
      (Map ResourceId (ResourceObservation, ResourceObservation))
  deriving stock (Eq, Show)

migrationObservationSet ::
  Set ResourceId ->
  ObservationSet ->
  ObservationSet ->
  Either Text MigrationObservationSet
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
  = CreateResource
  | UpdateResource
  | VerifyResource
  | AdoptResource
  | RetireResource
  | -- | Delete the pod that blocks a member StatefulSet's rollout, so the
    -- controller recreates it at the reviewed template (EP-181, RES-4 G3).
    ReplaceStuckPod
  | RunDeclaredOperation
  | OpenMaintenanceSession
  | RestoreLiveDatabase
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
  | -- | ADR 27: the provider returned the identity of the object this effect
    -- wrote, and the effect then ended as the inner result. A readiness wait
    -- that times out still knows which object it created.
    AdapterEffectIdentified !PhysicalIdentity !AdapterExecution
  deriving stock (Eq, Show, Generic)

-- | An effect's outcome with its provider-returned identity taken off.
data EffectOutcome
  = OutcomeCompleted
  | OutcomeFailed !FailureClass
  | OutcomeAmbiguous !Text
  deriving stock (Eq, Show)

-- | The provider-returned identity, if any (the outermost), and the outcome.
effectIdentity :: AdapterExecution -> (Maybe PhysicalIdentity, EffectOutcome)
effectIdentity = \case
  AdapterEffectCompleted -> (Nothing, OutcomeCompleted)
  AdapterEffectFailed failureClass -> (Nothing, OutcomeFailed failureClass)
  AdapterEffectAmbiguous reason -> (Nothing, OutcomeAmbiguous reason)
  AdapterEffectIdentified physical inner -> (Just physical, snd (effectIdentity inner))

data RecoveryDecision
  = RecoveryProvedComplete !ContentDigest
  | RecoverySafeToRetry
  | -- The exact created workload exists, but readiness is not completion.
    RecoveryAwaitingReadiness !PhysicalIdentity
  | -- The reviewed update landed on the accepted object exactly as reviewed
    -- (same UID, reviewed spec, generation observed, no other field owner),
    -- and its controller reports it not ready. Only a reviewed stop uses it.
    RecoveryLandedUnready !PhysicalIdentity
  | -- The live object at the reviewed update's address is owned by the
    -- member but is not the incarnation the update targeted: it was deleted
    -- and recreated outside review (F56). The conditional write can no longer
    -- land, and nothing proves the live object holds it. Only a reviewed stop
    -- uses it.
    RecoveryTargetReplaced !PhysicalIdentity
  | RecoveryTerminalFailure !PhysicalIdentity
  | RecoveryUnresolved !Text
  deriving stock (Eq, Show, Generic)

-- | ADR 26: what an operation with recorded intent and no completion did,
-- proved from a fresh provider observation. 'SettledUnknown' blocks a close
-- and names what would resolve it.
data Settlement
  = -- | Every address the operation could write is in its reviewed
    -- before-state.
    SettledNoEffect !Text
  | -- | The exact reviewed effect is on the exact reviewed object, which is
    -- not ready.
    SettledLanded !PhysicalIdentity
  | -- | The conditional write can no longer land: the target was deleted, or
    -- replaced under another identity (evidence only; never bound).
    SettledTargetGone !(Maybe PhysicalIdentity)
  | -- | A run-to-completion object of this review failed terminally.
    SettledTerminalPartial !PhysicalIdentity
  | -- | A create of several members stopped partway (F113): the provider's
    -- state holds the first members and proves the second absent.
    SettledPartial ![ResourceId] ![ResourceId]
  | -- | Unproved: the reason, and what would resolve it.
    SettledUnknown !Text !Text
  deriving stock (Eq, Show, Generic)

-- | An adapter's settlement, or one derived from its recovery decision when
-- the adapter has none of its own.
settleOperationWith :: Adapter -> PlannedOperation -> PreparedNative -> IO Settlement
settleOperationWith adapter operation prepared = case adapterSettle adapter of
  Just settle -> settle operation prepared
  Nothing -> settleFromRecovery <$> adapterRecover adapter operation prepared

-- | A fenced data operation keeps its own recovery phases and is excluded
-- from close; every other operation settles as the base adapter does.
fencedSettle :: OperationAction -> Adapter -> PlannedOperation -> PreparedNative -> IO Settlement
fencedSettle fenced base operation prepared
  | plannedAction operation == fenced =
      pure (SettledUnknown "a fenced data operation is excluded from close" "the fenced recovery actions")
  | otherwise = settleOperationWith base operation prepared

settleFromRecovery :: RecoveryDecision -> Settlement
settleFromRecovery decision = case decision of
  RecoveryProvedComplete _ -> SettledUnknown "the effect is proved complete" "inventory resume"
  RecoverySafeToRetry -> SettledUnknown "a retry is safe but the effect is not proved absent" "inventory resume"
  RecoveryAwaitingReadiness physical -> SettledLanded physical
  RecoveryLandedUnready physical -> SettledLanded physical
  RecoveryTargetReplaced physical -> SettledTargetGone (Just physical)
  RecoveryTerminalFailure physical -> SettledTerminalPartial physical
  RecoveryUnresolved reason -> SettledUnknown reason "a provider observation that proves the effect"

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
  , adapterSettle :: !(Maybe (PlannedOperation -> PreparedNative -> IO Settlement))
  -- ^ ADR 26 settlement; 'Nothing' derives it from 'adapterRecover'.
  }

-- | Planning may read current provider facts to capture one private fence
-- record. Apply reconstructs controls from that exact saved record; it must
-- not recapture provider intent from a later observation. Native effects occur
-- only after admission.
data AdapterFence = AdapterFence
  { fenceCapability :: !Text
  , fenceForOperation ::
      !( PlannedOperation ->
         PreparedNative ->
         IO (Either Text (Maybe DataFenceRecord))
       )
  , fenceFromReviewedRecord ::
      !( DataFenceRecord ->
         PlannedOperation ->
         PreparedNative ->
         Either Text DataFenceControls
       )
  , fenceResolveUncertainEffect ::
      !( Maybe
           ( DataFenceRecord ->
             PlannedOperation ->
             PreparedNative ->
             IO RecoveryDecision
           )
       )
  , fenceRestoreRecoveryBackup ::
      !( Maybe
           ( DataFenceRecord ->
             PlannedOperation ->
             PreparedNative ->
             IO (Either Text ContentDigest)
           )
       )
  , fenceVerifyRecoveryBackup ::
      !( Maybe
           ( DataFenceRecord ->
             PlannedOperation ->
             PreparedNative ->
             IO (Either Text ContentDigest)
           )
       )
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

data AdapterRegistry
  = AdapterRegistry
      (Map Executor Adapter)
      (Map Executor (Map Text AdapterFence))
      (Map Text AdapterRecovery)
      (Map Executor (PlannedOperation -> Maybe Text))

mkAdapterRegistry :: [Adapter] -> Either Text AdapterRegistry
mkAdapterRegistry adapters
  | length adapters == Map.size registry = Right (AdapterRegistry registry Map.empty Map.empty Map.empty)
  | otherwise = Left "adapter registry contains duplicate executors"
  where
    registry = Map.fromList [(adapterExecutor adapter, adapter) | adapter <- adapters]

emptyAdapterRegistry :: AdapterRegistry
emptyAdapterRegistry = AdapterRegistry Map.empty Map.empty Map.empty Map.empty

withAdapterFence ::
  AdapterRegistry ->
  Executor ->
  AdapterFence ->
  Either Text AdapterRegistry
withAdapterFence (AdapterRegistry adapters fences recoveries overlaps) executor fence
  | Map.notMember executor adapters = Left "data fence has no registered adapter"
  | T.null (fenceCapability fence) = Left "data fence capability identity is empty"
  | Map.member (fenceCapability fence) (Map.findWithDefault Map.empty executor fences) =
      Left "adapter already has this data fence capability"
  | otherwise =
      Right
        ( AdapterRegistry
            adapters
            ( Map.insertWith
                Map.union
                executor
                (Map.singleton (fenceCapability fence) fence)
                fences
            )
            recoveries
            overlaps
        )

withAdapterRecovery :: AdapterRegistry -> AdapterRecovery -> Either Text AdapterRegistry
withAdapterRecovery (AdapterRegistry adapters fences recoveries overlaps) capability
  | T.null key = Left "adapter recovery capability identity is empty"
  | Map.member key recoveries = Left "adapter recovery capability is duplicated"
  | otherwise = Right (AdapterRegistry adapters fences (Map.insert key capability recoveries) overlaps)
  where
    key = recoveryCapability capability

lookupAdapterRecovery :: AdapterRegistry -> Text -> Maybe AdapterRecovery
lookupAdapterRecovery (AdapterRegistry _ _ recoveries _) key = Map.lookup key recoveries

-- | EP-228 M2: an executor's promise that some of its effects may await
-- readiness while other independent effects of the same transaction do. It
-- names the address an eligible operation writes; operations whose addresses
-- differ may overlap. Every other operation, and every executor without the
-- promise, runs alone.
withOverlapCapability :: Executor -> (PlannedOperation -> Maybe Text) -> AdapterRegistry -> Either Text AdapterRegistry
withOverlapCapability executor eligible (AdapterRegistry adapters fences recoveries overlaps)
  | Map.notMember executor adapters = Left "an overlap capability has no registered adapter"
  | otherwise = Right (AdapterRegistry adapters fences recoveries (Map.insert executor eligible overlaps))

-- | The address an operation may overlap on, or 'Nothing' when it runs alone.
overlapAddress :: AdapterRegistry -> PlannedOperation -> Maybe Text
overlapAddress (AdapterRegistry _ _ _ overlaps) operation = Map.lookup (plannedExecutor operation) overlaps >>= ($ operation)

lookupAdapter :: AdapterRegistry -> Executor -> Either Text Adapter
lookupAdapter (AdapterRegistry registry _ _ _) executor =
  maybe (Left ("no adapter registered for " <> showText executor)) Right (Map.lookup executor registry)
  where
    showText = T.pack . show

-- | Wrap one executor's adapter in place; its fences and recovery
-- capabilities stay registered unchanged.
wrapRegisteredAdapter :: Executor -> (Adapter -> Adapter) -> AdapterRegistry -> Either Text AdapterRegistry
wrapRegisteredAdapter executor wrap (AdapterRegistry adapters fences recoveries overlaps)
  | Map.member executor adapters = Right (AdapterRegistry (Map.adjust wrap executor adapters) fences recoveries overlaps)
  | otherwise = Left ("no adapter registered for " <> T.pack (show executor))

-- | Narrow a command's review before any native plan is prepared or published.
-- Provider capabilities, recovery handlers and fences remain unchanged.
withPreparationGuard :: (PlannedOperation -> Either Text ()) -> AdapterRegistry -> AdapterRegistry
withPreparationGuard check (AdapterRegistry adapters fences recoveries overlaps) =
  AdapterRegistry (Map.map guarded adapters) fences recoveries overlaps
  where
    guarded adapter =
      adapter
        { adapterPrepare = \operation -> case check operation of
            Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
            Right () -> adapterPrepare adapter operation
        }

lookupAdapterFences :: AdapterRegistry -> Executor -> [AdapterFence]
lookupAdapterFences (AdapterRegistry _ fences _ _) executor =
  maybe [] Map.elems (Map.lookup executor fences)

lookupAdapterFenceByCapability ::
  AdapterRegistry ->
  Executor ->
  Text ->
  Maybe AdapterFence
lookupAdapterFenceByCapability (AdapterRegistry _ fences _ _) executor capability =
  Map.lookup executor fences >>= Map.lookup capability

observeWithRegistry :: AdapterRegistry -> Map Executor [ResourceId] -> IO (Either Text ObservationSet)
observeWithRegistry registry requests = do
  -- Executors observe disjoint resources and only read, so they read at
  -- once: a plan waits for its slowest executor, not for their sum (EP-224).
  results <- mapConcurrently observeOne (Map.toAscList requests)
  pure $ do
    observedSets <- sequence results
    withObservationNotes (Map.unions (map observationNotes observedSets)) . withStuckRollouts (Map.unions (map observationStuck observedSets))
      <$> observationSet (concatMap (Map.toList . observationMap) observedSets)
  where
    observeOne (executor, resources) = case lookupAdapter registry executor of
      Left err -> pure (Left err)
      Right adapter -> adapterObserve adapter resources
