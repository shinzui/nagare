-- | EP-177 (ADR 25 amendment): the kind table. One row per resource kind
-- declares what the recovery model must cover for it. Every executor and
-- every Kubernetes kind an adapter admits has a row; a kind outside release
-- line (b) has a documented-limit row naming its exit instead of a world.
module Nagare.Test.World.Kinds
  ( KindAction (..)
  , KindReadiness (..)
  , KindAtomicity (..)
  , KindIdentity (..)
  , KindStatus (..)
  , KindRow (..)
  , kindTable
  , kubernetesKind
  )
where

import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory (Executor (..))

data KindAction
  = KindCreate
  | KindUpdate
  | KindVerify
  | KindRetire
  | KindCollect
  | KindAdopt
  | KindMigrate
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data KindReadiness
  = NoReadiness
  | CanBeUnready
  | -- | Can also end terminally, as a Job does.
    CanFail
  deriving stock (Eq, Show)

data KindAtomicity
  = Atomic
  | -- | An effect of several provider steps, any prefix of which can land.
    Steps !Int
  deriving stock (Eq, Show)

data KindIdentity
  = -- | ADR 27: the UID the provider returned for the reviewed write.
    ProviderUid
  | -- | No provider identity beyond the name (ADR 27 §4 limit).
    NameOnly
  deriving stock (Eq, Show)

data KindStatus
  = InLine
  | -- | Outside release line (b); the reason names its exit.
    DocumentedLimit !Text
  deriving stock (Eq, Show)

data KindRow = KindRow
  { executor :: !Executor
  , kind :: !(Maybe (Text, Text))
  -- ^ The Kubernetes (API group, kind); 'Nothing' for another executor.
  , actions :: ![KindAction]
  , readiness :: !KindReadiness
  , atomicity :: !KindAtomicity
  , identity :: !KindIdentity
  , status :: !KindStatus
  }
  deriving stock (Eq, Generic, Show)

-- | The Kubernetes (group, kind) of a row, when it has one.
kubernetesKind :: KindRow -> Maybe (Text, Text)
kubernetesKind row = case row of
  KindRow {executor = KubernetesExecutor, kind = selected} -> selected
  _ -> Nothing

kindTable :: [KindRow]
kindTable =
  -- Application scopes: Knative Service, worker Deployment, CronJob tasks,
  -- DomainMapping, release history, volumes; databases and their backups.
  [ inLine ("serving.knative.dev", "service") updatable CanBeUnready
  , inLine ("serving.knative.dev", "domainmapping") fixed CanBeUnready
  , inLine ("apps", "deployment") updatable CanBeUnready
  , inLine ("apps", "statefulset") (migratable updatable) CanBeUnready
  , inLine ("batch", "cronjob") (migratable updatable) NoReadiness
  , inLine ("batch", "job") fixed CanFail
  , inLine ("", "configmap") updatable NoReadiness
  , inLine ("", "service") updatable NoReadiness
  , inLine ("", "secret") (migratable updatable) NoReadiness
  , inLine ("", "persistentvolumeclaim") (migratable updatable) NoReadiness
  , inLine ("", "serviceaccount") fixed NoReadiness
  , inLine ("", "namespace") updatable NoReadiness
  , inLine ("", "resourcequota") updatable NoReadiness
  , inLine ("networking.k8s.io", "networkpolicy") updatable NoReadiness
  , inLine ("rbac.authorization.k8s.io", "role") fixed NoReadiness
  , inLine ("rbac.authorization.k8s.io", "rolebinding") fixed NoReadiness
  , -- Platform bootstrap kinds are not in release line (b).
    platform ("apiextensions.k8s.io", "customresourcedefinition") CanBeUnready
  , platform ("cert-manager.io", "certificate") CanBeUnready
  , platform ("cert-manager.io", "clusterissuer") CanBeUnready
  ]
    <> [ KindRow
           { executor = other
           , kind = Nothing
           , actions = [KindCreate, KindUpdate, KindVerify, KindRetire]
           , readiness = NoReadiness
           , atomicity = Atomic
           , identity = NameOnly
           , status = DocumentedLimit "no world in release line (b); an unprovable operation ends by attested close (ADR 26 §5)"
           }
       | other <- [minBound .. maxBound]
       , other /= KubernetesExecutor
       ]
  where
    -- Collection is admitted per kind by the adapter; the totality test
    -- checks each row's claim against its list.
    fixed = [KindCreate, KindVerify, KindRetire, KindAdopt]
    updatable = KindUpdate : fixed
    migratable = (KindMigrate :)
    inLine selected admitted ready =
      KindRow
        { executor = KubernetesExecutor
        , kind = Just selected
        , actions = admitted <> [KindCollect | selected `elem` collectable]
        , readiness = ready
        , atomicity = Atomic
        , identity = ProviderUid
        , status = InLine
        }
    platform selected ready =
      (inLine selected fixed ready)
        { status = DocumentedLimit "platform bootstrap kind outside release line (b); an unprovable operation ends by attested close (ADR 26 §5)"
        }
    collectable =
      [ ("", "configmap")
      , ("", "service")
      , ("", "persistentvolumeclaim")
      , ("", "serviceaccount")
      , ("apps", "statefulset")
      , ("rbac.authorization.k8s.io", "role")
      , ("rbac.authorization.k8s.io", "rolebinding")
      , ("batch", "cronjob")
      , ("batch", "job")
      , ("serving.knative.dev", "service")
      ]
