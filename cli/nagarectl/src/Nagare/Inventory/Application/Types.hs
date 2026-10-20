-- | Types responsibilities; internal implementation behind Nagare.Inventory.Application.
module Nagare.Inventory.Application.Types
  ( AccessBinding (..)
  , ApplicationScopeInput (..)
  , CloudflareCdnBinding (..)
  , AppDatabaseBound (..)
  , DatabaseBinding (..)
  , ServerBinding (..)
  , GoogleCdnBinding (..)
  , ReviewedCdnBinding (..)
  )
where

import Data.Map.Strict (Map)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.App.Deploy (RolloutEnv)
import Nagare.Cdn.Provision (GcpStackRefs)
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.Dsl.Application (Application)
import Nagare.Dsl.Broker (BrokerName, TopicName)
import Nagare.Dsl.Database (Engine)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (DatabaseName, SecretName, VolumeName)
import Nagare.Inventory.Database (DatabaseBackupTarget)
import Nagare.Resource.Inventory (Declaration, ManagedResource)
import Nagare.Resource.Policy (RecoveryIntent)
import Nagare.Resource.Types
  ( Name
  , ResourceId
  , ScopeId
  , SourceLocation
  )
import Nagare.Static.Release (StaticRelease, StaticReleaseLog)

data AccessBinding = AccessBinding
  { accessOwner :: !ScopeId
  , accessEnforcer :: !Declaration
  , accessBaseDomain :: !Name
  }
  deriving stock (Eq, Show)

-- | A database connection is authorized by accepted scope history and an
-- original private credential template: a server bound directly, or an app
-- database on a shared server (EP-202). Keep the witnesses opaque so a caller
-- cannot substitute an engine or a Secret with the same display name.
data DatabaseBinding
  = ServerDatabaseBinding !ServerBinding
  | AppDatabaseBinding !AppDatabaseBound
  deriving stock (Eq, Show)

-- | A server bound directly: its administrator Secret is the workload's.
data ServerBinding = ServerBinding
  { boundService :: !ManagedResource
  , boundStatefulSet :: !ManagedResource
  , boundCredential :: !ManagedResource
  , boundEngine :: !Engine
  }
  deriving stock (Eq, Show)

-- | An app database: the server Service gives the host, the runtime
-- credential (or a reader's, EP-206) is the only Secret the workload
-- receives, and its users and databases order the workload after their
-- provisioning.
data AppDatabaseBound = AppDatabaseBound
  { appService :: !ManagedResource
  , appRuntimeCredential :: !ManagedResource
  , appMembers :: ![ManagedResource]
  , appEngine :: !Engine
  , appCredentialName :: !Text
  -- ^ @\<appdb\>-runtime@, or @\<appdb\>-reader-\<name\>@
  }
  deriving stock (Eq, Show)

-- | The reviewed dependencies and recovery decisions supplied by the command
-- service. A caller must bind the namespace and image publication to accepted
-- identities before producing an application scope.
data GoogleCdnBinding = GoogleCdnBinding
  { googleCdnRefs :: !GcpStackRefs
  , googleCdnBackend :: !Declaration
  }
  deriving stock (Eq, Show)

data CloudflareCdnBinding = CloudflareCdnBinding
  { cloudflareCdnZone :: !Name
  , cloudflareCdnOwner :: !ScopeId
  , cloudflareCdnOriginIp :: !T.Text
  }
  deriving stock (Eq, Show)

data ReviewedCdnBinding
  = GoogleCdnBindingFor !GoogleCdnBinding
  | CloudflareCdnBindingFor !CloudflareCdnBinding
  deriving stock (Eq, Show)

data ApplicationScopeInput = ApplicationScopeInput
  { scopeApplication :: !Application
  , scopeRollout :: !RolloutEnv
  , scopeCluster :: !ResourceId
  , scopeNamespace :: !ResourceId
  -- ^ Exact Namespace identity used by workload dependencies.
  , scopeNamespaceContributionOwner :: !(Maybe ScopeId)
  -- ^ When present, request this owner to compose the namespace. Composition
  -- still requires that owner's explicit grant to the application scope.
  , scopeImage :: !ResourceId
  , scopeBrokerServices :: !(Map BrokerName Declaration)
  , scopeBrokerTopics :: !(Map BrokerName (Map TopicName Declaration))
  , scopeAccessBinding :: !(Maybe AccessBinding)
  , scopeCdnBinding :: !(Maybe ReviewedCdnBinding)
  , scopeDatabaseRecovery :: !(Map DatabaseName RecoveryIntent)
  , scopeServiceVolumeRecovery :: !(Map VolumeName RecoveryIntent)
  , scopeTlsSecrets :: !(Map SecretName Declaration)
  , scopeEnvSecrets :: !(Map SecretName Declaration)
  , scopeBuildSecrets :: !(Set.Set SecretName)
  -- ^ Build-only references proved by the accepted image publication inputs.
  , scopeWorkerVolumeRecovery :: !(Map ResourceId RecoveryIntent)
  , scopeDatabaseBackup :: !DatabaseBackupTarget
  -- ^ Backup store and recovery-point objective of the active context.
  , scopeRelease :: !(StaticReleaseLog, StaticRelease)
  -- ^ Accepted prior log and the release this rollout records. The command
  -- service must source the prior log from immutable accepted native evidence.
  , scopeHookEffects :: !(Map T.Text [ResourceId])
  -- ^ An entry is required for every pre-deploy hook. An empty list is an
  -- explicit assertion that the hook has no data effects.
  , scopeInputOverrides :: !(Map T.Text T.Text)
  -- ^ Explicit public command choices retained with the config digest.
  , scopeSource :: !SourceLocation
  }
