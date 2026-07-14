-- | Deterministically render a one-shot 'Job' and the two resources that
-- confine it: a tokenless ServiceAccount and a default-deny NetworkPolicy.
module Nagare.Dsl.Job.Render
  ( renderJob
  , renderJobServiceAccount
  , renderJobNetworkPolicy
  , renderJobManifest
  )
where

import Nagare.Dsl.Prelude hiding ((.=))

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString (ByteString)
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Batch.Render
  ( argvPairs
  , batchConfig
  , managedEnvFromPairs
  , resourcesPairs
  , runtimeEnvPairs
  )
import Nagare.Dsl.Build (resolveImageTag)
import Nagare.Dsl.Command (commandArgvList)
import Nagare.Dsl.Job
import Nagare.Dsl.Types
  ( Quantity
  , Resources (..)
  , imageRefText
  , mkQuantity
  , namespaceText
  , quantityText
  , serviceNameText
  )

-- | Render resources in apply order: ServiceAccount, NetworkPolicy, then Job.
renderJob :: Job -> Text -> [ByteString]
renderJob job deployTag =
  [ renderJobServiceAccount job
  , renderJobNetworkPolicy job
  , renderJobManifest job deployTag
  ]

renderJobServiceAccount :: Job -> ByteString
renderJobServiceAccount =
  YP.encodePretty (batchConfig serviceAccountKeyRanks) . serviceAccountValue

renderJobNetworkPolicy :: Job -> ByteString
renderJobNetworkPolicy =
  YP.encodePretty (batchConfig networkPolicyKeyRanks) . networkPolicyValue

renderJobManifest :: Job -> Text -> ByteString
renderJobManifest job deployTag =
  YP.encodePretty (batchConfig jobKeyRanks) (jobValue job deployTag)

logicalName :: Job -> Text
logicalName = serviceNameText . jobName

namespaceName :: Job -> Text
namespaceName = namespaceText . jobNamespace

resourceName :: Job -> Text
resourceName job = jobResourceName (logicalName job)

-- | Labels shared by the applied resources and Pod template. The cache opt-in
-- label is present only when a ConfigMap was explicitly selected.
jobLabels :: Job -> Value
jobLabels job = object (baseLabels <> nixCacheLabelPairs job)
  where
    baseLabels =
      [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
      , "nagare.dev/job" .= logicalName job
      ]

nixCacheLabelPairs :: Job -> [Pair]
nixCacheLabelPairs job = case jobNixConfigMap job of
  Nothing -> []
  Just _ -> ["nagare.dev/nix-cache-client" .= ("true" :: Text)]

jobSelectorLabels :: Job -> Value
jobSelectorLabels job = object ["nagare.dev/job" .= logicalName job]

metadataValue :: Job -> Value
metadataValue job =
  object
    [ "name" .= resourceName job
    , "namespace" .= namespaceName job
    , "labels" .= jobLabels job
    ]

serviceAccountValue :: Job -> Value
serviceAccountValue job =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("ServiceAccount" :: Text)
    , "metadata" .= metadataValue job
    , "automountServiceAccountToken" .= False
    ]

networkPolicyValue :: Job -> Value
networkPolicyValue job =
  object
    [ "apiVersion" .= ("networking.k8s.io/v1" :: Text)
    , "kind" .= ("NetworkPolicy" :: Text)
    , "metadata" .= metadataValue job
    , "spec"
        .= object
          [ "podSelector" .= object ["matchLabels" .= jobSelectorLabels job]
          , "policyTypes" .= toJSON (["Ingress", "Egress"] :: [Text])
          , "ingress" .= toJSON ([] :: [Value])
          , "egress" .= toJSON ([] :: [Value])
          ]
    ]

jobValue :: Job -> Text -> Value
jobValue job deployTag =
  object
    [ "apiVersion" .= ("batch/v1" :: Text)
    , "kind" .= ("Job" :: Text)
    , "metadata" .= metadataValue job
    , "spec"
        .= object
          ( [ "parallelism" .= (1 :: Int)
            , "completions" .= (1 :: Int)
            , "backoffLimit" .= jobBackoffLimit job
            ]
              <> activeDeadlinePairs job
              <> ttlPairs job
              <> ["template" .= podTemplateValue job deployTag]
          )
    ]

activeDeadlinePairs :: Job -> [Pair]
activeDeadlinePairs job = case jobActiveDeadlineSeconds job of
  Nothing -> []
  Just seconds -> ["activeDeadlineSeconds" .= seconds]

ttlPairs :: Job -> [Pair]
ttlPairs job = case jobTtlSecondsAfterFinished job of
  Nothing -> []
  Just seconds -> ["ttlSecondsAfterFinished" .= seconds]

podTemplateValue :: Job -> Text -> Value
podTemplateValue job deployTag =
  object
    [ "metadata" .= object ["labels" .= jobLabels job]
    , "spec"
        .= object
          ( [ "restartPolicy" .= ("Never" :: Text)
            , "serviceAccountName" .= resourceName job
            , "automountServiceAccountToken" .= False
            ]
              <> activeDeadlinePairs job
              <> [ "securityContext" .= podSecurityContext
                 , "containers" .= toJSON [containerValue job deployTag]
                 , "volumes" .= toJSON (volumeValues job)
                 ]
          )
    ]

podSecurityContext :: Value
podSecurityContext =
  object
    [ "runAsNonRoot" .= True
    , "runAsUser" .= (65532 :: Int)
    , "seccompProfile" .= object ["type" .= ("RuntimeDefault" :: Text)]
    ]

