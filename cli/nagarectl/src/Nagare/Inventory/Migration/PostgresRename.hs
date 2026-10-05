-- | The bounded native contract for renaming one retained standalone
-- PostgreSQL database (IR-24 case 3). Every member keeps its logical
-- identity and moves to the new name. The old incarnation is fenced and kept
-- unchanged as the recovery point. Its volume is copied byte for byte, and
-- the copy is verified by manifest before the new StatefulSet starts.
-- Credentials keep their values. This module is pure: it classifies members,
-- derives the reviewed contract evidence and renders the transfer Job. The
-- provider effects live in "Nagare.Inventory.Adapters.KubernetesMigration".
module Nagare.Inventory.Migration.PostgresRename
  ( RenameMember (..)
  , RenameScope (..)
  , renameMember
  , renameScope
  , renameContract
  , rewriteCredentialData
  , fenceAnnotation
  , migrationFenced
  , scaledToZero
  , transferJobName
  , transferJob
  , transferScript
  , TransferMode (..)
  , TransferManifest (..)
  , parseTransferManifest
  )
where

import Data.Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Database.Secret (b64decode, b64encode, dbHost)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (OperationId, operationIdText)
import Nagare.Inventory.Migration.Types (MigrationContract (..))
import Nagare.Resource.Canonical (canonicalValue)
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Policy (DataPolicy (..))
import Nagare.Resource.Types

-- | How each member of a PostgreSQL database moves to its new name.
data RenameMember
  = -- | Generated credential: values copied, connection host rewritten.
    RenameCredential
  | -- | Backup signing key: bytes copied, so earlier receipts stay verifiable.
    RenameSigningKey
  | -- | The data volume: writer fenced, files copied and verified.
    RenameVolume
  | -- | The StatefulSet: started on the verified copy; the old one stays fenced.
    RenameWorkload
  | -- | The backup schedule: created under the new name; the old one is
    -- suspended so the retained incarnation never writes again.
    RenameSchedule
  | -- | Stateless companions created under the new name.
    RenameObject
  deriving stock (Eq, Show)

-- | Facts shared by every member of one renamed database.
data RenameScope = RenameScope
  { owner :: !ScopeId
  , namespace :: !Name
  , sourceDatabase :: !Name
  , destinationDatabase :: !Name
  , image :: !Text
  , writer :: !ResourceId
  }
  deriving stock (Eq, Show, Generic)

