-- | Each cache deletion is a separate one-shot operation with durable receipt.
module Nagare.Inventory.ImagePruneAdapter (withImagePrune) where

import Data.Aeson
import Data.Foldable (for_)
import Data.List (find)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ImagePrune
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Resource.Policy (RecoveryClass (OperatorRecovery))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data ImagePruneReceipt = ImagePruneReceipt
  { receiptPlan :: !ImagePrunePlan
  , receiptAbsent :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

withImagePrune :: Map.Map ContentDigest ImagePruneBinding -> ImagePruneOps -> Adapter -> Adapter
withImagePrune bindings ops base =
  base
    { adapterPrepare = \operation -> if selected operation then prepare operation else adapterPrepare base operation
    , adapterPreflight = \operation native -> if selected operation then void <$> inspect operation native else adapterPreflight base operation native
    , adapterExecute = \operation native -> if selected operation then execute operation native else adapterExecute base operation native
    , adapterVerify = \operation native -> if selected operation then verify operation native else adapterVerify base operation native
    , adapterSettle = Nothing
    , adapterRecover = \operation native ->
        if selected operation
          then either RecoveryUnresolved RecoveryProvedComplete <$> verify operation native
          else adapterRecover base operation native
    }
  where
    selected operation = plannedAction operation == RunDeclaredOperation && Map.member (plannedInputDigest operation) bindings
    binding operation = do
      value@(ImagePruneBinding resource _ _) <- maybe (Left "image prune binding missing") Right (Map.lookup (plannedInputDigest operation) bindings)
      unless
        (plannedResources operation == resource NE.:| [] && plannedRecovery operation == OperatorRecovery)
        (Left "image prune operation differs from accepted VM authority")
      pure value
    decode operation native = do
      plan <- first T.pack (eitherDecodeStrict' (preparedNativeBytes native))
      ImagePruneBinding _ address image <- binding operation
      unless
        ( pruneVersion plan == 1
            && pruneOperation plan == plannedOperationId operation
            && pruneInputDigest plan == plannedInputDigest operation
            && pruneImageId plan == image
        )
        (Left "image prune native plan differs from reviewed operation")
      validateImageCache (ImageCacheSnapshot (pruneInstanceId plan) [CachedImage image (pruneAliases plan) False] [])
      pure (plan, address)
    prepared plan = do
      bytes <- canonicalValue (toJSON plan)
      pure
        ( PreparedNative
            bytes
            ( "remove exact local CRI cache image "
                <> pruneImageId plan
                <> " on VM "
                <> pruneInstanceId plan
                <> "; published registry artifacts remain retained; completion never prunes a later re-pull"
            )
        )
    readReceipt operation = do
      stored <- imagePruneReadReceipt ops (plannedInputDigest operation)
      pure $ do
        bytes <- stored
        traverse
          ( \value -> do
              receipt <- first T.pack (eitherDecodeStrict' value)
              unless (receiptAbsent receipt) (Left "image prune receipt does not prove absence")
              native <- prepared (receiptPlan receipt)
              _ <- decode operation native
              pure receipt
          )
          bytes
    matchingReceipt operation native = do
      stored <- readReceipt operation
      pure $ do
        (plan, _) <- decode operation native
        receipt <- stored
        for_ receipt $ \value ->
          unless
            (receiptPlan value == plan)
            (Left "image prune receipt differs from original native plan")
        pure receipt
    prepare operation = do
      receipt <- readReceipt operation
      case receipt of
        Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
        Right (Just value) -> pure (first (PrepareRefused (plannedOperationId operation)) (prepared (receiptPlan value)))
        Right Nothing -> case binding operation of
          Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
          Right (ImagePruneBinding _ address image) -> do
            observed <- imagePruneObserve ops address
            pure $ first (PrepareRefused (plannedOperationId operation)) $ do
              snapshot <- observed
              unused <- unusedCacheImages snapshot
              let existing = find ((== image) . imageId) (cacheImages snapshot)
              unless (isNothing existing || image `elem` unused) (Left "reviewed cache image is pinned or used by a current/stopped container")
              prepared
                ( ImagePrunePlan
                    1
                    (plannedOperationId operation)
                    (plannedInputDigest operation)
                    (cacheInstanceId snapshot)
                    image
                    (maybe [] imageAliases existing)
                )
    -- Nothing is historical completion; Just False is freshly observed absence.
    inspect operation native = do
      receipt <- matchingReceipt operation native
      case receipt of
        Left reason -> pure (Left reason)
        Right (Just _) -> pure (Right Nothing)
        Right Nothing -> case decode operation native of
          Left reason -> pure (Left reason)
          Right (plan, address) -> do
            observed <- imagePruneObserve ops address
            pure $ do
              snapshot <- observed
              unused <- unusedCacheImages snapshot
              unless (cacheInstanceId snapshot == pruneInstanceId plan) (Left "image cache VM incarnation changed")
              let existing = find ((== pruneImageId plan) . imageId) (cacheImages snapshot)
              for_ existing $ \image -> do
                unless (imageAliases image == pruneAliases plan) (Left "cached image aliases changed since review")
                unless (imageId image `elem` unused) (Left "cached image became pinned or in use")
              pure (Just (isJust existing))
    execute operation native = do
      checked <- inspect operation native
      case checked of
        Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
        Right Nothing -> pure AdapterEffectCompleted
        Right (Just False) -> pure AdapterEffectCompleted
        Right (Just True) -> case decode operation native of
          Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
          Right (plan, address) -> do
            result <- imagePruneRemove ops address plan
            pure (either AdapterEffectAmbiguous (const AdapterEffectCompleted) result)
    verify operation native = do
      checked <- inspect operation native
      case checked of
        Left reason -> pure (Left reason)
        Right (Just True) -> pure (Left "image removal remains unresolved; an ambiguous deletion is never automatically repeated")
        Right _ -> case decode operation native of
          Left reason -> pure (Left reason)
          Right (plan, _) -> case canonicalValue (toJSON (ImagePruneReceipt plan True)) of
            Left reason -> pure (Left reason)
            Right bytes -> do
              saved <- imagePruneWriteReceipt ops (plannedInputDigest operation) bytes
              pure (contentDigest bytes <$ saved)
