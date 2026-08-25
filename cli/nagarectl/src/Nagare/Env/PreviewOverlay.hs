-- | Preview-scoped env overlay (EP-27 Milestone 2).
--
-- A preview deployment (a throwaway copy of a site for a branch or PR) usually
-- needs to point at /different/ backing services than production — a staging
-- database, a sandbox key — without changing production's variables. This module
-- adds, to a preview Service's container, an @envFrom@ block that imports the
-- app's Runtime store and then its Preview store, in that order, so Preview wins
-- on conflicts (Kubernetes applies @envFrom@ entries top-to-bottom):
--
-- @
-- envFrom:
--   - configMapRef: { name: nagare-env-<app>-runtime,  optional: true }
--   - secretRef:    { name: nagare-secret-<app>-runtime, optional: true }
--   - configMapRef: { name: nagare-env-<app>-preview,  optional: true }
--   - secretRef:    { name: nagare-secret-<app>-preview, optional: true }
-- @
--
-- @\<app\>@ is the /production/ app name (preview env is shared across all
-- previews of one app), not the derived preview Service name. The names come from
-- EP-23's IP2 helpers. The overlay is applied here, in the nagarectl preview
-- render path, rather than in the DSL renderer, because static Services carry no
-- env (and hence no @envFrom@) for the DSL to extend.
module Nagare.Env.PreviewOverlay
  ( withPreviewEnvFrom
  , previewEnvFrom
  )
where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Vector qualified as V
import Data.Yaml qualified as Yaml
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Render (managedConfigMapName, managedSecretName)
import Nagare.Dsl.Types (EnvScope (..))

-- | The four-entry preview @envFrom@ array for an app: the Runtime pair, then the
-- Preview pair (Preview last so it overrides Runtime), each @optional: true@.
previewEnvFrom :: Text -> Value
previewEnvFrom app =
  toJSON
    [ object ["configMapRef" .= object ["name" .= managedConfigMapName app Runtime, "optional" .= True]]
    , object ["secretRef" .= object ["name" .= managedSecretName app Runtime, "optional" .= True]]
    , object ["configMapRef" .= object ["name" .= managedConfigMapName app Preview, "optional" .= True]]
    , object ["secretRef" .= object ["name" .= managedSecretName app Preview, "optional" .= True]]
    ]

-- | Decode the Service YAML, set the first container's @envFrom@ to the four-entry
-- preview overlay for @app@, and re-encode with the Knative key comparator. On a
-- decode failure the input is returned unchanged (defensive; the input is always
-- our own deterministic render).
withPreviewEnvFrom :: Text -> ByteString -> ByteString
withPreviewEnvFrom app input =
  case Yaml.decodeEither' input of
    Left _ -> input
    Right v -> YP.encodePretty previewConfig (overlayContainer (previewEnvFrom app) v)

-- | Set @envFrom@ on @spec.template.spec.containers[0]@.
overlayContainer :: Value -> Value -> Value
overlayContainer envFrom =
  modifyKey "spec" $
    modifyKey "template" $
      modifyKey "spec" $
        modifyKey "containers" $
          modifyFirst $
            insertKey "envFrom" envFrom

modifyKey :: Key -> (Value -> Value) -> Value -> Value
modifyKey k g (Object o) = case KeyMap.lookup k o of
  Just v -> Object (KeyMap.insert k (g v) o)
  Nothing -> Object o
modifyKey _ _ v = v

modifyFirst :: (Value -> Value) -> Value -> Value
modifyFirst g (Array arr)
  | not (V.null arr) = Array (arr V.// [(0, g (V.head arr))])
modifyFirst _ v = v

insertKey :: Key -> Value -> Value -> Value
insertKey k val (Object o) = Object (KeyMap.insert k val o)
insertKey _ _ v = v

-- ---------------------------------------------------------------------------
-- YAML key ordering (mirrors Nagare.Dsl.Static.Render / Nagare.Dsl.Render, plus
-- the envFrom block keys, so the overlaid Service serializes deterministically).

previewConfig :: YP.Config
previewConfig = YP.setConfCompare keyCompare YP.defConfig

keyCompare :: Text -> Text -> Ordering
keyCompare a b = compare (rank a, a) (rank b, b)
  where
    rank :: Text -> Int
    rank k = fromMaybe maxBound (lookup k ranks)
    ranks :: [(Text, Int)]
    ranks =
      [ ("apiVersion", 0)
      , ("kind", 1)
      , ("name", 2)
      , ("namespace", 3)
      , ("metadata", 4)
      , ("spec", 5)
      , ("template", 0)
      , ("containers", 0)
      , ("image", 0)
      , ("ports", 1)
      , ("envFrom", 2)
      , ("containerPort", 0)
      , ("configMapRef", 0)
      , ("secretRef", 1)
      , ("optional", 4)
      , ("ref", 0)
      ]
