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

import Control.Applicative ((<|>))
import Control.Exception (IOException, bracket, bracket_, catch, try)
import Control.Monad (forM, forM_, unless, void)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as AesonMap
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Char (isAlphaNum)
import Data.Generics.Labels ()
import Data.List (find, sort)
import Data.List.NonEmpty qualified as NE
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import GHC.IO.Encoding (setLocaleEncoding)
import Nagare.Access.Grants (AccessGrantParams (..), AccessListParams (..), runAccessGrant, runAccessList, runAccessRevoke)
import Nagare.Access.Resolve
  ( ShomeiPortalChange (EnablePortal)
  , kubectlAccessOps
  , mkBaseDomain
  , portalRegistration
  , publicHostText
  , resolveDeploymentAccess
  )
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
import Nagare.App.Deploy (AppDeployParams (..), RolloutEnv (..), resolveAppRolloutWithBrokerEnv, runAppDeployWithGuard)
import Nagare.App.Deployments
  ( appConfigMapName
  , formatDeploymentsTable
  , readDeployments
  , recordDeploymentFor
  , resolveRevisionForTag
  )
import Nagare.Broker.Create (BrokerCreateParams (..), resolveBroker, runBrokerCreateWithGuard)
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
  , googleCdnHostname
  , planCdn
  , provisionCdn
  , renderCdnPlan
  )
import Nagare.Cdn.Status
  ( CdnDnsTarget (..)
  , CdnRow (..)
  , formatCdnList
  , formatCdnStatus
  , formatCertificateManagerStatus
  , parseCertificateManagerState
  , queryCdnRows
  )
import Nagare.Cluster.CertificateMigration qualified as CertificateMigration
import Nagare.Cluster.CertificatePolicy (parseLabeledNamespaces)
import Nagare.Cluster.GcsJob (StoreBackend (..))
import Nagare.Cluster.Kubeconfig
  ( KubeconfigIdentity (..)
  , defaultFetchOps
  , fetchKubeconfig
  , kubeconfigPath
  )
import Nagare.Cluster.Namespace (NamespacePurpose (..), ensureNamespace, renderNamespace)
import Nagare.Database.Backup (runDbBackup)
import Nagare.Database.Connection (connectionEnv, mergeConnectionEnvs)
import Nagare.Database.Create (DbCreateParams (..), resolveDatabase, runDbCreateWithGuard)
import Nagare.Database.Delete (DbDeleteParams (..), runDbDelete)
import Nagare.Database.Discover (lookupConnection)
import Nagare.Database.Get (runDbGet)
import Nagare.Database.List (runDbList)
import Nagare.Database.Restart (runDbRestart)
import Nagare.Database.Restore (runDbRestore)
import Nagare.Database.Shell (runDbShell)
import Nagare.Deploy (applyManifests, applyPVCs, pvcPhases, requireWait, serviceUrl, waitForReady)
import Nagare.Deploy.Resolve (resolveBrokerEnv, resolveBuildSpec, resolveConnectionEnv, resolveTag)
import Nagare.Domain.Binding
  ( BindingTarget (..)
  , preflightDomainBindings
  , renderBindingTarget
  , waitForDomainBindings
  )
import Nagare.Domain.Tls (preflightDomainTls, renderDomainTlsCheck, verifyDomainTlsReady)
import Nagare.Dsl.Application (Application (..))
import Nagare.Dsl.Broker (BrokerProvider (..), brokerNameText)
import Nagare.Dsl.Build (BuildSpec, requiresBuild, resolveImageTag)
import Nagare.Dsl.Cdn.Types (Cdn)
import Nagare.Dsl.Database (Database (..), Engine (..), dbSecretName)
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (managedConfigMapName, managedSecretName, pvcName, renderDomainMappings, renderService, renderVolumeClaims, scopeToken)
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Render (StaticDeployContext (..))
import Nagare.Dsl.Static.Types (StaticSite, siteNameText)
import Nagare.Dsl.Task (taskResourceName)
import Nagare.Dsl.Types
  ( DatabaseName
  , Deployment
  , DomainSpec
  , EnvName
  , EnvScope (..)
  , Namespace
  , ScopedEnvVar
  , databaseNameText
  , namespaceText
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
  , renderEnvSecretPreview
  , writeEnvStore
  , writeSecretStore
  )
import Nagare.Gcp.Adc
  ( AdcError
  , AdcObservation
  , adcEnvFromProcess
  , adcEvidenceValue
  , observeAdc
  , validateAdc
  )
import Nagare.GhcEnv (resolveProjectGhcEnv)
import Nagare.Host.AgeKey (placeAgeKeyWith)
import Nagare.Host.Config
  ( HostConfig (..)
  , HostInstallResult (..)
  , commitStagedHostFlake
  , defaultHostName
  , findHostNameCollision
  , hostConfigDir
  , hostSwitchEnvironment
  , hostSwitchIdentity
  , installHostFlake
  , readAuthorizedKeys
  , readContextHostName
  , readStagedHostName
  , renderHostFlake
  , renderHostModule
  , renderHostSummary
  , stageHostFlake
  )
import Nagare.Image
  ( computeTag
  , configureDockerAuthFor
  , imageRef
  , pushImage
  , qualifyImage
  )
import Nagare.Infra.Plan
  ( CurrentInfraIdentity (..)
  , PlanVerdict (..)
  , SavedPlanMetadata (..)
  , SavedPlanReview (..)
  , classifyPlan
  , digestFile
  , digestPulumiProgram
  , parsePreview
  , previewErrors
  , protectedResourceTypes
  , renderPlanBindingError
  , renderVerdict
  , reviewVerdict
  , verifySavedPlan
  )
import Nagare.Init
  ( InitOpts (..)
  , WriteResult (..)
  , checkInitOwnership
  , enableApis
  , findMissingTools
  , initContextMap
  , initFlagPairs
  , nextStepsText
  , profileFromOpts
  , renderInitSummary
  , renderTargetEnv
  , requiredApis
  , requiredInitTools
  , resolveInitBase
  , runPreflight
  , seedPulumiConfig
  , writeTargetEnv
  )
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Inventory.Adapters.Artifact (mkArtifactAdapter)
import Nagare.Inventory.Adapters.ArtifactRuntime
import Nagare.Inventory.Adapters.Broker (TopicBinding, mkTopicAdapter, topicSpecsFromDeclarations)
import Nagare.Inventory.Adapters.BrokerRuntime qualified as BrokerRuntime
import Nagare.Inventory.Adapters.Cache (cacheSpecsFromDeclarations, mkCacheAdapter)
import Nagare.Inventory.Adapters.CacheRuntime qualified as CacheRuntime
import Nagare.Inventory.Adapters.Host (mkHostAdapter)
import Nagare.Inventory.Adapters.HostRuntime
import Nagare.Inventory.Adapters.Helm (HelmAdapterOps (..), helmStateHealth, mkHelmAdapter)
import Nagare.Inventory.Adapters.HelmRuntime (HelmRuntimeConfig (..), helmRuntimeOps)
import Nagare.Inventory.Adapters.Kubernetes (mkKubernetesAdapter)
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..), mkKubernetesRuntimeOpsWithCacheKey, observeKubernetesHealth)
import Nagare.Inventory.Adapters.Pulumi (mkPulumiAdapter)
import Nagare.Inventory.Adapters.PulumiRuntime
import Nagare.Inventory.Artifact qualified as InventoryArtifact
import Nagare.Inventory.Artifact (ArtifactDeclarationBundle (..), ArtifactResourceSpec (..))
import Nagare.Inventory.Bootstrap (BootstrapInput (..), compileBootstrapStamp, compileBootstrapWithAuthAndScopes)
import Nagare.Inventory.Cloud qualified as InventoryCloud
import Nagare.Inventory.Components.Foundation (FoundationInput (..), compileContributedNamespaces)
import Nagare.Inventory.BackendMap (compileContributedBackendMaps, compileContributedShomeiSettings)
import Nagare.Inventory.Components.Auth (AuthInput (..), AuthMode (..))
import Nagare.Inventory.Components.ControllerImage (compileControllerImage, inspectArchive)
import Nagare.Inventory.Components.LocalObjectStore (compileLocalObjectStore)
import Nagare.Inventory.Components.Observability (PackagedHelmInput (..), pinnedObservabilityInputs, compilePinnedObservability)
import Nagare.Inventory.Components.ObservabilityExtras (compileObservabilityExtras)
import Nagare.Inventory.Components.ObservabilitySecrets (compileObservabilitySecrets, loadObservabilitySecretObjects, readAlertmanagerEnabled)
import Nagare.Inventory.Components.PackagedAuth (packagedAuthInputs)
import Nagare.Inventory.Components.PackagedCache (compilePackagedCache)
import Nagare.Inventory.Components.Upstream (IssuerMode (..), bindNetCertManagerControllerImage, configuredUpstreamInputsWithIssuer)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Application (ApplicationScopeInput (..), DatabaseBinding, acceptedAccessBinding, acceptedApplicationImage, acceptedApplicationReleaseLog, acceptedBrokerBindings, acceptedDatabaseBindings, acceptedSecretBindings, acceptedStandaloneReleaseLog, applicationNativeOwned, applicationRetirementScope, applicationVolumeRecoveryBindings, compileApplicationScope, compileStandaloneServiceWithRelease, compileStandaloneWorkerWithDependencies, databaseRecoveryBindings, legacyApplicationReleaseImport, legacyStandaloneReleaseImport, nativeWorkloadOwned, reviewedTaskImages, standaloneWorkerVolumeRecoveryBindings, workerRetirementScope)
import Nagare.Inventory.Site (acceptedStaticSiteReleaseLog, compileStaticSiteScope, legacyStaticSiteReleaseImport)
import Nagare.Inventory.Lifecycle qualified as InventoryLifecycle
import Nagare.Inventory.DataService (acceptedFoundationNamespace, brokerNativeOwned, compileStandaloneBroker, compileStandaloneDatabase, databaseNativeOwned, standaloneRetirementScope, standaloneStatefulSetOwned)
import Nagare.Inventory.Environment (acceptedEnvChannelValues, acceptedSecretChannelValues, compileBuildEnvChannel, compileBuildSecretChannel, compilePreviewEnvChannel, compilePreviewSecretChannel, compileRuntimeEnvChannel, compileRuntimeSecretChannel, validateSecretRotation)
import Nagare.Inventory.Host qualified as InventoryHost
import Nagare.Inventory.HelmReview (helmSpecsFromReview)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.KubernetesSources (loadKubernetesSources, validateSuppliedKubernetesMembers)
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Ops.Cleanup
  ( CleanupOpts (..)
  , defaultKeepReleases
  , defaultPreviewTtlDays
  , executeCleanup
  , formatCleanupReport
  )
import Nagare.Ops.ClusterGuard
  ( clusterGuardObservationsValue
  , clusterGuardVerdict
  , defaultClusterGuardOps
  , observeClusterGuard
  , renderClusterGuard
  )
import Nagare.Ops.ContextGuard
  ( ProjectGuardInputs (..)
  , PulumiProjectObservation (..)
  , parsePulumiProjectConfig
  , projectGuardObservationsValue
  , projectGuardVerdict
  , renderProjectGuard
  )
import Nagare.Ops.Doctor (doctorExitOk, formatDoctor, gradeChecksAt)
import Nagare.Ops.Domains
  ( CertificateState (..)
  , DnsExpectation (..)
  , DomainRow (..)
  , Observation (..)
  , domainCheckFailures
  , domainReportValue
  , formatDomainList
  , listNamespaces
  , observeNamespaces
  , queryBaseDomainRow
  , queryDomainRows
  )
import Nagare.Ops.Probe (InventoryOpts (..), Probe (..), ProbeStatus (..), captureTool, renderInventory)
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Ops.PulumiBackend (bootstrapPulumiStateBucket)
import Nagare.Ops.Status (gatherInventory, inventoryOptsFor, probeCertificatePolicy)
import Nagare.Platform.Deployment
  ( DeploymentState (..)
  , defaultDeploymentOps
  , observeHostDeployment
  )
import Nagare.Platform.Paths
  ( PlatformPaths (..)
  , PlatformRootSource (..)
  , platformRootSourceToken
  , renderPlatformPathError
  , resolvePlatformPaths
  , validatePlatformRoot
  )
import Nagare.Platform.PulumiReceipt
  ( PulumiApplyReceipt (..)
  , PulumiReceiptState (..)
  , PulumiRecoveryOutcome (..)
  , pulumiReceiptPath
  , readVerifiedPulumiReceipt
  , renderPulumiReceiptEvidence
  , writeRecoveryReceipt
  , writeResultReceipt
  , writeStartedReceipt
  )
import Nagare.Platform.StackConfig (contextStackConfigPath, linkContextStackConfig)
import Nagare.Platform.Status
  ( PlatformStatus (..)
  , ReleaseIdentity (..)
  , assessPlatformStatus
  , clusterMarkerValue
  , guardPlatformMutation
  , identityFromBuild
  , identityFromContext
  , identityFromPayload
  , parseClusterIdentity
  , parseHostIdentity
  , platformProbe
  , platformStatusValue
  , renderPlatformStatus
  , validatePlatformAdoption
  , validatePlatformRepin
  )
import Nagare.Platform.Upgrade
  ( PhaseState (..)
  , ResumeDecision (..)
  , TransactionState (..)
  , UpgradeOps (..)
  , UpgradePhase (..)
  , UpgradeTransaction (..)
  , applyUpgrade
  , newUpgradeTransaction
  , phaseToken
  , planUpgrade
  , readUpgradeTransaction
  , recordUpgradePhase
  , renderUpgradeTransaction
  , writeUpgradeTransaction
  )
import Nagare.Platform.Workspace
  ( PayloadManifest (..)
  , PlatformWorkspace (..)
  , findPlatformWorkspace
  , preparePlatformWorkspace
  , readPayloadManifest
  , renderWorkspaceError
  )
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Policy qualified as ResourcePolicy
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Application qualified as ResourceApplication
import Nagare.Resource.Wire qualified as ResourceWire
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
  ( StaticRelease (..)
  , StaticReleaseLog (..)
  , findRelease
  , formatReleasesTable
  , readReleaseLog
  , writeReleaseLog
  )
import Nagare.Storage.Inspect (runStorageInspect)
import Nagare.Storage.List (runStorageList)
import Nagare.Storage.Restore (runStorageRestore)
import Nagare.Storage.Snapshot (backupExcludedWarnings, runSnapshot)
import Nagare.Target
  ( AcmeDirectory (..)
  , ActiveTarget (..)
  , ContextName
  , Mode (..)
  , PulumiBackendKind (..)
  , InventoryStoreKind (..)
  , PulumiEnv (..)
  , TargetProfile (..)
  , VmShape (..)
  , acmeDirectoryToken
  , acmeDirectoryUrl
  , clearCurrentContext
  , contextExists
  , contextFilePath
  , contextNameText
  , defaultGcsInventoryStoreUrl
  , contextsDir
  , deleteContext
  , effectivePulumiBackend
  , effectiveInventoryStore
  , inventoryStoreToken
  , listContexts
  , mergeContextOverrides
  , mkContextName
  , nagareStateDir
  , parseAcmeDirectory
  , parsePulumiBackendKind
  , parseInventoryStoreKind
  , profileFromContextMap
  , pulumiBackendToken
  , pulumiEnvFor
  , readContextMap
  , readContextProfile
  , readCurrentContext
  , registryPrefix
  , renderContextShellEnv
  , resolveActiveContext
  , resolveActiveTarget
  , setCurrentContext
  , storeBackendFor
  , validateAcmeEmail
  , validateNixCacheMode
  , validateVmShape
  , vmShapeOf
  , writeContextPlatformVersion
  , writeContextInventoryStore
  )
import Nagare.Task.Delete (TaskDeleteParams (..), runTaskDelete)
import Nagare.Task.Discover (AppScope (..))
import Nagare.Task.List (runTaskList)
import Nagare.Task.Logs (TaskLogTarget (..), runTaskLogs)
import Nagare.Task.Resolve (predefinedTaskEnv, renderResolvedTask)
import Nagare.Task.Run (TaskRunParams (..), runTaskRun)
import Nagare.Version
  ( BuildVersion (..)
  , VersionError (..)
  , compatibilityToken
  , currentBuildVersion
  , parsePlatformVersion
  , renderBuildVersionJson
  , renderBuildVersionJsonWithTools
  , renderBuildVersionText
  , renderPlatformVersion
  )
import Nagare.Worker.Deploy (WorkerDeployParams (..), runWorkerDeployWithGuard)
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, doesPathExist, findExecutable, listDirectory, makeAbsolute, pathIsSymbolicLink, removeDirectoryRecursive, renameDirectory)
import System.Environment (getEnvironment, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitFailure, exitWith)
import System.FilePath (dropExtension, takeBaseName, takeDirectory, takeExtension, (</>))
import System.IO (hFlush, hIsTerminalDevice, hSetEcho, hSetEncoding, stderr, stdin, stdout, utf8)
import System.IO.Temp (createTempDirectory, withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, isDirectory, isRegularFile, setFileMode)
import System.Process
  ( CreateProcess (cwd, env)
  , proc
  , readCreateProcessWithExitCode
  , readProcessWithExitCode
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
  , savePlan :: !FilePath
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
  , databaseRecovery :: ![String]
  , tlsSecretResources :: ![String]
  , envSecretResources :: ![String]
  , serviceVolumeRecovery :: ![String]
  , workerVolumeRecovery :: ![String]
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
  | PortalSync
  deriving stock (Generic, Show)

data AccessGrantOpts = AccessGrantOpts
  { enUrl :: !(Maybe String)
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
  | InventoryCompile FilePath FilePath Bool
  | InventoryPlan FilePath FilePath
  | InventoryAdopt FilePath FilePath
  | InventoryMigrate FilePath FilePath
  | InventoryRetire String FilePath
  | InventoryGc FilePath
  | InventoryCollect (NE.NonEmpty String) FilePath
  | InventoryApply FilePath Bool
  | InventoryResume String Bool Bool
  | InventoryRecover String String FilePath Bool
  | InventoryExport FilePath
  | InventoryStatus Bool
  | InventoryExplain String Bool
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
  deriving stock (Generic, Show)

data KubeconfigCommand
  = KubeconfigFetch KubeconfigFetchOpts
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
  | ContextDelete String Bool
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
  }
  deriving stock (Generic, Show)

data InfraCommand
  = InfraGuard Bool
  | InfraPreview InfraPreviewOpts
  | InfraApply InfraApplyOpts
  | InfraDestroy Bool
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
  | -- | dryRun, KEY, VALUE, reviewed plan directory
    EnvSet StoreCommonOpts ScopeSelection Bool String String (Maybe FilePath)
  | -- | dryRun, KEY, reviewed plan directory
    EnvDelete StoreCommonOpts ScopeSelection Bool String (Maybe FilePath)
  | -- | dryRun, reconcileExact, dotenv file, reviewed plan directory
    EnvSync StoreCommonOpts ScopeSelection Bool Bool FilePath (Maybe FilePath)
  deriving stock (Generic, Show)

-- | The @secret@ subcommands. @SecretSet@'s value is read from stdin, never argv.
data SecretCommand
  = -- | dryRun, KEY (value from stdin), rotation version, reviewed plan directory
    SecretSet StoreCommonOpts ScopeSelection Bool String (Maybe String) (Maybe FilePath)
  | -- | Bool = --all
    SecretList StoreCommonOpts Bool
  | -- | dryRun, KEY, rotation version, reviewed plan directory
    SecretDelete StoreCommonOpts ScopeSelection Bool String (Maybe String) (Maybe FilePath)
  | -- | exact Runtime or Build dotenv file, opaque rotation version, reviewed plan directory
    SecretSync StoreCommonOpts ScopeSelection FilePath String FilePath
  deriving stock (Generic, Show)

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
  | -- | nagarectl db get NAME [-n NS]
    DbGet DbNameOpts
  | -- | nagarectl db shell NAME [-n NS]
    DbShell DbNameOpts
  | -- | nagarectl db restart NAME [-n NS] [--dry-run]
    DbRestart DbNameOpts Bool
  | -- | nagarectl db delete NAME [-n NS] [--yes] [--dry-run]
    DbDelete DbDeleteOpts
  | -- | nagarectl db retire NAME [-n NS] --save-plan DIR
    DbRetire StandaloneRetireOpts
  | -- | nagarectl db backup NAME [-n NS] [--bucket B] [--keep N] [--dry-run] (EP-47)
    DbBackup DbBackupOpts
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
    BrokerRestart BrokerNameOpts Bool
  | -- | nagarectl broker delete NAME [-n NS] [--yes] [--dry-run]
    BrokerDelete BrokerDeleteOpts
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
  | -- | nagarectl task delete APP TASK [-n NS] [--yes] [--dry-run]
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

-- | Options for @db delete NAME@: namespace, the --yes guard, and --dry-run.
data DbDeleteOpts = DbDeleteOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , yes :: !Bool
  , dryRun :: !Bool
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

-- | Options for @db backup NAME@ (EP-47): namespace, --bucket, --keep, --dry-run.
data DbBackupOpts = DbBackupOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , bucket :: !(Maybe String)
  , keep :: !Int
  , dryRun :: !Bool
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
  { skipVm :: !Bool
  }
  deriving stock (Generic, Show)

serverStatusOptsParser :: Parser ServerStatusOpts
serverStatusOptsParser =
  ServerStatusOpts
    <$> switch (long "skip-vm" <> help "Skip the IAP-SSH disk probe (no SSH setup needed)")

-- | Options for @doctor@ (MasterPlan 8, EP-39). Reuses the same inventory knob
-- as @server status@: @--skip-vm@ skips the best-effort IAP-SSH disk probe.
data DoctorOpts = DoctorOpts
  { skipVm :: !Bool
  }
  deriving stock (Generic, Show)

doctorOptsParser :: Parser DoctorOpts
doctorOptsParser =
  DoctorOpts
    <$> switch (long "skip-vm" <> help "Skip the IAP-SSH disk probe (no SSH setup needed)")

-- | Options for @init@ (MasterPlan 12, EP-63). Target flags are optional
-- so an absent flag prompts on a TTY (or errors non-interactively); the skip/force
-- flags exist for CI and partial recovery.
initOptsParser :: Parser InitOpts
initOptsParser =
  InitOpts
    <$> optional (strArgument (metavar "NAME" <> help "Context name to create and make current (omit to write ./nagare.target.env)"))
    <*> optional (strOption (long "project" <> metavar "PROJECT_ID" <> help "GCP project id (prompted if absent on a TTY)"))
    <*> optional (strOption (long "region" <> metavar "REGION" <> help "Compute region (default us-west1)"))
    <*> optional (strOption (long "zone" <> metavar "ZONE" <> help "Compute zone (default us-west1-a)"))
    <*> optional (strOption (long "base-domain" <> metavar "DOMAIN" <> help "Apps base domain (default apps.example.com)"))
    <*> optional (flag' "1" (long "enable-external-tls" <> help "Enable reviewed cloud-domain TLS after DNS delegation") <|> flag' "0" (long "disable-external-tls" <> help "Disable cloud-domain TLS in the desired context profile"))
    <*> optional (strOption (long "machine-type" <> metavar "TYPE" <> help "GCE machine type (default e2-standard-2)"))
    <*> optional (strOption (long "boot-disk-type" <> metavar "TYPE" <> help "Boot disk type (default pd-balanced; changing a live VM replaces it)"))
    <*> optional (strOption (long "boot-disk-size-gb" <> metavar "GB" <> help "Boot disk size in GB (default 100; changing a live VM replaces it)"))
    <*> optional (strOption (long "data-disk-size-gb" <> metavar "GB" <> help "Data disk size in GB (default 100)"))
    <*> optional (flag' "1" (long "enable-nix-cache" <> help "Enable the cloud-only Attic binary cache") <|> flag' "0" (long "disable-nix-cache" <> help "Disable Attic without deleting retained resources"))
    <*> optional (strOption (long "nix-cache-bucket" <> metavar "BUCKET" <> help "Attic GCS bucket (default <project>-nagare-nix-cache)"))
    <*> optional (strOption (long "pulumi-backend" <> metavar "BACKEND" <> help "local | gcs Pulumi state backend (default local; gcs is cloud-only)"))
    <*> optional (strOption (long "pulumi-backend-url" <> metavar "GS_URL" <> help "Explicit gs://bucket/path backend URL (default gs://<project>-nagare-pulumi-state/nagare/<context>)"))
    <*> optional (strOption (long "inventory-store" <> metavar "STORE" <> help "local | gcs resource inventory history store (default local)"))
    <*> optional (strOption (long "inventory-store-url" <> metavar "GS_URL" <> help "Explicit gs://bucket/prefix inventory history URL"))
    <*> optional (strOption (long "pulumi-backend-member" <> metavar "PRINCIPAL" <> help "Grant this principal objectAdmin on the state bucket during bootstrap (not persisted)"))
    <*> optional (strOption (long "acme-email" <> metavar "ADDRESS" <> help "Let's Encrypt contact address for this context (REQUIRED; prompted if absent on a TTY)"))
    <*> optional (strOption (long "acme-directory" <> metavar "ENDPOINT" <> help "production | staging | https:// ACME directory URL (default production)"))
    <*> switch (long "force" <> help "Overwrite an existing nagare.target.env")
    <*> switch (long "skip-preflight" <> help "Skip the gcloud auth + operator-IAM checks")
    <*> switch (long "skip-enable" <> help "Skip running scripts/enable-apis.sh")
    <*> switch (long "skip-seed" <> help "Skip seeding the Pulumi stack config")
    <*> switch (long "dry-run" <> help "Show what would be written/enabled/seeded without doing it")

contextNameArg :: Parser String
contextNameArg = strArgument (metavar "NAME" <> help "Context name")

contextCreateOptsParser :: Parser ContextCreateOpts
contextCreateOptsParser =
  ContextCreateOpts
    <$> optional (strOption (long "project" <> metavar "PROJECT_ID" <> help "GCP project id"))
    <*> optional (strOption (long "region" <> metavar "REGION" <> help "Compute region (default us-west1)"))
    <*> optional (strOption (long "zone" <> metavar "ZONE" <> help "Compute zone (default us-west1-a)"))
    <*> optional (strOption (long "base-domain" <> metavar "DOMAIN" <> help "Apps base domain (default apps.example.com)"))
    <*> optional (flag' "1" (long "enable-external-tls" <> help "Enable reviewed cloud-domain TLS after DNS delegation") <|> flag' "0" (long "disable-external-tls" <> help "Disable cloud-domain TLS in the desired context profile"))
    <*> optional (strOption (long "machine-type" <> metavar "TYPE" <> help "GCE machine type (default e2-standard-2)"))
    <*> optional (strOption (long "boot-disk-type" <> metavar "TYPE" <> help "Boot disk type (default pd-balanced; changing a live VM replaces it)"))
    <*> optional (strOption (long "boot-disk-size-gb" <> metavar "GB" <> help "Boot disk size in GB (default 100; changing a live VM replaces it)"))
    <*> optional (strOption (long "data-disk-size-gb" <> metavar "GB" <> help "Data disk size in GB (default 100)"))
    <*> optional (strOption (long "registry-host" <> metavar "HOST" <> help "Artifact Registry host (default <region>-docker.pkg.dev)"))
    <*> optional (strOption (long "artifact-registry-id" <> metavar "ID" <> help "Artifact Registry repo id (default nagare)"))
    <*> optional (strOption (long "image-bucket" <> metavar "BUCKET" <> help "Image bucket (default <project>-nagare-images)"))
    <*> optional (strOption (long "backup-bucket" <> metavar "BUCKET" <> help "Backup bucket (default <project>-nagare-backups)"))
    <*> optional (flag' "1" (long "enable-nix-cache" <> help "Enable the cloud-only Attic binary cache") <|> flag' "0" (long "disable-nix-cache" <> help "Disable Attic without deleting retained resources"))
    <*> optional (strOption (long "nix-cache-bucket" <> metavar "BUCKET" <> help "Attic GCS bucket (default <project>-nagare-nix-cache)"))
    <*> optional (strOption (long "instance-name" <> metavar "NAME" <> help "VM instance name (default nagare-01)"))
    <*> optional (strOption (long "target-platform" <> metavar "PLATFORM" <> help "Docker build platform (default linux/amd64)"))
    <*> optional (strOption (long "mode" <> metavar "MODE" <> help "cloud | local (default cloud)"))
    <*> optional (strOption (long "local-object-store" <> metavar "URL" <> help "Local S3 endpoint/bucket (local mode only)"))
    <*> optional (strOption (long "pulumi-backend" <> metavar "BACKEND" <> help "local | gcs Pulumi state backend (default local; gcs is cloud-only)"))
    <*> optional (strOption (long "pulumi-backend-url" <> metavar "GS_URL" <> help "Explicit gs://bucket/path backend URL (default gs://<project>-nagare-pulumi-state/nagare/<context>)"))
    <*> optional (strOption (long "inventory-store" <> metavar "STORE" <> help "local | gcs resource inventory history store (default local)"))
    <*> optional (strOption (long "inventory-store-url" <> metavar "GS_URL" <> help "Explicit gs://bucket/prefix inventory history URL"))
    <*> optional (strOption (long "pulumi-backend-member" <> metavar "PRINCIPAL" <> help "Grant this principal objectAdmin on the state bucket during --use bootstrap (not persisted)"))
    <*> optional (strOption (long "acme-email" <> metavar "ADDRESS" <> help "Let's Encrypt contact address (no default; required to render the cluster issuer)"))
    <*> optional (strOption (long "acme-directory" <> metavar "ENDPOINT" <> help "production | staging | https:// ACME directory URL (default production)"))
    <*> switch (long "force" <> help "Update an existing context: passed flags change, every other stored field is kept")
    <*> switch (long "use" <> help "Also set this context as the current context")

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

domainsListOptsParser :: Parser DomainsListOpts
domainsListOptsParser =
  DomainsListOpts
    <$> namespaceOpt
    <*> switch (long "all-namespaces" <> help "List domains across all namespaces")
    <*> baseDomainOpt
    <*> switch (long "json" <> help "Emit versioned JSON instead of the human table")

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
  }
  deriving stock (Generic, Show)

data CdnDisableOpts = CdnDisableOpts
  { host :: !String
  , namespace :: !(Maybe String)
  , dryRun :: !Bool
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
          ( long "build-context"
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
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed single-Service inventory plan"))
    <*> optional (strOption (long "image-resource" <> metavar "RESOURCE-ID" <> help "Accepted OCI image for --save-plan"))
    <*> many (strOption (long "service-volume-recovery" <> metavar "VOLUME=BACKUP:KEY:VERSION" <> help "Retained Service PVC recovery for --save-plan"))
    <*> many (strOption (long "tls-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted supplied-TLS Secret for --save-plan"))
    <*> many (strOption (long "env-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted runtime Secret for --save-plan"))
    <*> optional (strOption (long "legacy-release-import" <> metavar "FILE" <> help "Legacy release ConfigMap JSON to preserve during exact reviewed adoption"))
    <*> optional (strOption (long "release-adoption-input" <> metavar "FILE" <> help "Versioned exact-incarnation adoption proposal for --legacy-release-import"))

appImagePlanOptsParser :: Parser AppImagePlanOpts
appImagePlanOptsParser =
  AppImagePlanOpts
    <$> strOption (long "archive" <> metavar "FILE" <> help "Docker archive to bind by SHA-256")
    <*> strOption (long "destination" <> metavar "IMAGE:TAG" <> help "Exact registry tag to publish")
    <*> strOption (long "key" <> metavar "KEY" <> help "Stable publication key")
    <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed image publication")

appDeployOptsParser :: FilePath -> Parser AppDeployOpts
appDeployOptsParser defaultFile =
  AppDeployOpts
    <$> fileOpt defaultFile
    <*> tagOpt
    <*> baseDomainOpt
    <*> optional
      ( strOption
          ( long "build-context"
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
    <*> optional
      (strOption (long "save-plan" <> metavar "FILE" <> help "Save a reviewed inventory plan for a prepublished-image application"))
    <*> optional
      (strOption (long "image-resource" <> metavar "RESOURCE-ID" <> help "Accepted OCI image inventory resource used by --save-plan"))
    <*> many
      (strOption (long "database-recovery" <> metavar "NAME=BACKUP:KEY_VERSION" <> help "Recovery binding for an application database; repeat for each database with --save-plan"))
    <*> many
      (strOption (long "tls-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted Secret for a supplied-TLS domain; repeat with --save-plan"))
    <*> many
      (strOption (long "env-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted Secret for a runtime environment reference; repeat with --save-plan"))
    <*> many
      (strOption (long "service-volume-recovery" <> metavar "VOLUME=BACKUP:KEY:VERSION" <> help "Recovery binding for a retained Service PVC; repeat with --save-plan"))
    <*> many
      (strOption (long "worker-volume-recovery" <> metavar "WORKER/VOLUME=BACKUP:KEY:VERSION" <> help "Recovery binding for a retained worker PVC; repeat with --save-plan"))
    <*> switch
      (long "request-namespace" <> help "Request a new namespace through the platform foundation's explicit grant with --save-plan")
    <*> optional
      (strOption (long "legacy-release-import" <> metavar "FILE" <> help "Legacy release ConfigMap JSON to preserve during exact reviewed adoption"))
    <*> optional
      (strOption (long "release-adoption-input" <> metavar "FILE" <> help "Versioned exact-incarnation adoption proposal for --legacy-release-import"))

workerDeployOptsParser :: FilePath -> Parser WorkerDeployOpts
workerDeployOptsParser defaultFile =
  WorkerDeployOpts
    <$> fileOpt defaultFile
    <*> tagOpt
    <*> optional
      ( strOption
          ( long "build-context"
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
    <*> optional (strOption (long "save-plan" <> metavar "FILE" <> help "Save reviewed standalone worker inventory plan"))
    <*> optional (strOption (long "image-resource" <> metavar "RESOURCE-ID" <> help "Accepted OCI image publication with --save-plan"))
    <*> many (strOption (long "volume-recovery" <> metavar "VOLUME=BACKUP:KEY:VERSION" <> help "Recovery for a retained worker PVC; repeat with --save-plan"))
    <*> many (strOption (long "env-secret-resource" <> metavar "RESOURCE-ID" <> help "Accepted runtime Secret; repeat with --save-plan"))

workerDeleteOptsParser :: Parser WorkerDeleteOpts
workerDeleteOptsParser =
  WorkerDeleteOpts
    <$> strArgument (metavar "NAME" <> help "Worker Deployment name")
    <*> namespaceOpt
    <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save reviewed retirement of the accepted standalone worker")
    <*> optional (strOption (long "scope-key" <> metavar "KEY" <> help "Pin the accepted standalone worker logical key"))

accessGrantOptsParser :: Parser AccessGrantOpts
accessGrantOptsParser =
  AccessGrantOpts
    <$> enUrlOpt
    <*> enApiKeyOpt
    <*> strOption (long "host" <> metavar "HOST" <> help "Protected site hostname, e.g. tools.apps.example.com")
    <*> strOption (long "user" <> metavar "USER" <> help "Shomei user id to grant or revoke")

accessListOptsParser :: Parser AccessListOpts
accessListOptsParser =
  AccessListOpts
    <$> enUrlOpt
    <*> enApiKeyOpt
    <*> strOption (long "host" <> metavar "HOST" <> help "Protected site hostname, e.g. tools.apps.example.com")

enUrlOpt :: Parser (Maybe String)
enUrlOpt =
  optional
    ( strOption
        ( long "en-url"
            <> metavar "URL"
            <> help "en-server URL (default: NAGARE_EN_URL)"
        )
    )

enApiKeyOpt :: Parser (Maybe String)
enApiKeyOpt =
  optional
    ( strOption
        ( long "en-api-key"
            <> metavar "KEY"
            <> help "en-server bearer API key (default: NAGARE_EN_API_KEY)"
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
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save reviewed static-site deployment"))
    <*> optional (strOption (long "image-resource" <> metavar "RESOURCE-ID" <> help "Accepted prepublished OCI image with --save-plan"))
    <*> optional (strOption (long "legacy-release-import" <> metavar "FILE" <> help "Legacy static-site release ConfigMap JSON for exact adoption"))
    <*> optional (strOption (long "release-adoption-input" <> metavar "FILE" <> help "Versioned exact-incarnation adoption proposal"))

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
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed retirement of an accepted application or standalone web Service"))
    <*> optional (strOption (long "scope-key" <> metavar "KEY" <> help "Pin the accepted application logical key"))

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
    <*> switch (long "system-namespace" <> internal)
    <*> optional (strOption (long "version" <> metavar "TAG" <> help "Pinned engine image tag (per-engine default if absent)"))
    <*> optional (strOption (long "size" <> metavar "QTY" <> help "Data volume size (default 10Gi, redis 2Gi)"))
    <*> optional (strOption (long "cpu" <> metavar "QTY" <> help "CPU limit (e.g. 500m)"))
    <*> optional (strOption (long "memory" <> metavar "QTY" <> help "Memory limit (e.g. 1Gi)"))
    <*> optional (strOption (long "config" <> metavar "FILE" <> help "Load a typed Database from a Config.hs instead of building from flags"))
    <*> dryRunOpt
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed standalone database plan for inventory apply"))
    <*> optional (strOption (long "recovery-backup" <> metavar "NAME" <> help "Recovery backup policy for a reviewed database"))
    <*> optional (strOption (long "recovery-key-version" <> metavar "VERSION" <> help "Credential recovery key version for a reviewed database"))

dbDeleteOptsParser :: Parser DbDeleteOpts
dbDeleteOptsParser =
  DbDeleteOpts
    <$> dbNameArg
    <*> namespaceOpt
    <*> switch (long "yes" <> help "Confirm deletion (without it, prints the plan and deletes nothing)")
    <*> dryRunOpt

standaloneRetireOptsParser :: Parser String -> Parser StandaloneRetireOpts
standaloneRetireOptsParser nameParser =
  StandaloneRetireOpts
    <$> nameParser
    <*> namespaceOpt
    <*> optional (strOption (long "scope-key" <> metavar "KEY" <> help "Pinned standalone scope key used at creation"))
    <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save a review that retires the scope and retains all provider resources")

inventoryResourceOption :: Parser String
inventoryResourceOption = strOption
  (long "resource" <> metavar "RESOURCE_ID" <> help "Retained resource to collect; repeat for multiple resources")

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
    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed topic-free broker plan for inventory apply"))
    <*> optional (strOption (long "recovery-backup" <> metavar "NAME" <> help "Recovery backup policy for a reviewed broker"))
    <*> optional (strOption (long "recovery-key" <> metavar "NAME" <> help "Recovery key name for a reviewed broker"))
    <*> optional (strOption (long "recovery-key-version" <> metavar "VERSION" <> help "Recovery key version for a reviewed broker"))

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

globalContextParser :: Parser (Maybe String)
globalContextParser =
  optional
    ( strOption
        ( long "context"
            <> metavar "NAME"
            <> help "Target context to use for this command (overrides NAGARE_CONTEXT and the current-context pointer)"
        )
    )

opts :: ParserInfo (Maybe String, Command)
opts =
  info
    (((,) <$> globalContextParser <*> commandParser) <**> helper)
    ( fullDesc
        <> progDesc "nagarectl — deploy a typed Nagare app or static site to Knative"
    )
  where
    commandParser =
      subparser
        ( command "version" versionCmd
            <> command "inventory" inventoryCmd
            <> command "platform" platformCmd
            <> command "host" hostCmd
            <> command "kubeconfig" kubeconfigCmd
            <> command "cluster" clusterCmd
            <> command "deploy" deployCmd
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
            <> command "access" accessCmd
            <> command "server" serverCmd
            <> command "doctor" doctorCmd
            <> command "context" contextCmd
            <> command "init" initCmd
            <> command "infra" infraCmd
            <> command "domains" domainsCmd
            <> command "cdn" cdnCmd
            <> command "cleanup" cleanupCmd
        )
    versionCmd =
      info
        ( Version
            <$> ( VersionOpts
                    <$> switch (long "json" <> help "Print machine-readable version metadata")
                    <*> switch (long "tools" <> help "Report the executable paths selected from PATH")
                )
              <**> helper
        )
        (progDesc "Print the nagarectl version")
    inventoryCmd =
      info
        ( subparser
            ( command
                "compile"
                (info (InventoryCompile <$> strOption (long "input" <> metavar "FILE") <*> strOption (long "out" <> metavar "DIRECTORY") <*> switch (long "json") <**> helper) (progDesc "Compile complete resource scopes without contacting providers"))
                <> command
                  "plan"
                  (info (InventoryPlan <$> strOption (long "inventory" <> metavar "DIRECTORY") <*> strOption (long "out" <> metavar "DIRECTORY") <**> helper) (progDesc "Prepare and publish a digest-bound inventory review"))
                <> command
                  "adopt"
                  (info (InventoryAdopt <$> strOption (long "input" <> metavar "FILE") <*> strOption (long "out" <> metavar "DIRECTORY") <**> helper) (progDesc "Review exact adoption or known-owner transfer incarnations"))
                <> command
                  "migrate"
                  (info (InventoryMigrate <$> strOption (long "input" <> metavar "FILE") <*> strOption (long "out" <> metavar "DIRECTORY") <**> helper) (progDesc "Review exact source and destination migration incarnations"))
                <> command
                  "retire"
                  (info (InventoryRetire <$> strOption (long "scope" <> metavar "KIND:NAME") <*> strOption (long "out" <> metavar "DIRECTORY") <**> helper) (progDesc "Review retention of an accepted scope without deleting its resources"))
                <> command
                  "gc"
                  (info (InventoryGc <$> (flag' () (long "plan" <> help "Write a read-only collection assessment") *> strOption (long "out" <> metavar "DIRECTORY")) <**> helper) (progDesc "Screen retained resources for later collection review"))
                <> command
                  "collect"
                  (info (InventoryCollect <$> ((NE.:|) <$> inventoryResourceOption <*> many (strOption (long "resource" <> metavar "RESOURCE_ID" <> internal))) <*> strOption (long "out" <> metavar "DIRECTORY") <**> helper) (progDesc "Review exact collection of retained stateless Kubernetes resources"))
                <> command
                  "apply"
                  (info (InventoryApply <$> strArgument (metavar "REVIEW_DIRECTORY") <*> switch (long "yes") <**> helper) (progDesc "Apply an issued inventory review"))
                <> command
                  "resume"
                  (info (InventoryResume <$> strArgument (metavar "TRANSACTION") <*> switch (long "yes")
                    <*> switch (long "take-over") <**> helper) (progDesc "Resume an unresolved inventory transaction"))
                <> command
                  "recover"
                  (info (InventoryRecover <$> strArgument (metavar "TRANSACTION")
                    <*> strOption (long "operation" <> metavar "OPERATION")
                    <*> strOption (long "decision" <> metavar "FILE")
                    <*> switch (long "take-over") <**> helper)
                    (progDesc "Record an adapter-proved recovery decision for one uncertain operation"))
                <> command
                  "export"
                  (info (InventoryExport <$> strOption (long "out" <> metavar "DIRECTORY") <**> helper) (progDesc "Export the complete private inventory store under lock"))
                <> command
                  "status"
                  (info (InventoryStatus <$> switch (long "json") <**> helper) (progDesc "Report accepted resource ownership and observed drift without mutation"))
                <> command
                  "explain"
                  (info (InventoryExplain <$> strArgument (metavar "RESOURCE_ID") <*> switch (long "json") <**> helper) (progDesc "Explain one accepted resource and its current observation"))
                <> command "store" (info (subparser
                  (command "status" (info (InventoryStoreStatus <$> switch (long "json") <**> helper)
                    (progDesc "Read the selected inventory history store and executor claim"))
                  <> command "migrate" (info
                    (InventoryStoreMigrate <$> strOption (long "to" <> metavar "gcs|local")
                      <*> switch (long "dry-run") <*> switch (long "yes") <**> helper)
                    (progDesc "Copy inventory history and tombstone the source store"))) <**> helper)
                  (progDesc "Inspect the selected inventory history store"))
            )
            <**> helper
        )
        (progDesc "Typed resource inventory")
    platformCmd =
      info
        ( subparser
            ( command
                "root"
                ( info
                    (PlatformRoot <$> switch (long "json" <> help "Print machine-readable platform path metadata") <**> helper)
                    (progDesc "Resolve, validate, and materialize the active platform payload")
                )
                <> command
                  "status"
                  ( info
                      (PlatformStatusCmd <$> switch (long "json" <> help "Print machine-readable release identities") <**> helper)
                      (progDesc "Compare CLI, payload, context, host, and cluster release identities")
                  )
                <> command
                  "guard"
                  (info (pure PlatformGuard <**> helper) (progDesc "Refuse unsafe platform mutation when release versions are incompatible"))
                <> command
                  "stamp"
                  (info (pure PlatformStamp <**> helper) (progDesc "Retired: use a reviewed platform bootstrap apply to record the payload identity"))
                <> command
                  "bootstrap"
                  (info (bootstrapCommandParser <**> helper) (progDesc "Plan or apply reviewed cluster bootstrap resources"))
                <> command
                  "adopt"
                  ( info
                      (PlatformAdopt <$> strOption (long "version" <> metavar "VERSION" <> help "Release identity to assign to a legacy context") <*> switch (long "yes" <> help "Confirm the displayed observations") <*> switch (long "json" <> help "Print machine-readable observations and result") <**> helper)
                      (progDesc "Explicitly adopt the observed payload release for a legacy context")
                  )
                <> command
                  "repin"
                  ( info
                      (PlatformRepin <$> strOption (long "version" <> metavar "VERSION" <> help "Current payload release to assign before first deployment") <*> switch (long "yes" <> help "Confirm the displayed absence evidence") <**> helper)
                      (progDesc "Re-pin a versioned context whose GCE host has never been deployed")
                  )
                <> command
                  "upgrade"
                  (info (upgradeCommandParser <**> helper) (progDesc "Plan, apply, resume, or inspect a per-context platform upgrade"))
            )
            <**> helper
        )
        (fullDesc <> progDesc "Inspect packaged platform resources")
    bootstrapCommandParser =
      subparser
        ( command "plan"
            (info (PlatformBootstrapPlan <$> strOption (long "out" <> metavar "DIRECTORY") <**> helper)
              (progDesc "Compile and publish a reviewed bootstrap plan"))
        <> command "apply"
            (info (PlatformBootstrapApply <$> strArgument (metavar "REVIEW_DIRECTORY")
              <*> switch (long "yes") <**> helper)
              (progDesc "Apply a published bootstrap review"))
        )
    upgradeCommandParser =
      subparser
        ( command
            "status"
            ( info
                (PlatformUpgradeStatus <$> optional (strArgument (metavar "TRANSACTION_ID")) <*> switch (long "json" <> help "Print transaction JSON") <**> helper)
                (progDesc "Show the selected or latest upgrade transaction")
            )
            <> command
              "rollback"
              ( info
                  (PlatformUpgradeRollback <$> strArgument (metavar "TRANSACTION_ID") <*> switch (long "yes" <> help "Confirm the supported release rollback") <*> switch (long "json" <> help "Print transaction JSON") <**> helper)
                  (progDesc "Create and apply a reverse transaction when release metadata explicitly permits it")
              )
            <> command
              "recover-pulumi"
              ( info
                  (PlatformUpgradeRecoverPulumi <$> strArgument (metavar "TRANSACTION_ID") <*> strOption (long "outcome" <> metavar "applied|retry" <> help "Record the inspected Pulumi outcome") <*> switch (long "yes" <> help "Confirm the audited recovery decision") <**> helper)
                  (progDesc "Resolve an ambiguous or pre-receipt Pulumi apply outcome")
              )
        )
        <|> (PlatformUpgrade <$> upgradeOptsParser)
    upgradeOptsParser =
      UpgradeOpts
        <$> optional (strOption (long "to" <> metavar "VERSION" <> help "Target semantic platform version"))
        <*> optional (strOption (long "payload-root" <> metavar "PATH" <> help "Use this already-resolved payload (tests/offline recovery)"))
        <*> switch (long "apply" <> help "Apply a previously successful plan; requires --resume and --yes")
        <*> optional (strOption (long "resume" <> metavar "TRANSACTION_ID" <> help "Resume this persisted transaction"))
        <*> switch (long "dry-run" <> help "Plan only (the default; accepted for explicit automation)")
        <*> switch (long "yes" <> help "Confirm application of the planned infrastructure and cluster changes")
        <*> switch (long "json" <> help "Print the transaction as JSON")
    hostCmd =
      info
        (Host <$> hostSubparser <**> helper)
        (fullDesc <> progDesc "Manage context-owned NixOS host configuration")
    hostSubparser =
      subparser
        ( command "init" (info (HostInit <$> hostInitOptsParser <**> helper) (progDesc "Generate and validate a context-owned host flake"))
            <> command "show" (info (HostShow <$> optional hostContextOption <**> helper) (progDesc "Print the generated operator module"))
            <> command "path" (info (HostPath <$> optional hostContextOption <**> helper) (progDesc "Print the generated host-flake path"))
            <> command
              "name"
              ( info
                  (HostName <$> optional hostContextOption <*> switch (long "json" <> help "Print machine-readable host identity") <**> helper)
                  (progDesc "Print the validated generated NixOS and tailnet host name")
              )
            <> command
              "place-age-key"
              ( info
                  (HostPlaceAgeKey <$> hostPlaceAgeKeyOptsParser <**> helper)
                  (progDesc "Stream an age private key to the selected host over project-confined IAP")
              )
        )
    hostContextOption = strOption (long "context" <> metavar "NAME" <> help "Host context (defaults to the global or active context)")
    hostInitOptsParser =
      HostInitOpts
        <$> optional hostContextOption
        <*> many (strOption (long "ssh-public-key-file" <> metavar "PATH" <> help "Operator SSH public-key file; repeat for multiple keys"))
        <*> optional (strOption (long "sops-file" <> metavar "PATH" <> help "Existing sops-encrypted host secrets YAML; required for a new host"))
        <*> strOption (long "age-key-file" <> metavar "HOST_PATH" <> value "/var/lib/sops-nix/age-key.txt" <> showDefault <> help "Private age-key path on the host (the key is never read or copied)")
        <*> optional (strOption (long "host-name" <> metavar "NAME" <> help "NixOS and tailnet hostname (defaults to <context>-nagare)"))
        <*> optional (strOption (long "instance-name" <> metavar "NAME" <> help "Cloud instance identity (defaults to the context instance name)"))
        <*> optional (strOption (long "registry-host" <> metavar "HOST" <> help "Artifact Registry host (defaults to the context registry)"))
        <*> strOption (long "deploy-user" <> metavar "USER" <> value "deploy" <> showDefault <> help "Operator account created on the host")
        <*> switch (long "force" <> help "Atomically replace changed generated scaffolding")
        <*> switch (long "dry-run" <> help "Validate inputs and print generated configuration without writing")
    hostPlaceAgeKeyOptsParser =
      HostPlaceAgeKeyOpts
        <$> optional hostContextOption
        <*> strOption (long "key-file" <> metavar "PATH" <> help "Operator-held age private-key file to stream over SSH stdin")
        <*> switch (long "force" <> help "Replace a different installed key (interruption-sensitive; preserve both keys first)")
    kubeconfigCmd =
      info
        (Kubeconfig <$> kubeconfigSubparser <**> helper)
        (fullDesc <> progDesc "Fetch and manage context-owned Kubernetes credentials")
    kubeconfigSubparser =
      subparser
        ( command
            "fetch"
            ( info
                ( KubeconfigFetch
                    <$> ( KubeconfigFetchOpts
                            <$> optional (strOption (long "context" <> metavar "NAME" <> help "Context to fetch (defaults to the global or active context)"))
                            <*> optional (strOption (long "output" <> metavar "FILE" <> help "Destination (default: the context kubeconfig store)"))
                        )
                      <**> helper
                )
                (progDesc "Fetch k3s credentials over project-confined IAP and install them atomically")
            )
        )
    clusterCmd =
      info
        (Cluster <$> clusterSubparser <**> helper)
        (fullDesc <> progDesc "Inspect and guard the selected Kubernetes cluster")
    clusterSubparser =
      subparser
        ( command
            "guard"
            ( info
                ( ClusterGuard
                    <$> ( ClusterGuardOpts
                            <$> optional (strOption (long "context" <> metavar "NAME" <> help "Nagare context expected to own the active Kubernetes cluster"))
                            <*> switch (long "json" <> help "Emit the expected and observed identities as JSON")
                        )
                      <**> helper
                )
                (progDesc "Refuse unless the active kube context has the selected context's sole server node")
            )
            <> command
              "certificate-policy"
              ( info
                  (pure ClusterCertificatePolicy <**> helper)
                  (progDesc "Refuse when public ACME certificates contain internal names or unlabeled wildcards")
              )
        )
    doctorCmd =
      info
        (Doctor <$> doctorOptsParser <**> helper)
        (fullDesc <> progDesc "Health-check the platform and print remediation hints (exit 1 on any FAIL)")
    contextCmd =
      info
        (ContextCmdGroup <$> contextSubparser <**> helper)
        (fullDesc <> progDesc "Manage named target contexts")
    contextSubparser =
      subparser
        ( command "list" (info (pure ContextList <**> helper) (progDesc "List all contexts; mark the current one"))
            <> command "current" (info (pure ContextCurrent <**> helper) (progDesc "Print the current context name"))
            <> command "use" (info (ContextUse <$> contextNameArg <**> helper) (progDesc "Set the current context"))
            <> command "show" (info (ContextShow <$> optional contextNameArg <**> helper) (progDesc "Print a context bundle (default: active context)"))
            <> command "create" (info (ContextCreate <$> contextNameArg <*> contextCreateOptsParser <**> helper) (progDesc "Write a new context into the store"))
            <> command "delete" (info (ContextDelete <$> contextNameArg <*> switch (long "yes" <> help "Confirm deletion") <**> helper) (progDesc "Delete a context from the store"))
            <> command "guard" (info (ContextGuard <$> switch (long "json" <> help "Emit the compared values as JSON") <**> helper) (progDesc "Refuse unless the Pulumi stack, the environment and gcloud all agree with the active context's project"))
            <> command "env" (info (pure ContextEnv <**> helper) (progDesc "Print the active context's shell environment as export lines, safe to eval"))
        )
    initCmd =
      info
        (Init <$> initOptsParser <**> helper)
        (fullDesc <> progDesc "Onboard a fresh GCP project: preflight, write the target profile, enable APIs, seed Pulumi config")
    infraCmd =
      info
        ( subparser
            ( command
                "guard"
                ( info
                    (Infra . InfraGuard <$> switch (long "allow-replacement" <> help "Allow a deliberate GCE instance replacement for this run") <**> helper)
                    (progDesc "Preview and refuse a plan that replaces the GCE instance")
                )
                <> command
                  "preview"
                  ( info
                      ( Infra
                          . InfraPreview
                          <$> ( InfraPreviewOpts
                                  <$> strOption (long "save-plan" <> metavar "DIR" <> help "Write one private context-bound reviewed-plan bundle")
                                  <*> optional (strOption (long "inventory" <> metavar "COMPILED_DIRECTORY" <> help "Plan the compiled typed inventory through the shared executor"))
                                  <*> switch (long "allow-replacement" <> help "Record approval for protected replacements in this review")
                              )
                            <**> helper
                      )
                      (progDesc "Save and classify one context-bound Pulumi preview")
                  )
                <> command
                  "apply"
                  ( info
                      ( Infra
                          . InfraApply
                          <$> ( InfraApplyOpts
                                  <$> strOption (long "plan" <> metavar "DIR" <> help "Previously reviewed plan bundle")
                                  <*> switch (long "yes" <> help "Apply without an interactive prompt")
                                  <*> switch (long "allow-replacement" <> help "Acknowledge an approved protected replacement again at apply time")
                              )
                            <**> helper
                      )
                      (progDesc "Verify and non-interactively apply a reviewed Pulumi plan")
                  )
                <> command
                  "destroy"
                  ( info
                      (Infra . InfraDestroy <$> switch (long "yes" <> help "Confirm complete infrastructure teardown") <**> helper)
                      (progDesc "Guard and destroy the selected context's Pulumi stack")
                  )
            )
            <**> helper
        )
        (fullDesc <> progDesc "Preview, apply, and tear down guarded infrastructure")
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
            <> command
              "check"
              ( info
                  (Domains . DomainsCheck <$> domainsListOptsParser <**> helper)
                  (progDesc "Check public DNS, route ownership/readiness, and certificate state")
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
                (progDesc "Deploy or review a long-running worker (apps/v1 Deployment) from the current directory")
            )
        <> command
            "delete"
            ( info
                (Worker . WorkerDelete <$> workerDeleteOptsParser <**> helper)
                (progDesc "Review retirement of an accepted standalone worker")
            )
        )
    accessCmd =
      info
        (Access <$> accessSubparser <**> helper)
        (fullDesc <> progDesc "Manage identity-aware access grants for protected sites")
    accessSubparser =
      subparser
        ( command
            "grant"
            ( info
                (AccessGrant <$> accessGrantOptsParser <**> helper)
                (progDesc "Grant a shomei user access to a protected host")
            )
            <> command
              "revoke"
              ( info
                  (AccessRevoke <$> accessGrantOptsParser <**> helper)
                  (progDesc "Revoke a shomei user's access to a protected host")
              )
            <> command
              "list"
              ( info
                  (AccessList <$> accessListOptsParser <**> helper)
                  (progDesc "List users who currently expand to access on a protected host")
              )
            <> command
              "portal"
              ( info
                  (AccessPortal <$> portalSubparser <**> helper)
                  (progDesc "Inspect or synchronize the authentication portal")
              )
        )
    portalSubparser =
      subparser
        ( command
            "show"
            (info (pure PortalShow <**> helper) (progDesc "Show the registered authentication portal"))
            <> command
              "sync"
              (info (pure PortalSync <**> helper) (progDesc "Re-apply the registered portal configuration to Shomei"))
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
                      <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Review one env key update from accepted history"))
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
                      <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Review one env key deletion from accepted history"))
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
                      <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Review a merged or exact Runtime, Build, or Preview env channel"))
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
                    <*> optional (strOption (long "version" <> metavar "TOKEN" <> help "Opaque reviewed Secret rotation version"))
                    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Review one Secret key update"))
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
                    <*> optional (strOption (long "version" <> metavar "TOKEN" <> help "Opaque reviewed Secret rotation version"))
                    <*> optional (strOption (long "save-plan" <> metavar "DIR" <> help "Review one Secret key deletion"))
                      <**> helper
                  )
                  (progDesc "Delete one secret key")
              )
            <> command
              "sync"
              ( info
                  ( SecretSync
                      <$> storeCommonOptsParser
                      <*> scopeSelectionParser
                      <*> strOption (long "file" <> metavar "FILE" <> help "dotenv file with exact Runtime, Build, or Preview Secret values")
                      <*> strOption (long "version" <> metavar "TOKEN" <> help "Opaque Secret rotation version")
                      <*> strOption (long "save-plan" <> metavar "DIR" <> help "Save a reviewed Runtime, Build, or Preview Secret replacement")
                        <**> helper
                  )
                  (progDesc "Review an exact Runtime, Build, or Preview Secret replacement")
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
                  (progDesc "Delete a legacy app or review accepted web-Service retirement")
              )
            <> command
              "deploy"
              ( info
                  (AppDeploy <$> appDeployOptsParser defaultConfigFile <**> helper)
                  (progDesc "Deploy a whole multi-workload Application (service + workers + databases + hooks) in one ordered rollout")
              )
            <> command
              "image-plan"
              ( info
                  (AppImagePlan <$> appImagePlanOptsParser <**> helper)
                  (progDesc "Save a reviewed OCI archive publication for an application image")
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
            <> command
              "retire"
              ( info
                  (Broker . BrokerRetire <$> standaloneRetireOptsParser brokerNameArg <**> helper)
                  (progDesc "Review retirement of an accepted broker scope; retain all provider resources")
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
              "retire"
              ( info
                  (Db . DbRetire <$> standaloneRetireOptsParser dbNameArg <**> helper)
                  (progDesc "Review retirement of an accepted database scope; retain all provider resources")
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
main = do
  setLocaleEncoding utf8
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  execParser opts >>= \(mctx, cmd0) -> case cmd0 of
    Version versionOpts -> runVersion versionOpts
    PlatformRoot asJson -> runPlatformRoot mctx asJson
    PlatformStatusCmd asJson -> runPlatformStatus mctx asJson
    PlatformGuard -> runPlatformGuard mctx
    PlatformStamp -> runPlatformStamp mctx
    PlatformBootstrapPlan output -> runPlatformBootstrapPlan mctx output
    PlatformBootstrapApply review yes -> runInventoryApply mctx review yes
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
    SiteReleases copts -> runSiteReleases copts
    SiteRollback copts rid -> runSiteRollback mctx copts (T.pack rid)
    SitePreviewDeploy sopts pname -> runPreviewDeploy mctx sopts (T.pack pname)
    SitePreviewList copts -> runPreviewList copts
    SitePreviewDelete copts pname -> runPreviewDelete mctx copts (T.pack pname)
    Env ecmd -> runEnv mctx ecmd
    Secret scmd -> runSecret mctx scmd
    AppList o -> runAppList o
    AppGet o -> runAppGet o
    AppLogs o -> runAppLogs o
    AppRestart o -> runAppRestart mctx o
    AppStop o -> runAppStop mctx o
    AppDelete o -> runAppDelete mctx o
    AppDeploy o -> do
      provisionGhcEnv (o ^. #ghcEnv)
      tp <- activeProfile mctx
      case o ^. #savePlan of
        Nothing -> do
          when (isJust (o ^. #imageResource) || not (null (o ^. #databaseRecovery))
              || not (null (o ^. #tlsSecretResources)) || not (null (o ^. #envSecretResources))
              || not (null (o ^. #serviceVolumeRecovery)) || not (null (o ^. #workerVolumeRecovery))
              || o ^. #requestNamespace || isJust (o ^. #legacyReleaseImport)
              || isJust (o ^. #releaseAdoptionInput))
            (dieT "inventory resource and recovery options require --save-plan")
          runAppDeployWithGuard (refuseDirectApplicationDeployIfOwned mctx) (toAppDeployParams tp o)
        Just output -> runAppDeployPlan mctx (toAppDeployParams tp o) o output
    AppImagePlan o -> runAppImagePlan mctx o
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
    Infra (InfraDestroy yes) -> runInfraDestroy mctx yes
    Domains (DomainsList o) -> runDomainsList mctx o
    Domains (DomainsCheck o) -> runDomainsCheck mctx o
    CdnCmd ccmd -> runCdn mctx ccmd
    Cleanup o -> runCleanup mctx o
    InventoryCompile input output json -> Inventory.compileInventory input output json
    InventoryPlan input output -> runInventoryPlan mctx input output
    InventoryAdopt input output -> runInventoryAdopt mctx input output
    InventoryMigrate input output -> runInventoryMigrate mctx input output
    InventoryRetire owner output -> runInventoryRetire mctx owner output
    InventoryGc output -> runInventoryStatus mctx Nothing True (Just output)
    InventoryCollect resource output -> runInventoryCollect mctx resource output
    InventoryApply directory yes -> runInventoryApply mctx directory yes
    InventoryResume transaction yes takeOver -> runInventoryResume mctx (T.pack transaction) yes takeOver
    InventoryRecover transaction operation decisionFile takeOver ->
      runInventoryRecover mctx (T.pack transaction) (T.pack operation) decisionFile takeOver
    InventoryExport output -> activeTarget mctx >>= \target -> Inventory.exportInventory target output
    InventoryStatus json -> runInventoryStatus mctx Nothing json Nothing
    InventoryExplain resource json -> runInventoryStatus mctx (Just resource) json Nothing
    InventoryStoreStatus json -> runInventoryStoreStatus mctx json
    InventoryStoreMigrate destination dryRun yes -> runInventoryStoreMigrate mctx destination dryRun yes

runVersion :: VersionOpts -> IO ()
runVersion options = do
  resolvedTools <-
    if options ^. #tools
      then traverse resolveTool ["pulumi", "pulumi-language-nodejs", "socat", "attic", "skopeo", "gcloud", "npm"]
      else pure []
  if options ^. #json
    then
      BC.putStrLn
        ( if options ^. #tools
            then renderBuildVersionJsonWithTools currentBuildVersion resolvedTools
            else renderBuildVersionJson currentBuildVersion
        )
    else do
      TIO.putStrLn (renderBuildVersionText currentBuildVersion)
      forM_ resolvedTools $ \(name, path) ->
        TIO.putStrLn (name <> ": " <> maybe "not found" T.pack path)
  where
    resolveTool name = do
      path <- findExecutable name
      pure (T.pack name, path)

-- | @server status@: gather the platform inventory and print the aligned
-- report. Read-only and always exits 0 — graceful degradation is the probes'
-- job, so a probe whose source is unreachable shows as @UNKNOWN@/@WARN@ rather
-- than aborting the command (script-friendly exit codes belong to EP-39's
-- @doctor@).
activeProfile :: Maybe String -> IO TargetProfile
activeProfile = resolveActiveContext . fmap T.pack

activeTarget :: Maybe String -> IO ActiveTarget
activeTarget = resolveActiveTarget . fmap T.pack

resolvePlatformWorkspace :: ContextName -> IO (PlatformPaths, PlatformWorkspace)
resolvePlatformWorkspace contextName = do
  pathsResult <- resolvePlatformPaths Nothing
  paths <- either (dieT . renderPlatformPathError) pure pathsResult
  stateRoot <- nagareStateDir
  workspaceResult <- preparePlatformWorkspace stateRoot contextName paths
  workspace <- either (dieT . renderWorkspaceError) pure workspaceResult
  setEnv "NAGARE_WORKSPACE_ROOT" (workspace ^. #root)
  pure (paths, workspace)

runPlatformRoot :: Maybe String -> Bool -> IO ()
runPlatformRoot mctx asJson = do
  active <- activeTarget mctx
  (paths, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  if asJson
    then
      LBC.putStrLn $
        Aeson.encode $
          Aeson.object
            [ "source" Aeson..= platformRootSourceToken (paths ^. #rootSource)
            , "payloadRoot" Aeson..= (paths ^. #root)
            , "workspaceRoot" Aeson..= (workspace ^. #root)
            , "payloadId" Aeson..= (workspace ^. #payloadId)
            , "platformVersion" Aeson..= (workspace ^. #platformVersion)
            , "revision" Aeson..= (workspace ^. #sourceRevision)
            , "digest" Aeson..= (workspace ^. #digest)
            ]
    else do
      TIO.putStrLn ("source: " <> platformRootSourceToken (paths ^. #rootSource))
      putStrLn ("payload root: " <> paths ^. #root)
      putStrLn ("workspace root: " <> workspace ^. #root)

gatherPlatformStatus :: Maybe String -> IO (ActiveTarget, PlatformStatus)
gatherPlatformStatus mctx = do
  active <- activeTarget mctx
  (paths, _) <- resolvePlatformWorkspace (active ^. #contextName)
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  hostRoot <- hostConfigDir (active ^. #contextName)
  let hostFlake = hostRoot </> "flake.nix"
  hostExists <- doesFileExist hostFlake
  hostIdentity <- if hostExists then parseHostIdentity <$> TIO.readFile hostFlake else pure unknownIdentity
  hostDeployment <- case active ^. #profile . #mode of
    Cloud -> observeHostDeployment defaultDeploymentOps (active ^. #profile)
    Local -> pure (DeploymentUnknown "local contexts do not have a GCE deployment")
  (clusterIdentity, clusterDeployment) <- case hostDeployment of
    NotDeployed -> pure (unknownIdentity, NotDeployed)
    _ -> do
      clusterBytes <- captureTool "kubectl" ["get", "configmap", "nagare-platform-version", "-n", "nagare-system", "-o", "json", "--request-timeout=5s"]
      pure $ case clusterBytes >>= parseClusterIdentity of
        Just identity -> (identity, Deployed)
        Nothing -> (unknownIdentity, DeploymentUnknown "cluster release identity is unreachable or absent")
  let status =
        assessPlatformStatus
          (identityFromBuild currentBuildVersion)
          (identityFromPayload manifest)
          (identityFromContext (active ^. #profile))
          hostIdentity
          hostDeployment
          clusterIdentity
          clusterDeployment
  pure (active, status)
  where
    unknownIdentity = ReleaseIdentity Nothing Nothing Nothing

runPlatformStatus :: Maybe String -> Bool -> IO ()
runPlatformStatus mctx asJson = do
  (active, status) <- gatherPlatformStatus mctx
  if asJson
    then LBC.putStrLn (Aeson.encode (platformStatusValue status))
    else TIO.putStr (renderPlatformStatus (contextNameText (active ^. #contextName)) status)

runPlatformGuard :: Maybe String -> IO ()
runPlatformGuard mctx = do
  (_, status) <- gatherPlatformStatus mctx
  case guardPlatformMutation status of
    Left err -> dieT err
    Right () -> TIO.putStrLn ("platform mutation allowed (" <> compatibilityToken (status ^. #compatibility) <> ")")

runPlatformStamp :: Maybe String -> IO ()
runPlatformStamp _ =
  dieT "platform stamp is retired; use platform bootstrap plan --out DIRECTORY, then platform bootstrap apply DIRECTORY --yes"

runPlatformAdopt :: Maybe String -> String -> Bool -> Bool -> IO ()
runPlatformAdopt mctx rawVersion yes asJson = do
  target <- either (dieT . ("invalid --version: " <>) . renderVersionError) (pure . renderPlatformVersion) (parsePlatformVersion (T.pack rawVersion))
  (active, status) <- gatherPlatformStatus mctx
  if asJson
    then LBC.hPutStrLn stderr (Aeson.encode (Aeson.object ["context" Aeson..= contextNameText (active ^. #contextName), "requestedVersion" Aeson..= target, "observations" Aeson..= platformStatusValue status]))
    else TIO.putStr (renderPlatformStatus (contextNameText (active ^. #contextName)) status)
  either dieT pure (validatePlatformAdoption target status)
  unless yes (dieT "refusing to adopt a legacy context without --yes after reviewing the observations above")
  (paths, _) <- resolvePlatformWorkspace (active ^. #contextName)
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  applyClusterMarker manifest >>= either dieT (const (pure ()))
  writeContextPlatformVersion (active ^. #contextName) target >>= either dieT pure
  if asJson
    then LBC.putStrLn (Aeson.encode (Aeson.object
      [ "adopted" Aeson..= True
      , "context" Aeson..= contextNameText (active ^. #contextName)
      , "platformVersion" Aeson..= target
      , "observations" Aeson..= platformStatusValue status
      , "inventoryResourcesAdopted" Aeson..= False
      , "inventoryNextStep" Aeson..= ("compile the complete inventory, then review each legacy object with inventory adopt" :: Text)
      ]))
    else do
      TIO.putStrLn ("adopted Nagare platform " <> target <> " for context '" <> contextNameText (active ^. #contextName) <> "'")
      TIO.putStrLn "This pins the platform release; it does not adopt managed inventory resources. Compile the complete inventory and review legacy objects with inventory adopt."

runPlatformRepin :: Maybe String -> String -> Bool -> IO ()
runPlatformRepin mctx rawVersion yes = do
  target <- either (dieT . ("invalid --version: " <>) . renderVersionError) (pure . renderPlatformVersion) (parsePlatformVersion (T.pack rawVersion))
  (active, status) <- gatherPlatformStatus mctx
  let contextName = active ^. #contextName
      profile = active ^. #profile
      contextText = contextNameText contextName
      previousVersion = status ^. #context . #version
  when (profile ^. #mode == Local) $
    dieT "platform re-pin is available only for cloud contexts"
  TIO.putStr (renderPlatformStatus contextText status)
  either dieT pure (guardPlatformMutation status)
  either dieT pure (validatePlatformRepin target status)
  (gcloudAccount, adc) <- observeAdcForProject
  warnings <- either dieT pure (validateAdc (profile ^. #project) gcloudAccount adc)
  printPreflightWarnings warnings
  workspace <- ensurePulumiForContext contextName profile
  projectInputs <- projectGuardInputsFor contextName profile workspace
  either dieT pure (projectGuardVerdict projectInputs)
  TIO.putStrLn (renderProjectGuard projectInputs)
  unless yes (dieT "refusing to re-pin an undeployed context without --yes after reviewing the observations above")
  hostRoot <- hostConfigDir contextName
  let hostAlreadyMatches = status ^. #host . #version == Just target
      contextAlreadyMatches = previousVersion == Just target
  hostExists <- doesFileExist (hostRoot </> "flake.nix")
  if contextAlreadyMatches && (not hostExists || hostAlreadyMatches)
    then TIO.putStrLn ("context '" <> contextText <> "' is already pinned to Nagare platform " <> target)
    else do
      (paths, _) <- resolvePlatformWorkspace contextName
      manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
      stagedHost <-
        if hostExists
          then withSystemTempDirectory "nagare-platform-repin" $ \temporary -> do
            staged <- stageHostFlake hostRoot temporary (paths ^. #nixosDir) (BuildVersion target (manifest ^. #sourceRevision)) >>= either dieT pure
            -- Commit the context first; if the already-validated host commit fails,
            -- restore the old context pin before returning the error.
            writeContextPlatformVersion contextName target >>= either dieT pure
            committed <- commitStagedHostFlake staged hostRoot
            case committed of
              Right () -> pure True
              Left err -> do
                forM_ previousVersion $ \oldVersion -> void (writeContextPlatformVersion contextName oldVersion)
                dieT err
          else do
            writeContextPlatformVersion contextName target >>= either dieT pure
            pure False
      (_, finalStatus) <- gatherPlatformStatus mctx
      unless (finalStatus ^. #context . #version == finalStatus ^. #payload . #version) $
        dieT "re-pin wrote inconsistent context and payload release identities"
      TIO.putStr (renderPlatformStatus contextText finalStatus)
      TIO.putStrLn
        ( "re-pinned context '"
            <> contextText
            <> "' to Nagare platform "
            <> target
            <> if stagedHost then " and updated its generated host flake" else ""
        )

upgradeTransactionsDir :: ContextName -> IO FilePath
upgradeTransactionsDir context = do
  stateRoot <- nagareStateDir
  pure (stateRoot </> T.unpack (contextNameText context) </> "upgrades")

upgradeTransactionPath :: ContextName -> Text -> IO FilePath
upgradeTransactionPath context txId = (</> T.unpack txId <> ".json") <$> upgradeTransactionsDir context

latestUpgradeTransactionId :: ContextName -> IO (Maybe Text)
latestUpgradeTransactionId context = do
  directory <- upgradeTransactionsDir context
  exists <- doesDirectoryExist directory
  if not exists
    then pure Nothing
    else do
      entries <- listDirectory directory
      let ids = sort [T.pack (dropExtension entry) | entry <- entries, takeExtension entry == ".json"]
      pure (case reverse ids of [] -> Nothing; latest : _ -> Just latest)

loadUpgradeTransaction :: ContextName -> Maybe String -> IO (FilePath, UpgradeTransaction)
loadUpgradeTransaction context requested = do
  txId <- case requested of
    Just requestedId -> pure (T.pack requestedId)
    Nothing -> latestUpgradeTransactionId context >>= maybe (dieT "no upgrade transaction exists for this context") pure
  path <- upgradeTransactionPath context txId
  tx <- readUpgradeTransaction path >>= either dieT pure
  when (tx ^. #context /= contextNameText context) $
    dieT ("upgrade transaction belongs to context '" <> tx ^. #context <> "', not '" <> contextNameText context <> "'")
  pure (path, tx)

runPlatformUpgradeStatus :: Maybe String -> Maybe String -> Bool -> IO ()
runPlatformUpgradeStatus mctx requested asJson = do
  active <- activeTarget mctx
  (_, tx) <- loadUpgradeTransaction (active ^. #contextName) requested
  printUpgradeTransaction asJson tx

runPlatformUpgradeRollback :: Maybe String -> String -> Bool -> Bool -> IO ()
runPlatformUpgradeRollback mctx requested yes asJson = do
  active <- activeTarget mctx
  (_, original) <- loadUpgradeTransaction (active ^. #contextName) (Just requested)
  unless yes (dieT "refusing to roll back a release selection without --yes")
  unless (original ^. #state == Completed) (dieT "only a completed upgrade transaction can be rolled back")
  unless (original ^. #rollbackSupported) $
    dieT "release metadata does not declare this rollback direction supported; Nagare will not claim to reverse data or Pulumi schema migrations automatically"
  oldVersion <- maybe (dieT "the completed transaction began from a legacy context and has no previous release to select") pure (original ^. #previousVersion)
  oldWorkspace <- findRetainedWorkspace (active ^. #contextName) oldVersion
  runPlatformUpgrade
    mctx
    UpgradeOpts
      { to = Just (T.unpack oldVersion)
      , payloadRoot = Just oldWorkspace
      , apply = False
      , resume = Nothing
      , dryRun = True
      , yes = False
      , json = asJson
      }
  newId <- latestUpgradeTransactionId (active ^. #contextName) >>= maybe (dieT "rollback plan did not create a transaction") pure
  runPlatformUpgrade
    mctx
    UpgradeOpts
      { to = Nothing
      , payloadRoot = Nothing
      , apply = True
      , resume = Just (T.unpack newId)
      , dryRun = False
      , yes = True
      , json = asJson
      }

runPlatformUpgradeRecoverPulumi :: Maybe String -> String -> String -> Bool -> IO ()
runPlatformUpgradeRecoverPulumi mctx requested outcomeToken yes = do
  outcome <- case outcomeToken of
    "applied" -> pure RecoveryApplied
    "retry" -> pure RecoveryRetry
    _ -> dieT "--outcome must be either applied or retry"
  unless yes (dieT "refusing to record a Pulumi recovery decision without --yes")
  active <- activeTarget mctx
  (txPath, tx) <- loadUpgradeTransaction (active ^. #contextName) (Just requested)
  when (tx ^. #state == Completed) (dieT "a completed upgrade has no Pulumi outcome to recover")
  let workspace = platformWorkspaceFromTransaction tx
      bundle = takeDirectory (tx ^. #stagedHostRoot) </> "pulumi-plan"
      receiptPath = pulumiReceiptPath txPath tx
      pulumiRecord = find ((== PulumiApply) . (^. #name)) (tx ^. #phases)
  (metadata, _) <- verifyLocalReviewedPlanBundle bundle >>= either dieT pure
  existing <- readVerifiedPulumiReceipt receiptPath tx metadata >>= either dieT pure
  let isLegacySuccess = maybe False ((== Succeeded) . (^. #state)) pulumiRecord && existing == Nothing
      isAmbiguous = maybe False ((== ReceiptStarted) . receiptState) existing
      repeatsSameRecovery =
        maybe
          False
          (\receipt -> receiptState receipt == ReceiptOperatorAttested && receiptRecoveryOutcome receipt == Just outcome)
          existing
  unless (isLegacySuccess || isAmbiguous || repeatsSameRecovery) $
    dieT "Pulumi recovery is available only for an ambiguous started receipt or a successful legacy journal without a receipt"
  validatePulumiRecoveryEnvironment active workspace
  allowed <- (== Just "1") <$> lookupEnv "NAGARE_ALLOW_VM_REPLACEMENT"
  (identity, verifiedMetadata) <- verifyReviewedPlanBundleEvidence active workspace bundle allowed >>= either dieT pure
  TIO.putStrLn (renderPulumiRecoveryReview tx verifiedMetadata identity outcome)
  now <- currentTimestamp
  receipt <- writeRecoveryReceipt receiptPath tx verifiedMetadata outcome now >>= either dieT pure
  let recoveredState = case outcome of RecoveryApplied -> Succeeded; RecoveryRetry -> Failed
      evidence = renderPulumiReceiptEvidence receipt
      updated =
        recordUpgradePhase PulumiApply recoveredState evidence now tx
          & #state
          .~ TransactionFailed
          & #updatedAt
          .~ now
  writeUpgradeTransaction txPath updated
  TIO.putStrLn ("Recorded " <> recoveryOutcomeLabel outcome <> " recovery at " <> T.pack receiptPath)

validatePulumiRecoveryEnvironment :: ActiveTarget -> PlatformWorkspace -> IO ()
validatePulumiRecoveryEnvironment active workspace = do
  let context = active ^. #contextName
      profile = active ^. #profile
  case profile ^. #mode of
    Local -> pure ()
    Cloud -> do
      (gcloudAccount, adc) <- observeAdcForProject
      warnings <- either dieT pure (validateAdc (profile ^. #project) gcloudAccount adc)
      printPreflightWarnings warnings
  ensurePulumiInWorkspace context profile workspace
  case profile ^. #mode of
    Local -> pure ()
    Cloud -> do
      inputs <- projectGuardInputsFor context profile workspace
      either dieT pure (projectGuardVerdict inputs)
      TIO.putStrLn (renderProjectGuard inputs)

renderPulumiRecoveryReview :: UpgradeTransaction -> SavedPlanMetadata -> CurrentInfraIdentity -> PulumiRecoveryOutcome -> Text
renderPulumiRecoveryReview tx metadata identity outcome =
  T.unlines
    [ "Pulumi recovery review"
    , "Transaction: " <> tx ^. #id
    , "Context: " <> tx ^. #context
    , "Target version: " <> tx ^. #targetVersion
    , "Reviewed project/stack: " <> metadata ^. #project <> "/" <> metadata ^. #stack
    , "Reviewed backend: " <> metadata ^. #backend
    , "Reviewed plan digest: " <> metadata ^. #planDigest
    , "Reviewed Pulumi version: " <> metadata ^. #pulumiVersion
    , "Current project/stack: " <> identity ^. #currentProject <> "/" <> identity ^. #currentStack
    , "Current backend: " <> identity ^. #currentBackend
    , "Current Pulumi version: " <> identity ^. #currentPulumiVersion
    , "Recovery outcome: " <> recoveryOutcomeLabel outcome
    ]

recoveryOutcomeLabel :: PulumiRecoveryOutcome -> Text
recoveryOutcomeLabel RecoveryApplied = "applied"
recoveryOutcomeLabel RecoveryRetry = "retry"

findRetainedWorkspace :: ContextName -> Text -> IO FilePath
findRetainedWorkspace context wantedVersion = do
  stateRoot <- nagareStateDir
  let directory = stateRoot </> T.unpack (contextNameText context) </> "platform"
  exists <- doesDirectoryExist directory
  unless exists (dieT ("no retained platform workspaces exist for context '" <> contextNameText context <> "'"))
  names <- sort <$> listDirectory directory
  matches <- fmap catMaybes . forM names $ \name -> do
    let root = directory </> name
    candidate <- validatePlatformRoot ExplicitRoot root
    case candidate of
      Left _ -> pure Nothing
      Right paths -> do
        manifest <- readPayloadManifest paths
        pure $ case manifest of
          Right candidateManifest | candidateManifest ^. #platformVersion == wantedVersion -> Just root
          _ -> Nothing
  case reverse matches of
    root : _ -> pure root
    [] -> dieT ("the retained workspace for platform " <> wantedVersion <> " is unavailable; automatic rollback cannot proceed")

printUpgradeTransaction :: Bool -> UpgradeTransaction -> IO ()
printUpgradeTransaction asJson tx =
  if asJson then LBC.putStrLn (Aeson.encode tx) else TIO.putStr (renderUpgradeTransaction tx)

runPlatformUpgrade :: Maybe String -> UpgradeOpts -> IO ()
runPlatformUpgrade mctx options = do
  active <- activeTarget mctx
  if options ^. #apply
    then do
      unless (options ^. #yes) (dieT "refusing to apply an upgrade without --yes")
      resumeId <- maybe (dieT "--apply requires --resume TRANSACTION_ID") pure (options ^. #resume)
      (path, tx) <- loadUpgradeTransaction (active ^. #contextName) (Just resumeId)
      paths <- validatePlatformRoot ExplicitRoot (tx ^. #workspaceRoot) >>= either (dieT . renderPlatformPathError) pure
      manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
      let workspace = platformWorkspaceFromTransaction tx
      hostRoot <- hostConfigDir (active ^. #contextName)
      ops <- upgradeOps active workspace manifest (tx ^. #stagedHostRoot) hostRoot path
      result <- withEnvironment "NAGARE_SKIP_PULUMI_STACK_SELECT" "1" (applyUpgrade True ops tx)
      case result of
        Left err -> do
          readUpgradeTransaction path >>= either (const (pure ())) (printUpgradeTransaction (options ^. #json))
          dieT err
        Right completed -> printUpgradeTransaction (options ^. #json) completed
    else do
      when (options ^. #resume /= Nothing) (dieT "--resume is only valid with --apply")
      target <- maybe (dieT "a new upgrade plan requires --to VERSION") (either (dieT . ("invalid --to version: " <>) . renderVersionError) (pure . renderPlatformVersion) . parsePlatformVersion . T.pack) (options ^. #to)
      targetPaths <- resolveUpgradePayload target (options ^. #payloadRoot)
      manifest <- readPayloadManifest targetPaths >>= either (dieT . renderWorkspaceError) pure
      when (manifest ^. #platformVersion /= target) $
        dieT ("target payload reports version " <> manifest ^. #platformVersion <> ", expected " <> target)
      stateRoot <- nagareStateDir
      workspace <- preparePlatformWorkspace stateRoot (active ^. #contextName) targetPaths >>= either (dieT . renderWorkspaceError) pure
      now <- currentTimestamp
      let compactTime = T.take 20 (T.filter isAlphaNum now)
          txId = compactTime <> "-" <> target <> "-" <> T.take 8 (workspace ^. #digest)
      txPath <- upgradeTransactionPath (active ^. #contextName) txId
      txDirectory <- upgradeTransactionsDir (active ^. #contextName)
      let staged = txDirectory </> T.unpack txId </> "host-flake"
      hostRoot <- hostConfigDir (active ^. #contextName)
      hostExists <- doesDirectoryExist hostRoot
      unless hostExists (dieT "platform upgrade requires a generated host flake; run `nagarectl host init` first")
      _ <- stageHostFlake hostRoot staged (targetPaths ^. #nixosDir) (BuildVersion target (manifest ^. #sourceRevision)) >>= either dieT pure
      let tx =
            newUpgradeTransaction
              txId
              (contextNameText (active ^. #contextName))
              (active ^. #profile . #platformVersion)
              target
              (manifest ^. #payloadId)
              (workspace ^. #digest)
              (workspace ^. #root)
              staged
              (maybe False (`elem` manifest ^. #rollbackSupportedFrom) (active ^. #profile . #platformVersion))
              now
      writeUpgradeTransaction txPath tx
      ensurePulumiInWorkspace (active ^. #contextName) (active ^. #profile) workspace
      ops <- upgradeOps active workspace manifest staged hostRoot txPath
      result <- planUpgrade ops tx
      case result of
        Left err -> do
          readUpgradeTransaction txPath >>= either (const (pure ())) (printUpgradeTransaction (options ^. #json))
          dieT err
        Right planned -> printUpgradeTransaction (options ^. #json) planned

-- The transaction stores all paths needed to resume without re-resolving a tag.
platformWorkspaceFromTransaction :: UpgradeTransaction -> PlatformWorkspace
platformWorkspaceFromTransaction tx =
  PlatformWorkspace
    { root = tx ^. #workspaceRoot
    , payloadId = tx ^. #payloadId
    , platformVersion = tx ^. #targetVersion
    , sourceRevision = Nothing
    , digest = tx ^. #payloadDigest
    , pulumiDir = tx ^. #workspaceRoot </> "infra" </> "pulumi"
    , scriptsDir = tx ^. #workspaceRoot </> "scripts"
    , clusterDir = tx ^. #workspaceRoot </> "cluster"
    , nixosDir = tx ^. #workspaceRoot </> "nixos"
    , justfile = tx ^. #workspaceRoot </> "justfile"
    , docsDir = tx ^. #workspaceRoot </> "docs" </> "user"
    }

resolveUpgradePayload :: Text -> Maybe FilePath -> IO PlatformPaths
resolveUpgradePayload target override = case override of
  Just root -> validatePlatformRoot ExplicitRoot root >>= either (dieT . renderPlatformPathError) pure
  Nothing -> do
    current <- resolvePlatformPaths Nothing >>= either (dieT . renderPlatformPathError) pure
    currentManifest <- readPayloadManifest current >>= either (dieT . renderWorkspaceError) pure
    if currentManifest ^. #platformVersion == target
      then pure current
      else do
        (code, out, err) <-
          readProcessWithExitCode
            "nix"
            [ "build"
            , "github:shinzui/nagare/v" <> T.unpack target <> "#nagare-platform"
            , "--no-link"
            , "--print-out-paths"
            ]
            ""
        case (code, reverse (filter (not . null) (lines out))) of
          (ExitSuccess, packageRoot : _) ->
            validatePlatformRoot ExplicitRoot (packageRoot </> "share" </> "nagare") >>= either (dieT . renderPlatformPathError) pure
          _ -> dieT ("could not resolve Nagare release v" <> target <> " through Nix: " <> T.pack (err <> out))

upgradeOps :: ActiveTarget -> PlatformWorkspace -> PayloadManifest -> FilePath -> FilePath -> FilePath -> IO UpgradeOps
upgradeOps active workspace manifest staged hostRoot txPath = do
  generatedHostName <- readStagedHostName context staged >>= either dieT pure
  let hostEnvironment = hostSwitchEnvironment staged (hostSwitchIdentity generatedHostName)
  pure
    UpgradeOps
      { runUpgradePhase = runPhase hostEnvironment
      , upgradeResumeDecision = resumeDecision
      , saveUpgradeTransaction = writeUpgradeTransaction txPath
      , upgradeNow = currentTimestamp
      }
  where
    context = active ^. #contextName
    profile = active ^. #profile
    bootstrapEnvironment =
      [ ("NAGARE_CONTEXT", T.unpack (contextNameText context))
      , ("NAGARE_NIX_CACHE_ENABLED", if profile ^. #nixCacheEnabled then "1" else "0")
      , -- Force shell helpers to discard any stale context variables inherited
        -- from the operator's calling shell before they source the selected
        -- persisted context.
        ("NAGARE_RESOLVED_CONTEXT", "upgrade-transaction")
      ]
    reviewedPlanBundle = takeDirectory staged </> "pulumi-plan"
    reviewedKubernetesBundle = takeDirectory staged </> "kubernetes-plan"
    runPhase _ NixEvaluate =
      runExternal [ExitSuccess] "nix" ["eval", "path:" <> staged <> "#packages.x86_64-linux.nagare-image.drvPath"] ""
    -- EP-136: the preview phase persists one context-bound Pulumi plan beside
    -- the transaction. Apply verifies and consumes that exact bundle; it never
    -- launches a separate preview process.
    runPhase _ PulumiPreview = do
      guarded <- guardPulumiContext
      case guarded of
        Left err -> pure (Left err)
        Right evidence -> do
          allowed <- (== Just "1") <$> lookupEnv "NAGARE_ALLOW_VM_REPLACEMENT"
          alreadySaved <- doesDirectoryExist reviewedPlanBundle
          saved <-
            if alreadySaved
              then fmap (const ("Retained reviewed Pulumi plan at " <> T.pack reviewedPlanBundle <> "\n")) <$> verifyReviewedPlanBundle active workspace reviewedPlanBundle allowed
              else saveReviewedPlan active workspace reviewedPlanBundle allowed
          pure (fmap ((evidence <> "\n") <>) saved)
    runPhase _ PulumiApply = do
      ensurePulumiInWorkspace context profile workspace
      guarded <- guardPulumiContext
      case guarded of
        Left err -> pure (Left err)
        Right evidence -> do
          allowed <- (== Just "1") <$> lookupEnv "NAGARE_ALLOW_VM_REPLACEMENT"
          verified <- verifyReviewedPlanBundleEvidence active workspace reviewedPlanBundle allowed
          case verified of
            Left err -> pure (Left err)
            Right (identity, metadata) -> do
              loadedTx <- readUpgradeTransaction txPath
              case loadedTx of
                Left err -> pure (Left err)
                Right tx -> do
                  startedAt <- currentTimestamp
                  let receiptPath = pulumiReceiptPath txPath tx
                  started <- writeStartedReceipt receiptPath tx metadata startedAt
                  case started of
                    Left err -> pure (Left err)
                    Right _ -> do
                      applied <- applyVerifiedReviewedPlan workspace reviewedPlanBundle identity
                      resultAt <- currentTimestamp
                      recorded <-
                        writeResultReceipt
                          receiptPath
                          tx
                          metadata
                          (either (const ReceiptFailed) (const ReceiptSucceeded) applied)
                          resultAt
                      pure $ case (applied, recorded) of
                        (Left err, Right _) -> Left err
                        (Right applyEvidence, Right receipt) ->
                          Right (evidence <> "\n" <> applyEvidence <> "\n" <> renderPulumiReceiptEvidence receipt)
                        (Left applyError, Left receiptError) -> Left (applyError <> "\n" <> receiptError)
                        (Right _, Left receiptError) ->
                          Left
                            ( "Pulumi apply returned success but its durable receipt could not be recorded; outcome is ambiguous:\n"
                                <> receiptError
                            )
    runPhase _ KubernetesDiff = do
      guarded <- guardKubernetesContext active
      case guarded of
        Left err -> pure (Left err)
        Right evidence ->
          fmap ((evidence <> "\n") <>)
            <$> saveReviewedKubernetesPlan active workspace txPath reviewedKubernetesBundle
    runPhase hostEnvironment HostApply = do
      switched <- withEnvironmentValues hostEnvironment $ runExternal [ExitSuccess] "bash" [workspace ^. #scriptsDir </> "host-switch.sh"] ""
      case switched of
        Left err -> pure (Left err)
        Right evidence -> do
          committed <- commitStagedHostFlake staged hostRoot
          pure (evidence <$ committed)
    runPhase _ KubernetesApply = do
      migration <- applyReviewedKubernetesPlan active workspace txPath reviewedKubernetesBundle
      case migration of
        Left err -> pure (Left err)
        Right migrationEvidence -> do
          bootstrap <-
            withEnvironmentValues bootstrapEnvironment $
              withEnvironment "NAGARE_UPGRADE_APPLY" "1" $
                runExternal
                  [ExitSuccess]
                  "just"
                  ["--justfile", workspace ^. #justfile, "--working-directory", workspace ^. #root, bootstrapRecipe]
                  ""
          pure (fmap (\evidence -> migrationEvidence <> "\n" <> evidence) bootstrap)
    runPhase _ ClusterStamp = applyClusterMarker manifest
    runPhase _ ContextCommit =
      writeContextPlatformVersion context (manifest ^. #platformVersion)
        >>= pure . fmap (const ("context pin advanced to " <> manifest ^. #platformVersion))
    guardPulumiContext = case profile ^. #mode of
      Local ->
        pure (Right "context guard: local mode; no GCP project to confine")
      Cloud -> do
        pgi <- projectGuardInputsFor context profile workspace
        case projectGuardVerdict pgi of
          Left refusal -> pure (Left refusal)
          Right () -> pure (Right (renderProjectGuard pgi))
    bootstrapRecipe = case profile ^. #mode of
      Local -> "local-bootstrap"
      Cloud -> "cluster-bootstrap"
    phaseSatisfied NixEvaluate = doesFileExist (staged </> "flake.nix")
    phaseSatisfied PulumiPreview = pure False
    phaseSatisfied KubernetesDiff = pure False
    phaseSatisfied PulumiApply = pure False
    phaseSatisfied HostApply = do
      exists <- doesFileExist (hostRoot </> "flake.nix")
      if exists
        then (== Just (manifest ^. #platformVersion)) . (^. #version) . parseHostIdentity <$> TIO.readFile (hostRoot </> "flake.nix")
        else pure False
    phaseSatisfied KubernetesApply = pure False
    phaseSatisfied ClusterStamp = do
      observed <- captureTool "kubectl" ["get", "configmap", "nagare-platform-version", "-n", "nagare-system", "-o", "json", "--request-timeout=5s"]
      pure $ case observed >>= parseClusterIdentity of
        Just identity -> identity ^. #version == Just (manifest ^. #platformVersion)
        Nothing -> False
    phaseSatisfied ContextCommit = do
      current <- readContextProfile context
      pure (either (const False) ((== Just (manifest ^. #platformVersion)) . (^. #platformVersion)) current)
    resumeDecision PulumiApply state = pulumiResumeDecision state
    resumeDecision phase state
      | state /= Succeeded = pure RunPhase
      | otherwise = do
          satisfied <- phaseSatisfied phase
          pure (if satisfied then SkipPhase (phaseToken phase <> " postcondition is satisfied") else RunPhase)
    pulumiResumeDecision state = do
      loadedTx <- readUpgradeTransaction txPath
      case loadedTx of
        Left err -> pure (RefusePhase err)
        Right tx -> do
          localPlan <- verifyLocalReviewedPlanBundle reviewedPlanBundle
          case localPlan of
            Left err -> pure (RefusePhase err)
            Right (metadata, _) -> do
              receipt <- readVerifiedPulumiReceipt (pulumiReceiptPath txPath tx) tx metadata
              pure $ case receipt of
                Left err -> RefusePhase err
                Right Nothing
                  | state == Succeeded ->
                      RefusePhase
                        ( "the successful Pulumi journal predates durable receipts; run `nagarectl platform upgrade recover-pulumi "
                            <> tx ^. #id
                            <> " --outcome applied|retry --yes`"
                        )
                  | otherwise -> RunPhase
                Right (Just proof) -> case (receiptState proof, receiptRecoveryOutcome proof) of
                  (ReceiptSucceeded, Nothing) -> SkipPhase (renderPulumiReceiptEvidence proof)
                  (ReceiptFailed, Nothing) -> RunPhase
                  (ReceiptStarted, Nothing) ->
                    RefusePhase
                      ( "Pulumi may have changed provider state before its result was recorded; run `nagarectl platform upgrade recover-pulumi "
                          <> tx ^. #id
                          <> " --outcome applied|retry --yes`"
                      )
                  (ReceiptOperatorAttested, Just RecoveryApplied) -> SkipPhase (renderPulumiReceiptEvidence proof)
                  (ReceiptOperatorAttested, Just RecoveryRetry) -> RunPhase
                  _ -> RefusePhase "Pulumi apply receipt has an invalid state"

kubernetesManifestFileName, kubernetesReviewFileName, kubernetesMetadataFileName :: FilePath
kubernetesManifestFileName = "config-network.json"
kubernetesReviewFileName = "review.json"
kubernetesMetadataFileName = "metadata.json"

guardKubernetesContext :: ActiveTarget -> IO (Either Text Text)
guardKubernetesContext active = case active ^. #profile . #mode of
  Local -> pure (Right "cluster guard: local mode; no cloud cluster identity to confine")
  Cloud -> do
    let context = active ^. #contextName
        contextText = contextNameText context
    expectedNode <- readContextHostName context
    case expectedNode of
      Left err -> pure (Left err)
      Right expected -> do
        observed <- observeClusterGuard defaultClusterGuardOps contextText expected
        pure $ do
          inputs <- observed
          clusterGuardVerdict inputs
          Right (renderClusterGuard inputs)

currentKubernetesIdentity :: ActiveTarget -> PlatformWorkspace -> FilePath -> CertificateMigration.CurrentKubernetesIdentity
currentKubernetesIdentity active workspace txPath =
  CertificateMigration.CurrentKubernetesIdentity
    { CertificateMigration.currentTransactionId = T.pack (takeBaseName txPath)
    , CertificateMigration.currentContext = contextNameText (active ^. #contextName)
    , CertificateMigration.currentPayloadId = workspace ^. #payloadId
    , CertificateMigration.currentPayloadDigest = workspace ^. #digest
    }

saveReviewedKubernetesPlan :: ActiveTarget -> PlatformWorkspace -> FilePath -> FilePath -> IO (Either Text Text)
saveReviewedKubernetesPlan active workspace txPath destination = do
  exists <- doesPathExist destination
  if exists
    then do
      verified <- verifyReviewedKubernetesPlan active workspace txPath destination
      pure $
        fmap
          (\migration -> "Retained reviewed Kubernetes migration at " <> T.pack destination <> "\n" <> CertificateMigration.renderCertificateMigrationReview migration)
          verified
    else do
      observed <- captureCertificateMigrationInventory
      case observed of
        Left err -> pure (Left err)
        Right (config, optedIn, knativeCertificates, certManagerCertificates, secrets) ->
          case CertificateMigration.planCertificateMigration config optedIn knativeCertificates certManagerCertificates secrets of
            Left err -> pure (Left ("refusing Kubernetes migration plan: " <> err))
            Right migration -> save migration
  where
    save migration = do
      let parent = takeDirectory destination
      createDirectoryIfMissing True parent
      staging <- createTempDirectory parent ".nagare-kubernetes-plan-"
      setFileMode staging 0o700
      let manifestPath = staging </> kubernetesManifestFileName
          reviewPath = staging </> kubernetesReviewFileName
          metadataPath = staging </> kubernetesMetadataFileName
          manifestBytes = CertificateMigration.renderTargetConfigNetworkManifest
          reviewBytes = LBS.toStrict (Aeson.encode migration) <> "\n"
      BS.writeFile manifestPath manifestBytes
      BS.writeFile reviewPath reviewBytes
      setFileMode manifestPath 0o600
      setFileMode reviewPath 0o600
      manifestHash <- digestFile manifestPath
      reviewHash <- digestFile reviewPath
      let identity = currentKubernetesIdentity active workspace txPath
          metadata =
            CertificateMigration.KubernetesPlanMetadata
              { CertificateMigration.metadataSchemaVersion = 1
              , CertificateMigration.transactionId = CertificateMigration.currentTransactionId identity
              , CertificateMigration.context = CertificateMigration.currentContext identity
              , CertificateMigration.payloadId = CertificateMigration.currentPayloadId identity
              , CertificateMigration.payloadDigest = CertificateMigration.currentPayloadDigest identity
              , CertificateMigration.manifestDigest = manifestHash
              , CertificateMigration.reviewDigest = reviewHash
              }
      BS.writeFile metadataPath (LBS.toStrict (Aeson.encode metadata) <> "\n")
      setFileMode metadataPath 0o600
      diffResult <- case CertificateMigration.selectorChange migration of
        Nothing -> pure (Right "kubectl diff: TLS selector migration is not required")
        Just _ ->
          runExternal
            [ExitSuccess, ExitFailure 1]
            "kubectl"
            ["diff", "--server-side", "--force-conflicts", "--field-manager=nagare-upgrade", "-f", "-", "--request-timeout=5s"]
            (BC.unpack manifestBytes)
      case diffResult of
        Left err -> cleanupPlanStaging staging err
        Right diffEvidence -> do
          renamed <- try (renameDirectory staging destination)
          case renamed of
            Left (err :: IOException) -> cleanupPlanStaging staging ("could not publish Kubernetes migration bundle: " <> T.pack (show err))
            Right () ->
              pure
                ( Right
                    ( "Saved reviewed Kubernetes migration for context '"
                        <> CertificateMigration.currentContext identity
                        <> "' at "
                        <> T.pack destination
                        <> "\n"
                        <> CertificateMigration.renderCertificateMigrationReview migration
                        <> diffSuffix diffEvidence
                    )
                )
    diffSuffix evidence
      | T.null (T.strip evidence) = "kubectl diff: no server-side changes\n"
      | otherwise = evidence <> "\n"

verifyReviewedKubernetesPlan ::
  ActiveTarget ->
  PlatformWorkspace ->
  FilePath ->
  FilePath ->
  IO (Either Text CertificateMigration.CertificateMigrationPlan)
verifyReviewedKubernetesPlan active workspace txPath bundle = do
  loaded <- loadKubernetesPlanBundle bundle
  case loaded of
    Left err -> pure (Left err)
    Right (metadata, migration) -> do
      let identity = currentKubernetesIdentity active workspace txPath
      pure $ do
        first ("refusing Kubernetes plan: " <>) (CertificateMigration.verifyKubernetesPlanMetadata identity metadata)
        Right migration

loadKubernetesPlanBundle ::
  FilePath ->
  IO (Either Text (CertificateMigration.KubernetesPlanMetadata, CertificateMigration.CertificateMigrationPlan))
loadKubernetesPlanBundle bundle = do
  checked <- try (validateKubernetesPlanBundleSecurity bundle)
  case checked of
    Left (err :: IOException) -> pure (Left ("invalid Kubernetes plan bundle " <> T.pack bundle <> ": " <> T.pack (show err)))
    Right () -> do
      metadataBytes <- BS.readFile (bundle </> kubernetesMetadataFileName)
      reviewBytes <- BS.readFile (bundle </> kubernetesReviewFileName)
      decoded <- pure $ do
        metadata <- firstText "metadata.json" (Aeson.eitherDecodeStrict' metadataBytes)
        migration <- firstText "review.json" (Aeson.eitherDecodeStrict' reviewBytes)
        unless (metadataBytes == LBS.toStrict (Aeson.encode metadata) <> "\n") $
          Left "refusing Kubernetes plan: metadata.json is not in its canonical reviewed form"
        when (CertificateMigration.schemaVersion migration /= 1) (Left "unsupported Kubernetes review.json schema")
        Right (metadata, migration)
      case decoded of
        Left err -> pure (Left err)
        Right pair@(metadata, _) -> do
          manifestHash <- digestFile (bundle </> kubernetesManifestFileName)
          reviewHash <- digestFile (bundle </> kubernetesReviewFileName)
          pure $
            if manifestHash /= CertificateMigration.manifestDigest metadata
              then Left "refusing Kubernetes plan: config-network.json digest does not match metadata.json"
              else
                if reviewHash /= CertificateMigration.reviewDigest metadata
                  then Left "refusing Kubernetes plan: review.json digest does not match metadata.json"
                  else Right pair
  where
    firstText name = either (Left . (("invalid " <> name <> ": ") <>) . T.pack) Right

validateKubernetesPlanBundleSecurity :: FilePath -> IO ()
validateKubernetesPlanBundleSecurity bundle = do
  linked <- pathIsSymbolicLink bundle
  when linked (ioError (userError "bundle directory is a symlink"))
  bundleStatus <- getFileStatus bundle
  unless (isDirectory bundleStatus) (ioError (userError "bundle path is not a directory"))
  unless (privateMode bundleStatus) (ioError (userError "bundle directory is accessible by group or other users"))
  entries <- sort <$> listDirectory bundle
  unless (entries == sort [kubernetesManifestFileName, kubernetesMetadataFileName, kubernetesReviewFileName]) $
    ioError (userError "bundle must contain exactly config-network.json, metadata.json, and review.json")
  forM_ entries $ \entry -> do
    let path = bundle </> entry
    entryLinked <- pathIsSymbolicLink path
    when entryLinked (ioError (userError (entry <> " is a symlink")))
    status <- getFileStatus path
    unless (isRegularFile status) (ioError (userError (entry <> " is not a regular file")))
    unless (privateMode status) (ioError (userError (entry <> " is accessible by group or other users")))
  where
    privateMode status = fileMode status .&. 0o077 == 0

captureCertificateMigrationInventory ::
  IO
    ( Either
        Text
        ( CertificateMigration.ConfigNetworkObservation
        , Set Text
        , [CertificateMigration.CertificateResource]
        , [CertificateMigration.CertificateResource]
        , [CertificateMigration.SecretObservation]
        )
    )
captureCertificateMigrationInventory = do
  configBytes <- captureRequiredKubectl ["get", "configmap", "config-network", "-n", "knative-serving", "-o", "json", "--request-timeout=5s"]
  namespaceBytes <- captureRequiredKubectl ["get", "namespaces", "-l", "nagare.dev/app-namespace=true", "-o", "json", "--request-timeout=5s"]
  knativeBytes <- captureRequiredKubectl ["get", "certificates.networking.internal.knative.dev", "-A", "-o", "json", "--request-timeout=5s"]
  managerBytes <- captureRequiredKubectl ["get", "certificates.cert-manager.io", "-A", "-o", "json", "--request-timeout=5s"]
  secretBytes <- captureRequiredKubectl ["get", "secrets", "-A", "-o", "json", "--request-timeout=5s"]
  pure $ do
    config <- configBytes >>= first ("could not parse config-network: " <>) . CertificateMigration.parseConfigNetworkObservation
    namespaceInventory <- namespaceBytes
    optedIn <- maybe (Left "could not parse opted-in namespace inventory") Right (parseLabeledNamespaces namespaceInventory)
    knative <- knativeBytes >>= first ("could not parse Knative Certificate inventory: " <>) . CertificateMigration.parseKnativeCertificates
    managers <- managerBytes >>= first ("could not parse cert-manager Certificate inventory: " <>) . CertificateMigration.parseCertManagerCertificates
    secrets <- secretBytes >>= first ("could not parse Secret inventory: " <>) . CertificateMigration.parseSecretObservations
    Right (config, optedIn, knative, managers, secrets)

captureRequiredKubectl :: [String] -> IO (Either Text ByteString)
captureRequiredKubectl arguments = do
  result <- try (readProcessWithExitCode "kubectl" arguments "")
  pure $ case result of
    Left (err :: IOException) -> Left ("could not run kubectl: " <> T.pack (show err))
    Right (ExitSuccess, out, _) -> Right (BC.pack out)
    Right (ExitFailure code, out, err) ->
      Left
        ( "kubectl "
            <> T.unwords (map T.pack arguments)
            <> " exited "
            <> T.pack (show code)
            <> ": "
            <> T.strip (T.pack (err <> out))
        )

applyReviewedKubernetesPlan :: ActiveTarget -> PlatformWorkspace -> FilePath -> FilePath -> IO (Either Text Text)
applyReviewedKubernetesPlan active workspace txPath bundle = do
  guarded <- guardKubernetesContext active
  case guarded of
    Left err -> pure (Left err)
    Right guardEvidence -> do
      verified <- verifyReviewedKubernetesPlan active workspace txPath bundle
      case verified of
        Left err -> pure (Left err)
        Right migration -> case CertificateMigration.selectorChange migration of
          Nothing -> pure (Right (guardEvidence <> "\nKubernetes certificate migration: not required"))
          Just _ -> applyMigration guardEvidence migration
  where
    applyMigration guardEvidence migration = do
      observed <- captureCertificateMigrationInventory
      case observed of
        Left err -> pure (Left err)
        Right (config, _, knative, managers, secrets) ->
          case validateBeforeWrite migration config knative managers secrets of
            Left err -> pure (Left ("refusing Kubernetes migration apply: " <> err))
            Right () -> do
              let manifestBytes = CertificateMigration.renderTargetConfigNetworkManifest
              applied <-
                runExternal
                  [ExitSuccess]
                  "kubectl"
                  ["apply", "--server-side", "--force-conflicts", "--field-manager=nagare-upgrade", "-f", "-"]
                  (BC.unpack manifestBytes)
              case applied of
                Left err -> pure (Left err)
                Right applyEvidence -> do
                  converged <- waitForReviewedCertificates migration knative managers
                  case converged of
                    Left err -> pure (Left err)
                    Right waitEvidence -> do
                      deleted <- deleteReviewedSecrets migration
                      pure $
                        fmap
                          ( \deleteEvidence ->
                              guardEvidence
                                <> "\n"
                                <> CertificateMigration.renderCertificateMigrationReview migration
                                <> applyEvidence
                                <> "\n"
                                <> waitEvidence
                                <> deleteEvidence
                          )
                          deleted

validateBeforeWrite ::
  CertificateMigration.CertificateMigrationPlan ->
  CertificateMigration.ConfigNetworkObservation ->
  [CertificateMigration.CertificateResource] ->
  [CertificateMigration.CertificateResource] ->
  [CertificateMigration.SecretObservation] ->
  Either Text ()
validateBeforeWrite migration config knative managers secrets = do
  unless (CertificateMigration.externalDomainTlsEnabled config) $
    Left "external-domain-tls changed after review"
  case CertificateMigration.certificateSelector config of
    CertificateMigration.LegacyAllNamespaces -> Right ()
    CertificateMigration.TargetAppNamespaces -> Right ()
    CertificateMigration.UnsupportedSelector _ -> Left "namespace-wildcard-cert-selector changed after review"
  CertificateMigration.validateReviewedCleanup migration knative managers secrets

waitForReviewedCertificates ::
  CertificateMigration.CertificateMigrationPlan ->
  [CertificateMigration.CertificateResource] ->
  [CertificateMigration.CertificateResource] ->
  IO (Either Text Text)
waitForReviewedCertificates migration currentKnative currentManagers = do
  knativeResults <- traverse (waitIfPresent "certificates.networking.internal.knative.dev" currentKnative . CertificateMigration.knativeCertificate) (CertificateMigration.remove migration)
  case sequence knativeResults of
    Left err -> pure (Left err)
    Right knativeEvidence -> do
      managerResults <- traverse (waitIfPresent "certificates.cert-manager.io" currentManagers . CertificateMigration.certManagerCertificate) (CertificateMigration.remove migration)
      pure (fmap (T.concat . (knativeEvidence <>)) (sequence managerResults))
  where
    waitIfPresent resourceType observed reviewed =
      if any ((== CertificateMigration.certificateUid reviewed) . CertificateMigration.certificateUid) observed
        then
          fmap
            (fmap (const ("controller removed certificate: " <> certificateKey reviewed <> "\n")))
            ( runExternal
                [ExitSuccess]
                "kubectl"
                [ "wait"
                , "--for=delete"
                , resourceType <> "/" <> T.unpack (CertificateMigration.certificateName reviewed)
                , "-n"
                , T.unpack (CertificateMigration.certificateNamespace reviewed)
                , "--timeout=2m"
                ]
                ""
            )
        else pure (Right ("certificate already absent: " <> certificateKey reviewed <> "\n"))

deleteReviewedSecrets :: CertificateMigration.CertificateMigrationPlan -> IO (Either Text Text)
deleteReviewedSecrets migration = go [] (CertificateMigration.remove migration)
  where
    go evidence [] = pure (Right (T.concat (reverse evidence)))
    go evidence (chain : rest) = do
      observed <- captureCertificateMigrationInventory
      case observed of
        Left err -> pure (Left err)
        Right (_, _, knative, managers, secrets) ->
          case CertificateMigration.validateReviewedCleanup migration knative managers secrets of
            Left err -> pure (Left ("refusing Secret cleanup: " <> err))
            Right () -> do
              let reviewed = CertificateMigration.generatedSecret chain
                  present = any ((== CertificateMigration.secretUid reviewed) . CertificateMigration.secretUid) secrets
              if not present
                then go (("secret already absent: " <> secretKey reviewed <> "\n") : evidence) rest
                else do
                  deleted <-
                    runExternal
                      [ExitSuccess]
                      "kubectl"
                      [ "delete"
                      , "secret"
                      , T.unpack (CertificateMigration.secretResourceName reviewed)
                      , "-n"
                      , T.unpack (CertificateMigration.secretNamespace reviewed)
                      , "--wait=true"
                      ]
                      ""
                  case deleted of
                    Left err -> pure (Left err)
                    Right _ -> go (("deleted secret: " <> secretKey reviewed <> "\n") : evidence) rest

certificateKey :: CertificateMigration.CertificateResource -> Text
certificateKey resource = CertificateMigration.certificateNamespace resource <> "/" <> CertificateMigration.certificateName resource

secretKey :: CertificateMigration.SecretObservation -> Text
secretKey secret = CertificateMigration.secretNamespace secret <> "/" <> CertificateMigration.secretResourceName secret

applyClusterMarker :: PayloadManifest -> IO (Either Text Text)
applyClusterMarker manifest = do
  installedAt <- currentTimestamp
  let marker = LBC.unpack (Aeson.encode (clusterMarkerValue (identityFromPayload manifest) installedAt))
  runExternal [ExitSuccess] "kubectl" ["apply", "-f", "-"] marker

runExternal :: [ExitCode] -> FilePath -> [String] -> String -> IO (Either Text Text)
runExternal accepted executable arguments input = do
  result <- catch (Right <$> readProcessWithExitCode executable arguments input) (pure . Left)
  pure $ case result of
    Left (err :: IOException) -> Left ("could not run " <> T.pack executable <> ": " <> T.pack (show err))
    Right (code, out, err)
      | code `elem` accepted -> Right (T.strip (T.pack (out <> err)))
      | otherwise -> Left (T.pack executable <> " exited " <> T.pack (show code) <> ": " <> T.strip (T.pack (err <> out)))

currentTimestamp :: IO Text
currentTimestamp = T.pack . iso8601Show <$> getCurrentTime

withEnvironment :: String -> String -> IO a -> IO a
withEnvironment name envValue ioAction =
  bracket
    (lookupEnv name <* setEnv name envValue)
    (\saved -> maybe (unsetEnv name) (setEnv name) saved)
    (const ioAction)

withEnvironmentValues :: [(String, String)] -> IO a -> IO a
withEnvironmentValues variables ioAction =
  foldr (\(name, envValue) next -> withEnvironment name envValue next) ioAction variables

runHost :: Maybe String -> HostCommand -> IO ()
runHost globalContext = \case
  HostPlaceAgeKey options -> do
    active <- activeTarget (options ^. #context <|> globalContext)
    let context = active ^. #contextName
        profile = active ^. #profile
    when (profile ^. #mode == Local) $
      dieT "host age-key placement uses GCP IAP and is unavailable for local contexts"
    (_, workspace) <- resolvePlatformWorkspace context
    parentEnv <- getEnvironment
    let iapHelper = workspace ^. #scriptsDir </> "iap-ssh.sh"
        transport childEnv arguments =
          readCreateProcessWithExitCode ((proc iapHelper arguments) {env = Just childEnv}) ""
    placeAgeKeyWith transport parentEnv (contextNameText context) profile (options ^. #keyFile) (options ^. #force)
      >>= either dieT pure
    TIO.putStrLn
      ( "Host age key for context '"
          <> contextNameText context
          <> "' is ready on instance '"
          <> profile ^. #instanceName
          <> "'."
      )
  HostPath commandContext -> do
    active <- activeTarget (commandContext <|> globalContext)
    root <- hostConfigDir (active ^. #contextName)
    exists <- doesDirectoryExist root
    unless exists $ dieT ("host configuration does not exist for context '" <> contextNameText (active ^. #contextName) <> "'; run nagarectl host init first")
    putStrLn root
  HostName commandContext asJson -> do
    active <- activeTarget (commandContext <|> globalContext)
    let context = active ^. #contextName
    hostName <- readContextHostName context >>= either dieT pure
    if asJson
      then LBC.putStrLn (Aeson.encode (Aeson.object ["context" Aeson..= contextNameText context, "hostName" Aeson..= hostName]))
      else TIO.putStrLn hostName
  HostShow commandContext -> do
    active <- activeTarget (commandContext <|> globalContext)
    root <- hostConfigDir (active ^. #contextName)
    let modulePath = root </> "host.nix"
    exists <- doesFileExist modulePath
    unless exists $ dieT ("host configuration does not exist for context '" <> contextNameText (active ^. #contextName) <> "'; run nagarectl host init first")
    TIO.readFile modulePath >>= TIO.putStr
  HostInit options -> do
    active <- activeTarget (options ^. #context <|> globalContext)
    resolvedHostName <-
      case options ^. #hostName of
        Just explicitHostName -> pure (T.pack explicitHostName)
        Nothing -> do
          implicitHostName <- defaultHostName (active ^. #contextName) & either dieT pure
          collision <- findHostNameCollision (active ^. #contextName) implicitHostName >>= either dieT pure
          case collision of
            Nothing -> pure implicitHostName
            Just (owningContext, modulePath) ->
              dieT
                ( "default host name '"
                    <> implicitHostName
                    <> "' is already used by context '"
                    <> contextNameText owningContext
                    <> "' at "
                    <> T.pack modulePath
                    <> "; choose a distinct --host-name"
                )
    keys <- readAuthorizedKeys (options ^. #sshPublicKeyFiles) >>= either dieT pure
    (paths, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
    nixosSource <- makeAbsolute (paths ^. #nixosDir)
    let payloadBuild = BuildVersion (workspace ^. #platformVersion) (workspace ^. #sourceRevision)
    let profile = active ^. #profile
        defaultInstance = profile ^. #instanceName
        config =
          HostConfig
            { context = active ^. #contextName
            , name = resolvedHostName
            , instanceName = T.pack (fromMaybe (T.unpack defaultInstance) (options ^. #instanceName))
            , registryHost = T.pack (fromMaybe (T.unpack (profile ^. #registryHost)) (options ^. #registryHost))
            , deployUser = T.pack (options ^. #deployUser)
            , authorizedKeys = keys
            , ageKeyFile = options ^. #ageKeyFile
            , nagareNixosSource = nixosSource
            }
    root <- hostConfigDir (active ^. #contextName)
    if options ^. #dryRun
      then do
        TIO.putStrLn "DRY RUN — generated host configuration:"
        TIO.putStr (renderHostSummary root config)
        TIO.putStrLn "--- flake.nix ---"
        TIO.putStr (renderHostFlake config payloadBuild)
        TIO.putStrLn "--- host.nix ---"
        TIO.putStr (renderHostModule config)
      else do
        result <- installHostFlake (options ^. #force) config payloadBuild (options ^. #sopsFile) >>= either dieT pure
        let verb = case result of
              HostInstalled -> "Installed"
              HostReplaced -> "Replaced"
              HostUnchanged -> "Unchanged"
        TIO.putStrLn (verb <> " host configuration for context '" <> contextNameText (active ^. #contextName) <> "' at " <> T.pack root)

runKubeconfig :: Maybe String -> KubeconfigCommand -> IO ()
runKubeconfig globalContext = \case
  KubeconfigFetch options -> do
    active <- activeTarget (options ^. #context <|> globalContext)
    let profile = active ^. #profile
        context = active ^. #contextName
    when (profile ^. #mode == Local) $
      dieT "kubeconfig fetch uses the GCP IAP transport and is unavailable for local contexts"
    hostName <- readContextHostName context >>= either dieT pure
    (_, workspace) <- resolvePlatformWorkspace context
    destination <- maybe (kubeconfigPath context) pure (options ^. #output)
    let identity = KubeconfigIdentity (contextNameText context) hostName
        fetchOps = defaultFetchOps (workspace ^. #scriptsDir </> "iap-ssh.sh")
    fetchKubeconfig fetchOps identity profile destination >>= either dieT pure
    TIO.putStrLn
      ( "Wrote kubeconfig for context '"
          <> contextNameText context
          <> "' to "
          <> T.pack destination
          <> " (server https://"
          <> hostName
          <> ":6443)"
      )

runCluster :: Maybe String -> ClusterCommand -> IO ()
runCluster globalContext = \case
  ClusterGuard options -> do
    active <- activeTarget (options ^. #context <|> globalContext)
    let profile = active ^. #profile
        context = active ^. #contextName
        contextText = contextNameText context
    when (profile ^. #mode == Local) $
      dieT "cluster guard is a cloud-cluster identity check and is unavailable for local contexts"
    expectedNode <- readContextHostName context >>= either dieT pure
    observed <- observeClusterGuard defaultClusterGuardOps contextText expectedNode
    case observed of
      Left err ->
        if options ^. #json
          then do
            LBC.hPutStrLn stderr (Aeson.encode (Aeson.object ["guarded" Aeson..= False, "refusal" Aeson..= err]))
            exitFailure
          else dieT err
      Right inputs -> do
        let evidence = clusterGuardObservationsValue inputs
        case clusterGuardVerdict inputs of
          Left err ->
            if options ^. #json
              then do
                LBC.hPutStrLn stderr (Aeson.encode (Aeson.object ["guarded" Aeson..= False, "refusal" Aeson..= err, "observations" Aeson..= evidence]))
                exitFailure
              else dieT err
          Right () ->
            if options ^. #json
              then LBC.putStrLn (Aeson.encode (Aeson.object ["guarded" Aeson..= True, "observations" Aeson..= evidence]))
              else TIO.putStrLn (renderClusterGuard inputs)
  ClusterCertificatePolicy -> do
    probe <- probeCertificatePolicy
    TIO.putStr (renderInventory [probe])
    case probe ^. #status of
      StatusOk -> pure ()
      _ -> exitFailure

ensurePulumiForContext :: ContextName -> TargetProfile -> IO PlatformWorkspace
ensurePulumiForContext = ensurePulumiForContextWithInstallNotice True

ensurePulumiForContextWithInstallNotice :: Bool -> ContextName -> TargetProfile -> IO PlatformWorkspace
ensurePulumiForContextWithInstallNotice announceInstall name tp = do
  (paths, workspace) <- resolvePlatformWorkspace name
  -- EP-121: a source checkout's own `just` recipes run Pulumi in its infra/pulumi,
  -- so it must read the same context-owned stack config as the workspace.
  when (paths ^. #rootSource == SourceRoot) $
    linkContextStackConfig name (paths ^. #pulumiDir) >>= either dieT (const (pure ()))
  ensurePulumiInWorkspaceWithInstallNotice announceInstall name tp workspace
  pure workspace

ensurePulumiInWorkspace :: ContextName -> TargetProfile -> PlatformWorkspace -> IO ()
ensurePulumiInWorkspace = ensurePulumiInWorkspaceWithInstallNotice True

ensurePulumiInWorkspaceWithInstallNotice :: Bool -> ContextName -> TargetProfile -> PlatformWorkspace -> IO ()
ensurePulumiInWorkspaceWithInstallNotice announceInstall name tp workspace = do
  stateRoot <- nagareStateDir
  let penv = pulumiEnvFor stateRoot (contextNameText name) tp
      stack = penv ^. #stack
      pulumiDir = workspace ^. #pulumiDir
  -- EP-121: payload workspaces exclude every Pulumi.<stack>.yaml, so link the
  -- context-owned stack config in before Pulumi reads or writes it.
  linkContextStackConfig name pulumiDir >>= either dieT (const (pure ()))
  ensurePulumiProgramDependencies announceInstall pulumiDir
  createDirectoryIfMissing True (penv ^. #home)
  -- Only a local (@file://@) backend has a state directory to create; a GCS
  -- backend URL is @gs://…@ and must never be treated as a local path.
  case penv ^. #kind of
    PulumiBackendLocal ->
      createDirectoryIfMissing True (T.unpack (T.drop (T.length ("file://" :: Text)) (penv ^. #backendUrl)))
    PulumiBackendGcs -> pure ()
  -- EP-116: the passphrase file may hold the operator's real stack passphrase,
  -- so create it only when absent and never truncate it.
  let passphraseFile = penv ^. #home </> "passphrase"
  passphraseExists <- doesFileExist passphraseFile
  unless passphraseExists (writeFile passphraseFile "")
  setEnv "PULUMI_HOME" (penv ^. #home)
  setEnv "PULUMI_BACKEND_URL" (T.unpack (penv ^. #backendUrl))
  -- Pulumi prefers PULUMI_CONFIG_PASSPHRASE over the file whenever it is set,
  -- even to "", so drop an empty one and let the file decide.
  inheritedPassphrase <- lookupEnv "PULUMI_CONFIG_PASSPHRASE"
  when (maybe True null inheritedPassphrase) (unsetEnv "PULUMI_CONFIG_PASSPHRASE")
  setEnv "PULUMI_CONFIG_PASSPHRASE_FILE" passphraseFile
  setEnv "NAGARE_PULUMI_STACK" (T.unpack stack)
  selected <- pulumiQuiet ["-C", pulumiDir, "stack", "select", T.unpack stack]
  case selected of
    ExitSuccess -> pure ()
    ExitFailure _ -> do
      _ <- pulumiQuiet ["-C", pulumiDir, "stack", "init", T.unpack stack]
      void (pulumiQuiet ["-C", pulumiDir, "stack", "select", T.unpack stack])

-- | Bootstrap the GCS Pulumi state bucket for a context that opts into it. A
-- local/local-mode context is a no-op. A bootstrap failure is FATAL (EP-113): a
-- partially-applied bootstrap that lets @init@ report success is exactly the state
-- that hides a foreign-bucket refusal from the operator. The blast radius is small,
-- because the bootstrap is a no-op for every context whose Pulumi backend is @local@
-- (the default) — only a context that explicitly opted into
-- @NAGARE_PULUMI_BACKEND=gcs@ can reach the failure at all. Recovery is to fix the
-- cause the message names and re-run, both call sites being idempotent.
bootstrapGcsIfNeeded :: Bool -> Text -> TargetProfile -> Maybe Text -> IO ()
bootstrapGcsIfNeeded dryRun ctx tp mMember =
  bootstrapPulumiStateBucket dryRun ctx tp mMember
    >>= either (\msg -> dieT ("GCS state-bucket bootstrap failed: " <> msg)) pure

-- | EP-121: payload workspaces exclude node_modules, so a clone-free Pulumi run
-- would fail with "the Pulumi SDK has not been installed". Install the program's
-- locked dependencies once per workspace, before any Pulumi command needs them.
ensurePulumiProgramDependencies :: Bool -> FilePath -> IO ()
ensurePulumiProgramDependencies announceInstall pulumiDir = do
  installed <- doesFileExist (pulumiDir </> "node_modules" </> "@pulumi" </> "pulumi" </> "package.json")
  locked <- doesFileExist (pulumiDir </> "package-lock.json")
  when (locked && not installed) $ do
    when announceInstall $
      TIO.hPutStrLn stderr ("Installing the Pulumi program's locked Node dependencies in " <> T.pack pulumiDir <> " ...")
    result <-
      try (readCreateProcessWithExitCode ((proc "npm" ["ci", "--no-audit", "--no-fund"]) {cwd = Just pulumiDir}) "")
    case result of
      Left (err :: IOException) ->
        dieT ("could not run `npm ci` for the Pulumi program (Node.js and npm are required): " <> T.pack (show err))
      Right (ExitSuccess, _, _) -> pure ()
      Right (ExitFailure code, _, err) ->
        dieT ("`npm ci` failed in " <> T.pack pulumiDir <> " (exit " <> T.pack (show code) <> "):\n" <> T.strip (T.pack err))

pulumiQuiet :: [String] -> IO ExitCode
pulumiQuiet args =
  runIt `catch` handleMissing
  where
    runIt = do
      (code, _, _) <- readProcessWithExitCode "pulumi" args ""
      pure code
    handleMissing :: IOException -> IO ExitCode
    handleMissing _ = pure (ExitFailure 127)

ensurePulumiForActiveContext :: Maybe String -> IO (ContextName, PlatformWorkspace)
ensurePulumiForActiveContext mctx = do
  active <- activeTarget mctx
  workspace <- ensurePulumiForContext (active ^. #contextName) (active ^. #profile)
  pure (active ^. #contextName, workspace)

runServerStatus :: Maybe String -> ServerStatusOpts -> IO ()
runServerStatus mctx o = do
  (_, workspace) <- ensurePulumiForActiveContext mctx
  tp <- activeProfile mctx
  let invOpts = inventoryOptsFor (workspace ^. #pulumiDir) (workspace ^. #scriptsDir </> "iap-ssh.sh") tp & #skipVm .~ o ^. #skipVm
  probes <- gatherInventory tp invOpts
  (_, versionStatus) <- gatherPlatformStatus mctx
  TIO.putStr (renderInventory (probes <> [platformProbe versionStatus]))

-- | @doctor@: gather EP-38's probes, re-grade them into a remediation checklist,
-- print it, and exit non-zero iff any check FAILs. Read-only and advisory —
-- every remediation is printed text the operator runs themselves
-- ('gatherInventory' degrades unreachable sources to @UNKNOWN@, so the report is
-- always printed; only the exit code varies).
runDoctor :: Maybe String -> DoctorOpts -> IO ()
runDoctor mctx o = do
  (_, workspace) <- ensurePulumiForActiveContext mctx
  tp <- activeProfile mctx
  let invOpts = inventoryOptsFor (workspace ^. #pulumiDir) (workspace ^. #scriptsDir </> "iap-ssh.sh") tp & #skipVm .~ o ^. #skipVm
  probes <- gatherInventory tp invOpts
  (_, versionStatus) <- gatherPlatformStatus mctx
  let checks = gradeChecksAt (workspace ^. #root) (workspace ^. #pulumiDir) (workspace ^. #scriptsDir </> "iap-ssh.sh") tp (probes <> [platformProbe versionStatus])
  TIO.putStr (formatDoctor checks)
  unless (doctorExitOk checks) (exitWith (ExitFailure 1))

runInfraGuard :: Maybe String -> Bool -> IO ()
runInfraGuard mctx allowReplacementFlag = do
  (_, workspace) <- ensurePulumiForActiveContext mctx
  tp <- activeProfile mctx
  case tp ^. #mode of
    Local -> TIO.putStrLn "infra guard: local mode has no GCE instance to protect"
    Cloud -> do
      ctx <- fromMaybe "default" <$> lookupEnv "NAGARE_PULUMI_STACK"
      envAllowed <- (== Just "1") <$> lookupEnv "NAGARE_ALLOW_VM_REPLACEMENT"
      result <- instanceReplacementGuard tp workspace ctx (allowReplacementFlag || envAllowed)
      case result of
        Right message -> TIO.putStr message
        Left message -> TIO.hPutStr stderr (ensureNewline message) >> exitFailure
  where
    ensureNewline t = if "\n" `T.isSuffixOf` t then t else t <> "\n"

runInfraPreview :: Maybe String -> InfraPreviewOpts -> IO ()
runInfraPreview mctx options = case options ^. #inventory of
  Just candidate -> do
    when (options ^. #allowReplacement) (dieT "--allow-replacement belongs to the reviewed lifecycle decision; it cannot be attached to an inventory preview")
    runInventoryPlan mctx candidate (options ^. #savePlan)
  Nothing -> do
    (active, workspace) <- prepareInfraMutation mctx
    result <- saveReviewedPlan active workspace (options ^. #savePlan) (options ^. #allowReplacement)
    either dieT TIO.putStr result

runInfraApply :: Maybe String -> InfraApplyOpts -> IO ()
runInfraApply mctx options = do
  unless (options ^. #yes) $
    dieT "refusing to apply a reviewed infrastructure plan without --yes"
  inventoryReview <- doesFileExist (options ^. #plan </> "review.sha256")
  if inventoryReview
    then do
      when (options ^. #allowReplacement) (dieT "--allow-replacement belongs to the reviewed lifecycle decision and cannot alter an inventory review")
      runInventoryApply mctx (options ^. #plan) True
    else do
      (active, workspace) <- prepareInfraMutation mctx
      result <- applyReviewedPlan active workspace (options ^. #plan) (options ^. #allowReplacement)
      either dieT TIO.putStr result

runInfraDestroy :: Maybe String -> Bool -> IO ()
runInfraDestroy mctx yes = do
  unless yes $
    dieT "refusing to destroy the selected context's infrastructure without --yes"
  (active, workspace) <- prepareInfraMutation mctx
  let stack = T.unpack (contextNameText (active ^. #contextName))
  result <- runExternal [ExitSuccess] "pulumi" ["-C", workspace ^. #pulumiDir, "destroy", "--stack", stack, "--yes", "--non-interactive"] ""
  either dieT TIO.putStr result

-- | Build the production cloud adapter from the same composed declarations the
-- generic planner sees. Other domains retain their refusing adapters until
-- their production runtimes are registered by this child or later children.
runPlatformBootstrapPlan :: Maybe String -> FilePath -> IO ()
runPlatformBootstrapPlan mctx output = do
  active <- activeTarget mctx
  (paths, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  kubeVersion <- readBootstrapKubeVersion active
  let root = workspace ^. #root
      profile = active ^. #profile
      knownName value = either (error . T.unpack) (\name -> name) (Resource.mkName value)
      knownKey value = either (error . T.unpack) (\key -> key) (Resource.mkLogicalKey value)
      foundationOwner = either (error . T.unpack) (\scope -> scope) (Resource.mkScopeId Resource.Platform "foundation")
      clusterOwner = either (error . T.unpack) (\scope -> scope) (Resource.mkScopeId Resource.Platform "cluster")
      cluster = Resource.mintResourceId clusterOwner (knownKey "cluster") (knownName "cluster")
      observabilityInputs = pinnedObservabilityInputs cluster root kubeVersion
      granted = map packagedOwner observabilityInputs
      foundation = FoundationInput foundationOwner cluster
        (root </> "cluster/bootstrap/job-runs/resourcequota.yaml") granted
      issuer = case profile ^. #mode of
        Local -> LocalIssuer
        Cloud -> CloudIssuer
          (either (error . T.unpack) (acmeDirectoryUrl) (parseAcmeDirectory (profile ^. #acmeDirectory)))
          (profile ^. #acmeEmail)
          (profile ^. #project)
          (profile ^. #externalDomainTlsEnabled)
  when (profile ^. #mode == Cloud && T.null (profile ^. #acmeEmail))
    (dieT "bootstrap requires the selected context's ACME contact")
  when (profile ^. #mode == Local && profile ^. #nixCacheEnabled)
    (dieT "Attic cache is available only in cloud bootstrap mode")
  when (profile ^. #mode == Local && profile ^. #externalDomainTlsEnabled)
    (dieT "external domain TLS belongs to cloud bootstrap; local TLS is enabled by its own issuer")
  rawUpstream <- configuredUpstreamInputsWithIssuer cluster root (profile ^. #baseDomain)
    (profile ^. #registryHost) issuer >>= either dieT pure
  let controllerRegistry = if profile ^. #mode == Local
        then profile ^. #registryHost else registryPrefix profile
  (controllerImageScope, controllerImage, controllerPublish) <-
    compileControllerImage root controllerRegistry >>= either (dieT . T.pack . show) pure
  upstream <- either dieT pure
    (bindNetCertManagerControllerImage cluster controllerImage controllerPublish rawUpstream)
  metricsInput <- case observabilityInputs of
    firstRelease : _ | Resource.nameText (packagedName firstRelease) == "vmks" ->
      pure firstRelease
    _ -> dieT "pinned observability components have no metrics release"
  alertmanagerEnabled <- readAlertmanagerEnabled
    (packagedValues metricsInput) (packagedValuesDigest metricsInput) >>= either dieT pure
  secretObjects <- loadObservabilitySecretObjects root
    (contextNameText (active ^. #contextName)) alertmanagerEnabled >>= either dieT pure
  (secretScope, secretNative, secretIds) <- compileObservabilitySecrets foundation secretObjects
    >>= either (dieT . T.pack . show) pure
  let orderedObservability = case observabilityInputs of
        firstRelease : rest -> firstRelease
          {packagedDependencies = map ResourceReference.OrderedAfter secretIds
            <> packagedDependencies firstRelease} : rest
        [] -> []
  (observabilityScopes, observabilityNative) <- compilePinnedObservability foundationOwner orderedObservability
    >>= either (dieT . T.pack . show) pure
  let metricsRelease = packagedReleaseId metricsInput
  (observabilityExtra, extraNative) <- compileObservabilityExtras root foundation metricsRelease
    >>= either (dieT . T.pack . show) pure
  cacheComponent <- if profile ^. #nixCacheEnabled
    then Just <$> (compilePackagedCache root foundation (profile ^. #project)
      (registryPrefix profile) (profile ^. #backupBucket) (profile ^. #nixCacheBucket)
      >>= either (dieT . T.pack . show) pure)
    else pure Nothing
  authImages <- fmap Map.fromList $ forM
    [("en", "NAGARE_AUTH_EN_IMAGE"), ("shomei", "NAGARE_AUTH_SHOMEI_IMAGE"),
     ("nagare-access", "NAGARE_AUTH_ACCESS_IMAGE")] $ \(service, variable) -> do
      value <- lookupEnv variable >>= maybe (dieT ("bootstrap requires " <> T.pack variable <> " as an immutable image reference")) pure
      pure (service, T.pack value)
  backupBackend <- either dieT pure (storeBackendFor profile (profile ^. #backupBucket))
  localStore <- case backupBackend of
    MinioBackend store -> Just <$> (compileLocalObjectStore root foundation store
      >>= either (dieT . T.pack . show) pure)
    GcsBackend {} -> pure Nothing
  let authMode = if profile ^. #mode == Local then LocalAuth else CloudAuth
  (rawAuth, authDatabases) <- either (dieT . T.pack . show) pure
    (packagedAuthInputs root foundation authMode (profile ^. #baseDomain) authImages backupBackend)
  localPrerequisites <- case localStore of
    Nothing -> pure []
    Just (_, members) -> case
      [resource ^. #identity | (resource, _) <- Map.elems members,
        case resource ^. #address of
          Resource.Kubernetes _ "batch" kind _ name ->
            Resource.nameText kind == "job" && Resource.nameText name == "minio-make-bucket"
          _ -> False] of
      [bucketJob] -> pure [bucketJob]
      _ -> dieT "local object store has no unique bucket preparation Job"
  let auth = rawAuth {authExtraPrerequisites = localPrerequisites}
  -- The accepted completion marker depends on the previous resource set. Build
  -- the new set without that marker, then replace the marker in the final
  -- composition against the unmodified snapshot.
  let stampOwner = either (error . T.unpack) (\scope -> scope)
        (Resource.mkScopeId Resource.Platform "bootstrap-stamp")
      unstampedSnapshot = either (error . show) (\loaded -> loaded)
        (ResourceInventory.mkScopeSnapshot
          (ResourceInventory.snapshotBinding snapshot)
          (Map.delete stampOwner (ResourceInventory.snapshotScopes snapshot))
          (ResourceInventory.snapshotReservations snapshot))
  (base, baseNative) <- compileBootstrapWithAuthAndScopes unstampedSnapshot
    (BootstrapInput foundation Nothing upstream [controllerImageScope]) auth authDatabases
    (maybe [] (pure . fst) localStore)
    >>= either (dieT . T.pack . show) pure
  let certManagerOwner = either (error . T.unpack) (\scope -> scope) (Resource.mkScopeId Resource.Platform "cert-manager")
      certManagerIds =
        [resource ^. #identity
        | ResourceInventory.Managed resource <- ResourceInventory.inventoryDeclarations (ResourceInventory.candidateInventory base)
        , resource ^. #owner == certManagerOwner]
      orderHelm resource
        | resource ^. #executor == ResourceInventory.HelmExecutor = resource
            {ResourceInventory.dependencies = map ResourceReference.OrderedAfter certManagerIds
              <> resource ^. #dependencies}
        | otherwise = resource
      orderDeclaration = \case
        ResourceInventory.Managed resource -> ResourceInventory.Managed (orderHelm resource)
        other -> other
      orderScope scope = ResourceInventory.mkScopeDeclaration
        (ResourceInventory.scopeId scope)
        [bundle {ResourceInventory.declarations = map orderDeclaration (ResourceInventory.declarations bundle)}
        | bundle <- ResourceInventory.scopeBundles scope]
  orderedObservabilityScopes <- either (dieT . T.pack . show) pure
    (traverse orderScope observabilityScopes)
  let
      orderedObservabilityNative = Map.map (\(resource, bytes) -> (orderHelm resource, bytes)) observabilityNative
      (cacheScopes, cacheNative) = case cacheComponent of
        Nothing -> ([], Map.empty)
        Just (imageScope, cacheScope, native) -> ([imageScope, cacheScope], native)
      localNative = maybe Map.empty snd localStore
      nativeMaps = [baseNative, orderedObservabilityNative, extraNative, secretNative, cacheNative, localNative]
      native = Map.unions nativeMaps
  unless (Map.size native == sum (map Map.size nativeMaps))
    (dieT "bootstrap component native members share an identity")
  extra <- case orderedObservabilityScopes <> [observabilityExtra, secretScope] <> cacheScopes of
    firstScope : remaining -> pure (ResourceInventory.ReplaceScope firstScope NE.:| map ResourceInventory.ReplaceScope remaining)
    [] -> dieT "pinned bootstrap component set is empty"
  candidate <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeInventory unstampedSnapshot (ResourceInventory.candidateChanges base <> extra))
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  installedAt <- acceptedBootstrapInstalledAt active snapshot cluster
    (identityFromPayload manifest) candidate
  (stampScope, stampNative) <- either (dieT . T.pack . show) pure
    (compileBootstrapStamp cluster (clusterMarkerValue (identityFromPayload manifest) installedAt) candidate)
  stamped <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeInventory snapshot (ResourceInventory.candidateChanges candidate
      <> (ResourceInventory.ReplaceScope stampScope NE.:| [])))
  let completeNative = Map.union native stampNative
  unless (Map.size completeNative == Map.size native + Map.size stampNative)
    (dieT "bootstrap completion marker shares a native identity")
  Inventory.planInventoryCandidateWith (inventoryPlanRegistryWithNative active workspace completeNative)
    active stamped output

-- Reuse the recorded install time only when it reconstructs the accepted
-- marker's exact desired specification. A changed payload gets a new time;
-- a changed live marker remains visible as drift to the inventory planner.
acceptedBootstrapInstalledAt
  :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> Resource.ResourceId
  -> ReleaseIdentity -> ResourceInventory.CompositionCandidate -> IO Text
acceptedBootstrapInstalledAt active snapshot cluster identity candidate = do
  now <- currentTimestamp
  let owner = either (error . T.unpack) (\scope -> scope)
        (Resource.mkScopeId Resource.Platform "bootstrap-stamp")
      acceptedSpecs =
        [resource ^. #spec
        | Just (_, scope) <- [Map.lookup owner (ResourceInventory.snapshotScopes snapshot)]
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle]
  case acceptedSpecs of
    [acceptedSpec] -> do
      (code, output, err) <- readProcessWithExitCode "kubectl"
        ["--context", T.unpack (contextNameText (active ^. #contextName))
        , "-n", "nagare-system", "get", "configmap", "nagare-platform-version"
        , "-o", "json", "--ignore-not-found"] ""
      unless (code == ExitSuccess)
        (dieT ("could not inspect accepted bootstrap marker: " <> T.pack err))
      case Aeson.eitherDecodeStrict' (BC.pack output) :: Either String Aeson.Value of
        Right (Aeson.Object live) -> case AesonMap.lookup "data" live of
          Just (Aeson.Object fields) -> case AesonMap.lookup "installedAt" fields of
            Just (Aeson.String installedAt) | not (T.null installedAt) -> do
              let expected = compileBootstrapStamp cluster
                    (clusterMarkerValue identity installedAt) candidate
              pure $ case expected of
                Right (_, native) | any ((== acceptedSpec) . (^. #spec) . fst) (Map.elems native) -> installedAt
                _ -> now
            _ -> pure now
          _ -> pure now
        _ -> pure now
    _ -> pure now

readBootstrapKubeVersion :: ActiveTarget -> IO Text
readBootstrapKubeVersion active = do
  guardKubernetesContext active >>= either dieT pure
  (code, output, err) <- readProcessWithExitCode "kubectl"
    ["--context", T.unpack (contextNameText (active ^. #contextName)), "version", "-o", "json"] ""
  unless (code == ExitSuccess) (dieT ("could not inspect selected Kubernetes version: " <> T.pack err))
  value <- either (dieT . T.pack) pure (Aeson.eitherDecodeStrict' (BC.pack output) :: Either String Aeson.Value)
  case value of
    Aeson.Object root -> case AesonMap.lookup "serverVersion" root of
      Just (Aeson.Object server) -> case AesonMap.lookup "gitVersion" server of
        Just (Aeson.String version) | not (T.null version) -> pure version
        _ -> dieT "Kubernetes server version has no gitVersion"
      _ -> dieT "Kubernetes version response has no serverVersion"
    _ -> dieT "Kubernetes version response is not an object"

runInventoryStatus :: Maybe String -> Maybe String -> Bool -> Maybe FilePath -> IO ()
runInventoryStatus mctx requested json gcOutput = do
  active <- activeTarget mctx
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
  project <- either dieT pure (Resource.mkName (active ^. #profile . #project))
  let targetBinding = Resource.ContextBinding context project
  unless (InventoryStore.headBinding (InventoryPlan.historyHead history) == targetBinding)
    (dieT "accepted inventory belongs to a different context or project")
  snapshot <- either (dieT . T.pack . show) pure (ResourceInventory.mkScopeSnapshot
    targetBinding
    (Map.map (\(revision, scope) -> (InventoryStore.revisionGeneration revision, scope))
      (InventoryPlan.historyAccepted history)) (InventoryPlan.historyReservations history))
  inventory <- either (dieT . T.pack . show) pure (ResourceInventory.composeSnapshot snapshot)
  (kubernetesNative, helmNative) <- InventoryStatus.loadAcceptedNative store history inventory
    >>= either dieT pure
  (retainedKubernetesNative, retainedHelmNative) <- InventoryStatus.loadRetainedNative store history inventory
    >>= either dieT pure
  pathsResult <- resolvePlatformPaths Nothing
  paths <- either (dieT . renderPlatformPathError) pure pathsResult
  stateRoot <- nagareStateDir
  workspaceResult <- findPlatformWorkspace stateRoot (active ^. #contextName) paths
  workspace <- either (dieT . renderWorkspaceError) pure workspaceResult
  let binding = ResourceInventory.inventoryBinding inventory
      declarations = ResourceInventory.inventoryDeclarations inventory
      scopes = Map.elems (ResourceInventory.inventoryScopes inventory)
      managed = [resource | ResourceInventory.Managed resource <- ResourceInventory.inventoryDeclarations inventory]
      byId = Map.fromList [(resource ^. #identity, resource) | resource <- managed]
      ids executor = [resource ^. #identity | resource <- managed, resource ^. #executor == executor]
      retainedIds executor = [resource | (resource, (_, declaration)) <- Map.toAscList (InventoryPlan.historyRetained history),
              declaration ^. #executor == executor]
  registrations <- either dieT pure (InventoryCloud.registrationsFromDeclarations declarations)
  artifactSpecs <- either dieT pure (InventoryArtifact.artifactExecutionSpecsFromDeclarations declarations)
  cacheSpecs <- either dieT pure (cacheSpecsFromDeclarations declarations)
  topicSpecs <- either dieT pure (topicSpecsFromDeclarations (declarations <>
    [ResourceInventory.Managed resource | (_, resource) <- Map.elems (InventoryPlan.historyRetained history)]))
  hostInputs <- either dieT pure (InventoryHost.hostExecutionInputsFromScopes scopes)
  observationStartedAt <- currentTimestamp
  pulumi <- if null registrations
    then pure (Inventory.executionBlockedAdapterFor ResourceInventory.PulumiExecutor)
    else inventoryPulumiAdapter active workspace binding scopes registrations
  let artifact = if Map.null artifactSpecs
        then Inventory.executionBlockedAdapterFor ResourceInventory.ArtifactExecutor
        else inventoryArtifactAdapter active workspace artifactSpecs
  host <- maybe (pure (Inventory.executionBlockedAdapterFor ResourceInventory.HostExecutor))
    (inventoryHostAdapter active workspace) hostInputs
  (cache, cacheKey) <- inventoryCacheAdapter active workspace binding cacheSpecs
  broker <- inventoryBrokerAdapter active binding topicSpecs
    (acceptedTopicIds history `Set.union` Set.fromList (retainedIds ResourceInventory.BrokerExecutor))
  kubernetes <- inventoryKubernetesAdapter active binding
    cacheKey kubernetesNative
  helm <- inventoryHelmAdapter active workspace binding helmNative
  retainedKubernetes <- inventoryKubernetesAdapter active binding cacheKey retainedKubernetesNative
  retainedHelm <- inventoryHelmAdapter active workspace binding retainedHelmNative
  let inspect adapter executor = do
        let requestedIds = ids executor
        if null requestedIds then pure [] else do
          result <- InventoryAdapter.adapterObserve adapter requestedIds
          pure $ case result of
            Left reason -> [(resource, InventoryAdapter.ObservationUnavailable reason) | resource <- requestedIds]
            Right facts ->
              [(resource, Map.findWithDefault (InventoryAdapter.ObservationUnavailable
                "adapter omitted this resource") resource (InventoryAdapter.observationMap facts))
              | resource <- requestedIds]
  kubeFacts <- inspect kubernetes ResourceInventory.KubernetesExecutor
  helmFacts <- inspect helm ResourceInventory.HelmExecutor
  pulumiFacts <- inspect pulumi ResourceInventory.PulumiExecutor
  artifactFacts <- inspect artifact ResourceInventory.ArtifactExecutor
  hostFacts <- inspect host ResourceInventory.HostExecutor
  cacheFacts <- inspect cache ResourceInventory.CacheExecutor
  brokerFacts <- inspect broker ResourceInventory.BrokerExecutor
  let inspectRetained adapter executor = do
        let requestedIds = retainedIds executor
        if null requestedIds then pure [] else do
          result <- InventoryAdapter.adapterObserve adapter requestedIds
          pure $ case result of
            Left reason -> [(resource, InventoryAdapter.ObservationUnavailable reason) | resource <- requestedIds]
            Right facts ->
              [(resource, Map.findWithDefault (InventoryAdapter.ObservationUnavailable
                "adapter omitted this retained resource") resource (InventoryAdapter.observationMap facts))
              | resource <- requestedIds]
  retainedKubeFacts <- inspectRetained retainedKubernetes ResourceInventory.KubernetesExecutor
  retainedHelmFacts <- inspectRetained retainedHelm ResourceInventory.HelmExecutor
  retainedBrokerFacts <- inspectRetained broker ResourceInventory.BrokerExecutor
  let helmObserved = Map.fromList helmFacts
      helmStatusOps = helmRuntimeOps (inventoryHelmRuntimeConfig active workspace binding helmNative)
      helmObservedPhysical = \case
        InventoryAdapter.ObservedPresent _ -> True
        InventoryAdapter.ObservedDrifted _ _ -> True
        InventoryAdapter.ObservedReplacementRequired _ _ -> True
        _ -> False
  helmHealthPairs <- forM (ids ResourceInventory.HelmExecutor) $ \resourceId -> do
    health <- case Map.lookup resourceId helmObserved of
      Just fact | helmObservedPhysical fact -> do
        state <- helmObserve helmStatusOps resourceId
        pure (helmStateHealth resourceId fact state)
      _ -> pure Nothing
    pure (resourceId, health)
  let retainedHelmObserved = Map.fromList retainedHelmFacts
      retainedHelmStatusOps = helmRuntimeOps (inventoryHelmRuntimeConfig active workspace binding retainedHelmNative)
  retainedHelmHealthPairs <- forM (retainedIds ResourceInventory.HelmExecutor) $ \resourceId -> do
    health <- case Map.lookup resourceId retainedHelmObserved of
      Just fact | helmObservedPhysical fact -> do
        state <- helmObserve retainedHelmStatusOps resourceId
        pure (helmStateHealth resourceId fact state)
      _ -> pure Nothing
    pure (resourceId, health)
  let healthConfig = KubernetesRuntimeConfig context (contextNameText (active ^. #contextName))
        (fmap (fmap (const ())) (guardKubernetesContext active))
      kubeObserved = Map.fromList kubeFacts
  healthPairs <- forM managed $ \resource -> do
    let resourceId = resource ^. #identity
        physical = case Map.lookup resourceId kubeObserved of
          Just (InventoryAdapter.ObservedPresent uid) -> Just uid
          Just (InventoryAdapter.ObservedDrifted uid _) -> Just uid
          Just (InventoryAdapter.ObservedReplacementRequired uid _) -> Just uid
          _ -> Nothing
    health <- case (resource ^. #executor, physical) of
      (ResourceInventory.KubernetesExecutor, Just uid) ->
        observeKubernetesHealth healthConfig (resource ^. #address) uid
      _ -> pure Nothing
    pure (resourceId, health)
  let kubernetesObservations = either (error . T.unpack) (\value -> value)
        (InventoryAdapter.observationSet retainedKubeFacts)
  retainedHealthPairs <- forM (InventoryStatus.retainedHealthTargets history kubernetesObservations) $ \(resourceId, address, physical) -> do
    health <- observeKubernetesHealth healthConfig address physical
    pure (resourceId, health)
  transactionStatus <- InventoryStatus.loadActiveTransactionStatus store (InventoryPlan.historyHead history)
    >>= either dieT pure
  finalHead <- InventoryStore.readHead store >>= either (dieT . T.pack . show) pure
  unless (finalHead == Just (InventoryPlan.historyHead history))
    (dieT "accepted inventory changed during status; retry against the new head")
  let allFacts = kubeFacts <> helmFacts <> pulumiFacts <> artifactFacts <> hostFacts <> cacheFacts <> brokerFacts
      knownFacts = Map.fromList allFacts
      remaining =
        [(resource ^. #identity, InventoryAdapter.ObservationUnavailable
          "provider status adapter is not yet registered")
        | resource <- managed, Map.notMember (resource ^. #identity) knownFacts]
      observations = either (error . T.unpack) (\value -> value)
        (InventoryAdapter.observationSet (allFacts <> remaining))
      retainedObservations = either (error . T.unpack) (\value -> value)
        (InventoryAdapter.observationSet (retainedKubeFacts <> retainedHelmFacts <> retainedBrokerFacts))
      healthById = Map.fromList (healthPairs <> helmHealthPairs)
      findings =
        [finding {InventoryStatus.findingHealth = case Map.lookup (InventoryStatus.findingResource finding) healthById of
          Just (Just True) -> InventoryStatus.HealthReady
          Just (Just False) -> InventoryStatus.HealthNotReady
          _ -> InventoryStatus.findingHealth finding}
        | finding <- InventoryStatus.classifyDrift inventory observations]
      retainedHealthById = Map.fromList (retainedHealthPairs <> retainedHelmHealthPairs)
      retainedFindings =
        [finding {InventoryStatus.retainedHealth = case Map.lookup (InventoryStatus.retainedResource finding) retainedHealthById of
          Just (Just True) -> InventoryStatus.HealthReady
          Just (Just False) -> InventoryStatus.HealthNotReady
          _ -> InventoryStatus.retainedHealth finding}
        | finding <- InventoryStatus.retainedFindings history retainedObservations]
      collectionAssessments = InventoryStatus.assessCollections history inventory retainedObservations
      collectedEntries = Map.toAscList (InventoryStore.headCollected (InventoryPlan.historyHead history))
      unavailable = Set.toAscList (Set.fromList
        ([InventoryStatus.findingExecutor finding | finding <- findings,
          InventoryStatus.findingCategory finding == InventoryStatus.UnknownObservation]
        <> [InventoryStatus.retainedExecutor finding | finding <- retainedFindings,
          InventoryStatus.retainedObservation finding `elem` ["unknown", "unavailable"]]))
      missingScopes = Set.toAscList (Set.fromList
        ([(InventoryStatus.findingOwner finding, InventoryStatus.findingExecutor finding)
        | finding <- findings,
          InventoryStatus.findingCategory finding == InventoryStatus.UnknownObservation]
        <> [(InventoryStatus.retainedScope finding, InventoryStatus.retainedExecutor finding)
           | finding <- retainedFindings,
             InventoryStatus.retainedObservation finding `elem` ["unknown", "unavailable"]]))
      providers =
        [Aeson.object ["executor" Aeson..= InventoryAdapter.adapterExecutor adapter,
                       "identity" Aeson..= InventoryAdapter.adapterIdentity adapter,
                       "version" Aeson..= InventoryAdapter.adapterVersion adapter]
        | adapter <- [kubernetes, helm, pulumi, artifact, host, cache, broker]]
      revisions values =
        [Aeson.object ["scope" Aeson..= scope, "revision" Aeson..= revision]
        | (scope, revision) <- Map.toAscList values]
  observedAt <- currentTimestamp
  case gcOutput of
    Nothing -> pure ()
    Just output -> do
      exists <- doesPathExist output
      when exists (dieT "collection plan output already exists")
      let report = Aeson.object
            [ "version" Aeson..= (1 :: Int)
            , "context" Aeson..= binding
            , "observationStartedAt" Aeson..= observationStartedAt
            , "observedAt" Aeson..= observedAt
            , "deletionAuthorized" Aeson..= False
            , "assessments" Aeson..= collectionAssessments
            ]
      createDirectoryIfMissing True output
      LBS.writeFile (output </> "collection-plan.json") (Aeson.encode report)
      TIO.putStrLn ("Wrote read-only collection assessment: " <> T.pack (output </> "collection-plan.json"))
  let baseFields =
        [ "context" Aeson..= ResourceInventory.inventoryBinding inventory
        , "observationStartedAt" Aeson..= observationStartedAt
        , "observedAt" Aeson..= observedAt
        , "accepted" Aeson..= revisions (fmap fst (InventoryPlan.historyAccepted history))
        , "converged" Aeson..= revisions (InventoryPlan.historyConverged history)
        , "activeTransaction" Aeson..= InventoryStore.headActiveTransaction (InventoryPlan.historyHead history)
        , "transactionStatus" Aeson..= transactionStatus
        , "missingProviders" Aeson..= unavailable
        , "missingProviderScopes" Aeson..=
            [Aeson.object ["scope" Aeson..= scope, "executor" Aeson..= executor]
            | (scope, executor) <- missingScopes]
        , "providers" Aeson..= providers
        , "retained" Aeson..= retainedFindings
        , "collectionAssessments" Aeson..= collectionAssessments
        , "collected" Aeson..=
            [Aeson.object ["resource" Aeson..= resource, "tombstone" Aeson..= tombstone]
            | (resource, tombstone) <- collectedEntries]
        ]
  case (gcOutput, requested) of
    (Just _, _) -> pure ()
    (Nothing, Nothing) -> do
      let report = Aeson.object (baseFields <>
            ["observationComplete" Aeson..= null unavailable, "findings" Aeson..= findings])
      if json then LBC.putStrLn (Aeson.encode report)
        else TIO.putStrLn ("Inventory status: " <> T.pack (show (length findings))
          <> " resources; retained: " <> T.pack (show (length retainedFindings))
          <> "; collected: " <> T.pack (show (length collectedEntries))
          <> "; unavailable providers: " <> T.pack (show unavailable))
    (Nothing, Just raw) -> do
      resourceId <- either dieT pure (Resource.mkResourceId (T.pack raw))
      (explanation, summary) <- case Map.lookup resourceId byId of
        Just resource -> do
          finding <- maybe (dieT "resource finding is absent") pure
            (find ((== resourceId) . InventoryStatus.findingResource) findings)
          pure (Aeson.object (baseFields <>
            [ "finding" Aeson..= finding
            , "dependencies" Aeson..= (resource ^. #dependencies)
            , "dependencyTrace" Aeson..= InventoryStatus.traceDependencies inventory resourceId
            , "consumers" Aeson..= InventoryStatus.consumersOf history inventory resourceId
            , "addressAliases" Aeson..= (resource ^. #aliases)
            , "requiredConditions" Aeson..=
                [reference | ResourceReference.ReadyAfter reference <- resource ^. #dependencies]
            , "lifecycle" Aeson..= (resource ^. #lifecycle)
            , "dataPolicy" Aeson..= (resource ^. #dataPolicy)
            , "sensitivity" Aeson..= (resource ^. #sensitivity)
            , "delegations" Aeson..= (resource ^. #delegations)
            , "source" Aeson..= (resource ^. #source)
            ]), T.pack (show finding))
        Nothing -> case Map.lookup resourceId (InventoryPlan.historyRetained history) of
          Just (_, resource) -> do
            let retainedFinding = find ((== resourceId) . InventoryStatus.retainedResource) retainedFindings
            finding <- maybe (dieT "retained resource finding is absent") pure retainedFinding
            pure (Aeson.object (baseFields <>
              [ "finding" Aeson..= finding
              , "dependencies" Aeson..= (resource ^. #dependencies)
              , "dependencyTrace" Aeson..= InventoryStatus.traceRetainedDependencies history inventory resourceId
              , "consumers" Aeson..= InventoryStatus.consumersOf history inventory resourceId
              , "addressAliases" Aeson..= (resource ^. #aliases)
              , "requiredConditions" Aeson..=
                  [reference | ResourceReference.ReadyAfter reference <- resource ^. #dependencies]
              , "lifecycle" Aeson..= (resource ^. #lifecycle)
              , "dataPolicy" Aeson..= (resource ^. #dataPolicy)
              , "sensitivity" Aeson..= (resource ^. #sensitivity)
              , "delegations" Aeson..= (resource ^. #delegations)
              , "source" Aeson..= (resource ^. #source)
              , "collectionAssessment" Aeson..= find
                  ((== resourceId) . InventoryStatus.collectionResource) collectionAssessments
              , "recoveryReason" Aeson..= ("retained incarnation requires explicit collection or recovery review" :: Text)
              ]), "Retained resource " <> Resource.resourceIdText resourceId)
          Nothing -> case Map.lookup resourceId (InventoryStore.headCollected (InventoryPlan.historyHead history)) of
            Just tombstone -> pure (Aeson.object (baseFields <>
              ["finding" Aeson..= Aeson.object
                ["resource" Aeson..= resourceId,
                 "category" Aeson..= ("collected" :: Text),
                 "tombstone" Aeson..= tombstone]]),
              "Collected resource " <> Resource.resourceIdText resourceId)
            Nothing -> dieT "resource is absent from accepted and historical inventory"
      if json then LBC.putStrLn (Aeson.encode explanation)
        else TIO.putStrLn summary

runInventoryStoreStatus :: Maybe String -> Bool -> IO ()
runInventoryStoreStatus mctx json = do
  active <- activeTarget mctx
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  headValue <- InventoryStore.readHead store >>= either (dieT . T.pack . show) pure
    >>= maybe (dieT "inventory history is not initialized") pure
  rawHead <- InventoryStore.readObject store "head.json" >>= either (dieT . T.pack . show) pure
    >>= maybe (dieT "inventory history head disappeared") pure
  verified <- InventoryStore.readHead store >>= either (dieT . T.pack . show) pure
  unless (verified == Just headValue) (dieT "inventory history changed during status")
  let profile = active ^. #profile
      kind = effectiveInventoryStore profile
      context = contextNameText (active ^. #contextName)
      url = case kind of
        InventoryStoreLocal -> "local"
        InventoryStoreGcs -> if T.null (profile ^. #inventoryStoreUrl)
          then defaultGcsInventoryStoreUrl context profile
          else profile ^. #inventoryStoreUrl
      report = Aeson.object
        [ "kind" Aeson..= inventoryStoreToken kind
        , "url" Aeson..= url
        , "binding" Aeson..= InventoryStore.headBinding headValue
        , "headDigest" Aeson..= InventoryDigest.contentDigest rawHead
        , "generation" Aeson..= InventoryStore.headGeneration headValue
        , "activeTransaction" Aeson..= InventoryStore.headActiveTransaction headValue
        , "executorClaim" Aeson..= InventoryStore.headExecutorClaim headValue
        , "migration" Aeson..= InventoryStore.headMigration headValue
        ]
  if json then LBC.putStrLn (Aeson.encode report)
    else TIO.putStrLn ("Inventory store " <> inventoryStoreToken kind <> " at " <> url
      <> ", generation " <> T.pack (show (InventoryStore.headGeneration headValue)))

runInventoryStoreMigrate :: Maybe String -> String -> Bool -> Bool -> IO ()
runInventoryStoreMigrate mctx destination dryRun yes = do
  kind <- case destination of
    "gcs" -> pure InventoryStoreGcs
    "local" -> pure InventoryStoreLocal
    _ -> dieT "--to must be gcs or local"
  unless (dryRun || yes) (dieT "inventory store migration requires --yes or --dry-run")
  active <- activeTarget mctx
  when (kind == InventoryStoreGcs && effectiveInventoryStore (active ^. #profile) == InventoryStoreLocal
    && active ^. #profile . #mode == Local)
    (dieT "local-mode contexts cannot use a GCS inventory store")
  label <- Inventory.migrateTargetStore active kind dryRun >>= either (dieT . T.pack . show) pure
  if dryRun
    then TIO.putStrLn ("Inventory migration is ready for " <> label)
    else do
      let url = case kind of
            InventoryStoreLocal -> ""
            InventoryStoreGcs -> label
      writeContextInventoryStore (active ^. #contextName) kind url >>= either dieT pure
      TIO.putStrLn ("Inventory history migrated to " <> label <> "; reload the context shell")

runInventoryPlan :: Maybe String -> FilePath -> FilePath -> IO ()
runInventoryPlan mctx candidateDirectory output = do
  target <- activeTarget mctx
  candidate <- Inventory.loadCandidate candidateDirectory >>= either dieT pure
  let inventory = ResourceInventory.candidateInventory candidate
      declarations = ResourceInventory.inventoryDeclarations inventory
      scopes = Map.elems (ResourceInventory.inventoryScopes inventory)
  registrations <- either dieT pure (InventoryCloud.registrationsFromDeclarations declarations)
  artifactSpecs <- either dieT pure (InventoryArtifact.artifactExecutionSpecsFromDeclarations declarations)
  cacheSpecs <- either dieT pure (cacheSpecsFromDeclarations declarations)
  hostInputs <- either dieT pure (InventoryHost.hostExecutionInputsFromScopes scopes)
  let kubernetesResources = [resource | ResourceInventory.Managed resource <- declarations, resource ^. #executor == ResourceInventory.KubernetesExecutor]
      helmResources = [resource | ResourceInventory.Managed resource <- declarations, resource ^. #executor == ResourceInventory.HelmExecutor]
  if null registrations && Map.null artifactSpecs && isNothing hostInputs && null kubernetesResources && null helmResources && Map.null cacheSpecs
    then Inventory.planInventory target candidateDirectory output
    else do
      (active, workspace) <-
        if null registrations && Map.null artifactSpecs && isNothing hostInputs
          then do
            active <- activeTarget mctx
            (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
            pure (active, workspace)
          else prepareInfraMutation mctx
      Inventory.planInventoryWith (inventoryPlanRegistry active workspace) target candidateDirectory output

runInventoryAdopt :: Maybe String -> FilePath -> FilePath -> IO ()
runInventoryAdopt mctx input output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  Inventory.planInventoryAdoptionWith (inventoryPlanRegistry active workspace) active input output

runInventoryMigrate :: Maybe String -> FilePath -> FilePath -> IO ()
runInventoryMigrate mctx input output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  Inventory.planInventoryMigrationWith
    (inventoryMigrationSourceRegistry active workspace)
    (inventoryPlanRegistry active workspace) active input output

inventoryMigrationSourceRegistry :: ActiveTarget -> PlatformWorkspace
  -> ResourceInventory.CompositionCandidate -> InventoryPlan.InventoryHistory
  -> IO InventoryAdapter.AdapterRegistry
inventoryMigrationSourceRegistry active workspace candidate history = do
  let requirements = InventoryPlan.observationRequirements candidate history
      sourceIds = Map.keysSet (InventoryPlan.migrationIncarnations requirements)
      binding = ResourceInventory.inventoryBinding (ResourceInventory.candidateInventory candidate)
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  acceptedSnapshot <- either (dieT . T.pack . show) pure (ResourceInventory.mkScopeSnapshot
    binding
    (Map.map (\(revision, scope) -> (InventoryStore.revisionGeneration revision, scope))
      (InventoryPlan.historyAccepted history))
    (InventoryPlan.historyReservations history))
  acceptedInventory <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeSnapshot acceptedSnapshot)
  (allKubernetes, allHelm) <- InventoryStatus.loadAcceptedNative store history acceptedInventory
    >>= either dieT pure
  let oldKubernetes = Map.filterWithKey (\resource _ -> Set.member resource sourceIds) allKubernetes
      oldHelm = Map.filterWithKey (\resource _ -> Set.member resource sourceIds) allHelm
      selected = Map.keysSet oldKubernetes `Set.union` Map.keysSet oldHelm
      unsupported = sourceIds `Set.difference` selected
  unless (Set.null unsupported)
    (dieT "migration source needs an installed immutable provider observation contract")
  kubernetes <- inventoryKubernetesAdapter active binding
    (\_ -> pure (Left "migration source cache output unavailable")) oldKubernetes
  helm <- inventoryHelmAdapter active workspace binding oldHelm
  either dieT pure (InventoryAdapter.mkAdapterRegistry [kubernetes, helm])

runInventoryRetire :: Maybe String -> String -> FilePath -> IO ()
runInventoryRetire mctx rawScope output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  owner <- either dieT pure (parseScope (T.pack rawScope))
  Inventory.planInventoryRetirementWith (inventoryPlanRegistry active workspace) active owner output
  where
    parseScope scopeText = case T.splitOn ":" scopeText of
      [kind, name] -> do
        scopeKind <- case kind of
          "platform" -> Right Resource.Platform
          "application" -> Right Resource.Application
          "standalone" -> Right Resource.Standalone
          "publication" -> Right Resource.Publication
          _ -> Left "scope kind must be platform, application, standalone, or publication"
        Resource.mkScopeId scopeKind name
      _ -> Left "scope must be KIND:NAME"

runInventoryCollect :: Maybe String -> NE.NonEmpty String -> FilePath -> IO ()
runInventoryCollect mctx rawResources output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  resources <- traverse (either dieT pure . Resource.mkResourceId . T.pack) rawResources
  Inventory.planInventoryCollectionsWith (inventoryPlanRegistry active workspace) active resources output

runInventoryApply :: Maybe String -> FilePath -> Bool -> IO ()
runInventoryApply mctx reviewDirectory yes = do
  target <- activeTarget mctx
  Inventory.applyInventoryWithFactory (inventoryExecutionRegistry mctx) target reviewDirectory yes

runInventoryResume :: Maybe String -> Text -> Bool -> Bool -> IO ()
runInventoryResume mctx transaction yes takeOver = do
  target <- activeTarget mctx
  Inventory.resumeInventoryWithFactoryTakeover (inventoryExecutionRegistry mctx) target transaction yes takeOver

runInventoryRecover :: Maybe String -> Text -> Text -> FilePath -> Bool -> IO ()
runInventoryRecover mctx transaction operation decisionFile takeOver = do
  target <- activeTarget mctx
  Inventory.recoverInventoryWithFactory (inventoryExecutionRegistry mctx) target transaction operation decisionFile takeOver

inventoryExecutionRegistry :: Maybe String -> InventoryPlan.ReviewBundle -> IO InventoryAdapter.AdapterRegistry
inventoryExecutionRegistry mctx bundle = do
  scopes <- traverse (either (dieT . T.pack . show) pure . ResourceWire.decodeScope) (Map.elems (InventoryPlan.reviewBundleScopes bundle))
  let declarations = [declaration | scopeDeclaration <- scopes, resourceBundle <- ResourceInventory.scopeBundles scopeDeclaration, declaration <- ResourceInventory.declarations resourceBundle]
  registrations <- either dieT pure (InventoryCloud.registrationsFromDeclarations declarations)
  artifactSpecs <- either dieT pure (InventoryArtifact.artifactExecutionSpecsFromDeclarations declarations)
  cacheSpecs <- either dieT pure (cacheSpecsFromDeclarations declarations)
  topicSpecs <- either dieT pure (topicSpecsFromDeclarations declarations)
  hostInputs <- either dieT pure (InventoryHost.hostExecutionInputsFromScopes scopes)
  reviewedKubernetesSpecs <- either dieT pure (kubernetesSpecsFromReview bundle)
  helmSpecs <- either dieT pure (helmSpecsFromReview bundle)
  let retiredIds = Map.keysSet (InventoryPlan.reviewRetentions (InventoryPlan.reviewBundleDocument bundle))
        `Set.union` Map.keysSet (InventoryPlan.reviewCollections (InventoryPlan.reviewBundleDocument bundle))
      binding = InventoryPlan.reviewContextBinding (InventoryPlan.reviewBundleDocument bundle)
  (retiringKubernetesSpecs, retiringHelmSpecs) <- if Set.null retiredIds
    then pure (Map.empty, Map.empty) else do
    active <- activeTarget mctx
    store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
    history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
    acceptedSnapshot <- either (dieT . T.pack . show) pure (ResourceInventory.mkScopeSnapshot
      binding
      (Map.map (\(revision, scope) -> (InventoryStore.revisionGeneration revision, scope))
        (InventoryPlan.historyAccepted history))
      (InventoryPlan.historyReservations history))
    acceptedInventory <- either (dieT . T.pack . show) pure
      (ResourceInventory.composeSnapshot acceptedSnapshot)
    (native, helmNative) <- InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
    let selectedKubernetes = Map.filterWithKey (\resource _ -> Set.member resource retiredIds) native
        selectedHelm = Map.filterWithKey (\resource _ -> Set.member resource retiredIds) helmNative
    unless (Set.union (Map.keysSet selectedKubernetes) (Map.keysSet selectedHelm) == retiredIds)
      (dieT "retirement review lacks accepted immutable native evidence")
    pure (selectedKubernetes, selectedHelm)
  let kubernetesSpecs = Map.union reviewedKubernetesSpecs retiringKubernetesSpecs
      allHelmSpecs = Map.union helmSpecs retiringHelmSpecs
  if null registrations && Map.null artifactSpecs && isNothing hostInputs && Map.null kubernetesSpecs && Map.null cacheSpecs && Map.null topicSpecs && Map.null allHelmSpecs
    then either dieT pure (InventoryAdapter.mkAdapterRegistry (map Inventory.executionBlockedAdapterFor [ResourceInventory.KubernetesExecutor, ResourceInventory.PulumiExecutor, ResourceInventory.HostExecutor, ResourceInventory.ArtifactExecutor, ResourceInventory.CacheExecutor, ResourceInventory.BrokerExecutor, ResourceInventory.HelmExecutor]))
    else do
      (active, workspace) <-
        if null registrations && Map.null artifactSpecs && isNothing hostInputs
          then do
            active <- activeTarget mctx
            (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
            pure (active, workspace)
          else prepareInfraMutation mctx
      pulumi <-
        if null registrations
          then pure (Inventory.executionBlockedAdapterFor ResourceInventory.PulumiExecutor)
          else inventoryPulumiAdapter active workspace binding scopes registrations
      artifact <-
        if Map.null artifactSpecs
          then pure (Inventory.executionBlockedAdapterFor ResourceInventory.ArtifactExecutor)
          else pure (inventoryArtifactAdapter active workspace artifactSpecs)
      host <- maybe (pure (Inventory.executionBlockedAdapterFor ResourceInventory.HostExecutor)) (inventoryHostAdapter active workspace) hostInputs
      (cache, cacheKey) <- inventoryCacheAdapter active workspace binding cacheSpecs
      acceptedTopics <- if Map.null topicSpecs then pure Set.empty else do
        historyStore <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
        history <- InventoryPlan.loadInventoryHistory historyStore >>= either (dieT . T.pack . show) pure
        pure (acceptedTopicIds history)
      broker <- inventoryBrokerAdapter active binding topicSpecs acceptedTopics
      kubernetes <- inventoryKubernetesAdapter active binding cacheKey kubernetesSpecs
      helm <- inventoryHelmAdapter active workspace binding allHelmSpecs
      let adapters = [pulumi, artifact, host, kubernetes, cache, broker, helm]
      either dieT pure (InventoryAdapter.mkAdapterRegistry adapters)

inventoryPlanRegistry :: ActiveTarget -> PlatformWorkspace -> ResourceInventory.CompositionCandidate -> InventoryPlan.InventoryHistory -> IO InventoryAdapter.AdapterRegistry
inventoryPlanRegistry active workspace = inventoryPlanRegistryWithNative active workspace Map.empty

inventoryPlanRegistryWithNative :: ActiveTarget -> PlatformWorkspace -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> ResourceInventory.CompositionCandidate -> InventoryPlan.InventoryHistory -> IO InventoryAdapter.AdapterRegistry
inventoryPlanRegistryWithNative active workspace suppliedNative candidate history = do
  let inventory = ResourceInventory.candidateInventory candidate
      declarations = ResourceInventory.inventoryDeclarations inventory
      scopes = Map.elems (ResourceInventory.inventoryScopes inventory)
      historical =
        [declaration
        | (_, (_, scope)) <- Map.toAscList (InventoryPlan.historyAccepted history)
        , bundle <- ResourceInventory.scopeBundles scope
        , declaration <- ResourceInventory.declarations bundle]
  registrations <- either dieT pure (InventoryCloud.registrationsFromDeclarations declarations)
  artifactSpecs <- either dieT pure (InventoryArtifact.artifactExecutionSpecsFromDeclarations declarations)
  cacheSpecs <- either dieT pure (cacheSpecsFromDeclarations declarations)
  topicSpecs <- either dieT pure (topicSpecsFromDeclarations (historical <> declarations))
  hostInputs <- either dieT pure (InventoryHost.hostExecutionInputsFromScopes scopes)
  let kubernetesResources = [resource | ResourceInventory.Managed resource <- declarations, resource ^. #executor == ResourceInventory.KubernetesExecutor]
      helmResources = [resource | ResourceInventory.Managed resource <- declarations, resource ^. #executor == ResourceInventory.HelmExecutor]
  namespaceNative <- either dieT pure (compileContributedNamespaces declarations)
  backendNative <- either dieT pure (compileContributedBackendMaps declarations)
  shomeiNative <- either dieT pure (compileContributedShomeiSettings declarations)
  let generatedNative = Map.unions [namespaceNative, backendNative, shomeiNative]
  unless (Map.size generatedNative == Map.size namespaceNative + Map.size backendNative + Map.size shomeiNative
      && Map.null (Map.intersection suppliedNative generatedNative))
    (dieT "generated native members overlap a supplied or contributed resource")
  let allSuppliedNative = Map.union suppliedNative generatedNative
      kubernetesSuppliedNative = Map.filter ((== ResourceInventory.KubernetesExecutor) . (^. #executor) . fst) allSuppliedNative
      helmSuppliedNative = Map.filter ((== ResourceInventory.HelmExecutor) . (^. #executor) . fst) allSuppliedNative
      suppliedIds = Map.keysSet kubernetesSuppliedNative
      declaredIds = Set.fromList (map (^. #identity) kubernetesResources)
  unless (suppliedIds `Set.isSubsetOf` declaredIds) (dieT "generated native members include an undeclared Kubernetes resource")
  unless (Map.keysSet helmSuppliedNative == Set.fromList (map (^. #identity) helmResources))
    (dieT "Helm release lacks a captured native contract")
  either dieT pure (validateSuppliedKubernetesMembers kubernetesResources kubernetesSuppliedNative)
  let fileBacked = filter (\resource -> Set.notMember (resource ^. #identity) suppliedIds) kubernetesResources
  loaded <- if null fileBacked
    then pure Map.empty
    else loadKubernetesSources (workspace ^. #root) fileBacked >>= either dieT pure
  let desiredIds = Set.fromList (map ResourceInventory.declarationId declarations)
      retiringIds executor = Set.fromList
        [resource ^. #identity
        | (_, (_, acceptedScope)) <- Map.toAscList (InventoryPlan.historyAccepted history)
        , bundle <- ResourceInventory.scopeBundles acceptedScope
        , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
        , resource ^. #executor == executor
        , Set.notMember (resource ^. #identity) desiredIds]
      collectingIds = Set.fromList
        [resource | ResourceInventory.CollectRetained resource <- NE.toList (ResourceInventory.candidateChanges candidate)]
      historicalKubernetesIds = Set.union (retiringIds ResourceInventory.KubernetesExecutor) collectingIds
      historicalHelmIds = retiringIds ResourceInventory.HelmExecutor
      historicalIds = Set.union historicalKubernetesIds historicalHelmIds
  (retiringNative, retiringHelmNative) <- if Set.null historicalIds then pure (Map.empty, Map.empty) else do
    store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
    acceptedSnapshot <- either (dieT . T.pack . show) pure (ResourceInventory.mkScopeSnapshot
      (ResourceInventory.inventoryBinding inventory)
      (Map.map (\(revision, scope) -> (InventoryStore.revisionGeneration revision, scope))
        (InventoryPlan.historyAccepted history))
      (InventoryPlan.historyReservations history))
    acceptedInventory <- either (dieT . T.pack . show) pure
      (ResourceInventory.composeSnapshot acceptedSnapshot)
    (native, helmNative) <- InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
    let selectedKubernetes = Map.filterWithKey (\resource _ -> Set.member resource historicalKubernetesIds) native
        selectedHelm = Map.filterWithKey (\resource _ -> Set.member resource historicalHelmIds) helmNative
    unless (Map.keysSet selectedKubernetes == historicalKubernetesIds
        && Map.keysSet selectedHelm == historicalHelmIds)
      (dieT "retained or retiring resource lacks immutable native evidence")
    pure (selectedKubernetes, selectedHelm)
  let kubernetesSpecs = Map.unions [kubernetesSuppliedNative, loaded, retiringNative]
      helmSpecs = Map.union helmSuppliedNative retiringHelmNative
  pulumi <-
    if null registrations
      then pure (Inventory.manifestAdapterFor history ResourceInventory.PulumiExecutor)
      else inventoryPulumiAdapter active workspace (ResourceInventory.inventoryBinding inventory) scopes registrations
  let artifact =
        if Map.null artifactSpecs
          then Inventory.manifestAdapterFor history ResourceInventory.ArtifactExecutor
          else inventoryArtifactAdapter active workspace artifactSpecs
  host <- maybe (pure (Inventory.manifestAdapterFor history ResourceInventory.HostExecutor)) (inventoryHostAdapter active workspace) hostInputs
  (cache, cacheKey) <- if Map.null cacheSpecs
    then pure (Inventory.manifestAdapterFor history ResourceInventory.CacheExecutor, \_ -> pure (Left "cache output resolver is not installed"))
    else inventoryCacheAdapter active workspace (ResourceInventory.inventoryBinding inventory) cacheSpecs
  broker <- inventoryBrokerAdapter active (ResourceInventory.inventoryBinding inventory)
    topicSpecs (acceptedTopicIds history)
  kubernetes <- if Map.null kubernetesSpecs
    then pure (Inventory.manifestAdapterFor history ResourceInventory.KubernetesExecutor)
    else inventoryKubernetesAdapter active (ResourceInventory.inventoryBinding inventory) cacheKey kubernetesSpecs
  helm <- if Map.null helmSpecs
    then pure (Inventory.manifestAdapterFor history ResourceInventory.HelmExecutor)
    else inventoryHelmAdapter active workspace (ResourceInventory.inventoryBinding inventory) helmSpecs
  let adapters = [pulumi, artifact, host, kubernetes, cache, broker, helm]
  either dieT pure (InventoryAdapter.mkAdapterRegistry adapters)

inventoryKubernetesAdapter :: ActiveTarget -> Resource.ContextBinding -> (Resource.ResourceId -> IO (Either Text Text)) -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> IO InventoryAdapter.Adapter
inventoryKubernetesAdapter active binding cacheKey specs
  | Map.null specs = pure (Inventory.executionBlockedAdapterFor ResourceInventory.KubernetesExecutor)
  | otherwise = do
      context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
      unless (context == binding ^. #identity) (dieT "Kubernetes inventory review belongs to a different context")
      let config = KubernetesRuntimeConfig context (contextNameText (active ^. #contextName)) (fmap (fmap (const ())) (guardKubernetesContext active))
      pure (mkKubernetesAdapter specs (mkKubernetesRuntimeOpsWithCacheKey config cacheKey specs))

inventoryHelmAdapter :: ActiveTarget -> PlatformWorkspace -> Resource.ContextBinding -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> IO InventoryAdapter.Adapter
inventoryHelmAdapter active workspace binding specs
  | Map.null specs = pure (Inventory.executionBlockedAdapterFor ResourceInventory.HelmExecutor)
  | otherwise = do
      context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
      unless (context == binding ^. #identity) (dieT "Helm inventory review belongs to a different context")
      pure (mkHelmAdapter specs (helmRuntimeOps (inventoryHelmRuntimeConfig active workspace binding specs)))

inventoryHelmRuntimeConfig :: ActiveTarget -> PlatformWorkspace -> Resource.ContextBinding -> Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString) -> HelmRuntimeConfig
inventoryHelmRuntimeConfig active workspace binding specs = HelmRuntimeConfig
  { helmKubeContext = contextNameText (active ^. #contextName)
  , helmContextId = binding ^. #identity
  , helmVerifyPlugin = workspace ^. #root </> "cluster/observability/helm-review"
  , helmDeclarations = Map.map fst specs
  , helmRuntimeGuard = fmap (fmap (const ())) (guardKubernetesContext active)
  }

inventoryCacheAdapter :: ActiveTarget -> PlatformWorkspace -> Resource.ContextBinding -> Map.Map Resource.ResourceId ResourceInventory.ManagedResource -> IO (InventoryAdapter.Adapter, Resource.ResourceId -> IO (Either Text Text))
inventoryCacheAdapter active workspace binding specs
  | Map.null specs = pure (Inventory.executionBlockedAdapterFor ResourceInventory.CacheExecutor, \_ -> pure (Left "cache output resolver is not installed"))
  | otherwise = do
      context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
      unless (context == binding ^. #identity) (dieT "cache inventory review belongs to a different context")
      let config = CacheRuntime.CacheRuntimeConfig
            { CacheRuntime.runtimeCacheExecutable = workspace ^. #scriptsDir </> "inventory-cache-transport.sh"
            , CacheRuntime.runtimeCacheKubectlContext = contextNameText (active ^. #contextName)
            , CacheRuntime.runtimeCacheContextId = context
            , CacheRuntime.runtimeCacheGuard = fmap (fmap (const ())) (guardKubernetesContext active)
            , CacheRuntime.runtimeCacheSpecs = specs
            }
      pure (mkCacheAdapter specs (CacheRuntime.mkCacheRuntimeOps config), CacheRuntime.cachePublicKeyForResource config)

acceptedTopicIds :: InventoryPlan.InventoryHistory -> Set.Set Resource.ResourceId
acceptedTopicIds history = Set.fromList
  [ resource ^. #identity
  | (_, (_, scope)) <- Map.toAscList (InventoryPlan.historyAccepted history)
  , bundle <- ResourceInventory.scopeBundles scope
  , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
  , resource ^. #executor == ResourceInventory.BrokerExecutor
  ]

inventoryBrokerAdapter :: ActiveTarget -> Resource.ContextBinding
  -> Map.Map Resource.ResourceId TopicBinding -> Set.Set Resource.ResourceId
  -> IO InventoryAdapter.Adapter
inventoryBrokerAdapter active binding specs accepted
  | Map.null specs = pure (Inventory.executionBlockedAdapterFor ResourceInventory.BrokerExecutor)
  | otherwise = do
      context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
      unless (context == binding ^. #identity)
        (dieT "broker topic inventory review belongs to a different context")
      let config = BrokerRuntime.TopicRuntimeConfig
            { BrokerRuntime.topicKubectlContext = contextNameText (active ^. #contextName)
            , BrokerRuntime.topicContextGuard = fmap (fmap (const ())) (guardKubernetesContext active)
            , BrokerRuntime.topicRuntimeSpecs = specs
            }
      pure (mkTopicAdapter accepted specs (BrokerRuntime.topicRuntimeOps config))

inventoryArtifactAdapter :: ActiveTarget -> PlatformWorkspace -> Map.Map Resource.ResourceId InventoryArtifact.ArtifactExecutionSpec -> InventoryAdapter.Adapter
inventoryArtifactAdapter active workspace specs =
  mkArtifactAdapter specs (mkArtifactRuntimeOps config)
  where
    config =
      ArtifactRuntimeConfig
        { runtimeArtifactExecutable = workspace ^. #scriptsDir </> "inventory-artifact-transport.sh"
        , runtimeArtifactEnvironment = [("NAGARE_CONTEXT", T.unpack (contextNameText (active ^. #contextName)))]
        , runtimeArtifactSpecs = specs
        }

inventoryHostAdapter :: ActiveTarget -> PlatformWorkspace -> (Resource.ContentDigest, Resource.ContentDigest) -> IO InventoryAdapter.Adapter
inventoryHostAdapter active workspace (configurationDigest, lockDigest) = do
  hostName <- readContextHostName (active ^. #contextName) >>= either dieT pure
  hostRoot <- hostConfigDir (active ^. #contextName)
  context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
  attribute <- either dieT pure (Resource.mkName hostName)
  let profile = active ^. #profile
      config =
        HostRuntimeConfig
          { runtimeHostExecutable = workspace ^. #scriptsDir </> "inventory-host-transport.sh"
          , runtimeHostEnvironment =
              [ ("NAGARE_CONTEXT", T.unpack (contextNameText (active ^. #contextName)))
              , ("NAGARE_HOST_FLAKE", hostRoot)
              ]
          , runtimeHostContext = context
          , runtimeHostAttribute = attribute
          , runtimeHostProject = profile ^. #project
          , runtimeHostZone = profile ^. #zone
          , runtimeHostInstanceName = profile ^. #instanceName
          , runtimeHostDestination = "deploy@" <> hostName
          , runtimeHostConfigurationDigest = configurationDigest
          , runtimeHostLockDigest = lockDigest
          }
  pure (mkHostAdapter (mkHostRuntimeOps config))

inventoryPulumiAdapter :: ActiveTarget -> PlatformWorkspace -> Resource.ContextBinding -> [ResourceInventory.ScopeDeclaration] -> [InventoryCloud.NativeRegistration] -> IO InventoryAdapter.Adapter
inventoryPulumiAdapter active workspace binding scopes registrations = do
  stateRoot <- nagareStateDir
  stackConfig <- contextStackConfigPath (active ^. #contextName)
  stackName <- either dieT pure (Resource.mkName (contextNameText (active ^. #contextName)))
  payloadDigest <- either dieT pure (Resource.mkContentDigest (workspace ^. #digest))
  let profile = active ^. #profile
      context = contextNameText (active ^. #contextName)
      pulumiEnvironment = pulumiEnvFor stateRoot context profile
      declarationBundle =
        InventoryCloud.encodeRegistrationBundle
          (binding ^. #identity)
          (binding ^. #project)
          stackName
          (map ResourceInventory.scopeId scopes)
          registrations
      config =
        PulumiRuntimeConfig
          { runtimeContext = context
          , runtimeProject = profile ^. #project
          , runtimeStack = pulumiEnvironment ^. #stack
          , runtimeBackend = pulumiEnvironment ^. #backendUrl
          , runtimePayloadId = workspace ^. #payloadId
          , runtimePayloadDigest = payloadDigest
          , runtimePulumiExecutable = "pulumi"
          , runtimePulumiDirectory = workspace ^. #pulumiDir
          , runtimeStackConfig = stackConfig
          , runtimeDeclarationBundle = declarationBundle
          , runtimeRegistrations = registrations
          }
  pure (mkPulumiAdapter registrations (mkPulumiRuntimeOps config))

-- | Compose the release and project/ADC guards before any standalone
-- infrastructure mutation. ADC is validated before workspace preparation,
-- because preparation may select or initialize a Pulumi stack.
prepareInfraMutation :: Maybe String -> IO (ActiveTarget, PlatformWorkspace)
prepareInfraMutation mctx = do
  (active, status) <- gatherPlatformStatus mctx
  either dieT pure (guardPlatformMutation status)
  TIO.putStrLn ("platform mutation allowed (" <> compatibilityToken (status ^. #compatibility) <> ")")
  let contextName = active ^. #contextName
      profile = active ^. #profile
  case profile ^. #mode of
    Local -> pure ()
    Cloud -> do
      (gcloudAccount, adc) <- observeAdcForProject
      warnings <- either dieT pure (validateAdc (profile ^. #project) gcloudAccount adc)
      printPreflightWarnings warnings
  workspace <- ensurePulumiForContext contextName profile
  case profile ^. #mode of
    Local -> TIO.putStrLn "context guard: local mode; no GCP project to confine"
    Cloud -> do
      inputs <- projectGuardInputsFor contextName profile workspace
      either dieT pure (projectGuardVerdict inputs)
      TIO.putStrLn (renderProjectGuard inputs)
  pure (active, workspace)

planFileName, reviewFileName, metadataFileName :: FilePath
planFileName = "pulumi-plan.json"
reviewFileName = "review.json"
metadataFileName = "metadata.json"

currentInfraIdentity :: ActiveTarget -> PlatformWorkspace -> IO (Either Text CurrentInfraIdentity)
currentInfraIdentity active workspace = do
  result <- try $ do
    stateRoot <- nagareStateDir
    let contextName = active ^. #contextName
        profile = active ^. #profile
        penv = pulumiEnvFor stateRoot (contextNameText contextName) profile
    configPath <- contextStackConfigPath contextName
    configDigest <- digestFile configPath
    programDigest <- digestPulumiProgram (workspace ^. #pulumiDir)
    versionResult <- readProcessWithExitCode "pulumi" ["version"] ""
    pulumiVersion <- case versionResult of
      (ExitSuccess, out, _) | not (T.null (T.strip (T.pack out))) -> pure (T.strip (T.pack out))
      (ExitFailure code, out, err) ->
        ioError (userError ("pulumi version exited " <> show code <> ": " <> err <> out))
      _ -> ioError (userError "pulumi version returned an empty version")
    pure
      CurrentInfraIdentity
        { currentContext = contextNameText contextName
        , currentProject = profile ^. #project
        , currentStack = penv ^. #stack
        , currentBackend = penv ^. #backendUrl
        , currentPayloadId = workspace ^. #payloadId
        , currentPayloadDigest = workspace ^. #digest
        , currentProgramDigest = programDigest
        , currentConfigDigest = configDigest
        , currentPulumiVersion = pulumiVersion
        }
  pure $ case result of
    Left (err :: IOException) -> Left ("could not capture the current infrastructure identity: " <> T.pack (show err))
    Right identity -> Right identity

saveReviewedPlan :: ActiveTarget -> PlatformWorkspace -> FilePath -> Bool -> IO (Either Text Text)
saveReviewedPlan active workspace destination allowReplacement = do
  exists <- doesPathExist destination
  if exists
    then pure (Left ("refusing to overwrite existing saved-plan bundle " <> T.pack destination))
    else do
      identityResult <- currentInfraIdentity active workspace
      case identityResult of
        Left err -> pure (Left err)
        Right identity -> do
          let parent = takeDirectory destination
          createDirectoryIfMissing True parent
          staging <- createTempDirectory parent ".nagare-plan-"
          setFileMode staging 0o700
          preview <-
            try
              ( readProcessWithExitCode
                  "pulumi"
                  [ "-C"
                  , workspace ^. #pulumiDir
                  , "preview"
                  , "--json"
                  , "--save-plan"
                  , staging </> planFileName
                  , "--stack"
                  , T.unpack (identity ^. #currentStack)
                  , "--non-interactive"
                  ]
                  ""
              )
          case preview of
            Left (err :: IOException) -> cleanupPlanStaging staging ("could not run Pulumi preview: " <> T.pack (show err))
            Right (ExitFailure code, out, err) ->
              cleanupPlanStaging
                staging
                ( "Pulumi preview exited "
                    <> T.pack (show code)
                    <> ":\n"
                    <> T.strip (T.unlines (T.pack err : previewErrors (TE.encodeUtf8 (T.pack out))))
                )
            Right (ExitSuccess, out, _) -> case parsePreview (TE.encodeUtf8 (T.pack out)) of
              Left err -> cleanupPlanStaging staging ("could not parse Pulumi preview: " <> err)
              Right steps -> do
                let review = SavedPlanReview 1 allowReplacement steps
                    verdict = reviewVerdict review
                case verdict of
                  PlanReplacesProtected _
                    | not allowReplacement ->
                        cleanupPlanStaging staging (renderVerdict (active ^. #profile . #instanceName) verdict)
                  _ -> finalizePlan staging identity review verdict
  where
    finalizePlan staging identity review verdict = do
      let planPath = staging </> planFileName
          reviewPath = staging </> reviewFileName
          metadataPath = staging </> metadataFileName
          reviewBytes = LBS.toStrict (Aeson.encode review) <> "\n"
      planExists <- doesFileExist planPath
      if not planExists
        then cleanupPlanStaging staging "Pulumi preview succeeded without writing its saved plan"
        else do
          BS.writeFile reviewPath reviewBytes
          setFileMode planPath 0o600
          setFileMode reviewPath 0o600
          planDigest <- digestFile planPath
          reviewDigest <- digestFile reviewPath
          createdAt <- currentTimestamp
          let metadata =
                SavedPlanMetadata
                  { metadataSchemaVersion = 1
                  , context = identity ^. #currentContext
                  , project = identity ^. #currentProject
                  , stack = identity ^. #currentStack
                  , backend = identity ^. #currentBackend
                  , payloadId = identity ^. #currentPayloadId
                  , payloadDigest = identity ^. #currentPayloadDigest
                  , programDigest = identity ^. #currentProgramDigest
                  , configDigest = identity ^. #currentConfigDigest
                  , pulumiVersion = identity ^. #currentPulumiVersion
                  , createdAt = createdAt
                  , planDigest = planDigest
                  , reviewDigest = reviewDigest
                  }
          BS.writeFile metadataPath (LBS.toStrict (Aeson.encode metadata) <> "\n")
          setFileMode metadataPath 0o600
          renamed <- try (renameDirectory staging destination)
          case renamed of
            Left (err :: IOException) -> cleanupPlanStaging staging ("could not publish saved-plan bundle: " <> T.pack (show err))
            Right () ->
              pure
                ( Right
                    ( "Saved reviewed Pulumi plan for context '"
                        <> identity ^. #currentContext
                        <> "' at "
                        <> T.pack destination
                        <> "\n"
                        <> renderVerdict (active ^. #profile . #instanceName) verdict
                    )
                )

cleanupPlanStaging :: FilePath -> Text -> IO (Either Text a)
cleanupPlanStaging staging message = do
  present <- doesDirectoryExist staging
  when present (removeDirectoryRecursive staging)
  pure (Left message)

applyReviewedPlan :: ActiveTarget -> PlatformWorkspace -> FilePath -> Bool -> IO (Either Text Text)
applyReviewedPlan active workspace bundle allowReplacement = do
  verified <- verifyReviewedPlanBundleEvidence active workspace bundle allowReplacement
  case verified of
    Left err -> pure (Left err)
    Right (identity, _) -> applyVerifiedReviewedPlan workspace bundle identity

applyVerifiedReviewedPlan :: PlatformWorkspace -> FilePath -> CurrentInfraIdentity -> IO (Either Text Text)
applyVerifiedReviewedPlan workspace bundle identity = do
  applied <-
    runExternal
      [ExitSuccess]
      "pulumi"
      [ "-C"
      , workspace ^. #pulumiDir
      , "up"
      , "--plan"
      , bundle </> planFileName
      , "--stack"
      , T.unpack (identity ^. #currentStack)
      , "--yes"
      , "--non-interactive"
      ]
      ""
  pure $
    fmap
      ( \evidence ->
          "Applied reviewed Pulumi plan for context '"
            <> identity ^. #currentContext
            <> "' from "
            <> T.pack bundle
            <> if T.null (T.strip evidence) then "\n" else "\n" <> evidence
      )
      applied

verifyReviewedPlanBundle :: ActiveTarget -> PlatformWorkspace -> FilePath -> Bool -> IO (Either Text CurrentInfraIdentity)
verifyReviewedPlanBundle active workspace bundle allowReplacement =
  fmap (fmap fst) (verifyReviewedPlanBundleEvidence active workspace bundle allowReplacement)

verifyReviewedPlanBundleEvidence :: ActiveTarget -> PlatformWorkspace -> FilePath -> Bool -> IO (Either Text (CurrentInfraIdentity, SavedPlanMetadata))
verifyReviewedPlanBundleEvidence active workspace bundle allowReplacement = do
  local <- verifyLocalReviewedPlanBundle bundle
  case local of
    Left err -> pure (Left err)
    Right (metadata, savedReview) -> do
      identityResult <- currentInfraIdentity active workspace
      case identityResult of
        Left err -> pure (Left err)
        Right identity -> case verifySavedPlan identity metadata of
          Left err -> pure (Left ("refusing saved plan: " <> renderPlanBindingError err))
          Right () ->
            pure $ case reviewVerdict savedReview of
              PlanReplacesProtected _
                | not allowReplacement ->
                    Left "refusing saved plan: repeat the protected-replacement acknowledgement with --allow-replacement"
              _ -> Right (identity, metadata)

verifyLocalReviewedPlanBundle :: FilePath -> IO (Either Text (SavedPlanMetadata, SavedPlanReview))
verifyLocalReviewedPlanBundle bundle = do
  loaded <- loadPlanBundle bundle
  case loaded of
    Left err -> pure (Left err)
    Right (metadata, savedReview) -> do
      planHash <- digestFile (bundle </> planFileName)
      reviewHash <- digestFile (bundle </> reviewFileName)
      pure $
        if planHash /= metadata ^. #planDigest
          then Left "refusing saved plan: pulumi-plan.json digest does not match metadata.json"
          else
            if reviewHash /= metadata ^. #reviewDigest
              then Left "refusing saved plan: review.json digest does not match metadata.json"
              else case reviewVerdict savedReview of
                PlanReplacesProtected _
                  | not (savedReview ^. #replacementApproved) ->
                      Left "refusing saved plan: review contains a protected replacement that was not approved at preview time"
                _ -> Right (metadata, savedReview)

loadPlanBundle :: FilePath -> IO (Either Text (SavedPlanMetadata, SavedPlanReview))
loadPlanBundle bundle = do
  checked <- try (validatePlanBundleSecurity bundle)
  case checked of
    Left (err :: IOException) -> pure (Left ("invalid saved-plan bundle " <> T.pack bundle <> ": " <> T.pack (show err)))
    Right () -> do
      metadataBytes <- BS.readFile (bundle </> metadataFileName)
      reviewBytes <- BS.readFile (bundle </> reviewFileName)
      pure $ do
        metadata <- firstText "metadata.json" (Aeson.eitherDecodeStrict' metadataBytes)
        review <- firstText "review.json" (Aeson.eitherDecodeStrict' reviewBytes)
        if review ^. #reviewSchemaVersion /= 1
          then Left ("unsupported review.json schema " <> T.pack (show (review ^. #reviewSchemaVersion)))
          else Right (metadata, review)
  where
    firstText name = either (Left . (("invalid " <> name <> ": ") <>) . T.pack) Right

validatePlanBundleSecurity :: FilePath -> IO ()
validatePlanBundleSecurity bundle = do
  linked <- pathIsSymbolicLink bundle
  when linked (ioError (userError "bundle directory is a symlink"))
  bundleStatus <- getFileStatus bundle
  unless (isDirectory bundleStatus) (ioError (userError "bundle path is not a directory"))
  unless (privateMode bundleStatus) (ioError (userError "bundle directory is accessible by group or other users"))
  entries <- sort <$> listDirectory bundle
  unless (entries == sort [metadataFileName, planFileName, reviewFileName]) $
    ioError (userError "bundle must contain exactly metadata.json, pulumi-plan.json, and review.json")
  forM_ entries $ \entry -> do
    let path = bundle </> entry
    entryLinked <- pathIsSymbolicLink path
    when entryLinked (ioError (userError (entry <> " is a symlink")))
    status <- getFileStatus path
    unless (isRegularFile status) (ioError (userError (entry <> " is not a regular file")))
    unless (privateMode status) (ioError (userError (entry <> " is accessible by group or other users")))
  where
    privateMode status = fileMode status .&. 0o077 == 0

-- | Preview the stack and refuse a plan that replaces a protected resource (the
-- GCE instance, the Cloud DNS zone, or a bucket). Any failure to preview or parse
-- is a refusal. Shared by @nagarectl infra guard@ and the upgrade's Pulumi phases
-- (EP-121), so the transaction is never less guarded than @just infra-up@.
instanceReplacementGuard :: TargetProfile -> PlatformWorkspace -> String -> Bool -> IO (Either Text Text)
instanceReplacementGuard tp workspace stack allowReplacement =
  case validateVmShape (vmShapeOf tp) of
    Left err -> pure (Left err)
    Right _ -> do
      previewResult <-
        catch
          (Right <$> readProcessWithExitCode "pulumi" ["-C", workspace ^. #pulumiDir, "preview", "--json", "--stack", stack, "--non-interactive"] "")
          (pure . Left . (\(err :: IOException) -> err))
      pure $ case previewResult of
        Left err -> Left ("infra guard could not run Pulumi preview; refusing to apply: " <> T.pack (show err))
        Right (ExitFailure code, out, err) ->
          Left
            ( "infra guard could not inspect the Pulumi plan (preview exited "
                <> T.pack (show code)
                <> "); refusing to apply:\n"
                <> T.strip (T.unlines (T.pack err : previewErrors (TE.encodeUtf8 (T.pack out))))
            )
        Right (ExitSuccess, out, _) ->
          case parsePreview (TE.encodeUtf8 (T.pack out)) of
            Left err -> Left ("infra guard could not parse Pulumi preview; refusing to apply: " <> err)
            Right steps ->
              let verdict = classifyPlan protectedResourceTypes steps
                  message = renderVerdict (tp ^. #instanceName) verdict
               in case verdict of
                    PlanAllowed -> Right message
                    PlanReplacesProtected _
                      | allowReplacement -> Right ("Protected resource replacement explicitly allowed for this run.\n" <> message)
                      | otherwise -> Left message

-- | @nagarectl init@: the guided onboarding flow (EP-63). Order: resolve target
-- (flags or prompts) -> preflight (gcloud auth + operator IAM) -> write the profile
-- -> enable APIs -> seed Pulumi config -> print next steps. Each side-effecting
-- stage is skippable. The ONLY command that drives Pulumi/gcloud (MasterPlan 12
-- Decision Log).
runInit :: Maybe String -> InitOpts -> IO ()
runInit mctx o = case o ^. #contextName of
  Just rawName -> parseContextNameOrDie rawName >>= runNamedInit o
  Nothing -> runLegacyInit mctx o

-- | Initialize a named context from flags, built-in defaults, and only that
-- context's stored values under @--force@. No active-context resolver appears in
-- this path, which prevents ambient or foreign context values from becoming part
-- of a newly created context.
runNamedInit :: InitOpts -> ContextName -> IO ()
runNamedInit o contextName = do
  base <- either dieT pure =<< resolveInitBase contextName (o ^. #force)
  let preliminaryProfile = profileFromContextMap (initContextMap base (initFlagPairs o) "")
  preflightInitTools o (effectivePulumiBackend preliminaryProfile)
  pathsResult <- resolvePlatformPaths Nothing
  payloadPaths <- either (dieT . renderPlatformPathError) pure pathsResult
  manifest <- either (dieT . renderWorkspaceError) pure =<< readPayloadManifest payloadPaths
  let storedDefaults = profileFromContextMap (initContextMap base [] (manifest ^. #platformVersion))
      projectDefault = fromMaybe "" (base >>= Map.lookup "CLOUDSDK_CORE_PROJECT")
      acmeEmailDefault = fromMaybe "" (base >>= Map.lookup "NAGARE_ACME_EMAIL")

  project <- resolveField (T.null projectDefault) "GCP project id" "project" (o ^. #project) projectDefault
  region <- resolveField False "Compute region" "region" (o ^. #region) (storedDefaults ^. #region)
  zone <- resolveField False "Compute zone" "zone" (o ^. #zone) (storedDefaults ^. #zone)
  baseDomain <- resolveField False "Apps base domain" "base-domain" (o ^. #baseDomain) (storedDefaults ^. #baseDomain)
  machineType <- resolveField False "GCE machine type" "machine-type" (o ^. #machineType) (storedDefaults ^. #machineType)
  bootDiskType <- resolveField False "Boot disk type" "boot-disk-type" (o ^. #bootDiskType) (storedDefaults ^. #bootDiskType)
  bootDiskSizeGb <- resolveField False "Boot disk size (GB)" "boot-disk-size-gb" (o ^. #bootDiskSizeGb) (storedDefaults ^. #bootDiskSizeGb)
  dataDiskSizeGb <- resolveField False "Data disk size (GB)" "data-disk-size-gb" (o ^. #dataDiskSizeGb) (storedDefaults ^. #dataDiskSizeGb)
  shape <-
    either dieT pure $
      validateVmShape
        VmShape
          { machineType = machineType
          , bootDiskType = bootDiskType
          , bootDiskSizeGb = bootDiskSizeGb
          , dataDiskSizeGb = dataDiskSizeGb
          }
  acmeEmailRaw <- resolveField (T.null acmeEmailDefault) "Let's Encrypt contact address" "acme-email" (o ^. #acmeEmail) acmeEmailDefault
  acmeEmail <- either dieT pure (validateAcmeEmail acmeEmailRaw)
  let acmeDirectoryRaw = maybe (storedDefaults ^. #acmeDirectory) T.pack (o ^. #acmeDirectory)
  acmeDirectory <- either dieT (pure . acmeDirectoryToken) (parseAcmeDirectory acmeDirectoryRaw)

  let resolvedOpts =
        o
          & #project
          .~ Just (T.unpack project)
          & #region
          .~ Just (T.unpack region)
          & #zone
          .~ Just (T.unpack zone)
          & #baseDomain
          .~ Just (T.unpack baseDomain)
          & #machineType
          .~ Just (T.unpack (shape ^. #machineType))
          & #bootDiskType
          .~ Just (T.unpack (shape ^. #bootDiskType))
          & #bootDiskSizeGb
          .~ Just (T.unpack (shape ^. #bootDiskSizeGb))
          & #dataDiskSizeGb
          .~ Just (T.unpack (shape ^. #dataDiskSizeGb))
          & #acmeEmail
          .~ Just (T.unpack acmeEmail)
          & #acmeDirectory
          .~ Just (T.unpack acmeDirectory)
      tp =
        profileFromContextMap
          (initContextMap base (initFlagPairs resolvedOpts) (manifest ^. #platformVersion))
      context = contextNameText contextName

  void (either dieT pure (validateVmShape (vmShapeOf tp)))
  either dieT pure (validateNixCacheMode tp)
  TIO.putStr (renderInitSummary context tp)
  either dieT pure (checkInitOwnership (isJust (o ^. #pulumiBackendUrl)) context tp)
  (paths, workspace) <- resolvePlatformWorkspace contextName

  unless (o ^. #skipPreflight) $ do
    putStrLn ("Checking gcloud authentication and operator IAM on " <> T.unpack project <> "...")
    result <- runPreflight project
    case result of
      Left message -> TIO.hPutStr stderr message >> exitFailure
      Right warnings -> do
        printPreflightWarnings warnings
        putStrLn "  preflight OK"

  exportProfileEnv contextName tp
  writeNamedContext (o ^. #force) (o ^. #dryRun) contextName tp
  unless (o ^. #dryRun) (setCurrentContext contextName)
  if o ^. #dryRun
    then TIO.putStrLn ("DRY RUN — would write context '" <> context <> "' and set it current.")
    else TIO.putStrLn ("Wrote context '" <> context <> "' and set it current.")

  unless (o ^. #skipEnable) $ do
    putStrLn "Enabling GCP service APIs..."
    if o ^. #dryRun
      then do
        TIO.putStrLn "DRY RUN: would run:"
        TIO.putStrLn ("  gcloud services enable " <> T.unwords requiredApis <> " --project=" <> project)
      else do
        code <- enableApis (workspace ^. #scriptsDir </> "enable-apis.sh") False
        case code of
          ExitSuccess -> pure ()
          ExitFailure _ ->
            dieT
              ( "enable-apis failed; see the gcloud output above. The context '"
                  <> context
                  <> "' is written and current. After fixing the cause, re-run `nagarectl init "
                  <> context
                  <> " --force --skip-preflight` (it keeps the context's stored values)."
              )

  unless (o ^. #skipSeed) $ do
    putStrLn "Seeding Pulumi stack config from the profile..."
    bootstrapResult <- bootstrapPulumiStateBucket (o ^. #dryRun) context tp (T.pack <$> o ^. #pulumiBackendMember)
    either
      ( \message ->
          dieT
            ( "GCS state-bucket bootstrap failed: "
                <> message
                <> " The context '"
                <> context
                <> "' is written and current. Fix the cause and run `nagarectl context use "
                <> context
                <> "` to finish seeding."
            )
      )
      pure
      bootstrapResult
    unless (o ^. #dryRun) (ensurePulumiInWorkspace contextName tp workspace)
    result <- seedPulumiConfig (workspace ^. #pulumiDir) (o ^. #dryRun) context tp
    case result of
      Right () -> pure ()
      Left (key, code) -> dieT (namedSeedFailure context key code)

  TIO.putStr (nextStepsText (paths ^. #rootSource))

printPreflightWarnings :: [Text] -> IO ()
printPreflightWarnings = mapM_ (TIO.putStrLn . ("  warning: " <>))

-- | Legacy no-name initialization retains its active-context-compatible
-- resolver and writes @./nagare.target.env@.
runLegacyInit :: Maybe String -> InitOpts -> IO ()
runLegacyInit mctx o = do
  preflightInitTools o (parsePulumiBackendKind (o ^. #pulumiBackend))
  -- Defaults for prompts come from the current resolved profile, so re-running
  -- shows the operator their existing values.
  defs <- activeProfile mctx

  -- Resolve the core target values from flags or interactive prompts. Only
  -- the project is mandatory in non-interactive mode (there is no safe default for
  -- "your project"); region/zone/base-domain fall back to their EP-60 defaults.
  project <- resolveField True "GCP project id" "project" (o ^. #project) (defs ^. #project)
  region <- resolveField False "Compute region" "region" (o ^. #region) (defs ^. #region)
  zone <- resolveField False "Compute zone" "zone" (o ^. #zone) (defs ^. #zone)
  baseDomain <- resolveField False "Apps base domain" "base-domain" (o ^. #baseDomain) (defs ^. #baseDomain)
  machineType <- resolveField False "GCE machine type" "machine-type" (o ^. #machineType) (defs ^. #machineType)
  bootDiskType <- resolveField False "Boot disk type" "boot-disk-type" (o ^. #bootDiskType) (defs ^. #bootDiskType)
  bootDiskSizeGb <- resolveField False "Boot disk size (GB)" "boot-disk-size-gb" (o ^. #bootDiskSizeGb) (defs ^. #bootDiskSizeGb)
  dataDiskSizeGb <- resolveField False "Data disk size (GB)" "data-disk-size-gb" (o ^. #dataDiskSizeGb) (defs ^. #dataDiskSizeGb)
  shape <-
    either dieT pure $
      validateVmShape
        VmShape
          { machineType = machineType
          , bootDiskType = bootDiskType
          , bootDiskSizeGb = bootDiskSizeGb
          , dataDiskSizeGb = dataDiskSizeGb
          }

  -- EP-112: the ACME contact is mandatory, exactly like the project. There is no
  -- safe default for "your mailbox", and a Let's Encrypt account registered under
  -- the wrong address cannot be re-pointed without deleting its account key — so
  -- the cheapest possible failure is here, before a context file exists.
  acmeEmailRaw <- resolveField True "Let's Encrypt contact address" "acme-email" (o ^. #acmeEmail) (defs ^. #acmeEmail)
  acmeEmail <- either dieT pure (validateAcmeEmail acmeEmailRaw)
  let acmeDirectoryRaw = maybe (defs ^. #acmeDirectory) T.pack (o ^. #acmeDirectory)
  acmeDirectory <- either dieT (pure . acmeDirectoryToken) (parseAcmeDirectory acmeDirectoryRaw)

  -- Preflight (unless skipped). Runs AFTER we know the project but BEFORE any
  -- write/enable/seed, so a failure leaves nothing changed.
  unless (o ^. #skipPreflight) $ do
    putStrLn ("Checking gcloud authentication and operator IAM on " <> T.unpack project <> "...")
    r <- runPreflight project
    case r of
      Left msg -> TIO.hPutStr stderr msg >> exitFailure
      Right warnings -> do
        printPreflightWarnings warnings
        putStrLn "  preflight OK"

  -- Build the fully-derived profile (registry host, buckets) via the EP-62 resolver,
  -- then apply the EP-93 Pulumi backend choice (default local; gcs is cloud-only and
  -- downgraded in local mode by effectivePulumiBackend).
  tpBase <- profileFromOpts project region zone baseDomain shape acmeEmail acmeDirectory
  let baseProfile =
        tpBase
          & #pulumiBackend
          .~ parsePulumiBackendKind (o ^. #pulumiBackend)
          & #pulumiBackendUrl
          .~ maybe "" T.pack (o ^. #pulumiBackendUrl)
          & #inventoryStore
          .~ parseInventoryStoreKind (o ^. #inventoryStore)
          & #inventoryStoreUrl
          .~ maybe "" T.pack (o ^. #inventoryStoreUrl)
          & #nixCacheEnabled
          .~ maybe (defs ^. #nixCacheEnabled) (== "1") (o ^. #nixCacheEnabled)
          & #nixCacheBucket
          .~ maybe (project <> "-nagare-nix-cache") T.pack (o ^. #nixCacheBucket)
  contextName <- case o ^. #contextName of
    Just rawName -> parseContextNameOrDie rawName
    Nothing -> parseContextNameOrDie "default"
  (paths, workspace) <- resolvePlatformWorkspace contextName
  let tp = case o ^. #contextName of
        Just _ -> baseProfile & #platformVersion .~ Just (workspace ^. #platformVersion)
        Nothing -> baseProfile

  either dieT pure (validateNixCacheMode tp)

  case o ^. #contextName of
    Just _ -> do
      writeNamedContext (o ^. #force) (o ^. #dryRun) contextName tp
      unless (o ^. #dryRun) $ setCurrentContext contextName
      if o ^. #dryRun
        then TIO.putStrLn ("DRY RUN — would write context '" <> contextNameText contextName <> "' and set it current.")
        else TIO.putStrLn ("Wrote context '" <> contextNameText contextName <> "' and set it current.")
    Nothing -> do
      -- Write the profile idempotently.
      wr <- writeTargetEnv (o ^. #force) (o ^. #dryRun) tp
      case wr of
        Wrote -> putStrLn "Wrote nagare.target.env"
        DryRunWouldWrite -> do
          putStrLn "DRY RUN — would write nagare.target.env:"
          TIO.putStr (renderTargetEnv tp)
        RefusedExists ->
          dieT "nagare.target.env already exists; re-run with --force to overwrite it."

  -- Enable the GCP APIs (unless skipped).
  unless (o ^. #skipEnable) $ do
    putStrLn "Enabling GCP service APIs..."
    code <- enableApis (workspace ^. #scriptsDir </> "enable-apis.sh") (o ^. #dryRun)
    case code of
      ExitSuccess -> pure ()
      ExitFailure _ -> dieT "enable-apis failed; see the gcloud output above. Re-run `nagarectl init --skip-preflight` after fixing it."

  -- Seed the Pulumi stack config (unless skipped).
  unless (o ^. #skipSeed) $ do
    putStrLn "Seeding Pulumi stack config from the profile..."
    bootstrapGcsIfNeeded (o ^. #dryRun) (contextNameText contextName) tp (T.pack <$> o ^. #pulumiBackendMember)
    unless (o ^. #dryRun) (ensurePulumiInWorkspace contextName tp workspace)
    s <- seedPulumiConfig (workspace ^. #pulumiDir) (o ^. #dryRun) (contextNameText contextName) tp
    case s of
      Right () -> pure ()
      Left (k, ExitFailure 127) -> dieT ("pulumi could not be started while setting key " <> k <> "; install the nagare operator package and re-run `nagarectl init --skip-preflight --skip-enable`.")
      Left (k, _) -> dieT ("pulumi config set failed at key " <> k <> "; fix Pulumi state and re-run `nagarectl init --skip-preflight --skip-enable`.")

  -- Next steps.
  TIO.putStr (nextStepsText (paths ^. #rootSource))

preflightInitTools :: InitOpts -> PulumiBackendKind -> IO ()
preflightInitTools o backend = do
  missing <- findMissingTools (requiredInitTools o backend)
  unless (null missing) $
    dieT
      ( T.unlines
          ( ["init: required tools are not on PATH: " <> T.intercalate ", " (map T.pack missing)]
              <> [ "  pulumi ships with the nagare package (nix profile install github:shinzui/nagare/v"
                     <> currentBuildVersion ^. #version
                     <> "#nagare);"
                 | "pulumi" `elem` missing
                 ]
              <> ["  npm comes from Node.js, which must be installed separately." | "npm" `elem` missing]
              <> ["  Google Cloud SDK must be installed separately." | "gcloud" `elem` missing]
              <> ["  Nothing was changed."]
          )
      )

namedSeedFailure :: Text -> Text -> ExitCode -> Text
namedSeedFailure context key code =
  prefix
    <> " at key "
    <> key
    <> "; the context '"
    <> context
    <> "' is written and current. Fix the cause and run `nagarectl context use "
    <> context
    <> "` to finish seeding."
  where
    prefix = case code of
      ExitFailure 127 -> "pulumi could not be started"
      _ -> "pulumi config set failed"

-- | Export the named profile for child scripts. Empty values are removed so a
-- stale ambient value cannot outrank the new context. Pulumi's own variables are
-- still installed by 'ensurePulumiInWorkspace'.
exportProfileEnv :: ContextName -> TargetProfile -> IO ()
exportProfileEnv name tp = mapM_ (uncurry setOrUnset) fields
  where
    context = contextNameText name
    fields =
      [ ("NAGARE_CONTEXT", context)
      , ("CLOUDSDK_CORE_PROJECT", tp ^. #project)
      , ("CLOUDSDK_COMPUTE_REGION", tp ^. #region)
      , ("CLOUDSDK_COMPUTE_ZONE", tp ^. #zone)
      , ("NAGARE_REGISTRY_HOST", tp ^. #registryHost)
      , ("NAGARE_ARTIFACT_REGISTRY_ID", tp ^. #artifactRegistryId)
      , ("NAGARE_IMAGE_BUCKET", tp ^. #imageBucket)
      , ("NAGARE_BACKUP_BUCKET", tp ^. #backupBucket)
      , ("NAGARE_BASE_DOMAIN", tp ^. #baseDomain)
      , ("NAGARE_ACME_EMAIL", tp ^. #acmeEmail)
      , ("NAGARE_ACME_DIRECTORY", tp ^. #acmeDirectory)
      , ("NAGARE_INSTANCE_NAME", tp ^. #instanceName)
      , ("NAGARE_MACHINE_TYPE", tp ^. #machineType)
      , ("NAGARE_BOOT_DISK_TYPE", tp ^. #bootDiskType)
      , ("NAGARE_BOOT_DISK_SIZE_GB", tp ^. #bootDiskSizeGb)
      , ("NAGARE_DATA_DISK_SIZE_GB", tp ^. #dataDiskSizeGb)
      , ("NAGARE_TARGET_PLATFORM", tp ^. #targetPlatform)
      , ("NAGARE_MODE", modeToken (tp ^. #mode))
      , ("NAGARE_LOCAL_OBJECT_STORE", tp ^. #localObjectStore)
      , ("NAGARE_PULUMI_BACKEND", pulumiBackendToken (effectivePulumiBackend tp))
      , ("NAGARE_PULUMI_BACKEND_URL", tp ^. #pulumiBackendUrl)
      , ("NAGARE_INVENTORY_STORE", inventoryStoreToken (effectiveInventoryStore tp))
      , ("NAGARE_INVENTORY_STORE_URL", tp ^. #inventoryStoreUrl)
      , ("NAGARE_REGISTRY_PREFIX", registryPrefix tp)
      , ("NAGARE_PULUMI_STACK", context)
      ]
        <> maybe [] (\version -> [("NAGARE_PLATFORM_VERSION", version)]) (tp ^. #platformVersion)
    setOrUnset key fieldValue
      | T.null fieldValue = unsetEnv key
      | otherwise = setEnv key (T.unpack fieldValue)
    modeToken Cloud = "cloud"
    modeToken Local = "local"

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

runContext :: Maybe String -> ContextCommand -> IO ()
runContext mctx = \case
  ContextList -> do
    names <- listContexts
    cur <- readCurrentContext
    rows <- forM names $ \name -> do
      e <- readContextProfile name
      pure $ case e of
        Right tp -> (name, tp ^. #project, tp ^. #baseDomain)
        Left _ -> (name, "(unreadable)", "")
    TIO.putStr (formatContextList cur rows)
  ContextCurrent ->
    readCurrentContext >>= maybe (dieT "no current context set") (TIO.putStrLn . contextNameText)
  ContextUse rawName -> do
    name <- parseContextNameOrDie rawName
    ok <- contextExists name
    if ok
      then do
        setCurrentContext name
        tp <- either dieT pure =<< readContextProfile name
        case tp ^. #mode of
          Local -> void (resolvePlatformWorkspace name)
          Cloud -> do
            workspace <- ensurePulumiForContext name tp
            s <- seedPulumiConfig (workspace ^. #pulumiDir) False (contextNameText name) tp
            case s of
              Right () -> pure ()
              Left (k, code) -> dieT (namedSeedFailure (contextNameText name) k code)
        TIO.putStrLn ("Switched to context '" <> contextNameText name <> "'")
      else dieT ("no such context: " <> contextNameText name)
  ContextShow mname -> do
    tp <- case mname of
      Just rawName -> do
        name <- parseContextNameOrDie rawName
        either dieT pure =<< readContextProfile name
      Nothing -> activeProfile mctx
    TIO.putStr (renderTargetEnv tp)
  ContextCreate rawName o -> do
    name <- parseContextNameOrDie rawName
    exists <- contextExists name
    when (exists && not (o ^. #force)) $
      dieT ("context '" <> contextNameText name <> "' already exists; pass --force to change the given fields")
    -- EP-112: validate the ACME identity BEFORE a context file exists, so a typo
    -- is reported here rather than at `nagare cluster-bootstrap`. The contact is
    -- OPTIONAL here (unlike `init`): this is the low-level writer that also
    -- creates local contexts, where no ACME account is ever registered. The
    -- renderer's refusal is the backstop for a context written without one.
    mapM_ (either dieT (const (pure ())) . validateAcmeEmail . T.pack) (o ^. #acmeEmail)
    mapM_ (either dieT (const (pure ())) . parseAcmeDirectory . T.pack) (o ^. #acmeDirectory)
    (_, workspace) <- resolvePlatformWorkspace name
    path <- contextFilePath name
    -- EP-121: --force merges onto the stored context rather than resetting every
    -- omitted field to its default.
    stored <- if exists then readContextMap path else pure Nothing
    let contextMap = mergeContextOverrides stored (contextEnvPairs o) (workspace ^. #platformVersion)
        tp = profileFromContextMap contextMap
    void (either dieT pure (validateVmShape (vmShapeOf tp)))
    either dieT pure (validateNixCacheMode tp)
    when (tp ^. #mode == Local && tp ^. #externalDomainTlsEnabled)
      (dieT "external domain TLS belongs to cloud contexts")
    writeContextProfile name tp
    TIO.putStrLn ("Wrote context '" <> contextNameText name <> "' (" <> T.pack path <> ")")
    forM_ stored $ \previous -> do
      let before = T.lines (renderTargetEnv (profileFromContextMap previous))
          changed = filter (`notElem` before) (T.lines (renderTargetEnv tp))
      if null changed
        then TIO.putStrLn "No fields changed."
        else TIO.putStr (T.unlines ("Changed:" : map ("  " <>) changed))
    when (o ^. #use) $ do
      setCurrentContext name
      when (tp ^. #mode == Cloud) $ do
        bootstrapGcsIfNeeded False (contextNameText name) tp (T.pack <$> o ^. #pulumiBackendMember)
        ensurePulumiInWorkspace name tp workspace
        s <- seedPulumiConfig (workspace ^. #pulumiDir) False (contextNameText name) tp
        case s of
          Right () -> pure ()
          Left (k, code) -> dieT (namedSeedFailure (contextNameText name) k code)
      TIO.putStrLn ("Set current context to '" <> contextNameText name <> "'")
  ContextGuard asJson -> runContextGuard mctx asJson
  ContextEnv -> runContextEnv mctx
  ContextDelete rawName yes -> do
    name <- parseContextNameOrDie rawName
    ok <- contextExists name
    if not ok
      then dieT ("no such context: " <> contextNameText name)
      else
        if not yes
          then dieT ("refusing to delete '" <> contextNameText name <> "' without --yes")
          else do
            deleteContext name
            cur <- readCurrentContext
            when (cur == Just name) clearCurrentContext
            TIO.putStrLn ("Deleted context '" <> contextNameText name <> "'")

-- | @nagarectl context env@ (EP-113). Print the active context's shell environment
-- as @export K=V@ lines and nothing else, so the packaged @nagare@ launcher can
-- @eval@ it. A clone-free install has no @.envrc@, so without this every
-- Pulumi-invoking recipe inherits whatever Pulumi state the invoking shell happens
-- to carry — which, for an installed operator, is none.
--
-- Ensuring the per-context Pulumi home and state directory exist is done here, not
-- in the launcher, so the launcher stays a two-line shim.
runContextEnv :: Maybe String -> IO ()
runContextEnv mctx = do
  active <- activeTarget mctx
  let name = active ^. #contextName
      tp = active ^. #profile
  _ <- ensurePulumiForContext name tp
  stateRoot <- nagareStateDir
  TIO.putStr (renderContextShellEnv name tp (pulumiEnvFor stateRoot (contextNameText name) tp))

-- | @nagarectl context guard@ (EP-113). The project-confinement preflight for
-- @just infra-up@ / @just infra-preview@, which before this had no project check at
-- all: the selected Pulumi stack's own config was the only thing standing between
-- @pulumi up@ and someone else's project.
--
-- Deliberately separate from @nagarectl platform guard@, which answers the orthogonal
-- release-compatibility question. The @justfile@ composes both, which is where a
-- recipe's full preflight belongs.
runContextGuard :: Maybe String -> Bool -> IO ()
runContextGuard mctx asJson = do
  active <- activeTarget mctx
  let name = active ^. #contextName
      tp = active ^. #profile
      ctx = contextNameText name
  case tp ^. #mode of
    -- A local context has no GCP project, exactly as `_require_target_project` in
    -- scripts/lib/target.sh has no project to check there.
    Local ->
      if asJson
        then LBC.putStrLn (Aeson.encode (Aeson.object ["context" Aeson..= ctx, "mode" Aeson..= ("local" :: Text), "confined" Aeson..= True]))
        else TIO.putStrLn "context guard: local mode; no GCP project to confine"
    Cloud -> do
      -- ADC is checked before workspace preparation because preparation can invoke
      -- Pulumi. A foreign quota project must stop the very first Pulumi process.
      (gcloudAccount, adc) <- observeAdcForProject
      case validateAdc (tp ^. #project) gcloudAccount adc of
        Left msg ->
          if asJson
            then do
              let observed =
                    Aeson.object
                      [ "context" Aeson..= ctx
                      , "declaredProject" Aeson..= (tp ^. #project)
                      , "gcloudAccount" Aeson..= gcloudAccount
                      , "adc" Aeson..= adcEvidenceValue (tp ^. #project) gcloudAccount adc
                      , "warnings" Aeson..= ([] :: [Text])
                      ]
              LBC.hPutStrLn stderr (Aeson.encode (Aeson.object ["confined" Aeson..= False, "refusal" Aeson..= msg, "observations" Aeson..= observed]))
              exitFailure
            else dieT msg
        Right _ -> pure ()
      -- Ensure the per-context PULUMI_HOME, backend URL and stack exist and are
      -- selected, so the guard is usable as the ONLY preflight a clone-free recipe
      -- needs. These operations are idempotent and `.envrc` performs them on every
      -- shell entry already.
      workspace <- ensurePulumiForContextWithInstallNotice (not asJson) name tp
      pgi <- projectGuardInputsFor name tp workspace
      let observed = projectGuardObservationsValue pgi
      case projectGuardVerdict pgi of
        Left msg ->
          if asJson
            then do
              LBC.hPutStrLn stderr (Aeson.encode (Aeson.object ["confined" Aeson..= False, "refusal" Aeson..= msg, "observations" Aeson..= observed]))
              exitFailure
            else dieT msg
        Right () ->
          if asJson
            then LBC.putStrLn (Aeson.encode (Aeson.object ["confined" Aeson..= True, "observations" Aeson..= observed]))
            else TIO.putStrLn (renderProjectGuard pgi)

-- | The three project observations the project guard compares with the context.
-- Shared by @nagarectl context guard@ and the upgrade's Pulumi phases (EP-121).
projectGuardInputsFor :: ContextName -> TargetProfile -> PlatformWorkspace -> IO ProjectGuardInputs
projectGuardInputsFor name tp workspace = do
  stateRoot <- nagareStateDir
  let ctx = contextNameText name
      penv = pulumiEnvFor stateRoot ctx tp
      stack = penv ^. #stack
  (gcloudAccount, adc) <- observeAdcForProject
  stackProject <- case validateAdc (tp ^. #project) gcloudAccount adc of
    Left _ -> pure PulumiProbeSkipped
    Right _ -> probePulumiProject (workspace ^. #pulumiDir) stack
  ambient <- fmap T.pack <$> lookupEnv "CLOUDSDK_CORE_PROJECT"
  configured <- gcloudConfiguredProject
  pure
    ProjectGuardInputs
      { context = ctx
      , declared = tp ^. #project
      , stack = stack
      , pulumiBackendUrl = penv ^. #backendUrl
      , stackProject = stackProject
      , ambient = nonBlank =<< ambient
      , configured = configured
      , gcloudAccount = gcloudAccount
      , adc = adc
      }
  where
    nonBlank t = if T.null (T.strip t) then Nothing else Just (T.strip t)
    -- gcloud lets CLOUDSDK_CORE_PROJECT shadow its own configuration, so read the
    -- configured value with that variable stripped from the child's environment —
    -- otherwise the comparison would be a tautology. Modify the inherited
    -- environment rather than unsetting the variable in this process, which would
    -- not be safe.
    gcloudConfiguredProject = do
      parentEnv <- getEnvironment
      let childEnv = filter ((/= "CLOUDSDK_CORE_PROJECT") . fst) parentEnv
      captured <-
        (readCreateProcessResult childEnv) `catch` \(_ :: IOException) -> pure Nothing
      pure (nonBlank =<< captured)
    readCreateProcessResult childEnv = do
      (code, out, _) <-
        readCreateProcessWithExitCode
          (proc "gcloud" ["config", "get-value", "project"]) {env = Just childEnv}
          ""
      pure $ case code of
        ExitSuccess -> Just (T.pack out)
        ExitFailure _ -> Nothing

observeAdcForProject :: IO (Maybe Text, Either AdcError AdcObservation)
observeAdcForProject = do
  gcloudAccount <- activeGcloudAccount
  adcEnv <- adcEnvFromProcess
  adc <- observeAdc adcEnv
  pure (gcloudAccount, adc)

activeGcloudAccount :: IO (Maybe Text)
activeGcloudAccount = do
  observed <- captureTool "gcloud" ["auth", "list", "--filter=status:ACTIVE", "--format=value(account)"]
  pure (nonBlank =<< fmap (TE.decodeUtf8) observed)
  where
    nonBlank accountText
      | T.null (T.strip accountText) = Nothing
      | otherwise = Just (T.strip accountText)

-- | Collect the evidence required by the project guard without collapsing a
-- missing tool, a failed command, invalid output, and an absent config key.
probePulumiProject :: FilePath -> Text -> IO PulumiProjectObservation
probePulumiProject pulumiDir stack = do
  executable <- findExecutable "pulumi"
  case executable of
    Nothing -> pure PulumiToolNotFound
    Just path -> do
      result <-
        catch
          ( Right
              <$> readProcessWithExitCode
                path
                [ "-C"
                , pulumiDir
                , "config"
                , "--json"
                , "--stack"
                , T.unpack stack
                , "--non-interactive"
                ]
                ""
          )
          (pure . Left . T.pack . displayExceptionText)
      pure $ case result of
        Left err -> PulumiToolStartFailed err
        Right (ExitFailure exitCode, out, err) ->
          PulumiCommandFailed exitCode (commandDiagnostic out err)
        Right (ExitSuccess, out, _) ->
          either PulumiProjectInvalidOutput (\observation -> observation) (parsePulumiProjectConfig (TE.encodeUtf8 (T.pack out)))
  where
    displayExceptionText :: IOException -> String
    displayExceptionText = show
    commandDiagnostic out err =
      case filter (not . T.null) [T.strip (T.pack err), T.strip (T.pack out)] of
        diagnostic : _ -> diagnostic
        [] -> "(no stderr)"

parseContextNameOrDie :: String -> IO ContextName
parseContextNameOrDie raw =
  either (dieT . ("invalid context name: " <>)) pure (mkContextName (T.pack raw))

writeContextProfile :: ContextName -> TargetProfile -> IO ()
writeContextProfile name tp = do
  dir <- contextsDir
  createDirectoryIfMissing True dir
  path <- contextFilePath name
  TIO.writeFile path (renderTargetEnv tp)

writeNamedContext :: Bool -> Bool -> ContextName -> TargetProfile -> IO ()
writeNamedContext force dryRun name tp = do
  exists <- contextExists name
  when (exists && not force) $
    dieT ("context '" <> contextNameText name <> "' already exists; pass --force to overwrite it.")
  if dryRun
    then TIO.putStr (renderTargetEnv tp)
    else writeContextProfile name tp

contextEnvPairs :: ContextCreateOpts -> [(String, Text)]
contextEnvPairs o =
  catMaybes
    [ pair "CLOUDSDK_CORE_PROJECT" (o ^. #project)
    , pair "CLOUDSDK_COMPUTE_REGION" (o ^. #region)
    , pair "CLOUDSDK_COMPUTE_ZONE" (o ^. #zone)
    , pair "NAGARE_BASE_DOMAIN" (o ^. #baseDomain)
    , pair "NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED" (o ^. #externalDomainTlsEnabled)
    , pair "NAGARE_MACHINE_TYPE" (o ^. #machineType)
    , pair "NAGARE_BOOT_DISK_TYPE" (o ^. #bootDiskType)
    , pair "NAGARE_BOOT_DISK_SIZE_GB" (o ^. #bootDiskSizeGb)
    , pair "NAGARE_DATA_DISK_SIZE_GB" (o ^. #dataDiskSizeGb)
    , pair "NAGARE_REGISTRY_HOST" (o ^. #registryHost)
    , pair "NAGARE_ARTIFACT_REGISTRY_ID" (o ^. #artifactRegistryId)
    , pair "NAGARE_IMAGE_BUCKET" (o ^. #imageBucket)
    , pair "NAGARE_BACKUP_BUCKET" (o ^. #backupBucket)
    , pair "NAGARE_NIX_CACHE_ENABLED" (o ^. #nixCacheEnabled)
    , pair "NAGARE_NIX_CACHE_BUCKET" (o ^. #nixCacheBucket)
    , pair "NAGARE_INSTANCE_NAME" (o ^. #instanceName)
    , pair "NAGARE_TARGET_PLATFORM" (o ^. #targetPlatform)
    , pair "NAGARE_MODE" (o ^. #mode)
    , pair "NAGARE_LOCAL_OBJECT_STORE" (o ^. #localObjectStore)
    , pair "NAGARE_PULUMI_BACKEND" (o ^. #pulumiBackend)
    , pair "NAGARE_PULUMI_BACKEND_URL" (o ^. #pulumiBackendUrl)
    , pair "NAGARE_INVENTORY_STORE" (o ^. #inventoryStore)
    , pair "NAGARE_INVENTORY_STORE_URL" (o ^. #inventoryStoreUrl)
    , pair "NAGARE_ACME_EMAIL" (o ^. #acmeEmail)
    , pair "NAGARE_ACME_DIRECTORY" (o ^. #acmeDirectory)
    ]
  where
    pair k mv = fmap (\v -> (k, T.pack v)) mv

formatContextList :: Maybe ContextName -> [(ContextName, Text, Text)] -> Text
formatContextList cur rows =
  T.unlines (hdr : map row rows)
  where
    hdr = T.concat [pad 9 "CURRENT", pad 18 "NAME", pad 24 "PROJECT", "BASE DOMAIN"]
    row (name, project, baseDomain) =
      T.concat
        [ pad 9 (if cur == Just name then "*" else "")
        , pad 18 (contextNameText name)
        , pad 24 project
        , baseDomain
        ]
    pad n t =
      let t' = T.take n t
       in t' <> T.replicate (max 1 (n - T.length t')) " "

-- | @domains list@: show partial evidence successfully. @domains check@ uses
-- the same inventory, but treats unavailable probes and unhealthy configured
-- routes as a non-zero operations/CI gate.
runDomainsList :: Maybe String -> DomainsListOpts -> IO ()
runDomainsList mctx o = void (runDomainsInventory False mctx o)

runDomainsCheck :: Maybe String -> DomainsListOpts -> IO ()
runDomainsCheck mctx o = void (runDomainsInventory True mctx o)

runDomainsInventory :: Bool -> Maybe String -> DomainsListOpts -> IO [DomainRow]
runDomainsInventory checking mctx o = do
  (_, workspace) <- ensurePulumiForActiveContext mctx
  tp <- activeProfile mctx
  base <- resolveDomainsBaseAt mctx workspace (o ^. #baseDomain)
  (publicIp, apexIp, cdnGlobalIp) <- case tp ^. #mode of
    Local -> pure (Just "127.0.0.1", Just "127.0.0.1", Nothing)
    Cloud ->
      (,,)
        <$> stackOutput (workspace ^. #pulumiDir) "publicIp"
        <*> stackOutput (workspace ^. #pulumiDir) "apexIp"
        <*> stackOutput (workspace ^. #pulumiDir) "cdnGlobalIp"
  namespaceObservation <-
    if o ^. #allNamespaces
      then observeNamespaces
      else pure (Observed [appNamespace (o ^. #namespace)])
  let nss = case namespaceObservation of
        Observed namespaces -> namespaces
        _ -> []
  baseRow <- queryBaseDomainRow base apexIp
  observations <- traverse (queryDomainRows base publicIp apexIp cdnGlobalIp) nss
  let rows = baseRow : concat [found | Observed found <- observations]
      namespaceFailures = case namespaceObservation of
        Observed _ -> []
        NotFound -> ["namespace inventory was not found"]
        Unavailable detail -> ["namespace inventory unavailable: " <> detail]
      inventoryFailures =
        namespaceFailures
          <> [ namespace <> ": DomainMapping inventory was not found"
             | (namespace, NotFound) <- zip nss observations
             ]
          <> [namespace <> ": " <> detail | (namespace, Unavailable detail) <- zip nss observations]
      failures = inventoryFailures <> domainCheckFailures rows
  if o ^. #json
    then LBC.putStrLn (Aeson.encode (domainReportValue inventoryFailures rows))
    else TIO.putStr (formatDomainList rows)
  unless (checking || null inventoryFailures) $ do
    TIO.hPutStrLn stderr "Domain inventory is partial:"
    mapM_ (TIO.hPutStrLn stderr . ("  " <>)) inventoryFailures
  if checking && not (null failures)
    then do
      TIO.hPutStrLn stderr "Domain check failed:"
      mapM_ (TIO.hPutStrLn stderr . ("  " <>)) failures
      exitFailure
    else pure rows

resolveDomainsBaseAt :: Maybe String -> PlatformWorkspace -> Maybe String -> IO Text
resolveDomainsBaseAt _ _ (Just b) = pure (T.pack b)
resolveDomainsBaseAt mctx workspace Nothing = do
  mp <- stackOutput (workspace ^. #pulumiDir) "baseDomain"
  case mp of
    Just d | not (T.null d) -> pure d
    _ -> resolveBaseDomain mctx Nothing

-- | MasterPlan 11 / EP-58: the @nagarectl cdn@ command group dispatcher.
runCdn :: Maybe String -> CdnCommand -> IO ()
runCdn mctx = \case
  CdnList o -> runCdnList mctx o
  CdnStatus o -> runCdnStatus mctx o
  CdnPurge o -> runCdnPurge o
  CdnDisable o -> runCdnDisable mctx o

-- | @cdn list@: enumerate CDN-fronted hostnames and their provider/DNS/cache/
-- readiness. Discovery degrades gracefully to the empty sentinel when the
-- cluster / cloud tools are unavailable (VM off, no token) — see
-- 'Nagare.Cdn.Status.queryCdnRows'.
runCdnList :: Maybe String -> CdnListOpts -> IO ()
runCdnList mctx o = do
  (_, workspace) <- ensurePulumiForActiveContext mctx
  base <- resolveDomainsBaseAt mctx workspace (o ^. #baseDomain)
  ip <- fromMaybe "(unknown)" <$> stackOutput (workspace ^. #pulumiDir) "publicIp"
  nss <-
    if o ^. #allNamespaces
      then listNamespaces
      else pure [appNamespace (o ^. #namespace)]
  rows <- concat <$> traverse (queryCdnRows base ip) nss
  TIO.putStr (formatCdnList rows)

-- | @cdn status HOST@: show one hostname's CDN state, or an "unknown / not
-- discovered" block when the live discovery cannot run yet.
runCdnStatus :: Maybe String -> CdnStatusOpts -> IO ()
runCdnStatus mctx o = do
  (context, workspace) <- ensurePulumiForActiveContext mctx
  tp <- activeProfile mctx
  base <- resolveDomainsBaseAt mctx workspace (o ^. #baseDomain)
  ip <- fromMaybe "(unknown)" <$> stackOutput (workspace ^. #pulumiDir) "publicIp"
  let ns = appNamespace (o ^. #namespace)
      host = T.pack (o ^. #host)
  rows <- queryCdnRows base ip ns
  case filter ((== host) . (^. #host)) rows of
    (r : _) -> TIO.putStr (formatCdnStatus r)
    [] -> TIO.putStr (formatCdnStatus (CdnRow host "unknown" DnsUnknown "(not discovered)" False))
  certificate <- stackOutput (workspace ^. #pulumiDir) "cdnCertificate"
  mode <- fromMaybe "legacy" <$> stackOutput (workspace ^. #pulumiDir) "cdnCertificateMode"
  forM_ certificate $ \name ->
    unless ("(" `T.isPrefixOf` name) $ do
      observed <-
        captureTool
          "gcloud"
          [ "certificate-manager"
          , "certificates"
          , "describe"
          , T.unpack name
          , "--location=global"
          , "--format=json"
          , "--project=" <> T.unpack (tp ^. #project)
          ]
      let state = case observed of
            Nothing -> "unavailable"
            Just bytes -> either ("invalid: " <>) (\stateText -> stateText) (parseCertificateManagerState bytes)
          activation =
            T.unwords
              [ "pulumi"
              , "-C"
              , T.pack (workspace ^. #pulumiDir)
              , "config set --stack"
              , contextNameText context
              , "nagare:cdnCertificateMode certificate-map"
              ]
      TIO.putStr (formatCertificateManagerStatus name mode state activation)

-- | @cdn purge HOST [--path P]...@: purge the Cloudflare edge cache. @--dry-run@
-- prints the planned purge; live needs @CF_API_TOKEN@.
runCdnPurge :: CdnPurgeOpts -> IO ()
runCdnPurge o = do
  let host = T.pack (o ^. #host)
      paths = map T.pack (o ^. #paths)
      pathsDesc = if null paths then "everything" else T.intercalate ", " paths
  if o ^. #dryRun
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
runCdnDisable :: Maybe String -> CdnDisableOpts -> IO ()
runCdnDisable mctx o = do
  let host = T.pack (o ^. #host)
  (_, workspace) <- ensurePulumiForActiveContext mctx
  tp <- activeProfile mctx
  base <- resolveDomainsBaseAt mctx workspace Nothing
  when (host == base) $
    dieT
      ( "cdn disable will not delete the Pulumi-owned apex record for "
          <> base
          <> "; change nagare:enableCdn and preview the standing infrastructure instead"
      )
  either (dieT . ("cdn disable: " <>)) pure (googleCdnHostname base host)
  refs <- gatherGcpStackRefs (workspace ^. #pulumiDir) tp
  let gArgs =
        [ "dns"
        , "record-sets"
        , "delete"
        , host <> "."
        , "--type=A"
        , "--zone=" <> refs ^. #dnsZone
        , "--project=" <> tp ^. #project
        ]
  if o ^. #dryRun
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
                <> tp ^. #project
                <> "?)"
            )

-- | @cleanup@: gather (and, under @--confirm@, perform) reclamation across
-- images/previews/releases, then print the report. Dry-run by default.
runCleanup :: Maybe String -> CleanupOpts -> IO ()
runCleanup mctx o = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  report <- executeCleanup (workspace ^. #scriptsDir </> "iap-ssh.sh") (active ^. #profile . #instanceName) o
  TIO.putStr (formatCleanupReport report)

-- | Print the exact convergent Namespace action used by live workload deploys.
printNamespaceAction :: Text -> IO ()
printNamespaceAction namespace = do
  manifest <- orDie (renderNamespace ApplicationNamespace namespace)
  BC.putStrLn "--- Namespace manifest ---"
  BC.putStrLn manifest

runDeploy :: Maybe String -> DeployOpts -> IO ()
runDeploy mctx dopts = case dopts ^. #savePlan of
  Just output -> runDeployPlan mctx dopts output
  Nothing -> do
    unless (isNothing (dopts ^. #imageResource)
        && null (dopts ^. #serviceVolumeRecovery)
        && null (dopts ^. #tlsSecretResources)
        && null (dopts ^. #envSecretResources)
        && isNothing (dopts ^. #legacyReleaseImport)
        && isNothing (dopts ^. #releaseAdoptionInput))
      (dieT "inventory resource and recovery options require --save-plan")
    runDirectDeploy mctx dopts

-- | Database engine and credential authority come from the accepted private
-- review, never from a live name lookup or an independently supplied config.
reviewedStandaloneDatabases
  :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> Resource.ResourceId
  -> Text -> [DatabaseName] -> IO (Map DatabaseName DatabaseBinding)
reviewedStandaloneDatabases _ _ _ _ [] = pure Map.empty
reviewedStandaloneDatabases active snapshot cluster namespaceName names = do
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeSnapshot snapshot)
  (native, _) <- InventoryStatus.loadAcceptedNative store history inventory
    >>= either dieT pure
  either dieT pure (acceptedDatabaseBindings snapshot native cluster namespaceName names)

runDeployPlan :: Maybe String -> DeployOpts -> FilePath -> IO ()
runDeployPlan mctx options output = do
  case (options ^. #legacyReleaseImport, options ^. #releaseAdoptionInput) of
    (Nothing, Nothing) -> pure ()
    (Just _, Just _) -> pure ()
    _ -> dieT "legacy release import requires both --legacy-release-import and --release-adoption-input"
  when (options ^. #dryRun || isJust (options ^. #contextOverride)
      || isJust (options ^. #dockerfileOverride))
    (dieT "reviewed deploy requires a prepublished image and no build overrides or --dry-run")
  when (isNothing (options ^. #tag))
    (dieT "reviewed deploy requires an explicit --tag")
  imageText <- maybe (dieT "--save-plan requires --image-resource") (pure . T.pack)
    (options ^. #imageResource)
  imageId <- either dieT pure (Resource.mkResourceId imageText)
  provisionGhcEnv (options ^. #ghcEnv)
  service <- Load.loadDeployment (options ^. #file)
    >>= either (dieT . Load.renderLoadError) pure
  when (requiresBuild (service ^. #build))
    (dieT "reviewed deploy requires an already published image")
  unless (isNothing (service ^. #cdn))
    (dieT "reviewed single-Service deploy requires typed CDN ownership")
  let app = Application
        { name = service ^. #name
        , logicalKey = service ^. #logicalKey
        , namespace = service ^. #namespace
        , image = service ^. #image
        , env = Map.empty
        , databases = []
        , brokers = []
        , access = Nothing
        , service = Just service
        , workers = []
        , tasks = []
        }
  (volumeRecovery, workerRecovery) <- either dieT pure
    (applicationVolumeRecoveryBindings app
      (map T.pack (options ^. #serviceVolumeRecovery)) [])
  unless (Map.null workerRecovery)
    (dieT "standalone Service review contains worker recovery bindings")
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  let namespaceName = namespaceText (service ^. #namespace)
  (cluster, namespaceId) <- either dieT pure
    (acceptedFoundationNamespace snapshot namespaceName)
  accessBinding <- traverse (\_ -> either dieT pure
    (acceptedAccessBinding snapshot cluster)) (service ^. #access)
  (brokerServices, brokerTopics, _) <- either dieT pure
    (acceptedBrokerBindings snapshot cluster namespaceName (service ^. #brokers))
  databaseBindings <- reviewedStandaloneDatabases active snapshot cluster namespaceName
    (service ^. #databases)
  let params = AppDeployParams
        { configPath = options ^. #file
        , tag = T.pack <$> options ^. #tag
        , baseDomain = T.pack <$> options ^. #baseDomain
        , contextOverride = Nothing
        , dockerfileOverride = Nothing
        , dryRun = False
        , json = False
        , source = T.pack <$> options ^. #source
        , targetProfile = active ^. #profile
        }
  rollout <- resolveAppRolloutWithBrokerEnv params app Map.empty
  either dieT pure (acceptedApplicationImage snapshot imageId (rollout ^. #taggedAppImage))
  tlsIds <- traverse (either dieT pure . Resource.mkResourceId . T.pack)
    (options ^. #tlsSecretResources)
  envIds <- traverse (either dieT pure . Resource.mkResourceId . T.pack)
    (options ^. #envSecretResources)
  tlsSecrets <- either dieT pure (acceptedSecretBindings snapshot tlsIds)
  envSecrets <- either dieT pure (acceptedSecretBindings snapshot envIds)
  key <- maybe (either dieT pure (Resource.mkLogicalKey (serviceNameText (service ^. #name)))) pure
    (service ^. #logicalKey)
  owner <- either dieT pure (Resource.mkScopeId Resource.Standalone
    ("service-" <> Resource.logicalKeyText key))
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  acceptedInventory <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <- InventoryStatus.loadAcceptedNative store history acceptedInventory
    >>= either dieT pure
  let source = Resource.SourceLocation
        (maybe (T.pack (options ^. #file)) T.pack (options ^. #source))
        (serviceNameText (service ^. #name))
      releaseTag = rollout ^. #effectiveTag
  (priorReleases, release, adoption) <- case
    (options ^. #legacyReleaseImport, options ^. #releaseAdoptionInput) of
    (Nothing, Nothing) -> do
      prior <- either dieT pure
        (acceptedStandaloneReleaseLog snapshot acceptedNative owner service cluster)
      releasedAt <- getCurrentTime
      pure (prior, StaticRelease
        { releaseId = releaseTag
        , siteName = serviceNameText (service ^. #name)
        , namespace = namespaceName
        , image = imageRefText (rollout ^. #qualifiedImage)
        , imageTag = releaseTag
        , url = serviceUrl service (rollout ^. #baseDomain)
        , source = T.pack <$> options ^. #source
        , createdAt = releasedAt
        }, Nothing)
    (Just legacyFile, Just proposalFile) -> do
      legacyBytes <- (try (BS.readFile legacyFile) :: IO (Either IOException ByteString))
        >>= either (dieT . T.pack . show) pure
      (prior, currentRelease) <- either dieT pure
        (legacyStandaloneReleaseImport service releaseTag
          (imageRefText (rollout ^. #qualifiedImage)) legacyBytes)
      proposalBytes <- (try (BS.readFile proposalFile) :: IO (Either IOException ByteString))
        >>= either (dieT . T.pack . show) pure
      proposal <- either dieT pure (InventoryLifecycle.decodeAdoptionInput proposalBytes)
      unless (InventoryLifecycle.adoptionCandidateDirectory proposal == ".")
        (dieT "inline Service import requires candidate '.' in its adoption proposal")
      pure (prior, currentRelease, Just proposal)
    _ -> dieT "legacy release import options are incomplete"
  (scope, native) <- either (dieT . T.pack . show) pure
    (compileStandaloneServiceWithRelease owner service rollout cluster namespaceId imageId
      volumeRecovery tlsSecrets envSecrets brokerServices brokerTopics databaseBindings accessBinding
      priorReleases release source)
  candidate <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  case adoption of
    Nothing -> Inventory.planInventoryCandidateWith
      (inventoryPlanRegistryWithNative active workspace native) active candidate output
    Just proposal -> do
      validateInlineReleaseAdoption scope
        (appConfigMapName (serviceNameText (service ^. #name))) proposal
      Inventory.planInventoryCandidateAdoptionWith
        (inventoryPlanRegistryWithNative active workspace native)
        active candidate proposal output

runDirectDeploy :: Maybe String -> DeployOpts -> IO ()
runDirectDeploy mctx dopts = do
  bd <- resolveBaseDomain mctx (dopts ^. #baseDomain)
  provisionGhcEnv (dopts ^. #ghcEnv)

  edep <- Load.loadDeployment (dopts ^. #file)
  tp <- activeProfile mctx
  dep <- case edep of
    Left err -> dieT (Load.renderLoadError err)
    -- EP-62 M3: a name-only image (no '/') is qualified with the resolved
    -- registry prefix; a fully-qualified ref is left untouched.
    Right d -> do
      refuseDirectServiceMutationIfOwned mctx "deploy" (serviceNameText (d ^. #name))
        (namespaceText (d ^. #namespace))
      refuseDirectAccessOwnerIfManaged mctx "deploy"
      forM_ (d ^. #tasks) $ \task ->
        refuseDirectTaskMutationIfOwned mctx "deploy" (serviceNameText (task ^. #name))
          (namespaceText (d ^. #namespace))
      case qualifyImage tp (d ^. #image) of
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
      withPredef tk = tk & #env %~ mergeGenerated (predefinedTaskEnv tk)
      taskBytes =
        [ renderResolvedTask appImageTagged effTag withPredef tk
        | tk <- dep' ^. #tasks
        ]
      bindingTargets =
        [ BindingTarget
            { host = domainText (domainSpec ^. #domain)
            , namespace = ns
            , service = name
            }
        | domainSpec <- dep' ^. #domains
        ]

  -- EP-36: warn (never fail) for each volume opted out of backups, in both
  -- dry-run and live deploys, so no volume is ever silently unprotected.
  forM_ (backupExcludedWarnings name (dep' ^. #volumes)) (TIO.hPutStrLn stderr)

  if dopts ^. #dryRun
    then do
      printNamespaceAction ns
      -- EP-35: PVCs are created before the Service, so they print first in dry-run.
      forM_ pvcBytes $ \pvc -> do
        BC.putStrLn "--- PersistentVolumeClaim manifest ---"
        BC.putStr pvc
      BC.putStrLn "--- Knative Service manifest ---"
      BC.putStr svcBytes
      forM_ dmBytes $ \dm -> do
        BC.putStrLn "--- DomainMapping manifest ---"
        BC.putStr dm
      forM_ bindingTargets $ \target ->
        TIO.putStrLn ("Would check domain binding: " <> renderBindingTarget target)
      forM_ (dep' ^. #domains) $ \domainSpec ->
        TIO.putStrLn ("Would check domain TLS: " <> renderDomainTlsCheck domainSpec)
      forM_ taskBytes $ \tb -> do
        BC.putStrLn "--- Task CronJob manifest ---"
        BC.putStr tb
      TIO.putStrLn ("Build mode: " <> describeBuild (tp ^. #targetPlatform) spec)
      TIO.putStrLn ("URL: " <> url)
      cdnDeployStep mctx True (dep' ^. #cdn) [domainText (ds ^. #domain) | ds <- dep' ^. #domains] ns name
    else do
      ensureNamespace ApplicationNamespace ns >>= orDie
      if requiresBuild spec
        then do
          -- EP-27: gather the app's Build-scoped env (inline {Build} + the managed
          -- Build store) and pass it to docker build as --build-arg flags. Done only
          -- when actually building (Build-scoped env never reaches the runtime container).
          (bargs, warns) <- gatherBuildArgs name ns (dep ^. #env)
          printBuildArgWarnings warns
          configureDockerAuthFor tp
          performBuild (tp ^. #targetPlatform) (addBuildArgs bargs spec) ref
          pushImage ref
        else TIO.putStrLn "Skipping build/push: deploying prebuilt image."
      -- EP-35: apply the PVCs first (no-op when empty), then the Service. Never a
      -- pre-Service Bound wait (local-path is WaitForFirstConsumer; that deadlocks).
      preflightDomainBindings bindingTargets >>= orDie
      preflightDomainTls tp bd ns (dep' ^. #domains) >>= orDie
      applyPVCs pvcBytes
      applyManifests (svcBytes : dmBytes)
      -- EP-52: provision each co-located task's resolved CronJob in the same
      -- idempotent apply pass. Empty (no declared tasks) applies nothing.
      unless (null taskBytes) $ do
        applyManifests taskBytes
        TIO.putStrLn ("Provisioned " <> tShow (length taskBytes) <> " task(s).")
      waitForReady name ns >>= requireWait ("service '" <> name <> "'")
      waitForDomainBindings 300 bindingTargets >>= orDie
      verifyDomainTlsReady tp bd ns (dep' ^. #domains) >>= orDie
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
      cdnDeployStep mctx False (dep' ^. #cdn) [domainText (ds ^. #domain) | ds <- dep' ^. #domains] ns name

-- | After a live deploy, print one informational line per declared volume
-- reporting its PVC's bound phase (EP-35). A no-op when the app has no volumes,
-- so a stateless deploy's output is byte-identical to before this change. Never
-- fails the deploy: 'pvcPhases' tolerates a missing/Pending PVC.
reportPVCs :: Text -> Deployment -> IO ()
reportPVCs ns dep = do
  let app = serviceNameText (dep ^. #name)
      vols = dep ^. #volumes
      names = [pvcName app (volumeNameText (v ^. #name)) | v <- vols]
  unless (null vols) $ do
    phases <- pvcPhases ns names
    forM_ (zip vols phases) $ \(v, (pn, phase)) ->
      TIO.putStrLn
        ("Volume " <> volumeNameText (v ^. #name) <> ": pvc " <> pn <> " is " <> phase)

-- | Deploy a site (EP-14/EP-15/EP-18). Dispatches on the config's @kind@: a
-- @StaticSite@ runs the Nginx path, a @ServerSite@ runs the Node path. Both share
-- the same CLI options and record a release on success.
runSiteDeploy :: Maybe String -> SiteDeployOpts -> IO ()
runSiteDeploy mctx sopts = do
  bd <- resolveBaseDomain mctx (sopts ^. #baseDomain)
  provisionGhcEnv (sopts ^. #ghcEnv)
  tp <- activeProfile mctx
  esite <- Load.loadSite (sopts ^. #file)
  -- EP-62 M3: qualify a name-only image with the resolved registry prefix; a
  -- fully-qualified ref is left untouched. Inlined per kind because the static
  -- and server site records are distinct types.
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right (Load.SiteStatic s) -> do
      case qualifyImage tp (s ^. #image) of
        Left e -> dieT ("nagarectl deploy: " <> e)
        Right qimg -> case sopts ^. #savePlan of
          Nothing -> do
            when (isJust (sopts ^. #imageResource)
                || isJust (sopts ^. #legacyReleaseImport)
                || isJust (sopts ^. #releaseAdoptionInput))
              (dieT "static-site inventory options require --save-plan")
            refuseDirectServiceMutationIfOwned mctx "site deploy"
              (siteNameText (s ^. #name)) (namespaceText (s ^. #namespace))
            deployStatic mctx tp sopts (s & #image %~ const qimg) bd
          Just output -> runStaticSiteDeployPlan mctx tp sopts
            (s & #image %~ const qimg) bd output
    Right (Load.SiteServer s) -> do
      when (isJust (sopts ^. #savePlan) || isJust (sopts ^. #imageResource)
          || isJust (sopts ^. #legacyReleaseImport)
          || isJust (sopts ^. #releaseAdoptionInput))
        (dieT "reviewed server-site deployment is not yet supported")
      refuseDirectServiceMutationIfOwned mctx "site deploy"
        (siteNameText (s ^. #name)) (namespaceText (s ^. #namespace))
      case qualifyImage tp (s ^. #image) of
        Left e -> dieT ("nagarectl deploy: " <> e)
        Right qimg -> deployServer mctx tp sopts (s & #image %~ const qimg) bd

runStaticSiteDeployPlan
  :: Maybe String -> TargetProfile -> SiteDeployOpts -> StaticSite -> Text -> FilePath -> IO ()
runStaticSiteDeployPlan mctx tp options site bd output = do
  case (options ^. #legacyReleaseImport, options ^. #releaseAdoptionInput) of
    (Nothing, Nothing) -> pure ()
    (Just _, Just _) -> pure ()
    _ -> dieT "static-site import requires both --legacy-release-import and --release-adoption-input"
  when (options ^. #dryRun || not (options ^. #skipBuild))
    (dieT "reviewed static-site deployment requires --skip-build and no --dry-run")
  tag <- maybe (dieT "reviewed static-site deployment requires --tag")
    (pure . T.pack) (options ^. #tag)
  imageId <- maybe (dieT "reviewed static-site deployment requires --image-resource")
    (either dieT pure . Resource.mkResourceId . T.pack) (options ^. #imageResource)
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  let siteName = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
      inputs = siteDeployInputs tp options site tag bd
      rendered = productionManifests inputs
      source = Resource.SourceLocation
        (maybe (T.pack (options ^. #file)) T.pack (options ^. #source)) siteName
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
  either dieT pure (acceptedApplicationImage snapshot imageId
    (imageRefText (site ^. #image) <> ":" <> tag))
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  acceptedInventory <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <- InventoryStatus.loadAcceptedNative store history acceptedInventory
    >>= either dieT pure
  (prior, release, adoption) <- case
    (options ^. #legacyReleaseImport, options ^. #releaseAdoptionInput) of
    (Nothing, Nothing) -> do
      accepted <- either dieT pure
        (acceptedStaticSiteReleaseLog snapshot acceptedNative siteName ns cluster)
      releasedAt <- getCurrentTime
      pure (accepted, StaticRelease
        { releaseId = tag
        , siteName = siteName
        , namespace = ns
        , image = imageRefText (site ^. #image)
        , imageTag = tag
        , url = rendered ^. #url
        , source = T.pack <$> options ^. #source
        , createdAt = releasedAt
        }, Nothing)
    (Just legacyFile, Just proposalFile) -> do
      legacyBytes <- (try (BS.readFile legacyFile) :: IO (Either IOException ByteString))
        >>= either (dieT . T.pack . show) pure
      (oldLog, oldRelease) <- either dieT pure
        (legacyStaticSiteReleaseImport site tag legacyBytes)
      proposalBytes <- (try (BS.readFile proposalFile) :: IO (Either IOException ByteString))
        >>= either (dieT . T.pack . show) pure
      proposal <- either dieT pure (InventoryLifecycle.decodeAdoptionInput proposalBytes)
      unless (InventoryLifecycle.adoptionCandidateDirectory proposal == ".")
        (dieT "inline static-site import requires candidate '.' in its adoption proposal")
      pure (oldLog, oldRelease, Just proposal)
    _ -> dieT "static-site import options are incomplete"
  (scope, native) <- either (dieT . T.pack . show) pure
    (compileStaticSiteScope inputs cluster namespaceId imageId prior release source)
  candidate <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  case adoption of
    Nothing -> Inventory.planInventoryCandidateWith
      (inventoryPlanRegistryWithNative active workspace native) active candidate output
    Just proposal -> do
      validateInlineReleaseAdoption scope ("nagare-static-releases-" <> siteName) proposal
      Inventory.planInventoryCandidateAdoptionWith
        (inventoryPlanRegistryWithNative active workspace native)
        active candidate proposal output

-- | The static (Nginx) deploy path.
--
-- NOTE (EP-26): static sites have no env field and serve files via Nginx, so the
-- generated NAGARE_* runtime variables do not apply here and are intentionally not
-- injected. See docs/plans/26-generated-and-predefined-environment-variables.md.
deployStatic :: Maybe String -> TargetProfile -> SiteDeployOpts -> StaticSite -> Text -> IO ()
deployStatic mctx tp sopts site bd = do
  imageTag <- resolveTag (sopts ^. #tag)
  let inputs = siteDeployInputs tp sopts site imageTag bd
      m = productionManifests inputs
      cdnHosts = siteHostnames (site ^. #domains)
      cdnNs = namespaceText (site ^. #namespace)
      cdnSvc = siteNameText (site ^. #name)
  if sopts ^. #dryRun
    then do
      printNamespaceAction cdnNs
      printStaticArtifacts (m ^. #nginxConf) (m ^. #service) (m ^. #domainMappings) (m ^. #url)
      printBindingChecks (siteBindingTargets (site ^. #domains) cdnNs cdnSvc)
      printTlsChecks (site ^. #domains)
      TIO.putStrLn ("Release: " <> imageTag)
      cdnDeployStep mctx True (site ^. #cdn) cdnHosts cdnNs cdnSvc
    else do
      result <- deployStaticProduction inputs (T.pack <$> sopts ^. #source)
      case result of
        Left err -> dieT err
        Right u -> do
          TIO.putStrLn ("Deployed static site: " <> u)
          cdnDeployStep mctx False (site ^. #cdn) cdnHosts cdnNs cdnSvc

-- | The server (Node) deploy path.
deployServer :: Maybe String -> TargetProfile -> SiteDeployOpts -> ServerSite -> Text -> IO ()
deployServer mctx tp sopts site0 bd = do
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
          , targetProfile = tp
          }
      m = serverManifests inputs
  if sopts ^. #dryRun
    then do
      printNamespaceAction (namespaceText (site ^. #namespace))
      BC.putStrLn "--- Generated Dockerfile ---"
      TIO.putStr (m ^. #dockerfile)
      BC.putStrLn "--- Knative Service manifest ---"
      BC.putStr (m ^. #service)
      forM_ (m ^. #domainMappings) $ \dm -> do
        BC.putStrLn "--- DomainMapping manifest ---"
        BC.putStr dm
      printBindingChecks
        ( siteBindingTargets
            (site ^. #domains)
            (namespaceText (site ^. #namespace))
            (siteNameText (site ^. #name))
        )
      printTlsChecks (site ^. #domains)
      TIO.putStrLn ("URL: " <> (m ^. #url))
      TIO.putStrLn ("Release: " <> imageTag)
      cdnDeployStep mctx True (site ^. #cdn) (siteHostnames (site ^. #domains)) (namespaceText (site ^. #namespace)) (siteNameText (site ^. #name))
    else do
      result <- deployServerProduction inputs (T.pack <$> sopts ^. #source)
      case result of
        Left err -> dieT err
        Right u -> do
          TIO.putStrLn ("Deployed server site: " <> u)
          cdnDeployStep mctx False (site ^. #cdn) (siteHostnames (site ^. #domains)) (namespaceText (site ^. #namespace)) (siteNameText (site ^. #name))

-- | MasterPlan 11 / EP-58: the CDN provisioning step, run as the last step of a
-- deploy (after the origin is Ready) or printed under @--dry-run@. A 'Nothing'
-- CDN is a no-op, so a non-CDN deploy is byte-for-byte unchanged. In the live
-- branch a provisioning failure is reported to stderr and never fails the
-- already-successful origin deploy. The reusable @deploy*Production@ effects and
-- the @nagared@ webhook stay free of CDN/Pulumi coupling — orchestration lives
-- here in the CLI handler, where @--dry-run@ already lives.
cdnDeployStep :: Maybe String -> Bool -> Maybe Cdn -> [Text] -> Text -> Text -> IO ()
cdnDeployStep _ _ Nothing _ _ _ = pure ()
cdnDeployStep mctx dry (Just c) hostnames ns service = do
  (_, workspace) <- ensurePulumiForActiveContext mctx
  originIp <- fromMaybe "<publicIp>" <$> stackOutput (workspace ^. #pulumiDir) "publicIp"
  tp <- activeProfile mctx
  refs <- gatherGcpStackRefs (workspace ^. #pulumiDir) tp
  let target =
        CdnTarget
          { hostnames = hostnames
          , originIp = originIp
          , namespace = ns
          , service = service
          , baseDomain = tp ^. #baseDomain
          }
  if dry
    then either dieT (TIO.putStr . renderCdnPlan) (planCdn c target refs)
    else do
      res <- provisionCdn c target refs
      case res of
        Left e -> TIO.hPutStrLn stderr ("nagarectl: CDN provisioning failed (origin is up): " <> e)
        Right r -> TIO.putStrLn (r ^. #summary)

-- | Read the four EP-56 Google stack outputs, with a clear placeholder when an
-- output is absent (the CDN load balancer is disabled, or Pulumi is unavailable).
gatherGcpStackRefs :: FilePath -> TargetProfile -> IO GcpStackRefs
gatherGcpStackRefs pulumiDir tp = do
  let so name = fromMaybe ("<" <> name <> ">") <$> stackOutput pulumiDir name
  GcpStackRefs
    <$> so "cdnGlobalIp"
    <*> so "cdnBackendService"
    <*> so "cdnUrlMap"
    <*> so "dnsZoneName"
    <*> pure (tp ^. #project)

-- | The custom-domain hostnames of a site (in declaration order) — the hostnames
-- a CDN fronts.
siteHostnames :: [DomainSpec] -> [Text]
siteHostnames = map (domainText . (^. #domain))

siteBindingTargets :: [DomainSpec] -> Text -> Text -> [BindingTarget]
siteBindingTargets domains namespace service =
  [ BindingTarget
      { host = domainText (domainSpec ^. #domain)
      , namespace = namespace
      , service = service
      }
  | domainSpec <- domains
  ]

printBindingChecks :: [BindingTarget] -> IO ()
printBindingChecks =
  mapM_ (TIO.putStrLn . ("Would check domain binding: " <>) . renderBindingTarget)

printTlsChecks :: [DomainSpec] -> IO ()
printTlsChecks =
  mapM_ (TIO.putStrLn . ("Would check domain TLS: " <>) . renderDomainTlsCheck)

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
runSiteRollback :: Maybe String -> SiteCommonOpts -> Text -> IO ()
runSiteRollback mctx copts rid = do
  bd <- resolveBaseDomain mctx (copts ^. #baseDomain)
  tp <- activeProfile mctx
  provisionGhcEnv (copts ^. #ghcEnv)
  esite <- Load.loadSite (copts ^. #file)
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right sc -> do
      let (name, ns) = siteConfigIdentity sc
      refuseDirectServiceMutationIfOwned mctx "site rollback" name ns
      elog <- readReleaseLog name ns
      logv <- case elog of
        Left err -> dieT err
        Right l -> pure l
      case findRelease rid logv of
        Nothing -> dieT ("no such release: " <> rid)
        Just rel -> do
          let (svc, dms) = rollbackManifests tp sc bd (rel ^. #imageTag)
          ensureNamespace ApplicationNamespace ns >>= orDie
          applyManifests (svc : dms)
          waitForReady name ns >>= requireWait ("service '" <> name <> "'")
          writeReleaseLog name ns (logv & #current .~ Just (rel ^. #releaseId))
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
rollbackManifests :: TargetProfile -> Load.SiteConfig -> Text -> Text -> (ByteString, [ByteString])
rollbackManifests tp (Load.SiteStatic s) bd tag =
  let m = productionManifests (DeployInputs s tag bd "." True tp)
   in (m ^. #service, m ^. #domainMappings)
rollbackManifests tp (Load.SiteServer s) bd tag =
  let m = serverManifests (ServerDeployInputs s tag bd "." True tp)
   in (m ^. #service, m ^. #domainMappings)

-- | @site preview deploy --name NAME@: deploy the current build as an isolated
-- preview Service under a derived name and domain. Previews are not recorded in
-- the production release history.
runPreviewDeploy :: Maybe String -> SiteDeployOpts -> Text -> IO ()
runPreviewDeploy mctx sopts pname = do
  when (isJust (sopts ^. #savePlan) || isJust (sopts ^. #imageResource)
      || isJust (sopts ^. #legacyReleaseImport)
      || isJust (sopts ^. #releaseAdoptionInput))
    (dieT "site preview deploy does not support production inventory options")
  bd <- resolveBaseDomain mctx (sopts ^. #baseDomain)
  tp <- activeProfile mctx
  provisionGhcEnv (sopts ^. #ghcEnv)
  site <- loadSiteOrDie (sopts ^. #file)
  imageTag <- resolveTag (sopts ^. #tag)
  let inputs = siteDeployInputs tp sopts site imageTag bd
  m <- orDie (previewManifests inputs pname)
  refuseDirectServiceMutationIfOwned mctx "site preview deploy"
    (m ^. #serviceName) (namespaceText (site ^. #namespace))

  if sopts ^. #dryRun
    then do
      printNamespaceAction (namespaceText (site ^. #namespace))
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
runPreviewDelete :: Maybe String -> SiteCommonOpts -> Text -> IO ()
runPreviewDelete mctx copts pname = do
  bd <- resolveBaseDomain mctx (copts ^. #baseDomain)
  provisionGhcEnv (copts ^. #ghcEnv)
  site <- loadSiteOrDie (copts ^. #file)
  let prodName = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
  svcName <- orDie (previewServiceName prodName pname)
  pdomText <- orDie (previewDomain prodName pname bd)
  refuseDirectServiceMutationIfOwned mctx "site preview delete" svcName ns
  deletePreview ns svcName pdomText
  TIO.putStrLn ("Deleted preview: " <> svcName)

-- ---------------------------------------------------------------------------
-- app lifecycle handlers (EP-30)

-- | A Docker archive is immutable review input: the plan records its file
-- digest and OCI manifest digest, and the artifact transport rechecks both
-- before publishing the exact destination. The archive must remain available
-- at this absolute path for apply or resume.
runAppImagePlan :: Maybe String -> AppImagePlanOpts -> IO ()
runAppImagePlan mctx options = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  let profile = active ^. #profile
      destination = T.pack (options ^. #destination)
      prefix = case profile ^. #mode of
        Local -> profile ^. #registryHost
        Cloud -> registryPrefix profile
      imagePart = T.takeWhileEnd (/= '/') destination
  unless ((prefix <> "/") `T.isPrefixOf` destination
      && T.any (== ':') imagePart && not (T.any (<= ' ') destination)
      && not (T.any (== '@') destination))
    (dieT "image destination must be a tagged image in the active context registry")
  archivePath <- makeAbsolute (options ^. #archive)
  (archiveDigest, manifestDigest) <- inspectArchive archivePath >>= either dieT pure
  logical <- either dieT pure (Resource.mkLogicalKey (T.pack (options ^. #key)))
  owner <- either dieT pure (Resource.mkScopeId Resource.Publication
    ("app-image-" <> Resource.logicalKeyText logical))
  role <- either dieT pure (Resource.mkName "oci-image")
  artifactName <- either dieT pure (Resource.mkName (Resource.logicalKeyText logical))
  let imageId = Resource.mintResourceId owner logical role
      resource = ArtifactResourceSpec
        { artifactLogicalKey = logical
        , artifactRole = role
        , artifactName = artifactName
        , artifactDestination = destination
        , artifactContentDigest = manifestDigest
        , artifactSpecDigest = archiveDigest
        , artifactKind = InventoryArtifact.OciImageArtifact
        , artifactOwnership = InventoryArtifact.OwnedArtifact
        , artifactLifecycle = ResourcePolicy.Retain
        , artifactDataPolicy = ResourcePolicy.Stateless
        , artifactSensitivity = ResourcePolicy.Private
        , artifactDependencies = []
        , artifactConsumers = InventoryArtifact.ConsumerCompletenessUnknown
        , artifactPublishOperation = True
        , artifactSource = Resource.SourceLocation (T.pack archivePath) "oci-archive-v1"
        }
  scope <- either (dieT . T.pack . show) pure (InventoryArtifact.compileArtifactScope
    (ArtifactDeclarationBundle 1 owner (resource NE.:| [])))
  snapshot <- Inventory.loadTargetSnapshot active
  candidate <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  Inventory.planInventoryCandidateWith
    (inventoryPlanRegistryWithNative active workspace Map.empty) active candidate (options ^. #savePlan)
  TIO.putStrLn ("Image resource: " <> Resource.resourceIdText imageId)

-- | Resolve the namespace for an @app@ command: the @-n@ value, or @personal@.
appNamespace :: Maybe String -> Text
appNamespace = maybe "personal" T.pack

-- | @app list@: print a table of apps in a namespace (Nagare-managed unless
-- @--all@). An empty managed list prints a hint to try @--all@.
-- | Convert the executable's option record into the library deploy params
-- (MasterPlan 14, EP-2), so the library never depends on the option type.
runAppDeployPlan :: Maybe String -> AppDeployParams -> AppDeployOpts -> FilePath -> IO ()
runAppDeployPlan mctx params appOptions output = do
  case (appOptions ^. #legacyReleaseImport, appOptions ^. #releaseAdoptionInput) of
    (Nothing, Nothing) -> pure ()
    (Just _, Just _) -> pure ()
    _ -> dieT "legacy release import requires both --legacy-release-import and --release-adoption-input"
  when (appOptions ^. #dryRun || appOptions ^. #json)
    (dieT "--save-plan cannot be combined with --dry-run or --json")
  when (isJust (appOptions ^. #contextOverride) || isJust (appOptions ^. #dockerfileOverride))
    (dieT "reviewed app deploy requires a prepublished image; build overrides are unsupported")
  when (isNothing (appOptions ^. #tag))
    (dieT "reviewed app deploy requires an explicit --tag")
  imageText <- maybe (dieT "--save-plan requires --image-resource") (pure . T.pack)
    (appOptions ^. #imageResource)
  imageId <- either dieT pure (Resource.mkResourceId imageText)
  app <- Load.loadApplication (params ^. #configPath)
    >>= either (dieT . Load.renderLoadError) pure
  let builds = maybe [] (pure . (^. #build)) (app ^. #service)
        <> map (^. #build) (app ^. #workers)
  when (any requiresBuild builds)
    (dieT "reviewed app deploy requires an already published image")
  databaseRecovery <- either dieT pure
    (databaseRecoveryBindings app (map T.pack (appOptions ^. #databaseRecovery)))
  (serviceVolumeRecovery, workerVolumeRecovery) <- either dieT pure
    (applicationVolumeRecoveryBindings app
      (map T.pack (appOptions ^. #serviceVolumeRecovery))
      (map T.pack (appOptions ^. #workerVolumeRecovery)))
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  let appNamespaceName = namespaceText (app ^. #namespace)
  (cluster, namespaceId, namespaceOwner) <-
    if appOptions ^. #requestNamespace
      then do
        (foundationCluster, _) <- either dieT pure
          (acceptedFoundationNamespace snapshot "personal")
        foundation <- either dieT pure (Resource.mkScopeId Resource.Platform "foundation")
        namespaceName <- either dieT pure (Resource.mkName appNamespaceName)
        namespaceKey <- either dieT pure (Resource.mkLogicalKey appNamespaceName)
        case acceptedFoundationNamespace snapshot appNamespaceName of
          Right _ -> dieT "requested namespace is already accepted by the platform foundation"
          Left _ -> pure ()
        let request = ResourceInventory.RegisterNamespace foundation foundationCluster
              namespaceName namespaceKey
        pure (foundationCluster, ResourceInventory.contributionResourceId request, Just foundation)
      else do
        (foundationCluster, acceptedNamespace) <- either dieT pure
          (acceptedFoundationNamespace snapshot appNamespaceName)
        pure (foundationCluster, acceptedNamespace, Nothing)
  let accessPolicy = (app ^. #access) <|> (app ^. #service >>= (^. #access))
  accessBinding <- traverse (\_ -> either dieT pure
    (acceptedAccessBinding snapshot cluster)) accessPolicy
  (appBrokerServices, appBrokerTopics, brokerEnv) <- either dieT pure
    (acceptedBrokerBindings snapshot cluster appNamespaceName (app ^. #brokers))
  workloadBrokers <- either dieT pure (traverse
    (acceptedBrokerBindings snapshot cluster appNamespaceName)
    (maybe [] (pure . (^. #brokers)) (app ^. #service)
      <> map (^. #brokers) (app ^. #workers)))
  let brokerServices = Map.unions (appBrokerServices : [services | (services, _, _) <- workloadBrokers])
      brokerTopics = Map.unionsWith Map.union
        (appBrokerTopics : [topics | (_, topics, _) <- workloadBrokers])
  rollout <- resolveAppRolloutWithBrokerEnv params app brokerEnv
  unless (all (\build -> resolveImageTag build (rollout ^. #imageTag)
      == rollout ^. #effectiveTag) builds)
    (dieT "application workloads resolve to different prepublished image tags")
  either dieT pure (acceptedApplicationImage snapshot imageId (rollout ^. #taggedAppImage))
  either dieT pure (reviewedTaskImages (app ^. #tasks)
    (rollout ^. #taggedAppImage) (rollout ^. #effectiveTag))
  tlsIds <- traverse (either dieT pure . Resource.mkResourceId . T.pack)
    (appOptions ^. #tlsSecretResources)
  envIds <- traverse (either dieT pure . Resource.mkResourceId . T.pack)
    (appOptions ^. #envSecretResources)
  tlsSecrets <- either dieT pure (acceptedSecretBindings snapshot tlsIds)
  envSecrets <- either dieT pure (acceptedSecretBindings snapshot envIds)
  backend <- either dieT pure (storeBackendFor (active ^. #profile)
    (active ^. #profile . #backupBucket))
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  acceptedInventory <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <- InventoryStatus.loadAcceptedNative store history acceptedInventory
    >>= either dieT pure
  let source = Resource.SourceLocation
        (maybe (T.pack (params ^. #configPath)) T.pack (appOptions ^. #source))
        (serviceNameText (app ^. #name))
      releaseTag = rollout ^. #effectiveTag
      releaseSubject = maybe (serviceNameText (app ^. #name))
        (serviceNameText . (^. #name)) (app ^. #service)
  (priorReleases, release, adoption) <- case
    (appOptions ^. #legacyReleaseImport, appOptions ^. #releaseAdoptionInput) of
    (Nothing, Nothing) -> do
      prior <- either dieT pure
        (acceptedApplicationReleaseLog snapshot acceptedNative app cluster)
      releasedAt <- getCurrentTime
      pure (prior, StaticRelease
        { releaseId = releaseTag
        , siteName = releaseSubject
        , namespace = appNamespaceName
        , image = imageRefText (rollout ^. #qualifiedImage)
        , imageTag = releaseTag
        , url = maybe "" (\service -> serviceUrl service (rollout ^. #baseDomain))
            (app ^. #service)
        , source = T.pack <$> appOptions ^. #source
        , createdAt = releasedAt
        }, Nothing)
    (Just legacyFile, Just proposalFile) -> do
      legacyBytes <- (try (BS.readFile legacyFile) :: IO (Either IOException ByteString))
        >>= either (dieT . T.pack . show) pure
      (prior, currentRelease) <- either dieT pure
        (legacyApplicationReleaseImport app releaseTag
          (imageRefText (rollout ^. #qualifiedImage)) legacyBytes)
      proposalBytes <- (try (BS.readFile proposalFile) :: IO (Either IOException ByteString))
        >>= either (dieT . T.pack . show) pure
      proposal <- either dieT pure (InventoryLifecycle.decodeAdoptionInput proposalBytes)
      unless (InventoryLifecycle.adoptionCandidateDirectory proposal == ".")
        (dieT "inline application import requires candidate '.' in its adoption proposal")
      pure (prior, currentRelease, Just proposal)
    _ -> dieT "legacy release import options are incomplete"
  let input = ApplicationScopeInput
        { scopeApplication = app
        , scopeRollout = rollout
        , scopeCluster = cluster
        , scopeNamespace = namespaceId
        , scopeNamespaceContributionOwner = namespaceOwner
        , scopeImage = imageId
        , scopeBrokerServices = brokerServices
        , scopeBrokerTopics = brokerTopics
        , scopeAccessBinding = accessBinding
        , scopeDatabaseRecovery = databaseRecovery
        , scopeServiceVolumeRecovery = serviceVolumeRecovery
        , scopeTlsSecrets = tlsSecrets
        , scopeEnvSecrets = envSecrets
        , scopeWorkerVolumeRecovery = workerVolumeRecovery
        , scopeBackupBackend = backend
        , scopeRelease = (priorReleases, release)
        , scopeSource = source
        }
  (scope, native) <- either (dieT . T.pack . show) pure (compileApplicationScope input)
  candidate <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  case adoption of
    Nothing -> Inventory.planInventoryCandidateWith
      (inventoryPlanRegistryWithNative active workspace native) active candidate output
    Just proposal -> do
      validateInlineReleaseAdoption scope (appConfigMapName releaseSubject) proposal
      Inventory.planInventoryCandidateAdoptionWith
        (inventoryPlanRegistryWithNative active workspace native)
        active candidate proposal output

validateInlineReleaseAdoption
  :: ResourceInventory.ScopeDeclaration -> Text -> InventoryLifecycle.AdoptionInput -> IO ()
validateInlineReleaseAdoption scope releaseName proposal = do
  let releaseMembers = [member | bundle <- ResourceInventory.scopeBundles scope,
        ResourceInventory.Managed member <- ResourceInventory.declarations bundle,
        case member ^. #address of
          Resource.Kubernetes _ "" kind _ name ->
            Resource.nameText kind == "configmap"
              && Resource.nameText name == releaseName
          _ -> False]
      managedIds = Set.fromList
        [member ^. #identity | bundle <- ResourceInventory.scopeBundles scope,
          ResourceInventory.Managed member <- ResourceInventory.declarations bundle]
      proposed = InventoryLifecycle.adoptionTargets proposal
  releaseMember <- case releaseMembers of
    [member] -> pure member
    _ -> dieT "legacy import has no unique release-history declaration"
  unless (all (\target ->
      InventoryLifecycle.adoptionResource target `Set.member` managedIds
        && isNothing (InventoryLifecycle.adoptionPreviousOwner target)) proposed)
    (dieT "legacy release import can adopt only unowned resources in the selected deploy scope")
  unless (any ((== releaseMember ^. #identity) . InventoryLifecycle.adoptionResource) proposed)
    (dieT ("legacy import proposal must adopt the unowned release resource "
      <> Resource.resourceIdText (releaseMember ^. #identity)))

toAppDeployParams :: TargetProfile -> AppDeployOpts -> AppDeployParams
toAppDeployParams tp o =
  AppDeployParams
    { configPath = o ^. #file
    , tag = T.pack <$> o ^. #tag
    , baseDomain = T.pack <$> o ^. #baseDomain
    , contextOverride = o ^. #contextOverride
    , dockerfileOverride = o ^. #dockerfileOverride
    , dryRun = o ^. #dryRun
    , json = o ^. #json
    , source = T.pack <$> o ^. #source
    , targetProfile = tp
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
  TIO.putStrLn ("Name:     " <> s ^. #name)
  TIO.putStrLn ("Ready:    " <> maybe "?" boolText (s ^. #ready))
  TIO.putStrLn ("URL:      " <> fromMaybe "-" (s ^. #url))
  TIO.putStrLn ("Revision: " <> fromMaybe "-" (s ^. #latestRevision))
  TIO.putStrLn ("Image:    " <> fromMaybe "-" (s ^. #image))
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
          { namespace = ns
          , service = name
          , revision = Nothing
          , follow = following
          , tail = if following then Nothing else Just (fromMaybe 200 (o ^. #tailN))
          }
  streamServiceLogs target

-- | @app restart NAME@: roll a fresh revision (also clears the cluster-local
-- label, so a stopped app comes back online), then wait for readiness.
runAppRestart :: Maybe String -> AppNameOpts -> IO ()
runAppRestart mctx o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  refuseDirectServiceMutationIfOwned mctx "app restart" name ns
  stamp <- computeTag
  restartApp ns name stamp
  waitForReady name ns >>= requireWait ("service '" <> name <> "'")
  TIO.putStrLn ("Restarted: " <> name)

-- | @app stop NAME@: take the app offline recoverably.
runAppStop :: Maybe String -> AppNameOpts -> IO ()
runAppStop mctx o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  refuseDirectServiceMutationIfOwned mctx "app stop" name ns
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
runAppDelete :: Maybe String -> AppDeleteOpts -> IO ()
runAppDelete mctx o = do
  let ns = appNamespace (o ^. #namespace)
      name = T.pack (o ^. #nameArg)
  case o ^. #savePlan of
    Nothing -> do
      when (isJust (o ^. #scopeKey)) (dieT "--scope-key requires --save-plan")
      refuseDirectServiceMutationIfOwned mctx "app delete" name ns
      refuseDirectAccessOwnerIfManaged mctx "app delete"
      domains <- resolveDeleteDomains o ns name
      deleteApp ns name domains
      TIO.putStrLn ("Deleted " <> name)
    Just output -> do
      active <- activeTarget mctx
      snapshot <- Inventory.loadTargetSnapshot active
      owner <- either dieT pure (applicationRetirementScope name ns
        (T.pack <$> o ^. #scopeKey) snapshot)
      (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
      Inventory.planInventoryRetirementWith
        (inventoryPlanRegistry active workspace) active owner output

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
          { namespace = ns
          , service = name
          , revision = rev
          , follow = following
          , tail = tailLines
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

-- | Resolve @(name, namespace)@ from a Deployment, aggregate Application,
-- StaticSite, or ServerSite. Each loader identifies its own typed config kind.
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
    Left (Load.UnexpectedKind _ _) -> do
      application <- Load.loadApplication file
      case application of
        Right app -> pure (serviceNameText (app ^. #name), namespaceText (app ^. #namespace))
        Left (Load.UnexpectedKind _ _) -> siteIdentityOrDie file
        Left err -> dieT (Load.renderLoadError err)
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

runStorage :: Maybe String -> StorageCommand -> IO ()
runStorage mctx = \case
  StorageList copts -> resolveStorageDep copts >>= runStorageList
  StorageInspect copts vol -> do
    dep <- resolveStorageDep copts
    runStorageInspect dep (T.pack vol)
  StorageSnapshot copts vol bucket keep -> do
    dep <- resolveStorageDep copts
    refuseDirectVolumeMutationIfOwned mctx "snapshot" dep (T.pack vol)
    backend <- resolveStoreBackend mctx bucket
    runSnapshot dep (T.pack vol) backend keep
  StorageRestore copts vol backupId bucket live dryRun -> do
    dep <- resolveStorageDep copts
    refuseDirectVolumeMutationIfOwned mctx "restore" dep (T.pack vol)
    backend <- resolveStoreBackend mctx bucket
    runStorageRestore dep (T.pack vol) (T.pack backupId) live backend dryRun

-- | Dispatch the @broker@ subcommands (MasterPlan 15, EP-78). The namespace
-- defaults to @personal@.
runBroker :: Maybe String -> BrokerCommand -> IO ()
runBroker mctx = \case
  BrokerList o -> runBrokerList (nsOf (o ^. #namespace))
  BrokerCreate provider name o -> do
    when (isJust (o ^. #config)) (provisionGhcEnv Nothing)
    let params = BrokerCreateParams
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
    case o ^. #savePlan of
      Nothing -> do
        when (any isJust [o ^. #recoveryBackup, o ^. #recoveryKey, o ^. #recoveryKeyVersion])
          (dieT "recovery options require --save-plan")
        runBrokerCreateWithGuard provider (T.pack name) params $ \broker ->
          withAcceptedInventoryHistory mctx "broker create" $ \history ->
            when (brokerNativeOwned broker (ownedHistoryResources history))
              (dieT "broker objects are owned by accepted or retained inventory history; direct create is refused")
      Just output -> do
        when (o ^. #dryRun) (dieT "--dry-run and --save-plan cannot be combined")
        runBrokerCreatePlan mctx provider (T.pack name) params
          (o ^. #recoveryBackup) (o ^. #recoveryKey)
          (o ^. #recoveryKeyVersion) output
  BrokerGet o -> runBrokerGet (nsOf (o ^. #namespace)) (T.pack (o ^. #name))
  BrokerRestart o dryRun -> do
    refuseDirectDataMutationIfOwned mctx "broker" "restart" (T.pack (o ^. #name)) (nsOf (o ^. #namespace))
    runBrokerRestart (nsOf (o ^. #namespace)) (T.pack (o ^. #name)) dryRun
  BrokerDelete o ->
    refuseDirectDataMutationIfOwned mctx "broker" "delete" (T.pack (o ^. #name)) (nsOf (o ^. #namespace)) >>
    runBrokerDelete
      BrokerDeleteParams
        { name = T.pack (o ^. #name)
        , namespace = nsOf (o ^. #namespace)
        , yes = o ^. #yes
        , dryRun = o ^. #dryRun
        }
  BrokerRetire o ->
    runStandaloneRetirePlan mctx "broker" (T.pack (o ^. #name))
      (nsOf (o ^. #namespace)) (T.pack <$> o ^. #scopeKey) (o ^. #savePlan)
  where
    nsOf = maybe "personal" T.pack

runBrokerCreatePlan :: Maybe String -> BrokerProvider -> Text -> BrokerCreateParams
  -> Maybe String -> Maybe String -> Maybe String -> FilePath -> IO ()
runBrokerCreatePlan mctx provider name params backupName keyName keyVersion output = do
  broker <- resolveBroker provider name params
  let brokerName = brokerNameText (broker ^. #name)
      namespaceName = namespaceText (broker ^. #namespace)
      scopeName = maybe brokerName Resource.logicalKeyText (broker ^. #logicalKey)
  unless (brokerName == name && broker ^. #provider == provider)
    (dieT "reviewed broker config must match the command's provider and name")
  owner <- either dieT pure (Resource.mkScopeId Resource.Standalone ("broker-" <> scopeName))
  backup <- maybe (dieT "--save-plan requires --recovery-backup") (either dieT pure . Resource.mkName . T.pack) backupName
  key <- maybe (dieT "--save-plan requires --recovery-key") (either dieT pure . Resource.mkName . T.pack) keyName
  version <- maybe (dieT "--save-plan requires --recovery-key-version") (either dieT pure . Resource.mkName . T.pack) keyVersion
  let recovery = RecoveryIntent backup (mkSecretRef key version NE.:| [])
      source = Resource.SourceLocation
        (maybe "broker create" T.pack (params ^. #config)) brokerName
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot namespaceName)
  (scope, native) <- either (dieT . T.pack . show) pure
    (compileStandaloneBroker broker owner cluster namespaceId recovery source)
  candidate <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  Inventory.planInventoryCandidateWith
    (inventoryPlanRegistryWithNative active workspace native) active candidate output

-- | Dispatch the @db@ subcommands (MasterPlan 9, EP-45). The namespace defaults
-- to @personal@. EP-47 adds @DbBackup@/@DbRestore@ cases here.
runDb :: Maybe String -> DbCommand -> IO ()
runDb mctx = \case
  DbList o -> runDbList (nsOf (o ^. #namespace))
  DbCreate eng name o -> do
    when (isJust (o ^. #config)) (provisionGhcEnv Nothing)
    tp <- activeProfile mctx
    let params = DbCreateParams
          { namespace = nsOf (o ^. #namespace)
          , namespacePurpose = if o ^. #systemNamespace then PlatformNamespace else ApplicationNamespace
          , version = T.pack <$> o ^. #version
          , size = T.pack <$> o ^. #size
          , cpu = T.pack <$> o ^. #cpu
          , memory = T.pack <$> o ^. #memory
          , config = o ^. #config
          , dryRun = o ^. #dryRun
          , targetProfile = tp
          }
    case o ^. #savePlan of
      Nothing -> do
        when (isJust (o ^. #recoveryBackup) || isJust (o ^. #recoveryKeyVersion))
          (dieT "recovery options require --save-plan")
        runDbCreateWithGuard eng (T.pack name) params $ \database ->
          withAcceptedInventoryHistory mctx "database create" $ \history ->
            when (databaseNativeOwned database (ownedHistoryResources history))
              (dieT "database objects are owned by accepted or retained inventory history; direct create is refused")
      Just output -> do
        when (o ^. #dryRun) (dieT "--dry-run and --save-plan cannot be combined")
        runDbCreatePlan mctx eng (T.pack name) params
          (o ^. #recoveryBackup) (o ^. #recoveryKeyVersion) output
  DbGet o -> runDbGet (nsOf (o ^. #namespace)) (T.pack (o ^. #name))
  DbShell o -> do
    refuseDirectDataMutationIfOwned mctx "database" "shell" (T.pack (o ^. #name)) (nsOf (o ^. #namespace))
    runDbShell (nsOf (o ^. #namespace)) (T.pack (o ^. #name))
  DbRestart o dry -> do
    refuseDirectDataMutationIfOwned mctx "database" "restart" (T.pack (o ^. #name)) (nsOf (o ^. #namespace))
    runDbRestart (nsOf (o ^. #namespace)) (T.pack (o ^. #name)) dry
  DbDelete o ->
    refuseDirectDataMutationIfOwned mctx "database" "delete" (T.pack (o ^. #name)) (nsOf (o ^. #namespace)) >>
    runDbDelete
      DbDeleteParams
        { name = T.pack (o ^. #name)
        , namespace = nsOf (o ^. #namespace)
        , yes = o ^. #yes
        , dryRun = o ^. #dryRun
        }
  DbRetire o ->
    runStandaloneRetirePlan mctx "database" (T.pack (o ^. #name))
      (nsOf (o ^. #namespace)) (T.pack <$> o ^. #scopeKey) (o ^. #savePlan)
  DbBackup o -> do
    refuseDirectDataMutationIfOwned mctx "database" "backup" (T.pack (o ^. #name)) (nsOf (o ^. #namespace))
    backend <- resolveStoreBackend mctx (o ^. #bucket)
    runDbBackup (nsOf (o ^. #namespace)) (T.pack (o ^. #name)) backend (o ^. #keep) (o ^. #dryRun)
  DbRestore o -> do
    refuseDirectDataMutationIfOwned mctx "database" "restore" (T.pack (o ^. #name)) (nsOf (o ^. #namespace))
    backend <- resolveStoreBackend mctx (o ^. #bucket)
    runDbRestore (nsOf (o ^. #namespace)) (T.pack (o ^. #name)) (T.pack (o ^. #backupId)) (o ^. #live) backend (o ^. #dryRun)
  where
    nsOf = maybe "personal" T.pack

runDbCreatePlan :: Maybe String -> Engine -> Text -> DbCreateParams
  -> Maybe String -> Maybe String -> FilePath -> IO ()
runDbCreatePlan mctx eng name params backupName keyVersion output = do
  db <- resolveDatabase eng name params
  let databaseName = databaseNameText (db ^. #name)
      namespaceName = namespaceText (db ^. #namespace)
      scopeName = maybe databaseName Resource.logicalKeyText (db ^. #logicalKey)
  unless (databaseName == name && db ^. #engine == eng)
    (dieT "reviewed database config must match the command's engine and name")
  owner <- either dieT pure (Resource.mkScopeId Resource.Standalone ("database-" <> scopeName))
  backup <- maybe (dieT "--save-plan requires --recovery-backup") (either dieT pure . Resource.mkName . T.pack) backupName
  version <- maybe (dieT "--save-plan requires --recovery-key-version") (either dieT pure . Resource.mkName . T.pack) keyVersion
  credential <- either dieT pure (Resource.mkName (dbSecretName databaseName))
  let recovery = RecoveryIntent backup (mkSecretRef credential version NE.:| [])
      source = Resource.SourceLocation
        (maybe "db create" T.pack (params ^. #config)) databaseName
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot namespaceName)
  let direct = DatabaseDirectInput db owner cluster (Just namespaceId) recovery source
  backend <- either dieT pure (storeBackendFor (active ^. #profile) (active ^. #profile . #backupBucket))
  (scope, native) <- either (dieT . T.pack . show) pure (compileStandaloneDatabase direct backend)
  candidate <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  Inventory.planInventoryCandidateWith
    (inventoryPlanRegistryWithNative active workspace native) active candidate output

-- | Select only an accepted standalone data scope whose StatefulSet has the
-- requested native identity. A display name alone must never authorize
-- retirement of a different scope after a logical-key rename.
runStandaloneRetirePlan :: Maybe String -> Text -> Text -> Text
  -> Maybe Text -> FilePath -> IO ()
runStandaloneRetirePlan mctx kind name namespaceName pinnedKey output = do
  active <- activeTarget mctx
  snapshot <- Inventory.loadTargetSnapshot active
  owner <- either dieT pure (standaloneRetirementScope kind name namespaceName pinnedKey snapshot)
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  Inventory.planInventoryRetirementWith
    (inventoryPlanRegistry active workspace) active owner output

-- | The legacy create/delete paths have no inventory receipt. Refuse direct
-- mutation whenever accepted or retained history owns the named StatefulSet.
refuseDirectDataMutationIfOwned :: Maybe String -> Text -> Text -> Text -> Text -> IO ()
refuseDirectDataMutationIfOwned mctx kind operation name namespaceName =
  withAcceptedInventoryHistory mctx (kind <> " " <> operation) $ \history ->
    when (standaloneStatefulSetOwned name namespaceName (ownedHistoryResources history))
      (dieT (kind <> " " <> name <> " is owned by accepted or retained inventory history; direct " <> operation <> " is refused"))

-- | Reuse one read-only, context-bound history check for every legacy command
-- that can mutate a native resource without an inventory receipt.
withAcceptedInventoryHistory :: Maybe String -> Text -> (InventoryPlan.InventoryHistory -> IO ()) -> IO ()
withAcceptedInventoryHistory mctx operation inspect = do
  active <- activeTarget mctx
  opened <- Inventory.openTargetStoreReadOnly active
  case opened of
    Left (InventoryStore.StoreConditionFailed "inventory store is not initialized") -> pure ()
    Left (InventoryStore.StoreConditionFailed "inventory object prefix is not initialized") -> pure ()
    Left err -> dieT ("cannot verify inventory ownership before " <> operation <> ": " <> T.pack (show err))
    Right store -> do
      history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
      context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
      project <- either dieT pure (Resource.mkName (active ^. #profile . #project))
      unless (InventoryStore.headBinding (InventoryPlan.historyHead history) == Resource.ContextBinding context project)
        (dieT "accepted inventory belongs to a different context or project")
      inspect history

ownedHistoryResources :: InventoryPlan.InventoryHistory -> [ResourceInventory.ManagedResource]
ownedHistoryResources history =
  [ resource
  | (_, scope) <- Map.elems (InventoryPlan.historyAccepted history)
  , bundle <- ResourceInventory.scopeBundles scope
  , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
  ] <> map snd (Map.elems (InventoryPlan.historyRetained history))

-- The accepted auth owner composes the entire backend map from contributor
-- scopes. The legacy resolver can rewrite that ConfigMap even when the Service
-- it deploys is otherwise unowned, so it cannot run beside this owner.
authBackendOwned :: InventoryPlan.InventoryHistory -> Bool
authBackendOwned history = accepted || retained
  where
    accepted = or
      [ True
      | (_, scope) <- Map.elems (InventoryPlan.historyAccepted history)
      , bundle <- ResourceInventory.scopeBundles scope
      , ResourceInventory.BackendMapGrant _ <- ResourceInventory.grants bundle
      ]
    retained = or
      [ True
      | (_, resource) <- Map.elems (InventoryPlan.historyRetained history)
      , ResourceInventory.BackendMapSpec _ <- [resource ^. #spec]
      ]

refuseDirectAccessOwnerIfManaged :: Maybe String -> Text -> IO ()
refuseDirectAccessOwnerIfManaged mctx operation =
  withAcceptedInventoryHistory mctx operation $ \history ->
    when (authBackendOwned history)
      (dieT "the shared auth backend map is owned by accepted or retained inventory; direct access routing is refused")

-- | The direct aggregate rollout does not produce a reviewed inventory receipt.
-- Refuse it when either its stable scope or one of its native workloads is
-- already owned, including retained members after retirement.
refuseDirectApplicationDeployIfOwned :: Maybe String -> Application -> IO ()
refuseDirectApplicationDeployIfOwned mctx app =
  withAcceptedInventoryHistory mctx "app deploy" $ \history -> do
    owner <- either dieT pure (ResourceApplication.applicationScopeId app)
    when (isJust (app ^. #service) && authBackendOwned history)
      (dieT "the shared auth backend map is owned by accepted or retained inventory; direct app deploy is refused")
    when (Map.member owner (InventoryPlan.historyAccepted history)
        || applicationNativeOwned app (ownedHistoryResources history))
      (dieT "application is owned by accepted or retained inventory history; direct app deploy is refused")

refuseDirectServiceMutationIfOwned :: Maybe String -> Text -> Text -> Text -> IO ()
refuseDirectServiceMutationIfOwned mctx operation name namespaceName =
  withAcceptedInventoryHistory mctx operation $ \history ->
    when (nativeWorkloadOwned "serving.knative.dev" "service" name namespaceName
        (ownedHistoryResources history)
      || nativeWorkloadOwned "" "configmap" (appConfigMapName name) namespaceName
        (ownedHistoryResources history))
      (dieT ("Service " <> name <> " is owned by accepted or retained inventory history; direct " <> operation <> " is refused"))

refuseDirectWorkerDeployIfOwned :: Maybe String -> Text -> Text -> IO ()
refuseDirectWorkerDeployIfOwned mctx name namespaceName =
  withAcceptedInventoryHistory mctx "worker deploy" $ \history ->
    when (nativeWorkloadOwned "apps" "deployment" name namespaceName
        (ownedHistoryResources history))
      (dieT ("worker " <> name <> " is owned by accepted or retained inventory history; direct deploy is refused"))

refuseDirectTaskMutationIfOwned :: Maybe String -> Text -> Text -> Text -> IO ()
refuseDirectTaskMutationIfOwned mctx operation name namespaceName =
  withAcceptedInventoryHistory mctx ("task " <> operation) $ \history ->
    let resources = ownedHistoryResources history
        cronjob = nativeWorkloadOwned "batch" "cronjob" (taskResourceName name) namespaceName resources
        historyMap = nativeWorkloadOwned "" "configmap" ("nagare-task-runs-" <> name) namespaceName resources
    in when (cronjob || historyMap)
      (dieT ("task " <> name <> " is owned by accepted or retained inventory history; direct " <> operation <> " is refused"))

refuseDirectStoreMutationIfOwned :: Maybe String -> Bool -> Text -> Text -> [EnvScope] -> IO ()
refuseDirectStoreMutationIfOwned mctx secret appName namespaceName scopes =
  withAcceptedInventoryHistory mctx (if secret then "secret write" else "env write") $ \history -> do
    let resources = ownedHistoryResources history
        owned scope =
          let kind = if secret then "secret" else "configmap"
              nativeName = if secret then managedSecretName appName scope
                else managedConfigMapName appName scope
          in nativeWorkloadOwned "" kind nativeName namespaceName resources
    when (any owned scopes)
      (dieT ("environment store for " <> appName
        <> " is owned by accepted or retained inventory history; direct write is refused"))

refuseDirectVolumeMutationIfOwned :: Maybe String -> Text -> Deployment -> Text -> IO ()
refuseDirectVolumeMutationIfOwned mctx operation deployment volumeName =
  withAcceptedInventoryHistory mctx ("storage " <> operation) $ \history -> do
    let appName = serviceNameText (deployment ^. #name)
        namespaceName = namespaceText (deployment ^. #namespace)
        nativeName = pvcName appName volumeName
    when (nativeWorkloadOwned "" "persistentvolumeclaim" nativeName namespaceName
        (ownedHistoryResources history))
      (dieT ("volume " <> volumeName
        <> " is owned by accepted or retained inventory history; direct " <> operation <> " is refused"))

-- | Dispatch the @worker@ command group (EP-71). Provisions the GHC environment
-- before loading the worker's @Config.hs@ (mirroring @db create --config@), then
-- runs the deploy. Cluster I/O and rendering live in 'Nagare.Worker.Deploy'.
runWorker :: Maybe String -> WorkerCommand -> IO ()
runWorker mctx = \case
  WorkerDeploy o -> do
    case o ^. #savePlan of
      Just output -> runWorkerPlan mctx o output
      Nothing -> do
        unless (isNothing (o ^. #imageResource) && null (o ^. #volumeRecovery)
            && null (o ^. #envSecretResources))
          (dieT "inventory resource and recovery options require --save-plan")
        provisionGhcEnv (o ^. #ghcEnv)
        tp <- activeProfile mctx
        runWorkerDeployWithGuard (\worker -> refuseDirectWorkerDeployIfOwned mctx
          (serviceNameText (worker ^. #name)) (namespaceText (worker ^. #namespace)))
          WorkerDeployParams
            { configPath = o ^. #file
            , tag = T.pack <$> o ^. #tag
            , contextOverride = o ^. #contextOverride
            , dockerfileOverride = o ^. #dockerfileOverride
            , dryRun = o ^. #dryRun
            , targetProfile = tp
            }
  WorkerDelete o -> do
    active <- activeTarget mctx
    snapshot <- Inventory.loadTargetSnapshot active
    owner <- either dieT pure (workerRetirementScope (T.pack (o ^. #nameArg))
      (appNamespace (o ^. #namespace)) (T.pack <$> o ^. #scopeKey) snapshot)
    (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
    Inventory.planInventoryRetirementWith
      (inventoryPlanRegistry active workspace) active owner (o ^. #savePlan)

runWorkerPlan :: Maybe String -> WorkerDeployOpts -> FilePath -> IO ()
runWorkerPlan mctx options output = do
  when (options ^. #dryRun || isJust (options ^. #contextOverride)
      || isJust (options ^. #dockerfileOverride))
    (dieT "reviewed worker deploy requires a prepublished image and no build overrides or --dry-run")
  when (isNothing (options ^. #tag))
    (dieT "reviewed worker deploy requires an explicit --tag")
  imageText <- maybe (dieT "--save-plan requires --image-resource") (pure . T.pack)
    (options ^. #imageResource)
  imageId <- either dieT pure (Resource.mkResourceId imageText)
  provisionGhcEnv (options ^. #ghcEnv)
  worker <- Load.loadWorker (options ^. #file)
    >>= either (dieT . Load.renderLoadError) pure
  when (requiresBuild (worker ^. #build))
    (dieT "reviewed worker deploy requires an already published image")
  key <- maybe (either dieT pure (Resource.mkLogicalKey (serviceNameText (worker ^. #name)))) pure
    (worker ^. #logicalKey)
  owner <- either dieT pure (Resource.mkScopeId Resource.Standalone
    ("worker-" <> Resource.logicalKeyText key))
  recovery <- either dieT pure (standaloneWorkerVolumeRecoveryBindings owner worker
    (map T.pack (options ^. #volumeRecovery)))
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <- either dieT pure
    (acceptedFoundationNamespace snapshot (namespaceText (worker ^. #namespace)))
  (brokerServices, brokerTopics, _) <- either dieT pure
    (acceptedBrokerBindings snapshot cluster
      (namespaceText (worker ^. #namespace)) (worker ^. #brokers))
  databaseBindings <- reviewedStandaloneDatabases active snapshot cluster
    (namespaceText (worker ^. #namespace)) (worker ^. #databases)
  let app = Application
        { name = worker ^. #name
        , logicalKey = Nothing
        , namespace = worker ^. #namespace
        , image = worker ^. #image
        , env = Map.empty
        , databases = []
        , brokers = []
        , access = Nothing
        , service = Nothing
        , workers = [worker]
        , tasks = []
        }
      params = AppDeployParams
        { configPath = options ^. #file
        , tag = T.pack <$> options ^. #tag
        , baseDomain = Nothing
        , contextOverride = Nothing
        , dockerfileOverride = Nothing
        , dryRun = False
        , json = False
        , source = Nothing
        , targetProfile = active ^. #profile
        }
  rollout <- resolveAppRolloutWithBrokerEnv params app Map.empty
  either dieT pure (acceptedApplicationImage snapshot imageId (rollout ^. #taggedAppImage))
  envIds <- traverse (either dieT pure . Resource.mkResourceId . T.pack)
    (options ^. #envSecretResources)
  envSecrets <- either dieT pure (acceptedSecretBindings snapshot envIds)
  let source = Resource.SourceLocation (T.pack (options ^. #file))
        (serviceNameText (worker ^. #name))
  (scope, native) <- either (dieT . T.pack . show) pure
    (compileStandaloneWorkerWithDependencies owner worker rollout cluster namespaceId imageId
      recovery envSecrets brokerServices brokerTopics databaseBindings source)
  candidate <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  Inventory.planInventoryCandidateWith
    (inventoryPlanRegistryWithNative active workspace native) active candidate output

runAccess :: Maybe String -> AccessCommand -> IO ()
runAccess mctx = \case
  AccessGrant o ->
    runAccessGrant
      AccessGrantParams
        { enUrl = T.pack <$> o ^. #enUrl
        , enApiKey = T.pack <$> o ^. #enApiKey
        , host = T.pack (o ^. #host)
        , user = T.pack (o ^. #user)
        }
  AccessRevoke o ->
    runAccessRevoke
      AccessGrantParams
        { enUrl = T.pack <$> o ^. #enUrl
        , enApiKey = T.pack <$> o ^. #enApiKey
        , host = T.pack (o ^. #host)
        , user = T.pack (o ^. #user)
        }
  AccessList o ->
    void $
      runAccessList
        AccessListParams
          { enUrl = T.pack <$> o ^. #enUrl
          , enApiKey = T.pack <$> o ^. #enApiKey
          , host = T.pack (o ^. #host)
          }
  AccessPortal PortalShow -> do
    backends <- kubectlAccessOps ^. #loadBackends
    case portalRegistration backends of
      Nothing -> TIO.putStrLn "portal: (none; protected sites use the built-in sign-in pages)"
      Just (portalHost, entry) ->
        TIO.putStrLn ("portal: " <> publicHostText portalHost <> " -> " <> entry ^. #upstream)
  AccessPortal PortalSync -> do
    backends <- kubectlAccessOps ^. #loadBackends
    case portalRegistration backends of
      Nothing -> TIO.putStrLn "no portal registered"
      Just (portalHost, _) -> do
        rawBase <- resolveBaseDomain mctx Nothing
        base <- either dieT pure (mkBaseDomain rawBase)
        (kubectlAccessOps ^. #applyShomeiPortal) (EnablePortal portalHost base)
        TIO.putStrLn ("synchronized portal: " <> publicHostText portalHost)

-- | Dispatch the @task@ command group (MasterPlan 10, EP-51). Mirrors 'runDb'.
-- The @APP@ positional becomes an 'AppScope': @-@ means app-less, anything else is
-- that app; for @task list@ an omitted @APP@ means "any app".
runTask :: Maybe String -> TaskCommand -> IO ()
runTask mctx = \case
  TaskList o -> runTaskList (nsOf (o ^. #namespace)) (scopeOfMaybe (o ^. #app))
  TaskRun o -> do
    refuseDirectTaskMutationIfOwned mctx "run" (T.pack (o ^. #task)) (nsOf (o ^. #namespace))
    runTaskRun
      TaskRunParams
        { app = T.pack (o ^. #app)
        , task = T.pack (o ^. #task)
        , namespace = nsOf (o ^. #namespace)
        , scope = scopeOf (o ^. #app)
        , dryRun = o ^. #dryRun
        }
  TaskLogs o ->
    runTaskLogs
      TaskLogTarget
        { namespace = nsOf (o ^. #namespace)
        , task = T.pack (o ^. #task)
        , scope = scopeOf (o ^. #app)
        , follow = o ^. #follow
        , tail = o ^. #tail
        }
  TaskDelete o -> do
    refuseDirectTaskMutationIfOwned mctx "delete" (T.pack (o ^. #task)) (nsOf (o ^. #namespace))
    runTaskDelete
      TaskDeleteParams
        { name = T.pack (o ^. #task)
        , namespace = nsOf (o ^. #namespace)
        , scope = scopeOf (o ^. #app)
        , yes = o ^. #yes
        , dryRun = o ^. #dryRun
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
resolveBackupBucket :: Maybe String -> Maybe String -> IO Text
resolveBackupBucket _ (Just b) = pure (T.pack b)
resolveBackupBucket mctx Nothing = (^. #backupBucket) <$> activeProfile mctx

-- | Resolve the object-store backend for the four data-movement verbs (EP-84):
-- the cloud GCS backend (project + 'resolveBackupBucket') in cloud mode, the
-- in-cluster MinIO backend (from @NAGARE_LOCAL_OBJECT_STORE@) in local mode. The
-- backend is constructed __once__ here from 'mode' ('storeBackendFor') and
-- threaded into 'runDbBackup'/'runDbRestore'/'runSnapshot'/'runStorageRestore'.
resolveStoreBackend :: Maybe String -> Maybe String -> IO StoreBackend
resolveStoreBackend mctx bucketArg = do
  tp <- activeProfile mctx
  bucket <- resolveBackupBucket mctx bucketArg
  either dieT pure (storeBackendFor tp bucket)

runEnv :: Maybe String -> EnvCommand -> IO ()
runEnv mctx = \case
  EnvList copts allScopes -> do
    (name, ns) <- resolveAppOrDie copts
    let scopes = if allScopes then [minBound .. maxBound] else [Runtime]
    runEnvListBody name ns scopes
  EnvSet copts sel dry key val savePlan -> do
    (name, ns) <- resolveAppOrDie copts
    case savePlan of
      Just output -> saveReviewedEnvChange mctx name ns sel dry "env set"
        (Right . Map.insert (T.pack key) (T.pack val)) output
      Nothing -> do
        refuseDirectStoreMutationIfOwned mctx False name ns (selectedScopes sel)
        forM_ (selectedScopes sel) $ \scope -> do
          existing <- orDie =<< readEnvStore name ns scope
          let desired = reconcile Merge existing (Map.singleton (T.pack key) (T.pack val))
          applyOrDryRunEnv dry name ns scope desired
        unless dry $ TIO.putStrLn ("Set " <> T.pack key <> " in env for " <> name <> ".")
  EnvDelete copts sel dry key savePlan -> do
    (name, ns) <- resolveAppOrDie copts
    case savePlan of
      Just output -> saveReviewedEnvChange mctx name ns sel dry "env delete"
        (\existing -> if Map.member (T.pack key) existing
          then Right (Map.delete (T.pack key) existing)
          else Left "env key is absent from the accepted channel") output
      Nothing -> do
        refuseDirectStoreMutationIfOwned mctx False name ns (selectedScopes sel)
        forM_ (selectedScopes sel) $ \scope -> do
          existing <- orDie =<< readEnvStore name ns scope
          let desired = reconcile ReconcileExact mempty (Map.delete (T.pack key) existing)
          applyOrDryRunEnv dry name ns scope desired
        unless dry $ TIO.putStrLn ("Deleted " <> T.pack key <> " from env for " <> name <> ".")
  EnvSync copts sel dry exact dotenvPath savePlan -> do
    (name, ns) <- resolveAppOrDie copts
    raw <- TIO.readFile dotenvPath
    incoming <- orDie (parseDotenv raw)
    case savePlan of
      Just output -> do
        saveReviewedEnvChange mctx name ns sel dry (T.pack dotenvPath)
          (\existing -> Right (reconcile (if exact then ReconcileExact else Merge)
            existing incoming)) output
      Nothing -> do
        refuseDirectStoreMutationIfOwned mctx False name ns (selectedScopes sel)
        let mode = reconcileModeFrom exact
        forM_ (selectedScopes sel) $ \scope -> do
          existing <- orDie =<< readEnvStore name ns scope
          let desired = reconcile mode existing incoming
          applyOrDryRunEnv dry name ns scope desired
        unless dry $
          TIO.putStrLn ("Synced " <> tShow (Map.size incoming) <> " key(s) into env for " <> name <> ".")

saveReviewedEnvChange :: Maybe String -> Text -> Text -> ScopeSelection -> Bool
  -> Text -> (Map Text Text -> Either Text (Map Text Text)) -> FilePath -> IO ()
saveReviewedEnvChange mctx name ns selection dry sourceName change output = do
  unless (not dry && selectedScopes selection `elem` [[Runtime], [Build], [Preview]])
    (dieT "reviewed env changes require one scope and no --dry-run")
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
  let (compile, channelName) = case selectedScopes selection of
        [Build] -> (compileBuildEnvChannel, "build-env")
        [Preview] -> (compilePreviewEnvChannel, "preview-env")
        _ -> (compileRuntimeEnvChannel, "runtime-env")
      source = Resource.SourceLocation sourceName channelName
  (initial, _) <- either (dieT . T.pack . show) pure
    (compile name ns cluster namespaceId Map.empty source)
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <- InventoryStatus.loadAcceptedNative store history inventory
    >>= either dieT pure
  existing <- either dieT pure (acceptedEnvChannelValues snapshot acceptedNative initial)
  desired <- either dieT pure (change existing)
  (channel, native) <- either (dieT . T.pack . show) pure
    (compile name ns cluster namespaceId desired source)
  candidate <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope channel NE.:| []))
  Inventory.planInventoryCandidateWith
    (inventoryPlanRegistryWithNative active workspace native) active candidate output

runSecret :: Maybe String -> SecretCommand -> IO ()
runSecret mctx = \case
  SecretSet copts sel dry key rawVersion savePlan -> do
    (name, ns) <- resolveAppOrDie copts
    case savePlan of
      Just output -> do
        when dry (dieT "reviewed Secret set cannot use --dry-run")
        version <- maybe (dieT "reviewed Secret set requires --version")
          (either dieT pure . Resource.mkName . T.pack) rawVersion
        val <- readSecretValue
        saveReviewedSecretChange mctx name ns sel "secret set" version
          (Right . Map.insert (T.pack key) val) output
      Nothing -> do
        when (isJust rawVersion) (dieT "--version requires --save-plan")
        refuseDirectStoreMutationIfOwned mctx True name ns (selectedScopes sel)
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
  SecretDelete copts sel dry key rawVersion savePlan -> do
    (name, ns) <- resolveAppOrDie copts
    case savePlan of
      Just output -> do
        when dry (dieT "reviewed Secret delete cannot use --dry-run")
        version <- maybe (dieT "reviewed Secret delete requires --version")
          (either dieT pure . Resource.mkName . T.pack) rawVersion
        saveReviewedSecretChange mctx name ns sel "secret delete" version
          (\existing -> if Map.member (T.pack key) existing
            then Right (Map.delete (T.pack key) existing)
            else Left "Secret key is absent from the accepted channel") output
      Nothing -> do
        when (isJust rawVersion) (dieT "--version requires --save-plan")
        refuseDirectStoreMutationIfOwned mctx True name ns (selectedScopes sel)
        forM_ (selectedScopes sel) $ \scope -> do
          existing <- orDie =<< readSecretStore name ns scope
          let desired = reconcile ReconcileExact mempty (Map.delete (T.pack key) existing)
          applyOrDryRunSecret dry name ns scope desired
        unless dry $ TIO.putStrLn ("Deleted " <> T.pack key <> " from secret for " <> name <> ".")
  SecretSync copts sel dotenvPath rawVersion output -> do
    unless (selectedScopes sel `elem` [[Runtime], [Build], [Preview]])
      (dieT "reviewed Secret sync requires exactly one scope")
    (name, ns) <- resolveAppOrDie copts
    version <- either dieT pure (Resource.mkName (T.pack rawVersion))
    raw <- TIO.readFile dotenvPath
    incoming <- either (const (dieT "invalid secret dotenv file")) pure (parseDotenv raw)
    saveReviewedSecretChange mctx name ns sel (T.pack dotenvPath) version
      (const (Right incoming)) output

saveReviewedSecretChange :: Maybe String -> Text -> Text -> ScopeSelection -> Text
  -> Resource.Name -> (Map Text Text -> Either Text (Map Text Text)) -> FilePath -> IO ()
saveReviewedSecretChange mctx name ns selection sourceName version change output = do
  unless (selectedScopes selection `elem` [[Runtime], [Build], [Preview]])
    (dieT "reviewed Secret changes require exactly one scope")
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
  let (compile, channelName) = case selectedScopes selection of
        [Build] -> (compileBuildSecretChannel, "build-secret")
        [Preview] -> (compilePreviewSecretChannel, "preview-secret")
        _ -> (compileRuntimeSecretChannel, "runtime-secret")
      source = Resource.SourceLocation sourceName channelName
  (initial, _) <- either (dieT . T.pack . show) pure
    (compile name ns cluster namespaceId version Map.empty source)
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <- InventoryStatus.loadAcceptedNative store history inventory
    >>= either dieT pure
  existing <- either dieT pure (acceptedSecretChannelValues snapshot acceptedNative initial)
  desired <- either dieT pure (change existing)
  (channel, native) <- either (dieT . T.pack . show) pure
    (compile name ns cluster namespaceId version desired source)
  either dieT pure (validateSecretRotation snapshot channel)
  candidate <- either (dieT . T.pack . show) pure
    (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope channel NE.:| []))
  Inventory.planInventoryCandidateWith
    (inventoryPlanRegistryWithNative active workspace native) active candidate output

-- | Print the rendered ConfigMap (dry-run) or write the store (otherwise).
applyOrDryRunEnv :: Bool -> Text -> Text -> EnvScope -> Map Text Text -> IO ()
applyOrDryRunEnv dry name ns scope desired
  | dry = do
      BC.putStrLn ("--- ConfigMap (" <> TE.encodeUtf8 (scopeToken scope) <> ") ---")
      BC.putStrLn (renderEnvConfigMap name ns scope desired)
  | otherwise = writeEnvStore name ns scope desired

-- | A public dry-run shows only Secret identity and key names. Reversible
-- base64 values remain private even before the channel has inventory ownership.
applyOrDryRunSecret :: Bool -> Text -> Text -> EnvScope -> Map Text Text -> IO ()
applyOrDryRunSecret dry name ns scope desired
  | dry = do
      BC.putStrLn ("--- Secret (" <> TE.encodeUtf8 (scopeToken scope) <> ") ---")
      BC.putStrLn (renderEnvSecretPreview name ns scope desired)
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
siteDeployInputs :: TargetProfile -> SiteDeployOpts -> StaticSite -> Text -> Text -> DeployInputs
siteDeployInputs tp sopts site imageTag bd =
  DeployInputs
    { site = site
    , imageTag = imageTag
    , baseDomain = bd
    , projectDir = sopts ^. #projectDir
    , skipBuild = sopts ^. #skipBuild
    , targetProfile = tp
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

renderVersionError :: VersionError -> Text
renderVersionError (VersionError message) = message

-- | Resolve the apps base domain: an explicit @--base-domain@ flag wins;
-- otherwise the resolved target profile's base domain (EP-62; honors
-- @NAGARE_BASE_DOMAIN@, default @"apps.example.com"@).
resolveBaseDomain :: Maybe String -> Maybe String -> IO Text
resolveBaseDomain _ (Just bd) = pure (T.pack bd)
resolveBaseDomain mctx Nothing = (^. #baseDomain) <$> activeProfile mctx

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