containerValue :: Job -> Text -> Value
containerValue job deployTag =
  object
    ( [ "name" .= logicalName job
      , "image" .= resolvedImage
      ]
        <> maybe [] (argvPairs . commandArgvList) (jobCommand job)
        <> runtimeEnvPairs (jobEnv job)
        <> managedEnvFromPairs (logicalName job)
        <> resourcesPairs (Just (effectiveResources job))
        <> [ "securityContext" .= containerSecurityContext
           , "volumeMounts" .= toJSON (volumeMountValues job)
           ]
    )
  where
    resolvedImage =
      imageRefText (jobImage job)
        <> ":"
        <> resolveImageTag (jobBuild job) deployTag

effectiveResources :: Job -> Resources
effectiveResources job = fromMaybe defaultJobResources (jobResources job)

defaultJobResources :: Resources
defaultJobResources =
  Resources
    { cpu = Just (quantity "250m")
    , memory = Just (quantity "512Mi")
    , cpuLimit = Just (quantity "1")
    , memoryLimit = Just (quantity "1Gi")
    }

quantity :: Text -> Quantity
quantity value = case mkQuantity value of
  Left err -> error ("invalid static Job resource quantity: " <> show err)
  Right result -> result

containerSecurityContext :: Value
containerSecurityContext =
  object
    [ "readOnlyRootFilesystem" .= True
    , "allowPrivilegeEscalation" .= False
    , "capabilities" .= object ["drop" .= toJSON (["ALL"] :: [Text])]
    ]

volumeMountValues :: Job -> [Value]
volumeMountValues job = scratchMount : nixMounts
  where
    scratchMount =
      object
        [ "name" .= ("scratch" :: Text)
        , "mountPath" .= ("/scratch" :: Text)
        , "readOnly" .= False
        ]
    nixMounts = case jobNixConfigMap job of
      Nothing -> []
      Just _ ->
        [ object
            [ "name" .= ("nix-config" :: Text)
            , "mountPath" .= ("/etc/nix/nix.conf" :: Text)
            , "subPath" .= ("nix.conf" :: Text)
            , "readOnly" .= True
            ]
        ]

volumeValues :: Job -> [Value]
volumeValues job = scratchVolume : nixVolumes
  where
    scratchVolume =
      object
        [ "name" .= ("scratch" :: Text)
        , "emptyDir"
            .= object ["sizeLimit" .= quantityText (jobScratchSize job)]
        ]
    nixVolumes = case jobNixConfigMap job of
      Nothing -> []
      Just configMap ->
        [ object
            [ "name" .= ("nix-config" :: Text)
            , "configMap"
                .= object
                  [ "name" .= configMapNameText configMap
                  , "items"
                      .= toJSON
                        [ object
                            [ "key" .= ("nix.conf" :: Text)
                            , "path" .= ("nix.conf" :: Text)
                            ]
                        ]
                  ]
            ]
        ]

serviceAccountKeyRanks :: [(Text, Int)]
serviceAccountKeyRanks =
  commonTopLevelRanks
    <> [("automountServiceAccountToken", 3)]
    <> commonMetadataRanks
    <> commonLabelRanks

networkPolicyKeyRanks :: [(Text, Int)]
networkPolicyKeyRanks =
  commonTopLevelRanks
    <> commonMetadataRanks
    <> commonLabelRanks
    <> [ ("podSelector", 0)
       , ("matchLabels", 0)
       , ("policyTypes", 1)
       , ("ingress", 2)
       , ("egress", 3)
       ]

jobKeyRanks :: [(Text, Int)]
jobKeyRanks =
  commonTopLevelRanks
    <> commonMetadataRanks
    <> commonLabelRanks
    <> [ -- Job spec
         ("parallelism", 0)
       , ("completions", 1)
       , ("backoffLimit", 2)
       , ("activeDeadlineSeconds", 3)
       , ("ttlSecondsAfterFinished", 4)
       , ("template", 8)
       , -- Pod spec and container
         ("restartPolicy", 0)
       , ("serviceAccountName", 1)
       , ("automountServiceAccountToken", 2)
       , ("image", 1)
       , ("command", 2)
       , ("env", 3)
       , ("envFrom", 4)
       , ("resources", 5)
       , ("securityContext", 6)
       , ("containers", 7)
       , ("volumeMounts", 7)
       , ("volumes", 8)
       , -- Pod security
         ("runAsNonRoot", 0)
       , ("runAsUser", 1)
       , ("seccompProfile", 2)
       , ("type", 0)
       , -- Container security
         ("readOnlyRootFilesystem", 0)
       , ("allowPrivilegeEscalation", 1)
       , ("capabilities", 2)
       , ("drop", 0)
       , -- env and envFrom
         ("configMapRef", 0)
       , ("secretRef", 1)
       , ("optional", 1)
       , ("value", 1)
       , ("valueFrom", 2)
       , ("secretKeyRef", 0)
       , ("key", 1)
       , -- resources
         ("requests", 0)
       , ("limits", 1)
       , ("cpu", 0)
       , ("memory", 1)
       , -- mounts and volumes
         ("mountPath", 1)
       , ("subPath", 2)
       , ("readOnly", 3)
       , ("emptyDir", 1)
       , ("configMap", 1)
       , ("sizeLimit", 0)
       , ("items", 1)
       , ("path", 1)
       ]

commonTopLevelRanks :: [(Text, Int)]
commonTopLevelRanks =
  [ ("apiVersion", 0)
  , ("kind", 1)
  , ("metadata", 2)
  , ("spec", 3)
  ]

commonMetadataRanks :: [(Text, Int)]
commonMetadataRanks =
  [ ("name", 0)
  , ("namespace", 1)
  , ("labels", 2)
  ]

commonLabelRanks :: [(Text, Int)]
commonLabelRanks =
  [ ("nagare.dev/managed-by", 0)
  , ("nagare.dev/job", 1)
  , ("nagare.dev/nix-cache-client", 2)
  ]
