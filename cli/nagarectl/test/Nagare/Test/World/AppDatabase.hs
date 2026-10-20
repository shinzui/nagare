-- | EP-202 M3: an interpreter world for app-database members. It keeps an
-- in-memory catalog per engine, interprets the adapter's member-level
-- commands with the engine's semantics as M1 proved them, and lets an
-- adversary refuse a statement, lose its acknowledgement, kill the executor
-- after it lands, or fail an observation. The checker reads the catalog
-- through 'worldCatalog', a pure view that never passes through the faults.
module Nagare.Test.World.AppDatabase
  ( World (..)
  , WorldUser (..)
  , WorldDatabase (..)
  , WorldMutation (..)
  , newWorld
  , restartServer
  , worldOps
  , worldCatalog
  , secretKey
  , clickHouseTree
  , compressGrants
  )
where

import Control.Exception (throwIO)
import Control.Monad (foldM)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Nagare.Database.AppDatabase.Catalog
import Nagare.Database.AppDatabase.Sql (DatabaseAccess (..), PasswordHash (..), ReaderAccess (..), clickHouseCeilings, clickHouseDatabaseGrants, clickhouseHashMatches, postgresTimeout, scramVerifierMatches)
import Nagare.Dsl.AppDatabase (AppDatabaseRole (..), Grant (..), appDatabaseDatabaseGrants, appDatabaseServerGrants, appDatabaseServerRevokedGrants, runtimeOwnsObjects)
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.AppDatabase
import Nagare.Resource.Inventory (UserLogin (..))
import Nagare.Resource.Types (Name, nameText)
import Nagare.Test.World.Adversary

data WorldUser = WorldUser
  { physical :: !Text
  , password :: !PasswordHash
  , login :: !Bool
  , elevated :: ![Text]
  , serverGrants :: ![Text]
  , settings :: ![CatalogSetting]
  , inheritedProfiles :: ![Text]
  , connectionLimit :: !Int
  , roleSettings :: ![Text]
  , tableGrants :: ![CatalogTableGrant]
  -- ^ ClickHouse: a reader's SELECT per declared object (EP-206)
  }
  deriving stock (Generic, Eq, Show)

data WorldDatabase = WorldDatabase
  { physical :: !Text
  , owner :: !Text
  , grants :: !(Set CatalogGrant)
  , publicSchemaOwner :: !Text
  , defaultRoles :: ![Text]
  , otherSchemas :: !(Map Text Text)
  -- ^ schemas an app's migration created, with their owners
  , relations :: ![CatalogRelation]
  -- ^ PostgreSQL: the tables and views an app's migration created, with
  -- their readers' grants (EP-206)
  , functions :: ![CatalogFunction]
  -- ^ PostgreSQL: SECURITY DEFINER functions and who may execute them
  }
  deriving stock (Generic, Eq, Show)

-- | One server's catalogs and the Secrets of its app databases.
data World = World
  { engine :: !Engine
  , users :: !(Map Text WorldUser)
  , databases :: !(Map Text WorldDatabase)
  , publicSystemAccess :: !Bool
  , secrets :: !(Map Text CredentialSecret)
  , issued :: !Int
  , sessions :: !(Map Text Int)
  -- ^ EP-205: each user's running queries (ClickHouse) or sessions (PostgreSQL)
  , activeRuns :: !Int
  -- ^ polls until the scheduled backup Job in flight ends
  , mutations :: ![WorldMutation]
  , server :: !(Map Text Text)
  -- ^ the server Pod's UID and start time and the engine's identity
  , memberships :: !(Set (Text, Text, Bool))
  -- ^ PostgreSQL: (role, member, admin option) (EP-208)
  , privilegeTree :: !PrivilegeTree
  -- ^ ClickHouse: the 26.8 tree M1 captured; database grants are held as
  -- leaves and reported as their minimal cover, as system.grants does
  , legacySourceGrants :: !Bool
  -- ^ ClickHouse without @enable_read_write_grants@: a source grant is
  -- stored as the legacy @FILE@ (BUG-7). Off for the server Nagare renders
  -- now.
  , legacyEntities :: !(Set Text)
  -- ^ ClickHouse: the users whose access entity was last written in the
  -- legacy form. Turning the setting on does not rewrite them; a restart
  -- reloads their source grants as READ and WRITE until their access is
  -- set again (EP-209 M1, Run C). Only a user-access block rewrites an
  -- entity here, which reports the legacy READ at least as often as the
  -- engine does.
  }
  deriving stock (Generic, Eq, Show)

