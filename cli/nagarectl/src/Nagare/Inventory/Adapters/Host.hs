-- | Receipt-backed adapter for the existing self-reverting host activation protocol.
module Nagare.Inventory.Adapters.Host
  ( HostActivationPlan (..)
  , HostActivationState (..)
  , HostAdapterOps (..)
  , mkHostAdapter
  , hostCompletionProof
  , supportedHostPlanVersion
  , parseHostCommitReceipt
  )
where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Resource.Inventory (Executor (HostExecutor))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data HostActivationPlan = HostActivationPlan
  { hostPlanVersion :: !Int
  , hostPlanOperation :: !OperationId
  , hostPlanInputDigest :: !ContentDigest
  , hostPlanContext :: !ContextId
  , hostPlanAttribute :: !Name
  , hostPlanInstance :: !PhysicalIdentity
  , hostPlanDestination :: !Text
  , hostPlanConfigurationDigest :: !ContentDigest
  , hostPlanLockDigest :: !ContentDigest
  , hostPlanAgeKeyDigest :: !(Maybe ContentDigest)
  , hostPlanPreviousAgeKeyDigest :: !(Maybe ContentDigest)
  , hostPlanCredentialReceiptRequired :: !Bool
  , hostPlanExpectedOldClosure :: !Text
  , hostPlanNewClosure :: !Text
  , hostPlanActivationId :: !Text
  }
  deriving stock (Eq, Show, Generic)

data HostActivationState
  = HostBeforeActivation !PhysicalIdentity !Text
  | HostTimerArmed !PhysicalIdentity !Text
  | HostCommitted !PhysicalIdentity !Text !ContentDigest
  | HostReverted !PhysicalIdentity !Text
  | HostUnreachable !Text
  deriving stock (Eq, Show, Generic)

data HostAdapterOps = HostAdapterOps
  { hostObserveResources :: !([ResourceId] -> IO (Either Text ObservationSet))
  , hostPreparePlan :: !(PlannedOperation -> IO (Either Text HostActivationPlan))
  , hostInspectActivation :: !(HostActivationPlan -> IO HostActivationState)
  , hostRunActivation :: !(HostActivationPlan -> IO AdapterExecution)
  }

mkHostAdapter :: HostAdapterOps -> Adapter
mkHostAdapter ops =
  Adapter
    { adapterExecutor = HostExecutor
    , adapterIdentity = "nixos-safe-activation"
    , adapterVersion = "1"
    , adapterObserve = hostObserveResources ops
    , adapterPrepare = prepare
    , adapterPreflight = preflight
    , adapterExecute = executePlan
    , adapterVerify = verifyPlan
    , adapterSettle = Just settlePlan
    , adapterRecover = recoverPlan
    }
  where
    prepare operation = do
      result <- hostPreparePlan ops operation
      pure $ do
        plan <- first (PrepareRefused (plannedOperationId operation)) result
        validatePlan operation plan
        bytes <- first (PrepareRefused (plannedOperationId operation)) (canonicalValue (toJSON plan))
        pure (PreparedNative bytes (summary plan))
    preflight operation prepared = case decodePlan operation (preparedNativeBytes prepared) of
      Left err -> pure (Left err)
      Right plan -> preflightState plan <$> hostInspectActivation ops plan
    executePlan operation prepared = case decodePlan operation (preparedNativeBytes prepared) of
      Left err -> pure (AdapterEffectFailed (KnownNoEffect err))
      Right plan -> do
        state <- hostInspectActivation ops plan
        case state of
          HostCommitted physical closure _ | physical == hostPlanInstance plan && closure == hostPlanNewClosure plan -> pure AdapterEffectCompleted
          HostTimerArmed {} -> pure (AdapterEffectAmbiguous "host rollback timer remains armed")
          HostUnreachable reason -> pure (AdapterEffectAmbiguous reason)
          _ -> case preflightState plan state of
            Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
            Right () -> hostRunActivation ops plan
    verifyPlan operation prepared = case decodePlan operation (preparedNativeBytes prepared) of
      Left err -> pure (Left err)
      Right plan -> do
        state <- hostInspectActivation ops plan
        pure $ case state of
          HostCommitted physical closure acknowledgement
            | physical == hostPlanInstance plan && closure == hostPlanNewClosure plan -> Right (hostCompletionProof plan acknowledgement)
          _ -> Left "host activation lacks committed-closure acknowledgement"
    recoverPlan operation prepared = case decodePlan operation (preparedNativeBytes prepared) of
      Left err -> pure (RecoveryUnresolved err)
      Right plan -> recoveryState plan <$> hostInspectActivation ops plan
    settlePlan operation prepared = case decodePlan operation (preparedNativeBytes prepared) of
      Left err -> pure (SettledUnknown err "the saved review's native bundle")
      Right plan -> settleState plan <$> hostInspectActivation ops plan

