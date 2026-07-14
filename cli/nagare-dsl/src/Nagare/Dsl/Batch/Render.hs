-- | Internal rendering helpers shared by scheduled Tasks and one-shot Jobs.
-- Keeping these here prevents the two batch workload kinds from drifting in
-- environment, resource, and deterministic YAML behavior.
module Nagare.Dsl.Batch.Render
  ( argvPairs
  , managedEnvFromPairs
  , runtimeEnvPairs
  , resourcesPairs
  , batchConfig
  )
where

import Nagare.Dsl.Prelude hiding ((.=))

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Types (Pair)
import Data.Generics.Labels ()
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Types
  ( EnvName
  , EnvScope (Runtime)
  , EnvVar (..)
  , Resources
  , ScopedEnvVar
  , envNameText
  , quantityText
  , secretNameText
  )

-- | Emit @command@ only for a non-empty argv list.
argvPairs :: [Text] -> [Pair]
argvPairs [] = []
argvPairs argv = ["command" .= toJSON argv]

-- | The standard optional Runtime ConfigMap and Secret pair managed by
-- nagarectl. Kubernetes applies these before explicit @env@ entries.
managedEnvFromPairs :: Text -> [Pair]
managedEnvFromPairs name =
  [ "envFrom"
      .= toJSON
        [ object
            [ "configMapRef"
                .= object
                  [ "name" .= ("nagare-env-" <> name <> "-runtime")
                  , "optional" .= True
                  ]
            ]
        , object
            [ "secretRef"
                .= object
                  [ "name" .= ("nagare-secret-" <> name <> "-runtime")
                  , "optional" .= True
                  ]
            ]
        ]
  ]

-- | Render only Runtime-scoped inline environment entries, sorted by their
-- validated names through 'Map.toAscList'.
runtimeEnvPairs :: Map EnvName ScopedEnvVar -> [Pair]
runtimeEnvPairs env
  | null entries = []
  | otherwise = ["env" .= toJSON entries]
  where
    entries =
      [ envEntry (envNameText name) scoped
      | (name, scoped) <- Map.toAscList env
      , Set.member Runtime (scoped ^. #scopes)
      ]

envEntry :: Text -> ScopedEnvVar -> Value
envEntry name scoped = case scoped ^. #value of
  EnvLiteral literal -> object ["name" .= name, "value" .= literal]
  EnvSecretRef secret ->
    object
      [ "name" .= name
      , "valueFrom"
          .= object
            [ "secretKeyRef"
                .= object ["name" .= secretNameText secret, "key" .= name]
            ]
      ]

-- | Render the standard requests/limits resource block, omitting empty parts.
resourcesPairs :: Maybe Resources -> [Pair]
resourcesPairs Nothing = []
resourcesPairs (Just resources)
  | null requests && null limits = []
  | otherwise = ["resources" .= object (requestBlock <> limitBlock)]
  where
    requests = quantities (resources ^. #cpu) (resources ^. #memory)
    limits = quantities (resources ^. #cpuLimit) (resources ^. #memoryLimit)
    requestBlock = if null requests then [] else ["requests" .= object requests]
    limitBlock = if null limits then [] else ["limits" .= object limits]
    quantities maybeCpu maybeMemory =
      maybe [] (\quantity -> ["cpu" .= quantityText quantity]) maybeCpu
        <> maybe [] (\quantity -> ["memory" .= quantityText quantity]) maybeMemory

-- | Build a deterministic YAML config from a context-specific key rank table.
-- A rank table is context-specific because the same key can occupy a different
-- position in a CronJob and a hardened Job, while the comparison algorithm is
-- shared and falls back to lexical order for unlisted keys.
batchConfig :: [(Text, Int)] -> YP.Config
batchConfig ranks = YP.setConfCompare compareKey YP.defConfig
  where
    compareKey left right = compare (rank left, left) (rank right, right)
    rank key = maybe maxBound id (lookup key ranks)
