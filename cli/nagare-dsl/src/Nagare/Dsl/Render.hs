{-# LANGUAGE PackageImports #-}

-- | Render a 'Deployment' to Knative @Service@ and @DomainMapping@ YAML.
--
-- Rendering rules preserved exactly (the EP-6 cluster contract / MasterPlan
-- Integration Point 2):
--
--   * env entries sorted by variable name (@Data.Map.toAscList@);
--   * autoscaling annotation /values/ are Strings, rendered quoted (@'0'@);
--   * optional sub-blocks (@env@, @resources@, annotations) are omitted
--     entirely when their source field is absent — never emitted empty;
--   * @secretRef@ becomes @valueFrom.secretKeyRef@ with @name@ = the secret and
--     @key@ = the env var's own name.
--
-- Key ordering: the contract's key order is NOT alphabetical (in the
-- autoscaling block @min-scale@ precedes @max-scale@; a container lists
-- @image@/@ports@/@env@/@resources@ in document order). A plain
-- @Data.Yaml.encode@ cannot reproduce that order deterministically, so the
-- renderer serialises through @Data.Yaml.Pretty.encodePretty@ with an explicit
-- key comparator. (Lesson carried from the EP-8 spike; see this plan's Decision
-- Log.)
module Nagare.Dsl.Render
  ( renderService
  , renderDomainMappings
    -- * Managed-resource naming helpers (IP2)
  , scopeToken
  , managedConfigMapName
  , managedSecretName
    -- * Persistent volume rendering (IP2/IP3)
  , pvcName
  , renderVolumeClaims
  , renderPersistentVolumeClaims
  , volumeMountsField
  , volumesField
  , volumeAnnotationPairs
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import "generic-lens" Data.Generics.Labels ()

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Build (resolveImageTag)
import Nagare.Dsl.Types

-- | Render a 'Deployment' to a Knative Service YAML document. The second
-- argument is the resolved image tag, e.g. @"20260602-120000"@.
renderService :: Deployment -> Text -> ByteString
renderService dep tag = YP.encodePretty knativeConfig (serviceValue dep tag)

-- | Render one DomainMapping YAML document per configured custom domain. An app
-- with no custom domains renders an empty list (the Knative wildcard URL is used
-- instead). The canonical marker affects only URL reporting
-- ('Nagare.Deploy.serviceUrl'), not which mappings are rendered.
renderDomainMappings :: Deployment -> [ByteString]
renderDomainMappings dep =
  map (YP.encodePretty knativeConfig . domainMappingValue dep . (^. #domain)) (dep ^. #domains)

-- ---------------------------------------------------------------------------
-- Managed-resource naming helpers (MasterPlan IP2)
--
-- This module is the single owner of the managed-env resource name format.
-- EP-24 (store), EP-25 (CLI), and EP-27 (build/preview) import these helpers and
-- must never re-derive the names by hand.

-- | The lowercased scope token used in managed-resource names:
-- @Runtime -> "runtime"@, @Build -> "build"@, @Preview -> "preview"@.
scopeToken :: EnvScope -> Text
scopeToken Runtime = "runtime"
scopeToken Build = "build"
scopeToken Preview = "preview"

-- | Name of the non-secret managed-env ConfigMap for one app and scope, e.g.
-- @managedConfigMapName "notes" Runtime == "nagare-env-notes-runtime"@.
managedConfigMapName :: Text -> EnvScope -> Text
managedConfigMapName app s = "nagare-env-" <> app <> "-" <> scopeToken s

-- | Name of the managed-env Secret for one app and scope, e.g.
-- @managedSecretName "notes" Runtime == "nagare-secret-notes-runtime"@.
managedSecretName :: Text -> EnvScope -> Text
managedSecretName app s = "nagare-secret-" <> app <> "-" <> scopeToken s

-- ---------------------------------------------------------------------------
-- Persistent volume rendering (MasterPlan IP2/IP3; verified by EP-33)
--
-- This module is the single owner of the PVC naming convention and the
-- rendered volume/volumeMount/PVC YAML shape. EP-35/EP-36 discover PVCs by the
-- labels stamped here and must never re-derive the name. The Service-side
-- helpers ('volumeMountsField', 'volumesField', 'volumeAnnotationPairs') are
-- reused by 'Nagare.Dsl.Server.Render' so both renderers emit one shape.

-- | The deterministic PVC name for an app/volume pair (MasterPlan IP3):
-- @pvcName "hello" "data" == "nagare-vol-hello-data"@. EP-35 and EP-36 discover
-- PVCs by the @nagare.dev/app@/@nagare.dev/volume@ labels, never by re-deriving
-- this string.
pvcName :: Text -> Text -> Text
pvcName app vol = "nagare-vol-" <> app <> "-" <> vol

accessModeText :: AccessMode -> Text
accessModeText ReadWriteOnce = "ReadWriteOnce"

-- | Render one 'PersistentVolumeClaim' manifest per declared volume (MasterPlan
-- IP2/IP3). @storageClassName@ is the cluster's built-in @local-path@;
-- @accessModes@ is the single-node @[ReadWriteOnce]@; the requested size becomes
-- @resources.requests.storage@. The labels let EP-35/EP-36 discover the PVC by
-- app/volume. Shared by 'Nagare.Dsl.Server.Render' so PVC YAML is identical for
-- a 'Deployment' and a 'ServerSite'.
renderPersistentVolumeClaims :: Text -> Text -> [Volume] -> [ByteString]
renderPersistentVolumeClaims app ns = map (YP.encodePretty knativeConfig . pvcValue app ns)

-- | Render the PVC manifests for a 'Deployment' (one per declared volume).
renderVolumeClaims :: Deployment -> [ByteString]
renderVolumeClaims dep =
  renderPersistentVolumeClaims
    (serviceNameText (dep ^. #name))
    (namespaceText (dep ^. #namespace))
    (dep ^. #volumes)

pvcValue :: Text -> Text -> Volume -> Value
pvcValue app ns v =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("PersistentVolumeClaim" :: Text)
    , "metadata"
        .= object
          [ "name" .= pvcName app (volumeNameText (v ^. #volName))
          , "namespace" .= ns
          , "labels"
              .= object
                [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
                , "nagare.dev/app" .= app
                , "nagare.dev/volume" .= volumeNameText (v ^. #volName)
                ]
          ]
    , "spec"
        .= object
          [ "accessModes" .= toJSON [accessModeText (v ^. #accessMode)]
          , "storageClassName" .= ("local-path" :: Text)
          , "resources" .= object ["requests" .= object ["storage" .= quantityText (v ^. #size)]]
          ]
    ]

-- | The container @volumeMounts:@ block, one entry per volume (empty when none,
-- so no empty key is emitted — the 'resourcesField' convention).
volumeMountsField :: [Volume] -> [Pair]
volumeMountsField [] = []
volumeMountsField vs = ["volumeMounts" .= toJSON (map mountEntry vs)]
  where
    mountEntry v =
      object
        [ "name" .= volumeNameText (v ^. #volName)
        , "mountPath" .= mountPathText (v ^. #mountPath)
        , "readOnly" .= (v ^. #readOnly)
        ]

-- | The pod @volumes:@ block, one @persistentVolumeClaim@ entry per volume
-- referencing the deterministic 'pvcName' (empty when none).
volumesField :: Text -> [Volume] -> [Pair]
volumesField _ [] = []
volumesField app vs = ["volumes" .= toJSON (map volEntry vs)]
  where
    volEntry v =
      object
        [ "name" .= volumeNameText (v ^. #volName)
        , "persistentVolumeClaim"
            .= object ["claimName" .= pvcName app (volumeNameText (v ^. #volName))]
        ]

-- | The rollout-safety annotations EP-33 verified a single-node @ReadWriteOnce@
-- @local-path@ PVC needs to survive a Knative revision roll: pin a single
-- always-on replica (@min-scale=1@, @max-scale=1@) and cut over immediately
-- (@rollout-duration=0s@). Returns @[]@ for a stateless app (no volumes), so the
-- author's own scale annotations are used unchanged. When volumes are present
-- these REPLACE the scale-derived annotations: a writable RWO volume must not be
-- mounted by more than one concurrent writer, and the app must stay warm.
-- See @docs/plans/33-...@ Decision Log / Interfaces (verified IP2 shape).
volumeAnnotationPairs :: [Volume] -> [Pair]
volumeAnnotationPairs [] = []
volumeAnnotationPairs _ =
  [ "autoscaling.knative.dev/min-scale" .= ("1" :: Text)
  , "autoscaling.knative.dev/max-scale" .= ("1" :: Text)
  , "serving.knative.dev/rollout-duration" .= ("0s" :: Text)
  ]

-- ---------------------------------------------------------------------------
-- YAML key ordering

-- | A pretty-print config whose comparator imposes the contract's key order.
knativeConfig :: YP.Config
knativeConfig = YP.setConfCompare keyCompare YP.defConfig

-- | Order keys by a fixed rank (lower first), falling back to alphabetical for
-- any key not in the table. Ranks need only be distinct /within/ one object;
-- the same rank is safely reused across unrelated objects.
keyCompare :: Text -> Text -> Ordering
keyCompare a b = compare (rank a, a) (rank b, b)
  where
    rank :: Text -> Int
    rank k = maybe maxBound id (lookup k ranks)
    -- Ranks need only be distinct /within/ a single object, so the same rank
    -- is reused across unrelated objects. The one subtlety is "name": it must
    -- sort first in `metadata`/`secretKeyRef` (before namespace/key) but last
    -- in `ref` (after apiVersion/kind). The ranks below satisfy all three
    -- contexts at once: apiVersion(0) < kind(1) < name(2) < namespace/key/...(3).
    ranks :: [(Text, Int)]
    ranks =
      [ ("apiVersion", 0)
      , ("kind", 1)
      , ("name", 2)
      , ("namespace", 3)
      , ("key", 3)
      , ("value", 3)
      , ("valueFrom", 3)
      , ("labels", 4)
      , ("metadata", 4)
      , ("spec", 5)
      , ("autoscaling.knative.dev/min-scale", 0)
      , ("autoscaling.knative.dev/max-scale", 1)
      , ("serving.knative.dev/rollout-duration", 2)
      , ("annotations", 0)
      , ("template", 0)
      , ("containers", 0)
      , ("containerPort", 0)
      , ("secretKeyRef", 0)
      , ("requests", 0)
      , ("limits", 1)
      , ("ref", 0)
      , ("image", 0)
      , ("ports", 1)
      , ("env", 2)
      , ("envFrom", 3)
      , ("resources", 4)
      , ("readinessProbe", 5)
      , ("livenessProbe", 6)
      , ("startupProbe", 7)
      , ("volumeMounts", 8)
      , ("volumes", 1)
      , ("cpu", 0)
      , ("memory", 1)
      , ("optional", 4)
      , ("configMapRef", 0)
      , ("secretRef", 1)
      , -- probe sub-object keys: httpGet first, then timings in document order
        ("httpGet", 0)
      , ("initialDelaySeconds", 1)
      , ("periodSeconds", 2)
      , ("timeoutSeconds", 3)
      , ("failureThreshold", 4)
      , -- httpGet sub-object keys
        ("path", 0)
      , ("port", 1)
      , ("scheme", 2)
      , -- volumeMount entry keys: name(2) < mountPath < readOnly
        ("mountPath", 3)
      , ("readOnly", 4)
      , -- pod volume entry: name(2) < persistentVolumeClaim
        ("persistentVolumeClaim", 3)
      , ("claimName", 0)
      , -- PVC spec keys: accessModes < storageClassName < resources(4)
        ("accessModes", 0)
      , ("storageClassName", 1)
      , ("storage", 0)
      , -- PVC label keys (non-alphabetical contract order)
        ("nagare.dev/managed-by", 0)
      , ("nagare.dev/app", 1)
      , ("nagare.dev/volume", 2)
      ]

-- ---------------------------------------------------------------------------
-- Internal builders

serviceValue :: Deployment -> Text -> Value
serviceValue dep tag =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
    , "kind" .= ("Service" :: Text)
    , "metadata"
        .= object
          [ "name" .= serviceNameText (dep ^. #name)
          , "namespace" .= namespaceText (dep ^. #namespace)
          , -- IP1: every Nagare-managed Service carries this label so other
            -- commands (e.g. @nagarectl app list@) can recognise it. The exact
            -- string is an integration contract — do not change it.
            "labels" .= object ["nagare.dev/managed-by" .= ("nagarectl" :: Text)]
          ]
    , "spec" .= object ["template" .= templateValue dep tag]
    ]

namespacedMeta :: Text -> Text -> Value
namespacedMeta n ns = object ["name" .= n, "namespace" .= ns]

templateValue :: Deployment -> Text -> Value
templateValue dep tag =
  case annotationPairs dep of
    [] -> object ["spec" .= specValue dep tag]
    pairs ->
      object
        [ "metadata" .= object ["annotations" .= object pairs]
        , "spec" .= specValue dep tag
        ]

-- | The pod-template annotations. A storage-backed app (one or more volumes)
-- uses EP-33's verified rollout-safety set ('volumeAnnotationPairs'), which
-- replaces the author's scale annotations; a stateless app uses its 'Scale'
-- (or none). Empty means no @metadata.annotations@ block is emitted.
annotationPairs :: Deployment -> [Pair]
annotationPairs dep
  | not (null (dep ^. #volumes)) = volumeAnnotationPairs (dep ^. #volumes)
  | otherwise = case dep ^. #scale of
      Nothing -> []
      Just sc ->
        [ "autoscaling.knative.dev/min-scale" .= (Text.pack (show (sc ^. #minScale)) :: Text)
        , "autoscaling.knative.dev/max-scale" .= (Text.pack (show (sc ^. #maxScale)) :: Text)
        ]

specValue :: Deployment -> Text -> Value
specValue dep tag =
  object
    ( ["containers" .= toJSON [containerValue dep tag]]
        <> volumesField (serviceNameText (dep ^. #name)) (dep ^. #volumes)
    )

containerValue :: Deployment -> Text -> Value
containerValue dep tag =
  object (required <> optionals)
  where
    imageStr = imageRefText (dep ^. #image) <> ":" <> resolveImageTag (dep ^. #build) tag
    portN = portInt (dep ^. #port)
    required =
      [ "image" .= imageStr
      , "ports" .= toJSON [object ["containerPort" .= portN]]
      ]
    optionals =
      envField (dep ^. #env)
        <> envFromField (serviceNameText (dep ^. #name))
        <> resourcesField (dep ^. #resources)
        <> probesField (dep ^. #healthCheck) (dep ^. #port)
        <> volumeMountsField (dep ^. #volumes)

-- | The inline @env:@ block, restricted to entries whose scope set contains
-- 'Runtime'. A @{Build}@- or @{Preview}@-only entry is excluded from the running
-- container; an entry scoped @{Build, Runtime}@ is included. The block is omitted
-- entirely when no Runtime entry remains.
envField :: Map EnvName ScopedEnvVar -> [Pair]
envField m
  | null runtimeEntries = []
  | otherwise = ["env" .= toJSON (map envEntry runtimeEntries)]
  where
    runtimeEntries =
      [ (n, sev ^. #value)
      | (n, sev) <- Map.toAscList m
      , Set.member Runtime (sev ^. #scopes)
      ]
    envEntry (n, ev) = envEntryValue (envNameText n) ev

-- | The always-present @envFrom:@ block referencing the app's Runtime-scoped
-- managed ConfigMap and Secret with @optional: true@ (MasterPlan IP3). Kubernetes
-- applies @envFrom@ before the inline @env:@ list, so inline DSL env (and, later,
-- generated variables) overrides managed env of the same key. @optional: true@
-- means an app whose store was never written still deploys.
envFromField :: Text -> [Pair]
envFromField app =
  [ "envFrom"
      .= toJSON
        [ object ["configMapRef" .= object ["name" .= managedConfigMapName app Runtime, "optional" .= True]]
        , object ["secretRef" .= object ["name" .= managedSecretName app Runtime, "optional" .= True]]
        ]
  ]

envEntryValue :: Text -> EnvVar -> Value
envEntryValue n (EnvLiteral lit) =
  object ["name" .= n, "value" .= lit]
envEntryValue n (EnvSecretRef sn) =
  object
    [ "name" .= n
    , "valueFrom"
        .= object
          [ "secretKeyRef"
              .= object
                [ "name" .= secretNameText sn
                , "key" .= n
                ]
          ]
    ]

-- | The @resources:@ block, with @requests@ and/or @limits@ sub-blocks, each
-- omitted when it has no quantities. The whole block is omitted when no
-- quantity at all is present.
resourcesField :: Maybe Resources -> [Pair]
resourcesField Nothing = []
resourcesField (Just res)
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

-- | The probe keys for the container object. A 'HealthCheck' always emits a
-- @readinessProbe@, plus a @livenessProbe@ when 'asLiveness' and a
-- @startupProbe@ when 'asStartup'. The container 'Port' is the default probe
-- port when the check does not pin its own 'checkPort'. Knative's @httpGet@
-- probe does not assert a status, so 'expectedStatus' is intentionally not
-- rendered.
probesField :: Maybe HealthCheck -> Port -> [Pair]
probesField Nothing _ = []
probesField (Just hc) containerPort =
  ["readinessProbe" .= probe]
    <> (if hc ^. #asLiveness then ["livenessProbe" .= probe] else [])
    <> (if hc ^. #asStartup then ["startupProbe" .= probe] else [])
  where
    probePort = maybe (portInt containerPort) portInt (hc ^. #checkPort)
    schemeStr = case hc ^. #scheme of
      HTTP -> "HTTP" :: Text
      HTTPS -> "HTTPS"
    probe =
      object
        [ "httpGet"
            .= object
              [ "path" .= (hc ^. #path)
              , "port" .= probePort
              , "scheme" .= schemeStr
              ]
        , "initialDelaySeconds" .= (hc ^. #initialDelay)
        , "periodSeconds" .= (hc ^. #period)
        , "timeoutSeconds" .= (hc ^. #timeout)
        , "failureThreshold" .= (hc ^. #failureThreshold)
        ]

domainMappingValue :: Deployment -> Domain -> Value
domainMappingValue dep d =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
    , "kind" .= ("DomainMapping" :: Text)
    , "metadata"
        .= namespacedMeta (domainText d) (namespaceText (dep ^. #namespace))
    , "spec"
        .= object
          [ "ref"
              .= object
                [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
                , "kind" .= ("Service" :: Text)
                , "name" .= serviceNameText (dep ^. #name)
                ]
          ]
    ]
