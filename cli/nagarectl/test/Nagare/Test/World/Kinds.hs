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
  , KindSemantics (..)
  , GenerationRule (..)
  , ReadinessModel (..)
  , ChurnSource (..)
  , DeletionRule (..)
  , kindTable
  , kindFixture
  , kubernetesKind
  )
where

import Data.Aeson (Key, Value, object, (.=))
import Nagare.Dsl.Prelude hiding ((.=))
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
  , semantics :: !(Maybe KindSemantics)
  -- ^ EP-182: how the API server treats this kind, as RES-4 validated it
  -- against a real cluster; 'Nothing' for a documented limit.
  }
  deriving stock (Eq, Generic, Show)

-- | EP-182: a kind's validated API semantics (RES-4 §2). The kind-semantics
-- test checks every in-line row against the recorded traces in
-- @test/fixtures/kubernetes-semantics/traces.json@, and the recovery model's
-- world behaves as these say.
data KindSemantics = KindSemantics
  { generationRule :: !GenerationRule
  , tracksObservedGeneration :: !Bool
  -- ^ Whether the controller reports @status.observedGeneration@.
  , hasStatusSubresource :: !Bool
  , readinessModel :: !ReadinessModel
  , churnSource :: !ChurnSource
  -- ^ What moves the object's resourceVersion when nobody writes it.
  , deletionRule :: !DeletionRule
  }
  deriving stock (Eq, Generic, Show)

-- | When @metadata.generation@ moves.
data GenerationRule
  = -- | The kind has no generation.
    NoGeneration
  | -- | On spec writes only.
    SpecOnly
  | -- | On spec writes and on metadata annotation writes (a Deployment).
    SpecAndAnnotations
  deriving stock (Eq, Show)

-- | How the kind reports readiness.
data ReadinessModel
  = NoReadinessModel
  | -- | @Ready@ at @observedGeneration == generation@; a stale @Ready=True@
    -- survives a spec write until the controller observes it.
    KnativeConditions
  | -- | The rollout rule; @Available@ stays True from the old ReplicaSet
    -- during a broken update.
    DeploymentRollout
  | -- | The rollout rule over replica counters; a pod that is not Ready
    -- blocks every later template change (OrderedReady).
    StatefulSetRollout
  | -- | @Complete@, or terminally @Failed@ after @FailureTarget@.
    JobTerminal
  deriving stock (Eq, Show)

-- | What writes the object's status, and so moves its resourceVersion, at
-- steady state.
data ChurnSource
  = NoChurn
  | -- | Every schedule tick of an unsuspended schedule.
    ScheduleTicks
  | -- | Every pod created or deleted in the namespace.
    PodChanges
  deriving stock (Eq, Show)