validatePlan :: PlannedOperation -> HostActivationPlan -> Either PrepareError ()
validatePlan operation plan
  | MigrateResource _ <- plannedAction operation = refusal "host adapter has no migration stage contract"
  | not (supportedHostPlanVersion plan) = refusal "unsupported host activation plan version or credential authority"
  | hostPlanOperation plan /= plannedOperationId operation = refusal "host activation operation identity changed"
  | hostPlanInputDigest plan /= plannedInputDigest operation = refusal "host activation input digest changed"
  | (isJust (hostPlanPreviousAgeKeyDigest plan) || hostPlanCredentialReceiptRequired plan) && isNothing (hostPlanAgeKeyDigest plan) = refusal "credential replacement has no desired key digest"
  | T.null (T.strip (hostPlanDestination plan)) = refusal "host activation destination is empty"
  | T.null (T.strip (hostPlanExpectedOldClosure plan)) = refusal "host activation expected closure is empty"
  | T.null (T.strip (hostPlanNewClosure plan)) = refusal "host activation new closure is empty"
  | T.null (T.strip (hostPlanActivationId plan)) = refusal "host activation transaction identity is empty"
  | otherwise = Right ()
  where
    refusal = Left . PrepareRefused (plannedOperationId operation)

-- Version two prevents an older operator from ignoring credential activation
-- receipts. Unchanged version-one plans retain their original wire bytes.
supportedHostPlanVersion :: HostActivationPlan -> Bool
supportedHostPlanVersion plan = case hostPlanVersion plan of
  1 -> isNothing (hostPlanPreviousAgeKeyDigest plan) && not (hostPlanCredentialReceiptRequired plan)
  2 -> hostPlanCredentialReceiptRequired plan && isJust (hostPlanAgeKeyDigest plan)
  _ -> False

decodePlan :: PlannedOperation -> ByteString -> Either Text HostActivationPlan
decodePlan operation bytes = do
  plan <- first T.pack (eitherDecodeStrict bytes)
  first renderPrepare (validatePlan operation plan)
  pure plan
  where
    renderPrepare (PrepareRefused _ message) = message
    renderPrepare (PreparationBlocked barrier) = barrierReason barrier

preflightState :: HostActivationPlan -> HostActivationState -> Either Text ()
preflightState plan state = case state of
  HostBeforeActivation physical closure -> matches physical closure
  HostReverted physical closure -> matches physical closure
  HostCommitted physical closure _
    | physical /= hostPlanInstance plan -> Left "host physical instance changed"
    | closure == hostPlanNewClosure plan -> Right ()
    | otherwise -> Left "host reports a different committed closure"
  HostTimerArmed physical _
    | physical /= hostPlanInstance plan -> Left "host physical instance changed while rollback timer is armed"
    | otherwise -> Left "host rollback timer is armed; inspect or recover it without cancelling the timer"
  HostUnreachable reason -> Left ("host is unreachable: " <> reason)
  where
    matches physical closure
      | physical /= hostPlanInstance plan = Left "host physical instance changed"
      | closure /= hostPlanExpectedOldClosure plan = Left "host old closure changed since review"
      | otherwise = Right ()

-- | Checklist section 3: a started activation whose host runs the reviewed old
-- closure with no rollback timer armed did not commit, or its timer reverted
-- it. ADR 11 forbids switching again without investigation, so resume does not
-- retry it; close proves it had no effect, accepts nothing, and a new review
-- carries any retry.
recoveryState :: HostActivationPlan -> HostActivationState -> RecoveryDecision
recoveryState plan state = case state of
  HostCommitted physical closure acknowledgement
    | physical == hostPlanInstance plan && closure == hostPlanNewClosure plan -> RecoveryProvedComplete (hostCompletionProof plan acknowledgement)
  _ | onOldClosure plan state -> RecoveryUnresolved (oldClosureEvidence plan <> "; close the transaction and review the change again")
  HostTimerArmed {} -> RecoveryUnresolved "host activation is test-active with a rollback timer armed"
  HostUnreachable reason -> RecoveryUnresolved ("host is unreachable: " <> reason)
  _ -> RecoveryUnresolved "host identity or closure does not match the reviewed activation"

