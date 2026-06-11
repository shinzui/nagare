{-# LANGUAGE PackageImports #-}

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

    -- * The full Job @.spec@ body
  , DataMovementJob (..)
  , dataMovementJobSpec
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Text (Text)

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

-- | The parts of a GCS data-movement Job that vary across renderers. The shared
-- scaffolding (@restartPolicy: Never@, @backoffLimit: 0@, the metadata
-- @hostAliases@) is supplied by 'dataMovementJobSpec'; the caller supplies only
-- the variable pieces.
data DataMovementJob = DataMovementJob
  { dmjTemplateLabels :: !(Maybe Value)
  -- ^ optional pod-template @metadata.labels@ (snapshot omits these)
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
-- not change any rendered manifest's bytes. @initContainers@ is omitted entirely
-- when empty (snapshot/volume-restore have none), preserving their current shape.
dataMovementJobSpec :: DataMovementJob -> Value
dataMovementJobSpec j =
  object
    [ "backoffLimit" .= (0 :: Int)
    , "template"
        .= object
          ( maybe [] (\ls -> ["metadata" .= object ["labels" .= ls]]) (dmjTemplateLabels j)
              ++ [ "spec"
                     .= object
                       ( [ "restartPolicy" .= ("Never" :: Text)
                         , "hostAliases" .= metadataHostAliases
                         ]
                           ++ ["initContainers" .= toJSON (dmjInitContainers j) | not (null (dmjInitContainers j))]
                           ++ [ "containers" .= toJSON (dmjContainers j)
                              , "volumes" .= toJSON (dmjVolumes j)
                              ]
                       )
                 ]
          )
    ]