-- | What a DELETE leaves behind.
data DeletionRule
  = -- | Gone at once (an @Orphan@ delete holds its finalizer only briefly).
    Immediate
  | -- | Terminating while a pod uses it (@kubernetes.io/pvc-protection@).
    HeldWhileInUse
  | -- | An @Orphan@ delete never completes; a @Background@ one does.
    OrphanBlocked
  | -- | Terminating until its contents are gone (a Namespace).
    HeldUntilEmpty
  deriving stock (Eq, Show)

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
           , semantics = Nothing
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
        , semantics = lookup selected validatedSemantics
        }
    platform selected ready =
      (inLine selected fixed ready)
        { status = DocumentedLimit "platform bootstrap kind outside release line (b); an unprovable operation ends by attested close (ADR 26 §5)"
        , semantics = Nothing
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

-- | RES-4 §2, per in-line kind: generation rule, observedGeneration, status
-- subresource, readiness model, steady-state churn and deletion.
validatedSemantics :: [((Text, Text), KindSemantics)]
validatedSemantics =
  [ (("serving.knative.dev", "service"), KindSemantics SpecOnly True True KnativeConditions NoChurn OrphanBlocked)
  , (("serving.knative.dev", "domainmapping"), KindSemantics SpecOnly True True KnativeConditions NoChurn Immediate)
  , (("apps", "deployment"), KindSemantics SpecAndAnnotations True True DeploymentRollout NoChurn Immediate)
  , (("apps", "statefulset"), KindSemantics SpecOnly True True StatefulSetRollout NoChurn Immediate)
  , (("batch", "cronjob"), KindSemantics SpecOnly False True NoReadinessModel ScheduleTicks Immediate)
  , (("batch", "job"), KindSemantics SpecOnly False True JobTerminal NoChurn Immediate)
  , (("", "configmap"), plain False)
  , (("", "service"), plain True)
  , (("", "secret"), plain False)
  , (("", "persistentvolumeclaim"), (plain True) {deletionRule = HeldWhileInUse})
  , (("", "serviceaccount"), plain False)
  , (("", "namespace"), (plain True) {deletionRule = HeldUntilEmpty})
  , (("", "resourcequota"), (plain True) {churnSource = PodChanges})
  , (("networking.k8s.io", "networkpolicy"), (plain False) {generationRule = SpecOnly})
  , (("rbac.authorization.k8s.io", "role"), plain False)
  , (("rbac.authorization.k8s.io", "rolebinding"), plain False)
  ]
  where
    plain statusSubresource = KindSemantics NoGeneration False statusSubresource NoReadinessModel NoChurn Immediate

-- | A minimal valid manifest of a row's Kubernetes kind for the generated
-- model scenarios: what the API server accepts, so the production runtime's
-- per-kind write paths run as they would (EP-182). The release annotation
-- changes with each review, so a second review is an update of the same
-- object.
kindFixture :: KindRow -> Maybe (Text -> Value)
kindFixture row = case kubernetesKind row of
  Nothing -> Nothing
  Just (group, lowered) -> do
    (version, kindName, namespaced, body) <- lookup (group, lowered) manifests
    pure $ \release ->
      object $
        [ "apiVersion" .= (if group == "" then version else group <> "/" <> version)
        , "kind" .= kindName
        , "metadata"
            .= object
              ( ["name" .= ("model-extra" :: Text), "annotations" .= object ["model.nagare.dev/release" .= release]]
                  <> ["namespace" .= ("personal" :: Text) | namespaced]
              )
        ]
          <> body release
  where
    -- A workload's release is its image, as a deploy's is, so a second
    -- review rolls out a new revision.
    container release = object ["name" .= ("c" :: Text), "image" .= ("registry.example/extra:" <> release)]
    labels = object ["app" .= ("model-extra" :: Text)]
    podTemplate release = object ["metadata" .= object ["labels" .= labels], "spec" .= object ["containers" .= [container release]]]
    jobTemplate release = object ["spec" .= object ["restartPolicy" .= ("Never" :: Text), "containers" .= [container release]]]
    manifests :: [((Text, Text), (Text, Text, Bool, Text -> [(Key, Value)]))]
    manifests =
      [ (("serving.knative.dev", "service"), ("v1", "Service", True, \release -> ["spec" .= object ["template" .= object ["spec" .= object ["containers" .= [object ["image" .= ("registry.example/extra:" <> release)]]]]]]))
      , (("serving.knative.dev", "domainmapping"), ("v1beta1", "DomainMapping", True, const ["spec" .= object ["ref" .= object ["name" .= ("web" :: Text), "kind" .= ("Service" :: Text), "apiVersion" .= ("serving.knative.dev/v1" :: Text)]]]))
      , (("apps", "deployment"), ("v1", "Deployment", True, \release -> ["spec" .= object ["replicas" .= (1 :: Int), "selector" .= object ["matchLabels" .= labels], "template" .= podTemplate release]]))
      , (("apps", "statefulset"), ("v1", "StatefulSet", True, \release -> ["spec" .= object ["replicas" .= (1 :: Int), "serviceName" .= ("model-extra" :: Text), "selector" .= object ["matchLabels" .= labels], "template" .= podTemplate release]]))
      , (("batch", "cronjob"), ("v1", "CronJob", True, \release -> ["spec" .= object ["schedule" .= ("0 0 1 1 *" :: Text), "jobTemplate" .= object ["spec" .= object ["template" .= jobTemplate release]]]]))
      , (("batch", "job"), ("v1", "Job", True, \release -> ["spec" .= object ["template" .= jobTemplate release]]))
      , (("", "configmap"), ("v1", "ConfigMap", True, const ["data" .= object ["k" .= ("v" :: Text)]]))
      , (("", "service"), ("v1", "Service", True, const ["spec" .= object ["selector" .= labels, "ports" .= [object ["port" .= (80 :: Int), "targetPort" .= (8080 :: Int)]]]]))
      , (("", "secret"), ("v1", "Secret", True, const []))
      , (("", "persistentvolumeclaim"), ("v1", "PersistentVolumeClaim", True, const ["spec" .= object ["accessModes" .= ["ReadWriteOnce" :: Text], "resources" .= object ["requests" .= object ["storage" .= ("1Gi" :: Text)]]]]))
      , (("", "serviceaccount"), ("v1", "ServiceAccount", True, const []))
      , (("", "namespace"), ("v1", "Namespace", False, const []))
      , (("", "resourcequota"), ("v1", "ResourceQuota", True, const ["spec" .= object ["hard" .= object ["pods" .= ("10" :: Text)]]]))
      , (("networking.k8s.io", "networkpolicy"), ("v1", "NetworkPolicy", True, const ["spec" .= object ["podSelector" .= object [], "policyTypes" .= ["Ingress" :: Text]]]))
      , (("rbac.authorization.k8s.io", "role"), ("v1", "Role", True, const ["rules" .= [object ["apiGroups" .= ["" :: Text], "resources" .= ["configmaps" :: Text], "verbs" .= ["get" :: Text]]]]))
      , (("rbac.authorization.k8s.io", "rolebinding"), ("v1", "RoleBinding", True, const ["roleRef" .= object ["apiGroup" .= ("rbac.authorization.k8s.io" :: Text), "kind" .= ("Role" :: Text), "name" .= ("model-extra" :: Text)], "subjects" .= [object ["kind" .= ("ServiceAccount" :: Text), "name" .= ("default" :: Text), "namespace" .= ("personal" :: Text)]]]))
      ]
