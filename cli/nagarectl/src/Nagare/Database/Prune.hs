-- | One reviewed, expiry-gated deletion of a manual backup and its receipt.
-- The Job rereads both exact keys, checks the accepted hashes, and deletes
-- only the provider versions it just inspected. A partial result is left for
-- explicit recovery; Kubernetes must never retry this Job automatically.
module Nagare.Database.Prune
  ( PruneJobInputs (..)
  , renderPruneJob
  , renderScheduledPruneJob
  , renderScheduledReceiptRecoveryJob
  , renderVolumePruneJob
  , pruneShell
  , scheduledPruneShell
  , scheduledReceiptRecoveryShell
  ) where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Key qualified as K
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Yaml qualified as Y
import Nagare.Cluster.GcsJob
  ( DataMovementJob (..), MinioRef (..), StoreBackend (..)
  , dataMovementJobSpec, storeEnv, storeHostAliases
  , storeImage, storeShellPreamble )
import Nagare.Dsl.Prelude hiding ((.=))

data PruneJobInputs = PruneJobInputs
  { namespace :: !Text
  , jobName :: !Text
  , objectUrl :: !Text
  , receiptUrl :: !Text
  , objectSha256 :: !Text
  , receiptSha256 :: !Text
  , expiryEpoch :: !Integer
  , backend :: !StoreBackend
  }
  deriving stock (Generic, Eq, Show)

renderPruneJob :: PruneJobInputs -> ByteString
renderPruneJob = renderPruneJobWithLabel "nagare.dev/database-prune" Nothing Nothing

-- | Scheduled retention carries the two exact provider versions from the
-- accepted ingestion scope. A different current version refuses before the
-- first delete, even when its bytes happen to hash identically.
renderScheduledPruneJob :: PruneJobInputs -> Text -> Text -> ByteString
renderScheduledPruneJob inputs objectVersion receiptVersion =
  renderPruneJobWithLabel "nagare.dev/scheduled-prune"
    (Just (objectVersion, receiptVersion)) Nothing inputs

renderScheduledReceiptRecoveryJob :: PruneJobInputs -> Text -> Text -> ByteString
renderScheduledReceiptRecoveryJob inputs objectVersion receiptVersion =
  renderPruneJobWithLabel "nagare.dev/scheduled-prune-recovery"
    (Just (objectVersion, receiptVersion))
    (Just (scheduledReceiptRecoveryShell inputs)) inputs

renderVolumePruneJob :: PruneJobInputs -> ByteString
renderVolumePruneJob = renderPruneJobWithLabel "nagare.dev/volume-prune" Nothing Nothing

renderPruneJobWithLabel :: Text -> Maybe (Text, Text) -> Maybe Text
  -> PruneJobInputs -> ByteString