-- | A ClickHouse mutation on one table: done after its remaining polls, or
-- stuck with a failure reason.
data WorldMutation = WorldMutation
  { database :: !Text
  , table :: !Text
  , mutationId :: !Text
  , remaining :: !Int
  , failure :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

newWorld :: Engine -> Map Text CredentialSecret -> IO (IORef World)
newWorld engine' secrets' = do
  tree <- if engine' == ClickHouse then clickHouseTree else pure Map.empty
  newIORef (World engine' Map.empty Map.empty (engine' == Postgres) secrets' 0 Map.empty 0 [] (Map.fromList [("podUID", "pod-1"), ("podStarted", "2026-10-19T00:00:00Z"), ("serverUUID", "uuid-1"), ("processStarted", "2026-10-19 00:00:00")]) Set.empty tree False Set.empty)

-- | The server process restarts on a new Pod with the same data volume.
-- ClickHouse reloads every user whose entity is in the legacy form and holds
-- READ or WRITE on a source with both, as EP-209 M1 proved on 26.8.
restartServer :: World -> World
restartServer world =
  world
    & #server
    %~ ( Map.insert "podUID" ("pod-" <> T.show restarts)
           . Map.insert "podStarted" ("2026-10-20T00:00:" <> stamp <> "Z")
           . Map.insert "processStarted" ("2026-10-20 00:00:" <> stamp)
       )
    & #users
    %~ Map.mapWithKey (\name u -> if world ^. #engine == ClickHouse && Set.member name (world ^. #legacyEntities) then reload u else u)
  where
    -- The pods are pod-1, pod-2, ... in start order.
    restarts = 1 + maybe 1 (either (const 1) fst . TR.decimal) (T.stripPrefix "pod-" =<< Map.lookup "podUID" (world ^. #server)) :: Int
    stamp = T.justifyRight 2 '0' (T.show (restarts `mod` 60))
    reload u
      | any (`elem` ["READ", "WRITE"]) (u ^. #serverGrants) = u & #serverGrants %~ (\held -> nub (held <> ["READ", "WRITE"]))
      | otherwise = u

-- | ClickHouse 26.8's privilege tree, as EP-208 M1 observed it.
clickHouseTree :: IO PrivilegeTree
clickHouseTree = do
  bytes <- BS.readFile "test/fixtures/app-database/observed/clickhouse-privileges-declared.jsonl"
  either (fail . T.unpack) (pure . (^. #privilegeTree)) (parseClickHouseCatalog [] [] bytes)

-- | What system.grants reports for a set of held leaves: from the top of the
-- tree down, a privilege whose every leaf is held, else its children.
compressGrants :: PrivilegeTree -> Set Text -> [Text]
compressGrants tree held
  | Map.null tree = Set.toList held
  | otherwise = Set.toList (Set.fromList (concatMap cover roots) <> Set.filter (`Map.notMember` tree) held)
  where
    roots = [privilege' | (privilege', (Nothing, _)) <- Map.toList tree]
    children = Map.fromListWith (<>) [(parent, [child]) | (child, (Just parent, _)) <- Map.toList tree]
    cover node
      | expandPrivileges tree [node] `Set.isSubsetOf` held = [node]
      | otherwise = concatMap cover (Map.findWithDefault [] node children)

-- | The server as a drain observes it.
drainObservation :: World -> [Text] -> [Text] -> DrainObservation
drainObservation world users' databases' =
  DrainObservation
    { sessions = sum [Map.findWithDefault 0 user (world ^. #sessions) | user <- users']
    , unfinished = [mutationName m | m <- pending]
    , failed = [mutationName m <> ": " <> reason | m <- pending, Just reason <- [m ^. #failure]]
    , identity = Map.withoutKeys (world ^. #server) (Set.fromList ["podUID", "podStarted"])
    }
  where
    pending = [m | m <- world ^. #mutations, m ^. #database `elem` databases', m ^. #remaining > 0 || isJust (m ^. #failure)]
    mutationName m = m ^. #database <> "." <> m ^. #table <> " " <> m ^. #mutationId

secretKey :: Name -> Name -> Text
secretKey namespace' secretName = nameText namespace' <> "/" <> nameText secretName

-- | What the catalogs say, as the observation queries would report it.
worldCatalog :: World -> Catalog
worldCatalog world =
  Catalog
    (Map.map user (world ^. #users))
    (Map.map database (world ^. #databases))
    (world ^. #publicSystemAccess)
    (Set.toList (world ^. #memberships))
    (world ^. #privilegeTree)
  where
    user u =
      CatalogUser
        (u ^. #physical)
        (if u ^. #login then LoginOn else LoginOff)
        (u ^. #serverGrants)
        (map ("attribute " <>) (u ^. #elevated))
        (u ^. #settings)
        (u ^. #inheritedProfiles)
        (if world ^. #engine == ClickHouse then Nothing else Just (u ^. #connectionLimit))
        (u ^. #roleSettings)
        (u ^. #tableGrants)
    database db =
      CatalogDatabase
        (db ^. #physical)
        (if world ^. #engine == ClickHouse then Nothing else Just (db ^. #owner))
        (if world ^. #engine == ClickHouse then reported (db ^. #grants) else Set.toList (db ^. #grants))
        (if world ^. #engine == ClickHouse then Map.empty else Map.insert "public" (db ^. #publicSchemaOwner) (db ^. #otherSchemas))
        (db ^. #defaultRoles)
        []
        (db ^. #relations)
        (db ^. #functions)
    reported grants' =
      [ CatalogGrant who target' privilege'
      | (who, target') <- Set.toList (Set.map (\g -> (g ^. #grantee, g ^. #target)) grants')
      , privilege' <- compressGrants (world ^. #privilegeTree) (Set.fromList [g ^. #privilege | g <- Set.toList grants', g ^. #grantee == who, g ^. #target == target'])
      ]

worldOps :: IORef World -> IORef Adversary -> AppDatabaseOps
worldOps ref adversary =
  AppDatabaseOps
    { observeCatalog = \_ _ _ -> do
        fault <- nextFaultAt adversary ObserveCall
        case fault of
          Just placement@(_, TransientReadFailure) -> do
            noteActed adversary placement
            pure (Left "injected: catalog observation timed out")
          _ -> Right . worldCatalog <$> readIORef ref
    , passwordMatches = \_ name password' -> do
        world <- readIORef ref
        pure . Right $ case Map.lookup name (world ^. #users) of
          Nothing -> False
          Just u -> matches (u ^. #password) password'
    , readCredential = \namespace' secretName ->
        Right . Map.lookup (secretKey namespace' secretName) . (^. #secrets) <$> readIORef ref
    , runCommand = \_ command -> mutate (interpret command)
    , rewriteCredential = \namespace' secretName password' ->
        mutate $ \world -> case Map.lookup (secretKey namespace' secretName) (world ^. #secrets) of
          Nothing -> Left "injected world: Secret not found"
          Just secret -> Right (world & #secrets %~ Map.insert (secretKey namespace' secretName) (secret & #password .~ password'))
    , freshSalt = do
        n <- atomicModifyIORef' ref (\world -> (world & #issued %~ (+ 1), world ^. #issued + 1))
        pure (BS.pack (map fromIntegral (take 16 (iterate (+ 1) n))))
    , freshPassword = do
        n <- atomicModifyIORef' ref (\world -> (world & #issued %~ (+ 1), world ^. #issued + 1))
        pure ("rotated-" <> T.pack (show n))
    , observeDrain = \_ users' databases' -> do
        fault <- nextFaultAt adversary ObserveCall
        case fault of
          Just placement@(_, TransientReadFailure) -> do
            noteActed adversary placement
            pure (Left "injected: drain observation timed out")
          _ -> Right . (\world -> drainObservation world users' databases') <$> readIORef ref
    , terminateSessions = \_ users' -> mutate (Right . (#sessions %~ \running -> foldr (`Map.insert` 0) running users'))
    , observeActiveRuns = \_ _ -> Right . (^. #activeRuns) <$> readIORef ref
    , observeServerPod = \_ -> (\world -> Right (Map.findWithDefault "" "podUID" (world ^. #server), Map.findWithDefault "" "podStarted" (world ^. #server))) <$> readIORef ref
    , -- Time passes: a running Job and the mutations move one poll on.
      pause = modifyIORef' ref (\world -> world & #activeRuns %~ (max 0 . subtract 1) & #mutations . traverse . #remaining %~ (max 0 . subtract 1))
    }
  where
    -- One effectful call: the adversary may refuse it, lose its answer, or
    -- kill the executor once it has landed.
    mutate step = do
      fault <- nextFaultAt adversary MutateCall
      world <- readIORef ref
      case fault of
        Just placement@(_, RefusedBeforeEffect) -> do
          noteActed adversary placement
          pure (Left "injected: refused before effect")
        _ -> case step world of
          Left reason -> pure (Left reason)
          Right changed -> do
            writeIORef ref changed
            case fault of
              Just placement@(_, LostAcknowledgement) -> do
                noteActed adversary placement
                pure (Left "injected: acknowledgement lost")
              Just placement@(_, Interrupt) -> do
                noteActed adversary placement
                throwIO Interrupted
              _ -> pure (Right ())
    matches hash password' = case hash of
      PostgresVerifier verifier -> scramVerifierMatches password' verifier
      ClickHouseSha256 digest saltText -> clickhouseHashMatches password' digest saltText

interpret :: CatalogCommand -> World -> Either Text World
interpret command world = case command of
  CreateUser name hash _
    | Map.member name (world ^. #users) -> Left ("role " <> name <> " already exists")
    | otherwise -> Right (world & #users %~ Map.insert name (WorldUser (fresh "user" name) hash True [] [] [] [] (-1) [] []))
  -- As M1 proved: the declared exceptions are granted and every other
  -- allow-listed one revoked (a grant outside the list stays), the one
  -- SETTINGS statement replaces the whole settings list, CONNECTION LIMIT
  -- replaces the limit, and SET or RESET touches only statement_timeout.
  SetUserAccess role name login' access -> fmap (#legacyEntities %~ (if world ^. #legacySourceGrants then Set.insert name else Set.delete name)) $ withUser name $ \u ->
    let on = login' == LoginOpen
     in if engine' == ClickHouse
          then
            let managed = concatMap (^. #privileges) (appDatabaseServerGrants ClickHouse role <> appDatabaseServerRevokedGrants ClickHouse role) <> map exceptionGrantToken [minBound .. maxBound]
                granted = if on then concatMap (^. #privileges) (appDatabaseServerGrants ClickHouse role) <> map exceptionGrantToken (access ^. #exceptions) else []
             in u
                  & #login
                  .~ on
                  & #serverGrants
                  .~ (filter (`notElem` managed) (u ^. #serverGrants) <> granted)
                  & #settings
                  .~ [CatalogSetting settingName (Just value) (Just "1") (Just value) Nothing | (settingName, value) <- clickHouseCeilings (access ^. #limits)]
                  & #inheritedProfiles
                  .~ []
          else
            u
              & #login
              .~ (login' == LoginOpen)
              & #connectionLimit
              .~ fromMaybe (-1) (access ^. #limits . #connectionLimit)
              & #roleSettings
              .~ ( filter (not . ("statement_timeout=" `T.isPrefixOf`)) (u ^. #roleSettings)
                     <> ["statement_timeout=" <> postgresTimeout seconds | Just seconds <- [access ^. #limits . #statementTimeoutSeconds]]
                 )
  SetPassword name hash -> withUser name (#password .~ hash)
  CreateDatabase name owner'
    | Map.member name (world ^. #databases) ->
        if engine' == ClickHouse then Right world else Left ("database " <> name <> " already exists")
    | engine' == ClickHouse -> Right (world & #databases %~ Map.insert name (WorldDatabase (fresh "database" name) owner' Set.empty "" [] Map.empty [] []))
    | otherwise ->
        Right
          ( world
              & #databases
              %~ Map.insert
                name
                ( WorldDatabase
                    (fresh "database" name)
                    owner'
                    ( Set.fromList
                        ( [CatalogGrant owner' "database" p | p <- ["CREATE", "TEMPORARY", "CONNECT"]]
                            <> [CatalogGrant "PUBLIC" "database" p | p <- ["TEMPORARY", "CONNECT"]]
                            <> [CatalogGrant "pg_database_owner" "schema:public" p | p <- ["USAGE", "CREATE"]]
                            <> [CatalogGrant "PUBLIC" "schema:public" "USAGE"]
                        )
                    )
                    "pg_database_owner"
                    []
                    Map.empty
                    []
                    []
                )
          )
  -- As M1 proved: a reader's grants are exactly its statements; on
  -- PostgreSQL each one names an existing database, schema and relation, or
  -- the block stops.
  SetReaderAccess access
    | engine' == ClickHouse -> withUser (access ^. #user) $ \u ->
        let selects = [CatalogTableGrant (o ^. #database) (o ^. #relation) "SELECT" | o <- access ^. #granted]
            dropped = [CatalogTableGrant (o ^. #database) (o ^. #relation) "SELECT" | o <- access ^. #revoked]
            kept = filter (`notElem` (selects <> dropped)) (u ^. #tableGrants)
         in u
              & #login
              .~ on
              & #tableGrants
              .~ (kept <> (if on then selects else []))
              & #settings
              .~ readerSettings (access ^. #limits)
              & #inheritedProfiles
              .~ []
    | otherwise -> do
        let user' = access ^. #user
            databases' = nub (access ^. #databases <> access ^. #revokedDatabases <> map (^. #database) (access ^. #granted <> access ^. #revoked))
        roled <-
          withUser user' $ \u ->
            u
              & #login
              .~ on
              & #connectionLimit
              .~ fromMaybe (-1) (access ^. #limits . #connectionLimit)
              & #roleSettings
              .~ ( filter (\e -> not (any (`T.isPrefixOf` e) ["statement_timeout=", "default_transaction_read_only="])) (u ^. #roleSettings)
                     <> readerRoleSettings (access ^. #limits)
                 )
        let stopped = if on then roled else roled & #sessions %~ Map.insert user' 0
        foldM
          ( \w db -> case Map.lookup db (w ^. #databases) of
              Nothing -> Left ("database " <> db <> " does not exist")
              Just found -> do
                let connect = CatalogGrant user' "database" "CONNECT"
                    schemaGrant sc = CatalogGrant user' ("schema:" <> sc) "USAGE"
                    exists sc = sc == "public" || Map.member sc (found ^. #otherSchemas)
                    granted' = [o | o <- access ^. #granted, o ^. #database == db]
                    revoked' = [o | o <- access ^. #revoked, o ^. #database == db]
                    declaredSchemas = [sc | (db', sc) <- access ^. #schemas, db' == db]
                    droppedSchemas = [sc | (db', sc) <- access ^. #revokedSchemas, db' == db]
                    relationOf o r = r ^. #schema == fromMaybe "public" (o ^. #schema) && r ^. #name == o ^. #relation
                    missing = [o ^. #relation | o <- granted' <> revoked', not (any (relationOf o) (found ^. #relations))]
                unless (all exists (declaredSchemas <> droppedSchemas)) (Left ("schema does not exist in " <> db))
                unless (null missing) (Left ("relation " <> T.intercalate ", " missing <> " does not exist"))
                let grants' =
                      (if on && db `elem` access ^. #databases then Set.insert connect else Set.delete connect)
                        . flip (foldr (\sc -> if on then Set.insert (schemaGrant sc) else Set.delete (schemaGrant sc))) declaredSchemas
                        . flip (foldr (Set.delete . schemaGrant)) droppedSchemas
                        $ found ^. #grants
                    relation' r
                      | any (`relationOf` r) granted' = r & #grants %~ (\gs -> filter (/= (user', "SELECT")) gs <> [(user', "SELECT") | on])
                      | any (`relationOf` r) revoked' = r & #grants %~ filter (/= (user', "SELECT"))
                      | otherwise = r
                Right (w & #databases %~ Map.insert db (found & #grants .~ grants' & #relations %~ map relation'))
          )
          stopped
          databases'
    where
      on = access ^. #login == LoginOpen
  SetDatabaseAccess access -> do
    let migration = access ^. #migration
        runtime = access ^. #runtime
        -- As M1 proved: a GRANT keeps an admin option already held; a REVOKE
        -- removes the membership whatever its options.
        held = Set.filter (\(role, member, _) -> role == runtime && member == migration) (world ^. #memberships)
        membership
          | engine' == ClickHouse = id
          | access ^. #revokeMembership = Set.filter (`Set.notMember` held)
          | access ^. #enabled && runtimeOwnsObjects (access ^. #privileges) && Set.null held = Set.insert (runtime, migration, False)
          | otherwise = id
    -- A CREATE on a schema that does not exist stops the block (M1).
    case Map.lookup (access ^. #database) (world ^. #databases) of
      Just db
        | engine' /= ClickHouse
        , missing : _ <- [schema | schema <- access ^. #createIn <> access ^. #revokedCreateIn, Map.notMember schema (db ^. #otherSchemas)] ->
            Left ("schema \"" <> missing <> "\" does not exist")
      _ -> pure ()
    -- PostgreSQL access-on also revokes PUBLIC from the system databases.
    (if access ^. #enabled then #publicSystemAccess .~ False else id) . (#memberships %~ membership) <$> withDatabase (access ^. #database) (setAccess access)
  where
    engine' = world ^. #engine
    fresh kind' name = kind' <> ":" <> name <> ":" <> T.pack (show (Map.size (world ^. #users) + Map.size (world ^. #databases)))
    withUser name f = case Map.lookup name (world ^. #users) of
      Nothing -> Left ("role " <> name <> " does not exist")
      Just u -> Right (world & #users %~ Map.insert name (f u))
    withDatabase name f = case Map.lookup name (world ^. #databases) of
      Nothing -> Left ("database " <> name <> " does not exist")
      Just db -> Right (world & #databases %~ Map.insert name (f db))
    tree = world ^. #privilegeTree
    -- ClickHouse holds leaves: a REVOKE drops every leaf of its token, a
    -- GRANT adds every leaf of its list (M1).
    setAccess access db
      | engine' == ClickHouse =
          let users' = [(MigrationRole, access ^. #migration), (RuntimeRole, access ^. #runtime)]
              others = Set.filter (\g -> g ^. #grantee `notElem` map snd users') (db ^. #grants)
              heldBy who = Set.fromList [g ^. #privilege | g <- Set.toList (db ^. #grants), g ^. #grantee == who, g ^. #target == "database"]
              after (role, who)
                | not (access ^. #enabled) || who `elem` access ^. #withheld = Set.empty
                | otherwise =
                    (heldBy who `Set.difference` expandPrivileges tree [token | (who', token) <- access ^. #revoked, who' == who])
                      <> expandPrivileges tree (clickHouseDatabaseGrants role (access ^. #privileges))
           in db & #grants .~ Set.union others (Set.fromList [CatalogGrant who "database" leaf | user@(_, who) <- users', leaf <- Set.toList (after user)])
      | access ^. #enabled =
          let runtime = access ^. #runtime
              migration = access ^. #migration
              kept = Set.filter (\g -> g ^. #grantee `notElem` ["PUBLIC", "pg_database_owner"] || (g ^. #grantee == "PUBLIC" && g ^. #target == "default-functions")) (db ^. #grants)
              runtimeGrants = Set.fromList [CatalogGrant runtime (target g) p | g <- appDatabaseDatabaseGrants Postgres RuntimeRole, p <- g ^. #privileges]
              target g = case g ^. #objectClass of
                "schema" -> "schema:public"
                other -> other
              ownPrivileges =
                Set.fromList
                  ( [CatalogGrant runtime "database" "CREATE" | access ^. #privileges . #runtime . #createSchemas]
                      <> [CatalogGrant runtime ("schema:" <> schema) "CREATE" | schema <- access ^. #createIn]
                  )
              revokedOwn = Set.fromList ([CatalogGrant runtime "database" "CREATE" | access ^. #revokeDatabaseCreate] <> [CatalogGrant runtime ("schema:" <> schema) "CREATE" | schema <- access ^. #revokedCreateIn])
           in db
                & #grants
                .~ (Set.unions [kept, runtimeGrants, ownPrivileges, Set.fromList [CatalogGrant migration "schema:public" p | p <- ["USAGE", "CREATE"]], Set.singleton (CatalogGrant "PUBLIC" "default-functions" "EXECUTE")] `Set.difference` revokedOwn)
                & #publicSchemaOwner
                .~ migration
                & #defaultRoles
                .~ [migration]
      -- Retirement withholds CONNECT and TEMPORARY, and CREATE when held.
      | otherwise =
          db
            & #grants
            %~ Set.filter
              ( \g ->
                  not
                    ( g ^. #grantee == access ^. #runtime
                        && ( (g ^. #target == "database" && (g ^. #privilege /= "CREATE" || access ^. #revokeDatabaseCreate))
                               || (g ^. #privilege == "CREATE" && g ^. #target `elem` ["schema:" <> schema | schema <- access ^. #revokedCreateIn])
                           )
                    )
              )
