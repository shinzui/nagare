-- | Dispatch. Executable-private CLI boundary.
module Nagare.Cli.Dispatch
  ( dispatch
  , dispatchTraced
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Cli.Commands.Access (runAccess)
import Nagare.Cli.Commands.Application
  ( runAppCheck
  , runAppDelete
  , runAppDeploy
  , runAppGet
  , runAppList
  , runAppLogs
  , runAppRestart
  , runAppStop
  , runDeploymentsList
  , runDeploymentsLogs
  )
import Nagare.Cli.Commands.Bootstrap (runPlatformBootstrapApply, runPlatformBootstrapPlan)
import Nagare.Cli.Commands.Broker (runBroker)
import Nagare.Cli.Commands.Cdn (runCdn)
import Nagare.Cli.Commands.Context (runContext)
import Nagare.Cli.Commands.Database (runDb)
import Nagare.Cli.Commands.Deployment (runDeploy)
import Nagare.Cli.Commands.Domains (runDomains)
import Nagare.Cli.Commands.Environment (runEnv, runSecret)
import Nagare.Cli.Commands.Host
  ( runCluster
  , runHost
  , runKubeconfig
  )
import Nagare.Cli.Commands.Image (runAppImagePlan)
import Nagare.Cli.Commands.Infrastructure
  ( runCleanup
  , runDoctor
  , runInfraApply
  , runInfraDestroy
  , runInfraGuard
  , runInfraPreview
  , runServerStatus
  )
import Nagare.Cli.Commands.Init (runInit)
import Nagare.Cli.Commands.Inventory.Status (runInventoryPublications, runInventoryStatus)
import Nagare.Cli.Commands.Inventory.Store
  ( runInventoryMaterializeNative
  , runInventoryStoreMigrate
  , runInventoryStoreStatus
  )
import Nagare.Cli.Commands.Platform
  ( runPlatformAdopt
  , runPlatformGuard
  , runPlatformRepin
  , runPlatformRoot
  , runPlatformStamp
  , runPlatformStatus
  , runVersion
  )
import Nagare.Cli.Commands.Release (runReleasePublish)
import Nagare.Cli.Commands.Site
  ( deployLoadedStaticSite
  , runPreviewDelete
  , runPreviewDeploy
  , runPreviewList
  , runSiteDeploy
  , runSiteReleases
  , runSiteRollback
  , staticSiteUrl
  )
import Nagare.Cli.Commands.SiteList (runSiteList)
import Nagare.Cli.Commands.SitePublish (runSitePackage, runSitePublish)
import Nagare.Cli.Commands.Storage (runStorage)
import Nagare.Cli.Commands.Task (runTask)
import Nagare.Cli.Commands.Transition (runPlatformTransitionCommit, runPlatformTransitionPlan)
import Nagare.Cli.Commands.Worker (runWorker)
import Nagare.Cli.Inventory.Rebuild (runInventoryRebuild, runInventoryRebuildDecisions)
import Nagare.Cli.Inventory.Workflow
  ( runInventoryAbandonMigration
  , runInventoryAdopt
  , runInventoryApply
  , runInventoryClose
  , runInventoryCollect
  , runInventoryExport
  , runInventoryLegacyGuard
  , runInventoryMigrate
  , runInventoryPlan
  , runInventoryRecover
  , runInventoryRegistryRecoveryPlan
  , runInventoryRestore
  , runInventoryResume
  , runInventoryRetire
  )
import Nagare.Cli.Options (Command (..), InfraCommand (..))
import Nagare.Cli.Platform.Upgrade
  ( runPlatformUpgrade
  , runPlatformUpgradeRecoverPulumi
  , runPlatformUpgradeRollback
  , runPlatformUpgradeStatus
  )
import Nagare.Contract.Sink (withContract, withReadContract)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Trace (withCommandScope)

-- | Trace a command (EP-212, EP-224), named by its constructor, never its arguments.
dispatchTraced :: (Maybe String, Command) -> IO ()
dispatchTraced selected@(_, command) = withCommandScope (T.pack (takeWhile (/= ' ') (show command))) (dispatch selected)

dispatch :: (Maybe String, Command) -> IO ()
dispatch (mctx, cmd0) = case cmd0 of
  Version versionOpts -> runVersion versionOpts
  ReleasePublish repository version assets yes -> runReleasePublish (T.pack repository) (T.pack version) assets yes Nothing
  ReleaseCleanupStarter repository version assets releaseId assetId assetName yes ->
    runReleasePublish (T.pack repository) (T.pack version) assets yes (Just (releaseId, assetId, T.pack assetName))
  PlatformRoot asJson -> runPlatformRoot mctx asJson
  PlatformStatusCmd asJson -> runPlatformStatus mctx asJson
  PlatformGuard -> runPlatformGuard mctx
  PlatformStamp -> runPlatformStamp mctx
  PlatformBootstrapPlan output -> runPlatformBootstrapPlan mctx output
  PlatformBootstrapApply review yes -> runPlatformBootstrapApply mctx review yes
  PlatformTransitionPlan output summary -> runPlatformTransitionPlan mctx output summary
  PlatformTransitionCommit yes -> runPlatformTransitionCommit mctx yes
  PlatformAdopt version yes asJson -> runPlatformAdopt mctx version yes asJson
  PlatformRepin version yes -> runPlatformRepin mctx version yes
  PlatformUpgrade options -> runPlatformUpgrade mctx options
  PlatformUpgradeStatus txId asJson -> runPlatformUpgradeStatus mctx txId asJson
  PlatformUpgradeRollback txId yes asJson -> runPlatformUpgradeRollback mctx txId yes asJson
  PlatformUpgradeRecoverPulumi txId outcome yes -> runPlatformUpgradeRecoverPulumi mctx txId outcome yes
  Host hcmd -> runHost mctx hcmd
  Kubeconfig kcmd -> runKubeconfig mctx kcmd
  Cluster ccmd -> runCluster mctx ccmd
  Deploy dopts -> runDeploy mctx dopts
  SiteDeploy sopts -> runSiteDeploy mctx sopts
  SitePackage popts -> runSitePackage mctx popts
  SitePublish popts -> withContract (popts ^. #contract) (runSitePublish mctx popts (runAppImagePlan mctx) (deployLoadedStaticSite mctx) staticSiteUrl)
  SiteReleases copts -> runSiteReleases copts
  SiteList lopts -> withReadContract (lopts ^. #contract) (runSiteList mctx lopts)
  SiteRollback copts rid -> runSiteRollback mctx copts (T.pack rid)
  SitePreviewDeploy sopts pname -> runPreviewDeploy mctx sopts (T.pack pname)
  SitePreviewList copts -> runPreviewList copts
  SitePreviewDelete copts pname -> runPreviewDelete mctx copts (T.pack pname)
  Env ecmd -> runEnv mctx ecmd
  Secret scmd -> runSecret mctx scmd
  AppCheck o -> runAppCheck o
  AppList o -> runAppList o
  AppGet o -> runAppGet o
  AppLogs o -> runAppLogs o
  AppRestart o -> runAppRestart mctx o
  AppStop o -> runAppStop mctx o
  AppDelete o -> runAppDelete mctx o
  AppDeploy o -> withContract (o ^. #contract) (runAppDeploy mctx o)
  AppImagePlan o -> withContract (o ^. #contract) (runAppImagePlan mctx o)
  DeploymentsList o -> runDeploymentsList o
  DeploymentsLogs o -> runDeploymentsLogs o
  Storage scmd -> runStorage mctx scmd
  Broker bcmd -> runBroker mctx bcmd
  Db dcmd -> runDb mctx dcmd
  Task tcmd -> runTask mctx tcmd
  Worker wcmd -> runWorker mctx wcmd
  Access acmd -> runAccess mctx acmd
  ServerStatus o -> runServerStatus mctx o
  Doctor o -> runDoctor mctx o
  ContextCmdGroup ccmd -> runContext mctx ccmd
  Init o -> runInit mctx o
  Infra (InfraGuard allowReplacement) -> runInfraGuard mctx allowReplacement
  Infra (InfraPreview options) -> runInfraPreview mctx options
  Infra (InfraApply options) -> runInfraApply mctx options
  Infra (InfraDestroy yes output) -> runInfraDestroy mctx yes output
  Domains c -> runDomains mctx c
  CdnCmd ccmd -> runCdn mctx ccmd
  Cleanup o -> runCleanup mctx o
  InventoryCompile input output json -> Inventory.compileInventory input output json
  InventoryPlan input retained output -> runInventoryPlan mctx input retained output
  InventoryAdopt input output -> runInventoryAdopt mctx input output
  InventoryRebuildDecisions points snapshots runs fresh bucket store credentials output -> runInventoryRebuildDecisions mctx points snapshots runs fresh bucket store credentials output
  InventoryRebuild input output -> runInventoryRebuild mctx input output
  InventoryMigrate input output -> runInventoryMigrate mctx input output
  InventoryRetire owner output -> runInventoryRetire mctx owner output
  InventoryGc output -> runInventoryStatus mctx Nothing True (Just output) Nothing
  InventoryCollect resource output descendants -> runInventoryCollect mctx resource output descendants
  InventoryApply directory yes contract -> withContract contract (runInventoryApply mctx directory yes)
  InventoryResume transaction yes takeOver contract -> withContract contract (runInventoryResume mctx (T.pack transaction) yes takeOver)
  InventoryRecover transaction operation decisionFile takeOver ->
    runInventoryRecover mctx (T.pack transaction) (T.pack operation) decisionFile takeOver
  InventoryClose transaction review attest takeOver -> runInventoryClose mctx (T.pack transaction) (T.pack review) attest takeOver
  InventoryAbandonMigration transaction review takeOver -> runInventoryAbandonMigration mctx (T.pack transaction) (T.pack review) takeOver
  InventoryRegistryRecoveryPlan transaction operation output ->
    runInventoryRegistryRecoveryPlan mctx transaction operation output
  InventoryExport output -> runInventoryExport mctx output
  InventoryRestore backup yes -> runInventoryRestore mctx backup yes
  InventoryLegacyGuard operation -> runInventoryLegacyGuard mctx operation
  InventoryStatus json scope contract -> withReadContract contract (runInventoryStatus mctx Nothing json Nothing scope)
  InventoryPublications contract -> withReadContract contract (runInventoryPublications mctx)
  InventoryExplain resource json -> runInventoryStatus mctx (Just resource) json Nothing Nothing
  InventoryStoreMaterializeNative after limit -> runInventoryMaterializeNative mctx after limit
  InventoryStoreStatus json -> runInventoryStoreStatus mctx json
  InventoryStoreMigrate destination dryRun yes -> runInventoryStoreMigrate mctx destination dryRun yes
