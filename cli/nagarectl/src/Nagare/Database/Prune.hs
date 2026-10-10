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
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Key qualified as K
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Yaml qualified as Y
import Nagare.Cluster.GcsJob
  ( DataMovementJob (..)
  , MinioRef (..)
  , StoreBackend (..)
  , dataMovementJobSpec
  , storeEnv
  , storeHostAliases
  , storeImage
  , storeShellPreamble
  )
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
  renderPruneJobWithLabel
    "nagare.dev/scheduled-prune"
    (Just (objectVersion, receiptVersion))
    Nothing
    inputs

renderScheduledReceiptRecoveryJob :: PruneJobInputs -> Text -> Text -> ByteString
renderScheduledReceiptRecoveryJob inputs objectVersion receiptVersion =
  renderPruneJobWithLabel
    "nagare.dev/scheduled-prune-recovery"
    (Just (objectVersion, receiptVersion))
    (Just (scheduledReceiptRecoveryShell inputs))
    inputs

renderVolumePruneJob :: PruneJobInputs -> ByteString
renderVolumePruneJob = renderPruneJobWithLabel "nagare.dev/volume-prune" Nothing Nothing

renderPruneJobWithLabel ::
  Text ->
  Maybe (Text, Text) ->
  Maybe Text ->
  PruneJobInputs ->
  ByteString
