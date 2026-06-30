-- | The canonical pod scaffolding for a Kubernetes Job that moves data to or from
-- Google Cloud Storage (GCS) using the node service account's Application Default
-- Credentials (ADC). MasterPlan 13 / EP-1 Integration Point IP1.
--
-- Several @nagarectl@ verbs (@db backup@, @db restore@, @storage snapshot@, and
-- the new @storage restore@) render a short-lived @batch/v1@ Job whose container
-- is @google/cloud-sdk:slim@ and which authenticates to GCS via ADC: it asks the
-- GCE metadata server (the link-local IP @169.254.169.254@) for an access token
-- minted from the VM's attached service account. The @gsutil@/@gcloud@ tools look
-- the metadata server up by its canonical DNS name @metadata.google.internal@,
-- which a pod cannot resolve through cluster DNS — so the pod spec needs a
-- @hostAliases@ entry mapping that name to the metadata IP, plus the env pair
-- @GCE_METADATA_HOST=169.254.169.254@ / @CLOUDSDK_CORE_PROJECT=\<project\>@.
--
-- On 2026-06-10 a live audit found this scaffolding had been copied into some
-- renderers and was missing from others (volume snapshot, volume restore), which
-- failed live with @401 Anonymous@. This module renders that scaffolding /exactly
-- once/ so the bug cannot recur in one path while another is fixed.
--
-- It sits __below__ both @Nagare.Database.*@ and @Nagare.Storage.*@ in the module
-- graph and imports neither: @Database.Backup@/@Database.Restore@ already import
-- @Storage.Snapshot@, so the helper could not live in either of those branches
-- without forming an import cycle. A new leaf module nobody below it imports
-- breaks the knot. The @Cluster@ namespace reflects that this is about the
-- Kubernetes pod shape, not about databases or storage specifically.
module Nagare.Cluster.GcsJob
  ( -- * Canonical scaffolding fragments
    metadataHostAliases
  , metadataEnv
  , gcsContainerImage

    -- * The object-store backend (EP-84, MasterPlan 16 Integration Point 3)
  , StoreBackend (..)
  , MinioRef (..)
  , minioContainerImage
  , parseLocalObjectStore
  , storeImage
  , storeHostAliases
  , storeEnv
  , storeObjectUrl
  , storePrefixUrl
  , storeCpFromStdin
  , storeCpToStdout
  , storeLs
  , storeRmStdin

    -- * The full Job @.spec@ body
  , DataMovementJob (..)
  , dataMovementJobSpec
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Text (Text)
import qualified Data.Text as T

-- | A @hostAliases@ entry mapping @metadata.google.internal@ to the GCE metadata
-- IP, so @gcloud@/@gsutil@ (which look up the canonical name) find the metadata
-- server. Pods cannot resolve that name via cluster DNS; the node's /32 route
-- (nixos networking.nix) makes the IP reachable, and this maps the name to it.
-- Without it the pod's ADC falls back to anonymous access and GCS returns 401.
metadataHostAliases :: Value
metadataHostAliases =
  toJSON
    [ object
        [ "ip" .= ("169.254.169.254" :: Text)
        , "hostnames" .= toJSON (["metadata.google.internal"] :: [Text])
        ]
    ]

-- | The two env entries every GCS data-movement container needs, given the GCP
-- project: @GCE_METADATA_HOST@ (so @gcloud@/@gsutil@ reach the metadata server by
-- IP) and @CLOUDSDK_CORE_PROJECT@ (the in-cluster analogue of the shell
-- project-isolation preflight). Callers append this to their data-specific env.
metadataEnv :: Text -> [Value]
metadataEnv project =
  [ object ["name" .= ("GCE_METADATA_HOST" :: Text), "value" .= ("169.254.169.254" :: Text)]
  , object ["name" .= ("CLOUDSDK_CORE_PROJECT" :: Text), "value" .= project]
  ]

-- | The container image shared by every GCS data-movement Job: it ships
-- @gsutil@, @gcloud@, @tar@, and @gzip@.
gcsContainerImage :: Text
gcsContainerImage = "google/cloud-sdk:slim"

-- | The container image for every local (MinIO) data-movement Job: it ships
-- @aws s3@ on an Amazon Linux base that also carries @tar@ and @gzip@, so the
-- snapshot/backup shells need no change beyond the binary + @--endpoint-url@.
minioContainerImage :: Text
minioContainerImage = "amazon/aws-cli:latest"

-- ---------------------------------------------------------------------------
-- The object-store backend (EP-84, MasterPlan 16 Integration Point 3)

-- | Where a data-movement Job sends/reads bytes. Constructed __once__ from the
-- resolved mode ('Nagare.Target.tpMode') and threaded everywhere else as data,
-- so the "which store?" decision lives in exactly one place and the four verbs
-- ('db backup', 'db restore', 'storage snapshot', 'storage restore') cannot
-- drift apart. In cloud mode the rendered Job is byte-for-byte what it was
-- before EP-84.
data StoreBackend
  = -- | Cloud: the GCP project (for @CLOUDSDK_CORE_PROJECT@) and the GCS bucket.
    GcsBackend !Text !Text
  | -- | Local: the in-cluster MinIO endpoint, bucket, and credentials Secret.
    MinioBackend !MinioRef
  deriving stock (Eq, Show)

-- | The in-cluster MinIO target: the S3 endpoint URL, the bucket, and the name
-- of the Kubernetes Secret holding @AWS_ACCESS_KEY_ID@ / @AWS_SECRET_ACCESS_KEY@.
data MinioRef = MinioRef
  { mrEndpoint :: !Text
  -- ^ e.g. @http://minio.nagare-system.svc.cluster.local:9000@
  , mrBucket :: !Text
  -- ^ the bucket, from @NAGARE_LOCAL_OBJECT_STORE@
  , mrSecretName :: !Text
  -- ^ k8s Secret with @AWS_ACCESS_KEY_ID@ / @AWS_SECRET_ACCESS_KEY@
  }
  deriving stock (Eq, Show)

-- | Parse @NAGARE_LOCAL_OBJECT_STORE@ (form @"\<endpoint>/\<bucket>"@) into its
-- @(endpoint, bucket)@ parts by splitting on the last @/@. The endpoint keeps
-- its scheme (@http://minio…:9000@); the final path segment is the bucket.
-- Returns 'Nothing' when either part is empty (e.g. the variable is unset).
parseLocalObjectStore :: Text -> Maybe (Text, Text)
parseLocalObjectStore raw =
  let (beforeBucket, bucket) = T.breakOnEnd "/" raw
      endpoint = T.dropWhileEnd (== '/') beforeBucket
  in if T.null endpoint || T.null bucket then Nothing else Just (endpoint, bucket)

-- | The data-movement container image for the backend.
storeImage :: StoreBackend -> Text
storeImage GcsBackend {} = gcsContainerImage
storeImage MinioBackend {} = minioContainerImage

-- | The pod-level @hostAliases@: 'Just' the metadata alias for GCS (so ADC can
-- reach the GCE metadata server), 'Nothing' for MinIO (there is no metadata
-- server on a laptop, and the in-cluster MinIO is reached by its Service DNS).
storeHostAliases :: StoreBackend -> Maybe Value
storeHostAliases GcsBackend {} = Just metadataHostAliases
storeHostAliases MinioBackend {} = Nothing

-- | The data-movement container's store-credential env. For GCS this is the
-- metadata env ('metadataEnv', byte-for-byte the cloud path). For MinIO it is
-- the AWS creds via @secretKeyRef@ plus the region/metadata-disable settings the
-- @aws@ client needs to talk to a static endpoint with no instance metadata.
storeEnv :: StoreBackend -> [Value]
storeEnv (GcsBackend project _) = metadataEnv project
storeEnv (MinioBackend ref) =
  [ secretRefEnv "AWS_ACCESS_KEY_ID" (mrSecretName ref) "AWS_ACCESS_KEY_ID"
  , secretRefEnv "AWS_SECRET_ACCESS_KEY" (mrSecretName ref) "AWS_SECRET_ACCESS_KEY"
  , object ["name" .= ("AWS_DEFAULT_REGION" :: Text), "value" .= ("us-east-1" :: Text)]
  , object ["name" .= ("AWS_EC2_METADATA_DISABLED" :: Text), "value" .= ("true" :: Text)]
  ]
  where
    secretRefEnv n secret key =
      object
        [ "name" .= (n :: Text)
        , "valueFrom" .= object ["secretKeyRef" .= object ["name" .= secret, "key" .= (key :: Text)]]
        ]

-- | The full object URL for a stable key (@"databases/…"@ / @"volumes/…"@):
-- @gs://\<bucket>/\<key>@ for GCS, @s3://\<bucket>/\<key>@ for MinIO. The key
-- layout is identical across backends (EP-84 Decision Log).
storeObjectUrl :: StoreBackend -> Text -> Text
storeObjectUrl b key = storeScheme b <> storeBucket b <> "/" <> key

-- | The full object URL for a listing prefix (a key prefix ending in @/@).
storePrefixUrl :: StoreBackend -> Text -> Text
storePrefixUrl = storeObjectUrl

storeScheme :: StoreBackend -> Text
storeScheme GcsBackend {} = "gs://"
storeScheme MinioBackend {} = "s3://"

storeBucket :: StoreBackend -> Text
storeBucket (GcsBackend _ bucket) = bucket
storeBucket (MinioBackend ref) = mrBucket ref

-- | Copy stdin to the object named by @destExpr@ (a shell expression, e.g.
-- @"\\"$DEST\\""@). GCS uses @gsutil@; MinIO uses @aws s3 … --endpoint-url@.
storeCpFromStdin :: StoreBackend -> Text -> Text
storeCpFromStdin GcsBackend {} destExpr =
  "gsutil -o GSUtil:parallel_composite_upload_threshold=150M cp - " <> destExpr
storeCpFromStdin (MinioBackend ref) destExpr =
  "aws s3 cp - " <> destExpr <> " --endpoint-url " <> mrEndpoint ref

-- | Copy the object named by @srcExpr@ to stdout.
storeCpToStdout :: StoreBackend -> Text -> Text
storeCpToStdout GcsBackend {} srcExpr = "gsutil cp " <> srcExpr <> " -"
storeCpToStdout (MinioBackend ref) srcExpr =
  "aws s3 cp " <> srcExpr <> " - --endpoint-url " <> mrEndpoint ref

-- | List the objects under @prefixExpr@, one name per line, newest-sortable by
-- the timestamp tail. GCS lists full @gs://@ URLs (which 'storeRmStdin' for GCS
-- consumes directly); MinIO lists bare basenames (which its 'storeRmStdin'
-- re-qualifies against @$PREFIX@) — each backend's listing matches its own
-- delete, so @storeLs … | sort -r | tail | storeRmStdin@ works for both.
storeLs :: StoreBackend -> Text -> Text
storeLs GcsBackend {} prefixExpr = "gsutil ls " <> prefixExpr
storeLs (MinioBackend ref) prefixExpr =
  "aws s3 ls " <> prefixExpr <> " --endpoint-url " <> mrEndpoint ref <> " | awk '{print $NF}'"

-- | Delete the objects whose names are read on stdin. GCS reads full URLs
-- (@gsutil -m rm -I@); MinIO reads basenames and re-qualifies them against the
-- @$PREFIX@ env var the upload container exports.
storeRmStdin :: StoreBackend -> Text
storeRmStdin GcsBackend {} = "gsutil -m rm -I"
storeRmStdin (MinioBackend ref) =
  "while read k; do aws s3 rm \"$PREFIX$k\" --endpoint-url " <> mrEndpoint ref <> "; done"

-- | The parts of a GCS data-movement Job that vary across renderers. The shared
-- scaffolding (@restartPolicy: Never@, @backoffLimit: 0@, the metadata
-- @hostAliases@) is supplied by 'dataMovementJobSpec'; the caller supplies only
-- the variable pieces.
data DataMovementJob = DataMovementJob
  { dmjTemplateLabels :: !(Maybe Value)
  -- ^ optional pod-template @metadata.labels@ (snapshot omits these)
  , dmjHostAliases :: !(Maybe Value)
  -- ^ the pod @hostAliases@: 'Just' 'metadataHostAliases' for the GCS backend
  -- (so ADC reaches the metadata server), 'Nothing' for the MinIO backend.
  -- Supply @storeHostAliases backend@. When 'Nothing' the key is omitted
  -- entirely, so the rendered pod spec carries no @hostAliases@ at all.
  , dmjInitContainers :: ![Value]
  -- ^ zero or more initContainers (db backup/restore have one; volume jobs none)
  , dmjContainers :: ![Value]
  -- ^ one or more containers
  , dmjVolumes :: ![Value]
  -- ^ pod volumes (an @emptyDir@ scratch for db jobs; a PVC for volume jobs)
  }

-- | Assemble the full Job @.spec@ body from the per-Job variation. The field
-- order (@restartPolicy@, @hostAliases@, then @initContainers@, @containers@,
-- @volumes@) matches the existing renderers so refactoring onto this module does
-- not change any rendered manifest's bytes. @hostAliases@ is omitted when
-- 'dmjHostAliases' is 'Nothing' (the MinIO backend); supplying
-- @Just metadataHostAliases@ keeps the cloud bytes unchanged. @initContainers@
-- is omitted entirely when empty (snapshot/volume-restore have none), preserving
-- their current shape.
dataMovementJobSpec :: DataMovementJob -> Value
dataMovementJobSpec j =
  object
    [ "backoffLimit" .= (0 :: Int)
    , "template"
        .= object
          ( maybe [] (\ls -> ["metadata" .= object ["labels" .= ls]]) (dmjTemplateLabels j)
              ++ [ "spec"
                     .= object
                       ( [ "restartPolicy" .= ("Never" :: Text) ]
                           ++ maybe [] (\ha -> ["hostAliases" .= ha]) (dmjHostAliases j)
                           ++ ["initContainers" .= toJSON (dmjInitContainers j) | not (null (dmjInitContainers j))]
                           ++ [ "containers" .= toJSON (dmjContainers j)
                              , "volumes" .= toJSON (dmjVolumes j)
                              ]
                       )
                 ]
          )
    ]
