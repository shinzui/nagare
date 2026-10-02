-- | Suite responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Suite
  ( main
  )
where

import AccessGrantsSpec (accessGrantsTests)
import AccessResolveSpec (accessResolveTests)
import AppDeploySpec (appDeployTests)
import CertificateMigrationSpec (certificateMigrationTests)
import Data.ByteString qualified as BS
import DataFenceSpec (dataFenceTests)
import DomainBindingSpec (domainBindingTests)
import HostSpec (hostTests)
import InventoryAccessSpec (inventoryAccessTests)
import InventoryApplicationSpec (inventoryApplicationTests)
import InventoryArtifactSpec (inventoryArtifactTests)
import InventoryAuthSpec (inventoryAuthTests)
import InventoryCacheSpec (inventoryCacheTests)
import InventoryCdnSpec (inventoryCdnTests)
import InventoryCloudSpec (inventoryCloudTests)
import InventoryEffectfulCollectionSpec (inventoryEffectfulCollectionTests, runCollectionResumeProbe)
import InventoryEffectfulSpec (inventoryEffectfulTests, runEffectfulResumeProbe)
import InventoryFoundationSpec (inventoryFoundationTests)
import InventoryGcloudAuthSpec (inventoryGcloudAuthTests)
import InventoryGogolSpec (inventoryGogolTests)
import InventoryHostSpec (inventoryHostTests)
import InventoryIntegrationSpec (inventoryIntegrationTests)
import InventoryKubernetesSpec (inventoryKubernetesTests)
import InventoryLifecycleSpec (inventoryLifecycleTests)
import InventoryMaintenanceSpec (inventoryMaintenanceTests)
import InventoryMigrationSpec (inventoryMigrationTests)
import InventoryObjectOpsSpec (inventoryObjectOpsTests)
import InventoryObservabilitySpec (inventoryObservabilityTests)
import InventoryObservationSpec (inventoryObservationTests)
import InventoryPublicationSpec (inventoryPublicationTests)
import InventorySpec (inventoryTests)
import InventoryStatusSpec (inventoryStatusTests)
import InventoryTransactionSpec
  ( inventoryTransactionTests
  , runInventoryLockHoldProbe
  , runInventoryLockProbe
  )
import InventoryUpstreamSpec (inventoryUpstreamTests)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Test.Application (appTests, deploymentsTests)
import Nagare.Test.Backend
  ( backupProjectTests
  , gcsJobHostAliasesTests
  , storeBackendModeTests
  )
import Nagare.Test.BackupRestore (backupRestoreTests)
import Nagare.Test.Broker (brokerConnectionEnvTests, brokerTests)
import Nagare.Test.Build (buildModeTests)
import Nagare.Test.Cdn
  ( cdnProvisionTests
  , cdnStatusTests
  , cloudflareTests
  )
import Nagare.Test.Cluster
  ( certificatePolicyTests
  , clusterGuardTests
  , namespaceTests
  )
import Nagare.Test.Context
  ( contextGuardTests
  , contextResolutionTests
  , modeResolutionTests
  , targetProfileTests
  )
import Nagare.Test.Database (connectionEnvTests, databaseTests)
import Nagare.Test.Domains (domainTlsTests, domainsTests)
import Nagare.Test.Environment
  ( buildArgsTests
  , dotenvTests
  , envStoreTests
  , generatedEnvTests
  , previewOverlayTests
  , reconcileModeTests
  , renderDemonstrationTests
  )
import Nagare.Test.Gcp (adcTests)
import Nagare.Test.GhcEnvironment (ghcEnvTests)
import Nagare.Test.Image (dockerAuthPlanTests, qualifyImageTests)
import Nagare.Test.Infrastructure (infraPlanTests)
import Nagare.Test.Init (initTests)
import Nagare.Test.Operations
  ( cleanupTests
  , doctorTests
  , opsTests
  )
import Nagare.Test.Pulumi (pulumiBackendBootstrapTests)
import Nagare.Test.Server (serverBuildTests)
import Nagare.Test.SiteInventory (staticInventoryTests)
import Nagare.Test.Static
  ( dockerfileTests
  , prepareTests
  , previewTests
  , releaseTests
  )
import Nagare.Test.Storage
  ( storageDiscoverTests
  , storageSnapshotTests
  , volumeArchiveTests
  )
import Nagare.Test.Task
  ( taskDiscoverTests
  , taskResolveTests
  , taskRunTests
  )
import Nagare.Test.Version (versionTests)
import Nagare.Test.Webhook (webhookTests)
import PlatformCutoverSpec (platformCutoverTests)
import PlatformSpec (platformTests)
import System.Environment (lookupEnv)
import System.Exit (exitWith)
import Test.Tasty (defaultMain, localOption, testGroup)
import Test.Tasty.Runners (NumThreads (..))

