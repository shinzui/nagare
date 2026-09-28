-- | Attach the PostgreSQL live-effect procedure to its reviewed operation.
-- Every entrypoint rechecks accepted Job receipts, stored bytes, and the exact
-- target incarnation. A lost effect acknowledgement is proved by content,
-- never by running the destructive restore a second time.
module Nagare.Inventory.LiveRestoreAdapter
  ( liveRestoreAdapter
  ) where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
  (KubernetesAdapterOps (..), KubernetesState (..))
import Nagare.Inventory.Adapters.KubernetesRuntime
  (KubernetesRuntimeConfig (..), mkKubernetesRuntimeOpsWithCacheKey,
    readBackupReceiptFromCompletedPod)
import Nagare.Inventory.DataFence.MaintenancePostgres
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (..))
import Nagare.Inventory.LiveRestore
import Nagare.Inventory.LiveRestoreFence (selectedLiveRestoreProofs)
import Nagare.Inventory.LiveRestorePostgres
import Nagare.Inventory.LiveRestoreSource
import Nagare.Resource.Inventory (ManagedResource, ScopeDeclaration)
import Nagare.Resource.Types
import System.IO.Temp (withSystemTempDirectory)

liveRestoreAdapter :: KubernetesRuntimeConfig -> [ScopeDeclaration]
  -> Map ResourceId (ManagedResource, ByteString) -> Adapter -> Adapter
liveRestoreAdapter config scopes native base = base
  { adapterPreflight = preflight
  , adapterExecute = execute
  , adapterVerify = verify
  , adapterRecover = recover
  }
  where
    proofFor operation = case selectedLiveRestoreProofs scopes [operation] of
      Right [proof] -> Right proof
      Right _ -> Left "live restore operation has no unique source proof"
      Left reason -> Left reason

    ops = mkKubernetesRuntimeOpsWithCacheKey config
      (\_ -> pure (Left "live restore does not use a cache key")) native

    present resource uid = case Map.lookup resource native of
      Nothing -> pure (Left "live restore resource lacks accepted native bytes")
      Just (_, bytes) -> do
        current <- kubernetesObserve ops resource
        pure $ case current of
          KubernetesPresent actual _ (Just owner) digest
            | actual == uid, owner == resource,
              digest == contentDigest bytes -> Right ()
          _ -> Left "live restore resource incarnation or native bytes changed"

    completedBackup backup = do
      verified <- present (liveBackupJob backup) (liveBackupPhysical backup)
      case verified of
        Left reason -> pure (Left reason)
        Right () -> do
          receipt <- readBackupReceiptFromCompletedPod config
            (Map.restrictKeys native (Set.singleton (liveBackupJob backup)))
            (liveBackupJob backup) (liveBackupPhysical backup)
          pure $ do
            bytes <- receipt
            unless (contentDigest bytes == liveBackupReceiptDigest backup)
              (Left "live restore completed Job receipt changed since review")

    exactTarget proof = do
      stateful <- present (liveRestoreProofStateful proof)
        (liveRestoreProofStatefulUid proof)
      pvc <- present (liveRestoreProofPvc proof) (liveRestoreProofPvcUid proof)
      observedPod <- observePostgresPodUid
        (kubectlPostgresMaintenanceTransport config)
        (liveRestoreProofNamespace proof)
        (liveRestoreProofDatabase proof <> "-0")
      pure $ do
        stateful
        pvc
        podUid <- observedPod
        unless (podUid == physicalIdentityText (liveRestoreProofPodUid proof))
          (Left "live restore PostgreSQL Pod incarnation changed")

    verifyInputs proof = do
      target <- exactTarget proof
      case target of
        Left reason -> pure (Left reason)
        Right () -> do
          sourceJob <- completedBackup (liveRestoreProofSource proof)
          recoveryJob <- completedBackup (liveRestoreProofRecovery proof)
          case (sourceJob, recoveryJob) of
            (Right (), Right ()) -> do
              sourceStored <- withVerifiedLiveSource config proof
                (liveRestoreProofSource proof) (\_ -> pure (Right ()))
              recoveryStored <- withVerifiedLiveSource config proof
                (liveRestoreProofRecovery proof) (\_ -> pure (Right ()))
              pure (sourceStored >> recoveryStored)
            (Left reason, _) -> pure (Left reason)
            (_, Left reason) -> pure (Left reason)

    preflight operation prepared
      | plannedAction operation /= RestoreLiveDatabase =
          adapterPreflight base operation prepared
      | otherwise = do
          checked <- adapterPreflight base operation prepared
          case checked >>= \() -> proofFor operation of
            Left reason -> pure (Left reason)
            Right proof -> verifyInputs proof

    execute operation prepared
      | plannedAction operation /= RestoreLiveDatabase =
          adapterExecute base operation prepared
      | otherwise = do
          checked <- preflight operation prepared
          case checked >>= \() -> proofFor operation of
            Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
            Right proof -> do
              result <- withVerifiedLiveSource config proof
                (liveRestoreProofSource proof) $ \sourcePath ->
                  runLivePostgresRestore config proof sourcePath
              pure $ case result of
                Right () -> AdapterEffectCompleted
                Left reason -> AdapterEffectAmbiguous reason

    verify operation prepared
      | plannedAction operation /= RestoreLiveDatabase =
          adapterVerify base operation prepared
      | otherwise = case proofFor operation of
          Left reason -> pure (Left reason)
          Right proof -> do
            checked <- verifyInputs proof
            case checked of
              Left reason -> pure (Left reason)
              Right () -> withVerifiedLiveSource config proof
                (liveRestoreProofSource proof) $ \sourcePath ->
                  withSystemTempDirectory "nagare-live-verify" $ \scratch -> do
                    let observedPath = scratch <> "/observed.sql"
                    dumped <- dumpLivePostgres config proof observedPath
                    case dumped of
                      Left reason -> pure (Left reason)
                      Right () -> do
                        sourceBytes <- try (BS.readFile sourcePath)
                          :: IO (Either IOException ByteString)
                        observedBytes <- try (BS.readFile observedPath)
                          :: IO (Either IOException ByteString)
                        pure $ do
                          source <- first (const "live restore source SQL is unreadable")
                            sourceBytes >>= normalizePostgresDump
                          observed <- first (const "live restore PostgreSQL dump is unreadable")
                            observedBytes >>= normalizePostgresDump
                          unless (source == observed)
                            (Left "live PostgreSQL content differs from the reviewed backup")
                          pure (contentDigest observed)

    recover operation prepared
      | plannedAction operation /= RestoreLiveDatabase =
          adapterRecover base operation prepared
      | otherwise = case proofFor operation of
          Left reason -> pure (RecoveryUnresolved reason)
          Right proof -> do
            stopped <- terminateMarkedPostgresClients
              (kubectlPostgresMaintenanceTransport config)
              (liveRestoreProofNamespace proof)
              (liveRestoreProofDatabase proof <> "-0")
              (physicalIdentityText (liveRestoreProofPodUid proof))
              ("lr-" <> liveRestoreProofId proof)
            case stopped of
              Left reason -> pure (RecoveryUnresolved reason)
              Right () -> do
                result <- verify operation prepared
                pure (either RecoveryUnresolved RecoveryProvedComplete result)
