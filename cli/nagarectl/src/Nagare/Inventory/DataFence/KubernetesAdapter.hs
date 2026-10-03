-- | Attach the native Kubernetes fence to a reviewed inventory executor.
-- Planning captures provider facts once; replay reconstructs controls from
-- the private member saved with that review, without calling the selector.
module Nagare.Inventory.DataFence.KubernetesAdapter
  ( KubernetesFenceFactory (..)
  , registerKubernetesDataFence
  , registerKubernetesMaintenanceFence
  , registerKubernetesLiveRestoreFence
  )
where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence (DataFenceControls)
import Nagare.Inventory.DataFence.KubernetesCapture
import Nagare.Inventory.DataFence.KubernetesExclusion
import Nagare.Inventory.DataFence.KubernetesIntent (decodeKubernetesFenceIntent)
import Nagare.Inventory.DataFence.MaintenanceClickHouse
import Nagare.Inventory.DataFence.MaintenanceNetwork
import Nagare.Inventory.DataFence.MaintenancePostgres
import Nagare.Inventory.DataFence.MaintenanceRedis
import Nagare.Inventory.Store (DataFenceRecord (..), ScopeRevision)
import Nagare.Resource.Inventory (Declaration, Executor (KubernetesExecutor), ManagedResource)
import Nagare.Resource.Types

data KubernetesFenceFactory = KubernetesFenceFactory
  { factoryRuntime :: !KubernetesRuntimeConfig
  , factoryBinding :: !ContextBinding
  , factoryAccepted :: !(Map ScopeId ScopeRevision)
  , factoryDeclarations :: ![Declaration]
  , factoryNative :: !(Map ResourceId (ManagedResource, ByteString))
  , factorySelect ::
      !( PlannedOperation ->
         PreparedNative ->
         IO (Either Text (Maybe KubernetesCaptureRequest))
       )
  , factoryReplay ::
      !( DataFenceRecord ->
         PlannedOperation ->
         PreparedNative ->
         Either Text ()
       )
  , factoryVerify :: !(DataFenceRecord -> IO (Either Text Bool))
  , factoryResolveUncertainEffect ::
      !( Maybe
           ( DataFenceRecord ->
             PlannedOperation ->
             PreparedNative ->
             IO RecoveryDecision
           )
       )
  , factoryRestoreRecoveryBackup ::
      !( Maybe
           ( DataFenceRecord ->
             PlannedOperation ->
             PreparedNative ->
             IO (Either Text ContentDigest)
           )
       )
  , factoryVerifyRecoveryBackup ::
      !( Maybe
           ( DataFenceRecord ->
             PlannedOperation ->
             PreparedNative ->
             IO (Either Text ContentDigest)
           )
       )
  }

registerKubernetesDataFence ::
  KubernetesFenceFactory ->
  AdapterRegistry ->
  Either Text AdapterRegistry
registerKubernetesDataFence factory =
  registerKubernetesFence
    factory
    "kubernetes-native-data-fence-v1"
    Nothing
    ( \record _ _ ->
        Right
          ( kubernetesDataFenceControls
              ( kubectlKubernetesExclusion
                  (factoryRuntime factory)
                  (factoryAccepted factory)
                  (factoryDeclarations factory)
                  (factoryNative factory)
              )
              (factoryVerify factory)
          )
    )

-- | A maintenance replay obtains the Pod pin only from its saved private
-- source proof. It cannot select a replacement Pod during apply or recovery.
registerKubernetesMaintenanceFence ::
  KubernetesFenceFactory ->
  ( DataFenceRecord ->
    PlannedOperation ->
    PreparedNative ->
    Either Text (Engine, MaintenanceNetworkPin)
  ) ->
  AdapterRegistry ->
  Either Text AdapterRegistry
registerKubernetesMaintenanceFence factory selectPin =
  registerKubernetesOnlineDatabaseFence
    factory
    "kubernetes-native-maintenance-fence-v1"
    OpenMaintenanceSession
    selectPin

