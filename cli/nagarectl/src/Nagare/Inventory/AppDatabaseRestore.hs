-- | Reviewed scratch restore of one app database (EP-202). The archive is an
-- accepted, ingested scheduled run of that app database; the Job rereads and
-- checks its exact bytes, then, as the server's administrator, loads it under
-- scratch names owned by the app's migration user with the declared access.
-- No other app database's names are touched, and the target server is pinned
-- to its recorded incarnations.
module Nagare.Inventory.AppDatabaseRestore
  ( AppDatabaseRestoreRequest (..)
  , RestoreTarget (..)
  , compileAppDatabaseRestoreScope
  , appDatabaseRestoreShell
  , appDatabaseRebuiltShell
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Data.Vector qualified as V
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend, storeObjectUrl)
import Nagare.Database.AppDatabase.Backup (appDatabaseBackupKeyPrefix)
import Nagare.Database.AppDatabase.Sql (renderScratchRestore)
import Nagare.Database.Backup (appDatabaseBackupExt, manualDatabaseJobName)
import Nagare.Database.Restore (RestoreJobInputs (..), VerifiedRestoreSource (..), renderAppDatabaseRestoreJob)
import Nagare.Dsl.Database (Engine (..), dbSecretName, parseEngine)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Restore (scratchDatabaseName)
import Nagare.Inventory.RestoreNative (acceptedValue, sameCluster)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), RecoveryClass (VerifyBeforeRetry), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data AppDatabaseRestoreRequest = AppDatabaseRestoreRequest
  { appDatabase :: !Text
  , namespace :: !Text
  , restoreId :: !Text
  , appScope :: !ScopeDeclaration
  -- ^ the accepted @appdb-@ scope
  , serverScope :: !ScopeDeclaration
  -- ^ the accepted scope of the server the app database lives in
  , receiptScope :: !ScopeDeclaration
  -- ^ the accepted ingestion of the scheduled run to restore
  , targetStatefulUid :: !PhysicalIdentity
  , targetPvcUid :: !PhysicalIdentity
  , backend :: !StoreBackend
  , source :: !SourceLocation
  , target :: !RestoreTarget
  , serverRevision :: !ScopeRevision
  -- ^ the server scope's accepted revision, which admission re-checks
  }
  deriving stock (Generic, Eq, Show)

-- | Scratch names beside the live databases, or (M6) the declared databases
-- themselves after a server rebuild, which must still be empty.
data RestoreTarget = ScratchTarget | RebuiltTarget
  deriving stock (Eq, Show)

