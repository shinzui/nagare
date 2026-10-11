-- | The manifest-only adapter: plans against accepted declarations without a
-- provider, and refuses to execute, verify or recover anything.
module Nagare.Inventory.ManifestAdapter
  ( manifestAdapterFor
  , manifestOnlyRegistry
  )
where

import Data.Aeson (toJSON)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Inventory.Plan (InventoryHistory, historyAccepted)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

manifestOnlyRegistry :: InventoryHistory -> AdapterRegistry
manifestOnlyRegistry history =
  either (error . T.unpack) id (mkAdapterRegistry (map (manifestAdapterFor history) executors))
  where
    executors = [KubernetesExecutor, PulumiExecutor, CloudFoundationExecutor, HostExecutor, ArtifactExecutor, CacheExecutor, BrokerExecutor, HelmExecutor, CdnExecutor, AccessExecutor]

manifestAdapterFor :: InventoryHistory -> Executor -> Adapter
manifestAdapterFor history executor =
  Adapter
    { adapterExecutor = executor
    , adapterIdentity = "manifest-only"
    , adapterVersion = "1"
    , adapterObserve = \resources -> pure (observationSet [(resource, observation resource) | resource <- resources])
    , adapterPrepare = \operation -> pure (Right (PreparedNative (canonicalOperation operation) "manifest-only review; a provider adapter is required before apply"))
    , adapterPreflight = \_ _ -> pure (Left "manifest-only reviews are not executable; install the provider adapter delivered by a later inventory plan")
    , adapterExecute = \_ _ -> pure (AdapterEffectFailed (KnownNoEffect "manifest-only adapter cannot execute"))
    , adapterVerify = \_ _ -> pure (Left "manifest-only adapter cannot verify provider state")
    , adapterSettle = Nothing
    , adapterRecover = \_ _ -> pure (RecoveryUnresolved "manifest-only adapter cannot recover provider state")
    }
  where
    acceptedIds = Set.fromList [declarationId declaration | (_, (_, scope)) <- Map.toAscList (historyAccepted history), bundle <- scopeBundles scope, declaration <- bundle ^. #declarations]
    observation resource
      | Set.member resource acceptedIds = ObservedPresent (physical ("accepted:" <> resourceIdText resource))
      | otherwise = ConfirmedAbsent (contentDigest (TE.encodeUtf8 ("manifest-only-absence:" <> resourceIdText resource)))
    physical value = either (error . T.unpack) id (mkPhysicalIdentity value)
    canonicalOperation = either (error . T.unpack) id . canonicalValue . toJSON
