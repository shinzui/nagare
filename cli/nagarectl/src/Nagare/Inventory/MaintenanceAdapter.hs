-- | The reviewed database terminal operation. Preparation keeps the normal
-- immutable Kubernetes member format; execution is the one authorized local
-- socket client inside the online data fence.
module Nagare.Inventory.MaintenanceAdapter
  ( maintenanceAdapter
  )
where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (object, (.=))
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Database (Engine (..), engineToken)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
  ( KubernetesAdapterOps (..)
  , KubernetesState (..)
  )
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (..)
  , mkKubernetesRuntimeOpsWithCacheKey
  , readBackupReceiptFromCompletedPod
  )
import Nagare.Inventory.DataFence.MaintenanceClickHouse
import Nagare.Inventory.DataFence.MaintenancePostgres
import Nagare.Inventory.DataFence.MaintenanceRedis
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (..))
import Nagare.Inventory.Maintenance
import Nagare.Inventory.MaintenanceFence (selectedMaintenanceProofs)
import Nagare.Resource.Inventory (ManagedResource, ScopeDeclaration)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Exit (ExitCode (..))
import System.IO (hIsTerminalDevice, stdin, stdout)
import System.Process
  ( CreateProcess (..)
  , StdStream (Inherit)
  , createProcess
  , proc
  , waitForProcess
  )

maintenanceAdapter ::
  KubernetesRuntimeConfig ->
  [ScopeDeclaration] ->
  Map ResourceId (ManagedResource, ByteString) ->
  Adapter ->
  Adapter
maintenanceAdapter config scopes native base =
  base
    { adapterPreflight = preflight
    , adapterExecute = execute
    , adapterVerify = verify
    , adapterSettle = Just (fencedSettle OpenMaintenanceSession base)
    , adapterRecover = recover
    }
  where
    proofFor operation = case selectedMaintenanceProofs scopes [operation] of
      Right [proof] -> Right proof
      Right _ -> Left "maintenance operation has no unique source proof"
      Left reason -> Left reason

    preflight operation prepared
      | plannedAction operation /= OpenMaintenanceSession =
          adapterPreflight base operation prepared
      | otherwise = do
          checked <- adapterPreflight base operation prepared
          case checked >>= \() -> proofFor operation of
            Left reason -> pure (Left reason)
            Right proof -> do
              interactiveInput <- hIsTerminalDevice stdin
              interactiveOutput <- hIsTerminalDevice stdout
              if interactiveInput && interactiveOutput
                then observeRecovery proof
                else
                  pure
                    ( Left
                        "reviewed database shell requires an interactive terminal"
                    )

    observeRecovery proof = do
      let target = maintenanceSourceRecoveryJob proof
          backupNative = Map.restrictKeys native (Set.singleton target)
          ops =
            mkKubernetesRuntimeOpsWithCacheKey
              config
              (\_ -> pure (Left "maintenance recovery does not use a cache key"))
              backupNative
      case Map.lookup target backupNative of
        Nothing -> pure (Left "maintenance recovery Job lacks private native evidence")
        Just (_, bytes) -> do
          current <- kubernetesObserve ops target
          case current of
            KubernetesPresent uid _ (Just owner) digest
              | owner == target
              , uid == maintenanceSourceRecoveryJobUid proof
              , digest == contentDigest bytes -> do
                  receipt <-
                    readBackupReceiptFromCompletedPod
                      config
                      backupNative
                      target
                      uid
                  pure $ do
                    verified <- receipt
                    unless
                      ( contentDigest verified
                          == maintenanceSourceRecoveryReceiptDigest proof
                      )
                      (Left "maintenance recovery receipt changed since review")
            _ -> pure (Left "maintenance recovery Job incarnation or native bytes changed")

    execute operation prepared
      | plannedAction operation /= OpenMaintenanceSession =
          adapterExecute base operation prepared
      | otherwise = do
          checked <- preflight operation prepared
          case checked >>= \() -> proofFor operation of
            Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
            Right proof -> runTerminal proof

    runTerminal proof = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
        Right () -> do
          let namespace = maintenanceSourceNamespace proof
              pod = maintenanceSourceDatabase proof <> "-0"
              marker = "nagare-maintenance-" <> maintenanceSourceSession proof
              engine = maintenanceSourceEngine proof
              script = case engine of
                Postgres ->
                  "PGAPPNAME="
                    <> marker
                    <> " PGPASSWORD=\"$POSTGRES_PASSWORD\" exec psql -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""
                Redis ->
                  "NAGARE_MAINTENANCE_SESSION="
                    <> marker
                    <> " REDISCLI_AUTH=\"$REDIS_PASSWORD\" exec redis-cli --no-auth-warning --name "
                    <> marker
                ClickHouse ->
                  "NAGARE_MAINTENANCE_SESSION="
                    <> marker
                    <> " exec clickhouse-client --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\""
              command =
                ( proc
                    "kubectl"
                    [ "--context"
                    , T.unpack (runtimeKubectlContext config)
                    , "--namespace"
                    , T.unpack namespace
                    , "exec"
                    , "-it"
                    , T.unpack pod
                    , "--container"
                    , T.unpack (engineToken engine)
                    , "--"
                    , "sh"
                    , "-c"
                    , T.unpack script
                    ]
                )
                  { std_in = Inherit
                  , std_out = Inherit
                  , std_err = Inherit
                  }
          started <- try (createProcess command)
          case started of
            Left (_ :: IOException) ->
              pure
                ( AdapterEffectFailed
                    (KnownNoEffect "could not start reviewed database terminal")
                )
            Right (_, _, _, process) -> do
              outcome <- waitForProcess process
              pure $ case outcome of
                ExitSuccess -> AdapterEffectCompleted
                ExitFailure code ->
                  AdapterEffectAmbiguous
                    ( "database terminal exited "
                        <> T.pack (show code)
                        <> "; data outcome requires reviewed recovery"
                    )

    verify operation prepared
      | plannedAction operation /= OpenMaintenanceSession =
          adapterVerify base operation prepared
      | otherwise = case proofFor operation of
          Left reason -> pure (Left reason)
          Right proof -> do
            let observeClients = case maintenanceSourceEngine proof of
                  Postgres ->
                    observePostgresClients
                      (kubectlPostgresMaintenanceTransport config)
                  Redis ->
                    observeRedisClients
                      (kubectlRedisMaintenanceTransport config)
                  ClickHouse ->
                    observeClickHouseClients
                      (kubectlClickHouseMaintenanceTransport config)
            clients <-
              observeClients
                (maintenanceSourceNamespace proof)
                (maintenanceSourceDatabase proof <> "-0")
                (physicalIdentityText (maintenanceSourcePodUid proof))
            pure $ do
              gone <- clients
              unless gone (Left "reviewed database session still has clients")
              contentDigest
                <$> canonicalValue
                  ( object
                      [ "session" .= maintenanceSourceSession proof
                      , "podUid"
                          .= physicalIdentityText
                            (maintenanceSourcePodUid proof)
                      , "recoveryReceiptDigest"
                          .= digestText
                            (maintenanceSourceRecoveryReceiptDigest proof)
                      , "terminalOutcome" .= ("normal-exit" :: Text)
                      ]
                  )

    recover operation prepared
      | plannedAction operation /= OpenMaintenanceSession =
          adapterRecover base operation prepared
      | otherwise =
          pure
            ( RecoveryUnresolved
                "maintenance terminal outcome is unconfirmed; preserve the data fence"
            )
