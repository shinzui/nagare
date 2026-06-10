{-# LANGUAGE PackageImports #-}

-- | Render a 'ServerSite' to the three artifacts a server deploy needs (EP-18):
--
--   * the generated single-stage Node 'renderServerDockerfile';
--   * the Knative @Service@ YAML running that image ('renderServerService'),
--     with the env map, resources, and scale a server needs;
--   * one @DomainMapping@ per configured custom domain
--     ('renderServerDomainMappings').
--
-- The Knative env/resource/scale shape and key ordering match the cluster
-- contract used by 'Nagare.Dsl.Render' for a 'Nagare.Dsl.Types.Deployment'; the
-- container port defaults to 8080 and no @PORT@ env is set, because Knative
-- injects @PORT@ to match the declared container port.
module Nagare.Dsl.Server.Render
  ( ServerDeployContext (..)
  , renderServerDockerfile
  , renderServerService
  , renderServerDomainMappings
  , renderServerVolumeClaims
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import "generic-lens" Data.Generics.Labels ()

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.List.NonEmpty qualified as NE
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Render
  ( managedConfigMapName
  , managedSecretName
  , renderPersistentVolumeClaims
  , volumeAnnotationPairs
  , volumeMountsField
  , volumesField
  )
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types (siteNameText)
import Nagare.Dsl.Types
  ( Domain
  , EnvName
  , EnvScope (..)
  , EnvVar (..)
  , Resources
  , ScopedEnvVar
  , domainText
  , envNameText
  , imageRefText
  , namespaceText
  , portInt
  , quantityText
  , secretNameText
  )

-- | What a deploy knows beyond the 'ServerSite' itself: the resolved image tag
-- and an optional preview name (reserved for preview deploys; 'Nothing' for
-- production).
data ServerDeployContext = ServerDeployContext
  { imageTag :: Text
  , previewName :: Maybe Text
  }
  deriving stock (Generic, Eq, Show)

serviceNameFor :: ServerSite -> ServerDeployContext -> Text
serviceNameFor site ctx = fromMaybe (siteNameText (site ^. #name)) (previewName ctx)

-- ---------------------------------------------------------------------------
-- Dockerfile

-- | Render the single-stage Node Dockerfile from the runtime. @app/@ is the
-- directory the deploy step fills with the copied @outputDirs@; with the
-- defaults this is @FROM node:22-alpine@ … @CMD ["node", ".output/server/index.mjs"]@.
-- No @ENV PORT=@ line — Knative injects @PORT=8080@.
renderServerDockerfile :: ServerSite -> Text
renderServerDockerfile site =
  Text.unlines
    [ "FROM " <> runtimeImageText (rt ^. #baseImage)
    , "WORKDIR /app"
    , "ENV NODE_ENV=production"
    , "COPY app/ ./"
    , "EXPOSE 8080"
    , "CMD " <> jsonArray (NE.toList (rt ^. #startCommand))
    ]
  where
    rt = site ^. #runtime

-- | Render a JSON string array, e.g. @["node", ".output/server/index.mjs"]@.
jsonArray :: [Text] -> Text
jsonArray xs = "[" <> Text.intercalate ", " (map quote xs) <> "]"
  where
    quote x = "\"" <> Text.replace "\"" "\\\"" x <> "\""

-- ---------------------------------------------------------------------------
-- Knative Service

renderServerService :: ServerSite -> ServerDeployContext -> ByteString
renderServerService site ctx = YP.encodePretty knativeConfig (serviceValue site ctx)

renderServerDomainMappings :: ServerSite -> ServerDeployContext -> [ByteString]
renderServerDomainMappings site ctx =
  map (YP.encodePretty knativeConfig . domainMappingValue site ctx) (site ^. #domains)

-- | Render one 'PersistentVolumeClaim' manifest per declared volume (MasterPlan
-- IP2/IP3), delegating to 'Nagare.Dsl.Render.renderPersistentVolumeClaims' so a
-- 'ServerSite' and a 'Nagare.Dsl.Types.Deployment' emit byte-identical PVC YAML.
-- The app name is the (possibly preview) Service name, matching the @claimName@
-- the Service references.
renderServerVolumeClaims :: ServerSite -> ServerDeployContext -> [ByteString]
renderServerVolumeClaims site ctx =
  renderPersistentVolumeClaims
    (serviceNameFor site ctx)
    (namespaceText (site ^. #namespace))
    (site ^. #volumes)

serviceValue :: ServerSite -> ServerDeployContext -> Value
serviceValue site ctx =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
    , "kind" .= ("Service" :: Text)
    , "metadata"
        .= namespacedMeta (serviceNameFor site ctx) (namespaceText (site ^. #namespace))
    , "spec" .= object ["template" .= templateValue site ctx]
    ]

templateValue :: ServerSite -> ServerDeployContext -> Value
templateValue site ctx =
  case annotationPairs site of
    [] -> object ["spec" .= specValue site ctx]
    pairs ->
      object
        [ "metadata" .= object ["annotations" .= object pairs]
        , "spec" .= specValue site ctx
        ]

-- | Pod-template annotations: a storage-backed site uses EP-33's verified
-- rollout-safety set (which replaces the author's scale annotations); a
-- stateless site uses its 'Scale' (or none). Mirrors 'Nagare.Dsl.Render'.
annotationPairs :: ServerSite -> [Pair]
annotationPairs site
  | not (null (site ^. #volumes)) = volumeAnnotationPairs (site ^. #volumes)
  | otherwise = case site ^. #scale of
      Nothing -> []
      Just sc ->
        [ "autoscaling.knative.dev/min-scale" .= (Text.pack (show (sc ^. #minScale)) :: Text)
        , "autoscaling.knative.dev/max-scale" .= (Text.pack (show (sc ^. #maxScale)) :: Text)
        ]

specValue :: ServerSite -> ServerDeployContext -> Value
specValue site ctx =
  object
    ( ["containers" .= toJSON [containerValue site ctx]]
        <> volumesField (serviceNameFor site ctx) (site ^. #volumes)
    )

containerValue :: ServerSite -> ServerDeployContext -> Value
containerValue site ctx =
  object (required <> optionals)
  where
    imageStr = imageRefText (site ^. #image) <> ":" <> imageTag ctx
    portN = portInt (site ^. #port)
    required =
      [ "image" .= imageStr
      , "ports" .= toJSON [object ["containerPort" .= portN]]
      ]
    optionals =
      envField (site ^. #env)
        <> envFromField (serviceNameFor site ctx)
        <> resourcesField (site ^. #resources)
        <> volumeMountsField (site ^. #volumes)

-- | The inline @env:@ block, restricted to Runtime-scoped entries (see
-- 'Nagare.Dsl.Render.envField' for the rationale). Build/Preview-only entries
-- are excluded from the running container.
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

-- | The always-present @envFrom:@ block referencing the site's Runtime-scoped
-- managed ConfigMap and Secret with @optional: true@ (MasterPlan IP3). For a
-- preview deploy the name is the preview Service name, matching the store the
-- managed env was written to.
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
          ["secretKeyRef" .= object ["name" .= secretNameText sn, "key" .= n]]
    ]

resourcesField :: Maybe Resources -> [Pair]
resourcesField Nothing = []
resourcesField (Just res) =
  ["resources" .= object ["requests" .= object (cpuF <> memF)]]
  where
    cpuF = maybe [] (\q -> ["cpu" .= quantityText q]) (res ^. #cpu)
    memF = maybe [] (\q -> ["memory" .= quantityText q]) (res ^. #memory)

domainMappingValue :: ServerSite -> ServerDeployContext -> Domain -> Value
domainMappingValue site ctx d =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
    , "kind" .= ("DomainMapping" :: Text)
    , "metadata"
        .= namespacedMeta (domainText d) (namespaceText (site ^. #namespace))
    , "spec"
        .= object
          [ "ref"
              .= object
                [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
                , "kind" .= ("Service" :: Text)
                , "name" .= serviceNameFor site ctx
                ]
          ]
    ]

namespacedMeta :: Text -> Text -> Value
namespacedMeta n ns = object ["name" .= n, "namespace" .= ns]

-- ---------------------------------------------------------------------------
-- YAML key ordering (mirrors Nagare.Dsl.Render)

knativeConfig :: YP.Config
knativeConfig = YP.setConfCompare keyCompare YP.defConfig

keyCompare :: Text -> Text -> Ordering
keyCompare a b = compare (rank a, a) (rank b, b)
  where
    rank :: Text -> Int
    rank k = maybe maxBound id (lookup k ranks)
    ranks :: [(Text, Int)]
    ranks =
      [ ("apiVersion", 0)
      , ("kind", 1)
      , ("name", 2)
      , ("namespace", 3)
      , ("key", 3)
      , ("value", 3)
      , ("valueFrom", 3)
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
      , ("ref", 0)
      , ("image", 0)
      , ("ports", 1)
      , ("env", 2)
      , ("envFrom", 3)
      , ("resources", 4)
      , ("volumeMounts", 8)
      , ("volumes", 1)
      , ("cpu", 0)
      , ("memory", 1)
      , ("optional", 4)
      , ("configMapRef", 0)
      , ("secretRef", 1)
      , -- volumeMount entry keys: name(2) < mountPath < readOnly
        ("mountPath", 3)
      , ("readOnly", 4)
      , -- pod volume entry: name(2) < persistentVolumeClaim
        ("persistentVolumeClaim", 3)
      , ("claimName", 0)
      ]