-- | Live database restore uses the same online writer exclusion, under a
-- distinct saved capability and action. Its private source proof supplies the
-- exact Pod pin; apply never discovers a replacement Pod.
registerKubernetesLiveRestoreFence ::
  KubernetesFenceFactory ->
  ( DataFenceRecord ->
    PlannedOperation ->
    PreparedNative ->
    Either Text (Engine, MaintenanceNetworkPin)
  ) ->
  AdapterRegistry ->
  Either Text AdapterRegistry
registerKubernetesLiveRestoreFence factory selectPin =
  registerKubernetesOnlineDatabaseFence
    factory
    "kubernetes-native-live-restore-fence-v1"
    RestoreLiveDatabase
    selectPin

registerKubernetesOnlineDatabaseFence ::
  KubernetesFenceFactory ->
  Text ->
  OperationAction ->
  ( DataFenceRecord ->
    PlannedOperation ->
    PreparedNative ->
    Either Text (Engine, MaintenanceNetworkPin)
  ) ->
  AdapterRegistry ->
  Either Text AdapterRegistry
registerKubernetesOnlineDatabaseFence factory capability action selectPin =
  registerKubernetesFence factory capability (Just action) $ \record operation prepared -> do
    (engine, pin) <- selectPin record operation prepared
    let config = factoryRuntime factory
        observeClients = case engine of
          Postgres ->
            observePostgresClients
              (kubectlPostgresMaintenanceTransport config)
          Redis -> observeRedisClients (kubectlRedisMaintenanceTransport config)
          ClickHouse ->
            observeClickHouseClients
              (kubectlClickHouseMaintenanceTransport config)
    pure
      ( kubernetesMaintenanceFenceControls
          ( kubectlKubernetesExclusion
              config
              (factoryAccepted factory)
              (factoryDeclarations factory)
              (factoryNative factory)
          )
          (kubectlMaintenanceNetworkTransport config)
          engine
          observeClients
          pin
          (factoryVerify factory)
      )

registerKubernetesFence ::
  KubernetesFenceFactory ->
  Text ->
  Maybe OperationAction ->
  ( DataFenceRecord ->
    PlannedOperation ->
    PreparedNative ->
    Either Text DataFenceControls
  ) ->
  AdapterRegistry ->
  Either Text AdapterRegistry
registerKubernetesFence factory capability requiredAction controlsFor registry =
  withAdapterFence
    registry
    KubernetesExecutor
    AdapterFence
      { fenceCapability = capability
      , fenceForOperation = \operation prepared ->
          if maybe False (/= plannedAction operation) requiredAction
            then pure (Right Nothing)
            else do
              selected <- factorySelect factory operation prepared
              case selected of
                Left reason -> pure (Left reason)
                Right Nothing -> pure (Right Nothing)
                Right (Just request) ->
                  if captureBinding request /= factoryBinding factory
                    || captureAccepted request /= factoryAccepted factory
                    then pure (Left "Kubernetes fence planning context or accepted revisions changed")
                    else
                      fmap
                        (fmap Just)
                        ( captureKubernetesFence
                            (kubectlKubernetesCaptureTransport (factoryRuntime factory))
                            (factoryDeclarations factory)
                            (factoryNative factory)
                            request
                        )
      , fenceFromReviewedRecord = \record operation prepared -> do
          unless
            (maybe True (== plannedAction operation) requiredAction)
            (Left "Kubernetes fence action differs from reviewed capability")
          let ContextBinding context _ = factoryBinding factory
          unless
            ( fenceContext record == factoryBinding factory
                && fenceAccepted record == factoryAccepted factory
                && runtimeContext (factoryRuntime factory) == context
            )
            (Left "Kubernetes fence replay context or accepted revisions changed")
          _ <- decodeKubernetesFenceIntent record
          factoryReplay factory record operation prepared
          controlsFor record operation prepared
      , fenceResolveUncertainEffect = factoryResolveUncertainEffect factory
      , fenceRestoreRecoveryBackup = factoryRestoreRecoveryBackup factory
      , fenceVerifyRecoveryBackup = factoryVerifyRecoveryBackup factory
      }
