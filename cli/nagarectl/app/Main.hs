-- | The @nagarectl@ deploy CLI entry point.
--
-- Command namespaces:
--
--   * @nagarectl deploy@ — the original app deploy of a typed
--     'Nagare.Dsl.Types.Deployment'.
--   * @nagarectl site deploy@ — the static-site deploy (EP-14): load a
--     'Nagare.Dsl.Static.Types.StaticSite', render the generated Nginx config and
--     Knative manifests, package the built output into a generated Nginx image,
--     push, apply, wait, record a release, and print the URL. Kind-dispatching by
--     design: a later plan (EP-18) routes a @ServerSite@ down a Node-image path
--     through the same command.
--   * @nagarectl site releases@ / @site rollback@ — release history and rollback
--     (EP-15), backed by a per-site ConfigMap.
--   * @nagarectl site preview deploy|list|delete@ — branch/PR previews as
--     separate Knative Services (EP-15).
--
-- A config that fails to load prints a one-line error to stderr and exits 1
-- before anything touches Docker or the cluster. @--dry-run@ prints the rendered
-- artifacts and URL without side effects.
module Main (main) where

import Control.Exception (bracket_)
import Control.Monad (forM, forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Access.Resolve (resolveDeploymentAccess)
import Nagare.App
  ( AppSummary (..)
  , LogTarget (..)
  , appDomains
  , deleteApp
  , formatAppList
  , getAppSummary
  , listAppSummaries
  , restartApp
  , stopApp
  , streamServiceLogs
  )
import Nagare.App.Deploy (AppDeployParams (..), runAppDeploy)
import Nagare.App.Deployments
  ( formatDeploymentsTable
  , readDeployments
  , recordDeploymentFor
  , resolveRevisionForTag
  )
import Nagare.Broker.Create (BrokerCreateParams (..), runBrokerCreate)
import Nagare.Broker.Delete (BrokerDeleteParams (..), runBrokerDelete)
import Nagare.Broker.Get (runBrokerGet)
import Nagare.Broker.List (runBrokerList)
import Nagare.Broker.Restart (runBrokerRestart)
import Nagare.Build (addBuildArgs, applyBuildOverrides, describeBuild, performBuild)
import Nagare.Cdn.Cloudflare (loadCloudflareCreds, purgeHostname)
import Nagare.Cdn.Provision
  ( CdnResult (..)
  , CdnTarget (..)
  , GcpStackRefs (..)
  , planCdn
  , provisionCdn
  , renderCdnPlan
  )
import Nagare.Cdn.Status (CdnDnsTarget (..), CdnRow (..), formatCdnList, formatCdnStatus, queryCdnRows)
import Nagare.Database.Backup (runDbBackup)
import Nagare.Database.Connection (connectionEnv, mergeConnectionEnvs)
import Nagare.Database.Create (DbCreateParams (..), runDbCreate)
import Nagare.Database.Delete (DbDeleteParams (..), runDbDelete)
import Nagare.Database.Discover (lookupConnection)
import Nagare.Database.Get (runDbGet)
import Nagare.Database.List (runDbList)
import Nagare.Database.Restart (runDbRestart)
import Nagare.Database.Restore (runDbRestore)
import Nagare.Database.Shell (runDbShell)
import Nagare.Deploy (applyManifests, applyPVCs, pvcPhases, serviceUrl, waitForReady)
import Nagare.Deploy.Resolve (resolveBrokerEnv, resolveBuildSpec, resolveConnectionEnv, resolveTag)
import Nagare.Dsl.Broker (BrokerProvider (..))
import Nagare.Dsl.Build (BuildSpec, requiresBuild, resolveImageTag)
import Nagare.Dsl.Cdn.Types (Cdn)
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (pvcName, renderDomainMappings, renderService, renderVolumeClaims, scopeToken)
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Render (StaticDeployContext (..))
import Nagare.Dsl.Static.Types (StaticSite, siteNameText)
import Nagare.Dsl.Types
  ( DatabaseName
  , Deployment
  , Domain
  , EnvName
  , EnvScope (..)
  , Namespace
  , ScopedEnvVar
  , databaseNameText
  , domainText
  , imageRefText
  , namespaceText
  , quantityText
  , serviceNameText
  , volumeNameText
  )
import Nagare.Env.BuildArgs (gatherBuildArgs, printBuildArgWarnings)
import Nagare.Env.Dotenv (parseDotenv)
import Nagare.Env.Generated (generatedEnv, mergeGenerated)
import Nagare.Env.Generated qualified as Gen
import Nagare.Env.Store
  ( ReconcileMode (..)
  , readEnvStore
  , readSecretStore
  , reconcile
  , renderEnvConfigMap
  , renderEnvSecret
  , writeEnvStore
  , writeSecretStore
  )
import Nagare.GhcEnv (resolveProjectGhcEnv)
import Nagare.Image
  ( computeTag
  , configureDockerAuth
  , imageRef
  , pushImage
  , qualifyImage
  )
import Nagare.Init
  ( InitOpts (..)
  , WriteResult (..)
  , enableApis
  , nextStepsText
  , profileFromOpts
  , renderTargetEnv
  , runPreflight
  , seedPulumiConfig
  , writeTargetEnv
  )
import Nagare.Ops.Cleanup
  ( CleanupOpts (..)
  , defaultKeepReleases
  , defaultPreviewTtlDays
  , executeCleanup
  , formatCleanupReport
  )
import Nagare.Ops.Doctor (doctorExitOk, formatDoctor, gradeChecks)
import Nagare.Ops.Domains
  ( CertState (..)
  , DnsExpectation (..)
  , DomainRow (..)
  , formatDomainList
  , listNamespaces
  , queryDomainRows
  )
import Nagare.Ops.Probe (InventoryOpts (..), captureTool, renderInventory)
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Ops.Status (gatherInventory, inventoryOptsFor)
import Nagare.Server.Deploy
  ( ServerDeployInputs (..)
  , ServerManifests (..)
  , deployServerProduction
  , serverManifests
  , serverUrl
  )
import Nagare.Static.Deploy
  ( DeployInputs (..)
  , StaticManifests (..)
  , deployStaticPreview
  , deployStaticProduction
  , previewManifests
  , productionManifests
  )
import Nagare.Static.Preview (deletePreview, listPreviews, previewDomain, previewServiceName)
import Nagare.Static.Release
  ( StaticReleaseLog (..)
  , findRelease
  , formatReleasesTable
  , readReleaseLog
  , writeReleaseLog
  )
import Nagare.Storage.Inspect (runStorageInspect)
import Nagare.Storage.List (runStorageList)
import Nagare.Storage.Restore (runStorageRestore)
import Nagare.Storage.Snapshot (backupExcludedWarnings, runSnapshot)
import Nagare.Target (TargetProfile (..), resolveTargetProfile)
import Nagare.Task.Delete (TaskDeleteParams (..), runTaskDelete)
import Nagare.Task.Discover (AppScope (..))
import Nagare.Task.List (runTaskList)
import Nagare.Task.Logs (TaskLogTarget (..), runTaskLogs)
import Nagare.Task.Resolve (predefinedTaskEnv, renderResolvedTask)
import Nagare.Task.Run (TaskRunParams (..), runTaskRun)
import Nagare.Worker.Deploy (WorkerDeployParams (..), runWorkerDeploy)
import Options.Applicative
import System.Directory (doesFileExist, makeAbsolute)
import System.Environment (lookupEnv, setEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitFailure, exitWith)
import System.IO (hFlush, hIsTerminalDevice, hSetEcho, stderr, stdin, stdout)
import "generic-lens" Data.Generics.Labels ()

-- ---------------------------------------------------------------------------
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
  }
  deriving stock (Generic, Show)

-- | The @worker@ command group (EP-71). One subcommand today (@deploy@); a
-- 'newtype' with a constructor per subcommand, mirroring 'DbCommand'/'TaskCommand'.
newtype WorkerCommand = WorkerDeploy WorkerDeployOpts
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

-- | Options for @app list@: a namespace (default @personal@) and @--all@ to drop
-- the Nagare-managed label filter (EP-30).
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

