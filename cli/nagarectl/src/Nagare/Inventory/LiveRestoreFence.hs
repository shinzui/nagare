-- | Capture and replay the online data fence for an operation-only live
-- database restore. The saved proof fixes the current target incarnation and
-- both backup positions; replay never selects a replacement Pod or backup.
module Nagare.Inventory.LiveRestoreFence
  ( registerLiveRestoreFence
  , selectedLiveRestoreProofs
  ) where

import Control.Monad (unless)
import Data.Aeson (toJSON)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Database (Engine (Postgres))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence.KubernetesAdapter
import Nagare.Inventory.DataFence.KubernetesCapture
import Nagare.Inventory.DataFence.KubernetesIntent
import Nagare.Inventory.DataFence.MaintenanceNetwork
import Nagare.Inventory.DataFence.MaintenancePostgres
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.LiveRestore
import Nagare.Inventory.Store (DataFenceRecord (..), ScopeRevision)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

registerLiveRestoreFence :: KubernetesRuntimeConfig -> ContextBinding
  -> Map ScopeId ScopeRevision -> [ScopeDeclaration] -> [Declaration]
  -> Map ResourceId (ManagedResource, ByteString)
  -> (PlannedOperation -> IO (Either Text ContentDigest))
  -> (PlannedOperation -> IO (Either Text ContentDigest))
  -> AdapterRegistry
  -> Either Text AdapterRegistry
registerLiveRestoreFence config binding accepted scopes declarations native
  restoreRecovery verifyRecovery registry = do
  proofs <- liveRestoreProofIndex scopes
  if Map.null proofs then Right registry else do
    let ContextBinding context _ = binding
    unless (runtimeContext config == context)
      (Left "live restore Kubernetes context differs from the reviewed binding")
    let session proof = "lr-" <> liveRestoreProofId proof
        bySession = Map.fromList
          [(session proof, proof) | proof <- Map.elems proofs]
    unless (Map.size bySession == Map.size proofs)
      (Left "live restore review repeats a restore ID")
    let selected operation = Map.lookup (plannedInputDigest operation) proofs
        requireSelected operation = do
          unless (plannedAction operation == RestoreLiveDatabase)
            (Left "live restore fence operation has another action")
          proof <- maybe (Left "live restore source proof is absent") Right
            (selected operation)
          unless (NE.toList (plannedResources operation)
              == [liveRestoreProofStateful proof])
            (Left "live restore operation targets another database")
          unless (all (\(scope, revision) -> Map.lookup scope accepted == Just revision)
              [ (liveRestoreProofTargetScope proof,
                  liveRestoreProofTargetRevision proof)
              , (liveBackupScopeId (liveRestoreProofSource proof),
                  liveBackupScopeRevision (liveRestoreProofSource proof))
              , (liveBackupScopeId (liveRestoreProofRecovery proof),
                  liveBackupScopeRevision (liveRestoreProofRecovery proof)) ])
            (Left "live restore target or backup revision is no longer accepted")
          pure proof
        pinFor proof = mkMaintenanceNetworkPin
          (session proof)
          (liveRestoreProofNamespace proof)
          (liveRestoreProofDatabase proof)
          (liveRestoreProofDatabase proof <> "-0")
          (physicalIdentityText (liveRestoreProofPodUid proof))
        recoveryArtifact proof = "live-restore-recovery/"
          <> scopeIdText (liveBackupScopeId (liveRestoreProofRecovery proof))
          <> "/" <> liveBackupId (liveRestoreProofRecovery proof)
        proofDigest proof = contentDigest <$> canonicalValue (toJSON proof)
        replay record operation _ = do
          proof <- requireSelected operation
          intent <- decodeKubernetesFenceIntent record
          expectedDigest <- proofDigest proof
          unless (kubernetesNetworkExcluded intent
              && fenceContext record == binding
              && fenceSession record == session proof
              && fenceTargets record == Set.singleton (liveRestoreProofPvc proof)
              && Map.lookup (liveRestoreProofStateful proof) (fencePhysical record)
                == Just (liveRestoreProofStatefulUid proof)
              && Map.lookup (liveRestoreProofPvc proof) (fencePhysical record)
                == Just (liveRestoreProofPvcUid proof)
              && fenceRecoveryArtifact record == recoveryArtifact proof
              && fenceRecoveryDigest record == expectedDigest)
            (Left "live restore reviewed target or backup identity changed")
        selectRequest operation _ = case selected operation of
          Nothing -> pure (Right Nothing)
          Just _ -> pure $ do
            proof <- requireSelected operation
            service <- restoreService declarations proof
            expectedDigest <- proofDigest proof
            pure (Just KubernetesCaptureRequest
              { captureBinding = binding
              , captureAccepted = accepted
              , captureSession = session proof
              , captureVolumeResource = liveRestoreProofPvc proof
              , captureDependencyRoot = liveRestoreProofStateful proof
              , captureExpectedDatabaseEngine = Just Postgres
              , captureServiceResource = Just service
              , captureNetworkExclusion = True
              , captureRecoveryArtifact = recoveryArtifact proof
              , captureRecoveryDigest = expectedDigest
              , captureStatefulControllerPrincipal =
                  "system:serviceaccount:kube-system:statefulset-controller"
              , captureReplicaSetControllerPrincipal = Just
                  "system:serviceaccount:kube-system:replicaset-controller"
              , captureRestoreJob = Nothing
              })
        verify record = case Map.lookup (fenceSession record) bySession of
          Nothing -> pure (Left "live restore ID is absent from reviewed scopes")
          Just proof -> case pinFor proof of
            Left reason -> pure (Left reason)
            Right pin -> observePostgresClients
              (kubectlPostgresMaintenanceTransport config)
              (networkNamespace pin) (networkPodName pin) (networkPodUid pin)
        factory = KubernetesFenceFactory config binding accepted declarations native
          selectRequest replay verify Nothing
          (Just (\record operation prepared -> case replay record operation prepared of
            Left reason -> pure (Left reason)
            Right () -> restoreRecovery operation))
          (Just (\record operation prepared -> case replay record operation prepared of
            Left reason -> pure (Left reason)
            Right () -> verifyRecovery operation))
        selectPin record operation prepared = do
          replay record operation prepared
          proof <- requireSelected operation
          pin <- pinFor proof
          pure (Postgres, pin)
    registerKubernetesLiveRestoreFence factory selectPin registry