renderPruneJobWithLabel label pins recoveryShell inputs =
  Y.encode $
    object
      [ "apiVersion" .= ("batch/v1" :: Text)
      , "kind" .= ("Job" :: Text)
      , "metadata"
          .= object
            [ "name" .= (inputs ^. #jobName)
            , "namespace" .= (inputs ^. #namespace)
            , "labels" .= labels
            ]
      , "spec"
          .= dataMovementJobSpec
            DataMovementJob
              { templateLabels = Just labels
              , serviceAccountName = Nothing
              , hostAliases = storeHostAliases (inputs ^. #backend)
              , affinity = Nothing
              , initContainers = []
              , containers =
                  [ object
                      [ "name" .= ("prune" :: Text)
                      , "image" .= storeImage (inputs ^. #backend)
                      , "command" .= (["/bin/sh", "-c"] :: [Text])
                      , "args"
                          .= [ maybe
                                 ( maybe
                                     (pruneShell inputs)
                                     (const (scheduledPruneShell inputs))
                                     pins
                                 )
                                 id
                                 recoveryShell
                             ]
                      , "env"
                          .= toJSON
                            ( map
                                (uncurry plainEnv)
                                [ ("OBJECT", inputs ^. #objectUrl)
                                , ("RECEIPT", inputs ^. #receiptUrl)
                                , ("EXPECTED_OBJECT_SHA256", inputs ^. #objectSha256)
                                , ("EXPECTED_RECEIPT_SHA256", inputs ^. #receiptSha256)
                                , ("EXPIRY_EPOCH", T.pack (show (inputs ^. #expiryEpoch)))
                                ]
                                <> maybe
                                  []
                                  ( \(objectVersion, receiptVersion) ->
                                      map
                                        (uncurry plainEnv)
                                        [ ("EXPECTED_OBJECT_VERSION", objectVersion)
                                        , ("EXPECTED_RECEIPT_VERSION", receiptVersion)
                                        ]
                                  )
                                  pins
                                <> storeEnv (inputs ^. #backend)
                            )
                      ]
                  ]
              , volumes = []
              , backoffLimit = 0
              }
      ]
  where
    labels =
      object
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

-- | EP-183 M2: recovery of a scheduled prune Job that failed at any point.
-- The original review supplies both exact versions and hashes. The Job
-- converges each key in order, the archive before its receipt: a key with no
-- live object is done; a key whose only live object is the reviewed version
-- is checked against its hash, deleted by that exact version, and proved
-- absent; anything else refuses before any further deletion. Running it again
-- after any interruption therefore finishes the same deletion and nothing
-- more, and a receipt is never removed while its archive is still live.
scheduledReceiptRecoveryShell :: PruneJobInputs -> Text
scheduledReceiptRecoveryShell inputs = case inputs ^. #backend of
  GcsBackend _ bucket ->
    "set -eu; "
      <> "command -v sha256sum >/dev/null 2>&1; "
      <> gcsSetup bucket
      <> "test \"$RECEIPT\" = \"$OBJECT.receipt.json\"; "
      <> "case \"$EXPECTED_OBJECT_VERSION:$EXPECTED_RECEIPT_VERSION\" in *[!0-9:]*|:*|*:) exit 1;; esac; "
      <> "converge_one() { URL=$1; KEY=$2; GEN=$3; SHA=$4; "
      <> "STATE=$(gcs_live \"$KEY\"); "
      <> "if test \"$STATE\" = absent; then return 0; fi; "
      <> "LIVE=$(gcloud storage objects describe \"$URL\" --format='value(generation)'); "
      <> "test \"$LIVE\" = \"$GEN\"; "
      <> "ACTUAL=$(gcloud storage cp \"$URL#$GEN\" - | sha256sum | cut -d' ' -f1); "
      <> "test \"$ACTUAL\" = \"$SHA\"; "
      <> "gcloud storage rm \"$URL\" --if-generation-match=\"$GEN\"; "
      <> "test \"$(gcs_live \"$KEY\")\" = absent; }; "
      <> "converge_one \"$OBJECT\" \"$DATA_KEY\" \"$EXPECTED_OBJECT_VERSION\" \"$EXPECTED_OBJECT_SHA256\"; "
      <> "converge_one \"$RECEIPT\" \"$RECEIPT_KEY\" \"$EXPECTED_RECEIPT_VERSION\" \"$EXPECTED_RECEIPT_SHA256\""
  MinioBackend ref ->
    "set -eu; "
      <> storeShellPreamble (inputs ^. #backend)
      <> "command -v python3 >/dev/null 2>&1; "
      <> "command -v sha256sum >/dev/null 2>&1 || dnf install -y -q coreutils >/dev/null 2>&1; "
      <> "STORE_BUCKET='"
      <> ref ^. #bucket
      <> "'; STORE_ENDPOINT='"
      <> ref ^. #endpoint
      <> "'; "
      <> "VERSIONS_FILE=${NAGARE_VERSION_LIST_FILE:-/tmp/nagare-version-list.json}; "
      <> "case \"$OBJECT\" in s3://\"$STORE_BUCKET\"/*) ;; *) exit 1;; esac; "
      <> "DATA_KEY=${OBJECT#s3://$STORE_BUCKET/}; "
      <> "RECEIPT_KEY=${RECEIPT#s3://$STORE_BUCKET/}; "
      <> "test -n \"$DATA_KEY\"; test -n \"$EXPECTED_OBJECT_VERSION\"; test -n \"$EXPECTED_RECEIPT_VERSION\"; "
      <> "test \"$RECEIPT\" = \"$OBJECT.receipt.json\"; "
      -- Every version at the exact key, from a complete listing; a delete
      -- marker refuses, since this Job never writes one.
      <> "versions_of() { TARGET_KEY=$1; export TARGET_KEY; "
      <> "aws --no-paginate s3api list-object-versions --bucket \"$STORE_BUCKET\""
      <> " --prefix \"$TARGET_KEY\" --output json --endpoint-url \"$STORE_ENDPOINT\""
      <> " > \"$VERSIONS_FILE\" && "
      <> "python3 -c 'import json,os,sys; d=json.load(sys.stdin); "
      <> "assert d.get(\"IsTruncated\") is False; k=os.environ[\"TARGET_KEY\"]; "
      <> "assert not [m for m in d.get(\"DeleteMarkers\") or [] if m.get(\"Key\") == k]; "
      <> "print(\" \".join(v[\"VersionId\"] for v in d.get(\"Versions\") or [] if v.get(\"Key\") == k))'"
      <> " < \"$VERSIONS_FILE\"; }; "
      <> "converge_one() { KEY=$1; VERSION=$2; SHA=$3; "
      <> "FOUND=$(versions_of \"$KEY\"); "
      <> "if test -z \"$FOUND\"; then return 0; fi; "
      <> "test \"$FOUND\" = \"$VERSION\"; "
      <> "ACTUAL=$(aws s3api get-object --bucket \"$STORE_BUCKET\""
      <> " --key \"$KEY\" --version-id \"$VERSION\""
      <> " --endpoint-url \"$STORE_ENDPOINT\" /dev/fd/3 3>&1 1>/dev/null"
      <> " | sha256sum | cut -d' ' -f1); "
      <> "test \"$ACTUAL\" = \"$SHA\"; "
      <> "aws s3api delete-object --bucket \"$STORE_BUCKET\""
      <> " --key \"$KEY\" --version-id \"$VERSION\""
      <> " --endpoint-url \"$STORE_ENDPOINT\"; "
      <> "test -z \"$(versions_of \"$KEY\")\"; }; "
      <> "converge_one \"$DATA_KEY\" \"$EXPECTED_OBJECT_VERSION\" \"$EXPECTED_OBJECT_SHA256\"; "
      <> "converge_one \"$RECEIPT_KEY\" \"$EXPECTED_RECEIPT_VERSION\" \"$EXPECTED_RECEIPT_SHA256\""

-- | The bucket, the two keys, and a positive live-object check for GCS. The
-- JSON API's object GET without a generation answers 404 exactly when no live
-- generation exists at the key, whatever noncurrent generations the versioned
-- bucket keeps; any other answer, or a failed request, stops the Job. A failed
-- @describe@ is never read as absence.
gcsSetup :: Text -> Text
gcsSetup bucket =
  "STORE_BUCKET='"
    <> bucket
    <> "'; "
    <> "case \"$OBJECT\" in gs://\"$STORE_BUCKET\"/*) ;; *) exit 1;; esac; "
    <> "DATA_KEY=${OBJECT#gs://$STORE_BUCKET/}; "
    <> "RECEIPT_KEY=${RECEIPT#gs://$STORE_BUCKET/}; "
    <> "test -n \"$DATA_KEY\"; test -n \"$RECEIPT_KEY\"; "
    <> "gcs_live() { case \"$1\" in ''|*[!A-Za-z0-9._/-]*) exit 1;; esac; "
    <> "NAME=$(printf '%s' \"$1\" | sed 's#/#%2F#g'); "
    <> "TOKEN=$(gcloud auth print-access-token); "
    <> "CODE=$(curl -sS -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer $TOKEN\""
    <> " \"https://storage.googleapis.com/storage/v1/b/$STORE_BUCKET/o/$NAME\"); "
    <> "case \"$CODE\" in 200) echo live;; 404) echo absent;; *) exit 1;; esac; }; "

pruneShellWithPins :: PruneJobInputs -> Bool -> Text
pruneShellWithPins inputs pinned =
  "set -eu; "
    <> storeShellPreamble backend
    <> tools
    <> backendSetup
    <> "NOW=$(date -u +%s); test \"$NOW\" -ge \"$EXPIRY_EPOCH\"; "
    <> "test \"$RECEIPT\" = \"$OBJECT.receipt.json\"; "
    <> "DATA_VERSION=$("
    <> version "OBJECT"
    <> "); "
    <> "RECEIPT_VERSION=$("
    <> version "RECEIPT"
    <> "); "
    <> validateVersion
    <> ( if pinned
           then
             "test \"$DATA_VERSION\" = \"$EXPECTED_OBJECT_VERSION\"; "
               <> "test \"$RECEIPT_VERSION\" = \"$EXPECTED_RECEIPT_VERSION\"; "
           else ""
       )
    <> "ACTUAL_RECEIPT=$("
    <> readVersioned "RECEIPT" "RECEIPT_VERSION"
    <> " | sha256sum | cut -d' ' -f1); "
    <> "test \"$ACTUAL_RECEIPT\" = \"$EXPECTED_RECEIPT_SHA256\"; "
    <> "ACTUAL_OBJECT=$("
    <> readVersioned "OBJECT" "DATA_VERSION"
    <> " | sha256sum | cut -d' ' -f1); "
    <> "test \"$ACTUAL_OBJECT\" = \"$EXPECTED_OBJECT_SHA256\"; "
    <> "test \"$("
    <> version "OBJECT"
    <> ")\" = \"$DATA_VERSION\"; "
    <> "test \"$("
    <> version "RECEIPT"
    <> ")\" = \"$RECEIPT_VERSION\"; "
    <> delete "OBJECT" "DATA_VERSION"
    <> "; "
    <> verifyAbsent "DATA_KEY"
    <> "; "
    <> delete "RECEIPT" "RECEIPT_VERSION"
    <> "; "
    <> verifyAbsent "RECEIPT_KEY"
  where
    backend = inputs ^. #backend
    tools = case backend of
      GcsBackend {} -> "command -v sha256sum >/dev/null 2>&1; "
      MinioBackend {} ->
        "command -v sha256sum >/dev/null 2>&1 || dnf install -y -q coreutils >/dev/null 2>&1; "
          <> "command -v sha256sum >/dev/null 2>&1; "
    backendSetup = case backend of
      GcsBackend _ bucket -> gcsSetup bucket
      MinioBackend ref ->
        "STORE_BUCKET='"
          <> ref ^. #bucket
          <> "'; STORE_ENDPOINT='"
          <> ref ^. #endpoint
          <> "'; "
          <> "case \"$OBJECT\" in s3://\"$STORE_BUCKET\"/*) ;; *) exit 1;; esac; "
          <> "DATA_KEY=${OBJECT#s3://$STORE_BUCKET/}; "
          <> "RECEIPT_KEY=${RECEIPT#s3://$STORE_BUCKET/}; "
          <> "test -n \"$DATA_KEY\"; test -n \"$RECEIPT_KEY\"; "
    version variable = case backend of
      GcsBackend {} ->
        "gcloud storage objects describe \"$"
          <> variable
          <> "\" --format='value(generation)'"
      MinioBackend {} ->
        "aws s3api head-object --bucket \"$STORE_BUCKET\" --key \"$"
          <> key variable
          <> "\" --query VersionId --output text"
          <> " --endpoint-url \"$STORE_ENDPOINT\""
    key "OBJECT" = "DATA_KEY"
    key _ = "RECEIPT_KEY"
    readVersioned variable selectedVersion = case backend of
      GcsBackend {} ->
        "gcloud storage cp \"$" <> variable <> "#$" <> selectedVersion <> "\" -"
      MinioBackend {} ->
        "aws s3api get-object --bucket \"$STORE_BUCKET\" --key \"$"
          <> key variable
          <> "\" --version-id \"$"
          <> selectedVersion
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
        "gcloud storage rm \"$"
          <> variable
          <> "\" --if-generation-match=\"$"
          <> selectedVersion
          <> "\""
      MinioBackend {} ->
        "aws s3api delete-object --bucket \"$STORE_BUCKET\" --key \"$"
          <> key variable
          <> "\" --version-id \"$"
          <> selectedVersion
          <> "\" --endpoint-url \"$STORE_ENDPOINT\""
    -- Deleting a current S3 version can expose an older version. A successful
    -- delete is not completion proof until no object at this exact key is live.
    -- The receipt shares the backup key's prefix, so compare complete keys
    -- rather than searching for the selected key as a substring.
    verifyAbsent selectedKey = case backend of
      GcsBackend {} -> "test \"$(gcs_live \"$" <> selectedKey <> "\")\" = absent"
      MinioBackend {} ->
        "VISIBLE=$(aws s3api list-objects-v2 --bucket \"$STORE_BUCKET\""
          <> " --prefix \"$"
          <> selectedKey
          <> "\" --query 'Contents[].Key'"
          <> " --output text --endpoint-url \"$STORE_ENDPOINT\"); "
          <> "for FOUND in $VISIBLE; do test \"$FOUND\" != \"$"
          <> selectedKey
          <> "\"; done"
