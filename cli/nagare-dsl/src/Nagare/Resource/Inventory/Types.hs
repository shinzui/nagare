-- | The data types of the typed inventory (ADR 22): executors, the closed
-- 'DesiredSpec', declarations, operations, contributions and bundles.
-- Re-exported by "Nagare.Resource.Inventory", which holds their validation
-- and composition.
module Nagare.Resource.Inventory.Types
  ( Executor (..)
  , DesiredSpec (..)
  , CloudflareCacheIntent (..)
  , CloudflareTlsMode (..)
  , validDnsIpv4
  , ManagedResource (..)
  , Declaration (..)
  , ClaimKind (..)
  , declarationId
  , declarationSource
  , declarationDependencies
  , DeclaredOperation (..)
  , OperationKind (..)
  , OperationInput (..)
  , BackendRole (..)
  , Contribution (..)
  , ContributionGrant (..)
  , ResourceBundle (..)
  )
where

import Data.Char (isDigit)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified
import Nagare.Dsl.AppDatabase (MonitoringRole, UserAccess)
import Nagare.Dsl.Prelude
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types

data Executor = KubernetesExecutor | PulumiExecutor | CloudFoundationExecutor | HostExecutor | ArtifactExecutor | CacheExecutor | BrokerExecutor | HelmExecutor | CdnExecutor | AccessExecutor | AppDatabaseExecutor
  deriving stock (Eq, Ord, Show, Generic, Enum, Bounded)

-- | Closed, versioned alternatives. Native bytes are referenced by content identity.
-- Controller reservations are derived here, never supplied by an executor at apply.
data DesiredSpec
  = NativeObject !ContentDigest
  | KnativeService !ContentDigest
  | Certificate !Name !ContentDigest
  | StatefulSet !Integer ![Name] !ContentDigest
  | HelmRelease !(NonEmpty ProviderAddress) !ContentDigest
  | ArtifactPublication !Name !Text !ContentDigest !Bool
  | NamespaceSpec !(Maybe ContentDigest)
  | BackendMapSpec ![(Name, Text, BackendRole)]
  | ShomeiSettingsSpec !Name !(Maybe Name)
  | AccessGrantSpec !Text !Bool
  | LogicalCache !ContentDigest
  | LogicalBrokerTopic !Int !Int !(Maybe Int)
  | -- | A logical database inside a server: the engine token, its owning
    -- migration user, its runtime user, whether its declared access is on
    -- (retirement turns it off and keeps the data), the digest of the grant
    -- set declared on it, and the monitoring roles whose grants on its objects
    -- are expected (EP-204). Registration creates the empty database only.
    LogicalDatabase !Text !Name !Name !Bool !ContentDigest ![MonitoringRole]
  | -- | A login user inside a server: the engine token, the role token
    -- (@runtime@ or @migration@), whether it may log in, the digest of its
    -- declared attributes and server-wide grants, and its reviewed grant
    -- exceptions and limits (EP-204). The password lives only in its
    -- credential Secret.
    DatabaseUserSpec !Text !Text !Bool !ContentDigest !UserAccess
  | DnsARecord !Text !Int
  | CloudflareRulesSpec ![CloudflareCacheIntent]
  | CloudflareZoneTlsSpec !CloudflareTlsMode
  | CloudflareProxiedARecord !Text
  | CloudflareDnsOnlyARecord !Text
  deriving stock (Eq, Ord, Show, Generic)

data CloudflareCacheIntent = CloudflareCacheIntent
  { cacheHost :: !Name
  , cacheDefaultTtl :: !(Maybe Int)
  , cacheStaticAssets :: !Bool
  , cachePaths :: ![(Text, Maybe Int)]
  }
  deriving stock (Eq, Ord, Show, Generic)

data CloudflareTlsMode = CloudflareFlexible | CloudflareFull | CloudflareFullStrict
  deriving stock (Eq, Ord, Show, Generic)

validDnsIpv4 :: Text -> Bool
validDnsIpv4 address = case Data.Text.splitOn "." address of
  [firstOctet, secondOctet, thirdOctet, fourthOctet] ->
    all validOctet [firstOctet, secondOctet, thirdOctet, fourthOctet]
  _ -> False
  where
    validOctet value =
      not (Data.Text.null value)
        && Data.Text.length value <= 3
        && (Data.Text.length value == 1 || Data.Text.head value /= '0')
        && Data.Text.all isDigit value
        && case (reads (Data.Text.unpack value) :: [(Int, String)]) of
          [(number, "")] -> number <= 255
          _ -> False

