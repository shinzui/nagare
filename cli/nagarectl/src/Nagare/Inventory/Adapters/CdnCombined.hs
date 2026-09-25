-- | One executor dispatches independently owned Google and Cloudflare CDN
-- resources. A reviewed operation must belong wholly to one provider.
module Nagare.Inventory.Adapters.CdnCombined
  ( combineCdnAdapters
  )
where

import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Resource.Inventory (Executor (CdnExecutor))
import Nagare.Resource.Types (ResourceId)

combineCdnAdapters :: Map ResourceId a -> Adapter -> Map ResourceId b -> Adapter -> Adapter
combineCdnAdapters google googleAdapter cloudflare cloudflareAdapter =
  Adapter
    { adapterExecutor = CdnExecutor
    , adapterIdentity = "reviewed-cdn-providers"
    , adapterVersion = "1"
    , adapterObserve = \resources -> do
        let googleIds = filter (`Map.member` google) resources
            cloudflareIds = filter (`Map.member` cloudflare) resources
        if length googleIds + length cloudflareIds /= length resources
          then pure (Left "CDN resource has no provider binding")
          else do
            googleFacts <-
              if null googleIds
                then pure (observationSet [])
                else adapterObserve googleAdapter googleIds
            cloudflareFacts <-
              if null cloudflareIds
                then pure (observationSet [])
                else adapterObserve cloudflareAdapter cloudflareIds
            pure $ do
              firstFacts <- googleFacts
              secondFacts <- cloudflareFacts
              observationSet
                ( Map.toList (observationMap firstFacts)
                    <> Map.toList (observationMap secondFacts)
                )
    , adapterPrepare = \operation -> case dispatch (NE.toList (plannedResources operation)) of
        Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
        Right provider -> adapterPrepare provider operation
    , adapterPreflight = \operation prepared -> case dispatch (NE.toList (plannedResources operation)) of
        Left reason -> pure (Left reason)
        Right provider -> adapterPreflight provider operation prepared
    , adapterExecute = \operation prepared -> case dispatch (NE.toList (plannedResources operation)) of
        Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
        Right provider -> adapterExecute provider operation prepared
    , adapterVerify = \operation prepared -> case dispatch (NE.toList (plannedResources operation)) of
        Left reason -> pure (Left reason)
        Right provider -> adapterVerify provider operation prepared
    , adapterRecover = \operation prepared -> case dispatch (NE.toList (plannedResources operation)) of
        Left reason -> pure (RecoveryUnresolved reason)
        Right provider -> adapterRecover provider operation prepared
    }
  where
    dispatch :: [ResourceId] -> Either Text Adapter
    dispatch resources
      | all (`Map.member` google) resources = Right googleAdapter
      | all (`Map.member` cloudflare) resources = Right cloudflareAdapter
      | otherwise = Left "CDN operation crosses provider bindings"