liveRestoreProofIndex :: [ScopeDeclaration]
  -> Either Text (Map ContentDigest LiveRestoreProof)
liveRestoreProofIndex scopes = do
  entries <- fmap concat (traverse one scopes)
  let byDigest = Map.fromList entries
  unless (Map.size byDigest == length entries)
    (Left "live restore review repeats a declared operation")
  pure byDigest
  where
    one scope = case liveRestoreProof scope of
      Left reason -> Left reason
      Right Nothing -> Right []
      Right (Just proof) -> do
        let declared = [operation | bundle <- scopeBundles scope,
              operation <- Nagare.Resource.Inventory.operations bundle]
        operation <- case declared of
          [single] -> Right single
          _ -> Left "live restore scope lacks one exact declared operation"
        bytes <- canonicalValue (toJSON operation)
        pure [(contentDigest bytes, proof)]

selectedLiveRestoreProofs :: [ScopeDeclaration] -> [PlannedOperation]
  -> Either Text [LiveRestoreProof]
selectedLiveRestoreProofs scopes operations = do
  byDigest <- liveRestoreProofIndex scopes
  traverse (\operation -> maybe
      (Left "reviewed live restore operation lacks a private source proof")
      Right (Map.lookup (plannedInputDigest operation) byDigest))
    [operation | operation <- operations,
      plannedAction operation == RestoreLiveDatabase]

restoreService :: [Declaration] -> LiveRestoreProof -> Either Text ResourceId
restoreService declarations proof = do
  cluster <- case [selected
      | Managed member <- declarations
      , member ^. #identity == liveRestoreProofStateful proof
      , Kubernetes selected "apps" kind (Just namespace) name <-
          [member ^. #address]
      , nameText kind == "statefulset"
      , nameText namespace == liveRestoreProofNamespace proof
      , nameText name == liveRestoreProofDatabase proof] of
    [single] -> Right single
    _ -> Left "live restore database lacks one reviewed StatefulSet address"
  case [member ^. #identity
      | Managed member <- declarations
      , Kubernetes selected "" kind (Just namespace) name <-
          [member ^. #address]
      , selected == cluster
      , nameText kind == "service"
      , nameText namespace == liveRestoreProofNamespace proof
      , nameText name == liveRestoreProofDatabase proof] of
    [single] -> Right single
    _ -> Left "live restore database lacks one reviewed Service route"
