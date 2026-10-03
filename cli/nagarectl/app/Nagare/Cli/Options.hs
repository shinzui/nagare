-- | Options. Executable-private CLI boundary.
module Nagare.Cli.Options
  ( AccessCommand (..)
  , AccessGrantOpts (..)
  , AccessListOpts (..)
  , AppDeleteOpts (..)
  , AppDeployOpts (..)
  , AppGetOpts (..)
  , AppImagePlanOpts (..)
  , AppCheckOpts (..)
  , AppListOpts (..)
  , AppLogsOpts (..)
  , AppNameOpts (..)
  , BrokerCommand (..)
  , BrokerCreateOpts (..)
  , BrokerListOpts (..)
  , BrokerNameOpts (..)
  , CdnCommand (..)
  , CdnDisableOpts (..)
  , CdnListOpts (..)
  , CdnPurgeOpts (..)
  , CdnStatusOpts (..)
  , ClusterCommand (..)
  , ClusterGuardOpts (..)
  , Command (..)
  , ContextCommand (..)
  , ContextCreateOpts (..)
  , DbBackupOpts (..)
  , DbBackupReceiptsOpts (..)
  , DbEscrowSigningKeyOpts (..)
  , DbVerifyEscrowedBackupOpts (..)
  , DbCommand (..)
  , DbCreateOpts (..)
  , DbListOpts (..)
  , DbNameOpts (..)
  , DbPruneBackupOpts (..)
  , DbPruneScheduledBackupsOpts (..)
  , DbRecoverScheduledPruneOpts (..)
  , DbRestoreOpts (..)
  , DepListOpts (..)
  , DepLogsOpts (..)
  , DeployOpts (..)
  , DoctorOpts (..)
  , DomainsCommand (..)
  , DomainsListOpts (..)
  , EnvCommand (..)
  , HostCommand (..)
  , HostInitOpts (..)
  , HostPlaceAgeKeyOpts (..)
  , InfraApplyOpts (..)
  , InfraCommand (..)
  , InfraPreviewOpts (..)
  , KubeconfigCommand (..)
  , KubeconfigFetchOpts (..)
  , PortalCommand (..)
  , ScopeSelection (..)
  , SecretCommand (..)
  , ServerStatusOpts (..)
  , SiteCommonOpts (..)
  , SiteDeployOpts (..)
  , SitePreviewDeleteOpts (..)
  , SiteRollbackOpts (..)
  , StandaloneRetireOpts (..)
  , StorageCommand (..)
  , StoreCommonOpts (..)
  , TaskCommand (..)
  , TaskDeleteOpts (..)
  , TaskListOpts (..)
  , TaskLogsOpts (..)
  , TaskRunOpts (..)
  , UpgradeOpts (..)
  , VersionOpts (..)
  , WorkerCommand (..)
  , WorkerDeleteOpts (..)
  , WorkerDeployOpts (..)
  )
where

import Data.List.NonEmpty qualified as NE
import Nagare.Dsl.Broker (BrokerProvider)
import Nagare.Dsl.Database (Engine)
import Nagare.Dsl.Prelude
import Nagare.Init (InitOpts)
import Nagare.Ops.Cleanup (CleanupOpts)

-- CLI options