settleState :: HostActivationPlan -> HostActivationState -> Settlement
settleState plan state = case state of
  _ | onOldClosure plan state -> SettledNoEffect (oldClosureEvidence plan)
  HostCommitted physical closure _
    | physical == hostPlanInstance plan && closure == hostPlanNewClosure plan -> SettledUnknown "the activation is committed" "inventory resume"
  HostTimerArmed {} -> SettledUnknown "the host rollback timer is armed" "the rollback window to end, then inventory close or resume"
  HostUnreachable reason -> SettledUnknown ("host is unreachable: " <> reason) "a host observation"
  _ -> SettledUnknown "host identity or closure does not match the reviewed activation" "operator investigation of the host"

onOldClosure :: HostActivationPlan -> HostActivationState -> Bool
onOldClosure plan state = case state of
  HostBeforeActivation physical closure -> matches physical closure
  HostReverted physical closure -> matches physical closure
  _ -> False
  where
    matches physical closure = physical == hostPlanInstance plan && closure == hostPlanExpectedOldClosure plan && hostPlanExpectedOldClosure plan /= hostPlanNewClosure plan

oldClosureEvidence :: HostActivationPlan -> Text
oldClosureEvidence plan = "the reviewed host runs its old closure " <> hostPlanExpectedOldClosure plan <> " with no rollback timer armed"

hostCompletionProof :: HostActivationPlan -> ContentDigest -> ContentDigest
hostCompletionProof plan acknowledgement =
  contentDigest
    (either (error . T.unpack) id (canonicalValue (object ["plan" .= plan, "acknowledgement" .= acknowledgement])))

-- | Parse the one public receipt line emitted only after the client opened a
-- fresh SSH connection and the on-host helper committed the new closure.
parseHostCommitReceipt :: ByteString -> Either Text (Text, ContentDigest)
parseHostCommitReceipt output =
  case [line | line <- BC.lines output, "nagare-host-activation\t" `BC.isPrefixOf` line] of
    [line] -> case BC.split '\t' line of
      ["nagare-host-activation", "committed", closure, "fresh-login"]
        | not (BC.null closure) -> Right (T.pack (BC.unpack closure), contentDigest line)
      _ -> Left "host activation receipt is malformed"
    [] -> Left "host activation output has no committed fresh-login receipt"
    _ -> Left "host activation output has more than one committed receipt"

summary :: HostActivationPlan -> Text
summary plan =
  "guarded host activation "
    <> hostPlanActivationId plan
    <> "; instance "
    <> physicalIdentityText (hostPlanInstance plan)
    <> "; closure "
    <> hostPlanNewClosure plan

instance ToJSON HostActivationPlan where
  toJSON plan =
    object $
      [ "version" .= hostPlanVersion plan
      , "operation" .= hostPlanOperation plan
      , "inputDigest" .= hostPlanInputDigest plan
      , "context" .= hostPlanContext plan
      , "hostAttribute" .= hostPlanAttribute plan
      , "instance" .= hostPlanInstance plan
      , "destination" .= hostPlanDestination plan
      , "configurationDigest" .= hostPlanConfigurationDigest plan
      , "lockDigest" .= hostPlanLockDigest plan
      , "ageKeyDigest" .= hostPlanAgeKeyDigest plan
      , "expectedOldClosure" .= hostPlanExpectedOldClosure plan
      , "newClosure" .= hostPlanNewClosure plan
      , "activationId" .= hostPlanActivationId plan
      ]
        <> maybe [] (\digest -> ["previousAgeKeyDigest" .= digest]) (hostPlanPreviousAgeKeyDigest plan)
        <> ["credentialReceiptRequired" .= True | hostPlanCredentialReceiptRequired plan]

instance FromJSON HostActivationPlan where
  parseJSON = withObject "host activation plan" $ \o ->
    HostActivationPlan
      <$> o .: "version"
      <*> o .: "operation"
      <*> o .: "inputDigest"
      <*> o .: "context"
      <*> o .: "hostAttribute"
      <*> o .: "instance"
      <*> o .: "destination"
      <*> o .: "configurationDigest"
      <*> o .: "lockDigest"
      <*> o .:? "ageKeyDigest"
      <*> o .:? "previousAgeKeyDigest"
      <*> o .:? "credentialReceiptRequired" .!= False
      <*> o .: "expectedOldClosure"
      <*> o .: "newClosure"
      <*> o .: "activationId"
