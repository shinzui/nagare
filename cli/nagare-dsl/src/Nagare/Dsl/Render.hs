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
  , renderDomainMapping
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import "generic-lens" Data.Generics.Labels ()

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as Text
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Types

-- | Render a 'Deployment' to a Knative Service YAML document. The second
-- argument is the resolved image tag, e.g. @"20260602-120000"@.
renderService :: Deployment -> Text -> ByteString
renderService dep tag = YP.encodePretty knativeConfig (serviceValue dep tag)

-- | Render a DomainMapping YAML document, or 'Nothing' when the deployment has
-- no custom @domain@.
renderDomainMapping :: Deployment -> Maybe ByteString
renderDomainMapping dep =
  fmap (YP.encodePretty knativeConfig . domainMappingValue dep) (dep ^. #domain)

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
      , ("metadata", 4)
      , ("spec", 5)
      , ("autoscaling.knative.dev/min-scale", 0)
      , ("autoscaling.knative.dev/max-scale", 1)
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
      , ("resources", 3)
      , ("cpu", 0)
      , ("memory", 1)
      ]

-- ---------------------------------------------------------------------------
-- Internal builders

serviceValue :: Deployment -> Text -> Value
serviceValue dep tag =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
    , "kind" .= ("Service" :: Text)
    , "metadata"
        .= namespacedMeta
          (serviceNameText (dep ^. #name))
          (namespaceText (dep ^. #namespace))
    , "spec" .= object ["template" .= templateValue dep tag]
    ]

namespacedMeta :: Text -> Text -> Value
namespacedMeta n ns = object ["name" .= n, "namespace" .= ns]

templateValue :: Deployment -> Text -> Value
templateValue dep tag =
  case dep ^. #scale of
    Nothing -> object ["spec" .= specValue dep tag]
    Just sc ->
      object
        [ "metadata" .= object ["annotations" .= annotationsValue sc]
        , "spec" .= specValue dep tag
        ]

annotationsValue :: Scale -> Value
annotationsValue sc =
  object
    [ "autoscaling.knative.dev/min-scale" .= (Text.pack (show (sc ^. #minScale)) :: Text)
    , "autoscaling.knative.dev/max-scale" .= (Text.pack (show (sc ^. #maxScale)) :: Text)
    ]

specValue :: Deployment -> Text -> Value
specValue dep tag = object ["containers" .= toJSON [containerValue dep tag]]

containerValue :: Deployment -> Text -> Value
containerValue dep tag =
  object (required <> optionals)
  where
    imageStr = imageRefText (dep ^. #image) <> ":" <> tag
    portN = portInt (dep ^. #port)
    required =
      [ "image" .= imageStr
      , "ports" .= toJSON [object ["containerPort" .= portN]]
      ]
    optionals = envField (dep ^. #env) <> resourcesField (dep ^. #resources)

envField :: Map EnvName EnvVar -> [Pair]
envField m
  | Map.null m = []
  | otherwise = ["env" .= toJSON (map envEntry (Map.toAscList m))]
  where
    envEntry (n, ev) = envEntryValue (envNameText n) ev

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

resourcesField :: Maybe Resources -> [Pair]
resourcesField Nothing = []
resourcesField (Just res) =
  ["resources" .= object ["requests" .= object (cpuF <> memF)]]
  where
    cpuF = maybe [] (\q -> ["cpu" .= quantityText q]) (res ^. #cpu)
    memF = maybe [] (\q -> ["memory" .= quantityText q]) (res ^. #memory)

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
