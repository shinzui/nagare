-- | App databases on shared servers (EP-202). An app database is its own
-- standalone scope, @appdb-\<key\>@, holding typed references into an accepted
-- server scope (@database-\<key\>@). A server is either bound directly by
-- workloads, as before, or shared by app databases, never both: planning
-- refuses an app database on a directly bound server here, and a direct
-- binding of a shared server where bindings are resolved.
module Nagare.Inventory.AppDatabase
  ( AppDatabaseServer (..)
  , appDatabaseScopeId
  , acceptedAppDatabaseServer
  , directServerBindings
  , serverHostsAppDatabases
  , compileStandaloneAppDatabase
  , namedAppDatabaseScope
  , retireAppDatabaseScope
  , scheduleSuspended
  , AppDatabaseScheduleSource (..)
  , appDatabaseScheduleSource
  , rotateAppDatabaseScope
  , AppDatabaseRow (..)
  , appDatabaseRows
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Data.Yaml qualified as Yaml
import Nagare.Database.AppDatabase.Backup (AppDatabaseBackup (..), appDatabaseBackupScheduleName, renderInventoryAppDatabaseBackupCronJob)
import Nagare.Dsl.AppDatabase (AppDatabase (..), appDatabaseNameText, logicalDatabaseNameText)
import Nagare.Dsl.Config (encodeAppDatabases)
import Nagare.Dsl.Database (Engine, engineToken)
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (databaseNameText, namespaceText)
import Nagare.Inventory.Adapters.CredentialTemplate (databaseCredentialKind)
import Nagare.Inventory.Database (DatabaseBackupTarget)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.AppDatabase
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (RecoveryClass (VerifyBeforeRetry), RecoveryIntent)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | The accepted server an app database lives in.
data AppDatabaseServer = AppDatabaseServer
  { statefulSet :: !ManagedResource
  , engine :: !Engine
  , image :: !Text
  -- ^ the server's engine image, which the backup schedule runs as its client
  }
  deriving stock (Generic, Eq, Show)

appDatabaseScopeId :: AppDatabase -> Either Text ScopeId
appDatabaseScopeId db = do
  key <- appDatabaseScopeKey db
  mkScopeId Standalone ("appdb-" <> logicalKeyText key)

-- | Find the server by its native StatefulSet address in a standalone
-- @database-@ scope, and read its engine from that scope's credential
-- template. A server of the same name in another namespace is reported as a
-- namespace mismatch, not as absent.
acceptedAppDatabaseServer ::
  ScopeSnapshot ->
  Map ResourceId (ManagedResource, ByteString) ->
  ResourceId ->
  AppDatabase ->
  Either InventoryError AppDatabaseServer
acceptedAppDatabaseServer snapshot native cluster db = do
  let serverName = databaseNameText (db ^. #server)
      namespaceName = namespaceText (db ^. #namespace)
      servers =
        [ (owner, resource, resources)
        | (owner, (_, scope)) <- Map.toList (snapshotScopes snapshot)
        , scopeKind owner == Standalone
        , "database-" `T.isPrefixOf` nameText (scopeName owner)
        , let resources = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]
        , resource <- resources
        , Kubernetes target "apps" kind (Just _) name <- [resource ^. #address]
        , target == cluster
        , nameText kind == "statefulset"
        , nameText name == serverName
        ]
      inNamespace = [found | found@(_, resource, _) <- servers, statefulNamespace resource == Just namespaceName]
  (_, stateful, resources) <- case (inNamespace, servers) of
    ([found], _) -> Right found
    ([], []) -> Left (refuse "app-database-server-absent" ("server " <> serverName <> " is not an accepted managed database"))
    ([], _) -> Left (refuse "app-database-server-namespace" ("server " <> serverName <> " is not in namespace " <> namespaceName))
    _ -> Left (refuse "app-database-server-ambiguous" ("server " <> serverName <> " has more than one accepted StatefulSet"))
  credential <- case [member | member <- resources, Just prefix <- [T.stripSuffix "/statefulset" (resourceIdText (stateful ^. #identity))], resourceIdText (member ^. #identity) == prefix <> "/credential"] of
    [member] -> Right member
    _ -> Left (refuse "app-database-server-absent" ("server " <> serverName <> " has no accepted credential"))
  bytes <- case Map.lookup (credential ^. #identity) native of
    Just (member, nativeBytes) | member == credential -> Right nativeBytes
    _ -> Left (refuse "app-database-server-absent" ("server " <> serverName <> " credential has no private native template"))
  value <- first (refuse "app-database-server-absent" . T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
  serverEngine <- case databaseCredentialKind value of
    Right (Just (_, _, parsed)) -> Right parsed
    _ -> Left (refuse "app-database-server-absent" ("server " <> serverName <> " credential is not a database credential"))
  unless
    (serverEngine == db ^. #engine)
    ( Left
        ( refuse
            "app-database-server-engine"
            ("server " <> serverName <> " runs " <> engineToken serverEngine <> ", not " <> engineToken (db ^. #engine))
        )
    )
  serverImage <- case Map.lookup (stateful ^. #identity) native of
    Just (member, nativeBytes) | member == stateful -> first (refuse "app-database-server-absent") (containerImage nativeBytes)
    _ -> Left (refuse "app-database-server-absent" ("server " <> serverName <> " StatefulSet has no private native object"))
  pure (AppDatabaseServer stateful serverEngine serverImage)
  where
    statefulNamespace resource = case resource ^. #address of
      Kubernetes _ _ _ (Just namespace) _ -> Just (nameText namespace)
      _ -> Nothing
    refuse = inventoryError
    containerImage bytes = do
      value <- first (T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      case value of
        Object root
          | Just (Object spec) <- KM.lookup "spec" root
          , Just (Object template) <- KM.lookup "template" spec
          , Just (Object podSpec) <- KM.lookup "spec" template
          , Just (Array containers) <- KM.lookup "containers" podSpec
          , [Object container] <- V.toList containers
          , Just (String found) <- KM.lookup "image" container ->
              Right found
        _ -> Left "server StatefulSet has no single container image"

-- | Accepted members that bind a server directly: anything ordered after its
-- StatefulSet outside the server's own scope, its rebuild-restore scopes
-- (@database-*@) and app-database scopes (@appdb-*@). Workloads that bind a
-- database list its StatefulSet among their dependencies.
directServerBindings :: ScopeSnapshot -> ManagedResource -> [ManagedResource]
directServerBindings snapshot stateful =
  [ member
  | (owner, (_, scope)) <- Map.toList (snapshotScopes snapshot)
  , owner /= stateful ^. #owner
  , not (any (`T.isPrefixOf` nameText (scopeName owner)) ["database-", "appdb-"])
  , bundle <- scopeBundles scope
  , Managed member <- declarations bundle
  , OrderedAfter (stateful ^. #identity) `elem` member ^. #dependencies
  ]

-- | Whether any accepted app database claims a user or database on the server.
serverHostsAppDatabases :: ScopeSnapshot -> ResourceId -> Bool
serverHostsAppDatabases snapshot stateful =
  or
    [ case member ^. #address of
        DatabaseName target _ -> target == stateful
        DatabaseUser target _ -> target == stateful
        _ -> False
    | (_, (_, scope)) <- Map.toList (snapshotScopes snapshot)
    , bundle <- scopeBundles scope
    , Managed member <- declarations bundle
    ]

-- | Compile one app database into its own standalone scope against the
-- accepted server. Refuses an absent server, a different engine or
-- namespace, and a server that a workload binds directly.
compileStandaloneAppDatabase ::
  ScopeSnapshot ->
  Map ResourceId (ManagedResource, ByteString) ->
  DatabaseBackupTarget ->
  AppDatabase ->
  ResourceId ->
  Maybe ResourceId ->
  RecoveryIntent ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneAppDatabase snapshot acceptedNative target db cluster namespaceId recovery source = do
  owner <- first (invalid Nothing) (appDatabaseScopeId db)
  serverFound <- first (\err -> (err & #scopes .~ [owner] & #sources .~ [source]) :| []) (acceptedAppDatabaseServer snapshot acceptedNative cluster db)
  let stateful = serverFound ^. #statefulSet
  case directServerBindings snapshot stateful of
    [] -> pure ()
    bound ->
      Left
        . (:| [])
        $ ( inventoryError
              "app-database-on-direct-server"
              ( "server "
                  <> databaseNameText (db ^. #server)
                  <> " is bound directly by a workload; a server is either bound directly or shared by app databases"
              )
              & #scopes
              .~ [owner]
              & #resources
              .~ map (^. #identity) bound
              & #sources
              .~ [source]
          )
  -- Every app database has its own schedule, dumped with its migration
  -- credential; its receipts pin this declaration's digest.
  let schedule =
        renderInventoryAppDatabaseBackupCronJob
          (target ^. #objective)
          AppDatabaseBackup
            { namespace = namespaceText (db ^. #namespace)
            , appDatabase = appDatabaseNameText (db ^. #name)
            , server = databaseNameText (db ^. #server)
            , engine = db ^. #engine
            , clientImage = serverFound ^. #image
            , databases = map logicalDatabaseNameText (NE.toList (db ^. #logicalDatabases))
            , declaration = digestText (contentDigest (LBS.toStrict (encodeAppDatabases [db])))
            }
          (target ^. #backend)
          7
  scheduleValue <- first (invalid (Just owner) . T.pack . show) (Yaml.decodeEither' schedule :: Either Yaml.ParseException Value)
  (bundle, native) <-
    compileAppDatabase
      digestOf
      AppDatabaseInput
        { appDatabase = db
        , owner = owner
        , cluster = cluster
        , namespaceResource = namespaceId
        , server = stateful ^. #identity
        , recovery = recovery
        , source = source
        , backupSchedule = Just scheduleValue
        }
  bound <- traverse (bindOne owner bundle) native
  let nativeById = Map.fromList bound
  unless
    (Map.size nativeById == length native && Set.fromList (map fst native) == Map.keysSet nativeById)
    (Left (invalid (Just owner) "app-database native members share an identity"))
  scope <- mkScopeDeclaration owner [bundle]
  pure (scope, nativeById)
  where
    digestOf value = contentDigest <$> canonicalValue value
    invalid owner message =
      inventoryError "invalid-app-database" message
        & #scopes
        .~ maybe [] pure owner
        & #sources
        .~ [source]
        & (:| [])
    bindOne owner bundle (resource, value) = do
      declaration <-
        maybe
          (Left (invalid (Just owner) "app-database native object has no declaration"))
          Right
          (lookup resource [(member ^. #identity, member) | Managed member <- declarations bundle])
      digest <- first (invalid (Just owner)) (digestOf value)
      (recompiled, bytes) <-
        first (:| []) $
          bindKubernetesObject
            KubernetesInput
              { resourceId = resource
              , ownerScope = owner
              , clusterId = cluster
              , inputObject = value
              , objectDigest = digest
              , lifecyclePolicy = declaration ^. #lifecycle
              , inputDataPolicy = declaration ^. #dataPolicy
              , inputSensitivity = declaration ^. #sensitivity
              , sourceLocation = declaration ^. #source
              }
      unless
        (recompiled {dependencies = declaration ^. #dependencies} == declaration)
        (Left (invalid (Just owner) "app-database native object changed during binding"))
      pure (resource, (declaration, bytes))

-- | The accepted app-database scope a command names: @appdb-\<key\>@, where
-- the key is the pinned one or the app-database name.
namedAppDatabaseScope :: ScopeSnapshot -> Text -> Maybe Text -> Either Text ScopeDeclaration
namedAppDatabaseScope snapshot name pinned = do
  key <- mkLogicalKey (fromMaybe name pinned)
  owner <- mkScopeId Standalone ("appdb-" <> logicalKeyText key)
  scope <- maybe (Left ("app database " <> name <> " is not in accepted inventory history")) (Right . snd) (Map.lookup owner (snapshotScopes snapshot))
  unless
    (any (\member -> member ^. #executor == AppDatabaseExecutor) (scopeMembers scope))
    (Left ("accepted scope " <> nameText (scopeName owner) <> " is not an app database"))
  pure scope

-- | Retirement turns the users' logins and the declared access off, suspends
-- the backup schedule (F131), and keeps the databases and Secrets. It refuses
-- while any accepted member outside the scope is ordered after one of its
-- members (a workload binding it). The suspended schedule's receipt metadata,
-- and so its schedule revision, is unchanged, so earlier runs still ingest.
retireAppDatabaseScope ::
  ScopeSnapshot ->
  Map ResourceId (ManagedResource, ByteString) ->
  ScopeDeclaration ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
retireAppDatabaseScope snapshot native scope = do
  let owner = scopeId scope
      ours = Set.fromList (map (^. #identity) (scopeMembers scope))
      consumers =
        [ member
        | (other, (_, otherScope)) <- Map.toList (snapshotScopes snapshot)
        , other /= owner
        , member <- scopeMembers otherScope
        , any (\case OrderedAfter producer -> Set.member producer ours; _ -> False) (member ^. #dependencies)
        ]
  unless
    (null consumers)
    ( Left
        ( ( inventoryError "app-database-in-use" "an accepted workload still binds this app database; remove the binding first"
              & #scopes
              .~ [owner]
              & #resources
              .~ map (^. #identity) consumers
          )
            :| []
        )
    )
  suspended <- Map.fromList <$> traverse suspend [member | member <- scopeMembers scope, Kubernetes _ "batch" kind _ _ <- [member ^. #address], nameText kind == "cronjob"]
  revised <- reviseScope scope (map (\bundle -> bundle & #declarations %~ map (off suspended)) (scopeBundles scope))
  pure (revised, suspended)
  where
    off suspended = \case
      Managed member -> Managed (maybe (member & #spec %~ disable) fst (Map.lookup (member ^. #identity) suspended))
      other -> other
    suspend member = do
      bytes <- case Map.lookup (member ^. #identity) native of
        Just (accepted, bytes) | accepted == member -> Right bytes
        _ -> Left (retirement member "the backup schedule has no private native object")
      value <- first (retirement member . T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      changed <- case value of
        Object root | Just (Object spec) <- KM.lookup "spec" root -> Right (Object (KM.insert "spec" (Object (KM.insert "suspend" (Bool True) spec)) root))
        _ -> Left (retirement member "the backup schedule has no spec")
      changedBytes <- first (retirement member) (canonicalValue changed)
      let updated = member & #spec .~ NativeObject (contentDigest changedBytes)
      pure (member ^. #identity, (updated, changedBytes))
    retirement member message = (inventoryError "invalid-app-database-retirement" message & #scopes .~ [scopeId scope] & #resources .~ [member ^. #identity]) :| []
    disable = \case
      LogicalDatabase engine' migration runtime _ digest -> LogicalDatabase engine' migration runtime False digest
      DatabaseUserSpec engine' role _ digest -> DatabaseUserSpec engine' role False digest
      other -> other

-- | Whether an accepted schedule's native bytes are suspended, as a retired
-- app database's are.
scheduleSuspended :: ByteString -> Bool
scheduleSuspended bytes = case Yaml.decodeEither' bytes :: Either Yaml.ParseException Value of
  Right (Object root) | Just (Object spec) <- KM.lookup "spec" root -> KM.lookup "suspend" spec == Just (Bool True)
  _ -> False

-- | The accepted members an app database's schedule reads (EP-202): the
-- CronJob and signing Secret of its own scope, and the StatefulSet and claim
-- of the server its users live in, which the server's scope owns.
data AppDatabaseScheduleSource = AppDatabaseScheduleSource
  { scope :: !ScopeDeclaration
  , serverScope :: !ScopeDeclaration
  , statefulSet :: !ManagedResource
  , claim :: !ManagedResource
  , schedule :: !ManagedResource
  , signing :: !ManagedResource
  }
  deriving stock (Generic, Eq, Show)

appDatabaseScheduleSource :: ScopeSnapshot -> ResourceId -> Text -> Text -> Either Text AppDatabaseScheduleSource
appDatabaseScheduleSource snapshot cluster namespaceName appDatabase = do
  let scheduleName = appDatabaseBackupScheduleName appDatabase
      scopes = map snd (Map.elems (snapshotScopes snapshot))
      address api kind = kubernetesAddress cluster api kind (Just namespaceName)
      at target scope' = [member | member <- scopeMembers scope', member ^. #address == target]
  cronAddress <- address "batch/v1" "CronJob" scheduleName
  signingAddress <- address "v1" "Secret" (scheduleName <> "-signing")
  (owner, cron) <- case [(scope', member) | scope' <- scopes, member <- at cronAddress scope'] of
    [single] -> Right single
    _ -> Left "app-database schedule requires one accepted backup CronJob"
  signingSecret <- case at signingAddress owner of
    [single] -> Right single
    _ -> Left "app-database schedule requires one accepted backup signing Secret"
  statefulId <- case [target | member <- scopeMembers owner, DatabaseUser target _ <- [member ^. #address]] of
    target : _ -> Right target
    [] -> Left "app-database backup scope names no server"
  (server, stateful) <- case [(scope', member) | scope' <- scopes, member <- scopeMembers scope', member ^. #identity == statefulId] of
    [single] -> Right single
    _ -> Left "app-database schedule requires its accepted server StatefulSet"
  pvcAddress <- case stateful ^. #address of
    Kubernetes _ _ _ _ serverName -> address "v1" "PersistentVolumeClaim" (dbPvcName (nameText serverName))
    _ -> Left "app-database server has no Kubernetes address"
  pvc <- case at pvcAddress server of
    [single] -> Right single
    _ -> Left "app-database schedule requires one accepted server PVC"
  pure (AppDatabaseScheduleSource owner server stateful pvc cron signingSecret)

-- | Rotation is one forward-only operation on one user member, keyed by the
-- role: a new stamp makes a new operation, so each rotation runs once.
rotateAppDatabaseScope :: ScopeDeclaration -> Text -> Text -> Either (NonEmpty InventoryError) ScopeDeclaration
rotateAppDatabaseScope scope role stamp = do
  let owner = scopeId scope
      users = [member | member <- scopeMembers scope, DatabaseUserSpec _ memberRole _ _ <- [member ^. #spec], memberRole == role]
  user <- case users of
    [member] -> Right member
    _ -> Left (single owner ("the app database has no " <> role <> " user"))
  key <- first (single owner) (mkLogicalKey (nameText (scopeName owner)))
  operationName <- first (single owner) (mkName ("rotate-" <> role))
  let operation =
        DeclaredOperation
          { identity = mintResourceId owner key operationName
          , affects = user ^. #identity :| []
          , inputs = [ContentInput (contentDigest (TE.encodeUtf8 ("rotate " <> role <> " at " <> stamp)))]
          , recovery = VerifyBeforeRetry
          , operationKind = RotateCredential
          }
      replace bundle = bundle & #operations %~ ((operation :) . filter (\existing -> existing ^. #identity /= operation ^. #identity))
  case scopeBundles scope of
    first' : rest -> reviseScope scope (replace first' : rest)
    [] -> Left (single owner "the app-database scope has no bundle")
  where
    single owner message = (inventoryError "invalid-app-database-rotation" message & #scopes .~ [owner]) :| []

-- | One accepted app database, as @db app-database list@ shows it.
data AppDatabaseRow = AppDatabaseRow
  { name :: !Text
  , server :: !Text
  , namespace :: !Text
  , engine :: !Text
  , databases :: ![Text]
  , retired :: !Bool
  }
  deriving stock (Generic, Eq, Show)

appDatabaseRows :: ScopeSnapshot -> [AppDatabaseRow]
appDatabaseRows snapshot =
  [ AppDatabaseRow
      (fromMaybe (nameText (scopeName owner)) (T.stripPrefix "appdb-" (nameText (scopeName owner))))
      serverName
      serverNamespace
      engineText
      [nameText db | member <- members, DatabaseName _ db <- [member ^. #address]]
      (not (or [on | member <- members, DatabaseUserSpec _ _ on _ <- [member ^. #spec]]))
  | (owner, (_, scope)) <- Map.toList (snapshotScopes snapshot)
  , "appdb-" `T.isPrefixOf` nameText (scopeName owner)
  , let members = filter ((== AppDatabaseExecutor) . (^. #executor)) (scopeMembers scope)
  , (stateful, engineText) : _ <- [[(target, engine') | member <- members, DatabaseUser target _ <- [member ^. #address], DatabaseUserSpec engine' _ _ _ <- [member ^. #spec]]]
  , let (serverName, serverNamespace) = fromMaybe ("?", "?") (Map.lookup stateful statefulSets)
  ]
  where
    statefulSets =
      Map.fromList
        [ (member ^. #identity, (nameText name, nameText ns))
        | (_, (_, scope)) <- Map.toList (snapshotScopes snapshot)
        , member <- scopeMembers scope
        , Kubernetes _ "apps" _ (Just ns) name <- [member ^. #address]
        ]

scopeMembers :: ScopeDeclaration -> [ManagedResource]
scopeMembers scope = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]

-- | A revision of an accepted scope keeps its config digest and overrides.
reviseScope :: ScopeDeclaration -> [ResourceBundle] -> Either (NonEmpty InventoryError) ScopeDeclaration
reviseScope scope bundles = do
  base <- mkScopeDeclaration (scopeId scope) bundles
  pure $ withScopeOverrides (scopeOverrides scope) $ case scopeConfigDigest scope of
    Nothing -> base
    Just digest -> withScopeConfigDigest digest base
