-- | Reviewed one-shot power transitions of an already owned Compute Engine VM.
-- Recovery observes the outcome; an uncertain request is never sent again.
module Nagare.Inventory.VmPower
  ( VmPowerBinding (..)
  , VmPowerObservation (..)
  , VmPowerOps (..)
  , compileVmPower
  , retainVmPowerIntents
  , vmPowerOnly
  , vmPowerBindings
  , vmPowerReceiptKey
  , withVmPower
  )
where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Cloud (NativeRegistration (..), registrationsFromDeclarations)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RecoveryClass (OperatorRecovery))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data VmPowerBinding = VmPowerBinding !ResourceId !ProviderAddress !Bool
  deriving stock (Eq, Show)

data VmPowerObservation = VmPowerObservation
  { vmInstanceId :: !Text
  , vmPowerState :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data VmPowerOps = VmPowerOps
  { vmPowerObserve :: !(ProviderAddress -> IO (Either Text VmPowerObservation))
  , vmPowerSubmit :: !(ProviderAddress -> Bool -> IO (Either Text ()))
  , vmPowerReadReceipt :: !(ContentDigest -> IO (Either Text (Maybe ByteString)))
  , vmPowerWriteReceipt :: !(ContentDigest -> ByteString -> IO (Either Text ()))
  }

data PowerPlan = PowerPlan
  { version :: !Int
  , operation :: !OperationId
  , inputDigest :: !ContentDigest
  , instanceId :: !Text
  , beforeState :: !Text
  , afterState :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PowerReceipt = PowerReceipt
  { receiptPlan :: !PowerPlan
  , receiptObservation :: !VmPowerObservation
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

vmPowerReceiptKey :: ContentDigest -> FilePath
vmPowerReceiptKey digest = "vm-power/" <> T.unpack (digestText digest) <> ".json"

compileVmPower :: ScopeSnapshot -> ProviderAddress -> Text -> Bool -> Either Text ScopeDeclaration
compileVmPower snapshot address requestId start = do
  role <- mkName requestId
  key <- mkLogicalKey "vm-power"
  (scope, resource) <- case [ (scope, resource)
                            | (_, scope) <- Map.elems (snapshotScopes snapshot)
                            , bundle <- scopeBundles scope
                            , Managed resource <- bundle ^. #declarations
                            , matchesInstance address resource
                            , resource ^. #executor == PulumiExecutor
                            , scopeKind (scopeId scope) == Platform
                            ] of
    [single] -> Right single
    _ -> Left "VM power requires one accepted platform-owned instance"
  case address of
    CloudInstance {} -> pure ()
    _ -> Left "VM power requires a Compute Engine instance"
  let intent =
        DeclaredOperation
          { identity = mintResourceId (scopeId scope) key role
          , affects = (resource ^. #identity) NE.:| []
          , inputs = [ContentInput (targetDigest address)]
          , recovery = OperatorRecovery
          , operationKind = if start then StartVm else StopVm
          }
      previous =
        [ op
        | bundle <- scopeBundles scope
        , op <- bundle ^. #operations
        , op ^. #identity == intent ^. #identity
        ]
  case previous of
    [old] | old == intent -> pure scope
    [] -> case scopeBundles scope of
      firstBundle : rest ->
        first
          (T.pack . show)
          ( mkScopeDeclaration
              (scopeId scope)
              (firstBundle {operations = (firstBundle ^. #operations) <> [intent]} : rest)
          )
      [] -> Left "accepted VM scope is empty"
    _ -> Left "VM power operation ID is already bound to a different transition"

vmPowerBindings :: ProviderAddress -> [ScopeDeclaration] -> Either Text (Map ContentDigest VmPowerBinding)
vmPowerBindings address scopes = Map.fromList <$> traverse bind intents
  where
    resources =
      Map.fromList
        [ (resource ^. #identity, resource)
        | scope <- scopes
        , bundle <- scopeBundles scope
        , Managed resource <- bundle ^. #declarations
        ]
    intents =
      [ (scopeId scope, op)
      | scope <- scopes
      , bundle <- scopeBundles scope
      , op <- bundle ^. #operations
      , op ^. #operationKind `elem` [StartVm, StopVm]
      ]
    bind (owner, op) = do
      target <- case NE.toList (op ^. #affects) of
        [single] -> Right single
        _ -> Left "VM power must affect exactly one resource"
      resource <- maybe (Left "VM power resource is missing") Right (Map.lookup target resources)
      unless
        ( resource ^. #owner == owner
            && scopeKind owner == Platform
            && resource ^. #executor == PulumiExecutor
            && op ^. #inputs == [ContentInput (targetDigest address)]
            && op ^. #recovery == OperatorRecovery
        )
        (Left "VM power ownership or recovery differs")
      unless (matchesInstance address resource) (Left "VM power target is not the accepted Compute Engine instance")
      digest <- contentDigest <$> canonicalValue (toJSON op)
      pure (digest, VmPowerBinding target address (op ^. #operationKind == StartVm))

-- Keep completed one-shot IDs when the ordinary cloud compiler repairs drift.
-- This prevents a later use of an old ID from becoming a fresh power request.
retainVmPowerIntents :: ScopeDeclaration -> ScopeDeclaration -> Either Text ScopeDeclaration
retainVmPowerIntents prior next = do
  unless (scopeId prior == scopeId next) (Left "VM power history belongs to another scope")
  case scopeBundles next of
    firstBundle : rest ->
      first
        (T.pack . show)
        ( mkScopeDeclaration
            (scopeId next)
            (firstBundle {operations = (firstBundle ^. #operations) <> intents} : rest)
        )
    [] -> Left "cloud scope is empty"
  where
    intents =
      [ intent
      | bundle <- scopeBundles prior
      , intent <- bundle ^. #operations
      , intent ^. #operationKind `elem` [StartVm, StopVm]
      ]

-- The platform inventory names the native Pulumi registration. Its accepted
-- type/name and the content-bound context address identify the power target.
matchesInstance :: ProviderAddress -> ManagedResource -> Bool
matchesInstance target resource = case (target, registrationsFromDeclarations [Managed resource]) of
  (CloudInstance _ _ name, Right [registration]) ->
    registrationPulumiType registration == "gcp:compute/instance:Instance"
      && registrationPulumiName registration == name
  _ -> False

targetDigest :: ProviderAddress -> ContentDigest
targetDigest = contentDigest . either (error . T.unpack) id . canonicalValue . toJSON

-- A power-only review may verify cloud declarations, but cannot perform other
-- native mutations under the off-host preparation path.
vmPowerOnly :: [ScopeDeclaration] -> [PlannedOperation] -> Bool
vmPowerOnly scopes planned = not (null intents) && all permitted planned
  where
    intents =
      [ intent
      | scope <- scopes
      , bundle <- scopeBundles scope
      , intent <- bundle ^. #operations
      , intent ^. #operationKind `elem` [StartVm, StopVm]
      ]
    permitted operation =
      plannedExecutor operation == PulumiExecutor
        && (plannedAction operation == VerifyResource || any (matches operation) intents)
    matches operation intent =
      plannedAction operation == RunDeclaredOperation
        && plannedInputDigest operation == contentDigest (either (error . T.unpack) id (canonicalValue (toJSON intent)))
        && plannedResources operation == intent ^. #affects
        && plannedRecovery operation == OperatorRecovery

withVmPower :: Map ContentDigest VmPowerBinding -> VmPowerOps -> Adapter -> Adapter
withVmPower bindings ops base =
  base
    { adapterPrepare = \op -> if selected op then prepare op else adapterPrepare base op
    , adapterPreflight = \op native -> if selected op then inspect op native (const (Right ())) else adapterPreflight base op native
    , adapterExecute = \op native -> if selected op then execute op native else adapterExecute base op native
    , adapterVerify = \op native -> if selected op then verify op native else adapterVerify base op native
    , adapterRecover = \op native ->
        if selected op
          then either RecoveryUnresolved RecoveryProvedComplete <$> verify op native
          else adapterRecover base op native
    }
  where
    selected op = plannedAction op == RunDeclaredOperation && Map.member (plannedInputDigest op) bindings
    binding op = do
      value@(VmPowerBinding target _ _) <-
        maybe
          (Left "VM power binding is absent")
          Right
          (Map.lookup (plannedInputDigest op) bindings)
      unless
        (NE.toList (plannedResources op) == [target] && plannedRecovery op == OperatorRecovery)
        (Left "VM power operation differs from its declaration")
      pure value
    prepare op = do
      previous <- readReceipt op
      case previous of
        Left reason -> pure (Left (PrepareRefused (plannedOperationId op) reason))
        Right (Just receipt) -> pure (first (PrepareRefused (plannedOperationId op)) (prepared (receiptPlan receipt)))
        Right Nothing -> case binding op of
          Left reason -> pure (Left (PrepareRefused (plannedOperationId op) reason))
          Right (VmPowerBinding _ address start) -> do
            observed <- vmPowerObserve ops address
            pure $ first (PrepareRefused (plannedOperationId op)) $ do
              state <- observed
              validateObservation state
              unless
                (vmPowerState state `elem` ["RUNNING", "TERMINATED"])
                (Left "VM power review requires a stable RUNNING or TERMINATED instance")
              prepared
                ( PowerPlan
                    1
                    (plannedOperationId op)
                    (plannedInputDigest op)
                    (vmInstanceId state)
                    (vmPowerState state)
                    (desired start)
                )
    prepared plan = do
      bytes <- canonicalValue (toJSON plan)
      pure
        ( PreparedNative
            bytes
            ( "one-shot VM "
                <> instanceId plan
                <> " transition to "
                <> afterState plan
                <> "; a retained completion proves the original request, not current power readiness"
            )
        )
    readReceipt op = do
      stored <- vmPowerReadReceipt ops (plannedInputDigest op)
      pure $ do
        bytes <- stored
        traverse (validateReceipt op) bytes
    validateReceipt op bytes = do
      receipt <- first T.pack (eitherDecodeStrict' bytes)
      native <- prepared (receiptPlan receipt)
      (plan, _, _) <- decode op native
      let state = receiptObservation receipt
      validateObservation state
      unless
        (vmInstanceId state == instanceId plan && vmPowerState state == afterState plan)
        (Left "VM completion receipt does not prove the reviewed outcome")
      pure receipt
    matchingReceipt op native = do
      stored <- readReceipt op
      pure $ do
        (plan, _, _) <- decode op native
        receipt <- stored
        for_ receipt $ \value ->
          unless
            (receiptPlan value == plan)
            (Left "VM completion receipt differs from the saved native plan")
        pure receipt
    decode op native = do
      plan <- first T.pack (eitherDecodeStrict' (preparedNativeBytes native))
      VmPowerBinding _ address start <- binding op
      unless
        ( version plan == 1
            && operation plan == plannedOperationId op
            && inputDigest plan == plannedInputDigest op
            && afterState plan == desired start
            && beforeState plan `elem` ["RUNNING", "TERMINATED"]
            && validId (instanceId plan)
        )
        (Left "VM power native plan differs from the reviewed operation")
      pure (plan, address, start)
    inspect :: PlannedOperation -> PreparedNative -> ((PowerPlan, VmPowerObservation) -> Either Text a) -> IO (Either Text a)
    inspect op native finish = do
      stored <- matchingReceipt op native
      case stored of
        Left reason -> pure (Left reason)
        Right (Just receipt) -> pure (finish (receiptPlan receipt, receiptObservation receipt))
        Right Nothing -> case decode op native of
          Left reason -> pure (Left reason)
          Right (plan, address, _) -> do
            observed <- vmPowerObserve ops address
            pure $ do
              state <- observed
              validateObservation state
              unless (vmInstanceId state == instanceId plan) (Left "VM physical instance changed since review")
              unless
                (vmPowerState state `elem` [beforeState plan, afterState plan])
                (Left "VM power transition is still pending or state changed; inspect and resume")
              finish (plan, state)
    execute op native = do
      checked <- inspect op native Right
      case checked of
        Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
        Right (plan, state) | vmPowerState state == afterState plan -> pure AdapterEffectCompleted
        Right _ -> case decode op native of
          Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
          Right (_, address, start) -> do
            outcome <- vmPowerSubmit ops address start
            pure (either AdapterEffectAmbiguous (const AdapterEffectCompleted) outcome)
    verify op native = do
      checked <- inspect op native $ \(plan, state) -> do
        unless
          (vmPowerState state == afterState plan)
          (Left "VM power outcome is unresolved; this request will not be automatically repeated")
        canonicalValue (toJSON (PowerReceipt plan state))
      case checked of
        Left reason -> pure (Left reason)
        Right bytes -> do
          stored <- vmPowerWriteReceipt ops (plannedInputDigest op) bytes
          pure (contentDigest bytes <$ stored)
    desired start = if start then "RUNNING" else "TERMINATED"

validId :: Text -> Bool
validId value = not (T.null value) && T.all (`elem` ("0123456789" :: String)) value

validateObservation :: VmPowerObservation -> Either Text ()
validateObservation state =
  unless
    (validId (vmInstanceId state) && not (T.null (vmPowerState state)))
    (Left "VM observation lacks a numeric instance ID or power state")
