-- | EP-208: declarable privileges inside an app database's own databases
-- and owner bindings: the declaration loads, compiles onto the logical
-- databases and the migration user, binds the migration credential only for
-- a declared owner, and converges in the interpreter world.
module AppDatabasePrivilegeSpec (appDatabasePrivilegeTests) where

import AppDatabaseSpec (acceptedNative, alpha, assertLeftContaining, chServer, compileWorker, kansokuCh, kansokuChAccess, kansokuPg, kansokuPgAccess, kansokuPgReader, known, pgServer, scopeAndNative, secretKeyRefs, snapshotWith, testCluster)
import AppDatabaseWorldSpec (Members, adapterFor, catalogAccess, chTokens, converge, convergeAgainst, declaredAccess, membersFor, observeAll, observeAllAgainst, ownPrivileges, pgmqPrivileges, planned, quiesceCycleWith, replan, replanAgainst, seedPgmq, setup, setupWith, user', withPrivileges)
import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Database.AppDatabase.Catalog (CatalogGrant (..), CatalogRelation (..), privilegeUnknownCode)
import Nagare.Dsl.AppDatabase
import Nagare.Dsl.Config (encodeAppDatabases)
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Load (decodeAppDatabases)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.AppDatabase
import Nagare.Inventory.Application (acceptedAppDatabaseBindings)
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Test.World.Adversary
import Nagare.Test.World.Adversary qualified as Adversary
import Nagare.Test.World.AppDatabase
import Test.Tasty
import Test.Tasty.HUnit

appDatabasePrivilegeTests :: TestTree
appDatabasePrivilegeTests =
  testGroup
    "AppDatabase own privileges"
    [ testGroup
        "declaration"
        [ testCase "own-database privileges and owners round-trip, and none emits no key (EP-208 M2)" $ do
            let schema' = known (mkSchemaName "pgmq")
                pgDeclared = kansokuPg & #access . #privileges . #runtime . #createIn .~ [schema'] & #access . #privileges . #runtime . #createSchemas .~ True & #access . #owners .~ [known (Dsl.mkServiceName "kansoku-migrate")]
                chDeclared = kansokuCh & #access . #privileges . #runtime . #clickhouse .~ map (known . mkClickHousePrivilege) ["CREATE TABLE", "DROP TABLE"] & #access . #privileges . #migration . #clickhouse .~ [known (mkClickHousePrivilege "UNDROP TABLE")]
                emitted = TE.decodeUtf8 . LBS.toStrict . encodeAppDatabases
            decodeAppDatabases (LBS.toStrict (encodeAppDatabases [pgDeclared, chDeclared])) @?= Right [pgDeclared, chDeclared]
            assertBool "no privileges emit no key" (not (any (`T.isInfixOf` emitted [kansokuPgAccess, kansokuChAccess, kansokuPgReader]) ["privileges", "owners"]))
            assertBool (T.unpack (emitted [pgDeclared])) ("\"privileges\":{\"runtime\":{\"createIn\":[\"pgmq\"],\"createSchemas\":true}}" `T.isInfixOf` emitted [pgDeclared])
            assertBool "only declared halves are emitted" (not ("migration" `T.isInfixOf` emitted [pgDeclared & #access . #owners .~ []]))
            -- The spec layer: the logical databases carry the privileges, the migration user the owners.
            let (pgScope, _) = scopeAndNative pgServer (alpha Postgres & #access . #privileges .~ (pgDeclared ^. #access . #privileges) & #access . #owners .~ (pgDeclared ^. #access . #owners))
                specs' = [m ^. #spec | bundle <- scopeBundles pgScope, Managed m <- declarations bundle]
            [p | LogicalDatabase _ _ _ _ _ _ p <- specs'] @?= [pgDeclared ^. #access . #privileges]
            [(role, e ^. #owners) | DatabaseUserSpec _ role _ _ e <- specs', not (null (e ^. #owners))] @?= [("migration", [known (Dsl.mkServiceName "kansoku-migrate")])]
            -- An undeclared app database keeps its accepted spec bytes and digests.
            let (plainScope, _) = scopeAndNative pgServer (alpha Postgres)
            [p | bundle <- scopeBundles plainScope, Managed m <- declarations bundle, LogicalDatabase _ _ _ _ _ _ p <- [m ^. #spec]] @?= [noDatabasePrivileges]
        , testCase "privileges on the wrong engine or user, a malformed or fixed token, or a repeat refuse before planning (IR-35 AC-1, EP-208 M2)" $ do
            let entry engine' accessJson = "{\"name\":\"x\",\"server\":\"s\",\"engine\":\"" <> engine' <> "\",\"namespace\":\"personal\",\"logicalDatabases\":[\"x\"],\"access\":" <> accessJson <> "}"
                pgmq = known (mkSchemaName "pgmq")
                tokens = map (known . mkClickHousePrivilege)
            assertLeftContaining "createInto" (decodeAppDatabases (rawJson (entry "postgres" "{\"privileges\":{\"runtime\":{\"createInto\":[\"pgmq\"]}}}")))
            assertLeftContaining "schema name" (decodeAppDatabases (rawJson (entry "postgres" "{\"privileges\":{\"runtime\":{\"createIn\":[\"PGMQ\"]}}}")))
            assertLeftContaining "single spaces" (decodeAppDatabases (rawJson (entry "clickhouse" "{\"privileges\":{\"runtime\":{\"clickhouse\":[\"CREATE  TABLE\"]}}}")))
            assertLeftContaining "not ALL" (decodeAppDatabases (rawJson (entry "clickhouse" "{\"privileges\":{\"runtime\":{\"clickhouse\":[\"ALL\"]}}}")))
            assertLeftContaining "single spaces" (decodeAppDatabases (rawJson (entry "clickhouse" "{\"privileges\":{\"runtime\":{\"clickhouse\":[\"SELECT; DROP\"]}}}")))
            assertLeftContaining "Bad_Name" (decodeAppDatabases (rawJson (entry "postgres" "{\"owners\":[\"Bad_Name\"]}")))
            refused (kansokuCh & #access . #privileges . #runtime . #createIn .~ [pgmq]) "createIn and createSchemas are PostgreSQL privileges"
            refused (kansokuCh & #access . #privileges . #runtime . #createSchemas .~ True) "createIn and createSchemas are PostgreSQL privileges"
            refused (kansokuPg & #access . #privileges . #migration . #createIn .~ [pgmq]) "the migration user owns the database"
            refused (kansokuPg & #access . #privileges . #runtime . #clickhouse .~ tokens ["CREATE TABLE"]) "clickhouse privileges are ClickHouse privileges"
            refused (kansokuPg & #access . #privileges . #runtime . #createIn .~ [pgmq, pgmq]) "repeat a schema"
            refused (kansokuCh & #access . #privileges . #runtime . #clickhouse .~ tokens ["DROP TABLE", "DROP TABLE"]) "repeat a ClickHouse privilege"
            refused (kansokuCh & #access . #privileges . #runtime . #clickhouse .~ tokens ["ALTER UPDATE"]) "already holds ALTER UPDATE"
            refused (kansokuCh & #access . #privileges . #migration . #clickhouse .~ tokens ["CREATE TABLE"]) "already holds CREATE TABLE"
            refused (kansokuPg & #access . #owners .~ replicate 2 (known (Dsl.mkServiceName "gamma"))) "repeats an owner"
        , testCase "a declared owner binds the migration Secret and every other workload the runtime Secret (IR-35 AC-5)" $
            forM_ [(pgServer, alpha Postgres, "pg"), (chServer, alpha ClickHouse, "ch")] $ \(server', base, short) -> do
              let db = base & #access . #owners .~ [known (Dsl.mkServiceName "gamma")]
                  (scope, native') = scopeAndNative server' db
                  accepted = snapshotWith [server'] [scope]
                  native = Map.union (acceptedNative [server']) native'
                  render workload = do
                    bindings <- either (assertFailure . T.unpack) pure (acceptedAppDatabaseBindings accepted native testCluster "personal" (known (Dsl.mkServiceName workload)) [db ^. #name])
                    (workerScope, workerNative) <- either (assertFailure . show) pure (compileWorker workload (Just [db ^. #name]) bindings)
                    let rendered = Map.elems workerNative
                    pure (nub (sort (concatMap (secretKeyRefs . snd) rendered)), sort (concatMap (secretEnvNames . snd) rendered), workerScope)
              (gammaRefs, gammaEnv, gammaScope) <- render "gamma"
              (deltaRefs, deltaEnv, _) <- render "delta"
              gammaRefs @?= ["alpha-" <> short <> "-migration"]
              deltaRefs @?= ["alpha-" <> short <> "-runtime"]
              assertBool "the same variables are injected" (not (null gammaEnv) && gammaEnv == deltaEnv)
              -- The owner is ordered after the same members as a runtime binder.
              let users = [member ^. #identity | bundle <- scopeBundles scope, Managed member <- declarations bundle, member ^. #executor == AppDatabaseExecutor]
                  dependencies = concat [member ^. #dependencies | bundle <- scopeBundles gammaScope, Managed member <- declarations bundle]
              assertBool "the owner is ordered after the app database" (all (\user -> OrderedAfter user `elem` dependencies) users)
              -- Without the declaration no workload can name the migration Secret.
              let (plainScope, plainNative) = scopeAndNative server' base
              epsilon <- either (assertFailure . T.unpack) pure (acceptedAppDatabaseBindings (snapshotWith [server'] [plainScope]) (Map.union (acceptedNative [server']) plainNative) testCluster "personal" (known (Dsl.mkServiceName "gamma")) [db ^. #name])
              (_, epsilonNative) <- either (assertFailure . show) pure (compileWorker "gamma" (Just [db ^. #name]) epsilon)
              nub (sort (concatMap (secretKeyRefs . snd) (Map.elems epsilonNative))) @?= ["alpha-" <> short <> "-runtime"]
              -- The owners ride on the migration user's spec, and nowhere else.
              [owners' | bundle <- scopeBundles scope, Managed member <- declarations bundle, DatabaseUserSpec _ role _ _ extension <- [member ^. #spec], let owners' = (role, extension ^. #owners), not (null (snd owners'))]
                @?= [("migration", [known (Dsl.mkServiceName "gamma")])]
        ]
    , testGroup "Postgres world" postgresPrivilegeTests
    , testGroup "ClickHouse world" clickHousePrivilegeTests
    ]
  where
    refused db reason = assertLeftContaining reason (decodeAppDatabases (LBS.toStrict (encodeAppDatabases [db])))
    rawJson entry = TE.encodeUtf8 ("{\"kind\":\"AppDatabases\",\"appDatabases\":[" <> entry <> "]}")

databaseMember :: Members -> Text -> Text -> ResourceId
databaseMember members app db =
  head
    [ resource
    | (resource, member) <- Map.toList members
    , ("appdb-" <> app) `T.isPrefixOf` nameText (scopeName (member ^. #declaration . #owner))
    , DatabaseMember name _ _ _ _ <- [member ^. #kind]
    , name == db
    ]

-- | The runtime creates a table in a schema of alpha's database, as PGMQ's
-- create does for its queue (M1).
runtimeCreates :: Text -> Text -> World -> World
runtimeCreates schema' table' = #databases %~ Map.adjust (#relations %~ (<> [CatalogRelation schema' table' "r" (Just (user' Postgres "alpha" "runtime")) [] []])) "alpha"

runtimeGrantsOn :: Engine -> Text -> World -> [CatalogGrant]
runtimeGrantsOn engine' db world = sort [g | g <- Set.toList (world ^?! #databases . ix db . #grants), g ^. #grantee == user' engine' "alpha" "runtime"]

postgresPrivilegeTests :: [TestTree]
postgresPrivilegeTests =
  [ testCase "a PGMQ startup queue: pending until the migration, granted after, owned by the runtime, reachable by the migration user (IR-35 AC-1, AC-2)" $ do
      (world, ops, members) <- setup Postgres (ownPrivileges Postgres) []
      let alphaDb = databaseMember members "alpha" "alpha"
          runtime = user' Postgres "alpha" "runtime"
          migration = user' Postgres "alpha" "migration"
      converge ops members >>= expectRight
      -- The schema is the app's migration's: pending, nothing planned.
      notes <- either (assertFailure . T.unpack) (pure . observationNotes) =<< adapterObserve (adapterFor ops members) [alphaDb]
      notes @?= Map.singleton alphaDb "pending: schema pgmq"
      replan ops members >>= (@?= [])
      (^. #memberships) <$> readIORef world >>= (@?= Set.singleton (runtime, migration, False))
      -- The migration installs PGMQ; the next plan grants CREATE on it.
      modifyIORef' world seedPgmq
      replan ops members >>= (@?= [alphaDb])
      converge ops members >>= expectRight
      readIORef world >>= \w -> assertBool "CREATE on schema pgmq" (CatalogGrant runtime "schema:pgmq" "CREATE" `elem` runtimeGrantsOn Postgres "alpha" w)
      -- The runtime creates its queue; the backup and the migration user's
      -- ALTER TABLE reach it through the membership (M1).
      modifyIORef' world (runtimeCreates "pgmq" "q_events" . runtimeCreates "pgmq" "a_events")
      replan ops members >>= (@?= [])
      converged <- readIORef world
      -- A hand REVOKE of the membership is restored; a hand ADMIN OPTION is drift.
      writeIORef world (converged & #memberships .~ Set.empty)
      replan ops members >>= (@?= [alphaDb])
      converge ops members >>= expectRight
      replan ops members >>= (@?= [])
      writeIORef world (converged & #memberships .~ Set.singleton (runtime, migration, True))
      observeAll ops members >>= \refusals -> assertBool (show refusals) (any (\r -> grantDriftCode `T.isPrefixOf` r && "admin option" `T.isInfixOf` r) refusals)
      -- A rebuilt server: re-apply (pgmq pending), then the dump brings the
      -- schema with its CREATE grant and the runtime-owned queue.
      writeIORef world (converged & #users .~ Map.empty & #databases .~ Map.empty & #memberships .~ Set.empty & #publicSystemAccess .~ True)
      converge ops members >>= expectRight
      modifyIORef' world (runtimeCreates "pgmq" "q_events" . (#databases %~ Map.adjust (#grants %~ Set.insert (CatalogGrant runtime "schema:pgmq" "CREATE")) "alpha") . seedPgmq)
      replan ops members >>= (@?= [])
  , testCase "the same grant by hand, or a runtime-owned table outside a declared schema, is drift (IR-35 AC-1, AC-3)" $ do
      (world, ops, members) <- setup Postgres (withPrivileges (pgmqPrivileges False)) []
      converge ops members >>= expectRight
      modifyIORef' world seedPgmq
      converge ops members >>= expectRight
      converged <- readIORef world
      plain <- membersFor Postgres (declaredAccess Postgres)
      refusals <- observeAllAgainst plain ops plain
      assertBool (show refusals) (any (\r -> grantDriftCode `T.isPrefixOf` r && "runtime holds CREATE on schema:pgmq" `T.isInfixOf` r) refusals)
      -- A temporary hand grant let the runtime create in public; it is gone, the table is not.
      writeIORef world (runtimeCreates "public" "leak" converged)
      leaked <- observeAll ops members
      assertBool (show leaked) (any (\r -> grantDriftCode `T.isPrefixOf` r && "runtime owns public.leak" `T.isInfixOf` r) leaked)
      -- Under createSchemas a schema the runtime creates, and its tables, are expected.
      (world', ops', members') <- setup Postgres (ownPrivileges Postgres) []
      converge ops' members' >>= expectRight
      modifyIORef' world' (runtimeCreates "scratch" "t" . (#databases %~ Map.adjust ((#otherSchemas %~ Map.insert "scratch" (user' Postgres "alpha" "runtime")) . (#grants %~ Set.union (Set.fromList [CatalogGrant (user' Postgres "alpha" "runtime") "schema:scratch" p | p <- ["USAGE", "CREATE"]]))) "alpha"))
      replan ops' members' >>= (@?= [])
      -- Without it, the same schema is drift.
      narrowed <- membersFor Postgres (withPrivileges (pgmqPrivileges False))
      narrowedRefusals <- observeAllAgainst narrowed ops' narrowed
      assertBool (show narrowedRefusals) (any (\r -> grantDriftCode `T.isPrefixOf` r && "scratch" `T.isInfixOf` r) narrowedRefusals)
  , testCase "the reviewed operation names createIn, createSchemas and the membership (IR-35 AC-1)" $ do
      members <- membersFor Postgres (ownPrivileges Postgres)
      (_, ops, _) <- setup Postgres (ownPrivileges Postgres) []
      prepared <- adapterPrepare (adapterFor ops members) (planned UpdateResource (databaseMember members "alpha" "alpha"))
      summary <- either (assertFailure . show) (pure . preparedPublicSummary) prepared
      forM_ ["createIn pgmq", "createSchemas", "migration member of runtime"] $ \needle -> assertBool (T.unpack summary) (needle `T.isInfixOf` summary)
  , testCase "removing the privileges refuses while the runtime owns objects, then revokes them and the membership (EP-208)" $ do
      (world, ops, accepted) <- setup Postgres (ownPrivileges Postgres) []
      converge ops accepted >>= expectRight
      modifyIORef' world seedPgmq
      converge ops accepted >>= expectRight
      modifyIORef' world (runtimeCreates "pgmq" "q_events")
      desired <- membersFor Postgres (withPrivileges noDatabasePrivileges)
      refusals <- observeAllAgainst accepted ops desired
      assertBool (show refusals) (any (\r -> grantDriftCode `T.isPrefixOf` r && "runtime owns pgmq.q_events" `T.isInfixOf` r) refusals)
      -- The app's migration reassigns its queue to the migration user.
      modifyIORef' world (#databases %~ Map.adjust (#relations . traverse . #owner .~ Just (user' Postgres "alpha" "migration")) "alpha")
      replanAgainst accepted ops desired >>= (@?= [databaseMember desired "alpha" "alpha"])
      convergeAgainst accepted ops desired >>= expectRight
      replan ops desired >>= (@?= [])
      after <- readIORef world
      after ^. #memberships @?= Set.empty
      [g | g <- runtimeGrantsOn Postgres "alpha" after, g ^. #privilege == "CREATE"] @?= []
  , testCase "every fault while granting the privileges ends converged (IR-35 AC-6)" $ do
      let declare = ownPrivileges Postgres
          -- A first apply and PGMQ's install, then the plan that grants CREATE on it.
          prepare = do
            (world', ops', members', adversary') <- setupWith Postgres declare []
            converge ops' members' >>= expectRight
            modifyIORef' world' seedPgmq
            used <- Map.findWithDefault 0 MutateCall . counts <$> readIORef adversary'
            pure (ops', members', adversary', used)
      (ops, members, adversary, used) <- prepare
      converge ops members >>= expectRight
      calls <- subtract used . Map.findWithDefault 0 MutateCall . counts <$> readIORef adversary
      assertBool "the grant makes mutation calls" (calls > 0)
      forM_ [(n, fault) | n <- [1 .. calls], fault <- [RefusedBeforeEffect, LostAcknowledgement, Interrupt]] $ \(n, fault) -> do
        (ops', members', adversary', used') <- prepare
        modifyIORef' adversary' (\a -> a {Adversary.schedule = [(Boundary MutateCall (used' + n), fault)]})
        converge ops' members' >>= either (\reason -> assertFailure (show (n, fault) <> ": " <> T.unpack reason)) pure
        replan ops' members' >>= (@?= [])
        unacted <$> readIORef adversary' >>= assertEqual ("fault placement fired " <> show (n, fault)) []
  , testCase "quiesce and resume leave the privileges and the membership as declared (IR-35 AC-6)" $ do
      (world, ops, open) <- setup Postgres (ownPrivileges Postgres) []
      converge ops open >>= expectRight
      modifyIORef' world seedPgmq
      converge ops open >>= expectRight
      before' <- readIORef world
      (during, after') <- quiesceCycleWith (ownPrivileges Postgres) Postgres world ops open >>= either (assertFailure . T.unpack) pure
      during ^. #memberships @?= before' ^. #memberships
      catalogAccess after' @?= catalogAccess before'
      after' ^. #memberships @?= before' ^. #memberships
  ]
  where
    expectRight = either (assertFailure . T.unpack) pure

clickHousePrivilegeTests :: [TestTree]
clickHousePrivilegeTests =
  [ testCase "declared CREATE TABLE and DROP TABLE are granted on each of alpha's databases and nowhere else (IR-35 AC-4)" $ do
      (world, ops, members) <- setup ClickHouse (withPrivileges (chTokens ["CREATE TABLE", "DROP TABLE"])) []
      converge ops members >>= expectRight
      replan ops members >>= (@?= [])
      after <- readIORef world
      let reported db = sort [g ^. #privilege | g <- (worldCatalog after) ^?! #databases . ix db . #grants, g ^. #grantee == user' ClickHouse "alpha" "runtime"]
      forM_ ["alpha", "alpha_ledger"] $ \db -> reported db @?= sort ["SHOW TABLES", "SHOW COLUMNS", "SELECT", "INSERT", "ALTER UPDATE", "ALTER DELETE", "dictGet", "CREATE TABLE", "DROP TABLE"]
      [g | (name, wdb) <- Map.toList (after ^. #databases), "beta" `T.isPrefixOf` name, g <- Set.toList (wdb ^. #grants), g ^. #privilege `elem` ["CREATE TABLE", "DROP TABLE"], g ^. #grantee == user' ClickHouse "beta" "runtime"] @?= []
  , testCase "a declared group over the fixed set converges, and its removal revokes it and restores the fixed set (IR-35 AC-4)" $ do
      (world, ops, accepted) <- setup ClickHouse (withPrivileges (chTokens ["ALTER TABLE", "CREATE TABLE"])) []
      converge ops accepted >>= expectRight
      replan ops accepted >>= (@?= [])
      grouped <- readIORef world
      let reported w = sort [g ^. #privilege | g <- (worldCatalog w) ^?! #databases . ix "alpha" . #grants, g ^. #grantee == user' ClickHouse "alpha" "runtime"]
      assertBool (show (reported grouped)) ("ALTER TABLE" `elem` reported grouped && "ALTER UPDATE" `notElem` reported grouped)
      desired <- membersFor ClickHouse (withPrivileges (chTokens ["CREATE TABLE"]))
      replanAgainst accepted ops desired >>= (@?= sort [databaseMember desired "alpha" "alpha", databaseMember desired "alpha" "alpha_ledger"])
      convergeAgainst accepted ops desired >>= expectRight
      replan ops desired >>= (@?= [])
      readIORef world >>= \w -> reported w @?= sort ["SHOW TABLES", "SHOW COLUMNS", "SELECT", "INSERT", "ALTER UPDATE", "ALTER DELETE", "dictGet", "CREATE TABLE"]
  , testCase "a privilege the server cannot grant exactly on a database refuses the plan; a hand grant is drift (IR-35 AC-4)" $ do
      (world, ops, members) <- setup ClickHouse id []
      converge ops members >>= expectRight
      unknown <- membersFor ClickHouse (withPrivileges (chTokens ["ACCESS MANAGEMENT"]))
      refusals <- observeAllAgainst unknown ops unknown
      assertBool (show refusals) (any (\r -> privilegeUnknownCode `T.isPrefixOf` r && "ACCESS MANAGEMENT" `T.isInfixOf` r) refusals)
      modifyIORef' world (#databases %~ Map.adjust (#grants %~ Set.insert (CatalogGrant (user' ClickHouse "alpha" "runtime") "database" "TRUNCATE")) "alpha")
      drifted <- observeAll ops members
      assertBool (show drifted) (any (\r -> grantDriftCode `T.isPrefixOf` r && "TRUNCATE" `T.isInfixOf` r) drifted)
  , testCase "quiesce withholds the declared privileges with the fixed set and resume grants both back (IR-35 AC-6)" $ do
      (world, ops, open) <- setup ClickHouse (ownPrivileges ClickHouse) []
      converge ops open >>= expectRight
      before' <- readIORef world
      (during, after') <- quiesceCycleWith (ownPrivileges ClickHouse) ClickHouse world ops open >>= either (assertFailure . T.unpack) pure
      runtimeGrantsOn ClickHouse "alpha" during @?= []
      catalogAccess after' @?= catalogAccess before'
  ]
  where
    expectRight = either (assertFailure . T.unpack) pure

-- | The names of the variables a render takes from Secrets.
secretEnvNames :: ByteString -> [Text]
secretEnvNames bytes = either (const []) collect (eitherDecodeStrict bytes)
  where
    collect = \case
      Object fields ->
        [name | Just (Object from) <- [KM.lookup "valueFrom" fields], KM.member "secretKeyRef" from, Just (String name) <- [KM.lookup "name" fields]]
          <> concatMap collect (KM.elems fields)
      Array items -> concatMap collect (V.toList items)
      _ -> []