main :: IO ()
main = do
  collectionRoot <- lookupEnv "NAGARE_COLLECTION_ROOT"
  collectionReview <- lookupEnv "NAGARE_COLLECTION_REVIEW"
  collectionTransaction <- lookupEnv "NAGARE_COLLECTION_TRANSACTION"
  collectionExpected <- lookupEnv "NAGARE_COLLECTION_EXPECT"
  case (collectionRoot, collectionReview, collectionTransaction, collectionExpected) of
    (Just root, Just digest, Just transaction, Just expected) -> runCollectionResumeProbe root digest transaction expected >>= exitWith
    _ -> pure ()
  effectRoot <- lookupEnv "NAGARE_EFFECTFUL_RESUME_ROOT"
  effectReview <- lookupEnv "NAGARE_EFFECTFUL_REVIEW"
  effectTransaction <- lookupEnv "NAGARE_EFFECTFUL_TRANSACTION"
  case (effectRoot, effectReview, effectTransaction) of
    (Just root, Just review, Just transaction) -> runEffectfulResumeProbe root review transaction >>= exitWith
    _ -> pure ()
  lockHolder <- lookupEnv "NAGARE_INVENTORY_LOCK_HOLD"
  lockReady <- lookupEnv "NAGARE_INVENTORY_LOCK_READY"
  lockProbe <- lookupEnv "NAGARE_INVENTORY_LOCK_PROBE"
  case (lockHolder, lockReady, lockProbe) of
    (Just root, Just ready, _) -> runInventoryLockHoldProbe root ready >>= exitWith
    (_, _, Just root) -> runInventoryLockProbe root >>= exitWith
    _ -> do
      taskFixture <- BS.readFile "test/fixtures/cronjob-list.json"
      defaultMain $
        localOption (NumThreads 1) $
          testGroup "nagarectl" $
            [ inventoryAccessTests
            , testGroup "Nagare.Static.Image" dockerfileTests
            , hostTests
            , inventoryArtifactTests
            , inventoryCacheTests
            , inventoryFoundationTests
            , inventoryUpstreamTests
            , inventoryAuthTests
            , inventoryObservabilityTests
            , inventoryPublicationTests
            , inventoryCloudTests
            , inventoryHostTests
            , inventoryEffectfulCollectionTests
            , inventoryEffectfulTests
            , inventoryKubernetesTests
            , inventoryApplicationTests
            , inventoryCdnTests
            , inventoryLifecycleTests
            , inventoryMigrationTests
            , inventoryStatusTests
            , inventoryObservationTests
            , inventoryGcloudAuthTests
            , inventoryGogolTests
            , inventoryObjectOpsTests
            , inventoryTests
            , inventoryTransactionTests
            , dataFenceTests
            , inventoryMaintenanceTests
            , inventoryIntegrationTests
            , platformTests
            , platformCutoverTests
            , testGroup "Nagare.Static.Build" prepareTests
            , testGroup "Nagare.Static.Release" releaseTests
            , testGroup "Nagare.Inventory.Site" staticInventoryTests
            , testGroup "Nagare.Static.Preview" previewTests
            , testGroup "Nagare.Static.Webhook" webhookTests
            , testGroup "Nagare.Server.Build" serverBuildTests
            , testGroup "Nagare.Build" buildModeTests
            , testGroup "Nagare.Env.Store" envStoreTests
            , testGroup "Nagare.Env.Dotenv" dotenvTests
            , testGroup "Nagare.Env reconcile mode" reconcileModeTests
            , testGroup "Nagare.Env.Generated" generatedEnvTests
            , testGroup "EP-26 render demonstration" renderDemonstrationTests
            , testGroup "Nagare.Env.BuildArgs" buildArgsTests
            , testGroup "Nagare.Env.PreviewOverlay" previewOverlayTests
            , testGroup "Nagare.Ops" opsTests
            , testGroup "Nagare.Ops.Doctor" doctorTests
            , testGroup "Nagare.Ops.Domains" domainsTests
            , testGroup "Nagare.Ops.Cleanup" cleanupTests
            , testGroup "Nagare.App" appTests
            , testGroup "Nagare.App.Deployments" deploymentsTests
            , testGroup "Nagare.Storage.Discover" storageDiscoverTests
            , testGroup "Nagare.Storage.Snapshot" storageSnapshotTests
            , testGroup "Nagare.Storage.Restore archive" volumeArchiveTests
            , testGroup "GCS data-movement Job hostAliases (EP-1)" gcsJobHostAliasesTests
            , testGroup "Nagare.Cluster.Namespace" namespaceTests
            , testGroup "Nagare.Cluster.CertificatePolicy" certificatePolicyTests
            , certificateMigrationTests
            , testGroup "Data-movement Job store backend (EP-84)" storeBackendModeTests
            , testGroup "Nagare.GhcEnv (EP-6)" ghcEnvTests
            , testGroup "Nagare.Version" versionTests
            , testGroup "Nagare.Database (EP-45)" databaseTests
            , testGroup "Nagare.Broker (EP-78)" brokerTests
            , testGroup "Nagare.Broker.Connection (EP-77)" brokerConnectionEnvTests
            , testGroup "Nagare.Database.Connection (EP-46)" connectionEnvTests
            , testGroup "Nagare.Database.Backup/Restore (EP-47)" backupRestoreTests
            , testGroup "Nagare.Task.Discover (EP-51)" (taskDiscoverTests taskFixture)
            , testGroup "Nagare.Task.Run / Logs (EP-51)" taskRunTests
            , testGroup "Nagare.Task.Resolve (EP-52)" taskResolveTests
            , testGroup "Nagare.Cdn (EP-57)" cloudflareTests
            , testGroup "Nagare.Cdn.Provision (EP-58)" cdnProvisionTests
            , testGroup "Nagare.Cdn.Status (EP-58)" cdnStatusTests
            , testGroup "Nagare.Target (EP-62)" [targetProfileTests]
            , contextResolutionTests
            , testGroup "EP-62 rendered Job project" backupProjectTests
            , testGroup "EP-62 qualifyImage" qualifyImageTests
            , modeResolutionTests
            , dockerAuthPlanTests
            , initTests
            , infraPlanTests
            , pulumiBackendBootstrapTests
            , contextGuardTests
            , adcTests
            , clusterGuardTests
            , domainBindingTests
            , testGroup "Nagare.Domain.Tls" domainTlsTests
            , accessGrantsTests
            , accessResolveTests
            , appDeployTests
            ]
