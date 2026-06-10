{-# LANGUAGE PackageImports #-}

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

import Nagare.Dsl.Prelude

import "generic-lens" Data.Generics.Labels ()

import Control.Exception (bracket_)
import Control.Monad (forM, forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Options.Applicative
import Data.Maybe (catMaybes)
import System.Directory (doesFileExist, makeAbsolute)
import System.Environment (lookupEnv, setEnv)
import System.Exit (ExitCode (ExitFailure), exitFailure, exitWith)
import System.IO (hFlush, hSetEcho, hIsTerminalDevice, stderr, stdin)

import Nagare.Build (addBuildArgs, applyBuildOverrides, describeBuild, performBuild)
import Nagare.Deploy (applyManifests, applyPVCs, pvcPhases, serviceUrl, waitForReady)
import Nagare.Dsl.Build (BuildSpec, requiresBuild, resolveImageTag)
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Render (pvcName, renderDomainMappings, renderService, renderVolumeClaims, scopeToken)
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Render (StaticDeployContext (..))
import Nagare.Dsl.Static.Types (StaticSite, siteNameText)
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
import Nagare.App.Deployments
  ( formatDeploymentsTable
  , readDeployments
  , recordDeploymentFor
  , resolveRevisionForTag
  )
import Nagare.Dsl.Types
  ( Deployment
  , EnvScope (..)
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
import Nagare.Image
  ( computeTag
  , configureDockerAuth
  , imageRef
  , pushImage
  )
import Nagare.Ops.Doctor (doctorExitOk, formatDoctor, gradeChecks)
import Nagare.Ops.Domains
  ( DomainRow (..)
  , DnsExpectation (..)
  , CertState (..)
  , formatDomainList
  , listNamespaces
  , queryDomainRows
  )
import Nagare.Ops.Probe (InventoryOpts (..), renderInventory)
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Ops.Status (defaultInventoryOpts, gatherInventory)
import Nagare.Static.Deploy
  ( DeployInputs (..)
  , StaticManifests (..)
  , deployStaticPreview
  , deployStaticProduction
  , previewManifests
  , productionManifests
  )
import Nagare.Server.Deploy
  ( ServerDeployInputs (..)
  , ServerManifests (..)
  , deployServerProduction
  , serverManifests
  , serverUrl
  )
import Nagare.Static.Preview (deletePreview, listPreviews, previewDomain, previewServiceName)
import Nagare.Storage.Inspect (runStorageInspect)
import Nagare.Storage.List (runStorageList)
import Nagare.Storage.Snapshot (backupExcludedWarnings, runSnapshot)
import Nagare.Static.Release
  ( StaticReleaseLog (..)
  , findRelease
  , formatReleasesTable
  , readReleaseLog
  , writeReleaseLog
  )

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
  | DeploymentsList DepListOpts
  | DeploymentsLogs DepLogsOpts
  | Storage StorageCommand
  | ServerStatus ServerStatusOpts
  | Doctor DoctorOpts
  | Domains DomainsCommand

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
  = EnvList StoreCommonOpts Bool -- ^ Bool = --all (show all three scopes)
  | EnvSet StoreCommonOpts ScopeSelection Bool String String -- ^ dryRun, KEY, VALUE
  | EnvDelete StoreCommonOpts ScopeSelection Bool String -- ^ dryRun, KEY
  | EnvSync StoreCommonOpts ScopeSelection Bool Bool FilePath -- ^ dryRun, reconcileExact, dotenv file

-- | The @secret@ subcommands. @SecretSet@'s value is read from stdin, never argv.
data SecretCommand
  = SecretSet StoreCommonOpts ScopeSelection Bool String -- ^ dryRun, KEY (value from stdin)
  | SecretList StoreCommonOpts Bool -- ^ Bool = --all
  | SecretDelete StoreCommonOpts ScopeSelection Bool String -- ^ dryRun, KEY

-- | The @storage@ subcommands (EP-35). Both reuse 'StoreCommonOpts' (positional
-- APP + @-f@ config + @--ghc-env@); identity and the declared volume set come
-- from the loaded config. 'StorageInspect' adds a positional @VOLUME@. EP-36
-- extends this with a @StorageSnapshot@ constructor (Integration Point IP5).
data StorageCommand
  = StorageList StoreCommonOpts
  | StorageInspect StoreCommonOpts String -- ^ VOLUME
  | StorageSnapshot StoreCommonOpts String (Maybe String) Int -- ^ VOLUME, --bucket, --keep (EP-36)

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
            <> command "server" serverCmd
            <> command "doctor" doctorCmd
            <> command "domains" domainsCmd
        )
    doctorCmd =
      info
        (Doctor <$> doctorOptsParser <**> helper)
        (fullDesc <> progDesc "Health-check the platform and print remediation hints (exit 1 on any FAIL)")
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
                                        <> help "GCS backup bucket (overrides NAGARE_BACKUP_BUCKET, default tan-nb-exp-nagare-backups)"
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
    DeploymentsList o -> runDeploymentsList o
    DeploymentsLogs o -> runDeploymentsLogs o
    Storage scmd -> runStorage scmd
    ServerStatus o -> runServerStatus o
    Doctor o -> runDoctor o
    Domains (DomainsList o) -> runDomainsList o

-- | @server status@: gather the platform inventory and print the aligned
-- report. Read-only and always exits 0 — graceful degradation is the probes'
-- job, so a probe whose source is unreachable shows as @UNKNOWN@/@WARN@ rather
-- than aborting the command (script-friendly exit codes belong to EP-39's
-- @doctor@).
runServerStatus :: ServerStatusOpts -> IO ()
runServerStatus o = do
  let invOpts = defaultInventoryOpts {ioSkipVm = ssSkipVm o}
  probes <- gatherInventory invOpts
  TIO.putStr (renderInventory probes)

-- | @doctor@: gather EP-38's probes, re-grade them into a remediation checklist,
-- print it, and exit non-zero iff any check FAILs. Read-only and advisory —
-- every remediation is printed text the operator runs themselves
-- ('gatherInventory' degrades unreachable sources to @UNKNOWN@, so the report is
-- always printed; only the exit code varies).
runDoctor :: DoctorOpts -> IO ()
runDoctor o = do
  let invOpts = defaultInventoryOpts {ioSkipVm = dSkipVm o}
  probes <- gatherInventory invOpts
  let checks = gradeChecks probes
  TIO.putStr (formatDoctor checks)
  unless (doctorExitOk checks) (exitWith (ExitFailure 1))

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

runDeploy :: DeployOpts -> IO ()
runDeploy dopts = do
  bd <- resolveBaseDomain (dopts ^. #baseDomain)
  provisionGhcEnv (dopts ^. #ghcEnv)

  edep <- Load.loadDeployment (dopts ^. #file)
  dep <- case edep of
    Left err -> dieT (Load.renderLoadError err)
    Right d -> pure d

  imageTag <- resolveTag (dopts ^. #tag)
  spec <- resolveBuildSpec dopts (dep ^. #build)

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
      dep' = dep & #env %~ mergeGenerated (generatedEnv gctx)

  let effTag = resolveImageTag spec imageTag
      ref = imageRef dep' effTag
      pvcBytes = renderVolumeClaims dep' -- EP-35: [] when the app declares no volumes
      svcBytes = renderService dep' imageTag -- renderer resolves the tag itself
      dmBytes = renderDomainMappings dep'
      name = serviceNameText (dep' ^. #name)
      ns = namespaceText (dep' ^. #namespace)

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
      TIO.putStrLn ("Build mode: " <> describeBuild spec)
      TIO.putStrLn ("URL: " <> url)
    else do
      if requiresBuild spec
        then do
          -- EP-27: gather the app's Build-scoped env (inline {Build} + the managed
          -- Build store) and pass it to docker build as --build-arg flags. Done only
          -- when actually building (Build-scoped env never reaches the runtime container).
          (bargs, warns) <- gatherBuildArgs name ns (dep ^. #env)
          printBuildArgWarnings warns
          configureDockerAuth
          performBuild (addBuildArgs bargs spec) ref
          pushImage ref
        else TIO.putStrLn "Skipping build/push: deploying prebuilt image."
      -- EP-35: apply the PVCs first (no-op when empty), then the Service. Never a
      -- pre-Service Bound wait (local-path is WaitForFirstConsumer; that deadlocks).
      applyPVCs pvcBytes
      applyManifests (svcBytes : dmBytes)
      waitForReady name ns
      reportPVCs ns dep'
      -- EP-31: record the deployment in the per-app history ConfigMap. The
      -- deployment id is the resolved image tag (= NAGARE_RELEASE_ID, = --tag).
      -- Non-fatal: a failed history write must not fail a successful deploy.
      rec <- recordDeploymentFor (imageRefText (dep ^. #image)) imageTag url name ns srcText
      case rec of
        Left warn -> TIO.hPutStrLn stderr ("nagarectl: " <> warn)
        Right () -> pure ()
      TIO.putStrLn ("Deployed: " <> url)

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

-- | Apply the @--context@/@--dockerfile@ overrides to the config's build spec,
-- exiting with a clear error if an override is invalid or misused (e.g. an
-- override against a prebuilt-image config). With no overrides the spec is
-- returned unchanged.
resolveBuildSpec :: DeployOpts -> BuildSpec -> IO BuildSpec
resolveBuildSpec dopts spec =
  orDie (applyBuildOverrides (dopts ^. #contextOverride) (dopts ^. #dockerfileOverride) spec)

-- | Deploy a site (EP-14/EP-15/EP-18). Dispatches on the config's @kind@: a
-- @StaticSite@ runs the Nginx path, a @ServerSite@ runs the Node path. Both share
-- the same CLI options and record a release on success.
runSiteDeploy :: SiteDeployOpts -> IO ()
runSiteDeploy sopts = do
  bd <- resolveBaseDomain (sopts ^. #baseDomain)
  provisionGhcEnv (sopts ^. #ghcEnv)
  esite <- Load.loadSite (sopts ^. #file)
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right (Load.SiteStatic s) -> deployStatic sopts s bd
    Right (Load.SiteServer s) -> deployServer sopts s bd

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
  if sopts ^. #dryRun
    then do
      printStaticArtifacts (m ^. #nginxConf) (m ^. #service) (m ^. #domainMappings) (m ^. #url)
      TIO.putStrLn ("Release: " <> imageTag)
    else do
      result <- deployStaticProduction inputs (T.pack <$> sopts ^. #source)
      case result of
        Left err -> dieT err
        Right u -> TIO.putStrLn ("Deployed static site: " <> u)

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
    else do
      result <- deployServerProduction inputs (T.pack <$> sopts ^. #source)
      case result of
        Left err -> dieT err
        Right u -> TIO.putStrLn ("Deployed server site: " <> u)

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
    b <- resolveBackupBucket bucket
    runSnapshot dep (T.pack vol) b keep

-- | Resolve the GCS backup bucket: @--bucket@, then @NAGARE_BACKUP_BUCKET@,
-- defaulting to @tan-nb-exp-nagare-backups@ (the Pulumi @backupBucket@ output).
resolveBackupBucket :: Maybe String -> IO Text
resolveBackupBucket (Just b) = pure (T.pack b)
resolveBackupBucket Nothing = do
  menv <- lookupEnv "NAGARE_BACKUP_BUCKET"
  pure (maybe "tan-nb-exp-nagare-backups" T.pack menv)

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

resolveTag :: Maybe String -> IO Text
resolveTag (Just t) = pure (T.pack t)
resolveTag Nothing = computeTag

-- | Exit with a one-line error from a pure @Either Text@ validation.
orDie :: Either Text a -> IO a
orDie = either dieT pure

-- | Print a one-line @nagarectl:@ error to stderr and exit non-zero.
dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure

-- | Resolve the apps base domain from @--base-domain@, then
-- @NAGARE_BASE_DOMAIN@, defaulting to @"apps.example.com"@.
resolveBaseDomain :: Maybe String -> IO Text
resolveBaseDomain (Just bd) = pure (T.pack bd)
resolveBaseDomain Nothing = do
  menv <- lookupEnv "NAGARE_BASE_DOMAIN"
  pure $ maybe "apps.example.com" T.pack menv

-- | If a GHC package-environment file is given (via @--ghc-env@ or
-- @NAGARE_GHC_ENVIRONMENT@), export it as @GHC_ENVIRONMENT@ (absolute) so the
-- loader's child @runghc@ resolves the @nagare-dsl@ package.
provisionGhcEnv :: Maybe FilePath -> IO ()
provisionGhcEnv mflag = do
  menv <- lookupEnv "NAGARE_GHC_ENVIRONMENT"
  case mflag <|> menv of
    Nothing -> pure ()
    Just p -> do
      abs' <- makeAbsolute p
      setEnv "GHC_ENVIRONMENT" abs'