renderPruneJobWithLabel label pins recoveryShell inputs = Y.encode $ object
  [ "apiVersion" .= ("batch/v1" :: Text)
  , "kind" .= ("Job" :: Text)
  , "metadata" .= object
      [ "name" .= (inputs ^. #jobName)
      , "namespace" .= (inputs ^. #namespace)
      , "labels" .= labels
      ]
  , "spec" .= dataMovementJobSpec DataMovementJob
      { templateLabels = Just labels
      , serviceAccountName = Nothing
      , hostAliases = storeHostAliases (inputs ^. #backend)
      , affinity = Nothing
      , initContainers = []
      , containers = [object
          [ "name" .= ("prune" :: Text)
          , "image" .= storeImage (inputs ^. #backend)
          , "command" .= (["/bin/sh", "-c"] :: [Text])
          , "args" .= [maybe (maybe (pruneShell inputs)
              (const (scheduledPruneShell inputs)) pins) id recoveryShell]
          , "env" .= toJSON (map (uncurry plainEnv)
              [ ("OBJECT", inputs ^. #objectUrl)
              , ("RECEIPT", inputs ^. #receiptUrl)
              , ("EXPECTED_OBJECT_SHA256", inputs ^. #objectSha256)
              , ("EXPECTED_RECEIPT_SHA256", inputs ^. #receiptSha256)
              , ("EXPIRY_EPOCH", T.pack (show (inputs ^. #expiryEpoch)))
              ] <> maybe [] (\(objectVersion, receiptVersion) ->
                map (uncurry plainEnv)
                  [ ("EXPECTED_OBJECT_VERSION", objectVersion)
                  , ("EXPECTED_RECEIPT_VERSION", receiptVersion) ]) pins
                <> storeEnv (inputs ^. #backend))
          ]]
      , volumes = []
      , backoffLimit = 0
      }
  ]
  where
    labels = object
      [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
      , K.fromText label .= ("reviewed" :: Text)
      ]

plainEnv :: Text -> Text -> Value
plainEnv name value = object ["name" .= name, "value" .= value]

pruneShell :: PruneJobInputs -> Text
pruneShell inputs = pruneShellWithPins inputs False

-- | Values are supplied by the rendered Job's EXPECTED_*_VERSION env entries.
scheduledPruneShell :: PruneJobInputs -> Text
scheduledPruneShell inputs = pruneShellWithPins inputs True

-- | Recovery of an immutable Job that deleted only the data version. The
-- original review supplies both exact versions and hashes; a complete version
-- listing must find no data-key version or delete marker before the receipt
-- can be removed. The ordinary prune Job cannot be replayed after this point.
scheduledReceiptRecoveryShell :: PruneJobInputs -> Text
scheduledReceiptRecoveryShell inputs = case inputs ^. #backend of
  GcsBackend {} -> "exit 1"
  MinioBackend ref ->
    "set -eu; " <> storeShellPreamble (inputs ^. #backend)
      <> "command -v python3 >/dev/null 2>&1; "
      <> "command -v sha256sum >/dev/null 2>&1 || dnf install -y -q coreutils >/dev/null 2>&1; "
      <> "STORE_BUCKET='" <> ref ^. #bucket <> "'; STORE_ENDPOINT='"
      <> ref ^. #endpoint <> "'; "
      <> "VERSIONS_FILE=${NAGARE_VERSION_LIST_FILE:-/tmp/nagare-version-list.json}; "
      <> "case \"$OBJECT\" in s3://\"$STORE_BUCKET\"/*) ;; *) exit 1;; esac; "
      <> "DATA_KEY=${OBJECT#s3://$STORE_BUCKET/}; "
      <> "RECEIPT_KEY=${RECEIPT#s3://$STORE_BUCKET/}; "
      <> "test -n \"$DATA_KEY\"; test -n \"$EXPECTED_OBJECT_VERSION\"; "
      <> "test \"$RECEIPT\" = \"$OBJECT.receipt.json\"; "
      <> "version_absent() { TARGET_KEY=$1; export TARGET_KEY; "
      <> "aws --no-paginate s3api list-object-versions --bucket \"$STORE_BUCKET\""
      <> " --prefix \"$TARGET_KEY\" --output json --endpoint-url \"$STORE_ENDPOINT\""
      <> " > \"$VERSIONS_FILE\"; "
      <> "python3 -c 'import json,os,sys; d=json.load(sys.stdin); "
      <> "assert d.get(\"IsTruncated\") is False; "
      <> "assert all(v.get(\"Key\") != os.environ[\"TARGET_KEY\"] "
      <> "for v in d.get(\"Versions\",[])+d.get(\"DeleteMarkers\",[]))'"
      <> " < \"$VERSIONS_FILE\"; }; "
      <> "version_absent \"$DATA_KEY\"; "
      <> "RECEIPT_VERSION=$(aws s3api head-object --bucket \"$STORE_BUCKET\""
      <> " --key \"$RECEIPT_KEY\" --query VersionId --output text"
      <> " --endpoint-url \"$STORE_ENDPOINT\"); "
      <> "test \"$RECEIPT_VERSION\" = \"$EXPECTED_RECEIPT_VERSION\"; "
      <> "ACTUAL_RECEIPT=$(aws s3api get-object --bucket \"$STORE_BUCKET\""
      <> " --key \"$RECEIPT_KEY\" --version-id \"$RECEIPT_VERSION\""
      <> " --endpoint-url \"$STORE_ENDPOINT\" /dev/fd/3 3>&1 1>/dev/null"
      <> " | sha256sum | cut -d' ' -f1); "
      <> "test \"$ACTUAL_RECEIPT\" = \"$EXPECTED_RECEIPT_SHA256\"; "
      <> "version_absent \"$DATA_KEY\"; "
      <> "test \"$(aws s3api head-object --bucket \"$STORE_BUCKET\""
      <> " --key \"$RECEIPT_KEY\" --query VersionId --output text"
      <> " --endpoint-url \"$STORE_ENDPOINT\")\" = \"$RECEIPT_VERSION\"; "
      <> "aws s3api delete-object --bucket \"$STORE_BUCKET\""
      <> " --key \"$RECEIPT_KEY\" --version-id \"$RECEIPT_VERSION\""
      <> " --endpoint-url \"$STORE_ENDPOINT\"; "
      <> "version_absent \"$RECEIPT_KEY\""

pruneShellWithPins :: PruneJobInputs -> Bool -> Text
pruneShellWithPins inputs pinned =
  "set -eu; " <> storeShellPreamble backend
    <> tools <> backendSetup
    <> "NOW=$(date -u +%s); test \"$NOW\" -ge \"$EXPIRY_EPOCH\"; "
    <> "test \"$RECEIPT\" = \"$OBJECT.receipt.json\"; "
    <> "DATA_VERSION=$(" <> version "OBJECT" <> "); "
    <> "RECEIPT_VERSION=$(" <> version "RECEIPT" <> "); "
    <> validateVersion
    <> (if pinned then
      "test \"$DATA_VERSION\" = \"$EXPECTED_OBJECT_VERSION\"; "
        <> "test \"$RECEIPT_VERSION\" = \"$EXPECTED_RECEIPT_VERSION\"; "
      else "")
    <> "ACTUAL_RECEIPT=$(" <> readVersioned "RECEIPT" "RECEIPT_VERSION"
    <> " | sha256sum | cut -d' ' -f1); "
    <> "test \"$ACTUAL_RECEIPT\" = \"$EXPECTED_RECEIPT_SHA256\"; "
    <> "ACTUAL_OBJECT=$(" <> readVersioned "OBJECT" "DATA_VERSION"
    <> " | sha256sum | cut -d' ' -f1); "
    <> "test \"$ACTUAL_OBJECT\" = \"$EXPECTED_OBJECT_SHA256\"; "
    <> "test \"$(" <> version "OBJECT" <> ")\" = \"$DATA_VERSION\"; "
    <> "test \"$(" <> version "RECEIPT" <> ")\" = \"$RECEIPT_VERSION\"; "
    <> delete "OBJECT" "DATA_VERSION" <> "; "
    <> verifyAbsent "DATA_KEY" <> "; "
    <> delete "RECEIPT" "RECEIPT_VERSION" <> "; "
    <> verifyAbsent "RECEIPT_KEY"
  where
    backend = inputs ^. #backend
    tools = case backend of
      GcsBackend {} -> "command -v sha256sum >/dev/null 2>&1; "
      MinioBackend {} ->
        "command -v sha256sum >/dev/null 2>&1 || dnf install -y -q coreutils >/dev/null 2>&1; "
          <> "command -v sha256sum >/dev/null 2>&1; "
    backendSetup = case backend of
      GcsBackend {} -> ""
      MinioBackend ref ->
        "STORE_BUCKET='" <> ref ^. #bucket <> "'; STORE_ENDPOINT='"
          <> ref ^. #endpoint <> "'; "
          <> "case \"$OBJECT\" in s3://\"$STORE_BUCKET\"/*) ;; *) exit 1;; esac; "
          <> "DATA_KEY=${OBJECT#s3://$STORE_BUCKET/}; "
          <> "RECEIPT_KEY=${RECEIPT#s3://$STORE_BUCKET/}; "
          <> "test -n \"$DATA_KEY\"; test -n \"$RECEIPT_KEY\"; "
    version variable = case backend of
      GcsBackend {} ->
        "gcloud storage objects describe \"$" <> variable
          <> "\" --format='value(generation)'"
      MinioBackend {} ->
        "aws s3api head-object --bucket \"$STORE_BUCKET\" --key \"$"
          <> key variable <> "\" --query VersionId --output text"
          <> " --endpoint-url \"$STORE_ENDPOINT\""
    key "OBJECT" = "DATA_KEY"
    key _ = "RECEIPT_KEY"
    readVersioned variable selectedVersion = case backend of
      GcsBackend {} ->
        "gcloud storage cp \"$" <> variable <> "#$" <> selectedVersion <> "\" -"
      MinioBackend {} ->
        "aws s3api get-object --bucket \"$STORE_BUCKET\" --key \"$"
          <> key variable <> "\" --version-id \"$" <> selectedVersion
          <> "\" --endpoint-url \"$STORE_ENDPOINT\" /dev/fd/3 3>&1 1>/dev/null"
    validateVersion = case backend of
      GcsBackend {} ->
        "case \"$DATA_VERSION:$RECEIPT_VERSION\" in *[!0-9:]*|:*|*:) exit 1;; esac; "
      MinioBackend {} ->
        "test -n \"$DATA_VERSION\"; test -n \"$RECEIPT_VERSION\"; "
          <> "test \"$DATA_VERSION\" != None; test \"$RECEIPT_VERSION\" != None; "
          <> "test \"$DATA_VERSION\" != null; test \"$RECEIPT_VERSION\" != null; "
    delete variable selectedVersion = case backend of
      GcsBackend {} ->
        "gcloud storage rm \"$" <> variable
          <> "\" --if-generation-match=\"$" <> selectedVersion <> "\""
      MinioBackend {} ->
        "aws s3api delete-object --bucket \"$STORE_BUCKET\" --key \"$"
          <> key variable <> "\" --version-id \"$" <> selectedVersion
          <> "\" --endpoint-url \"$STORE_ENDPOINT\""
    -- Deleting a current S3 version can expose an older version. A successful
    -- delete is not completion proof until no object at this exact key is live.
    -- The receipt shares the backup key's prefix, so compare complete keys
    -- rather than searching for the selected key as a substring.
    verifyAbsent selectedKey = case backend of
      GcsBackend {} -> "true"
      MinioBackend {} ->
        "VISIBLE=$(aws s3api list-objects-v2 --bucket \"$STORE_BUCKET\""
          <> " --prefix \"$" <> selectedKey <> "\" --query 'Contents[].Key'"
          <> " --output text --endpoint-url \"$STORE_ENDPOINT\"); "
          <> "for FOUND in $VISIBLE; do test \"$FOUND\" != \"$"
          <> selectedKey <> "\"; done"
