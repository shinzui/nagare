{-# LANGUAGE PackageImports #-}

-- | Render a 'Database' to its Kubernetes manifest set (MasterPlan 9, IP2):
-- a StatefulSet, a ClusterIP Service, a PersistentVolumeClaim, and — for engines
-- that need server-side config (ClickHouse's memory cap) — a ConfigMap. The
-- managed credential Secret 'dbSecretName' is REFERENCED by name and key (via
-- @valueFrom.secretKeyRef@) but its data is NOT emitted: the password is
-- generated and written by EP-45 at create time. Every resource carries the IP3
-- labels @nagare.dev/managed-by@, @nagare.dev/database@, @nagare.dev/engine@ so
-- EP-45 and EP-47 can discover them.
--
-- The rendered shapes reproduce EP-43's verified manifests
-- (@docs/plans/43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md@):
-- Postgres pins @PGDATA@ to a subdirectory of the mount; Redis takes its password
-- as the @--requirepass@ server flag (the image does not read a password env var
-- on its own); ClickHouse exposes both the native (9000) and HTTP (8123) ports
-- and mounts a @config.d@ memory cap so it stays within the small VM.
module Nagare.Dsl.Database.Render
  ( renderDatabase
  , renderStatefulSet
  , renderDatabaseService
  , renderDatabasePvc
  , renderDatabaseConfigMap
  , statefulSetName
  , dbServiceName
  , dbPvcName
  , dbConfigMapName
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import "generic-lens" Data.Generics.Labels ()

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Database
import Nagare.Dsl.Types (Resources, namespaceText, quantityText)

-- ---------------------------------------------------------------------------
-- Deterministic resource names (single owners; EP-45/47 discover by label).

-- | StatefulSet name for a database (= the database name).
statefulSetName :: Text -> Text
statefulSetName n = n

-- | ClusterIP Service name = the database name (stable in-cluster DNS).
dbServiceName :: Text -> Text
dbServiceName n = n

-- | PVC name for a database's data disk.
dbPvcName :: Text -> Text
dbPvcName n = "nagare-db-" <> n <> "-data"

-- | ConfigMap name for an engine's server-side config (ClickHouse memory cap).
dbConfigMapName :: Text -> Text
dbConfigMapName n = "nagare-db-" <> n <> "-mem"

-- ---------------------------------------------------------------------------
-- Top-level: the manifest set, in apply order.

-- | Render every manifest a database needs, in the order EP-45 applies them
-- (PVC, then the optional ConfigMap, then the Service, then the StatefulSet;
-- EP-45 applies the credential Secret before all of these). Engines with no
-- extra config (Postgres, Redis) omit the ConfigMap.
renderDatabase :: Database -> [ByteString]
renderDatabase db =
  [renderDatabasePvc db]
    <> maybe [] (const [renderDatabaseConfigMap db]) (engineMemoryConfig (db ^. #engine))
    <> [renderDatabaseService db, renderStatefulSet db]

renderStatefulSet :: Database -> ByteString
renderStatefulSet = YP.encodePretty dbConfig . statefulSetValue

renderDatabaseService :: Database -> ByteString
renderDatabaseService = YP.encodePretty dbConfig . serviceValue

renderDatabasePvc :: Database -> ByteString
renderDatabasePvc = YP.encodePretty dbConfig . pvcValue

-- | Render the engine's server-side-config ConfigMap. Only meaningful for an
-- engine whose 'engineMemoryConfig' is 'Just'; for others it emits an empty
-- @data@ block (callers use 'renderDatabase', which omits it).
renderDatabaseConfigMap :: Database -> ByteString
renderDatabaseConfigMap = YP.encodePretty dbConfig . configMapValue

-- ---------------------------------------------------------------------------
-- Shared helpers.

txt :: Text -> Text
txt = id

nsText :: Database -> Text
nsText db = namespaceText (db ^. #namespace)

nameText :: Database -> Text
nameText db = databaseNameText (db ^. #dbName)

-- | The IP3 labels stamped on every rendered resource.
dbLabels :: Database -> Value
dbLabels db =
  object
    [ "nagare.dev/managed-by" .= txt "nagarectl"
    , "nagare.dev/database" .= nameText db
    , "nagare.dev/engine" .= engineToken (db ^. #engine)
    ]

metadataValue :: Text -> Database -> Value
metadataValue n db =
  object
    [ "name" .= n
    , "namespace" .= nsText db
    , "labels" .= dbLabels db
    ]

-- ---------------------------------------------------------------------------
-- StatefulSet.

statefulSetValue :: Database -> Value
statefulSetValue db =
  object
    [ "apiVersion" .= txt "apps/v1"
    , "kind" .= txt "StatefulSet"
    , "metadata" .= metadataValue (statefulSetName (nameText db)) db
    , "spec"
        .= object
          [ "serviceName" .= dbServiceName (nameText db)
          , "replicas" .= (1 :: Int)
          , "selector" .= object ["matchLabels" .= object ["nagare.dev/database" .= nameText db]]
          , "template"
              .= object
                [ "metadata" .= object ["labels" .= dbLabels db]
                , "spec"
                    .= object
                      [ "containers" .= toJSON [containerValue db]
                      , "volumes" .= toJSON (podVolumes db)
                      ]
                ]
          ]
    ]

containerValue :: Database -> Value
containerValue db =
  object
    ( [ "name" .= engineToken eng
      , "image" .= (engineImage eng <> ":" <> engineVersionText (db ^. #version))
      ]
        <> commandPairs eng
        <> ["ports" .= toJSON (map containerPort (enginePorts eng))]
        <> ["env" .= toJSON (credentialEnv db)]
        <> resourcesPairs (db ^. #resources)
        <> ["volumeMounts" .= toJSON (volumeMounts db)]
    )
  where
    eng = db ^. #engine
    containerPort (_, p) = object ["containerPort" .= p]

-- | Redis takes its password as the @--requirepass@ server flag (the image does
-- not read a password env var on its own — EP-43). Postgres and ClickHouse read
-- their credentials directly from the env, so they need no command override.
commandPairs :: Engine -> [Pair]
commandPairs Redis =
  [ "command" .= toJSON (["sh", "-c"] :: [Text])
  , "args"
      .= toJSON
        ( ["exec redis-server --requirepass \"$REDIS_PASSWORD\" --dir /data --save 60 1 --appendonly no"]
            :: [Text]
        )
  ]
commandPairs _ = []

-- | The container env: any engine-specific literal (Postgres's @PGDATA@
-- subdirectory) followed by one @valueFrom.secretKeyRef@ entry per startup
-- credential key (from the managed Secret 'dbSecretName').
credentialEnv :: Database -> [Value]
credentialEnv db = literalEnv eng <> map (secretEnvEntry secret) (engineStartupSecretKeys eng)
  where
    eng = db ^. #engine
    secret = dbSecretName (nameText db)

literalEnv :: Engine -> [Value]
literalEnv Postgres =
  [object ["name" .= txt "PGDATA", "value" .= txt "/var/lib/postgresql/data/pgdata"]]
literalEnv _ = []

secretEnvEntry :: Text -> Text -> Value
secretEnvEntry secret key =
  object
    [ "name" .= key
    , "valueFrom" .= object ["secretKeyRef" .= object ["name" .= secret, "key" .= key]]
    ]

-- | The container @volumeMounts@: the data disk at the engine data path, plus —
-- for ClickHouse — the memory-cap config file mounted into @config.d@.
volumeMounts :: Database -> [Value]
volumeMounts db =
  [object ["name" .= txt "data", "mountPath" .= engineDataPath eng]]
    <> case engineMemoryConfig eng of
      Just _ ->
        [ object
            [ "name" .= txt "config"
            , "mountPath" .= txt "/etc/clickhouse-server/config.d/low-memory.xml"
            , "subPath" .= txt "low-memory.xml"
            ]
        ]
      Nothing -> []
  where
    eng = db ^. #engine

-- | The pod @volumes@: the data PVC, plus — for ClickHouse — the config
-- ConfigMap.
podVolumes :: Database -> [Value]
podVolumes db =
  [ object
      [ "name" .= txt "data"
      , "persistentVolumeClaim" .= object ["claimName" .= dbPvcName (nameText db)]
      ]
  ]
    <> case engineMemoryConfig eng of
      Just _ ->
        [ object
            [ "name" .= txt "config"
            , "configMap" .= object ["name" .= dbConfigMapName (nameText db)]
            ]
        ]
      Nothing -> []
  where
    eng = db ^. #engine

-- | The @resources@ block (reuses the @requests@/@limits@ shape of the app
-- renderer): each sub-block omitted when it has no quantities; the whole block
-- omitted when 'resources' is absent or empty.
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
-- ClusterIP Service.

serviceValue :: Database -> Value
serviceValue db =
  object
    [ "apiVersion" .= txt "v1"
    , "kind" .= txt "Service"
    , "metadata" .= metadataValue (dbServiceName (nameText db)) db
    , "spec"
        .= object
          [ "type" .= txt "ClusterIP"
          , "selector" .= object ["nagare.dev/database" .= nameText db]
          , "ports" .= toJSON (map portEntry (enginePorts (db ^. #engine)))
          ]
    ]
  where
    portEntry (pn, p) = object ["name" .= pn, "port" .= p, "targetPort" .= p]

-- ---------------------------------------------------------------------------
-- PVC.

pvcValue :: Database -> Value
pvcValue db =
  object
    [ "apiVersion" .= txt "v1"
    , "kind" .= txt "PersistentVolumeClaim"
    , "metadata" .= metadataValue (dbPvcName (nameText db)) db
    , "spec"
        .= object
          [ "accessModes" .= toJSON (["ReadWriteOnce"] :: [Text])
          , "storageClassName" .= txt "local-path"
          , "resources" .= object ["requests" .= object ["storage" .= quantityText (db ^. #size)]]
          ]
    ]

-- ---------------------------------------------------------------------------
-- ConfigMap (ClickHouse memory cap).

configMapValue :: Database -> Value
configMapValue db =
  object
    [ "apiVersion" .= txt "v1"
    , "kind" .= txt "ConfigMap"
    , "metadata" .= metadataValue (dbConfigMapName (nameText db)) db
    , "data" .= object ["low-memory.xml" .= fromMaybe "" (engineMemoryConfig (db ^. #engine))]
    ]

-- ---------------------------------------------------------------------------
-- YAML key ordering (mirrors Nagare.Dsl.Render.knativeConfig's approach with a
-- local rank table for the StatefulSet/Service/PVC/ConfigMap key set).

dbConfig :: YP.Config
dbConfig = YP.setConfCompare keyCompare YP.defConfig

keyCompare :: Text -> Text -> Ordering
keyCompare a b = compare (rank a, a) (rank b, b)
  where
    rank :: Text -> Int
    rank k = maybe maxBound id (lookup k ranks)
    ranks :: [(Text, Int)]
    ranks =
      [ -- top-level document keys
        ("apiVersion", 0)
      , ("kind", 1)
      , ("metadata", 2)
      , ("spec", 3)
      , ("data", 4)
      , -- metadata
        ("name", 0)
      , ("namespace", 1)
      , ("labels", 2)
      , -- labels (non-alphabetical contract order)
        ("nagare.dev/managed-by", 0)
      , ("nagare.dev/database", 1)
      , ("nagare.dev/engine", 2)
      , -- StatefulSet spec
        ("serviceName", 0)
      , ("replicas", 1)
      , ("selector", 2)
      , ("template", 3)
      , ("matchLabels", 0)
      , -- pod spec
        ("containers", 0)
      , ("volumes", 1)
      , -- container
        ("image", 1)
      , ("command", 2)
      , ("args", 3)
      , ("ports", 4)
      , ("env", 5)
      , ("resources", 6)
      , ("volumeMounts", 7)
      , -- port entry
        ("containerPort", 1)
      , ("port", 2)
      , ("targetPort", 3)
      , -- env entry
        ("value", 1)
      , ("valueFrom", 2)
      , ("secretKeyRef", 0)
      , ("key", 1)
      , -- resources
        ("requests", 0)
      , ("limits", 1)
      , ("cpu", 0)
      , ("memory", 1)
      , ("storage", 0)
      , -- volumeMount entry
        ("mountPath", 1)
      , ("subPath", 2)
      , -- pod volume entry
        ("persistentVolumeClaim", 1)
      , ("configMap", 2)
      , ("claimName", 0)
      , -- PVC spec
        ("accessModes", 0)
      , ("storageClassName", 1)
      , -- Service spec
        ("type", 0)
      ]
