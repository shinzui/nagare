-- | Review binding and conditional transport boundary for Helm releases.
-- Native execution must check the release revision and gate Helm's exact
-- post-renderer bytes before any chart resources are changed.
module Nagare.Inventory.Adapters.Helm
  ( HelmState (..)
  , HelmMutation (..)
  , HelmAdapterOps (..)
  , mkHelmAdapter
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
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data HelmState
  = HelmAbsent !ContentDigest
  | HelmPresent !PhysicalIdentity !Text !ResourceId !ContentDigest
  | HelmForeign !Text
  | HelmUnavailable !Text
  deriving stock (Eq, Show, Generic)

data HelmMutation = HelmMutation
  { helmMutationVersion :: !Int
  , helmMutationOperation :: !OperationId
  , helmMutationAction :: !OperationAction
  , helmMutationInputDigest :: !ContentDigest
  , helmMutationResource :: !ResourceId
  , helmMutationAddress :: !ProviderAddress
  , helmMutationContract :: !Text
  , helmMutationContractDigest :: !ContentDigest
  , helmMutationBefore :: !HelmState
  }
  deriving stock (Eq, Show, Generic)

data HelmAdapterOps = HelmAdapterOps
  { helmObserve :: !(ResourceId -> IO HelmState)
  -- This callback must enforce the reviewed release revision at the provider,
  -- not merely reread it before an unrestricted upgrade.
  , helmMutateConditional :: !(HelmMutation -> IO AdapterExecution)
  }

mkHelmAdapter :: Map ResourceId (ManagedResource, ByteString) -> HelmAdapterOps -> Adapter
mkHelmAdapter specs ops = Adapter
  { adapterExecutor = HelmExecutor
  , adapterIdentity = "helm-reviewed-render"
  , adapterVersion = "1"
  , adapterObserve = \resources -> do
      states <- traverse (helmObserve ops) resources
      pure (observationSet (zipWith observe resources states))
  , adapterPrepare = \operation -> case specFor operation of
      Left reason -> pure (Left (refuse operation reason))
      Right (resource, declaration, contract) -> do
        before <- helmObserve ops resource
        pure $ do
          checkBefore operation resource before
          contractText <- first (refuse operation . T.pack . show) (TE.decodeUtf8' contract)
          let mutation = HelmMutation 1 (plannedOperationId operation) (plannedAction operation)
                (plannedInputDigest operation) resource (declaration ^. #address)
                contractText (contentDigest contract) before
          bytes <- first (refuse operation) (canonicalValue (toJSON mutation))
          pure (PreparedNative bytes ("reconcile Helm release " <> resourceIdText resource))
  , adapterPreflight = \operation prepared -> case decodeMutation operation prepared of
      Left reason -> pure (Left reason)
      Right mutation -> do
        current <- helmObserve ops (helmMutationResource mutation)
        pure (if current == helmMutationBefore mutation then Right () else Left "Helm release revision changed after review")
  , adapterExecute = \operation prepared -> case decodeMutation operation prepared of
      Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
      Right mutation -> do
        current <- helmObserve ops (helmMutationResource mutation)
        if current /= helmMutationBefore mutation
          then pure (AdapterEffectFailed (KnownNoEffect "Helm release revision changed after review"))
          else helmMutateConditional ops mutation
  , adapterVerify = \operation prepared -> case decodeMutation operation prepared of
      Left reason -> pure (Left reason)
      Right mutation -> do
        current <- helmObserve ops (helmMutationResource mutation)
        pure (proof mutation current)
  , adapterRecover = \operation prepared -> case decodeMutation operation prepared of
      Left reason -> pure (RecoveryUnresolved reason)
      Right mutation -> do
        current <- helmObserve ops (helmMutationResource mutation)
        pure (case proof mutation current of
          Right digest -> RecoveryProvedComplete digest
          Left _ | current == helmMutationBefore mutation -> RecoverySafeToRetry
          Left reason -> RecoveryUnresolved reason)
  }
  where
    refuse operation = PrepareRefused (plannedOperationId operation)
    observe resource = \case
      HelmAbsent digest -> (resource, ConfirmedAbsent digest)
      HelmPresent physical _ owner digest
        | owner /= resource -> (resource, ObservedForeign physical)
        | Just (_, contract) <- Map.lookup resource specs
        , digest /= contentDigest contract -> (resource, ObservedDrifted physical digest)
        | otherwise -> (resource, ObservedPresent physical)
      HelmForeign reason -> (resource, ObservationUnavailable reason)
      HelmUnavailable reason -> (resource, ObservationUnavailable reason)
    specFor operation = do
      unless (plannedExecutor operation == HelmExecutor
          && plannedAction operation `elem` [CreateResource, UpdateResource])
        (Left "Helm adapter supports only reviewed create and update")
      resource <- case NE.toList (plannedResources operation) of
        [single] -> Right single
        _ -> Left "Helm operation must name one release"
      (declaration, contract) <- maybe (Left "Helm release has no bound native contract") Right (Map.lookup resource specs)
      unless (declaration ^. #identity == resource && declaration ^. #executor == HelmExecutor)
        (Left "Helm declaration identity or executor differs")
      case (declaration ^. #address, declaration ^. #spec) of
        (Helm {} , HelmRelease _ digest) | digest == contentDigest contract -> Right (resource, declaration, contract)
        _ -> Left "Helm native contract differs from its typed release"
    checkBefore operation resource = first (refuse operation) . \case
      HelmAbsent _ | plannedAction operation == CreateResource -> Right ()
      HelmPresent _ revision owner _ | plannedAction operation == UpdateResource
        && owner == resource && not (T.null revision) -> Right ()
      HelmUnavailable reason -> Left ("Helm observation unavailable: " <> reason)
      HelmForeign reason -> Left ("Helm release is foreign: " <> reason)
      _ -> Left "Helm action lacks confirmed absence or an owned release revision"
    decodeMutation operation prepared = do
      mutation <- first T.pack (eitherDecodeStrict (preparedNativeBytes prepared))
      (resource, declaration, contract) <- specFor operation
      unless (helmMutationVersion mutation == 1
          && helmMutationOperation mutation == plannedOperationId operation
          && helmMutationInputDigest mutation == plannedInputDigest operation
          && helmMutationAction mutation == plannedAction operation
          && helmMutationResource mutation == resource
          && helmMutationAddress mutation == declaration ^. #address
          && TE.encodeUtf8 (helmMutationContract mutation) == contract
          && helmMutationContractDigest mutation == contentDigest contract)
        (Left "Helm mutation differs from the reviewed release")
      first (const "Helm mutation precondition is invalid") (checkBefore operation resource (helmMutationBefore mutation))
      pure mutation
    proof mutation = \case
      HelmPresent physical revision owner digest
        | owner == helmMutationResource mutation
        , digest == helmMutationContractDigest mutation
        , not (T.null revision) -> Right (contentDigest (preparedProof physical revision digest))
      HelmAbsent _ -> Left "Helm release is absent"
      HelmForeign reason -> Left reason
      HelmUnavailable reason -> Left reason
      HelmPresent {} -> Left "Helm release identity or native contract differs from review"
    preparedProof physical revision digest =
      either (error . T.unpack) id (canonicalValue (toJSON
        (physicalIdentityText physical, revision, digestText digest)))

instance ToJSON HelmState where toJSON = genericToJSON defaultOptions
instance FromJSON HelmState where parseJSON = genericParseJSON defaultOptions
instance ToJSON HelmMutation where toJSON = genericToJSON defaultOptions
instance FromJSON HelmMutation where parseJSON = genericParseJSON defaultOptions
