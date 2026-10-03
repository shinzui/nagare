-- | Bind an operation-only maintenance scope to the shared reviewed fence.
-- Both planning and replay select the same private source proof; live Pod
-- discovery is permitted only while capturing a new review.
module Nagare.Inventory.MaintenanceFence
  ( registerMaintenanceFence
  , selectedMaintenanceProofs
  )
where

import Control.Monad (unless)
import Data.Aeson (object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence.KubernetesAdapter
import Nagare.Inventory.DataFence.KubernetesCapture
import Nagare.Inventory.DataFence.KubernetesIntent
import Nagare.Inventory.DataFence.MaintenanceClickHouse
import Nagare.Inventory.DataFence.MaintenanceNetwork
import Nagare.Inventory.DataFence.MaintenancePostgres
import Nagare.Inventory.DataFence.MaintenanceRedis
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Maintenance
import Nagare.Inventory.Store (DataFenceRecord (..), ScopeRevision)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

registerMaintenanceFence ::
  KubernetesRuntimeConfig ->
  ContextBinding ->
  Map ScopeId ScopeRevision ->
  [ScopeDeclaration] ->
  [Declaration] ->
  Map ResourceId (ManagedResource, ByteString) ->
  AdapterRegistry ->
  Either Text AdapterRegistry
registerMaintenanceFence config binding accepted scopes declarations native registry = do
  proofs <- maintenanceProofIndex scopes
  if Map.null proofs
    then Right registry
    else do
      let ContextBinding context _ = binding
      unless
        (runtimeContext config == context)
        (Left "maintenance Kubernetes context differs from the reviewed binding")
      let bySession =
            Map.fromList
              [(maintenanceSourceSession proof, proof) | proof <- Map.elems proofs]
      unless
        (Map.size bySession == Map.size proofs)
        (Left "maintenance review repeats a session ID")
      let selected operation = Map.lookup (plannedInputDigest operation) proofs
          requireSelected operation = do
            unless
              (plannedAction operation == OpenMaintenanceSession)
              (Left "maintenance fence operation has another action")
            proof <-
              maybe
                (Left "maintenance source proof is absent")
                Right
                (selected operation)
            unless
              ( NE.toList (plannedResources operation)
                  == [maintenanceSourceStateful proof]
              )
              (Left "maintenance operation targets another database")
            pure proof
          pinFor proof =
            mkMaintenanceNetworkPin
              (maintenanceSourceSession proof)
              (maintenanceSourceNamespace proof)
              (maintenanceSourceDatabase proof)
              (maintenanceSourceDatabase proof <> "-0")
              (physicalIdentityText (maintenanceSourcePodUid proof))
          artifact proof =
            "maintenance-recovery/"
              <> maintenanceSourceRecovery proof
              <> "/"
              <> maintenanceSourceRecoveryId proof
          recoveryDigest proof =
            contentDigest
              <$> canonicalValue
                ( object
                    [ "scope" .= maintenanceSourceRecovery proof
                    , "revision" .= digestText (maintenanceSourceRecoveryDigest proof)
                    , "job" .= resourceIdText (maintenanceSourceRecoveryJob proof)
                    , "jobUid"
                        .= physicalIdentityText
                          (maintenanceSourceRecoveryJobUid proof)
                    , "receiptDigest"
                        .= digestText
                          (maintenanceSourceRecoveryReceiptDigest proof)
                    ]
                )
          replay record operation _ = do
            proof <- requireSelected operation
            intent <- decodeKubernetesFenceIntent record
            expectedRecovery <- recoveryDigest proof
            unless
              ( kubernetesNetworkExcluded intent
                  && fenceContext record == binding
                  && fenceSession record == maintenanceSourceSession proof
                  && fenceTargets record == Set.singleton (maintenanceSourcePvc proof)
                  && Map.lookup (maintenanceSourceStateful proof) (fencePhysical record)
                    == Just (maintenanceSourceStatefulUid proof)
                  && Map.lookup (maintenanceSourcePvc proof) (fencePhysical record)
                    == Just (maintenanceSourcePvcUid proof)
                  && fenceRecoveryArtifact record == artifact proof
                  && fenceRecoveryDigest record == expectedRecovery
              )
              (Left "maintenance reviewed source or recovery identity changed")
          selectRequest operation _ = case selected operation of
            Nothing -> pure (Right Nothing)
            Just proof -> pure $ do
              _ <- requireSelected operation
              service <- maintenanceService declarations proof
              expectedRecovery <- recoveryDigest proof
              pure
                ( Just
                    KubernetesCaptureRequest
                      { captureBinding = binding
                      , captureAccepted = accepted
                      , captureSession = maintenanceSourceSession proof
                      , captureVolumeResource = maintenanceSourcePvc proof
                      , captureDependencyRoot = maintenanceSourceStateful proof
                      , captureExpectedDatabaseEngine =
                          Just
                            (maintenanceSourceEngine proof)
                      , captureServiceResource = Just service
                      , captureNetworkExclusion = True
                      , captureRecoveryArtifact = artifact proof
                      , captureRecoveryDigest = expectedRecovery
                      , captureStatefulControllerPrincipal =
                          "system:serviceaccount:kube-system:statefulset-controller"
                      , captureReplicaSetControllerPrincipal =
                          Just
                            "system:serviceaccount:kube-system:replicaset-controller"
                      , captureRestoreJob = Nothing
                      }
                )
          verify record = case Map.lookup (fenceSession record) bySession of
            Nothing -> pure (Left "maintenance session is absent from reviewed scopes")
            Just proof -> case pinFor proof of
              Left reason -> pure (Left reason)
              Right pin -> observeClients proof pin
          resolve record operation prepared = case do
            replay record operation prepared
            proof <- requireSelected operation
            pin <- pinFor proof
            pure (proof, pin) of
            Left reason -> pure (RecoveryUnresolved reason)
            Right (proof, pin) -> do
              stopped <- terminateClients proof pin
              case stopped of
                Left reason -> pure (RecoveryUnresolved reason)
                Right () -> do
                  observed <- observeClients proof pin
                  pure $ case observed of
                    Left reason -> RecoveryUnresolved reason
                    Right False ->
                      RecoveryUnresolved
                        "maintenance database clients remain after termination"
                    Right True -> case canonicalValue
                      ( object
                          [ "session" .= maintenanceSourceSession proof
                          , "podUid"
                              .= physicalIdentityText
                                (maintenanceSourcePodUid proof)
                          , "recoveryReceiptDigest"
                              .= digestText
                                (maintenanceSourceRecoveryReceiptDigest proof)
                          , "terminalOutcome" .= ("operator-terminated" :: Text)
                          ]
                      ) of
                      Left reason -> RecoveryUnresolved reason
                      Right bytes -> RecoveryProvedComplete (contentDigest bytes)
          factory =
            KubernetesFenceFactory
              config
              binding
              accepted
              declarations
              native
              selectRequest
              replay
              verify
              (Just resolve)
              Nothing
              Nothing
          selectPin record operation prepared = do
            replay record operation prepared
            proof <- requireSelected operation
            pin <- pinFor proof
            pure (maintenanceSourceEngine proof, pin)
          observeClients proof pin = case maintenanceSourceEngine proof of
            Postgres ->
              observePostgresClients
                (kubectlPostgresMaintenanceTransport config)
                (networkNamespace pin)
                (networkPodName pin)
                (networkPodUid pin)
            Redis ->
              observeRedisClients
                (kubectlRedisMaintenanceTransport config)
                (networkNamespace pin)
                (networkPodName pin)
                (networkPodUid pin)
            ClickHouse ->
              observeClickHouseClients
                (kubectlClickHouseMaintenanceTransport config)
                (networkNamespace pin)
                (networkPodName pin)
                (networkPodUid pin)
          terminateClients proof pin = case maintenanceSourceEngine proof of
            Postgres ->
              terminateMarkedPostgresClients
                (kubectlPostgresMaintenanceTransport config)
                (networkNamespace pin)
                (networkPodName pin)
                (networkPodUid pin)
                (maintenanceSourceSession proof)
            Redis ->
              terminateMarkedRedisClients
                (kubectlRedisMaintenanceTransport config)
                (networkNamespace pin)
                (networkPodName pin)
                (networkPodUid pin)
                (maintenanceSourceSession proof)
            ClickHouse ->
              terminateMarkedClickHouseClients
                (kubectlClickHouseMaintenanceTransport config)
                (networkNamespace pin)
                (networkPodName pin)
                (networkPodUid pin)
                (maintenanceSourceSession proof)
      registerKubernetesMaintenanceFence factory selectPin registry

maintenanceProofIndex ::
  [ScopeDeclaration] ->
  Either Text (Map ContentDigest MaintenanceSourceProof)
maintenanceProofIndex scopes = do
  entries <- fmap concat $ traverse one scopes
  let indexed = Map.fromList entries
  unless
    (Map.size indexed == length entries)
    (Left "maintenance review repeats a declared operation")
  pure indexed
  where
    one scope = case maintenanceSourceProof scope of
      Left reason -> Left reason
      Right Nothing -> Right []
      Right (Just proof) -> do
        let operations =
              [ operation
              | bundle <- scopeBundles scope
              , operation <- Nagare.Resource.Inventory.operations bundle
              ]
        operation <- case operations of
          [selected]
            | operationKind selected == MaintainData
                && NE.toList (affects selected) == [maintenanceSourceStateful proof] ->
                Right selected
          _ -> Left "maintenance scope lacks one exact declared session"
        bytes <- canonicalValue (toJSON operation)
        pure [(contentDigest bytes, proof)]

selectedMaintenanceProofs ::
  [ScopeDeclaration] ->
  [PlannedOperation] ->
  Either Text [MaintenanceSourceProof]
selectedMaintenanceProofs scopes operations = do
  indexed <- maintenanceProofIndex scopes
  traverse
    ( \operation ->
        maybe
          (Left "reviewed maintenance operation lacks a private source proof")
          Right
          (Map.lookup (plannedInputDigest operation) indexed)
    )
    [ operation
    | operation <- operations
    , plannedAction operation == OpenMaintenanceSession
    ]

maintenanceService ::
  [Declaration] ->
  MaintenanceSourceProof ->
  Either Text ResourceId
maintenanceService declarations proof = do
  cluster <- case [ selected
                  | Managed member <- declarations
                  , member ^. #identity == maintenanceSourceStateful proof
                  , Kubernetes selected "apps" kind (Just namespace) name <-
                      [member ^. #address]
                  , nameText kind == "statefulset"
                  , nameText namespace == maintenanceSourceNamespace proof
                  , nameText name == maintenanceSourceDatabase proof
                  ] of
    [single] -> Right single
    _ -> Left "maintenance database lacks one reviewed StatefulSet address"
  case [ member ^. #identity
       | Managed member <- declarations
       , Kubernetes selected "" kind (Just namespace) name <-
           [member ^. #address]
       , selected == cluster
       , nameText kind == "service"
       , nameText namespace == maintenanceSourceNamespace proof
       , nameText name == maintenanceSourceDatabase proof
       ] of
    [single] -> Right single
    _ -> Left "maintenance database lacks one reviewed Service route"
