-- | One reviewed, expiry-gated deletion of a manual backup and its receipt.
-- The Job rereads both exact keys, checks the accepted hashes, and deletes
-- only the provider versions it just inspected. A partial result is left for
-- explicit recovery; Kubernetes must never retry this Job automatically.
module Nagare.Database.Prune
  ( PruneJobInputs (..)
  , renderPruneJob
  , pruneShell
  ) where

import Data.Aeson (Value, object, toJSON, (.=))
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
renderPruneJob inputs = Y.encode $ object
  [ "apiVersion" .= ("batch/v1" :: Text)
  , "kind" .= ("Job" :: Text)
  , "metadata" .= object
      [ "name" .= (inputs ^. #jobName)
      , "namespace" .= (inputs ^. #namespace)
      , "labels" .= labels
      ]
  , "spec" .= dataMovementJobSpec DataMovementJob
      { templateLabels = Just labels
      , hostAliases = storeHostAliases (inputs ^. #backend)
      , initContainers = []
      , containers = [object
          [ "name" .= ("prune" :: Text)
          , "image" .= storeImage (inputs ^. #backend)
          , "command" .= (["/bin/sh", "-c"] :: [Text])
          , "args" .= [pruneShell inputs]
          , "env" .= toJSON (map (uncurry plainEnv)
              [ ("OBJECT", inputs ^. #objectUrl)
              , ("RECEIPT", inputs ^. #receiptUrl)
              , ("EXPECTED_OBJECT_SHA256", inputs ^. #objectSha256)
              , ("EXPECTED_RECEIPT_SHA256", inputs ^. #receiptSha256)
              , ("EXPIRY_EPOCH", T.pack (show (inputs ^. #expiryEpoch)))
              ] <> storeEnv (inputs ^. #backend))
          ]]
      , volumes = []
      , backoffLimit = 0
      }
  ]
  where
    labels = object
      [ "nagare.dev/managed-by" .= ("nagarectl" :: Text)
      , "nagare.dev/database-prune" .= ("reviewed" :: Text)
      ]

plainEnv :: Text -> Text -> Value
plainEnv name value = object ["name" .= name, "value" .= value]

pruneShell :: PruneJobInputs -> Text
pruneShell inputs =
  "set -eu; " <> storeShellPreamble backend
    <> tools <> backendSetup
    <> "NOW=$(date -u +%s); test \"$NOW\" -ge \"$EXPIRY_EPOCH\"; "
    <> "test \"$RECEIPT\" = \"$OBJECT.receipt.json\"; "
    <> "DATA_VERSION=$(" <> version "OBJECT" <> "); "
    <> "RECEIPT_VERSION=$(" <> version "RECEIPT" <> "); "
    <> validateVersion
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
    -- A listing error is fatal; a sibling with this prefix may cause a safe
    -- false refusal, never a false success.
    verifyAbsent selectedKey = case backend of
      GcsBackend {} -> "true"
      MinioBackend {} ->
        "VISIBLE=$(aws s3api list-objects-v2 --bucket \"$STORE_BUCKET\""
          <> " --prefix \"$" <> selectedKey <> "\" --query 'Contents[].Key'"
          <> " --output text --endpoint-url \"$STORE_ENDPOINT\"); "
          <> "case \"$VISIBLE\" in *\"$" <> selectedKey
          <> "\"*) exit 1;; esac"