-- | Options for the @deploy@ subcommand. @contextOverride@ and
-- @dockerfileOverride@ are optional overrides of the build mode declared in the
-- config; both default to 'Nothing' (use the config's values).
data DeployOpts = DeployOpts
  { file :: !FilePath
  , tag :: !(Maybe String)
  , baseDomain :: !(Maybe String)
  , contextOverride :: !(Maybe FilePath)
  , dockerfileOverride :: !(Maybe FilePath)
  , ghcEnv :: !(Maybe FilePath)
  , dryRun :: !Bool
  , source :: !(Maybe String)
  -- ^ Free-form provenance recorded with the deployment (e.g. a git SHA or
  -- branch), and surfaced as @NAGARE_SOURCE@ — matching the site deploy path.
  , savePlan :: !(Maybe FilePath)
  , imageResource :: !(Maybe String)
  , serviceVolumeRecovery :: ![String]
  , tlsSecretResources :: ![String]
  , envSecretResources :: ![String]
  , legacyReleaseImport :: !(Maybe FilePath)
  , releaseAdoptionInput :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

data AppImagePlanOpts = AppImagePlanOpts
  { archive :: !FilePath
  , destination :: !String
  , key :: !String
  , buildInputResources :: ![String]
  , buildDockerfile :: !(Maybe FilePath)
  , buildContext :: !(Maybe FilePath)
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | Options for @worker deploy@ (EP-71). A worker has no URL and no deployment
-- history, so (unlike 'DeployOpts') it carries no @--base-domain@ or @--source@.
data WorkerDeployOpts = WorkerDeployOpts
  { file :: !FilePath
  , tag :: !(Maybe String)
  , contextOverride :: !(Maybe FilePath)
  , dockerfileOverride :: !(Maybe FilePath)
  , ghcEnv :: !(Maybe FilePath)
  , dryRun :: !Bool
  , savePlan :: !(Maybe FilePath)
  , imageResource :: !(Maybe String)
  , volumeRecovery :: ![String]
  , envSecretResources :: ![String]
  }
  deriving stock (Generic, Show)

-- | Options for @app deploy@ (MasterPlan 14, EP-2): deploy a whole multi-workload
-- 'Nagare.Dsl.Application.Application' in one command. Mirrors 'DeployOpts' plus a
-- @--json@ switch that selects the machine-readable @--dry-run@ plan (the kotei
-- contract).
data AppDeployOpts = AppDeployOpts
  { file :: !FilePath
  , tag :: !(Maybe String)
  , baseDomain :: !(Maybe String)
  , contextOverride :: !(Maybe FilePath)
  , dockerfileOverride :: !(Maybe FilePath)
  , ghcEnv :: !(Maybe FilePath)
  , dryRun :: !Bool
  , json :: !Bool
  , source :: !(Maybe String)
  , savePlan :: !(Maybe FilePath)
  , imageResource :: !(Maybe String)
  , cdnBackendResource :: !(Maybe String)
  , databaseRecovery :: ![String]
  , tlsSecretResources :: ![String]
  , envSecretResources :: ![String]
  , serviceVolumeRecovery :: ![String]
  , workerVolumeRecovery :: ![String]
  , hookAffects :: ![String]
  , hookNoDataEffects :: ![String]
  , requestNamespace :: !Bool
  , legacyReleaseImport :: !(Maybe FilePath)
  , releaseAdoptionInput :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

data WorkerCommand
  = WorkerDeploy WorkerDeployOpts
  | WorkerDelete WorkerDeleteOpts
  deriving stock (Generic, Show)

data WorkerDeleteOpts = WorkerDeleteOpts
  { nameArg :: !String
  , namespace :: !(Maybe String)
  , savePlan :: !FilePath
  , scopeKey :: !(Maybe String)
  }
  deriving stock (Generic, Show)

data AccessCommand
  = AccessGrant AccessGrantOpts
  | AccessRevoke AccessGrantOpts
  | AccessList AccessListOpts
  | AccessPortal PortalCommand
  deriving stock (Generic, Show)

data PortalCommand
  = PortalShow
  | PortalSync !(Maybe FilePath)
  deriving stock (Generic, Show)

data AccessGrantOpts = AccessGrantOpts
  { savePlan :: !(Maybe FilePath)
  , enUrl :: !(Maybe String)
  , enApiKey :: !(Maybe String)
  , host :: !String
  , user :: !String
  }
  deriving stock (Generic, Show)

data AccessListOpts = AccessListOpts
  { enUrl :: !(Maybe String)
  , enApiKey :: !(Maybe String)
  , host :: !String
  }
  deriving stock (Generic, Show)

-- | Options for @site deploy@ (and, with a @--name@, @site preview deploy@).
data SiteDeployOpts = SiteDeployOpts
  { file :: !FilePath
  , tag :: !(Maybe String)
  , baseDomain :: !(Maybe String)
  , projectDir :: !FilePath
  , ghcEnv :: !(Maybe FilePath)
  , dryRun :: !Bool
  , skipBuild :: !Bool
  , source :: !(Maybe String)
  -- ^ Free-form provenance recorded with the release (e.g. a git SHA or branch).
  , savePlan :: !(Maybe FilePath)
  , imageResource :: !(Maybe String)
  , cdnBackendResource :: !(Maybe String)
  , siteVolumeRecovery :: ![String]
  , siteEnvSecretResources :: ![String]
  , siteTlsSecretResources :: ![String]
  , sitePreviewEnvResources :: ![String]
  , sitePreviewAdoptionInput :: !(Maybe FilePath)
  , legacyReleaseImport :: !(Maybe FilePath)
  , releaseAdoptionInput :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | Options for the read-only / config-only site subcommands (@releases@,
-- @rollback@, @preview list@, @preview delete@): enough to load the config and
-- resolve the base domain.
data SiteCommonOpts = SiteCommonOpts
  { file :: !FilePath
  , baseDomain :: !(Maybe String)
  , ghcEnv :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

data SiteRollbackOpts = SiteRollbackOpts
  { common :: !SiteCommonOpts
  , savePlan :: !(Maybe FilePath)
  , imageResource :: !(Maybe String)
  , cdnBackendResource :: !(Maybe String)
  , siteVolumeRecovery :: ![String]
  , siteEnvSecretResources :: ![String]
  , siteTlsSecretResources :: ![String]
  }
  deriving stock (Generic, Show)

data SitePreviewDeleteOpts = SitePreviewDeleteOpts
  { common :: !SiteCommonOpts
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | Options for @app list@: a namespace (default @personal@) and @--all@ to drop
-- the Nagare-managed label filter (EP-30).
-- | @app check@: evaluate a typed Application config with no context access.
data AppCheckOpts = AppCheckOpts
  { file :: !FilePath
  , ghcEnv :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

data AppListOpts = AppListOpts
  { namespace :: !(Maybe String)
  , allApps :: !Bool
  }
  deriving stock (Generic, Show)

-- | Options for @app get@: a positional @NAME@, optional namespace, and a
-- @--file@ config used only to enrich the output with EP-29's configured
-- domains/health check/limits (skipped when the config is absent).
data AppGetOpts = AppGetOpts
  { nameArg :: !String
  , namespace :: !(Maybe String)
  , file :: !FilePath
  , ghcEnv :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | Options for @app logs@: a positional @NAME@, optional namespace, @--follow@,
-- and an optional @--tail N@ (default 200 when not following).
data AppLogsOpts = AppLogsOpts
  { nameArg :: !String
  , namespace :: !(Maybe String)
  , follow :: !Bool
  , tailN :: !(Maybe Int)
  }
  deriving stock (Generic, Show)

-- | Options for the @app NAME@ commands that need only a name and namespace
-- (@restart@, @stop@).
data AppNameOpts = AppNameOpts
  { nameArg :: !String
  , namespace :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | Options for saved review of application or standalone Service retirement.
data AppDeleteOpts = AppDeleteOpts
  { nameArg :: !String
  , namespace :: !(Maybe String)
  , savePlan :: !(Maybe FilePath)
  , scopeKey :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | Options for @deployments list NAME@ (EP-31).
data DepListOpts = DepListOpts
  { nameArg :: !String
  , namespace :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | Options for @deployments logs NAME [DEPLOYMENT_ID]@ (EP-31): an optional
-- positional id selects a past deployment's revision; absent streams the live one.
data DepLogsOpts = DepLogsOpts
  { nameArg :: !String
  , depId :: !(Maybe String)
  , namespace :: !(Maybe String)
  , follow :: !Bool
  , tailN :: !(Maybe Int)
  }
  deriving stock (Generic, Show)

-- | Everything @nagarectl@ can be asked to do.
data Command
  = Version VersionOpts
  | ReleasePublish String String FilePath Bool
  | ReleaseCleanupStarter String String FilePath Integer Integer String Bool
  | InventoryCompile FilePath FilePath Bool
  | InventoryPlan FilePath [String] FilePath
  | InventoryAdopt FilePath FilePath
  | InventoryMigrate FilePath FilePath
  | InventoryRetire String FilePath
  | InventoryGc FilePath
  | InventoryCollect (NE.NonEmpty String) FilePath Bool
  | InventoryApply FilePath Bool
  | InventoryResume String Bool Bool
  | InventoryRecover String String FilePath Bool
  | InventoryRegistryRecoveryPlan String String FilePath
  | InventoryExport FilePath
  | InventoryRestore FilePath Bool
  | InventoryStatus Bool
  | InventoryLegacyGuard String
  | InventoryExplain String Bool
  | InventoryStoreMaterializeNative (Maybe String) Int
  | InventoryStoreStatus Bool
  | InventoryStoreMigrate String Bool Bool
  | PlatformRoot Bool
  | PlatformStatusCmd Bool
  | PlatformGuard
  | PlatformStamp
  | PlatformBootstrapPlan FilePath
  | PlatformBootstrapApply FilePath Bool
  | PlatformAdopt String Bool Bool
  | PlatformRepin String Bool
  | PlatformUpgrade UpgradeOpts
  | PlatformUpgradeStatus (Maybe String) Bool
  | PlatformUpgradeRollback String Bool Bool
  | PlatformUpgradeRecoverPulumi String String Bool
  | Host HostCommand
  | Kubeconfig KubeconfigCommand
  | Cluster ClusterCommand
  | Deploy DeployOpts
  | SiteDeploy SiteDeployOpts
  | SiteReleases SiteCommonOpts
  | SiteRollback SiteRollbackOpts String
  | SitePreviewDeploy SiteDeployOpts String
  | SitePreviewList SiteCommonOpts
  | SitePreviewDelete SitePreviewDeleteOpts String
  | Env EnvCommand
  | Secret SecretCommand
  | AppCheck AppCheckOpts
  | AppList AppListOpts
  | AppGet AppGetOpts
  | AppLogs AppLogsOpts
  | AppRestart AppNameOpts
  | AppStop AppNameOpts
  | AppDelete AppDeleteOpts
  | AppDeploy AppDeployOpts
  | AppImagePlan AppImagePlanOpts
  | DeploymentsList DepListOpts
  | DeploymentsLogs DepLogsOpts
  | Storage StorageCommand
  | Broker BrokerCommand
  | Db DbCommand
  | Task TaskCommand
  | Worker WorkerCommand
  | Access AccessCommand
  | ServerStatus ServerStatusOpts
  | Doctor DoctorOpts
  | ContextCmdGroup ContextCommand
  | Init InitOpts
  | Infra InfraCommand
  | Domains DomainsCommand
  | CdnCmd CdnCommand
  | Cleanup CleanupOpts
  deriving stock (Generic, Show)

data VersionOpts = VersionOpts
  { json :: !Bool
  , tools :: !Bool
  }
  deriving stock (Generic, Show)

data HostCommand
  = HostInit HostInitOpts
  | HostShow (Maybe String)
  | HostPath (Maybe String)
  | HostName (Maybe String) Bool
  | HostPlaceAgeKey HostPlaceAgeKeyOpts
  | HostImagePlan FilePath
  | HostPlan FilePath (Maybe FilePath) Bool
  | HostStart String FilePath
  | HostStop String FilePath
  | HostApply FilePath Bool
  deriving stock (Generic, Show)

data KubeconfigCommand
  = KubeconfigFetch KubeconfigFetchOpts
  | KubeconfigRecover
  deriving stock (Generic, Show)

data KubeconfigFetchOpts = KubeconfigFetchOpts
  { context :: !(Maybe String)
  , output :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

data ClusterCommand
  = ClusterGuard ClusterGuardOpts
  | ClusterCertificatePolicy
  deriving stock (Generic, Show)

data ClusterGuardOpts = ClusterGuardOpts
  { context :: !(Maybe String)
  , json :: !Bool
  }
  deriving stock (Generic, Show)

data UpgradeOpts = UpgradeOpts
  { to :: !(Maybe String)
  , payloadRoot :: !(Maybe FilePath)
  , apply :: !Bool
  , resume :: !(Maybe String)
  , dryRun :: !Bool
  , yes :: !Bool
  , json :: !Bool
  }
  deriving stock (Generic, Show)

data HostInitOpts = HostInitOpts
  { context :: !(Maybe String)
  , sshPublicKeyFiles :: ![FilePath]
  , sopsFile :: !(Maybe FilePath)
  , ageKeyFile :: !FilePath
  , hostName :: !(Maybe String)
  , instanceName :: !(Maybe String)
  , registryHost :: !(Maybe String)
  , deployUser :: !String
  , force :: !Bool
  , dryRun :: !Bool
  }
  deriving stock (Generic, Show)

data HostPlaceAgeKeyOpts = HostPlaceAgeKeyOpts
  { context :: !(Maybe String)
  , keyFile :: !FilePath
  , force :: !Bool
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | The @context@ subcommands (EP-88). They manage the user-level target context
-- store introduced by EP-87.
data ContextCommand
  = ContextList
  | ContextCurrent
  | ContextUse String
  | ContextShow (Maybe String)
  | ContextCreate String ContextCreateOpts
  | ContextDelete String Bool (Maybe FilePath)
  | ContextApply FilePath Bool
  | ContextRestore FilePath Bool
  | -- | EP-113: refuse when anything disagrees about which project the next
    -- Pulumi operation would write to. The 'Bool' is @--json@.
    ContextGuard Bool
  | -- | EP-113: print the active context's shell environment for @eval@ by the
    -- @nagare@ launcher, which has no @.envrc@.
    ContextEnv
  deriving stock (Generic, Show)

data ContextCreateOpts = ContextCreateOpts
  { project :: !(Maybe String)
  , region :: !(Maybe String)
  , zone :: !(Maybe String)
  , baseDomain :: !(Maybe String)
  , externalDomainTlsEnabled :: !(Maybe String)
  , machineType :: !(Maybe String)
  , bootDiskType :: !(Maybe String)
  , bootDiskSizeGb :: !(Maybe String)
  , dataDiskSizeGb :: !(Maybe String)
  , registryHost :: !(Maybe String)
  , artifactRegistryId :: !(Maybe String)
  , imageBucket :: !(Maybe String)
  , backupBucket :: !(Maybe String)
  , nixCacheEnabled :: !(Maybe String)
  , nixCacheBucket :: !(Maybe String)
  , instanceName :: !(Maybe String)
  , serviceAccountId :: !(Maybe String)
  , targetPlatform :: !(Maybe String)
  , mode :: !(Maybe String)
  , localObjectStore :: !(Maybe String)
  , pulumiBackend :: !(Maybe String)
  , pulumiBackendUrl :: !(Maybe String)
  , inventoryStore :: !(Maybe String)
  , inventoryStoreUrl :: !(Maybe String)
  , pulumiBackendMember :: !(Maybe String)
  , acmeEmail :: !(Maybe String)
  , acmeDirectory :: !(Maybe String)
  , force :: !Bool
  , use :: !Bool
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

data InfraCommand
  = InfraGuard Bool
  | InfraPreview InfraPreviewOpts
  | InfraApply InfraApplyOpts
  | InfraDestroy Bool (Maybe FilePath)
  deriving stock (Generic, Show)

data InfraPreviewOpts = InfraPreviewOpts
  { savePlan :: !FilePath
  , inventory :: !(Maybe FilePath)
  , allowReplacement :: !Bool
  }
  deriving stock (Generic, Show)

data InfraApplyOpts = InfraApplyOpts
  { plan :: !FilePath
  , yes :: !Bool
  , allowReplacement :: !Bool
  }
  deriving stock (Generic, Show)

-- | Options shared by every @env@/@secret@ subcommand: enough to load the config
-- and resolve @(name, namespace)@, plus the positional @APP@ for readability. The
-- config file uses @-f/--config@ here (not @--file@) so @env sync@'s dotenv
-- argument can use @--file@.
data StoreCommonOpts = StoreCommonOpts
  { app :: !String
  -- ^ positional APP (informational; identity comes from the loaded config)
  , file :: !FilePath
  -- ^ -f/--config, default nagare/Config.hs
  , ghcEnv :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | Which scope store(s) an operation targets. When none of
-- @--runtime/--build/--preview@ is given, 'Runtime' is the default.
data ScopeSelection = ScopeSelection
  { runtime :: !Bool
  , build :: !Bool
  , preview :: !Bool
  }
  deriving stock (Generic, Show)

-- | The @env@ subcommands. The trailing 'Bool' on the mutating variants is
-- @--dry-run@.
data EnvCommand
  = -- | Bool = --all (show all three scopes)
    EnvList StoreCommonOpts Bool
  | -- | dryRun, KEY, VALUE, reviewed execution, optional review directory
    EnvSet StoreCommonOpts ScopeSelection Bool String String Bool (Maybe FilePath)
  | -- | dryRun, KEY, reviewed execution, optional review directory
    EnvDelete StoreCommonOpts ScopeSelection Bool String Bool (Maybe FilePath)
  | -- | dryRun, reconcileExact, dotenv file, reviewed execution, optional review directory
    EnvSync StoreCommonOpts ScopeSelection Bool Bool FilePath Bool (Maybe FilePath)
  deriving stock (Generic, Show)

-- | The @secret@ subcommands. @SecretSet@'s value is read from stdin, never argv.
data SecretCommand
  = -- | dryRun, KEY (value from stdin), rotation version, reviewed plan directory
    SecretSet StoreCommonOpts ScopeSelection Bool String (Maybe String) (Maybe FilePath)
  | -- | Bool = --all
    SecretList StoreCommonOpts Bool
  | -- | dryRun, KEY, rotation version, reviewed plan directory
    SecretDelete StoreCommonOpts ScopeSelection Bool String (Maybe String) (Maybe FilePath)
  | -- | exact Runtime, Build, or Preview dotenv file, opaque rotation version, optional review directory
    SecretSync StoreCommonOpts ScopeSelection FilePath String (Maybe FilePath)
  deriving stock (Generic, Show)

-- | The @storage@ subcommands (EP-35). Both reuse 'StoreCommonOpts' (positional
-- APP + @-f@ config + @--ghc-env@); identity and the declared volume set come
-- from the loaded config. 'StorageInspect' adds a positional @VOLUME@. EP-36
-- extends this with a @StorageSnapshot@ constructor (Integration Point IP5).
data StorageCommand
  = StorageList StoreCommonOpts
  | -- | VOLUME
    StorageInspect StoreCommonOpts String
  | -- | VOLUME, --bucket, --expires-at, --snapshot-id, --save-plan, --dry-run
    StorageSnapshot StoreCommonOpts String (Maybe String) (Maybe String) (Maybe String) (Maybe FilePath) Bool
  | -- | VOLUME, BACKUP_ID, --bucket, --into-live, --dry-run, --restore-id, --save-plan
    StorageRestore StoreCommonOpts String String (Maybe String) Bool Bool (Maybe String) (Maybe FilePath)
  | -- | VOLUME, BACKUP_ID, --bucket, --save-plan
    StoragePrune StoreCommonOpts String String (Maybe String) FilePath
  deriving stock (Generic, Show)

-- | The @db@ subcommands (MasterPlan 9, EP-45, Integration Point IP4). One
-- constructor per subcommand. EP-47 extends this with @DbBackup@/@DbRestore@
-- constructors and the matching @command "backup"@/@command "restore"@ in the
-- subparser — extend, not fork.
data DbCommand
  = -- | nagarectl db list [-n NS]
    DbList DbListOpts
  | -- | nagarectl db create ENGINE NAME [flags]
    DbCreate Engine String DbCreateOpts
  | -- | nagarectl db rename ENGINE OLD NEW [--scope-key KEY] [create flags] --save-plan DIR
    DbRename Engine String String (Maybe String) DbCreateOpts
  | -- | nagarectl db get NAME [-n NS]
    DbGet DbNameOpts
  | -- | nagarectl db shell NAME [-n NS] [--session-id ID --recovery-backup ID --save-plan DIR]
    DbShell DbNameOpts (Maybe String) (Maybe String) (Maybe FilePath)
  | -- | nagarectl db restart NAME [-n NS] [--dry-run]
    DbRestart DbNameOpts Bool (Maybe FilePath)
  | -- | nagarectl db delete NAME [-n NS] --save-plan DIR
    DbDelete StandaloneRetireOpts
  | -- | nagarectl db retire NAME [-n NS] --save-plan DIR
    DbRetire StandaloneRetireOpts
  | -- | nagarectl db backup NAME [-n NS] [--bucket B] [--keep N] [--dry-run] (EP-47)
    DbBackup DbBackupOpts
  | DbPruneBackup DbPruneBackupOpts
  | DbPruneScheduledBackups DbPruneScheduledBackupsOpts
  | DbRecoverScheduledPrune DbRecoverScheduledPruneOpts
  | DbBackupReceipts DbBackupReceiptsOpts
  | DbManualReceipt DbBackupReceiptsOpts
  | -- | nagarectl db escrow-signing-key NAME [-n NS] [--output FILE] (MasterPlan 23 D1)
    DbEscrowSigningKey DbEscrowSigningKeyOpts
  | -- | nagarectl db verify-escrowed-backup NAME --backup-id JOB_UID [-n NS] [--escrow FILE] [--bucket B]
    DbVerifyEscrowedBackup DbVerifyEscrowedBackupOpts
  | -- | nagarectl db disable-backup-prune NAME [-n NS] --save-plan DIR
    DbDisableBackupPrune DbNameOpts FilePath
  | -- | nagarectl db restore NAME BACKUP_ID [--into live] [--dry-run] (EP-47)
    DbRestore DbRestoreOpts
  deriving stock (Generic, Show)

-- | The @broker@ subcommands (MasterPlan 15, EP-78).
data BrokerCommand
  = -- | nagarectl broker list [-n NS]
    BrokerList BrokerListOpts
  | -- | nagarectl broker create redpanda NAME [flags]
    BrokerCreate BrokerProvider String BrokerCreateOpts
  | -- | nagarectl broker get NAME [-n NS]
    BrokerGet BrokerNameOpts
  | -- | nagarectl broker restart NAME [-n NS] [--dry-run]
    BrokerRestart BrokerNameOpts Bool (Maybe FilePath)
  | -- | nagarectl broker delete NAME [-n NS] --save-plan DIR
    BrokerDelete StandaloneRetireOpts
  | -- | nagarectl broker retire NAME [-n NS] --save-plan DIR
    BrokerRetire StandaloneRetireOpts
  deriving stock (Generic, Show)

-- | The @task@ subcommands (MasterPlan 10, EP-51, Integration Point IP4). One
-- constructor per subcommand, mirroring 'DbCommand'. EP-52 may add app-scoping
-- flags but must extend, not fork, this group.
data TaskCommand
  = -- | nagarectl task list [APP] [-n NS]
    TaskList TaskListOpts
  | -- | nagarectl task run APP TASK [-n NS] [--dry-run]
    TaskRun TaskRunOpts
  | -- | nagarectl task logs APP TASK [-n NS] [--follow] [--tail N]
    TaskLogs TaskLogsOpts
  | -- | nagarectl task delete APP TASK [-n NS] [--yes] [--dry-run] [--save-plan DIR]
    TaskDelete TaskDeleteOpts
  deriving stock (Generic, Show)

-- | Options for @task list [APP]@: an optional positional APP (scopes by the
-- @nagare.dev/app@ label; @-@ means app-less) and a namespace.
data TaskListOpts = TaskListOpts
  { app :: !(Maybe String)
  , namespace :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | The positional APP + TASK plus a namespace, shared by run.
data TaskRunOpts = TaskRunOpts
  { app :: !String
  , task :: !String
  , namespace :: !(Maybe String)
  , dryRun :: !Bool
  , runId :: !(Maybe String)
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

data TaskLogsOpts = TaskLogsOpts
  { app :: !String
  , task :: !String
  , namespace :: !(Maybe String)
  , follow :: !Bool
  , tail :: !(Maybe Int)
  }
  deriving stock (Generic, Show)

data TaskDeleteOpts = TaskDeleteOpts
  { app :: !String
  , task :: !String
  , namespace :: !(Maybe String)
  , yes :: !Bool
  , dryRun :: !Bool
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | Options for @db list@: just a namespace (default @personal@).
newtype DbListOpts = DbListOpts {namespace :: Maybe String}
  deriving stock (Generic, Show)

-- | The positional NAME plus a namespace, shared by get/shell/restart.
data DbNameOpts = DbNameOpts
  { name :: !String
  , namespace :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | Options for @db create ENGINE NAME@. Engine and NAME are positionals on the
-- 'DbCreate' constructor, not in this record.
data DbCreateOpts = DbCreateOpts
  { namespace :: !(Maybe String)
  , systemNamespace :: !Bool
  , version :: !(Maybe String)
  , size :: !(Maybe String)
  , cpu :: !(Maybe String)
  , memory :: !(Maybe String)
  , config :: !(Maybe FilePath)
  , dryRun :: !Bool
  , savePlan :: !(Maybe FilePath)
  , recoveryBackup :: !(Maybe String)
  , recoveryKeyVersion :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | Retiring an accepted scope preserves its provider resources and records
-- their identities for later review and collection.
data StandaloneRetireOpts = StandaloneRetireOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , scopeKey :: !(Maybe String)
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)

-- | A reviewed backup has a stable ID and a saved review. Older contexts keep
-- the direct backup flags until the remaining data commands are migrated.
data DbBackupOpts = DbBackupOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , bucket :: !(Maybe String)
  , keep :: !(Maybe Int)
  , dryRun :: !Bool
  , backupId :: !(Maybe String)
  , expiresAt :: !(Maybe String)
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

data DbPruneBackupOpts = DbPruneBackupOpts
  { name :: !String
  , backupId :: !String
  , namespace :: !(Maybe String)
  , bucket :: !(Maybe String)
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)

data DbPruneScheduledBackupsOpts = DbPruneScheduledBackupsOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , bucket :: !(Maybe String)
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)

data DbRecoverScheduledPruneOpts = DbRecoverScheduledPruneOpts
  { name :: !String
  , backupId :: !String
  , namespace :: !(Maybe String)
  , bucket :: !(Maybe String)
  , failedReview :: !FilePath
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)

data DbBackupReceiptsOpts = DbBackupReceiptsOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , bucket :: !(Maybe String)
  , backupId :: !(Maybe String)
  , savePlan :: !(Maybe FilePath)
  , checkFreshness :: !Bool
  }
  deriving stock (Generic, Show)

data DbEscrowSigningKeyOpts = DbEscrowSigningKeyOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , output :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

data DbVerifyEscrowedBackupOpts = DbVerifyEscrowedBackupOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , backupId :: !String
  , escrow :: !(Maybe FilePath)
  , bucket :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | Options for @db restore NAME BACKUP_ID@ (EP-47): namespace, --bucket,
-- --into live (default scratch), --dry-run.
data DbRestoreOpts = DbRestoreOpts
  { name :: !String
  , backupId :: !String
  , namespace :: !(Maybe String)
  , bucket :: !(Maybe String)
  , live :: !Bool
  , dryRun :: !Bool
  , restoreId :: !(Maybe String)
  , recoveryBackup :: !(Maybe String)
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | Options for @broker list@: just a namespace (default @personal@).
newtype BrokerListOpts = BrokerListOpts {namespace :: Maybe String}
  deriving stock (Generic, Show)

-- | The positional NAME plus a namespace, shared by get/restart.
data BrokerNameOpts = BrokerNameOpts
  { name :: !String
  , namespace :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | Options for @broker create PROVIDER NAME@. Provider and NAME are positionals.
data BrokerCreateOpts = BrokerCreateOpts
  { namespace :: !(Maybe String)
  , version :: !(Maybe String)
  , size :: !(Maybe String)
  , cpu :: !(Maybe String)
  , memory :: !(Maybe String)
  , config :: !(Maybe FilePath)
  , dryRun :: !Bool
  , redpandaSmp :: !(Maybe Int)
  , redpandaMemory :: !(Maybe String)
  , topics :: ![String]
  , topicPartitions :: !(Maybe Int)
  , topicRetentionMs :: !(Maybe Int)
  , savePlan :: !(Maybe FilePath)
  , recoveryBackup :: !(Maybe String)
  , recoveryKey :: !(Maybe String)
  , recoveryKeyVersion :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | Options for @server status@ (MasterPlan 8, EP-38). @--skip-vm@ skips the
-- best-effort IAP-SSH disk probe (so the report needs no SSH setup).
data ServerStatusOpts = ServerStatusOpts
  { skipVm :: !Bool
  }
  deriving stock (Generic, Show)

-- | Options for @doctor@ (MasterPlan 8, EP-39). Reuses the same inventory knob
-- as @server status@: @--skip-vm@ skips the best-effort IAP-SSH disk probe.
data DoctorOpts = DoctorOpts
  { skipVm :: !Bool
  }
  deriving stock (Generic, Show)

data DomainsCommand
  = DomainsList DomainsListOpts
  | DomainsCheck DomainsListOpts
  deriving stock (Generic, Show)

-- | Options for @domains list@: namespace selection and an optional base-domain
-- override (matching the deploy path's @--base-domain@).
data DomainsListOpts = DomainsListOpts
  { namespace :: !(Maybe String)
  , allNamespaces :: !Bool
  , baseDomain :: !(Maybe String)
  , json :: !Bool
  }
  deriving stock (Generic, Show)

-- | MasterPlan 11 / EP-58: the @cdn@ command group. The constructor is named
-- 'CdnCmd' (not @Cdn@) to avoid clashing with the 'Cdn' type from
-- 'Nagare.Dsl.Cdn.Types', mirroring the 'Domains'/'DomainsCommand' split.
data CdnCommand
  = CdnList CdnListOpts
  | CdnStatus CdnStatusOpts
  | CdnPurge CdnPurgeOpts
  | CdnDisable CdnDisableOpts
  deriving stock (Generic, Show)

data CdnListOpts = CdnListOpts
  { namespace :: !(Maybe String)
  , allNamespaces :: !Bool
  , baseDomain :: !(Maybe String)
  }
  deriving stock (Generic, Show)

data CdnStatusOpts = CdnStatusOpts
  { host :: !String
  , namespace :: !(Maybe String)
  , baseDomain :: !(Maybe String)
  }
  deriving stock (Generic, Show)

data CdnPurgeOpts = CdnPurgeOpts
  { host :: !String
  , paths :: ![String]
  , namespace :: !(Maybe String)
  , dryRun :: !Bool
  , savePlan :: !(Maybe FilePath)
  , purgeId :: !(Maybe String)
  , wholeZone :: !Bool
  }
  deriving stock (Generic, Show)

data CdnDisableOpts = CdnDisableOpts
  { host :: !String
  , namespace :: !(Maybe String)
  , dryRun :: !Bool
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)
