{-# LANGUAGE OverloadedStrings #-}

-- | GCS Pulumi state-bucket bootstrap (EP-93). This is the __one__ place nagarectl
-- creates or updates the remote Pulumi state bucket for a @mode=cloud@ context that
-- opts into @NAGARE_PULUMI_BACKEND=gcs@. The bucket is a bootstrap prerequisite —
-- Pulumi must be able to reach its backend before it can run the program whose state
-- it stores — so it lives here, in @nagarectl init@ / @nagarectl context@, NOT in the
-- Pulumi program (@infra/pulumi/index.ts@).
--
-- The argv builders are pure and unit-tested; 'bootstrapPulumiStateBucket' is the
-- idempotent IO runner (describe → create-if-missing → assert ownership → update →
-- optional IAM grant), with a dry-run mode that prints the exact @gcloud storage@
-- commands.
--
-- EP-113: GCS bucket names are GLOBAL, so a same-named bucket may already exist in a
-- FOREIGN project that the operator can describe. The existence probe alone is
-- therefore not evidence that the bucket is ours, and @buckets update@ /
-- @add-iam-policy-binding@ address the bucket only by its global @gs:\/\/@ name. Before
-- either of those steps this module compares the bucket's OWNING PROJECT NUMBER with
-- the target project's, and fails closed when either number is unreadable. This is the
-- Haskell half of a contract shared with @_require_bucket_in_target_project@ in
-- @scripts\/lib\/target.sh@; see
-- @docs\/adr\/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md@.
module Nagare.Ops.PulumiBackend
  ( gcsBucketOfUrl
  , pulumiStateBackendUrl
  , pulumiStateBucket
  , bucketDescribeArgs
  , bucketCreateArgs
  , bucketUpdateArgs
  , bucketIamArgs
  , bucketProjectNumberArgs
  , projectNumberArgs
  , bucketOwnershipVerdict
  , bootstrapCommands
  , bootstrapPulumiStateBucket
  , GcloudOps (..)
  , realGcloudOps
  , bootstrapPulumiStateBucketWith
  )
where

import Cradle (addArgs, cmd, run)
import Control.Monad (foldM)
import Data.Function ((&))
import Data.Generics.Labels ()
import Data.Maybe (isJust)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Prelude
import Nagare.Target
  ( PulumiBackendKind (..)
  , InventoryStoreKind (..)
  , TargetProfile (..)
  , defaultGcsPulumiBackendUrl
  , defaultGcsInventoryStoreUrl
  , effectivePulumiBackend
  , effectiveInventoryStore
  )
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

-- | Parse the bucket out of a @gs://\<bucket>/\<path>@ URL. 'Nothing' if the URL is
-- not a @gs://@ URL or names no bucket.
gcsBucketOfUrl :: Text -> Maybe Text
gcsBucketOfUrl url = do
  rest <- T.stripPrefix "gs://" url
  let bucket = T.takeWhile (/= '/') rest
  if T.null bucket then Nothing else Just bucket

-- | The resolved @gs://@ backend URL for a context: the explicit
-- 'pulumiBackendUrl' when set, else 'defaultGcsPulumiBackendUrl'.
pulumiStateBackendUrl :: Text -> TargetProfile -> Text
pulumiStateBackendUrl ctx tp
  | T.null (tp ^. #pulumiBackendUrl) = defaultGcsPulumiBackendUrl ctx tp
  | otherwise = tp ^. #pulumiBackendUrl

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

-- | @gcloud storage buckets describe gs:\/\/\<bucket> --raw --format=value(projectNumber)@ —
-- reads the bucket's OWNING project number. GCS bucket names are global, so a
-- successful describe is not evidence that the bucket is ours; only the owning
-- project number is, because a name collision cannot forge it. @--raw@ is required:
-- current gcloud omits @projectNumber@ from the formatted bucket resource (EP-116).
bucketProjectNumberArgs :: Text -> [String]
bucketProjectNumberArgs bucket =
  ["storage", "buckets", "describe", "gs://" <> T.unpack bucket, "--raw", "--format=value(projectNumber)"]

-- | @gcloud projects describe \<project> --format=value(projectNumber)@ — the target
-- project's own number, the value the bucket's must equal.
projectNumberArgs :: Text -> [String]
projectNumberArgs project =
  ["projects", "describe", T.unpack project, "--format=value(projectNumber)"]

-- | Fail closed: refuse unless BOTH numbers are present, non-empty and equal. An
-- absent number (missing gcloud, missing permission, network failure) is a mismatch,
-- never permission to continue. The message mirrors the Bash helper
-- @_require_bucket_in_target_project@ in @scripts\/lib\/target.sh@.
bucketOwnershipVerdict :: Text -> Text -> Maybe Text -> Maybe Text -> Either Text ()
bucketOwnershipVerdict bucket project mBucketNumber mTargetNumber
  | Just b <- nonEmpty mBucketNumber
  , Just t <- nonEmpty mTargetNumber
  , b == t =
      Right ()
  | otherwise = Left refusal
  where
    nonEmpty mv = case fmap T.strip mv of
      Just v | not (T.null v) -> Just v
      _ -> Nothing
    shown = maybe "<unknown>" id . nonEmpty
    refusal =
      "refusing: gs://"
        <> bucket
        <> " is owned by project number '"
        <> shown mBucketNumber
        <> "', not the target project '"
        <> project
        <> "' (number '"
        <> shown mTargetNumber
        <> "'). GCS bucket names are global; choose a state bucket name that is unique"
        <> " across all of Google Cloud, or set NAGARE_PULUMI_BACKEND_URL to"
        <> " gs://<unique-name>/nagare/<context>."

-- | The ordered @gcloud@ commands a bootstrap runs: the create, the two
-- project-number reads that assert the bucket is ours (EP-113), the update, and an
-- optional IAM grant. Pure, for the dry-run print and for unit tests. The create is
-- conditional on the bucket being absent at runtime, but it is listed here so the
-- dry-run shows the full intended sequence including the assertion.
bootstrapCommands :: Text -> Text -> Text -> Maybe Text -> [[String]]
bootstrapCommands bucket project location mMember =
  [ bucketCreateArgs bucket project location
  , bucketProjectNumberArgs bucket
  , projectNumberArgs project
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
bootstrapPulumiStateBucket = bootstrapPulumiStateBucketWith realGcloudOps

-- | The external @gcloud@ effects this module needs, injectable so the bootstrap
-- sequence itself (not just its argv) can be unit-tested. 'realGcloudOps' is the
-- production implementation; tests supply a recording fake, which is what lets a test
-- prove that a refusal ran NO update and NO IAM change rather than merely returning an
-- error.
data GcloudOps = GcloudOps
  { capture :: !([String] -> IO (Maybe Text))
  -- ^ Run and capture trimmed stdout; 'Nothing' on any failure.
  , execute :: !(Text -> [String] -> IO (Either Text ()))
  -- ^ Run for effect, streaming output; 'Left' names the failed step.
  }
  deriving stock (Generic)

-- | The production 'GcloudOps': a real @gcloud@ on @PATH@.
realGcloudOps :: GcloudOps
realGcloudOps = GcloudOps {capture = captureGcloud, execute = runGcloud}

-- | 'bootstrapPulumiStateBucket' with the @gcloud@ effects supplied by the caller.
bootstrapPulumiStateBucketWith :: GcloudOps -> Bool -> Text -> TargetProfile -> Maybe Text -> IO (Either Text ())
bootstrapPulumiStateBucketWith ops dryRun ctx tp mMember = case traverse bucketFor urls of
  Left err -> pure (Left err)
  Right buckets -> foldM ensure (Right ()) (nub buckets)
  where
    urls =
      [pulumiStateBackendUrl ctx tp | effectivePulumiBackend tp == PulumiBackendGcs]
        <> [inventoryUrl | effectiveInventoryStore tp == InventoryStoreGcs]
    inventoryUrl = if T.null (tp ^. #inventoryStoreUrl)
      then defaultGcsInventoryStoreUrl ctx tp
      else tp ^. #inventoryStoreUrl
    bucketFor url = maybe (Left ("cannot derive a GCS bucket from backend URL " <> url)) Right (gcsBucketOfUrl url)
    ensure (Left err) _ = pure (Left err)
    ensure (Right ()) bucket
      | dryRun = do
          TIO.putStrLn ("  # ensure the context state bucket gs://" <> bucket <> " exists (idempotent):")
          mapM_ (\args -> TIO.putStrLn ("  gcloud " <> T.pack (unwords args)))
            (bootstrapCommands bucket (tp ^. #project) (tp ^. #region) mMember)
          pure (Right ())
      | otherwise = runBootstrap ops bucket (tp ^. #project) (tp ^. #region) mMember

-- | The bootstrap sequence. The ownership assertion sits between the
-- create-if-missing step and the update, exactly where its Bash twin
-- @ensure_bucket@ in @scripts\/migrate-pulumi-backend.sh@ puts it: a refusal must
-- happen before ANY mutation that addresses the bucket by its global name.
runBootstrap :: GcloudOps -> Text -> Text -> Text -> Maybe Text -> IO (Either Text ())
runBootstrap ops bucket project location mMember = do
  exists <- isJust <$> (ops ^. #capture) (bucketDescribeArgs bucket)
  createStep <-
    if exists
      then pure (Right ())
      else (ops ^. #execute) ("create bucket gs://" <> bucket) (bucketCreateArgs bucket project location)
  chain createStep $
    chainIO assertOwnership $
      chainIO ((ops ^. #execute) ("update bucket gs://" <> bucket) (bucketUpdateArgs bucket)) $
        case mMember of
          Nothing -> pure (Right ())
          Just m -> (ops ^. #execute) ("grant " <> m <> " on gs://" <> bucket) (bucketIamArgs bucket m)
  where
    assertOwnership = do
      mBucketNumber <- (ops ^. #capture) (bucketProjectNumberArgs bucket)
      mTargetNumber <- (ops ^. #capture) (projectNumberArgs project)
      pure (bucketOwnershipVerdict bucket project mBucketNumber mTargetNumber)
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

-- | Run a @gcloud@ command and capture its trimmed stdout, or 'Nothing' on any
-- failure — a non-zero exit, a missing @gcloud@, or empty output. Used both as the
-- boolean existence probe (a 'Nothing' reads as \"does not exist\", so the caller
-- attempts the create, which surfaces the missing-tool error through 'runGcloud')
-- and to read the two project numbers, where 'Nothing' is a REFUSAL.
--
-- @Nagare.Ops.Probe.captureTool@ is not reused here: it yields a 'ByteString' and
-- collapses the empty-output case this code must distinguish.
captureGcloud :: [String] -> IO (Maybe Text)
captureGcloud args = do
  (code, out, _) <- readProcessWithExitCode "gcloud" args ""
  let trimmed = T.strip (T.pack out)
  pure $ case code of
    ExitSuccess | not (T.null trimmed) -> Just trimmed
    _ -> Nothing