-- | Options for @app delete@: like 'AppNameOpts' plus an optional @--file@ config
-- whose declared domains are deleted (falling back to a cluster query).
data AppDeleteOpts = AppDeleteOpts
  { nameArg :: !String
  , namespace :: !(Maybe String)
  , file :: !FilePath
  , ghcEnv :: !(Maybe FilePath)
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
  = Deploy DeployOpts
  | SiteDeploy SiteDeployOpts
  | SiteReleases SiteCommonOpts
  | SiteRollback SiteCommonOpts String
  | SitePreviewDeploy SiteDeployOpts String
  | SitePreviewList SiteCommonOpts
  | SitePreviewDelete SiteCommonOpts String
  | Env EnvCommand
  | Secret SecretCommand
  | AppList AppListOpts
  | AppGet AppGetOpts
  | AppLogs AppLogsOpts
  | AppRestart AppNameOpts
  | AppStop AppNameOpts
  | AppDelete AppDeleteOpts
  | AppDeploy AppDeployOpts
  | DeploymentsList DepListOpts
  | DeploymentsLogs DepLogsOpts
  | Storage StorageCommand
  | Broker BrokerCommand
  | Db DbCommand
  | Task TaskCommand
  | Worker WorkerCommand
  | ServerStatus ServerStatusOpts
  | Doctor DoctorOpts
  | Init InitOpts
  | Domains DomainsCommand
  | CdnCmd CdnCommand
  | Cleanup CleanupOpts

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
  | -- | dryRun, KEY, VALUE
    EnvSet StoreCommonOpts ScopeSelection Bool String String
  | -- | dryRun, KEY
    EnvDelete StoreCommonOpts ScopeSelection Bool String
  | -- | dryRun, reconcileExact, dotenv file
    EnvSync StoreCommonOpts ScopeSelection Bool Bool FilePath

-- | The @secret@ subcommands. @SecretSet@'s value is read from stdin, never argv.
data SecretCommand
  = -- | dryRun, KEY (value from stdin)
    SecretSet StoreCommonOpts ScopeSelection Bool String
  | -- | Bool = --all
    SecretList StoreCommonOpts Bool
  | -- | dryRun, KEY
    SecretDelete StoreCommonOpts ScopeSelection Bool String

-- | The @storage@ subcommands (EP-35). Both reuse 'StoreCommonOpts' (positional
-- APP + @-f@ config + @--ghc-env@); identity and the declared volume set come
-- from the loaded config. 'StorageInspect' adds a positional @VOLUME@. EP-36
-- extends this with a @StorageSnapshot@ constructor (Integration Point IP5).
data StorageCommand
  = StorageList StoreCommonOpts
  | -- | VOLUME
    StorageInspect StoreCommonOpts String
  | -- | VOLUME, --bucket, --keep (EP-36)
    StorageSnapshot StoreCommonOpts String (Maybe String) Int
  | -- | VOLUME, BACKUP_ID, --bucket, --into-live, --dry-run (EP-1)
    StorageRestore StoreCommonOpts String String (Maybe String) Bool Bool

-- | The @db@ subcommands (MasterPlan 9, EP-45, Integration Point IP4). One
-- constructor per subcommand. EP-47 extends this with @DbBackup@/@DbRestore@
-- constructors and the matching @command "backup"@/@command "restore"@ in the
-- subparser — extend, not fork.
data DbCommand
  = -- | nagarectl db list [-n NS]
    DbList DbListOpts
  | -- | nagarectl db create ENGINE NAME [flags]
    DbCreate Engine String DbCreateOpts
  | -- | nagarectl db get NAME [-n NS]
    DbGet DbNameOpts
  | -- | nagarectl db shell NAME [-n NS]
    DbShell DbNameOpts
  | -- | nagarectl db restart NAME [-n NS] [--dry-run]
    DbRestart DbNameOpts Bool
  | -- | nagarectl db delete NAME [-n NS] [--yes] [--dry-run]
    DbDelete DbDeleteOpts
  | -- | nagarectl db backup NAME [-n NS] [--bucket B] [--keep N] [--dry-run] (EP-47)
    DbBackup DbBackupOpts
  | -- | nagarectl db restore NAME BACKUP_ID [--into live] [--dry-run] (EP-47)
    DbRestore DbRestoreOpts

-- | The @broker@ subcommands (MasterPlan 15, EP-78).
data BrokerCommand
  = -- | nagarectl broker list [-n NS]
    BrokerList BrokerListOpts
  | -- | nagarectl broker create redpanda NAME [flags]
    BrokerCreate BrokerProvider String BrokerCreateOpts
  | -- | nagarectl broker get NAME [-n NS]
    BrokerGet BrokerNameOpts
  | -- | nagarectl broker restart NAME [-n NS] [--dry-run]
    BrokerRestart BrokerNameOpts Bool
  | -- | nagarectl broker delete NAME [-n NS] [--yes] [--dry-run]
    BrokerDelete BrokerDeleteOpts

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
  | -- | nagarectl task delete APP TASK [-n NS] [--yes] [--dry-run]
    TaskDelete TaskDeleteOpts

-- | Options for @task list [APP]@: an optional positional APP (scopes by the
-- @nagare.dev/app@ label; @-@ means app-less) and a namespace.
data TaskListOpts = TaskListOpts
  { tlsApp :: !(Maybe String)
  , tlsNamespace :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | The positional APP + TASK plus a namespace, shared by run.
data TaskRunOpts = TaskRunOpts
  { troApp :: !String
  , troTask :: !String
  , troNamespace :: !(Maybe String)
  , troDryRun :: !Bool
  }
  deriving stock (Generic, Show)

data TaskLogsOpts = TaskLogsOpts
  { tlgApp :: !String
  , tlgTask :: !String
  , tlgNamespace :: !(Maybe String)
  , tlgFollow :: !Bool
  , tlgTail :: !(Maybe Int)
  }
  deriving stock (Generic, Show)

data TaskDeleteOpts = TaskDeleteOpts
  { tdoApp :: !String
  , tdoTask :: !String
  , tdoNamespace :: !(Maybe String)
  , tdoYes :: !Bool
  , tdoDryRun :: !Bool
  }
  deriving stock (Generic, Show)

-- | Options for @db list@: just a namespace (default @personal@).
newtype DbListOpts = DbListOpts {dbloNamespace :: Maybe String}
  deriving stock (Generic, Show)

-- | The positional NAME plus a namespace, shared by get/shell/restart.
data DbNameOpts = DbNameOpts
  { dbnName :: !String
  , dbnNamespace :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | Options for @db create ENGINE NAME@. Engine and NAME are positionals on the
-- 'DbCreate' constructor, not in this record.
data DbCreateOpts = DbCreateOpts
  { dbcNamespace :: !(Maybe String)
  , dbcVersion :: !(Maybe String)
  , dbcSize :: !(Maybe String)
  , dbcCpu :: !(Maybe String)
  , dbcMemory :: !(Maybe String)
  , dbcConfig :: !(Maybe FilePath)
  , dbcDryRun :: !Bool
  }
  deriving stock (Generic, Show)

-- | Options for @db delete NAME@: namespace, the --yes guard, and --dry-run.
data DbDeleteOpts = DbDeleteOpts
  { dbdName :: !String
  , dbdNamespace :: !(Maybe String)
  , dbdYes :: !Bool
  , dbdDryRun :: !Bool
  }
  deriving stock (Generic, Show)

-- | Options for @db backup NAME@ (EP-47): namespace, --bucket, --keep, --dry-run.
data DbBackupOpts = DbBackupOpts
  { dbbName :: !String
  , dbbNamespace :: !(Maybe String)
  , dbbBucket :: !(Maybe String)
  , dbbKeep :: !Int
  , dbbDryRun :: !Bool
  }
  deriving stock (Generic, Show)

-- | Options for @db restore NAME BACKUP_ID@ (EP-47): namespace, --bucket,
-- --into live (default scratch), --dry-run.
data DbRestoreOpts = DbRestoreOpts
  { dbrName :: !String
  , dbrBackupId :: !String
  , dbrNamespace :: !(Maybe String)
  , dbrBucket :: !(Maybe String)
  , dbrLive :: !Bool
  , dbrDryRun :: !Bool
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
  }
  deriving stock (Generic, Show)

-- | Options for @broker delete NAME@: namespace, the --yes guard, and --dry-run.
data BrokerDeleteOpts = BrokerDeleteOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , yes :: !Bool
  , dryRun :: !Bool
  }
  deriving stock (Generic, Show)

-- | Options for @server status@ (MasterPlan 8, EP-38). @--skip-vm@ skips the
-- best-effort IAP-SSH disk probe (so the report needs no SSH setup).
data ServerStatusOpts = ServerStatusOpts
  { ssSkipVm :: !Bool
  }
  deriving stock (Generic, Show)

serverStatusOptsParser :: Parser ServerStatusOpts
serverStatusOptsParser =
  ServerStatusOpts
    <$> switch (long "skip-vm" <> help "Skip the IAP-SSH disk probe (no SSH setup needed)")

-- | Options for @doctor@ (MasterPlan 8, EP-39). Reuses the same inventory knob
-- as @server status@: @--skip-vm@ skips the best-effort IAP-SSH disk probe.
data DoctorOpts = DoctorOpts
  { dSkipVm :: !Bool
  }
  deriving stock (Generic, Show)

doctorOptsParser :: Parser DoctorOpts
doctorOptsParser =
  DoctorOpts
    <$> switch (long "skip-vm" <> help "Skip the IAP-SSH disk probe (no SSH setup needed)")

-- | Options for @init@ (MasterPlan 12, EP-63). The four target flags are optional
-- so an absent flag prompts on a TTY (or errors non-interactively); the skip/force
-- flags exist for CI and partial recovery.
initOptsParser :: Parser InitOpts
initOptsParser =
  InitOpts
    <$> optional (strOption (long "project" <> metavar "PROJECT_ID" <> help "GCP project id (prompted if absent on a TTY)"))
    <*> optional (strOption (long "region" <> metavar "REGION" <> help "Compute region (default us-west1)"))
    <*> optional (strOption (long "zone" <> metavar "ZONE" <> help "Compute zone (default us-west1-a)"))
    <*> optional (strOption (long "base-domain" <> metavar "DOMAIN" <> help "Apps base domain (default apps.example.com)"))
    <*> switch (long "force" <> help "Overwrite an existing nagare.target.env")
    <*> switch (long "skip-preflight" <> help "Skip the gcloud auth + operator-IAM checks")
    <*> switch (long "skip-enable" <> help "Skip running scripts/enable-apis.sh")
    <*> switch (long "skip-seed" <> help "Skip seeding the Pulumi stack config")
    <*> switch (long "dry-run" <> help "Show what would be written/enabled/seeded without doing it")

-- | The @domains@ group (MasterPlan 8, EP-40). Only @list@ exists today; the
-- group leaves room for future @domains add@/@remove@.
newtype DomainsCommand = DomainsList DomainsListOpts

-- | Options for @domains list@: namespace selection and an optional base-domain
-- override (matching the deploy path's @--base-domain@).
data DomainsListOpts = DomainsListOpts
  { dloNamespace :: !(Maybe String)
  , dloAllNamespaces :: !Bool
  , dloBaseDomain :: !(Maybe String)
  }
  deriving stock (Generic, Show)

domainsListOptsParser :: Parser DomainsListOpts
domainsListOptsParser =
  DomainsListOpts
    <$> namespaceOpt
    <*> switch (long "all-namespaces" <> help "List domains across all namespaces")
    <*> baseDomainOpt

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
  { cloNamespace :: !(Maybe String)
  , cloAllNamespaces :: !Bool
  , cloBaseDomain :: !(Maybe String)
  }
  deriving stock (Generic, Show)

data CdnStatusOpts = CdnStatusOpts
  { csoHost :: !String
  , csoNamespace :: !(Maybe String)
  , csoBaseDomain :: !(Maybe String)
  }
  deriving stock (Generic, Show)

data CdnPurgeOpts = CdnPurgeOpts
  { cpoHost :: !String
  , cpoPaths :: ![String]
  , cpoNamespace :: !(Maybe String)
  , cpoDryRun :: !Bool
  }
  deriving stock (Generic, Show)

data CdnDisableOpts = CdnDisableOpts
  { cdoHost :: !String
  , cdoNamespace :: !(Maybe String)
  , cdoDryRun :: !Bool
  }
  deriving stock (Generic, Show)

cdnHostArg :: Parser String
cdnHostArg = strArgument (metavar "HOST" <> help "CDN-fronted hostname (e.g. blog.example.com)")

cdnListOptsParser :: Parser CdnListOpts
cdnListOptsParser =
  CdnListOpts
    <$> namespaceOpt
    <*> switch (long "all-namespaces" <> help "List CDN-fronted hostnames across all namespaces")
    <*> baseDomainOpt

cdnStatusOptsParser :: Parser CdnStatusOpts
cdnStatusOptsParser =
  CdnStatusOpts <$> cdnHostArg <*> namespaceOpt <*> baseDomainOpt

cdnPurgeOptsParser :: Parser CdnPurgeOpts
cdnPurgeOptsParser =
  CdnPurgeOpts
    <$> cdnHostArg
    <*> many
      ( strOption
          (long "path" <> metavar "PATH" <> help "Purge only this path (repeatable; default: purge everything)")
      )
    <*> namespaceOpt
    <*> dryRunOpt

cdnDisableOptsParser :: Parser CdnDisableOpts
cdnDisableOptsParser =
  CdnDisableOpts <$> cdnHostArg <*> namespaceOpt <*> dryRunOpt

-- | Options for @cleanup@ (MasterPlan 8, EP-41). @--confirm@ defaults 'False', so
-- a plain run is the dry run; when none of @--images/--previews/--releases@ is
-- given, all three categories are acted on.
cleanupOptsParser :: Parser CleanupOpts
cleanupOptsParser =
  CleanupOpts
    <$> switch (long "images" <> help "Limit cleanup to the containerd image store")
    <*> switch (long "previews" <> help "Limit cleanup to stale static-site previews")
    <*> switch (long "releases" <> help "Limit cleanup to old release-history entries")
    <*> switch (long "confirm" <> help "REQUIRED to delete; without it cleanup is a dry run")
    <*> option
      auto
      (long "preview-ttl-days" <> value defaultPreviewTtlDays <> showDefault <> metavar "N" <> help "Previews older than N days are stale")
    <*> option
      auto
      (long "keep-releases" <> value defaultKeepReleases <> showDefault <> metavar "N" <> help "Keep the most recent N releases per log (current always kept)")
    <*> optional (T.pack <$> strOption (long "namespace" <> short 'n' <> metavar "NS" <> help "Namespace to scan for previews/releases"))

-- Reusable option fragments shared across the subcommands.

fileOpt :: FilePath -> Parser FilePath
fileOpt defaultFile =
  strOption
    ( long "file"
        <> short 'f'
        <> metavar "FILE"
        <> value defaultFile
        <> showDefault
        <> help "Path to the typed config file"
    )

tagOpt :: Parser (Maybe String)
tagOpt =
  optional
    ( strOption
        ( long "tag"
            <> short 't'
            <> metavar "TAG"
            <> help "Image tag override (default: UTC timestamp YYYYMMDD-HHMMSS)"
        )
    )

baseDomainOpt :: Parser (Maybe String)
baseDomainOpt =
  optional
    ( strOption
        ( long "base-domain"
            <> metavar "DOMAIN"
            <> help "Apps base domain (overrides NAGARE_BASE_DOMAIN, default apps.example.com)"
        )
    )

ghcEnvOpt :: Parser (Maybe FilePath)
ghcEnvOpt =
  optional
    ( strOption
        ( long "ghc-env"
            <> metavar "FILE"
            <> help "GHC package-environment file for the config loader's runghc (overrides NAGARE_GHC_ENVIRONMENT)"
        )
    )

dryRunOpt :: Parser Bool
dryRunOpt =
  switch
    ( long "dry-run"
        <> help "Print rendered artifacts and URL without building, pushing, or applying"
    )

deployOptsParser :: FilePath -> Parser DeployOpts
deployOptsParser defaultFile =
  DeployOpts
    <$> fileOpt defaultFile
    <*> tagOpt
    <*> baseDomainOpt
    <*> optional
      ( strOption
          ( long "context"
              <> short 'c'
              <> metavar "DIR"
              <> help "Override the build context directory from the config (build modes only)"
          )
      )
    <*> optional
      ( strOption
          ( long "dockerfile"
              <> metavar "FILE"
              <> help "Override the Dockerfile path from the config (Dockerfile build only)"
          )
      )
    <*> ghcEnvOpt
    <*> dryRunOpt
    <*> optional
      ( strOption
          ( long "source"
              <> metavar "REF"
              <> help "Provenance to record with the deployment (e.g. a git SHA or branch)"
          )
      )

appDeployOptsParser :: FilePath -> Parser AppDeployOpts
appDeployOptsParser defaultFile =
  AppDeployOpts
    <$> fileOpt defaultFile
    <*> tagOpt
    <*> baseDomainOpt
    <*> optional
      ( strOption
          ( long "context"
              <> short 'c'
              <> metavar "DIR"
              <> help "Override the build context directory from the config (build modes only)"
          )
      )
    <*> optional
      ( strOption
          ( long "dockerfile"
              <> metavar "FILE"
              <> help "Override the Dockerfile path from the config (Dockerfile build only)"
          )
      )
    <*> ghcEnvOpt
    <*> dryRunOpt
    <*> switch
      ( long "json"
          <> help "With --dry-run, emit the rollout plan as a single JSON document (for tooling/kotei)"
      )
    <*> optional
      ( strOption
          ( long "source"
              <> metavar "REF"
              <> help "Provenance to record with the deployment (e.g. a git SHA or branch)"
          )
      )

workerDeployOptsParser :: FilePath -> Parser WorkerDeployOpts
workerDeployOptsParser defaultFile =
  WorkerDeployOpts
    <$> fileOpt defaultFile
    <*> tagOpt
    <*> optional
      ( strOption
          ( long "context"
              <> short 'c'
              <> metavar "DIR"
              <> help "Override the build context directory from the config (build modes only)"
          )
      )
    <*> optional
      ( strOption
          ( long "dockerfile"
              <> metavar "FILE"
              <> help "Override the Dockerfile path from the config (Dockerfile build only)"
          )
      )
    <*> ghcEnvOpt
    <*> dryRunOpt

siteDeployOptsParser :: FilePath -> Parser SiteDeployOpts
siteDeployOptsParser defaultFile =
  SiteDeployOpts
    <$> fileOpt defaultFile
    <*> tagOpt
    <*> baseDomainOpt
    <*> strOption
      ( long "project-dir"
          <> short 'C'
          <> metavar "DIR"
          <> value "."
          <> showDefault
          <> help "Project root: where the build runs and the output directory is resolved"
      )
    <*> ghcEnvOpt
    <*> dryRunOpt
    <*> switch
      ( long "skip-build"
          <> help "Do not run the build command; package the existing output directory as-is"
      )
    <*> optional
      ( strOption
          ( long "source"
              <> metavar "REF"
              <> help "Provenance to record with the release (e.g. a git SHA or branch)"
          )
      )

siteCommonOptsParser :: FilePath -> Parser SiteCommonOpts
siteCommonOptsParser defaultFile =
  SiteCommonOpts <$> fileOpt defaultFile <*> baseDomainOpt <*> ghcEnvOpt

-- App lifecycle option fragments (EP-30).

-- | @-n/--namespace@ for the @app@ commands; 'Nothing' means @personal@.
namespaceOpt :: Parser (Maybe String)
namespaceOpt =
  optional
    ( strOption
        ( long "namespace"
            <> short 'n'
            <> metavar "NS"
            <> help "Kubernetes namespace (default: personal)"
        )
    )

-- | The positional @NAME@ (Knative Service name) every @app NAME@ command takes.
appNameArg :: Parser String
appNameArg = strArgument (metavar "NAME" <> help "App (Knative Service) name")

appListOptsParser :: Parser AppListOpts
appListOptsParser =
  AppListOpts
    <$> namespaceOpt
    <*> switch (long "all" <> help "List every Knative Service, not only Nagare-managed apps")

appGetOptsParser :: Parser AppGetOpts
appGetOptsParser =
  AppGetOpts
    <$> appNameArg
    <*> namespaceOpt
    <*> fileOpt defaultConfigFile
    <*> ghcEnvOpt

appLogsOptsParser :: Parser AppLogsOpts
appLogsOptsParser =
  AppLogsOpts
    <$> appNameArg
    <*> namespaceOpt
    <*> switch (long "follow" <> help "Stream logs until interrupted")
    <*> optional
      ( option
          auto
          ( long "tail"
              <> metavar "N"
              <> help "Lines of recent logs to show (default: 200; ignored with --follow)"
          )
      )

appNameOptsParser :: Parser AppNameOpts
appNameOptsParser = AppNameOpts <$> appNameArg <*> namespaceOpt

appDeleteOptsParser :: Parser AppDeleteOpts
appDeleteOptsParser =
  AppDeleteOpts
    <$> appNameArg
    <*> namespaceOpt
    <*> fileOpt defaultConfigFile
    <*> ghcEnvOpt

depListOptsParser :: Parser DepListOpts
depListOptsParser = DepListOpts <$> appNameArg <*> namespaceOpt

depLogsOptsParser :: Parser DepLogsOpts
depLogsOptsParser =
  DepLogsOpts
    <$> appNameArg
    <*> optional (strArgument (metavar "DEPLOYMENT_ID" <> help "A past deployment id (image tag); omit for the live deployment"))
    <*> namespaceOpt
    <*> switch (long "follow" <> help "Stream logs until interrupted")
    <*> optional
      ( option
          auto
          ( long "tail"
              <> metavar "N"
              <> help "Lines of recent logs to show (default: 200; ignored with --follow)"
          )
      )

previewNameOpt :: Parser String
previewNameOpt =
  strOption
    ( long "name"
        <> short 'n'
        <> metavar "NAME"
        <> help "Preview name (branch or PR identifier)"
    )

-- | The default config filename for the chosen substrate (EP-8).
defaultConfigFile :: FilePath
defaultConfigFile = "nagare/Config.hs"

-- Env / secret option fragments (EP-25).

appArg :: Parser String
appArg = strArgument (metavar "APP" <> help "App whose env/secret store to manage")

-- | The config-file option for @env@/@secret@: @-f/--config@ (not @--file@), so
-- @env sync@'s dotenv argument can use the @--file@ long name.
configFileOpt :: Parser FilePath
configFileOpt =
  strOption
    ( long "config"
        <> short 'f'
        <> metavar "FILE"
        <> value defaultConfigFile
        <> showDefault
        <> help "Typed config file; its name/namespace identify the app"
    )

storeCommonOptsParser :: Parser StoreCommonOpts
storeCommonOptsParser =
  StoreCommonOpts <$> appArg <*> configFileOpt <*> ghcEnvOpt

-- Managed-database option fragments (MasterPlan 9, EP-45).

-- | Parse the positional ENGINE argument into the typed 'Engine'.
engineReader :: ReadM Engine
engineReader = eitherReader $ \case
  "postgres" -> Right Postgres
  "redis" -> Right Redis
  "clickhouse" -> Right ClickHouse
  other -> Left ("unknown engine '" <> other <> "' (expected postgres | redis | clickhouse)")

dbNameArg :: Parser String
dbNameArg = strArgument (metavar "NAME" <> help "Managed database name (DNS label)")

brokerProviderReader :: ReadM BrokerProvider
brokerProviderReader = eitherReader $ \case
  "redpanda" -> Right Redpanda
  "tansu" -> Left "Tansu is reserved but not implemented yet; use redpanda"
  other -> Left ("unknown broker provider '" <> other <> "' (expected redpanda)")

brokerNameArg :: Parser String
brokerNameArg = strArgument (metavar "NAME" <> help "Broker name (DNS label)")

-- Scheduled-task option fragments (MasterPlan 10, EP-51).

-- | The positional TASK argument every @task ... TASK@ command takes.
taskNameArg :: Parser String
taskNameArg = strArgument (metavar "TASK" <> help "Scheduled task name (DNS label)")

-- | The positional APP argument: scopes by the @nagare.dev/app@ label. @-@ means
-- "tasks with no app association".
taskAppArg :: Parser String
taskAppArg = strArgument (metavar "APP" <> help "Owning app (or - for app-less tasks)")

taskListOptsParser :: Parser TaskListOpts
taskListOptsParser =
  TaskListOpts
    <$> optional (strArgument (metavar "APP" <> help "Owning app to scope to (or - for app-less; omit for all)"))
    <*> namespaceOpt

taskRunOptsParser :: Parser TaskRunOpts
taskRunOptsParser =
  TaskRunOpts <$> taskAppArg <*> taskNameArg <*> namespaceOpt <*> dryRunOpt

taskLogsOptsParser :: Parser TaskLogsOpts
taskLogsOptsParser =
  TaskLogsOpts
    <$> taskAppArg
    <*> taskNameArg
    <*> namespaceOpt
    <*> switch (long "follow" <> help "Stream logs until interrupted")
    <*> optional (option auto (long "tail" <> metavar "N" <> help "Show only the last N lines"))

taskDeleteOptsParser :: Parser TaskDeleteOpts
taskDeleteOptsParser =
  TaskDeleteOpts
    <$> taskAppArg
    <*> taskNameArg
    <*> namespaceOpt
    <*> switch (long "yes" <> help "Confirm deletion (without it, prints the plan and deletes nothing)")
    <*> dryRunOpt

dbListOptsParser :: Parser DbListOpts
dbListOptsParser = DbListOpts <$> namespaceOpt

dbNameOptsParser :: Parser DbNameOpts
dbNameOptsParser = DbNameOpts <$> dbNameArg <*> namespaceOpt

dbCreateOptsParser :: Parser DbCreateOpts
dbCreateOptsParser =
  DbCreateOpts
    <$> namespaceOpt
    <*> optional (strOption (long "version" <> metavar "TAG" <> help "Pinned engine image tag (per-engine default if absent)"))
    <*> optional (strOption (long "size" <> metavar "QTY" <> help "Data volume size (default 10Gi, redis 2Gi)"))
    <*> optional (strOption (long "cpu" <> metavar "QTY" <> help "CPU limit (e.g. 500m)"))
    <*> optional (strOption (long "memory" <> metavar "QTY" <> help "Memory limit (e.g. 1Gi)"))
    <*> optional (strOption (long "config" <> metavar "FILE" <> help "Load a typed Database from a Config.hs instead of building from flags"))
    <*> dryRunOpt

dbDeleteOptsParser :: Parser DbDeleteOpts
dbDeleteOptsParser =
  DbDeleteOpts
    <$> dbNameArg
    <*> namespaceOpt
    <*> switch (long "yes" <> help "Confirm deletion (without it, prints the plan and deletes nothing)")
    <*> dryRunOpt

brokerListOptsParser :: Parser BrokerListOpts
brokerListOptsParser = BrokerListOpts <$> namespaceOpt

brokerNameOptsParser :: Parser BrokerNameOpts
brokerNameOptsParser = BrokerNameOpts <$> brokerNameArg <*> namespaceOpt

brokerCreateOptsParser :: Parser BrokerCreateOpts
brokerCreateOptsParser =
  BrokerCreateOpts
    <$> namespaceOpt
    <*> optional (strOption (long "version" <> metavar "TAG" <> help "Pinned provider image tag (provider default if absent)"))
    <*> optional (strOption (long "size" <> metavar "QTY" <> help "Data volume size (default 5Gi)"))
    <*> optional (strOption (long "cpu" <> metavar "QTY" <> help "CPU limit (e.g. 1)"))
    <*> optional (strOption (long "memory" <> metavar "QTY" <> help "Memory limit (e.g. 1536Mi)"))
    <*> optional (strOption (long "config" <> metavar "FILE" <> help "Load a typed Broker from a Config.hs instead of building from flags"))
    <*> dryRunOpt
    <*> optional (option auto (long "redpanda-smp" <> metavar "N" <> help "Redpanda core count / --smp"))
    <*> optional (strOption (long "redpanda-memory" <> metavar "QTY" <> help "Redpanda process memory (e.g. 1G)"))
    <*> many (strOption (long "topic" <> metavar "TOPIC" <> help "Topic to create; repeat for multiple topics"))
    <*> optional (option auto (long "topic-partitions" <> metavar "N" <> help "Partitions for topics declared with --topic"))
    <*> optional (option auto (long "topic-retention-ms" <> metavar "MS" <> help "retention.ms for topics declared with --topic"))

brokerDeleteOptsParser :: Parser BrokerDeleteOpts
brokerDeleteOptsParser =
  BrokerDeleteOpts
    <$> brokerNameArg
    <*> namespaceOpt
    <*> switch (long "yes" <> help "Confirm deletion (without it, prints the plan and deletes nothing)")
    <*> dryRunOpt

dbBackupBucketOpt :: Parser (Maybe String)
dbBackupBucketOpt =
  optional
    ( strOption
        ( long "bucket"
            <> metavar "BUCKET"
            <> help "GCS backup bucket (overrides the target profile NAGARE_BACKUP_BUCKET / <project>-nagare-backups)"
        )
    )

dbBackupOptsParser :: Parser DbBackupOpts
dbBackupOptsParser =
  DbBackupOpts
    <$> dbNameArg
    <*> namespaceOpt
    <*> dbBackupBucketOpt
    <*> option auto (long "keep" <> metavar "N" <> value 7 <> showDefault <> help "Backups to keep per database (older are pruned)")
    <*> dryRunOpt

dbRestoreOptsParser :: Parser DbRestoreOpts
dbRestoreOptsParser =
  DbRestoreOpts
    <$> dbNameArg
    <*> strArgument (metavar "BACKUP_ID" <> help "Backup timestamp (or full gs:// URL) to restore")
    <*> namespaceOpt
    <*> dbBackupBucketOpt
    <*> switch (long "into-live" <> help "Restore into the LIVE database (default: a scratch target)")
    <*> dryRunOpt

scopeSelectionParser :: Parser ScopeSelection
scopeSelectionParser =
  ScopeSelection
    <$> switch (long "runtime" <> help "Target the runtime scope (default if no scope flag is given)")
    <*> switch (long "build" <> help "Target the build scope")
    <*> switch (long "preview" <> help "Target the preview scope")

-- | Resolve the selected scopes; with none chosen, default to @[Runtime]@.
selectedScopes :: ScopeSelection -> [EnvScope]
selectedScopes (ScopeSelection r b p)
  | not r && not b && not p = [Runtime]
  | otherwise = [Runtime | r] <> [Build | b] <> [Preview | p]

-- | @--reconcile-exact@ => 'True', @--merge@ (or default) => 'False'. The two
-- flags are mutually exclusive.
reconcileExactParser :: Parser Bool
reconcileExactParser =
  flag' True (long "reconcile-exact" <> help "Make the store exactly the file (drop keys not present)")
    <|> flag' False (long "merge" <> help "Keep existing keys not in the file (default)")
    <|> pure False

-- | The reconcile mode for a sync.
reconcileModeFrom :: Bool -> ReconcileMode
reconcileModeFrom True = ReconcileExact
reconcileModeFrom False = Merge

opts :: ParserInfo Command
opts =
  info
    (commandParser <**> helper)
    ( fullDesc
        <> progDesc "nagarectl — deploy a typed Nagare app or static site to Knative"
    )
  where
    commandParser =
      subparser
        ( command "deploy" deployCmd
            <> command "site" siteCmd
            <> command "env" envCmd
            <> command "secret" secretCmd
            <> command "app" appCmd
            <> command "deployments" deploymentsCmd
            <> command "storage" storageCmd
            <> command "broker" brokerCmd
            <> command "db" dbCmd
            <> command "task" taskCmd
            <> command "worker" workerCmd
            <> command "server" serverCmd
            <> command "doctor" doctorCmd
            <> command "init" initCmd
            <> command "domains" domainsCmd
            <> command "cdn" cdnCmd
            <> command "cleanup" cleanupCmd
        )
    doctorCmd =
      info
        (Doctor <$> doctorOptsParser <**> helper)
        (fullDesc <> progDesc "Health-check the platform and print remediation hints (exit 1 on any FAIL)")
    initCmd =
      info
        (Init <$> initOptsParser <**> helper)
        (fullDesc <> progDesc "Onboard a fresh GCP project: preflight, write the target profile, enable APIs, seed Pulumi config")
    domainsCmd =
      info
        (domainsSubparser <**> helper)
        (fullDesc <> progDesc "Inspect platform domains, DNS expectation, and certificate readiness")
    domainsSubparser =
      subparser
        ( command
            "list"
            ( info
                (Domains . DomainsList <$> domainsListOptsParser <**> helper)
                (progDesc "List the base domain and per-app DomainMappings with DNS and cert state")
            )
        )
    cdnCmd =
      info
        (cdnSubparser <**> helper)
        (fullDesc <> progDesc "Inspect and manage CDN-fronted hostnames (list, status, purge, disable)")
    cdnSubparser =
      subparser
        ( command
            "list"
            ( info
                (CdnCmd . CdnList <$> cdnListOptsParser <**> helper)
                (progDesc "List CDN-fronted sites/apps, provider, and edge status")
            )
            <> command
              "status"
              ( info
                  (CdnCmd . CdnStatus <$> cdnStatusOptsParser <**> helper)
                  (progDesc "Show one hostname's provider, DNS target, cache config, and readiness")
              )
            <> command
              "purge"
              ( info
                  (CdnCmd . CdnPurge <$> cdnPurgeOptsParser <**> helper)
                  (progDesc "Purge the edge cache for a hostname (optionally specific --path values)")
              )
            <> command
              "disable"
              ( info
                  (CdnCmd . CdnDisable <$> cdnDisableOptsParser <**> helper)
                  (progDesc "Revert a hostname's DNS back to the VM (un-proxy / delete the A record)")
              )
        )
    cleanupCmd =
      info
        (Cleanup <$> cleanupOptsParser <**> helper)
        (fullDesc <> progDesc "Reclaim disk: prune unused images, stale previews, old releases (dry-run by default)")
    serverCmd =
      info
        (serverSubparser <**> helper)
        (fullDesc <> progDesc "Server and platform inventory")
    serverSubparser =
      subparser
        ( command
            "status"
            ( info
                (ServerStatus <$> serverStatusOptsParser <**> helper)
                (progDesc "One-screen platform health report")
            )
        )
    deployCmd =
      info
        (Deploy <$> deployOptsParser defaultConfigFile <**> helper)
        (fullDesc <> progDesc "Build, push, and deploy the app in the current directory")
    workerCmd =
      info
        (workerSubparser <**> helper)
        (fullDesc <> progDesc "Run long-running background workers (apps/v1 Deployments)")
    workerSubparser =
      subparser
        ( command
            "deploy"
            ( info
                (Worker . WorkerDeploy <$> workerDeployOptsParser defaultConfigFile <**> helper)
                (progDesc "Build, push, and run a long-running worker (apps/v1 Deployment) from the current directory")
            )
        )
    siteCmd =
      info
        (siteSubparser <**> helper)
        (fullDesc <> progDesc "Static and full-stack site hosting")
    siteSubparser =
      subparser
        ( command "deploy" siteDeployCmd
            <> command "releases" siteReleasesCmd
            <> command "rollback" siteRollbackCmd
            <> command "preview" sitePreviewCmd
        )
    siteDeployCmd =
      info
        (SiteDeploy <$> siteDeployOptsParser defaultConfigFile <**> helper)
        (fullDesc <> progDesc "Build, package, and deploy the static site in the current directory")
    siteReleasesCmd =
      info
        (SiteReleases <$> siteCommonOptsParser defaultConfigFile <**> helper)
        (fullDesc <> progDesc "List recorded releases for the site")
    siteRollbackCmd =
      info
        ( SiteRollback
            <$> siteCommonOptsParser defaultConfigFile
            <*> strArgument (metavar "RELEASE_ID" <> help "Release id to roll back to")
              <**> helper
        )
        (fullDesc <> progDesc "Roll production back to a prior release")
    sitePreviewCmd =
      info
        (previewSubparser <**> helper)
        (fullDesc <> progDesc "Branch / pull-request preview deployments")
    previewSubparser =
      subparser
        ( command "deploy" previewDeployCmd
            <> command "list" previewListCmd
            <> command "delete" previewDeleteCmd
        )
    previewDeployCmd =
      info
        (SitePreviewDeploy <$> siteDeployOptsParser defaultConfigFile <*> previewNameOpt <**> helper)
        (fullDesc <> progDesc "Deploy a preview of the site under a derived name and domain")
    previewListCmd =
      info
        (SitePreviewList <$> siteCommonOptsParser defaultConfigFile <**> helper)
        (fullDesc <> progDesc "List the site's preview deployments")
    previewDeleteCmd =
      info
        ( SitePreviewDelete
            <$> siteCommonOptsParser defaultConfigFile
            <*> strArgument (metavar "NAME" <> help "Preview name to delete")
              <**> helper
        )
        (fullDesc <> progDesc "Delete a preview deployment")
    envCmd =
      info
        (Env <$> envSubparser <**> helper)
        (fullDesc <> progDesc "Manage an app's environment variables (managed ConfigMap store)")
    envSubparser =
      subparser
        ( command
            "list"
            ( info
                ( EnvList
                    <$> storeCommonOptsParser
                    <*> switch (long "all" <> help "Show all scopes, grouped")
                      <**> helper
                )
                (progDesc "List env keys/values for an app")
            )
            <> command
              "set"
              ( info
                  ( EnvSet
                      <$> storeCommonOptsParser
                      <*> scopeSelectionParser
                      <*> dryRunOpt
                      <*> strArgument (metavar "KEY")
                      <*> strArgument (metavar "VALUE")
                        <**> helper
                  )
                  (progDesc "Set one env key (single-key merge)")
              )
            <> command
              "delete"
              ( info
                  ( EnvDelete
                      <$> storeCommonOptsParser
                      <*> scopeSelectionParser
                      <*> dryRunOpt
                      <*> strArgument (metavar "KEY")
                        <**> helper
                  )
                  (progDesc "Delete one env key")
              )
            <> command
              "sync"
              ( info
                  ( EnvSync
                      <$> storeCommonOptsParser
                      <*> scopeSelectionParser
                      <*> dryRunOpt
                      <*> reconcileExactParser
                      <*> strOption (long "file" <> metavar "FILE" <> help "dotenv file to import")
                        <**> helper
                  )
                  (progDesc "Bulk-import a dotenv file into the env store")
              )
        )
    secretCmd =
      info
        (Secret <$> secretSubparser <**> helper)
        (fullDesc <> progDesc "Manage an app's secrets (managed Secret store)")
    secretSubparser =
      subparser
        ( command
            "set"
            ( info
                ( SecretSet
                    <$> storeCommonOptsParser
                    <*> scopeSelectionParser
                    <*> dryRunOpt
                    <*> strArgument (metavar "KEY")
                      <**> helper
                )
                (progDesc "Set one secret key; the value is read from stdin")
            )
            <> command
              "list"
              ( info
                  ( SecretList
                      <$> storeCommonOptsParser
                      <*> switch (long "all" <> help "Show all scopes")
                        <**> helper
                  )
                  (progDesc "List secret key names (never values)")
              )
            <> command
              "delete"
              ( info
                  ( SecretDelete
                      <$> storeCommonOptsParser
                      <*> scopeSelectionParser
                      <*> dryRunOpt
                      <*> strArgument (metavar "KEY")
                        <**> helper
                  )
                  (progDesc "Delete one secret key")
              )
        )
    appCmd =
      info
        (appSubparser <**> helper)
        (fullDesc <> progDesc "Application lifecycle: list, get, logs, restart, stop, delete")
    appSubparser =
      subparser
        ( command
            "list"
            ( info
                (AppList <$> appListOptsParser <**> helper)
                (progDesc "List Nagare-managed apps in a namespace")
            )
            <> command
              "get"
              ( info
                  (AppGet <$> appGetOptsParser <**> helper)
                  (progDesc "Show one app's image, revision, URL, and readiness")
              )
            <> command
              "logs"
              ( info
                  (AppLogs <$> appLogsOptsParser <**> helper)
                  (progDesc "Stream an app's container logs")
              )
            <> command
              "restart"
              ( info
                  (AppRestart <$> appNameOptsParser <**> helper)
                  (progDesc "Roll a fresh revision (also brings a stopped app back online)")
              )
            <> command
              "stop"
              ( info
                  (AppStop <$> appNameOptsParser <**> helper)
                  (progDesc "Take the app offline, recoverably")
              )
            <> command
              "delete"
              ( info
                  (AppDelete <$> appDeleteOptsParser <**> helper)
                  (progDesc "Delete the app, its DomainMappings, and its deployment history")
              )
            <> command
              "deploy"
              ( info
                  (AppDeploy <$> appDeployOptsParser defaultConfigFile <**> helper)
                  (progDesc "Deploy a whole multi-workload Application (service + workers + databases + hooks) in one ordered rollout")
              )
        )
    storageCmd =
      info
        (storageSubparser <**> helper)
        (fullDesc <> progDesc "Inspect an app's persistent volumes")
    storageSubparser =
      subparser
        ( command
            "list"
            ( info
                (Storage . StorageList <$> storeCommonOptsParser <**> helper)
                (progDesc "List an app's volumes and their PVC status")
            )
            <> command
              "inspect"
              ( info
                  ( Storage
                      <$> ( StorageInspect
                              <$> storeCommonOptsParser
                              <*> strArgument (metavar "VOLUME" <> help "Declared volume name")
                          )
                        <**> helper
                  )
                  (progDesc "Show full detail of one volume's PVC")
              )
            <> command
              "snapshot"
              ( info
                  ( Storage
                      <$> ( StorageSnapshot
                              <$> storeCommonOptsParser
                              <*> strArgument (metavar "VOLUME" <> help "Declared volume name")
                              <*> optional
                                ( strOption
                                    ( long "bucket"
                                        <> metavar "BUCKET"
                                        <> help "GCS backup bucket (overrides the target profile NAGARE_BACKUP_BUCKET / <project>-nagare-backups)"
                                    )
                                )
                              <*> option
                                auto
                                ( long "keep"
                                    <> metavar "N"
                                    <> value 7
                                    <> showDefault
                                    <> help "Snapshots to keep per volume (older are pruned)"
                                )
                          )
                        <**> helper
                  )
                  (progDesc "Snapshot a volume's contents to the GCS backup bucket")
              )
            <> command
              "restore"
              ( info
                  ( Storage
                      <$> ( StorageRestore
                              <$> storeCommonOptsParser
                              <*> strArgument (metavar "VOLUME" <> help "Declared volume name")
                              <*> strArgument (metavar "BACKUP_ID" <> help "Snapshot timestamp (or full gs:// URL) to restore")
                              <*> optional
                                ( strOption
                                    ( long "bucket"
                                        <> metavar "BUCKET"
                                        <> help "GCS backup bucket (overrides the target profile NAGARE_BACKUP_BUCKET / <project>-nagare-backups)"
                                    )
                                )
                              <*> switch (long "into-live" <> help "Restore into the LIVE volume PVC (default: a scratch PVC)")
                              <*> dryRunOpt
                          )
                        <**> helper
                  )
                  (progDesc "Restore a volume snapshot from GCS into a scratch PVC (or --into-live)")
              )
        )
    dbCmd =
      info
        (dbSubparser <**> helper)
        (fullDesc <> progDesc "Provision and operate managed databases (Postgres, Redis, ClickHouse)")
    brokerCmd =
      info
        (brokerSubparser <**> helper)
        (fullDesc <> progDesc "Provision and operate in-cluster messaging brokers")
    brokerSubparser =
      subparser
        ( command
            "list"
            ( info
                (Broker . BrokerList <$> brokerListOptsParser <**> helper)
                (progDesc "List managed brokers in a namespace")
            )
            <> command
              "create"
              ( info
                  ( Broker
                      <$> ( BrokerCreate
                              <$> Options.Applicative.argument brokerProviderReader (metavar "PROVIDER" <> help "redpanda")
                              <*> brokerNameArg
                              <*> brokerCreateOptsParser
                          )
                        <**> helper
                  )
                  (progDesc "Create an internal Kafka-compatible broker")
              )
            <> command
              "get"
              ( info
                  (Broker . BrokerGet <$> brokerNameOptsParser <**> helper)
                  (progDesc "Show one broker's detail")
              )
            <> command
              "restart"
              ( info
                  (Broker <$> (BrokerRestart <$> brokerNameOptsParser <*> dryRunOpt) <**> helper)
                  (progDesc "Roll the broker StatefulSet and wait for Ready")
              )
            <> command
              "delete"
              ( info
                  (Broker . BrokerDelete <$> brokerDeleteOptsParser <**> helper)
                  (progDesc "Delete a broker (guarded by --yes)")
              )
        )
    dbSubparser =
      subparser
        ( command
            "list"
            ( info
                (Db . DbList <$> dbListOptsParser <**> helper)
                (progDesc "List managed databases in a namespace")
            )
            <> command
              "create"
              ( info
                  ( Db
                      <$> ( DbCreate
                              <$> Options.Applicative.argument engineReader (metavar "ENGINE" <> help "postgres | redis | clickhouse")
                              <*> strArgument (metavar "NAME" <> help "Database name (DNS label)")
                              <*> dbCreateOptsParser
                          )
                        <**> helper
                  )
                  (progDesc "Create a managed database: generate credentials and provision it")
              )
            <> command
              "get"
              ( info
                  (Db . DbGet <$> dbNameOptsParser <**> helper)
                  (progDesc "Show one database's detail and its Secret key names")
              )
            <> command
              "shell"
              ( info
                  (Db . DbShell <$> dbNameOptsParser <**> helper)
                  (progDesc "Open an interactive engine client inside the database pod")
              )
            <> command
              "restart"
              ( info
                  (Db <$> (DbRestart <$> dbNameOptsParser <*> dryRunOpt) <**> helper)
                  (progDesc "Roll the database StatefulSet and wait for Ready")
              )
            <> command
              "delete"
              ( info
                  (Db . DbDelete <$> dbDeleteOptsParser <**> helper)
                  (progDesc "Delete a database, honoring its retention policy (guarded by --yes)")
              )
            <> command
              "backup"
              ( info
                  (Db . DbBackup <$> dbBackupOptsParser <**> helper)
                  (progDesc "Back up a database to GCS (keep-last-N retention); --dry-run prints the Job/CronJob")
              )
            <> command
              "restore"
              ( info
                  (Db . DbRestore <$> dbRestoreOptsParser <**> helper)
                  (progDesc "Restore a backup into a scratch target (or --into-live); --dry-run prints the Job")
              )
        )
    taskCmd =
      info
        (taskSubparser <**> helper)
        (fullDesc <> progDesc "List, run, view logs for, and delete scheduled tasks (CronJobs)")
    taskSubparser =
      subparser
        ( command
            "list"
            ( info
                (Task . TaskList <$> taskListOptsParser <**> helper)
                (progDesc "List scheduled tasks (optionally scoped to one app)")
            )
            <> command
              "run"
              ( info
                  (Task . TaskRun <$> taskRunOptsParser <**> helper)
                  (progDesc "Run a task once, now: create a Job from its CronJob and wait; --dry-run prints the command")
              )
            <> command
              "logs"
              ( info
                  (Task . TaskLogs <$> taskLogsOptsParser <**> helper)
                  (progDesc "Show a task's most recent pod logs (--follow to tail); prints a Grafana history hint")
              )
            <> command
              "delete"
              ( info
                  (Task . TaskDelete <$> taskDeleteOptsParser <**> helper)
                  (progDesc "Delete a task's CronJob (guarded by --yes)")
              )
        )
    deploymentsCmd =
      info
        (deploymentsSubparser <**> helper)
        (fullDesc <> progDesc "Application deployment history and logs")
    deploymentsSubparser =
      subparser
        ( command
            "list"
            ( info
                (DeploymentsList <$> depListOptsParser <**> helper)
                (progDesc "List recorded deployments for an app, newest first")
            )
            <> command
              "logs"
              ( info
                  (DeploymentsLogs <$> depLogsOptsParser <**> helper)
                  (progDesc "Stream logs for the live or a specific past deployment")
              )
        )

-- ---------------------------------------------------------------------------
-- Main

main :: IO ()
main =
  execParser opts >>= \case
    Deploy dopts -> runDeploy dopts
    SiteDeploy sopts -> runSiteDeploy sopts
    SiteReleases copts -> runSiteReleases copts
    SiteRollback copts rid -> runSiteRollback copts (T.pack rid)
    SitePreviewDeploy sopts pname -> runPreviewDeploy sopts (T.pack pname)
    SitePreviewList copts -> runPreviewList copts
    SitePreviewDelete copts pname -> runPreviewDelete copts (T.pack pname)
    Env ecmd -> runEnv ecmd
    Secret scmd -> runSecret scmd
    AppList o -> runAppList o
    AppGet o -> runAppGet o
    AppLogs o -> runAppLogs o
    AppRestart o -> runAppRestart o
    AppStop o -> runAppStop o
    AppDelete o -> runAppDelete o
    AppDeploy o -> do
      provisionGhcEnv (o ^. #ghcEnv)
      runAppDeploy (toAppDeployParams o)
    DeploymentsList o -> runDeploymentsList o
    DeploymentsLogs o -> runDeploymentsLogs o
    Storage scmd -> runStorage scmd
    Broker bcmd -> runBroker bcmd
    Db dcmd -> runDb dcmd
    Task tcmd -> runTask tcmd
    Worker wcmd -> runWorker wcmd
    ServerStatus o -> runServerStatus o
    Doctor o -> runDoctor o
    Init o -> runInit o
    Domains (DomainsList o) -> runDomainsList o
    CdnCmd ccmd -> runCdn ccmd
    Cleanup o -> runCleanup o

-- | @server status@: gather the platform inventory and print the aligned
-- report. Read-only and always exits 0 — graceful degradation is the probes'
-- job, so a probe whose source is unreachable shows as @UNKNOWN@/@WARN@ rather
-- than aborting the command (script-friendly exit codes belong to EP-39's
-- @doctor@).
runServerStatus :: ServerStatusOpts -> IO ()
runServerStatus o = do
  tp <- resolveTargetProfile
  let invOpts = (inventoryOptsFor tp) {ioSkipVm = ssSkipVm o}
  probes <- gatherInventory tp invOpts
  TIO.putStr (renderInventory probes)

-- | @doctor@: gather EP-38's probes, re-grade them into a remediation checklist,
-- print it, and exit non-zero iff any check FAILs. Read-only and advisory —
-- every remediation is printed text the operator runs themselves
-- ('gatherInventory' degrades unreachable sources to @UNKNOWN@, so the report is
-- always printed; only the exit code varies).
runDoctor :: DoctorOpts -> IO ()
runDoctor o = do
  tp <- resolveTargetProfile
  let invOpts = (inventoryOptsFor tp) {ioSkipVm = dSkipVm o}
  probes <- gatherInventory tp invOpts
  let checks = gradeChecks tp probes
  TIO.putStr (formatDoctor checks)
  unless (doctorExitOk checks) (exitWith (ExitFailure 1))

-- | @nagarectl init@: the guided onboarding flow (EP-63). Order: resolve target
-- (flags or prompts) -> preflight (gcloud auth + operator IAM) -> write the profile
-- -> enable APIs -> seed Pulumi config -> print next steps. Each side-effecting
-- stage is skippable. The ONLY command that drives Pulumi/gcloud (MasterPlan 12
-- Decision Log).
runInit :: InitOpts -> IO ()
runInit o = do
  -- Defaults for prompts come from the current resolved profile, so re-running
  -- shows the operator their existing values.
  defs <- resolveTargetProfile

  -- Resolve the four core target values from flags or interactive prompts. Only
  -- the project is mandatory in non-interactive mode (there is no safe default for
  -- "your project"); region/zone/base-domain fall back to their EP-60 defaults.
  project <- resolveField True "GCP project id" "project" (o ^. #ioProject) (tpProject defs)
  region <- resolveField False "Compute region" "region" (o ^. #ioRegion) (tpRegion defs)
  zone <- resolveField False "Compute zone" "zone" (o ^. #ioZone) (tpZone defs)
  baseDomain <- resolveField False "Apps base domain" "base-domain" (o ^. #ioBaseDomain) (tpBaseDomain defs)

  -- Preflight (unless skipped). Runs AFTER we know the project but BEFORE any
  -- write/enable/seed, so a failure leaves nothing changed.
  unless (o ^. #ioSkipPreflight) $ do
    putStrLn ("Checking gcloud authentication and operator IAM on " <> T.unpack project <> "...")
    r <- runPreflight project
    case r of
      Left msg -> TIO.hPutStr stderr msg >> exitFailure
      Right () -> putStrLn "  preflight OK"

  -- Build the fully-derived profile (registry host, buckets) via the EP-62 resolver.
  tp <- profileFromOpts project region zone baseDomain

  -- Write the profile idempotently.
  wr <- writeTargetEnv (o ^. #ioForce) (o ^. #ioDryRun) tp
  case wr of
    Wrote -> putStrLn "Wrote nagare.target.env"
    DryRunWouldWrite -> do
      putStrLn "DRY RUN — would write nagare.target.env:"
      TIO.putStr (renderTargetEnv tp)
    RefusedExists ->
      dieT "nagare.target.env already exists; re-run with --force to overwrite it."

  -- Enable the GCP APIs (unless skipped).
  unless (o ^. #ioSkipEnable) $ do
    putStrLn "Enabling GCP service APIs..."
    code <- enableApis (o ^. #ioDryRun)
    case code of
      ExitSuccess -> pure ()
      ExitFailure _ -> dieT "enable-apis failed; see the gcloud output above. Re-run `nagarectl init --skip-preflight` after fixing it."

  -- Seed the Pulumi stack config (unless skipped).
  unless (o ^. #ioSkipSeed) $ do
    putStrLn "Seeding Pulumi stack config from the profile..."
    s <- seedPulumiConfig (o ^. #ioDryRun) tp
    case s of
      Right () -> pure ()
      Left (k, _) -> dieT ("pulumi config set failed at key " <> k <> "; fix Pulumi state and re-run `nagarectl init --skip-preflight --skip-enable`.")

  -- Next steps.
  TIO.putStr nextStepsText

-- | Resolve one @init@ target field: a flag value wins; otherwise prompt on a TTY
-- with the default; otherwise (non-TTY, no flag) use the default unless the field
-- is @required@ (only the project), in which case error clearly naming the flag.
resolveField :: Bool -> String -> String -> Maybe String -> Text -> IO Text
resolveField _ _ _ (Just v) _ = pure (T.pack v)
resolveField required label flag Nothing def = do
  tty <- hIsTerminalDevice stdin
  if tty
    then do
      putStr (label <> " [" <> T.unpack def <> "]: ")
      hFlush stdout
      line <- getLine
      pure (if null line then def else T.pack line)
    else
      if required
        then dieT (T.pack ("nagarectl init: --" <> flag <> " is required in non-interactive mode"))
        else pure def

-- | @domains list@: print the base domain plus every per-app DomainMapping with
-- its owning Service, computed DNS expectation, and certificate readiness.
-- Read-only; degrades gracefully when Pulumi/kubectl are unreachable (base row
-- still prints, per-app rows empty, cert column @disabled@).
runDomainsList :: DomainsListOpts -> IO ()
runDomainsList o = do
  base <- resolveDomainsBase (dloBaseDomain o)
  ip <- fromMaybe "(unknown)" <$> stackOutput "infra/pulumi" "publicIp"
  nss <-
    if dloAllNamespaces o
      then listNamespaces
      else pure [appNamespace (dloNamespace o)]
  rows <- concat <$> traverse (queryDomainRows base ip) nss
  let baseRow = DomainRow base Nothing Nothing (UnderWildcard ip) CertDisabled
  TIO.putStr (formatDomainList (baseRow : rows))

-- | Resolve the platform base domain for @domains list@: the @--base-domain@
-- override, else the authoritative Pulumi @baseDomain@ output, else the existing
-- flag/env/literal fallback chain ('resolveBaseDomain').
resolveDomainsBase :: Maybe String -> IO Text
resolveDomainsBase (Just b) = pure (T.pack b)
resolveDomainsBase Nothing = do
  mp <- stackOutput "infra/pulumi" "baseDomain"
  case mp of
    Just d | not (T.null d) -> pure d
    _ -> resolveBaseDomain Nothing

-- | MasterPlan 11 / EP-58: the @nagarectl cdn@ command group dispatcher.
runCdn :: CdnCommand -> IO ()
runCdn = \case
  CdnList o -> runCdnList o
  CdnStatus o -> runCdnStatus o
  CdnPurge o -> runCdnPurge o
  CdnDisable o -> runCdnDisable o

-- | @cdn list@: enumerate CDN-fronted hostnames and their provider/DNS/cache/
-- readiness. Discovery degrades gracefully to the empty sentinel when the
-- cluster / cloud tools are unavailable (VM off, no token) — see
-- 'Nagare.Cdn.Status.queryCdnRows'.
runCdnList :: CdnListOpts -> IO ()
runCdnList o = do
  base <- resolveDomainsBase (cloBaseDomain o)
  ip <- fromMaybe "(unknown)" <$> stackOutput "infra/pulumi" "publicIp"
  nss <-
    if cloAllNamespaces o
      then listNamespaces
      else pure [appNamespace (cloNamespace o)]
  rows <- concat <$> traverse (queryCdnRows base ip) nss
  TIO.putStr (formatCdnList rows)

-- | @cdn status HOST@: show one hostname's CDN state, or an "unknown / not
-- discovered" block when the live discovery cannot run yet.
runCdnStatus :: CdnStatusOpts -> IO ()
runCdnStatus o = do
  base <- resolveDomainsBase (csoBaseDomain o)
  ip <- fromMaybe "(unknown)" <$> stackOutput "infra/pulumi" "publicIp"
  let ns = appNamespace (csoNamespace o)
      host = T.pack (csoHost o)
  rows <- queryCdnRows base ip ns
  case filter ((== host) . cdnRowHost) rows of
    (r : _) -> TIO.putStr (formatCdnStatus r)
    [] -> TIO.putStr (formatCdnStatus (CdnRow host "unknown" DnsUnknown "(not discovered)" False))

-- | @cdn purge HOST [--path P]...@: purge the Cloudflare edge cache. @--dry-run@
-- prints the planned purge; live needs @CF_API_TOKEN@.
runCdnPurge :: CdnPurgeOpts -> IO ()
runCdnPurge o = do
  let host = T.pack (cpoHost o)
      paths = map T.pack (cpoPaths o)
      pathsDesc = if null paths then "everything" else T.intercalate ", " paths
  if cpoDryRun o
    then TIO.putStrLn ("Would purge Cloudflare edge cache for " <> host <> " (paths: " <> pathsDesc <> ")")
    else do
      ecreds <- loadCloudflareCreds
      case ecreds of
        Left e -> dieT ("cdn purge needs Cloudflare credentials: " <> e)
        Right creds -> do
          r <- purgeHostname creds host paths
          case r of
            Left e -> dieT ("cdn purge failed: " <> e)
            Right () -> TIO.putStrLn ("Purged edge cache for " <> host <> " (paths: " <> pathsDesc <> ")")

-- | @cdn disable HOST@: revert a hostname's DNS to the VM. For the Google
-- provider this deletes the more-specific Cloud DNS A record so the
-- @*.<baseDomain>@ wildcard (which points at the VM) wins again. @--dry-run@
-- prints the planned revert without making it.
runCdnDisable :: CdnDisableOpts -> IO ()
runCdnDisable o = do
  let host = T.pack (cdoHost o)
  tp <- resolveTargetProfile
  refs <- gatherGcpStackRefs tp
  let gArgs =
        [ "dns"
        , "record-sets"
        , "delete"
        , host <> "."
        , "--type=A"
        , "--zone=" <> gsrDnsZone refs
        , "--project=" <> tpProject tp
        ]
  if cdoDryRun o
    then do
      TIO.putStrLn ("Would revert " <> host <> " DNS to the VM:")
      TIO.putStrLn ("  Google: gcloud " <> T.unwords gArgs)
      TIO.putStrLn "  Cloudflare: re-point the proxied record to DNS-only (un-proxy)"
    else do
      m <- captureTool "gcloud" (map T.unpack gArgs)
      case m of
        Just _ -> TIO.putStrLn ("Reverted " <> host <> " to the VM (deleted the more-specific A record).")
        Nothing ->
          dieT
            ( "cdn disable: could not delete the Cloud DNS record for "
                <> host
                <> " (is it a Google-CDN hostname? is gcloud configured for "
                <> tpProject tp
                <> "?)"
            )

-- | @cleanup@: gather (and, under @--confirm@, perform) reclamation across
-- images/previews/releases, then print the report. Dry-run by default.
runCleanup :: CleanupOpts -> IO ()
runCleanup o = do
  report <- executeCleanup o
  TIO.putStr (formatCleanupReport report)

runDeploy :: DeployOpts -> IO ()
runDeploy dopts = do
  bd <- resolveBaseDomain (dopts ^. #baseDomain)
  provisionGhcEnv (dopts ^. #ghcEnv)

  edep <- Load.loadDeployment (dopts ^. #file)
  tp <- resolveTargetProfile
  dep <- case edep of
    Left err -> dieT (Load.renderLoadError err)
    -- EP-62 M3: a name-only image (no '/') is qualified with the resolved
    -- registry prefix; a fully-qualified ref is left untouched.
    Right d -> case qualifyImage tp (d ^. #image) of
      Left e -> dieT ("nagarectl deploy: " <> e)
      Right qimg -> pure (d & #image %~ const qimg)

  imageTag <- resolveTag (dopts ^. #tag)
  spec <- resolveBuildSpec (dopts ^. #contextOverride) (dopts ^. #dockerfileOverride) (dep ^. #build)

  -- EP-46: resolve each referenced managed database to its engine + identity and
  -- build the per-engine connection env (literals + Secret refs). Empty when the
  -- app references no databases (no cluster call), so stateless apps are
  -- unaffected. Merged below alongside the NAGARE_* generated env.
  connEnv <- resolveConnectionEnv (dep ^. #namespace) (dep ^. #databases)
  brokerEnv <- resolveBrokerEnv (dep ^. #namespace) (dep ^. #brokers)

  -- EP-26: inject the generated NAGARE_* identity variables as inline {Runtime}
  -- env before rendering, so they appear in the Service and override the managed
  -- envFrom store. EP-31 adds an app-level --source, surfaced as NAGARE_SOURCE.
  let srcText = T.pack <$> dopts ^. #source
      url = serviceUrl dep bd
      gctx =
        Gen.GeneratedContext
          { Gen.serviceName = serviceNameText (dep ^. #name)
          , Gen.namespace = namespaceText (dep ^. #namespace)
          , Gen.serviceUrl = url
          , Gen.baseDomain = bd
          , Gen.releaseId = imageTag
          , Gen.source = srcText
          }
      -- EP-46 connection vars, EP-77 broker vars, and EP-26 NAGARE_* all win
      -- over user env (disjoint names; all left of the user map).
      dep' =
        dep
          & #env
          %~ ( mergeGenerated (generatedEnv gctx)
                 . mergeGenerated brokerEnv
                 . mergeGenerated connEnv
             )

  let effTag = resolveImageTag spec imageTag
      ref = imageRef dep' effTag
      pvcBytes = renderVolumeClaims dep' -- EP-35: [] when the app declares no volumes
      svcBytes = renderService dep' imageTag -- renderer resolves the tag itself
      dmBytes = renderDomainMappings dep'
      name = serviceNameText (dep' ^. #name)
      ns = namespaceText (dep' ^. #namespace)
      -- EP-52: render each co-located task's CronJob with deploy-time values
      -- resolved. The app's resolved image reference is the SAME string the app's
      -- own container gets this run, so an inheriting task runs the app's current
      -- code. The predefined NAGARE_* vars are merged into each task's inline env
      -- (the task's own env wins on a non-NAGARE collision; left-biased merge).
      appImageTagged = imageRefText (dep' ^. #image) <> ":" <> effTag
      withPredef tk = tk & #taskEnv %~ mergeGenerated (predefinedTaskEnv tk)
      taskBytes =
        [ renderResolvedTask appImageTagged effTag withPredef tk
        | tk <- dep' ^. #tasks
        ]

  -- EP-36: warn (never fail) for each volume opted out of backups, in both
  -- dry-run and live deploys, so no volume is ever silently unprotected.
  forM_ (backupExcludedWarnings name (dep' ^. #volumes)) (TIO.hPutStrLn stderr)

  if dopts ^. #dryRun
    then do
      -- EP-35: PVCs are created before the Service, so they print first in dry-run.
      forM_ pvcBytes $ \pvc -> do
        BC.putStrLn "--- PersistentVolumeClaim manifest ---"
        BC.putStr pvc
      BC.putStrLn "--- Knative Service manifest ---"
      BC.putStr svcBytes
      forM_ dmBytes $ \dm -> do
        BC.putStrLn "--- DomainMapping manifest ---"
        BC.putStr dm
      forM_ taskBytes $ \tb -> do
        BC.putStrLn "--- Task CronJob manifest ---"
        BC.putStr tb
      TIO.putStrLn ("Build mode: " <> describeBuild (tpTargetPlatform tp) spec)
      TIO.putStrLn ("URL: " <> url)
      cdnDeployStep True (dep' ^. #cdn) [domainText (ds ^. #domain) | ds <- dep' ^. #domains] ns name
    else do
      if requiresBuild spec
        then do
          -- EP-27: gather the app's Build-scoped env (inline {Build} + the managed
          -- Build store) and pass it to docker build as --build-arg flags. Done only
          -- when actually building (Build-scoped env never reaches the runtime container).
          (bargs, warns) <- gatherBuildArgs name ns (dep ^. #env)
          printBuildArgWarnings warns
          configureDockerAuth
          performBuild (tpTargetPlatform tp) (addBuildArgs bargs spec) ref
          pushImage ref
        else TIO.putStrLn "Skipping build/push: deploying prebuilt image."
      -- EP-35: apply the PVCs first (no-op when empty), then the Service. Never a
      -- pre-Service Bound wait (local-path is WaitForFirstConsumer; that deadlocks).
      applyPVCs pvcBytes
      applyManifests (svcBytes : dmBytes)
      -- EP-52: provision each co-located task's resolved CronJob in the same
      -- idempotent apply pass. Empty (no declared tasks) applies nothing.
      unless (null taskBytes) $ do
        applyManifests taskBytes
        TIO.putStrLn ("Provisioned " <> tShow (length taskBytes) <> " task(s).")
      waitForReady name ns
      resolveDeploymentAccess bd dep'
      reportPVCs ns dep'
      -- EP-31: record the deployment in the per-app history ConfigMap. The
      -- deployment id is the resolved image tag (= NAGARE_RELEASE_ID, = --tag).
      -- Non-fatal: a failed history write must not fail a successful deploy.
      rec <- recordDeploymentFor (imageRefText (dep ^. #image)) imageTag url name ns srcText
      case rec of
        Left warn -> TIO.hPutStrLn stderr ("nagarectl: " <> warn)
        Right () -> pure ()
      TIO.putStrLn ("Deployed: " <> url)
      cdnDeployStep False (dep' ^. #cdn) [domainText (ds ^. #domain) | ds <- dep' ^. #domains] ns name

-- | After a live deploy, print one informational line per declared volume
-- reporting its PVC's bound phase (EP-35). A no-op when the app has no volumes,
-- so a stateless deploy's output is byte-identical to before this change. Never
-- fails the deploy: 'pvcPhases' tolerates a missing/Pending PVC.
reportPVCs :: Text -> Deployment -> IO ()
reportPVCs ns dep = do
  let app = serviceNameText (dep ^. #name)
      vols = dep ^. #volumes
      names = [pvcName app (volumeNameText (v ^. #volName)) | v <- vols]
  unless (null vols) $ do
    phases <- pvcPhases ns names
    forM_ (zip vols phases) $ \(v, (pn, phase)) ->
      TIO.putStrLn
        ("Volume " <> volumeNameText (v ^. #volName) <> ": pvc " <> pn <> " is " <> phase)

-- | Deploy a site (EP-14/EP-15/EP-18). Dispatches on the config's @kind@: a
-- @StaticSite@ runs the Nginx path, a @ServerSite@ runs the Node path. Both share
-- the same CLI options and record a release on success.
runSiteDeploy :: SiteDeployOpts -> IO ()
runSiteDeploy sopts = do
  bd <- resolveBaseDomain (sopts ^. #baseDomain)
  provisionGhcEnv (sopts ^. #ghcEnv)
  tp <- resolveTargetProfile
  esite <- Load.loadSite (sopts ^. #file)
  -- EP-62 M3: qualify a name-only image with the resolved registry prefix; a
  -- fully-qualified ref is left untouched. Inlined per kind because the static
  -- and server site records are distinct types.
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right (Load.SiteStatic s) -> case qualifyImage tp (s ^. #image) of
      Left e -> dieT ("nagarectl deploy: " <> e)
      Right qimg -> deployStatic sopts (s & #image %~ const qimg) bd
    Right (Load.SiteServer s) -> case qualifyImage tp (s ^. #image) of
      Left e -> dieT ("nagarectl deploy: " <> e)
      Right qimg -> deployServer sopts (s & #image %~ const qimg) bd

-- | The static (Nginx) deploy path.
--
-- NOTE (EP-26): static sites have no env field and serve files via Nginx, so the
-- generated NAGARE_* runtime variables do not apply here and are intentionally not
-- injected. See docs/plans/26-generated-and-predefined-environment-variables.md.
deployStatic :: SiteDeployOpts -> StaticSite -> Text -> IO ()
deployStatic sopts site bd = do
  imageTag <- resolveTag (sopts ^. #tag)
  let inputs = siteDeployInputs sopts site imageTag bd
      m = productionManifests inputs
      cdnHosts = siteHostnames (site ^. #domains)
      cdnNs = namespaceText (site ^. #namespace)
      cdnSvc = siteNameText (site ^. #name)
  if sopts ^. #dryRun
    then do
      printStaticArtifacts (m ^. #nginxConf) (m ^. #service) (m ^. #domainMappings) (m ^. #url)
      TIO.putStrLn ("Release: " <> imageTag)
      cdnDeployStep True (site ^. #cdn) cdnHosts cdnNs cdnSvc
    else do
      result <- deployStaticProduction inputs (T.pack <$> sopts ^. #source)
      case result of
        Left err -> dieT err
        Right u -> do
          TIO.putStrLn ("Deployed static site: " <> u)
          cdnDeployStep False (site ^. #cdn) cdnHosts cdnNs cdnSvc

-- | The server (Node) deploy path.
deployServer :: SiteDeployOpts -> ServerSite -> Text -> IO ()
deployServer sopts site0 bd = do
  imageTag <- resolveTag (sopts ^. #tag)
  -- EP-26: inject the generated NAGARE_* identity variables into the ServerSite's
  -- env before rendering. The server path carries --source, so NAGARE_SOURCE is
  -- present when provided. serverUrl matches the URL serverManifests renders.
  let gctx =
        Gen.GeneratedContext
          { Gen.serviceName = siteNameText (site0 ^. #name)
          , Gen.namespace = namespaceText (site0 ^. #namespace)
          , Gen.serviceUrl = serverUrl site0 bd
          , Gen.baseDomain = bd
          , Gen.releaseId = imageTag
          , Gen.source = T.pack <$> sopts ^. #source
          }
      site = site0 & #env %~ mergeGenerated (generatedEnv gctx)
      inputs =
        ServerDeployInputs
          { site = site
          , imageTag = imageTag
          , baseDomain = bd
          , projectDir = sopts ^. #projectDir
          , skipBuild = sopts ^. #skipBuild
          }
      m = serverManifests inputs
  if sopts ^. #dryRun
    then do
      BC.putStrLn "--- Generated Dockerfile ---"
      TIO.putStr (m ^. #dockerfile)
      BC.putStrLn "--- Knative Service manifest ---"
      BC.putStr (m ^. #service)
      forM_ (m ^. #domainMappings) $ \dm -> do
        BC.putStrLn "--- DomainMapping manifest ---"
        BC.putStr dm
      TIO.putStrLn ("URL: " <> (m ^. #url))
      TIO.putStrLn ("Release: " <> imageTag)
      cdnDeployStep True (site ^. #cdn) (siteHostnames (site ^. #domains)) (namespaceText (site ^. #namespace)) (siteNameText (site ^. #name))
    else do
      result <- deployServerProduction inputs (T.pack <$> sopts ^. #source)
      case result of
        Left err -> dieT err
        Right u -> do
          TIO.putStrLn ("Deployed server site: " <> u)
          cdnDeployStep False (site ^. #cdn) (siteHostnames (site ^. #domains)) (namespaceText (site ^. #namespace)) (siteNameText (site ^. #name))

-- | MasterPlan 11 / EP-58: the CDN provisioning step, run as the last step of a
-- deploy (after the origin is Ready) or printed under @--dry-run@. A 'Nothing'
-- CDN is a no-op, so a non-CDN deploy is byte-for-byte unchanged. In the live
-- branch a provisioning failure is reported to stderr and never fails the
-- already-successful origin deploy. The reusable @deploy*Production@ effects and
-- the @nagared@ webhook stay free of CDN/Pulumi coupling — orchestration lives
-- here in the CLI handler, where @--dry-run@ already lives.
cdnDeployStep :: Bool -> Maybe Cdn -> [Text] -> Text -> Text -> IO ()
cdnDeployStep _ Nothing _ _ _ = pure ()
cdnDeployStep dry (Just c) hostnames ns service = do
  originIp <- fromMaybe "<publicIp>" <$> stackOutput "infra/pulumi" "publicIp"
  tp <- resolveTargetProfile
  refs <- gatherGcpStackRefs tp
  let target = CdnTarget {cdnHostnames = hostnames, cdnOriginIp = originIp, cdnNamespace = ns, cdnService = service}
  if dry
    then TIO.putStr (renderCdnPlan (planCdn c target refs))
    else do
      res <- provisionCdn c target refs
      case res of
        Left e -> TIO.hPutStrLn stderr ("nagarectl: CDN provisioning failed (origin is up): " <> e)
        Right r -> TIO.putStrLn (cdnSummary r)

-- | Read the four EP-56 Google stack outputs, with a clear placeholder when an
-- output is absent (the CDN load balancer is disabled, or Pulumi is unavailable).
gatherGcpStackRefs :: TargetProfile -> IO GcpStackRefs
gatherGcpStackRefs tp = do
  let so name = fromMaybe ("<" <> name <> ">") <$> stackOutput "infra/pulumi" name
  GcpStackRefs
    <$> so "cdnGlobalIp"
    <*> so "cdnBackendService"
    <*> so "cdnUrlMap"
    <*> so "dnsZoneName"
    <*> pure (tpProject tp)

-- | The custom-domain hostnames of a site (in declaration order) — the hostnames
-- a CDN fronts.
siteHostnames :: [Domain] -> [Text]
siteHostnames = map domainText

-- | @site releases@: print the recorded release history. Kind-agnostic — works
-- for both static and server sites (the release record is runtime-agnostic).
runSiteReleases :: SiteCommonOpts -> IO ()
runSiteReleases copts = do
  provisionGhcEnv (copts ^. #ghcEnv)
  (name, ns) <- siteIdentityOrDie (copts ^. #file)
  elog <- readReleaseLog name ns
  case elog of
    Left err -> dieT err
    Right logv -> TIO.putStr (formatReleasesTable logv)

-- | @site rollback RELEASE_ID@: re-point the production Service at a prior
-- release's image tag and mark it current. The image already exists in the
-- registry, so this re-applies the rendered Service (no rebuild). Kind-agnostic:
-- it renders the static or server Service to match the project.
runSiteRollback :: SiteCommonOpts -> Text -> IO ()
runSiteRollback copts rid = do
  bd <- resolveBaseDomain (copts ^. #baseDomain)
  provisionGhcEnv (copts ^. #ghcEnv)
  esite <- Load.loadSite (copts ^. #file)
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right sc -> do
      let (name, ns) = siteConfigIdentity sc
      elog <- readReleaseLog name ns
      logv <- case elog of
        Left err -> dieT err
        Right l -> pure l
      case findRelease rid logv of
        Nothing -> dieT ("no such release: " <> rid)
        Just rel -> do
          let (svc, dms) = rollbackManifests sc bd (rel ^. #imageTag)
          applyManifests (svc : dms)
          waitForReady name ns
          writeReleaseLog name ns logv {current = Just (rel ^. #releaseId)}
          TIO.putStrLn ("Rolled back to " <> (rel ^. #releaseId) <> ": " <> (rel ^. #url))

-- | The (name, namespace) of either site kind.
siteConfigIdentity :: Load.SiteConfig -> (Text, Text)
siteConfigIdentity (Load.SiteStatic s) =
  (siteNameText (s ^. #name), namespaceText (s ^. #namespace))
siteConfigIdentity (Load.SiteServer s) =
  (siteNameText (s ^. #name), namespaceText (s ^. #namespace))

-- | Load a site of either kind and return its (name, namespace).
siteIdentityOrDie :: FilePath -> IO (Text, Text)
siteIdentityOrDie file = do
  esite <- Load.loadSite file
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right sc -> pure (siteConfigIdentity sc)

-- | Render the production Service + DomainMappings for a rollback to @tag@,
-- dispatching on kind.
rollbackManifests :: Load.SiteConfig -> Text -> Text -> (ByteString, [ByteString])
rollbackManifests (Load.SiteStatic s) bd tag =
  let m = productionManifests (DeployInputs s tag bd "." True)
   in (m ^. #service, m ^. #domainMappings)
rollbackManifests (Load.SiteServer s) bd tag =
  let m = serverManifests (ServerDeployInputs s tag bd "." True)
   in (m ^. #service, m ^. #domainMappings)

-- | @site preview deploy --name NAME@: deploy the current build as an isolated
-- preview Service under a derived name and domain. Previews are not recorded in
-- the production release history.
runPreviewDeploy :: SiteDeployOpts -> Text -> IO ()
runPreviewDeploy sopts pname = do
  bd <- resolveBaseDomain (sopts ^. #baseDomain)
  provisionGhcEnv (sopts ^. #ghcEnv)
  site <- loadSiteOrDie (sopts ^. #file)
  imageTag <- resolveTag (sopts ^. #tag)
  let inputs = siteDeployInputs sopts site imageTag bd
  m <- orDie (previewManifests inputs pname)

  if sopts ^. #dryRun
    then do
      printStaticArtifacts (m ^. #nginxConf) (m ^. #service) (m ^. #domainMappings) (m ^. #url)
      TIO.putStrLn ("Preview service: " <> (m ^. #serviceName))
    else do
      result <- deployStaticPreview inputs pname
      case result of
        Left err -> dieT err
        Right u -> TIO.putStrLn ("Deployed preview: " <> u)

-- | @site preview list@: list the site's preview Service names.
runPreviewList :: SiteCommonOpts -> IO ()
runPreviewList copts = do
  provisionGhcEnv (copts ^. #ghcEnv)
  site <- loadSiteOrDie (copts ^. #file)
  let name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
  pnames <- listPreviews name ns
  if null pnames
    then TIO.putStrLn "(no previews)"
    else mapM_ TIO.putStrLn pnames

-- | @site preview delete NAME@: remove a preview's Service and DomainMapping.
runPreviewDelete :: SiteCommonOpts -> Text -> IO ()
runPreviewDelete copts pname = do
  bd <- resolveBaseDomain (copts ^. #baseDomain)
  provisionGhcEnv (copts ^. #ghcEnv)
  site <- loadSiteOrDie (copts ^. #file)
  let prodName = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
  svcName <- orDie (previewServiceName prodName pname)
  pdomText <- orDie (previewDomain prodName pname bd)
  deletePreview ns svcName pdomText
  TIO.putStrLn ("Deleted preview: " <> svcName)

-- ---------------------------------------------------------------------------
-- app lifecycle handlers (EP-30)

-- | Resolve the namespace for an @app@ command: the @-n@ value, or @personal@.
appNamespace :: Maybe String -> Text
appNamespace = maybe "personal" T.pack

-- | @app list@: print a table of apps in a namespace (Nagare-managed unless
-- @--all@). An empty managed list prints a hint to try @--all@.
-- | Convert the executable's option record into the library deploy params
-- (MasterPlan 14, EP-2), so the library never depends on the option type.
toAppDeployParams :: AppDeployOpts -> AppDeployParams
toAppDeployParams o =
  AppDeployParams
    { adpConfigPath = o ^. #file
    , adpTag = T.pack <$> o ^. #tag
    , adpBaseDomain = T.pack <$> o ^. #baseDomain
    , adpContextOverride = o ^. #contextOverride
    , adpDockerfileOverride = o ^. #dockerfileOverride
    , adpDryRun = o ^. #dryRun
    , adpJson = o ^. #json
    , adpSource = T.pack <$> o ^. #source
    }

runAppList :: AppListOpts -> IO ()
runAppList o = do
  let ns = appNamespace (o ^. #namespace)
  esummaries <- listAppSummaries ns (o ^. #allApps)
  case esummaries of
    Left err -> dieT err
    Right [] ->
      if o ^. #allApps
        then TIO.putStrLn "(no Knative Services in this namespace)"
        else TIO.putStrLn "(no Nagare-managed apps; pass --all to list every Knative Service)"
    Right summaries -> TIO.putStr (formatAppList summaries)

-- | @app get NAME@: print one app's live state, enriched with the config's
-- declared domains/health check/limits when a readable config is present.
runAppGet :: AppGetOpts -> IO ()
runAppGet o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  esummary <- getAppSummary ns name
  case esummary of
    Left err -> dieT err
    Right s -> do
      printAppSummary s
      enrichFromConfig (o ^. #file) (o ^. #ghcEnv)

-- | Print the aligned @app get@ field block.
printAppSummary :: AppSummary -> IO ()
printAppSummary s = do
  TIO.putStrLn ("Name:     " <> asName s)
  TIO.putStrLn ("Ready:    " <> maybe "?" boolText (asReady s))
  TIO.putStrLn ("URL:      " <> fromMaybe "-" (asUrl s))
  TIO.putStrLn ("Revision: " <> fromMaybe "-" (asLatestRevision s))
  TIO.putStrLn ("Image:    " <> fromMaybe "-" (asImage s))
  where
    boolText True = "True"
    boolText False = "False"

-- | When @file@ exists and loads as a 'Deployment', print its configured
-- domains, health check, and resource limits (EP-29's richer model). Any
-- absence or load failure is silently skipped — @app get@ works without a config.
enrichFromConfig :: FilePath -> Maybe FilePath -> IO ()
enrichFromConfig file ghc = do
  exists <- doesFileExist file
  when exists $ do
    provisionGhcEnv ghc
    edep <- Load.loadDeployment file
    case edep of
      Left _ -> pure ()
      Right dep -> do
        let doms = dep ^. #domains
        unless (null doms) $
          TIO.putStrLn ("Domains:  " <> T.intercalate ", " (map domainLabel doms))
        forM_ (dep ^. #healthCheck) $ \hc ->
          TIO.putStrLn ("Health:   " <> (hc ^. #path) <> " (" <> T.pack (show (hc ^. #scheme)) <> ")")
        forM_ (dep ^. #resources) $ \res ->
          let lims =
                catMaybes
                  [ ("cpu " <>) . quantityText <$> (res ^. #cpuLimit)
                  , ("memory " <>) . quantityText <$> (res ^. #memoryLimit)
                  ]
           in unless (null lims) $ TIO.putStrLn ("Limits:   " <> T.intercalate ", " lims)
  where
    domainLabel d =
      domainText (d ^. #domain) <> if d ^. #canonical then " (canonical)" else ""

-- | @app logs NAME [--follow] [--tail N]@: stream the app's user-container logs.
runAppLogs :: AppLogsOpts -> IO ()
runAppLogs o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
      following = o ^. #follow
      target =
        LogTarget
          { ltNamespace = ns
          , ltService = name
          , ltRevision = Nothing
          , ltFollow = following
          , ltTail = if following then Nothing else Just (fromMaybe 200 (o ^. #tailN))
          }
  streamServiceLogs target

-- | @app restart NAME@: roll a fresh revision (also clears the cluster-local
-- label, so a stopped app comes back online), then wait for readiness.
runAppRestart :: AppNameOpts -> IO ()
runAppRestart o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  stamp <- computeTag
  restartApp ns name stamp
  waitForReady name ns
  TIO.putStrLn ("Restarted: " <> name)

-- | @app stop NAME@: take the app offline recoverably.
runAppStop :: AppNameOpts -> IO ()
runAppStop o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  stopApp ns name
  TIO.putStrLn
    ( "Stopped "
        <> name
        <> " (run 'nagarectl deploy' or 'nagarectl app restart "
        <> name
        <> "' to restore public serving)"
    )

-- | @app delete NAME@: remove the Service, its DomainMappings, and its history.
-- Domains come from the config when @--file@ resolves to a 'Deployment',
-- otherwise from a cluster query of DomainMappings pointing at the Service.
runAppDelete :: AppDeleteOpts -> IO ()
runAppDelete o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  domains <- resolveDeleteDomains o ns name
  deleteApp ns name domains
  TIO.putStrLn ("Deleted " <> name)

-- | The DomainMapping hostnames to delete with an app: the config's declared
-- domains when a readable 'Deployment' config is present, else the cluster's
-- DomainMappings that reference the Service.
resolveDeleteDomains :: AppDeleteOpts -> Text -> Text -> IO [Text]
resolveDeleteDomains o ns name = do
  exists <- doesFileExist (o ^. #file)
  if exists
    then do
      provisionGhcEnv (o ^. #ghcEnv)
      edep <- Load.loadDeployment (o ^. #file)
      case edep of
        Right dep -> pure (map (\d -> domainText (d ^. #domain)) (dep ^. #domains))
        Left _ -> appDomains ns name
    else appDomains ns name

-- ---------------------------------------------------------------------------
-- deployments handlers (EP-31)

-- | @deployments list NAME@: print the app's deployment history newest-first,
-- the live deployment starred.
runDeploymentsList :: DepListOpts -> IO ()
runDeploymentsList o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  elog <- readDeployments name ns
  case elog of
    Left err -> dieT err
    Right logv -> TIO.putStr (formatDeploymentsTable logv)

-- | @deployments logs NAME [DEPLOYMENT_ID]@: stream the live revision's logs, or
-- (with an id) the revision that deployment produced — mapped via its image tag.
-- A non-existent revision for an old id is a clear error.
runDeploymentsLogs :: DepLogsOpts -> IO ()
runDeploymentsLogs o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
      following = o ^. #follow
      tailLines = if following then Nothing else Just (fromMaybe 200 (o ^. #tailN))
      mkTarget rev =
        LogTarget
          { ltNamespace = ns
          , ltService = name
          , ltRevision = rev
          , ltFollow = following
          , ltTail = tailLines
          }
  case o ^. #depId of
    Nothing -> streamServiceLogs (mkTarget Nothing)
    Just idStr -> do
      let did = T.pack idStr
      mrev <- resolveRevisionForTag ns name did
      case mrev of
        Just rev -> streamServiceLogs (mkTarget (Just rev))
        Nothing ->
          dieT
            ( "no live revision for deployment "
                <> did
                <> " (its pods may have been garbage-collected; try 'nagarectl deployments logs "
                <> name
                <> "' for the live deployment)"
            )

-- ---------------------------------------------------------------------------
-- env / secret handlers (EP-25)

-- | Resolve @(name, namespace)@ from a config of any kind: a plain Deployment, a
-- StaticSite, or a ServerSite. Tries the Deployment loader first; on an
-- 'Load.UnexpectedKind' (the config is a site) falls back to the site loader.
--
-- (Distinct from 'Nagare.App.appIdentityOrDie', which is Deployment-only and is
-- the IP2 helper the @app@/@deployments@ commands use. This site-aware resolver
-- is the env/secret path, which must accept site configs too.)
configIdentityOrDie :: FilePath -> IO (Text, Text)
configIdentityOrDie file = do
  edep <- Load.loadDeployment file
  case edep of
    Right dep ->
      pure (serviceNameText (dep ^. #name), namespaceText (dep ^. #namespace))
    Left (Load.UnexpectedKind _ _) -> siteIdentityOrDie file
    Left err -> dieT (Load.renderLoadError err)

-- | Resolve @(name, namespace)@ from the loaded config and reconcile it against
-- the positional @APP@: the config's name is authoritative; a mismatch is a hard
-- error so the operator is told rather than silently surprised.
resolveAppOrDie :: StoreCommonOpts -> IO (Text, Text)
resolveAppOrDie copts = do
  provisionGhcEnv (copts ^. #ghcEnv)
  (name, ns) <- configIdentityOrDie (copts ^. #file)
  let typed = T.pack (copts ^. #app)
  if typed /= name
    then
      dieT
        ( "config names app '"
            <> name
            <> "' but the command names '"
            <> typed
            <> "'; they must match (the config's name is what the Service references)"
        )
    else pure (name, ns)

-- | Load the app's typed config for the @storage@ commands and verify the
-- positional @APP@ matches the config's name (mirrors 'resolveAppOrDie' but
-- returns the full 'Deployment' so the declared volumes are available to
-- 'runStorageList'/'runStorageInspect'). EP-35.
resolveStorageDep :: StoreCommonOpts -> IO Deployment
resolveStorageDep copts = do
  provisionGhcEnv (copts ^. #ghcEnv)
  edep <- Load.loadDeployment (copts ^. #file)
  dep <- case edep of
    Left err -> dieT (Load.renderLoadError err)
    Right d -> pure d
  let typed = T.pack (copts ^. #app)
      name = serviceNameText (dep ^. #name)
  if typed /= name
    then
      dieT
        ( "config names app '"
            <> name
            <> "' but the command names '"
            <> typed
            <> "'; they must match (the config's name is what the Service references)"
        )
    else pure dep

runStorage :: StorageCommand -> IO ()
runStorage = \case
  StorageList copts -> resolveStorageDep copts >>= runStorageList
  StorageInspect copts vol -> do
    dep <- resolveStorageDep copts
    runStorageInspect dep (T.pack vol)
  StorageSnapshot copts vol bucket keep -> do
    dep <- resolveStorageDep copts
    tp <- resolveTargetProfile
    b <- resolveBackupBucket bucket
    runSnapshot dep (T.pack vol) b keep (tpProject tp)
  StorageRestore copts vol backupId bucket live dryRun -> do
    dep <- resolveStorageDep copts
    tp <- resolveTargetProfile
    b <- resolveBackupBucket bucket
    runStorageRestore dep (T.pack vol) (T.pack backupId) live b (tpProject tp) dryRun

-- | Dispatch the @broker@ subcommands (MasterPlan 15, EP-78). The namespace
-- defaults to @personal@.
runBroker :: BrokerCommand -> IO ()
runBroker = \case
  BrokerList o -> runBrokerList (nsOf (o ^. #namespace))
  BrokerCreate provider name o -> do
    when (isJust (o ^. #config)) (provisionGhcEnv Nothing)
    runBrokerCreate
      provider
      (T.pack name)
      BrokerCreateParams
        { namespace = nsOf (o ^. #namespace)
        , version = T.pack <$> o ^. #version
        , size = T.pack <$> o ^. #size
        , cpu = T.pack <$> o ^. #cpu
        , memory = T.pack <$> o ^. #memory
        , config = o ^. #config
        , dryRun = o ^. #dryRun
        , redpandaSmp = o ^. #redpandaSmp
        , redpandaMemory = T.pack <$> o ^. #redpandaMemory
        , topics = map T.pack (o ^. #topics)
        , topicPartitions = o ^. #topicPartitions
        , topicRetentionMs = o ^. #topicRetentionMs
        }
  BrokerGet o -> runBrokerGet (nsOf (o ^. #namespace)) (T.pack (o ^. #name))
  BrokerRestart o dryRun -> runBrokerRestart (nsOf (o ^. #namespace)) (T.pack (o ^. #name)) dryRun
  BrokerDelete o ->
    runBrokerDelete
      BrokerDeleteParams
        { name = T.pack (o ^. #name)
        , namespace = nsOf (o ^. #namespace)
        , yes = o ^. #yes
        , dryRun = o ^. #dryRun
        }
  where
    nsOf = maybe "personal" T.pack

-- | Dispatch the @db@ subcommands (MasterPlan 9, EP-45). The namespace defaults
-- to @personal@. EP-47 adds @DbBackup@/@DbRestore@ cases here.
runDb :: DbCommand -> IO ()
runDb = \case
  DbList o -> runDbList (nsOf (dbloNamespace o))
  DbCreate eng name o -> do
    when (isJust (dbcConfig o)) (provisionGhcEnv Nothing)
    runDbCreate
      eng
      (T.pack name)
      DbCreateParams
        { dcpNamespace = nsOf (dbcNamespace o)
        , dcpVersion = T.pack <$> dbcVersion o
        , dcpSize = T.pack <$> dbcSize o
        , dcpCpu = T.pack <$> dbcCpu o
        , dcpMemory = T.pack <$> dbcMemory o
        , dcpConfig = dbcConfig o
        , dcpDryRun = dbcDryRun o
        }
  DbGet o -> runDbGet (nsOf (dbnNamespace o)) (T.pack (dbnName o))
  DbShell o -> runDbShell (nsOf (dbnNamespace o)) (T.pack (dbnName o))
  DbRestart o dry -> runDbRestart (nsOf (dbnNamespace o)) (T.pack (dbnName o)) dry
  DbDelete o ->
    runDbDelete
      DbDeleteParams
        { ddpName = T.pack (dbdName o)
        , ddpNamespace = nsOf (dbdNamespace o)
        , ddpYes = dbdYes o
        , ddpDryRun = dbdDryRun o
        }
  DbBackup o -> do
    tp <- resolveTargetProfile
    bucket <- resolveBackupBucket (dbbBucket o)
    runDbBackup (nsOf (dbbNamespace o)) (T.pack (dbbName o)) bucket (dbbKeep o) (tpProject tp) (dbbDryRun o)
  DbRestore o -> do
    tp <- resolveTargetProfile
    bucket <- resolveBackupBucket (dbrBucket o)
    runDbRestore (nsOf (dbrNamespace o)) (T.pack (dbrName o)) (T.pack (dbrBackupId o)) (dbrLive o) bucket (tpProject tp) (dbrDryRun o)
  where
    nsOf = maybe "personal" T.pack

-- | Dispatch the @worker@ command group (EP-71). Provisions the GHC environment
-- before loading the worker's @Config.hs@ (mirroring @db create --config@), then
-- runs the deploy. Cluster I/O and rendering live in 'Nagare.Worker.Deploy'.
runWorker :: WorkerCommand -> IO ()
runWorker = \case
  WorkerDeploy o -> do
    provisionGhcEnv (o ^. #ghcEnv)
    runWorkerDeploy
      WorkerDeployParams
        { wdpConfigPath = o ^. #file
        , wdpTag = T.pack <$> o ^. #tag
        , wdpContextOverride = o ^. #contextOverride
        , wdpDockerfileOverride = o ^. #dockerfileOverride
        , wdpDryRun = o ^. #dryRun
        }

-- | Dispatch the @task@ command group (MasterPlan 10, EP-51). Mirrors 'runDb'.
-- The @APP@ positional becomes an 'AppScope': @-@ means app-less, anything else is
-- that app; for @task list@ an omitted @APP@ means "any app".
runTask :: TaskCommand -> IO ()
runTask = \case
  TaskList o -> runTaskList (nsOf (tlsNamespace o)) (scopeOfMaybe (tlsApp o))
  TaskRun o ->
    runTaskRun
      TaskRunParams
        { trpApp = T.pack (troApp o)
        , trpTask = T.pack (troTask o)
        , trpNamespace = nsOf (troNamespace o)
        , trpScope = scopeOf (troApp o)
        , trpDryRun = troDryRun o
        }
  TaskLogs o ->
    runTaskLogs
      TaskLogTarget
        { tltNamespace = nsOf (tlgNamespace o)
        , tltTask = T.pack (tlgTask o)
        , tltScope = scopeOf (tlgApp o)
        , tltFollow = tlgFollow o
        , tltTail = tlgTail o
        }
  TaskDelete o ->
    runTaskDelete
      TaskDeleteParams
        { tdpName = T.pack (tdoTask o)
        , tdpNamespace = nsOf (tdoNamespace o)
        , tdpScope = scopeOf (tdoApp o)
        , tdpYes = tdoYes o
        , tdpDryRun = tdoDryRun o
        }
  where
    nsOf = maybe "personal" T.pack
    -- A required APP positional: "-" means app-less, anything else is that app.
    scopeOf "-" = NoApp
    scopeOf a = App (T.pack a)
    -- An optional APP positional (task list): absent means "any app".
    scopeOfMaybe Nothing = AnyApp
    scopeOfMaybe (Just a) = scopeOf a

-- | Resolve the GCS backup bucket: an explicit @--bucket@ flag wins; otherwise
-- the resolved target profile's backup bucket (EP-62; honors
-- @NAGARE_BACKUP_BUCKET@ and the @\<project>-nagare-backups@ derivation).
resolveBackupBucket :: Maybe String -> IO Text
resolveBackupBucket (Just b) = pure (T.pack b)
resolveBackupBucket Nothing = tpBackupBucket <$> resolveTargetProfile

runEnv :: EnvCommand -> IO ()
runEnv = \case
  EnvList copts allScopes -> do
    (name, ns) <- resolveAppOrDie copts
    let scopes = if allScopes then [minBound .. maxBound] else [Runtime]
    runEnvListBody name ns scopes
  EnvSet copts sel dry key val -> do
    (name, ns) <- resolveAppOrDie copts
    forM_ (selectedScopes sel) $ \scope -> do
      existing <- orDie =<< readEnvStore name ns scope
      let desired = reconcile Merge existing (Map.singleton (T.pack key) (T.pack val))
      applyOrDryRunEnv dry name ns scope desired
    unless dry $ TIO.putStrLn ("Set " <> T.pack key <> " in env for " <> name <> ".")
  EnvDelete copts sel dry key -> do
    (name, ns) <- resolveAppOrDie copts
    forM_ (selectedScopes sel) $ \scope -> do
      existing <- orDie =<< readEnvStore name ns scope
      let desired = reconcile ReconcileExact mempty (Map.delete (T.pack key) existing)
      applyOrDryRunEnv dry name ns scope desired
    unless dry $ TIO.putStrLn ("Deleted " <> T.pack key <> " from env for " <> name <> ".")
  EnvSync copts sel dry exact dotenvPath -> do
    (name, ns) <- resolveAppOrDie copts
    raw <- TIO.readFile dotenvPath
    incoming <- orDie (parseDotenv raw)
    let mode = reconcileModeFrom exact
    forM_ (selectedScopes sel) $ \scope -> do
      existing <- orDie =<< readEnvStore name ns scope
      let desired = reconcile mode existing incoming
      applyOrDryRunEnv dry name ns scope desired
    unless dry $
      TIO.putStrLn ("Synced " <> tShow (Map.size incoming) <> " key(s) into env for " <> name <> ".")

runSecret :: SecretCommand -> IO ()
runSecret = \case
  SecretSet copts sel dry key -> do
    (name, ns) <- resolveAppOrDie copts
    val <- readSecretValue
    forM_ (selectedScopes sel) $ \scope -> do
      existing <- orDie =<< readSecretStore name ns scope
      let desired = reconcile Merge existing (Map.singleton (T.pack key) val)
      applyOrDryRunSecret dry name ns scope desired
    unless dry $ TIO.putStrLn ("Set " <> T.pack key <> " in secret for " <> name <> ".")
  SecretList copts allScopes -> do
    (name, ns) <- resolveAppOrDie copts
    let scopes = if allScopes then [minBound .. maxBound] else [Runtime]
    keys <- fmap concat $ forM scopes $ \scope -> do
      m <- orDie =<< readSecretStore name ns scope
      pure (Map.keys m)
    if null keys then TIO.putStrLn "(no secrets set)" else mapM_ TIO.putStrLn keys
  SecretDelete copts sel dry key -> do
    (name, ns) <- resolveAppOrDie copts
    forM_ (selectedScopes sel) $ \scope -> do
      existing <- orDie =<< readSecretStore name ns scope
      let desired = reconcile ReconcileExact mempty (Map.delete (T.pack key) existing)
      applyOrDryRunSecret dry name ns scope desired
    unless dry $ TIO.putStrLn ("Deleted " <> T.pack key <> " from secret for " <> name <> ".")

-- | Print the rendered ConfigMap (dry-run) or write the store (otherwise).
applyOrDryRunEnv :: Bool -> Text -> Text -> EnvScope -> Map Text Text -> IO ()
applyOrDryRunEnv dry name ns scope desired
  | dry = do
      BC.putStrLn ("--- ConfigMap (" <> TE.encodeUtf8 (scopeToken scope) <> ") ---")
      BC.putStrLn (renderEnvConfigMap name ns scope desired)
  | otherwise = writeEnvStore name ns scope desired

-- | Print the rendered Secret (dry-run) or write the store (otherwise). Under
-- dry-run the manifest carries base64-encoded values (the wire format); the
-- operator already holds the plaintext, so this is not a secrecy regression.
applyOrDryRunSecret :: Bool -> Text -> Text -> EnvScope -> Map Text Text -> IO ()
applyOrDryRunSecret dry name ns scope desired
  | dry = do
      BC.putStrLn ("--- Secret (" <> TE.encodeUtf8 (scopeToken scope) <> ") ---")
      BC.putStrLn (renderEnvSecret name ns scope desired)
  | otherwise = writeSecretStore name ns scope desired

-- | Read each requested scope's env store and print an aligned table.
runEnvListBody :: Text -> Text -> [EnvScope] -> IO ()
runEnvListBody name ns scopes = do
  rows <- fmap concat $ forM scopes $ \scope -> do
    m <- orDie =<< readEnvStore name ns scope
    pure [(scopeToken scope, k, v) | (k, v) <- Map.toAscList m]
  if null rows
    then TIO.putStrLn "(no env set)"
    else TIO.putStr (formatEnvRows rows)

formatEnvRows :: [(Text, Text, Text)] -> Text
formatEnvRows rows = T.unlines (header : map row rows)
  where
    header = "  SCOPE    KEY                 VALUE"
    row (s, k, v) = T.concat ["  ", pad 9 s, pad 20 k, v]
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

-- | Read one secret value. If stdin is a TTY, prompt with echo off; otherwise
-- read all of stdin and strip a single trailing newline (so a piped
-- @printf '%s' v@ and an interactive line both work). The value never appears in
-- @argv@.
readSecretValue :: IO Text
readSecretValue = do
  isTty <- hIsTerminalDevice stdin
  if isTty
    then do
      TIO.hPutStr stderr "Value (input hidden): "
      hFlush stderr
      bracket_
        (hSetEcho stdin False)
        (hSetEcho stdin True >> TIO.hPutStrLn stderr "")
        TIO.getLine
    else do
      raw <- TIO.getContents
      pure (fromMaybe raw (T.stripSuffix "\n" raw))

tShow :: (Show a) => a -> Text
tShow = T.pack . show

-- ---------------------------------------------------------------------------
-- Shared helpers

-- | Assemble the runtime-agnostic 'DeployInputs' from the @site deploy@ options.
siteDeployInputs :: SiteDeployOpts -> StaticSite -> Text -> Text -> DeployInputs
siteDeployInputs sopts site imageTag bd =
  DeployInputs
    { site = site
    , imageTag = imageTag
    , baseDomain = bd
    , projectDir = sopts ^. #projectDir
    , skipBuild = sopts ^. #skipBuild
    }

printStaticArtifacts :: ByteString -> ByteString -> [ByteString] -> Text -> IO ()
printStaticArtifacts nginxBytes svcBytes dmBytes url = do
  BC.putStrLn "--- Generated nginx.conf ---"
  BC.putStr nginxBytes
  BC.putStrLn "--- Knative Service manifest ---"
  BC.putStr svcBytes
  forM_ dmBytes $ \dm -> do
    BC.putStrLn "--- DomainMapping manifest ---"
    BC.putStr dm
  TIO.putStrLn ("URL: " <> url)

loadSiteOrDie :: FilePath -> IO StaticSite
loadSiteOrDie file = do
  esite <- Load.loadStaticSite file
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right s -> pure s

-- | Exit with a one-line error from a pure @Either Text@ validation.
orDie :: Either Text a -> IO a
orDie = either dieT pure

-- | Print a one-line @nagarectl:@ error to stderr and exit non-zero.
dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure

-- | Resolve the apps base domain: an explicit @--base-domain@ flag wins;
-- otherwise the resolved target profile's base domain (EP-62; honors
-- @NAGARE_BASE_DOMAIN@, default @"apps.example.com"@).
resolveBaseDomain :: Maybe String -> IO Text
resolveBaseDomain (Just bd) = pure (T.pack bd)
resolveBaseDomain Nothing = tpBaseDomain <$> resolveTargetProfile

-- | Ensure the loader's child @runghc@ can resolve the @nagare-dsl@ package by
-- exporting a GHC package-environment file as @GHC_ENVIRONMENT@. Precedence
-- (EP-6 M1): the @--ghc-env@ flag > the @NAGARE_GHC_ENVIRONMENT@ env var >
-- the project's auto-discovered @.ghc.environment.*@ file. When none is found,
-- do nothing (the loader then fails with its existing, clear compile error).
provisionGhcEnv :: Maybe FilePath -> IO ()
provisionGhcEnv mflag = do
  menv <- lookupEnv "NAGARE_GHC_ENVIRONMENT"
  case mflag <|> menv of
    Just p -> do
      abs' <- makeAbsolute p
      setEnv "GHC_ENVIRONMENT" abs'
    Nothing -> do
      mfile <- resolveProjectGhcEnv
      case mfile of
        Just f -> setEnv "GHC_ENVIRONMENT" f -- already absolute
        Nothing -> pure ()
