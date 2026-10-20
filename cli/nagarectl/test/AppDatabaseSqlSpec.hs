-- | EP-202 M3: every app-database command renders exactly the statements
-- proven against the real engines in @test/fixtures/app-database/@.
module AppDatabaseSqlSpec (appDatabaseSqlTests) where

import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Database.AppDatabase.Catalog
import Nagare.Database.AppDatabase.Sql
import Nagare.Dsl.AppDatabase
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory (UserLogin (..))
import Test.Tasty
import Test.Tasty.HUnit

appDatabaseSqlTests :: TestTree
appDatabaseSqlTests =
  testGroup
    "AppDatabase SQL"
    [ testCase "PostgreSQL commands match the proven fixture" $ do
        blocks <- fixture "postgres"
        let pg = hashPassword Postgres
            access on = DatabaseAccess Postgres "smoke_pg" "alpha" "alpha_migration" "alpha_runtime" on [] [] []
        mapM_
          (uncurry (matches blocks))
          [ ("create-user alpha_migration", renderCreateUser Postgres "alpha_migration" (pg salt0 "pw-alpha_migration") "alpha")
          , ("create-user alpha_runtime", renderCreateUser Postgres "alpha_runtime" (pg salt0 "pw-alpha_runtime") "alpha")
          , ("create-database alpha", renderCreateDatabase Postgres "alpha" "alpha_migration")
          , ("database-access alpha on", renderDatabaseAccess (access True))
          , ("database-access alpha off", renderDatabaseAccess (access False))
          , ("user-access alpha_runtime on", renderUserAccess Postgres RuntimeRole "alpha_runtime" LoginOpen noUserAccess)
          , ("user-access alpha_runtime off", renderUserAccess Postgres RuntimeRole "alpha_runtime" LoginClosed noUserAccess)
          , ("user-access alpha_migration on", renderUserAccess Postgres MigrationRole "alpha_migration" LoginOpen noUserAccess)
          , ("user-access alpha_migration off", renderUserAccess Postgres MigrationRole "alpha_migration" LoginClosed noUserAccess)
          , ("user-access alpha_runtime on with declared access", renderUserAccess Postgres RuntimeRole "alpha_runtime" LoginOpen pgRuntimeAccess)
          , ("user-access alpha_runtime off with declared access", renderUserAccess Postgres RuntimeRole "alpha_runtime" LoginClosed pgRuntimeAccess)
          , ("user-access alpha_runtime quiesced", renderUserAccess Postgres RuntimeRole "alpha_runtime" LoginQuiesced noUserAccess)
          , ("drain alpha_runtime", renderTerminateSessions Postgres ["alpha_runtime"] <> renderObserveDrain Postgres ["alpha_runtime"] ["alpha"])
          , ("set-password alpha_runtime", renderSetPassword "alpha_runtime" (pg salt1 "pw2-alpha_runtime"))
          , ("observe-server", renderObserveServer ["alpha_migration", "alpha_runtime"] ["alpha"] "smoke_pg")
          , ("observe-database alpha", renderObserveDatabase)
          , ("observe-password alpha_runtime", renderObservePassword "alpha_runtime")
          , ("restore-scratch", renderScratchRestore Postgres [("alpha", "alpha_restore_r1")] "" "alpha_migration" "alpha_runtime")
          , ("reader-access alpha_reader_dash on", renderReaderAccess Postgres (ReaderAccess "alpha_reader_dash" LoginOpen (defaultReaderLimits Postgres) [pgView "v1", pgView "v2"] [pgView "vi"] ["alpha"] [] [("alpha", "public")] []))
          , ("reader-access alpha_reader_dash off", renderReaderAccess Postgres (ReaderAccess "alpha_reader_dash" LoginClosed (defaultReaderLimits Postgres) [pgView "v1", pgView "v2"] [] [] ["alpha"] [] [("alpha", "public")]))
          , ("observe-relations alpha", renderObserveRelations ["alpha_reader_dash"])
          ]
    , testCase "ClickHouse commands match the proven fixture" $ do
        blocks <- fixture "clickhouse"
        let ch = hashPassword ClickHouse
            access db on = DatabaseAccess ClickHouse "" db "alpha_migration" "alpha_runtime" on [] [] []
        mapM_
          (uncurry (matches blocks))
          [ ("create-user alpha_migration", renderCreateUser ClickHouse "alpha_migration" (ch salt0 "pw-alpha_migration") "alpha")
          , ("create-user alpha_runtime", renderCreateUser ClickHouse "alpha_runtime" (ch salt0 "pw-alpha_runtime") "alpha")
          , ("user-access alpha_migration on", renderUserAccess ClickHouse MigrationRole "alpha_migration" LoginOpen noUserAccess)
          , ("user-access alpha_migration off", renderUserAccess ClickHouse MigrationRole "alpha_migration" LoginClosed noUserAccess)
          , ("user-access alpha_runtime on", renderUserAccess ClickHouse RuntimeRole "alpha_runtime" LoginOpen noUserAccess)
          , ("user-access alpha_runtime off", renderUserAccess ClickHouse RuntimeRole "alpha_runtime" LoginClosed noUserAccess)
          , ("user-access alpha_runtime on with declared access", renderUserAccess ClickHouse RuntimeRole "alpha_runtime" LoginOpen chRuntimeAccess)
          , ("user-access alpha_runtime off with declared access", renderUserAccess ClickHouse RuntimeRole "alpha_runtime" LoginClosed chRuntimeAccess)
          , ("user-access alpha_migration on with declared access", renderUserAccess ClickHouse MigrationRole "alpha_migration" LoginOpen chMigrationAccess)
          , ("create-database alpha", renderCreateDatabase ClickHouse "alpha" "alpha_migration")
          , ("create-database alpha_ledger", renderCreateDatabase ClickHouse "alpha_ledger" "alpha_migration")
          , ("database-access alpha on", renderDatabaseAccess (access "alpha" True))
          , ("database-access alpha off", renderDatabaseAccess (access "alpha" False))
          , ("database-access alpha_ledger on", renderDatabaseAccess (access "alpha_ledger" True))
          , ("database-access alpha_ledger off", renderDatabaseAccess (access "alpha_ledger" False))
          , ("database-access alpha withheld alpha_runtime", renderDatabaseAccess (access "alpha" True & #withheld .~ ["alpha_runtime"]))
          , ("user-access alpha_runtime off", renderUserAccess ClickHouse RuntimeRole "alpha_runtime" LoginQuiesced noUserAccess)
          , ("drain alpha_runtime", renderTerminateSessions ClickHouse ["alpha_runtime"] <> renderObserveDrain ClickHouse ["alpha_runtime"] ["alpha", "alpha_ledger"])
          , ("set-password alpha_runtime", renderSetPassword "alpha_runtime" (ch salt1 "pw2-alpha_runtime"))
          , ("observe", renderObserveClickHouse ["alpha_migration", "alpha_runtime"] ["alpha", "alpha_ledger"])
          , ("restore-scratch", renderScratchRestore ClickHouse [("alpha", "alpha_restore_r1"), ("alpha_ledger", "alpha_ledger_restore_r1")] "alpha-ch-backup-r1.zip" "alpha_migration" "alpha_runtime")
          , ("reader-access alpha_reader_dash on", renderReaderAccess ClickHouse (ReaderAccess "alpha_reader_dash" LoginOpen (defaultReaderLimits ClickHouse) (map chView ["v1", "v2", "pv"]) [chView "not_yet"] [] [] [] []))
          , ("reader-access alpha_reader_dash off", renderReaderAccess ClickHouse (ReaderAccess "alpha_reader_dash" LoginClosed (defaultReaderLimits ClickHouse) (map chView ["v1", "v2", "pv"]) [] [] [] [] []))
          ]
    , testCase "a converged PostgreSQL app database observes as complete" $ do
        catalog <- postgresCatalog "converged" "alpha"
        classifyUser Postgres (plain RuntimeRole True) "alpha_runtime" [] catalog @?= MemberComplete "postgres-role:16386"
        classifyUser Postgres (plain MigrationRole True) "alpha_migration" [] catalog @?= MemberComplete "postgres-role:16385"
        classifyDatabase (pgAccess "alpha" "alpha" True) catalog @?= MemberComplete "postgres-database:16387"
        incomplete (classifyUser Postgres (plain RuntimeRole False) "alpha_runtime" [] catalog)
        incomplete (classifyDatabase (pgAccess "alpha" "alpha" False) catalog)
    , testCase "a fresh PostgreSQL database is incomplete and elevated roles are drift" $ do
        catalog <- postgresCatalog "fresh" "gamma"
        drift (classifyUser Postgres (plain RuntimeRole True) "gamma_runtime" [] catalog)
        classifyUser Postgres (plain MigrationRole True) "gamma_migration" [] catalog @?= MemberComplete "postgres-role:16407"
        incomplete (classifyDatabase (pgAccess "gamma" "gamma" True) catalog)
        classifyUser Postgres (plain RuntimeRole True) "absent_runtime" [] catalog @?= MemberAbsent
    , testCase "ClickHouse converged access is complete and foreign grants are drift" $ do
        converged <- clickHouseCatalog "converged" ["alpha_migration", "alpha_runtime"] ["alpha", "alpha_ledger"]
        mapM_ (\role -> complete (classifyUser ClickHouse (plain role True) ("alpha_" <> roleName role) [] converged)) [RuntimeRole, MigrationRole]
        mapM_ (\db -> complete (classifyDatabase (chAccess db True) converged)) ["alpha", "alpha_ledger"]
        incomplete (classifyDatabase (chAccess "alpha" False) converged)
        drifted <- clickHouseCatalog "drifted" ["gamma_migration", "gamma_runtime"] ["gamma", "alpha"]
        drift (classifyUser ClickHouse (plain RuntimeRole True) "gamma_runtime" [] drifted)
        drift (classifyUser ClickHouse (plain MigrationRole True) "gamma_migration" [] drifted)
        incomplete (classifyDatabase (DatabaseAccess ClickHouse "" "gamma" "gamma_migration" "gamma_runtime" True [] [] []) drifted)
        drift (classifyDatabase (DatabaseAccess ClickHouse "" "alpha" "gamma_migration" "gamma_runtime" True [] [] []) drifted)
    , testCase "access to the app's own scratch restores is not drift; to any other database it is (M7)" $ do
        catalog <- postgresCatalog "converged" "alpha"
        let with anomalies = catalog & #users . ix "alpha_runtime" . #anomalies .~ anomalies
        classifyUser Postgres (plain RuntimeRole True) "alpha_runtime" ["alpha"] (with ["access to database alpha_restore_r1"]) @?= MemberComplete "postgres-role:16386"
        drift (classifyUser Postgres (plain RuntimeRole True) "alpha_runtime" ["alpha"] (with ["access to database beta_restore_r1"]))
        drift (classifyUser Postgres (plain RuntimeRole True) "alpha_runtime" ["alpha"] (with ["access to database alpha_restore_R1"]))
        drift (classifyUser Postgres (plain RuntimeRole True) "alpha_runtime" [] (with ["access to database alpha_restore_r1"]))
        complete (classifyUser ClickHouse (plain RuntimeRole True) "alpha_runtime" ["alpha_ledger"] (with ["grant of SELECT on database alpha_ledger_restore_r1"]))
        drift (classifyUser ClickHouse (plain RuntimeRole True) "alpha_runtime" ["alpha_ledger"] (with ["grant of SELECT on database beta_restore_r1"]))
    , testCase "observed ClickHouse exceptions and ceilings classify by the desired and accepted declaration (EP-204)" $ do
        observed <- clickHouseCatalog "access" ["alpha_migration", "alpha_runtime"] ["alpha", "alpha_ledger"]
        complete (classifyUser ClickHouse (declared RuntimeRole chRuntimeAccess) "alpha_runtime" [] observed)
        complete (classifyUser ClickHouse (declared MigrationRole chMigrationAccess) "alpha_migration" [] observed)
        -- Never declared: access Nagare never reviewed.
        drift (classifyUser ClickHouse (plain RuntimeRole True) "alpha_runtime" [] observed)
        drift (classifyUser ClickHouse (plain MigrationRole True) "alpha_migration" [] observed)
        -- Removed from the declaration under review: revoked and reset.
        incomplete (classifyUser ClickHouse (UserDeclaration RuntimeRole True noUserAccess chRuntimeAccess) "alpha_runtime" [] observed)
        incomplete (classifyUser ClickHouse (UserDeclaration RuntimeRole True (chRuntimeAccess & #limits . #maxExecutionSeconds ?~ 9) chRuntimeAccess) "alpha_runtime" [] observed)
        -- Retired: the exceptions are kept until the update revokes them.
        incomplete (classifyUser ClickHouse (UserDeclaration RuntimeRole False chRuntimeAccess chRuntimeAccess) "alpha_runtime" [] observed)
        mapM_ (\db -> complete (classifyDatabase (chAccess db True) observed)) ["alpha", "alpha_ledger"]
        -- A scratch restore's grants beside the declared access are the app's own.
        let restored = observed & #users . ix "alpha_runtime" . #anomalies .~ ["grant of SELECT on database alpha_restore_r1"]
        complete (classifyUser ClickHouse (declared RuntimeRole chRuntimeAccess) "alpha_runtime" ["alpha"] restored)
        handChanged <- clickHouseCatalog "access-drifted" ["alpha_migration", "alpha_runtime"] ["alpha", "alpha_ledger"]
        drift (classifyUser ClickHouse (declared RuntimeRole chRuntimeAccess) "alpha_runtime" [] handChanged)
        drift (classifyUser ClickHouse (declared MigrationRole chMigrationAccess) "alpha_migration" [] handChanged)
    , testCase "observed PostgreSQL limits classify by declaration and declared pg_monitor grants are not drift (EP-204)" $ do
        observed <- postgresCatalogFrom "access" "pgmq" "alpha"
        complete (classifyUser Postgres (declared RuntimeRole pgRuntimeAccess) "alpha_runtime" [] observed)
        complete (classifyUser Postgres (plain MigrationRole True) "alpha_migration" [] observed)
        drift (classifyUser Postgres (plain RuntimeRole True) "alpha_runtime" [] observed)
        incomplete (classifyUser Postgres (UserDeclaration RuntimeRole True noUserAccess pgRuntimeAccess) "alpha_runtime" [] observed)
        incomplete (classifyUser Postgres (plain MigrationRole True & #desired .~ pgRuntimeAccess) "alpha_migration" [] observed)
        complete (classifyDatabase (pgAccess "alpha" "alpha" True & #monitoring .~ [PgMonitor]) observed)
        case classifyDatabase (pgAccess "alpha" "alpha" True) observed of
          MemberDrift reason -> assertBool (T.unpack reason) ("pg_monitor" `T.isInfixOf` reason)
          other -> assertFailure ("undeclared pg_monitor grants are not drift: " <> show other)
    , testCase "drain observations parse: running work, unfinished and failed mutations, and the server identity (EP-205)" $ do
        let parsed engine' file = BS.readFile ("test/fixtures/app-database/observed/" <> file) >>= either (assertFailure . T.unpack) pure . parseDrainObservation engine'
        busy <- parsed ClickHouse "clickhouse-drain-busy.jsonl"
        (busy ^. #sessions, busy ^. #unfinished) @?= (1, ["alpha.t mutation_9.txt"])
        assertBool (show busy) (["alpha.t mutation_9.txt: Code: 395"] == map (T.take 33) (busy ^. #failed))
        idle <- parsed ClickHouse "clickhouse-drain-idle.jsonl"
        (idle ^. #sessions, idle ^. #unfinished, idle ^. #failed) @?= (0, [], [])
        -- The process start time moved by a second between the two reads; the
        -- compared identity does not.
        assertBool "process start moved" (busy ^. #identity /= idle ^. #identity)
        comparedIdentity (busy ^. #identity) @?= comparedIdentity (idle ^. #identity)
        pgBusy <- parsed Postgres "postgres-drain-busy.json"
        pgIdle <- parsed Postgres "postgres-drain-idle.json"
        (pgBusy ^. #sessions, pgIdle ^. #sessions) @?= (1, 0)
        pgBusy ^. #identity @?= pgIdle ^. #identity
    , testCase "a quiesced ClickHouse user's withheld grants classify by the sibling users' login (EP-205)" $ do
        converged <- clickHouseCatalog "converged" ["alpha_migration", "alpha_runtime"] ["alpha", "alpha_ledger"]
        incomplete (classifyDatabase (chAccess "alpha" True & #withheld .~ ["alpha_runtime"]) converged)
        let withheld = converged & #databases . ix "alpha" . #grants %~ filter ((/= "alpha_runtime") . (^. #grantee))
        complete (classifyDatabase (chAccess "alpha" True & #withheld .~ ["alpha_runtime"]) withheld)
        incomplete (classifyDatabase (chAccess "alpha" True) withheld)
    , testCase "an observed ClickHouse reader classifies by its declared objects and the reader settings (EP-206)" $ do
        observed <- clickHouseCatalog "reader" ["alpha_migration", "alpha_runtime", "alpha_reader_dash"] ["alpha", "alpha_ledger"]
        let spec names = ReaderSpec [chObject n | n <- names] (defaultReaderLimits ClickHouse)
            reader desired accepted' = fst (classifyReader ClickHouse (ReaderDeclaration True (spec desired) (spec <$> accepted')) "alpha_reader_dash" observed)
        complete (reader ["v1", "v2", "pv"] (Just ["v1", "v2", "pv"]))
        -- A declared object not held yet is granted up front: nothing is pending on ClickHouse.
        classifyReader ClickHouse (ReaderDeclaration True (spec ["v1", "v2", "pv", "later"]) Nothing) "alpha_reader_dash" observed
          @?= (MemberIncomplete "clickhouse-user:134bd01d-b46a-dd89-6156-dd34bb809ea6" "alpha_reader_dash: lacks SELECT on alpha.later", [])
        -- Only the accepted declaration named pv: revoked by review.
        incomplete (reader ["v1", "v2"] (Just ["v1", "v2", "pv"]))
        -- Neither names it: a grant Nagare never made.
        drift (reader ["v1", "v2"] (Just ["v1", "v2"]))
        -- A raised ceiling the review did not declare is drift; a declared change is an update.
        drift (fst (classifyReader ClickHouse (ReaderDeclaration True (spec ["v1", "v2", "pv"] & #limits . #maxThreads ?~ 8) (Just (spec ["v1", "v2", "pv"] & #limits . #maxThreads ?~ 8))) "alpha_reader_dash" observed))
        incomplete (fst (classifyReader ClickHouse (ReaderDeclaration True (spec ["v1", "v2", "pv"] & #limits . #maxThreads ?~ 8) (Just (spec ["v1", "v2", "pv"]))) "alpha_reader_dash" observed))
        -- Disabled: its grants are kept until the update revokes them.
        incomplete (fst (classifyReader ClickHouse (ReaderDeclaration False (spec ["v1", "v2", "pv"]) (Just (spec ["v1", "v2", "pv"]))) "alpha_reader_dash" observed))
        -- The reader's table grants are not the database's foreign grants.
        mapM_ (\db -> complete (classifyDatabase (chAccess db True & #readers .~ ["alpha_reader_dash"]) observed)) ["alpha", "alpha_ledger"]
    , testCase "an observed PostgreSQL reader classifies by its grants, refuses definer functions and invoker views, and names pending objects (EP-206)" $ do
        base <- postgresCatalogFrom "reader" "reader" "alpha"
        relations <- BS.readFile "test/fixtures/app-database/observed/postgres-relations-reader.json"
        observed <- either (assertFailure . T.unpack) pure (withPostgresRelations (Map.singleton "alpha" relations) base)
        let spec names = ReaderSpec [pgObject n | n <- names] (defaultReaderLimits Postgres)
            classify desired accepted' catalog = classifyReader Postgres (ReaderDeclaration True (spec desired) (spec <$> accepted')) "alpha_reader_dash" catalog
            revoked = observed & #databases . ix "alpha" . #definerFunctions .~ []
        -- add_row is SECURITY DEFINER and PUBLIC may execute it in public.
        case fst (classify ["v1", "v2"] (Just ["v1", "v2"]) observed) of
          MemberRefused code reason -> do
            code @?= readerDefinerCode
            assertBool (T.unpack reason) ("public.add_row(x integer)" `T.isInfixOf` reason)
          other -> assertFailure ("expected the definer refusal: " <> show other)
        classify ["v1", "v2"] (Just ["v1", "v2"]) revoked @?= (MemberComplete "postgres-role:16432", [])
        case fst (classify ["v1", "v2", "vi"] (Just ["v1", "v2"]) revoked) of
          MemberRefused code _ -> code @?= readerInvokerCode
          other -> assertFailure ("expected the invoker refusal: " <> show other)
        -- A view the app's migrations have not created is pending, not a change.
        classify ["v1", "v2", "later"] (Just ["v1", "v2"]) revoked @?= (MemberComplete "postgres-role:16432", [pgView "later"])
        incomplete (fst (classify ["v1"] (Just ["v1", "v2"]) revoked))
        drift (fst (classify ["v1"] (Just ["v1"]) revoked))
        -- Its CONNECT and USAGE are judged by the reader member, not the database's.
        complete (classifyDatabase (pgAccess "alpha" "alpha" True & #readers .~ ["alpha_reader_dash"]) revoked)
        drift (classifyDatabase (pgAccess "alpha" "alpha" True) revoked)
    , testCase "a stored verifier matches only the password it was made from" $ do
        let verifier = scramVerifier salt1 "pw2-alpha_runtime"
        scramVerifierMatches "pw2-alpha_runtime" verifier @?= True
        scramVerifierMatches "pw-alpha_runtime" verifier @?= False
        scramVerifierMatches "pw2-alpha_runtime" "md5abc" @?= False
    ]

postgresCatalog :: Text -> Text -> IO Catalog
postgresCatalog state = postgresCatalogFrom state state

postgresCatalogFrom :: Text -> Text -> Text -> IO Catalog
postgresCatalogFrom serverState databaseState db = do
  server <- BS.readFile ("test/fixtures/app-database/observed/postgres-server-" <> T.unpack serverState <> ".json")
  inside <- BS.readFile ("test/fixtures/app-database/observed/postgres-database-" <> T.unpack databaseState <> ".json")
  either (assertFailure . T.unpack) pure (parsePostgresCatalog server (Map.singleton db inside))

clickHouseCatalog :: Text -> [Text] -> [Text] -> IO Catalog
clickHouseCatalog state users dbs = do
  bytes <- BS.readFile ("test/fixtures/app-database/observed/clickhouse-" <> T.unpack state <> ".jsonl")
  either (assertFailure . T.unpack) pure (parseClickHouseCatalog users dbs bytes)

pgAccess :: Text -> Text -> Bool -> DatabaseAccess
pgAccess app db on = DatabaseAccess Postgres "smoke_pg" db (app <> "_migration") (app <> "_runtime") on [] [] []

chAccess :: Text -> Bool -> DatabaseAccess
chAccess db on = DatabaseAccess ClickHouse "" db "alpha_migration" "alpha_runtime" on [] [] []

-- | The M1 fixture's reader objects.
pgView, chView :: Text -> ResolvedObject
pgView = ResolvedObject "alpha" (Just "public")
chView = ResolvedObject "alpha" Nothing

pgObject, chObject :: Text -> ReaderObject
pgObject name = ReaderRelation (ok (mkLogicalDatabaseName "alpha")) Nothing (ok (mkRelationName name))
chObject = pgObject

ok :: Either Text a -> a
ok = either (error . T.unpack) id

-- | A user declaring no reviewed access, now or before.
plain :: AppDatabaseRole -> Bool -> UserDeclaration
plain role on = UserDeclaration role on noUserAccess noUserAccess

-- | A user whose desired and accepted access are both the given one.
declared :: AppDatabaseRole -> UserAccess -> UserDeclaration
declared role access = UserDeclaration role True access access

-- | The access the EP-204 fixture blocks were proven with.
chRuntimeAccess, chMigrationAccess, pgRuntimeAccess :: UserAccess
chRuntimeAccess = UserAccess [minBound .. maxBound] (noUserLimits & #maxMemoryBytes ?~ 268435456 & #maxExecutionSeconds ?~ 5 & #maxConcurrentQueries ?~ 2)
chMigrationAccess = UserAccess [SystemDisks, SystemStoragePolicies] (noUserLimits & #maxMemoryBytes ?~ 1073741824 & #maxExecutionSeconds ?~ 600)
pgRuntimeAccess = UserAccess [] (noUserLimits & #connectionLimit ?~ 3 & #statementTimeoutSeconds ?~ 30)

roleName :: AppDatabaseRole -> Text
roleName = appDatabaseRoleToken

complete, incomplete, drift :: MemberState -> Assertion
complete state = case state of MemberComplete _ -> pure (); other -> assertFailure ("expected complete: " <> show other)
incomplete state = case state of MemberIncomplete _ _ -> pure (); other -> assertFailure ("expected incomplete: " <> show other)
drift state = case state of MemberDrift _ -> pure (); other -> assertFailure ("expected drift: " <> show other)

salt0 :: BS.ByteString
salt0 = BS.pack [0 .. 15]

salt1 :: BS.ByteString
salt1 = BS.pack [16 .. 31]

-- | The statements of each @-- operation: NAME@ block, without comments or
-- blank lines.
fixture :: Text -> IO (Map.Map Text Text)
fixture engine = do
  content <- TIO.readFile ("test/fixtures/app-database/" <> T.unpack engine <> ".sql")
  pure (Map.fromListWith (flip (<>)) (blocks Nothing (T.lines content)))
  where
    blocks _ [] = []
    blocks current (line : rest) = case T.stripPrefix "-- operation: " line of
      Just name -> (name, "") : blocks (Just name) rest
      Nothing
        | Just name <- current
        , not (T.null (T.strip line))
        , not ("--" `T.isPrefixOf` line) ->
            (name, line <> "\n") : blocks current rest
        | otherwise -> blocks current rest

matches :: Map.Map Text Text -> Text -> Text -> Assertion
matches blocks name rendered = case Map.lookup name blocks of
  Nothing -> assertFailure ("fixture has no block " <> T.unpack name)
  Just expected -> assertEqual (T.unpack name) expected (T.unlines (filter (not . T.null . T.strip) (T.lines rendered)))
