{-# LANGUAGE OverloadedStrings #-}

-- | GCS Pulumi state-bucket bootstrap (EP-93). This is the __one__ place nagarectl
-- creates or updates the remote Pulumi state bucket for a @mode=cloud@ context that
-- opts into @NAGARE_PULUMI_BACKEND=gcs@. The bucket is a bootstrap prerequisite —
-- Pulumi must be able to reach its backend before it can run the program whose state
-- it stores — so it lives here, in @nagarectl init@ / @nagarectl context@, NOT in the
-- Pulumi program (@infra/pulumi/index.ts@).
--
-- The argv builders are pure and unit-tested; 'bootstrapPulumiStateBucket' is the
-- idempotent IO runner (describe → create-if-missing → update → optional IAM grant),
-- with a dry-run mode that prints the exact @gcloud storage@ commands.
module Nagare.Ops.PulumiBackend
  ( gcsBucketOfUrl
  , pulumiStateBackendUrl
  , pulumiStateBucket
  , bucketDescribeArgs
  , bucketCreateArgs
  , bucketUpdateArgs
  , bucketIamArgs
  , bootstrapCommands
  , bootstrapPulumiStateBucket
  ) where

import Data.Function ((&))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

import Cradle (addArgs, cmd, run)

import Nagare.Target
  ( PulumiBackendKind (..)
  , TargetProfile (..)
  , defaultGcsPulumiBackendUrl
  , effectivePulumiBackend
  )

-- | Parse the bucket out of a @gs://\<bucket>/\<path>@ URL. 'Nothing' if the URL is
-- not a @gs://@ URL or names no bucket.
gcsBucketOfUrl :: Text -> Maybe Text
gcsBucketOfUrl url = do
  rest <- T.stripPrefix "gs://" url
  let bucket = T.takeWhile (/= '/') rest
  if T.null bucket then Nothing else Just bucket

-- | The resolved @gs://@ backend URL for a context: the explicit
-- 'tpPulumiBackendUrl' when set, else 'defaultGcsPulumiBackendUrl'.
pulumiStateBackendUrl :: Text -> TargetProfile -> Text
pulumiStateBackendUrl ctx tp
  | T.null (tpPulumiBackendUrl tp) = defaultGcsPulumiBackendUrl ctx tp
  | otherwise = tpPulumiBackendUrl tp

-- | The GCS bucket that holds a context's Pulumi state (the bucket portion of
-- 'pulumiStateBackendUrl').
pulumiStateBucket :: Text -> TargetProfile -> Maybe Text
pulumiStateBucket ctx tp = gcsBucketOfUrl (pulumiStateBackendUrl ctx tp)

-- | @gcloud storage buckets describe gs://\<bucket>@ — the existence probe.
bucketDescribeArgs :: Text -> [String]
bucketDescribeArgs bucket =
  ["storage", "buckets", "describe", "gs://" <> T.unpack bucket, "--format=value(name)"]

-- | @gcloud storage buckets create@ with uniform access + public-access-prevention.
bucketCreateArgs :: Text -> Text -> Text -> [String]
bucketCreateArgs bucket project location =
  [ "storage"
  , "buckets"
  , "create"
  , "gs://" <> T.unpack bucket
  , "--project=" <> T.unpack project
  , "--location=" <> T.unpack location
  , "--uniform-bucket-level-access"
  , "--public-access-prevention"
  ]

-- | @gcloud storage buckets update@ — enable versioning and re-assert the access
-- settings. Idempotent, so it is safe to run whether or not the bucket pre-existed.
-- No retention lock is set (EP-93 Idempotence: retention locks are hard to undo).
bucketUpdateArgs :: Text -> [String]
bucketUpdateArgs bucket =
  [ "storage"
  , "buckets"
  , "update"
  , "gs://" <> T.unpack bucket
  , "--versioning"
  , "--uniform-bucket-level-access"
  , "--public-access-prevention"
  ]

-- | @gcloud storage buckets add-iam-policy-binding@ granting a CI/operator principal
-- bucket-scoped @roles/storage.objectAdmin@ on the state bucket.
bucketIamArgs :: Text -> Text -> [String]
bucketIamArgs bucket member =
  [ "storage"
  , "buckets"
  , "add-iam-policy-binding"
  , "gs://" <> T.unpack bucket
  , "--member=" <> T.unpack member
  , "--role=roles/storage.objectAdmin"
  ]