-- | Classify by logical role and native kind; anything else is outside the
-- bounded rename.
renameMember :: ManagedResource -> Either Text RenameMember
renameMember declaration = case (role, declaration ^. #address) of
  ("credential", Kubernetes _ "" kind (Just _) _) | nameText kind == "secret" -> durable RenameCredential
  ("backup-signing-key", Kubernetes _ "" kind (Just _) _) | nameText kind == "secret" -> durable RenameSigningKey
  ("pvc", Kubernetes _ "" kind (Just _) _) | nameText kind == "persistentvolumeclaim" -> durable RenameVolume
  ("statefulset", Kubernetes _ "apps" kind (Just _) _) | nameText kind == "statefulset" -> stateless RenameWorkload
  ("service", Kubernetes _ "" kind (Just _) _) | nameText kind == "service" -> stateless RenameObject
  ("backup-account", Kubernetes _ "" kind (Just _) _) | nameText kind == "serviceaccount" -> stateless RenameObject
  ("backup-read-role", Kubernetes _ "rbac.authorization.k8s.io" kind (Just _) _) | nameText kind == "role" -> stateless RenameObject
  ("backup-read-binding", Kubernetes _ "rbac.authorization.k8s.io" kind (Just _) _) | nameText kind == "rolebinding" -> stateless RenameObject
  ("backup", Kubernetes _ "batch" kind (Just _) _) | nameText kind == "cronjob" -> stateless RenameSchedule
  _ -> Left "member is outside the bounded PostgreSQL rename"
  where
    role = last (T.splitOn "/" (resourceIdText (declaration ^. #identity)))
    durable member = case declaration ^. #dataPolicy of
      Durable _ -> Right member
      Stateless -> Left "durable PostgreSQL member lost its recovery policy"
    stateless member = case declaration ^. #dataPolicy of
      Stateless -> Right member
      Durable _ -> Left "stateless PostgreSQL member declares durable data"

-- | Derive the shared facts from the source and destination StatefulSets of
-- one standalone database scope. Both must run the same PostgreSQL image in
-- the same namespace; only the database name may differ.
renameScope ::
  Map ResourceId (ManagedResource, ByteString) ->
  Map ResourceId (ManagedResource, ByteString) ->
  ScopeId ->
  Either Text RenameScope
renameScope sources destinations scope = do
  unless
    (scopeKind scope == Standalone && "database-" `T.isPrefixOf` nameText (scopeName scope))
    (Left "rename needs a standalone database scope")
  (sourceStateful, sourceNative) <- statefulOf sources
  (destinationStateful, destinationNative) <- statefulOf destinations
  unless
    (sourceStateful ^. #identity == destinationStateful ^. #identity)
    (Left "renamed StatefulSet changed its logical identity")
  (sourceNamespace, sourceName) <- located (sourceStateful ^. #address)
  (destinationNamespace, destinationName) <- located (destinationStateful ^. #address)
  unless (sourceNamespace == destinationNamespace) (Left "rename may not change the namespace")
  unless (sourceName /= destinationName) (Left "rename needs a new database name")
  sourceImage <- containerImage sourceNative
  destinationImage <- containerImage destinationNative
  unless (sourceImage == destinationImage) (Left "rename may not change the PostgreSQL image")
  unless (postgresImage sourceImage) (Left "rename supports only PostgreSQL")
  pure
    RenameScope
      { owner = scope
      , namespace = sourceNamespace
      , sourceDatabase = sourceName
      , destinationDatabase = destinationName
      , image = sourceImage
      , writer = sourceStateful ^. #identity
      }
  where
    statefulOf members = case [ entry
                              | entry@(declaration, _) <- Map.elems members
                              , declaration ^. #owner == scope
                              , renameMember declaration == Right RenameWorkload
                              ] of
      [entry] -> Right entry
      _ -> Left "rename needs exactly one database StatefulSet on each side"
    located (Kubernetes _ _ _ (Just namespaceName) name) = Right (namespaceName, name)
    located _ = Left "database StatefulSet has no namespaced address"
    postgresImage reference =
      let repository = T.takeWhile (\c -> c /= ':' && c /= '@') (last (T.splitOn "/" reference))
       in repository == "postgres"

containerImage :: ByteString -> Either Text Text
containerImage native = do
  value <- first T.pack (eitherDecodeStrict native)
  case value of
    Object root
      | Just (Object spec) <- KM.lookup "spec" root
      , Just (Object template) <- KM.lookup "template" spec
      , Just (Object podSpec) <- KM.lookup "spec" template
      , Just (Array containers) <- KM.lookup "containers" podSpec
      , [Object container] <- V.toList containers
      , Just (String reference) <- KM.lookup "image" container ->
          Right reference
    _ -> Left "database StatefulSet must run exactly one container image"

-- | The reviewed evidence each durable member's adapter checks. The source
-- incarnation itself is the recovery point and stays retained until a
-- separate reviewed collection.
renameContract :: RenameScope -> ManagedResource -> Either Text MigrationContract
renameContract scope source = case source ^. #dataPolicy of
  Stateless -> Right StatelessMigration
  Durable _ ->
    DurableMigration
      <$> evidence ["kind" .= ("retained-source-incarnation" :: Text), "resource" .= resource, "sourceAddress" .= (source ^. #address)]
      <*> evidence ["kind" .= ("postgres-same-image" :: Text), "image" .= (scope ^. #image)]
      <*> evidence ["kind" .= ("writer-scaled-to-zero" :: Text), "writer" .= (scope ^. #writer)]
      <*> evidence ["kind" .= ("source-retained-until-collection" :: Text), "resource" .= resource]
  where
    resource = source ^. #identity
    evidence fields = contentDigest <$> canonicalValue (object fields)

-- | Copy a generated credential's values unchanged except for the in-cluster
-- host in its connection URL. @POSTGRES_DB@ keeps naming the SQL database
-- inside the copied data directory.
rewriteCredentialData :: RenameScope -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
rewriteCredentialData scope fields = case KM.lookup "DATABASE_URL" fields of
  Just (String encoded) -> do
    url <- b64decode encoded
    let marker host = "@" <> host <> ":"
        sourceHost = marker (dbHost (nameText (scope ^. #sourceDatabase)) (nameText (scope ^. #namespace)))
        destinationHost = marker (dbHost (nameText (scope ^. #destinationDatabase)) (nameText (scope ^. #namespace)))
    unless (T.count sourceHost url == 1) (Left "source connection URL does not name the source database host")
    pure (KM.insert "DATABASE_URL" (String (b64encode (T.replace sourceHost destinationHost url))) fields)
  _ -> Left "source credential lacks a connection URL"

-- | Marks a StatefulSet scaled to zero, or a CronJob suspended, by a reviewed
-- migration. Observation treats exactly that state as the retained
-- incarnation, not as drift.
fenceAnnotation :: Key
fenceAnnotation = "nagare.dev/migration-fence"

-- | A reviewed rename scales the old StatefulSet to zero, or suspends the old
-- CronJob, and marks it. That exact state is the retained incarnation,
-- observed unready rather than as drift; any other difference still counts.
migrationFenced :: Value -> Value -> Bool
migrationFenced (Object desired) (Object observed) =
  KM.lookup "kind" desired `elem` [Just (String "StatefulSet"), Just (String "CronJob")]
    && ( case KM.lookup "metadata" observed of
           Just (Object metadata) -> case KM.lookup "annotations" metadata of
             Just (Object annotations) -> case KM.lookup fenceAnnotation annotations of
               Just (String marker) -> not (T.null marker)
               _ -> False
             _ -> False
           _ -> False
       )
    && ( case KM.lookup "spec" observed of
           Just (Object spec) -> KM.lookup fencedField spec == Just fencedValue
           _ -> False
       )
  where
    (fencedField, fencedValue) = migrationFence (Object desired)
migrationFenced _ _ = False

migrationFence :: Value -> (Key, Value)
migrationFence (Object root)
  | KM.lookup "kind" root == Just (String "CronJob") = ("suspend", Bool True)
migrationFence _ = ("replicas", Number 0)

scaledToZero :: Value -> Value
scaledToZero (Object root) = case KM.lookup "spec" root of
  Just (Object spec) ->
    let (field, value) = migrationFence (Object root)
     in Object (KM.insert "spec" (Object (KM.insert field value spec)) root)
  _ -> Object root
scaledToZero value = value

data TransferMode = TransferCopy | TransferVerify
  deriving stock (Eq, Show)

transferJobName :: OperationId -> TransferMode -> Text
transferJobName operation mode =
  "nagare-migrate-"
    <> T.takeEnd 12 (operationIdText operation)
    <> case mode of
      TransferCopy -> "-copy"
      TransferVerify -> "-verify"

-- | A one-shot Job on the database image. It mounts the fenced source
-- read-only and either copies into the empty destination or only compares
-- the two. Its termination message carries both manifest digests.
transferJob :: RenameScope -> OperationId -> TransferMode -> Name -> Name -> Value
transferJob scope operation mode sourceClaim destinationClaim =
  object
    [ "apiVersion" .= ("batch/v1" :: Text)
    , "kind" .= ("Job" :: Text)
    , "metadata"
        .= object
          [ "name" .= transferJobName operation mode
          , "namespace" .= nameText (scope ^. #namespace)
          , "labels" .= object ["nagare.dev/migration-operation" .= operationIdText operation]
          ]
    , "spec"
        .= object
          [ "backoffLimit" .= (0 :: Int)
          , "template"
              .= object
                [ "metadata" .= object ["labels" .= object ["nagare.dev/migration-operation" .= operationIdText operation]]
                , "spec"
                    .= object
                      [ "restartPolicy" .= ("Never" :: Text)
                      , "containers"
                          .= [ object
                                 [ "name" .= ("transfer" :: Text)
                                 , "image" .= (scope ^. #image)
                                 , "command" .= (["sh", "-c", transferScript] :: [Text])
                                 , "env" .= [object ["name" .= ("MODE" :: Text), "value" .= modeText]]
                                 , "volumeMounts"
                                     .= [ object ["name" .= ("source" :: Text), "mountPath" .= ("/migration/source" :: Text), "readOnly" .= True]
                                        , object ["name" .= ("destination" :: Text), "mountPath" .= ("/migration/destination" :: Text), "readOnly" .= (mode == TransferVerify)]
                                        ]
                                 ]
                             ]
                      , "volumes"
                          .= [ object ["name" .= ("source" :: Text), "persistentVolumeClaim" .= object ["claimName" .= nameText sourceClaim, "readOnly" .= True]]
                             , object ["name" .= ("destination" :: Text), "persistentVolumeClaim" .= object ["claimName" .= nameText destinationClaim]]
                             ]
                      ]
                ]
          ]
    ]
  where
    modeText :: Text
    modeText = case mode of
      TransferCopy -> "copy"
      TransferVerify -> "verify"

-- | Manifest lines list every path except a filesystem's @lost+found@ with
-- its type, owner, mode and content digest, in byte order. Copy refuses a
-- non-empty destination unless it already equals the source, so a retry after
-- a lost acknowledgement proves the earlier copy rather than repeating it.
--
-- F61: a copy marks the destination incomplete before writing and clears the
-- mark only after the whole copy. A copy that died part way (an evicted pod, a
-- full disk) leaves the mark, so the retry clears that partial data and copies
-- again. A destination with other data and no mark still refuses.
transferScript :: Text
transferScript =
  T.unlines
    [ "set -eu"
    , "fail() { printf '{\"error\":\"%s\"}' \"$1\" > /dev/termination-log; exit 1; }"
    , "manifest() {"
    , "  ( cd \"$1\" && find . -mindepth 1 \\( -path ./lost+found -prune \\) -o -print | LC_ALL=C sort | while IFS= read -r p; do"
    , "      if [ -L \"$p\" ]; then printf 'l %s %s\\n' \"$p\" \"$(readlink \"$p\")\";"
    , "      elif [ -d \"$p\" ]; then printf 'd %s %s\\n' \"$p\" \"$(stat -c %u:%g:%a \"$p\")\";"
    , "      elif [ -f \"$p\" ]; then printf 'f %s %s %s\\n' \"$p\" \"$(stat -c %u:%g:%a \"$p\")\" \"$(sha256sum < \"$p\" | cut -d' ' -f1)\";"
    , "      else printf 'o %s\\n' \"$p\"; fi"
    , "    done ) | sha256sum | cut -d' ' -f1"
    , "}"
    , "src=/migration/source; dst=/migration/destination; mark=\"$dst/.nagare-transfer-incomplete\""
    , "[ -n \"$(cd \"$src\" && find . -mindepth 1 -maxdepth 1 ! -name lost+found -print)\" ] || fail 'source volume is empty'"
    , "source_manifest=$(manifest \"$src\")"
    , "if [ \"$MODE\" = copy ]; then"
    , "  if [ -z \"$(cd \"$dst\" && find . -mindepth 1 -maxdepth 1 ! -name lost+found -print)\" ] || [ -e \"$mark\" ]; then"
    , "    ( cd \"$dst\" && find . -mindepth 1 -maxdepth 1 ! -name lost+found ! -name .nagare-transfer-incomplete -exec rm -rf {} + ) || fail 'clearing an incomplete copy failed'"
    , "    : > \"$mark\" || fail 'copy failed'"
    , "    cp -a \"$src\"/. \"$dst\"/ || fail 'copy failed'"
    , "    rm -f \"$mark\" || fail 'copy failed'"
    , "  elif [ \"$(manifest \"$dst\")\" != \"$source_manifest\" ]; then"
    , "    fail 'destination volume is not empty and differs from the source'"
    , "  fi"
    , "fi"
    , "destination_manifest=$(manifest \"$dst\")"
    , "[ \"$destination_manifest\" = \"$source_manifest\" ] || fail 'destination manifest differs from the source'"
    , "printf '{\"source\":\"%s\",\"destination\":\"%s\"}' \"$source_manifest\" \"$destination_manifest\" > /dev/termination-log"
    ]

data TransferManifest = TransferManifest
  { sourceManifest :: !Text
  , destinationManifest :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | Accept only equal, well-formed SHA-256 manifest digests.
parseTransferManifest :: ByteString -> Either Text TransferManifest
parseTransferManifest bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  case value of
    Object root
      | Just (String source) <- KM.lookup (Key.fromText "source") root
      , Just (String destination) <- KM.lookup (Key.fromText "destination") root
      , hex source
      , source == destination ->
          Right (TransferManifest source destination)
      | Just (String reason) <- KM.lookup "error" root -> Left ("volume transfer refused: " <> reason)
    _ -> Left "volume transfer reported no matching manifests"
  where
    hex digest = T.length digest == 64 && T.all (`elem` ("0123456789abcdef" :: String)) digest
