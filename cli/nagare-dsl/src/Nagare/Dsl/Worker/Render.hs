-- | Render a 'Worker' to its Kubernetes manifest set (EP-71): one @apps/v1@
-- 'Deployment' (the Kubernetes primitive — /not/ a Knative Service and /not/
-- nagare's request-driven 'Nagare.Dsl.Types.Deployment'), plus one
-- PersistentVolumeClaim per declared volume. A worker renders no Service,
-- Ingress, DomainMapping, or @autoscaling.knative.dev/*@ annotation: it is not
-- request-driven and not reachable from outside.
--
-- This module is modelled almost verbatim on "Nagare.Dsl.Database.Render"
-- (which renders a 'StatefulSet'): a Deployment has the same
-- @spec.selector@ / @spec.template.spec.containers@ shape, plus @spec.replicas@
-- and /no/ @spec.serviceName@. The env/managed-@envFrom@ blocks reuse the exact
-- helpers the app renderer exports ('envField', 'envFromField'), so a worker's
-- env is byte-identical to an app's and obeys the same managed-env contract
-- ('nagarectl env' keeps working for workers). The volume blocks and PVC
-- manifests reuse 'volumeMountsField' / 'volumesField' /
-- 'renderPersistentVolumeClaims' for the same reason.
module Nagare.Dsl.Worker.Render
  ( renderWorker
  , renderWorkerDeployment
  , workerDeploymentName
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import Data.Generics.Labels ()

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Build (resolveImageTag)
import Nagare.Dsl.Render
  ( envField
  , envFromField
  , renderPersistentVolumeClaims
  , volumeMountsField
  , volumesField
  )
import Nagare.Dsl.Types
  ( HealthScheme (..)
  , Resources
  , imageRefText
  , namespaceText
  , portInt
  , quantityText
  , serviceNameText
  )
import Nagare.Dsl.Worker

-- | The Deployment's name (= the worker name), exposed as a named owner so the
-- CLI never re-derives it.
workerDeploymentName :: Text -> Text
workerDeploymentName n = n

-- | Render every manifest a worker needs, in apply order: the PVCs first
-- (reusing 'renderPersistentVolumeClaims', exactly as the app path applies PVCs
-- before the consuming workload — the @local-path@ StorageClass binds
-- @WaitForFirstConsumer@), then the Deployment. For a volume-free worker this is
-- a one-element list. The second argument is the resolved image tag.
renderWorker :: Worker -> Text -> [ByteString]
renderWorker w tag =
  renderPersistentVolumeClaims (nameText w) (nsText w) (w ^. #volumes)
    <> [renderWorkerDeployment w tag]

-- | Render the single @apps/v1@ Deployment document for a worker.
renderWorkerDeployment :: Worker -> Text -> ByteString
renderWorkerDeployment w tag = YP.encodePretty workerConfig (deploymentValue w tag)

-- ---------------------------------------------------------------------------
-- Shared helpers.

txt :: Text -> Text
txt = id

nsText :: Worker -> Text
nsText w = namespaceText (w ^. #namespace)

nameText :: Worker -> Text
nameText w = serviceNameText (w ^. #name)

-- | The labels stamped on the Deployment and propagated to the pod template /
-- selector. @nagare.dev/worker@ is the worker analogue of the app's
-- @nagare.dev/app@ label.
workerLabels :: Worker -> Value
workerLabels w =
  object
    [ "nagare.dev/managed-by" .= txt "nagarectl"
    , "nagare.dev/worker" .= nameText w
    ]

-- | The single-label selector / pod-template label set (just @nagare.dev/worker@,
-- so the selector matches the pod template exactly).
workerSelectorLabels :: Worker -> Value
workerSelectorLabels w = object ["nagare.dev/worker" .= nameText w]

-- ---------------------------------------------------------------------------
-- Deployment.

deploymentValue :: Worker -> Text -> Value
deploymentValue w tag =
  object
    [ "apiVersion" .= txt "apps/v1"
    , "kind" .= txt "Deployment"
    , "metadata"
        .= object
          [ "name" .= workerDeploymentName (nameText w)
          , "namespace" .= nsText w
          , "labels" .= workerLabels w
          ]
    , "spec"
        .= object
          [ "replicas" .= replicasInt (w ^. #replicas)
          , "selector" .= object ["matchLabels" .= workerSelectorLabels w]
          , "template"
              .= object
                [ "metadata" .= object ["labels" .= workerSelectorLabels w]
                , "spec"
                    .= object
                      ( ["containers" .= toJSON [containerValue w tag]]
                          <> volumesField (nameText w) (w ^. #volumes)
                      )
                ]
          ]
    ]

containerValue :: Worker -> Text -> Value
containerValue w tag =
  object
    ( [ "name" .= nameText w
      , "image" .= imageStr
      ]
        <> commandPairs (w ^. #command)
        <> envField (w ^. #env)
        <> envFromField (nameText w)
        <> resourcesPairs (w ^. #resources)
        <> probesField (w ^. #liveness)
        <> volumeMountsField (w ^. #volumes)
    )
  where
    imageStr = imageRefText (w ^. #image) <> ":" <> resolveImageTag (w ^. #build) tag

-- | The liveness/startup probe block for a worker container (EP-74). Mirrors the
-- app renderer's @probesField@ ("Nagare.Dsl.Render") but emits NO @readinessProbe@
-- (a headless worker routes no traffic) and swaps @httpGet@ for the probe's
-- mechanism: @exec@ (the primary case), @tcpSocket@, or @httpGet@. A
-- @startupProbe@ with the same check is added when 'asStartup' is set. A worker
-- with no probe ('Nothing') emits nothing, so its rendered Deployment is
-- byte-identical to one rendered before this field existed.
probesField :: Maybe WorkerProbe -> [Pair]
probesField Nothing = []
probesField (Just p) =
  ["livenessProbe" .= probe]
    <> (if t ^. #asStartup then ["startupProbe" .= probe] else [])
  where
    t = probeTiming p
    probe = object (checkPair p <> timingPairs t)

-- | The Kubernetes probe-mechanism sub-object for a 'WorkerProbe' branch.
checkPair :: WorkerProbe -> [Pair]
checkPair (ExecProbe argv _) = ["exec" .= object ["command" .= toJSON argv]]
checkPair (TcpProbe port _) = ["tcpSocket" .= object ["port" .= portInt port]]
checkPair (HttpProbe path mport scheme _) =
  ["httpGet" .= object (["path" .= path] <> portPair <> ["scheme" .= schemeStr])]
  where
    portPair = maybe [] (\pt -> ["port" .= portInt pt]) mport
    schemeStr = case scheme of
      HTTP -> "HTTP" :: Text
      HTTPS -> "HTTPS"

-- | The shared timing keys, rendered exactly as the app renderer renders them
-- (Knative's @httpGet@ probe asserts no status, so no @expectedStatus@).
timingPairs :: ProbeTiming -> [Pair]
timingPairs t =
  [ "initialDelaySeconds" .= (t ^. #initialDelay)
  , "periodSeconds" .= (t ^. #period)
  , "timeoutSeconds" .= (t ^. #timeout)
  , "failureThreshold" .= (t ^. #failureThreshold)
  ]

-- | The container @command:@ block, emitted only when the worker overrides the
-- image's entrypoint. Rendered as a YAML list of the @commandArgv@ strings.
commandPairs :: Maybe Command -> [Pair]
commandPairs Nothing = []
commandPairs (Just c) = ["command" .= toJSON (commandArgvList c)]

-- | The @resources@ block (the @requests@/@limits@ shape shared with the app and
-- database renderers): each sub-block omitted when it has no quantities; the
-- whole block omitted when 'resources' is absent or empty.
resourcesPairs :: Maybe Resources -> [Pair]
resourcesPairs Nothing = []
resourcesPairs (Just res)
  | null reqs && null lims = []
  | otherwise = ["resources" .= object (reqBlock <> limBlock)]
  where
    reqs = quantities (res ^. #cpu) (res ^. #memory)
    lims = quantities (res ^. #cpuLimit) (res ^. #memoryLimit)
    reqBlock = if null reqs then [] else ["requests" .= object reqs]
    limBlock = if null lims then [] else ["limits" .= object lims]
    quantities mc mm =
      maybe [] (\q -> ["cpu" .= quantityText q]) mc
        <> maybe [] (\q -> ["memory" .= quantityText q]) mm

-- ---------------------------------------------------------------------------
-- YAML key ordering (mirrors Database/Render.hs's dbConfig with a local rank
-- table extended for the Deployment-specific keys: replicas, command, envFrom,
-- configMapRef, secretRef, optional).

workerConfig :: YP.Config
workerConfig = YP.setConfCompare keyCompare YP.defConfig

keyCompare :: Text -> Text -> Ordering
keyCompare a b = compare (rank a, a) (rank b, b)
  where
    rank :: Text -> Int
    rank k = maybe maxBound id (lookup k ranks)
    ranks :: [(Text, Int)]
    ranks =
      [ -- top-level document keys (also order template's metadata < spec)
        ("apiVersion", 0)
      , ("kind", 1)
      , ("metadata", 2)
      , ("spec", 3)
      , -- metadata
        ("name", 0)
      , ("namespace", 1)
      , ("labels", 2)
      , -- labels (non-alphabetical contract order)
        ("nagare.dev/managed-by", 0)
      , ("nagare.dev/worker", 1)
      , -- Deployment spec
        ("replicas", 0)
      , ("selector", 1)
      , ("template", 2)
      , ("matchLabels", 0)
      , -- pod spec
        ("containers", 0)
      , ("volumes", 1)
      , -- container (name(0) < image < command < env < envFrom < resources <
        -- livenessProbe < startupProbe < volumeMounts)
        ("image", 1)
      , ("command", 2)
      , ("env", 3)
      , ("envFrom", 4)
      , ("resources", 5)
      , ("livenessProbe", 6)
      , ("startupProbe", 7)
      , ("volumeMounts", 8)
      , -- probe sub-object: the check mechanism first, then timings in doc order
        ("exec", 0)
      , ("tcpSocket", 0)
      , ("httpGet", 0)
      , ("initialDelaySeconds", 1)
      , ("periodSeconds", 2)
      , ("timeoutSeconds", 3)
      , ("failureThreshold", 4)
      , -- httpGet sub-object keys (path(0) < port < scheme); exec's 'command' and
        -- tcpSocket's 'port' reuse the ranks above
        ("path", 0)
      , ("port", 1)
      , ("scheme", 2)
      , -- env entry
        ("value", 1)
      , ("valueFrom", 2)
      , ("secretKeyRef", 0)
      , ("key", 1)
      , -- envFrom entry
        ("configMapRef", 0)
      , ("secretRef", 1)
      , ("optional", 1)
      , -- resources
        ("requests", 0)
      , ("limits", 1)
      , ("cpu", 0)
      , ("memory", 1)
      , -- volumeMount entry (name(0) < mountPath < readOnly)
        ("mountPath", 1)
      , ("readOnly", 2)
      , -- pod volume entry (name(0) < persistentVolumeClaim)
        ("persistentVolumeClaim", 1)
      , ("claimName", 0)
      ]