-- | The ordered @gcloud storage@ commands a bootstrap runs (create, update, and an
-- optional IAM grant). Pure, for the dry-run print and for unit tests. The
-- create is conditional on the bucket being absent at runtime, but it is listed here
-- so the dry-run shows the full intended sequence.
bootstrapCommands :: Text -> Text -> Text -> Maybe Text -> [[String]]
bootstrapCommands bucket project location mMember =
  [ bucketCreateArgs bucket project location
  , bucketUpdateArgs bucket
  ]
    <> maybe [] (\m -> [bucketIamArgs bucket m]) mMember

-- | Ensure a context's GCS Pulumi state bucket exists and is configured, idempotently.
-- A local backend (or a local-mode context, via 'effectivePulumiBackend') is a no-op.
-- With @dryRun@, prints the exact @gcloud@ commands and runs nothing. Otherwise:
-- describe the bucket; create it only if missing; always run the idempotent update;
-- and, when a member is supplied, add the bucket-scoped IAM binding. Returns the first
-- failure with a precise message so the caller can surface it.
bootstrapPulumiStateBucket :: Bool -> Text -> TargetProfile -> Maybe Text -> IO (Either Text ())
bootstrapPulumiStateBucket dryRun ctx tp mMember =
  case effectivePulumiBackend tp of
    PulumiBackendLocal -> pure (Right ())
    PulumiBackendGcs -> case pulumiStateBucket ctx tp of
      Nothing ->
        pure (Left ("cannot derive a GCS bucket from backend URL " <> pulumiStateBackendUrl ctx tp))
      Just bucket
        | dryRun -> do
            TIO.putStrLn ("  # ensure the Pulumi state bucket gs://" <> bucket <> " exists (idempotent):")
            mapM_
              (\a -> TIO.putStrLn ("  gcloud " <> T.pack (unwords a)))
              (bootstrapCommands bucket (tpProject tp) (tpRegion tp) mMember)
            pure (Right ())
        | otherwise -> runBootstrap bucket (tpProject tp) (tpRegion tp) mMember

runBootstrap :: Text -> Text -> Text -> Maybe Text -> IO (Either Text ())
runBootstrap bucket project location mMember = do
  exists <- gcloudDescribeOk (bucketDescribeArgs bucket)
  createStep <-
    if exists
      then pure (Right ())
      else runGcloud ("create bucket gs://" <> bucket) (bucketCreateArgs bucket project location)
  chain createStep $
    chainIO (runGcloud ("update bucket gs://" <> bucket) (bucketUpdateArgs bucket)) $
      case mMember of
        Nothing -> pure (Right ())
        Just m -> runGcloud ("grant " <> m <> " on gs://" <> bucket) (bucketIamArgs bucket m)
  where
    chain (Left e) _ = pure (Left e)
    chain (Right ()) next = next
    chainIO act next = do
      r <- act
      case r of
        Left e -> pure (Left e)
        Right () -> next

-- | Run a @gcloud@ command, streaming its output; map a non-zero exit to a 'Left'
-- naming the step. A missing @gcloud@ (127) is reported as a clear remediation.
runGcloud :: Text -> [String] -> IO (Either Text ())
runGcloud step args = do
  code <- run $ cmd "gcloud" & addArgs args
  pure $ case code of
    ExitSuccess -> Right ()
    ExitFailure 127 -> Left ("gcloud not found on PATH while trying to " <> step)
    ExitFailure n -> Left ("gcloud failed (exit " <> T.pack (show n) <> ") while trying to " <> step)

-- | @gcloud storage buckets describe@ as a boolean existence probe (exit 0 == exists),
-- swallowing output. A missing @gcloud@ reads as \"does not exist\" so the caller then
-- attempts the create, which surfaces the missing-tool error through 'runGcloud'.
gcloudDescribeOk :: [String] -> IO Bool
gcloudDescribeOk args = do
  (code, _, _) <- readProcessWithExitCode "gcloud" args ""
  pure (code == ExitSuccess)
