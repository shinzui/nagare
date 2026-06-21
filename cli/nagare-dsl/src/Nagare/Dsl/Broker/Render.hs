-- | Render broker manifests from the provider-neutral 'Broker' model.
--
-- Redpanda is the only provider rendered in v1. The resource names and labels
-- are Nagare-owned so later lifecycle and observability code can discover
-- brokers without parsing Redpanda-specific details.
module Nagare.Dsl.Broker.Render
  ( renderBroker
  , renderBrokerStatefulSet
  , renderBrokerService
  , renderBrokerPvc
  , brokerStatefulSetName
  , brokerServiceName
  , brokerPvcName
  , brokerBootstrapServers
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Broker
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (Resources, namespaceText, quantityText)
import "generic-lens" Data.Generics.Labels ()

renderBroker :: Broker -> [ByteString]
renderBroker broker =
  case broker ^. #provider of
    Redpanda -> [renderBrokerPvc broker, renderBrokerService broker, renderBrokerStatefulSet broker]
    Tansu -> error "Tansu broker rendering is reserved for a future provider implementation"

renderBrokerStatefulSet :: Broker -> ByteString
renderBrokerStatefulSet = YP.encodePretty brokerConfig . statefulSetValue

renderBrokerService :: Broker -> ByteString
renderBrokerService = YP.encodePretty brokerConfig . serviceValue

renderBrokerPvc :: Broker -> ByteString
renderBrokerPvc = YP.encodePretty brokerConfig . pvcValue

brokerStatefulSetName :: Text -> Text
brokerStatefulSetName = id

brokerServiceName :: Text -> Text
brokerServiceName = id

brokerPvcName :: Text -> Text
brokerPvcName n = "nagare-broker-" <> n <> "-data"

brokerBootstrapServers :: Broker -> Text
brokerBootstrapServers broker =
  brokerServiceName (nameText broker)
    <> "."
    <> nsText broker
    <> ".svc.cluster.local:"
    <> tshow (brokerProviderKafkaPort (broker ^. #provider))

txt :: Text -> Text
txt = id

nameText :: Broker -> Text
nameText broker = brokerNameText (broker ^. #name)

nsText :: Broker -> Text
nsText broker = namespaceText (broker ^. #namespace)

providerText :: Broker -> Text
providerText broker = brokerProviderToken (broker ^. #provider)

brokerLabels :: Broker -> Value
brokerLabels broker =
  object
    [ "nagare.dev/managed-by" .= txt "nagarectl"
    , "nagare.dev/broker" .= nameText broker
    , "nagare.dev/broker-provider" .= providerText broker
    ]

podLabels :: Broker -> Value
podLabels broker =
  object
    [ "app.kubernetes.io/name" .= providerText broker
    , "nagare.dev/managed-by" .= txt "nagarectl"
    , "nagare.dev/broker" .= nameText broker
    , "nagare.dev/broker-provider" .= providerText broker
    ]

metadataValue :: Text -> Broker -> Value
metadataValue n broker =
  object
    [ "name" .= n
    , "namespace" .= nsText broker
    , "labels" .= brokerLabels broker
    ]

statefulSetValue :: Broker -> Value
statefulSetValue broker =
  object
    [ "apiVersion" .= txt "apps/v1"
    , "kind" .= txt "StatefulSet"
    , "metadata" .= metadataValue (brokerStatefulSetName (nameText broker)) broker
    , "spec"
        .= object
          [ "serviceName" .= brokerServiceName (nameText broker)
          , "replicas" .= (1 :: Int)
          , "selector"
              .= object
                [ "matchLabels"
                    .= object
                      [ "app.kubernetes.io/name" .= providerText broker
                      , "nagare.dev/broker" .= nameText broker
                      ]
                ]
          , "template"
              .= object
                [ "metadata" .= object ["labels" .= podLabels broker]
                , "spec"
                    .= object
                      [ "terminationGracePeriodSeconds" .= (30 :: Int)
                      , "securityContext"
                          .= object
                            [ "fsGroup" .= (101 :: Int)
                            , "fsGroupChangePolicy" .= txt "OnRootMismatch"
                            ]
                      , "containers" .= toJSON [redpandaContainer broker]
                      , "volumes" .= toJSON [dataVolume broker]
                      ]
                ]
          ]
    ]

redpandaContainer :: Broker -> Value
redpandaContainer broker =
  object
    ( [ "name" .= txt "redpanda"
      , "image" .= (brokerProviderImage Redpanda <> ":" <> brokerVersionText (broker ^. #version))
      , "imagePullPolicy" .= txt "IfNotPresent"
      , "command" .= toJSON redpandaCommand
      , "ports" .= toJSON redpandaPorts
      ]
        <> resourcesPairs (broker ^. #sizing . #resources)
        <> [ "startupProbe" .= readinessProbe 60
           , "readinessProbe" .= readinessProbe 6
           , "volumeMounts"
               .= toJSON
                 [ object
                     [ "name" .= txt "data"
                     , "mountPath" .= txt "/var/lib/redpanda/data"
                     ]
                 ]
           ]
    )
  where
    sizing' = broker ^. #sizing
    redpandaCommand =
      [ "/usr/bin/rpk"
      , "redpanda"
      , "start"
      , "--mode"
      , "dev-container"
      , "--smp"
      , tshow (smp sizing')
      , "--memory"
      , quantityText (memory sizing')
      , "--reserve-memory"
      , "0M"
      , "--overprovisioned"
      , "--node-id"
      , "0"
      , "--kafka-addr"
      , "internal://0.0.0.0:9092"
      , "--advertise-kafka-addr"
      , "internal://" <> brokerBootstrapServers broker
      , "--rpc-addr"
      , "0.0.0.0:33145"
      , "--advertise-rpc-addr"
      , nameText broker
          <> "-0."
          <> brokerServiceName (nameText broker)
          <> "."
          <> nsText broker
          <> ".svc.cluster.local:33145"
      , "--set"
      , "redpanda.empty_seed_starts_cluster=true"
      , "--set"
      , "redpanda.auto_create_topics_enabled=false"
      ]
    redpandaPorts =
      [ object ["name" .= txt "kafka", "containerPort" .= (9092 :: Int)]
      , object ["name" .= txt "admin", "containerPort" .= (9644 :: Int)]
      , object ["name" .= txt "rpc", "containerPort" .= (33145 :: Int)]
      ]

readinessProbe :: Int -> Value
readinessProbe failureThreshold =
  object
    [ "httpGet"
        .= object
          [ "path" .= txt "/v1/status/ready"
          , "port" .= txt "admin"
          ]
    , "failureThreshold" .= failureThreshold
    , "periodSeconds" .= (5 :: Int)
    ]

dataVolume :: Broker -> Value
dataVolume broker =
  object
    [ "name" .= txt "data"
    , "persistentVolumeClaim" .= object ["claimName" .= brokerPvcName (nameText broker)]
    ]

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

serviceValue :: Broker -> Value
serviceValue broker =
  object
    [ "apiVersion" .= txt "v1"
    , "kind" .= txt "Service"
    , "metadata" .= metadataValue (brokerServiceName (nameText broker)) broker
    , "spec"
        .= object
          [ "type" .= txt "ClusterIP"
          , "selector"
              .= object
                [ "app.kubernetes.io/name" .= providerText broker
                , "nagare.dev/broker" .= nameText broker
                ]
          , "ports"
              .= toJSON
                [ object
                    [ "name" .= txt "kafka"
                    , "port" .= brokerProviderKafkaPort (broker ^. #provider)
                    , "targetPort" .= txt "kafka"
                    ]
                , object
                    [ "name" .= txt "admin"
                    , "port" .= (9644 :: Int)
                    , "targetPort" .= txt "admin"
                    ]
                ]
          ]
    ]

pvcValue :: Broker -> Value
pvcValue broker =
  object
    [ "apiVersion" .= txt "v1"
    , "kind" .= txt "PersistentVolumeClaim"
    , "metadata" .= metadataValue (brokerPvcName (nameText broker)) broker
    , "spec"
        .= object
          [ "accessModes" .= toJSON (["ReadWriteOnce"] :: [Text])
          , "storageClassName" .= txt "local-path"
          , "resources" .= object ["requests" .= object ["storage" .= quantityText (broker ^. #storageSize)]]
          ]
    ]

brokerConfig :: YP.Config
brokerConfig = YP.setConfCompare keyCompare YP.defConfig

keyCompare :: Text -> Text -> Ordering
keyCompare a b = compare (rank a, a) (rank b, b)
  where
    rank :: Text -> Int
    rank k = maybe maxBound id (lookup k ranks)
    ranks :: [(Text, Int)]
    ranks =
      [ ("apiVersion", 0)
      , ("kind", 1)
      , ("metadata", 2)
      , ("spec", 3)
      , ("name", 0)
      , ("namespace", 1)
      , ("labels", 2)
      , ("nagare.dev/managed-by", 0)
      , ("nagare.dev/broker", 1)
      , ("nagare.dev/broker-provider", 2)
      , ("app.kubernetes.io/name", 0)
      , ("serviceName", 0)
      , ("replicas", 1)
      , ("selector", 2)
      , ("template", 3)
      , ("matchLabels", 0)
      , ("terminationGracePeriodSeconds", 0)
      , ("securityContext", 1)
      , ("containers", 2)
      , ("volumes", 3)
      , ("fsGroup", 0)
      , ("fsGroupChangePolicy", 1)
      , ("image", 1)
      , ("imagePullPolicy", 2)
      , ("command", 3)
      , ("ports", 4)
      , ("resources", 5)
      , ("startupProbe", 6)
      , ("readinessProbe", 7)
      , ("volumeMounts", 8)
      , ("containerPort", 1)
      , ("port", 2)
      , ("targetPort", 3)
      , ("requests", 0)
      , ("limits", 1)
      , ("cpu", 0)
      , ("memory", 1)
      , ("storage", 0)
      , ("httpGet", 0)
      , ("path", 0)
      , ("failureThreshold", 1)
      , ("periodSeconds", 2)
      , ("mountPath", 1)
      , ("persistentVolumeClaim", 1)
      , ("claimName", 0)
      , ("accessModes", 0)
      , ("storageClassName", 1)
      , ("type", 0)
      ]

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