compileAppDatabaseRestoreScope ::
  AppDatabaseRestoreRequest ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileAppDatabaseRestoreScope request native = do
  let appName = request ^. #appDatabase
      ns = request ^. #namespace
      appMembers = members (request ^. #appScope)
      receipt = scopeOverrides (request ^. #receiptScope)
      required key = maybe (Left (invalid ("accepted backup lacks " <> key))) Right (Map.lookup key receipt)
  unless
    (T.length (request ^. #restoreId) <= 20 && T.all (\c -> c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9']) (request ^. #restoreId) && not (T.null (request ^. #restoreId)))
    (Left (invalid "restore ID must be 1-20 lowercase letters or digits"))
  -- The backup is an ingested run of exactly this app database.
  sourceScope <- required "scheduled.backup.source.scope"
  kind <- required "scheduled.backup.source.kind"
  unless
    (sourceScope == scopeIdText (scopeId (request ^. #appScope)) && kind == "app-database")
    (Left (invalid "the backup is not an ingested run of this app database"))
  (engine, migration, runtime, databases, stateful) <- case ( [(engineText, nameText user, role) | member <- appMembers, DatabaseUser _ user <- [member ^. #address], DatabaseUserSpec engineText role _ _ _ <- [member ^. #spec]]
                                                            , [(nameText db, target) | member <- appMembers, DatabaseName target db <- [member ^. #address]]
                                                            ) of
    (users@((engineText, _, _) : _), dbs@((_, target) : _))
      | Just engine <- parseEngine engineText
      , [migration] <- [user | (_, user, "migration") <- users]
      , [runtime] <- [user | (_, user, "runtime") <- users] ->
          Right (engine, migration, runtime, sort (map fst dbs), target)
    _ -> Left (invalid "the app database scope has no users and databases")
  serverStateful <- case [member | member <- members (request ^. #serverScope), member ^. #identity == stateful] of
    [member] -> Right member
    _ -> Left (invalid "the server scope lacks the app database's StatefulSet")
  server <- case serverStateful ^. #address of
    Kubernetes _ "apps" _ (Just _) name -> Right (nameText name)
    _ -> Left (invalid "the app database's server has no StatefulSet address")
  let byAddress objectKind name = [member | member <- members (request ^. #serverScope), Kubernetes _ "" k (Just n) nativeName <- [member ^. #address], nameText k == objectKind, nameText n == ns, nameText nativeName == name]
  pvc <- case byAddress "persistentvolumeclaim" (dbPvcName server) of
    [member] -> Right member
    _ -> Left (invalid "the server scope has no unique PVC")
  credential <- case byAddress "secret" (dbSecretName server) of
    [member] -> Right member
    _ -> Left (invalid "the server scope has no unique administrator credential")
  statefulValue <- acceptedValue invalid native serverStateful
  _ <- acceptedValue invalid native pvc
  _ <- acceptedValue invalid native credential
  cluster <- case serverStateful ^. #address of
    Kubernetes clusterId _ _ _ _ -> Right clusterId
    _ -> Left (invalid "the server has no Kubernetes address")
  unless (all (sameCluster cluster) [pvc, credential]) (Left (invalid "restore resources belong to different clusters"))
  clientImage <- first invalid (containerImage statefulValue)
  objectUrl <- required "scheduled.backup.object"
  receiptUrl <- required "scheduled.backup.receipt"
  backupId <- required "scheduled.backup.id"
  checksum <- required "scheduled.backup.object.sha256"
  receiptDigest <- required "scheduled.backup.receipt.digest" >>= first invalid . mkContentDigest
  objectVersion <- required "scheduled.backup.object.version"
  receiptVersion <- required "scheduled.backup.receipt.version"
  unless
    ( objectUrl == storeObjectUrl (request ^. #backend) (appDatabaseBackupKeyPrefix ns appName <> backupId <> "." <> appDatabaseBackupExt engine)
        && receiptUrl == objectUrl <> ".receipt.json"
        && all (not . T.null) [objectVersion, receiptVersion]
    )
    (Left (invalid "the backup has another address or lacks exact versions"))
  scratches <- traverse (\db -> (db,) <$> first invalid (scratchDatabaseName db (request ^. #restoreId))) databases
  let targets = if request ^. #target == RebuiltTarget then databases else map snd scratches
  firstScratch <- case targets of
    target : _ -> Right target
    [] -> Left (invalid "the app database has no databases")
  owner <- first invalid (mkScopeId Standalone ("appdb-restore-" <> ns <> "-" <> appName <> "-" <> request ^. #restoreId))
  key <- first invalid (mkLogicalKey (request ^. #restoreId))
  jobRole <- first invalid (mkName "job")
  proofRole <- first invalid (mkName "restore")
  let jobId = mintResourceId owner key jobRole
      proofId = mintResourceId owner key proofRole
      jobName = manualDatabaseJobName "nagare-dbrestore-" appName (request ^. #restoreId)
      inputs =
        RestoreJobInputs
          { namespace = ns
          , jobName = jobName
          , engine = engine
          , clientImage = clientImage
          , serviceHost = server
          , secretName = dbSecretName server
          , name = server
          , sourceUrl = objectUrl
          , liveTarget = False
          , verifiedSource = Just (VerifiedRestoreSource receiptUrl (digestText receiptDigest) checksum firstScratch 0 (Just objectVersion) (Just receiptVersion))
          , backend = request ^. #backend
          }
  rendered <-
    first
      (invalid . T.pack . show)
      ( Yaml.decodeEither'
          ( renderAppDatabaseRestoreJob
              inputs
              ( case request ^. #target of
                  ScratchTarget -> appDatabaseRestoreShell engine server scratches migration runtime
                  RebuiltTarget -> appDatabaseRebuiltShell engine server databases (request ^. #restoreId)
              )
          ) ::
          Either Yaml.ParseException Value
      )
  job <- first invalid (annotate rendered [("nagare.dev/restore-id", request ^. #restoreId), ("nagare.dev/restore-backup-object", objectUrl), ("nagare.dev/restore-target-statefulset", resourceIdText stateful), ("nagare.dev/restore-target-statefulset-uid", physicalIdentityText (request ^. #targetStatefulUid)), ("nagare.dev/restore-target-pvc", resourceIdText (pvc ^. #identity)), ("nagare.dev/restore-target-pvc-uid", physicalIdentityText (request ^. #targetPvcUid)), ("nagare.dev/restore-target-database", firstScratch)])
  canonical <- first invalid (canonicalValue job)
  (bound, bytes) <-
    first
      (:| [])
      ( bindKubernetesObject
          KubernetesInput
            { resourceId = jobId
            , ownerScope = owner
            , clusterId = cluster
            , inputObject = job
            , objectDigest = contentDigest canonical
            , lifecyclePolicy = DeleteWhenUnreferenced
            , inputDataPolicy = Stateless
            , inputSensitivity = Private
            , sourceLocation = request ^. #source
            }
      )
  receiptJobs <- Right [member ^. #identity | member <- members (request ^. #receiptScope)]
  let member = bound {dependencies = sort (map OrderedAfter ([serverStateful ^. #identity, pvc ^. #identity, credential ^. #identity] <> receiptJobs))}
      proof = DeclaredOperation proofId (jobId :| []) (sort [ContentInput (contentDigest bytes), ContentInput receiptDigest]) VerifyBeforeRetry RestoreData
      overrides =
        Map.fromList
          [ ("restore.id", request ^. #restoreId)
          , ("restore.app-database", appName)
          , ("restore.namespace", ns)
          , ("restore.backup.id", backupId)
          , ("restore.backup.scope", scopeIdText (scopeId (request ^. #receiptScope)))
          , ("restore.backup.object", objectUrl)
          , ("restore.backup.receipt", receiptUrl)
          , ("restore.backup.receipt.digest", digestText receiptDigest)
          , ("restore.backup.sha256", checksum)
          , ("restore.target.scope", scopeIdText (scopeId (request ^. #serverScope)))
          , ("restore.target.generation", T.pack (show (generationNumber (revisionGeneration (request ^. #serverRevision)))))
          , ("restore.target.revision", digestText (revisionDigest (request ^. #serverRevision)))
          , ("restore.target.statefulset", resourceIdText stateful)
          , ("restore.target.statefulset.uid", physicalIdentityText (request ^. #targetStatefulUid))
          , ("restore.target.pvc", resourceIdText (pvc ^. #identity))
          , ("restore.target.pvc.uid", physicalIdentityText (request ^. #targetPvcUid))
          , ("restore.target.databases", T.intercalate "," targets)
          , ("restore.target.kind", if request ^. #target == RebuiltTarget then "rebuilt" else "scratch")
          ]
  base <- mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [proof] []]
  pure (withScopeOverrides overrides (withScopeConfigDigest (contentDigest canonical) base), Map.singleton jobId (member, bytes))
  where
    members scope = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]
    invalid message =
      (inventoryError "invalid-app-database-restore" message & #scopes .~ [scopeId (request ^. #appScope)] & #sources .~ [request ^. #source]) :| []
    annotate value pairs = case value of
      Object root
        | Just (Object metadata) <- KM.lookup "metadata" root ->
            Right (Object (KM.insert "metadata" (Object (KM.insert "annotations" (object [fromString' k .= v | (k, v) <- pairs]) metadata)) root))
      _ -> Left "app-database restore Job lacks metadata"
    fromString' = Key.fromText
    containerImage value = case value of
      Object root
        | Just (Object spec) <- KM.lookup "spec" root
        , Just (Object template) <- KM.lookup "template" spec
        , Just (Object podSpec) <- KM.lookup "spec" template
        , Just (Array containers) <- KM.lookup "containers" podSpec
        , [Object container] <- V.toList containers
        , Just (String found) <- KM.lookup "image" container ->
            Right found
      _ -> Left "server StatefulSet has no single container image"

-- | M6: load into the declared databases of a rebuilt server, re-applied
-- empty by the app-database scope. Each engine first refuses a database that
-- already holds data; PostgreSQL then loads the dump keeping owners and ACLs,
-- ClickHouse restores the archive into the existing empty databases under
-- their own names (grants are kept by name).
appDatabaseRebuiltShell :: Engine -> Text -> [Text] -> Text -> Text
appDatabaseRebuiltShell ClickHouse server databases restoreKey =
  let archive = "nagare-rebuild-" <> restoreKey <> ".zip"
      list = T.intercalate ", " ["'" <> db <> "'" | db <- databases]
   in "set -e; ch() { clickhouse-client -h "
        <> server
        <> " --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\" --query \"$1\"; }; "
        <> "test \"$(ch \"SELECT count() FROM system.databases WHERE name IN ("
        <> list
        <> ")\")\" = "
        <> T.pack (show (length databases))
        <> " || { echo \"the declared databases are not all present; re-apply the app database first\" >&2; exit 4; }; "
        <> "tables=\"$(ch \"SELECT count() FROM system.tables WHERE database IN ("
        <> list
        <> ")\")\"; test \"$tables\" = 0 || { echo \"the declared databases already hold $tables tables; refusing to restore over data\" >&2; exit 3; }; "
        <> "ARCHIVE=\"/source-data/backups/"
        <> archive
        <> "\"; test ! -e \"$ARCHIVE\"; mkdir -p /source-data/backups; cp /dump/backup.zip \"$ARCHIVE\"; "
        <> "ch \"RESTORE "
        <> T.intercalate ", " ["DATABASE " <> db | db <- databases]
        <> " FROM File('"
        <> archive
        <> "')\"; rm -- \"$ARCHIVE\""
appDatabaseRebuiltShell _ server databases _ =
  "set -e; "
    <> T.concat
      [ "relations=\"$(psql -tA -v ON_ERROR_STOP=1 -h "
          <> server
          <> " -U \"$POSTGRES_USER\" -d "
          <> db
          <> " -c \"select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_toast%' and n.nspname not like 'pg_temp%'\")\"; "
          <> "test \"$relations\" = 0 || { echo \"database "
          <> db
          <> " already holds $relations relations; refusing to restore over data\" >&2; exit 3; }; "
          <> "pg_restore --exit-on-error -h "
          <> server
          <> " -U \"$POSTGRES_USER\" -d "
          <> db
          <> " /dump/backup.sql; "
      | db <- databases
      ]

-- | The restore shell, run as the administrator: PostgreSQL creates the
-- scratch database with its declared access and loads the custom-format dump
-- keeping owners and ACLs; ClickHouse restores every database under its
-- scratch name from the archive placed on the server's volume, then grants
-- the declared access. A leftover scratch name refuses.
appDatabaseRestoreShell :: Engine -> Text -> [(Text, Text)] -> Text -> Text -> Text
appDatabaseRestoreShell ClickHouse server scratches migration runtime =
  let archive = "nagare-restore-" <> firstScratch <> ".zip"
      firstScratch = maybe "" snd (listToMaybe scratches)
   in "set -e; ARCHIVE=\"/source-data/backups/"
        <> archive
        <> "\"; test ! -e \"$ARCHIVE\"; mkdir -p /source-data/backups; cp /dump/backup.zip \"$ARCHIVE\"; "
        <> "clickhouse-client -h "
        <> server
        <> " --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\" --multiquery <<'SQL'\n"
        <> renderScratchRestore ClickHouse scratches archive migration runtime
        <> "SQL\nrm -- \"$ARCHIVE\""
appDatabaseRestoreShell engine server scratches migration runtime =
  "set -e; psql -v ON_ERROR_STOP=1 -X -q -h "
    <> server
    <> " -U \"$POSTGRES_USER\" -d postgres <<'SQL'\n"
    <> renderScratchRestore engine scratches "" migration runtime
    <> "SQL\n"
    <> T.concat ["pg_restore --exit-on-error -h " <> server <> " -U \"$POSTGRES_USER\" -d " <> scratch <> " /dump/backup.sql\n" | (_, scratch) <- scratches]