data ManagedResource = ManagedResource
  { identity :: !ResourceId
  , owner :: !ScopeId
  , executor :: !Executor
  , address :: !ProviderAddress
  , aliases :: ![ProviderAddress]
  , spec :: !DesiredSpec
  , lifecycle :: !LifecyclePolicy
  , dataPolicy :: !DataPolicy
  , sensitivity :: !Sensitivity
  , dependencies :: ![Dependency]
  , delegations :: ![Delegation]
  , source :: !SourceLocation
  }
  deriving stock (Eq, Ord, Show, Generic)

data Declaration
  = Managed !ManagedResource
  | External !ResourceId !ProviderAddress ![Dependency] !SourceLocation
  | ObservedChild !ResourceId !ResourceId !ProviderAddress !PhysicalIdentity !SourceLocation
  deriving stock (Eq, Ord, Show, Generic)

data ClaimKind = DirectClaim | AliasClaim | DerivedReservation deriving stock (Eq, Ord, Show, Generic)

declarationId :: Declaration -> ResourceId
declarationId (Managed r) = r ^. #identity
declarationId (External r _ _ _) = r
declarationId (ObservedChild r _ _ _ _) = r

declarationSource :: Declaration -> SourceLocation
declarationSource (Managed r) = r ^. #source
declarationSource (External _ _ _ s) = s
declarationSource (ObservedChild _ _ _ _ s) = s

declarationDependencies :: Declaration -> [Dependency]
declarationDependencies (Managed r) = r ^. #dependencies
declarationDependencies (External _ _ ds _) = ds
declarationDependencies (ObservedChild _ p _ _ _) = [OrderedAfter p]

data OperationInput = CapabilityInput !SomeRef | SecretInput !SecretRef | ContentInput !ContentDigest | CdnPathsInput ![Text] | HostImageInput !Text
  deriving stock (Eq, Ord, Show, Generic)

data OperationKind = SchemaMigration | PreDeployHook | CreateLogicalCache | SnapshotData | RestoreData | RestoreLiveData | PruneData | MaintainData | PublishRelease | ActivateHost | PurgeCdnCache | PurgeCdnZone | StartVm | StopVm | PruneHostImage | RotateCredential
  deriving stock (Eq, Ord, Show, Generic)

data DeclaredOperation = DeclaredOperation
  { identity :: !ResourceId
  , affects :: !(NonEmpty ResourceId)
  , inputs :: ![OperationInput]
  , recovery :: !RecoveryClass
  , operationKind :: !OperationKind
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | 'ApiBackend': a protected host whose @/v1@ paths the gateway answers as an API (EP-198).
data BackendRole = ProtectedBackend | PortalBackend | ApiBackend
  deriving stock (Eq, Ord, Show, Generic)

data Contribution
  = RegisterNamespace
      {owner :: !ScopeId, cluster :: !ResourceId, namespace :: !Name, key :: !LogicalKey}
  | RegisterBackend
      { owner :: !ScopeId
      , cluster :: !ResourceId
      , host :: !Name
      , upstream :: !Text
      , role :: !BackendRole
      , key :: !LogicalKey
      }
  | RegisterCloudflareCache
      { owner :: !ScopeId
      , zone :: !Name
      , cacheIntent :: !CloudflareCacheIntent
      , route :: !ResourceId
      }
  deriving stock (Eq, Ord, Show, Generic)

data ContributionGrant = NamespaceGrant !ScopeId !ResourceId | BackendMapGrant !ResourceId | ShomeiSettingsGrant !ResourceId !Name | CloudflareZoneGrant !Name !CloudflareTlsMode
  deriving stock (Eq, Ord, Show, Generic)

data ResourceBundle = ResourceBundle
  { declarations :: ![Declaration]
  , exports :: ![SomeExport]
  , conditions :: ![SomeRef]
  , contributions :: ![Contribution]
  , operations :: ![DeclaredOperation]
  , grants :: ![ContributionGrant]
  }
  deriving stock (Eq, Ord, Show, Generic)
