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
import Test.Tasty
import Test.Tasty.HUnit

appDatabaseSqlTests :: TestTree
appDatabaseSqlTests =
  testGroup
    "AppDatabase SQL"
    [ testCase "PostgreSQL commands match the proven fixture" $ do
        blocks <- fixture "postgres"
        let pg = hashPassword Postgres
            access on = DatabaseAccess Postgres "smoke_pg" "alpha" "alpha_migration" "alpha_runtime" on []
        mapM_
          (uncurry (matches blocks))
          [ ("create-user alpha_migration", renderCreateUser Postgres "alpha_migration" (pg salt0 "pw-alpha_migration") "alpha")
          , ("create-user alpha_runtime", renderCreateUser Postgres "alpha_runtime" (pg salt0 "pw-alpha_runtime") "alpha")
          , ("create-database alpha", renderCreateDatabase Postgres "alpha" "alpha_migration")
          , ("database-access alpha on", renderDatabaseAccess (access True))
          , ("database-access alpha off", renderDatabaseAccess (access False))
          , ("user-access alpha_runtime on", renderUserAccess Postgres RuntimeRole "alpha_runtime" True noUserAccess)
          , ("user-access alpha_runtime off", renderUserAccess Postgres RuntimeRole "alpha_runtime" False noUserAccess)
          , ("user-access alpha_migration on", renderUserAccess Postgres MigrationRole "alpha_migration" True noUserAccess)
          , ("user-access alpha_migration off", renderUserAccess Postgres MigrationRole "alpha_migration" False noUserAccess)
          , ("user-access alpha_runtime on with declared access", renderUserAccess Postgres RuntimeRole "alpha_runtime" True pgRuntimeAccess)
          , ("user-access alpha_runtime off with declared access", renderUserAccess Postgres RuntimeRole "alpha_runtime" False pgRuntimeAccess)
          , ("set-password alpha_runtime", renderSetPassword "alpha_runtime" (pg salt1 "pw2-alpha_runtime"))
          , ("observe-server", renderObserveServer ["alpha_migration", "alpha_runtime"] ["alpha"] "smoke_pg")
          , ("observe-database alpha", renderObserveDatabase)
          , ("observe-password alpha_runtime", renderObservePassword "alpha_runtime")
          , ("restore-scratch", renderScratchRestore Postgres [("alpha", "alpha_restore_r1")] "" "alpha_migration" "alpha_runtime")
          ]
    , testCase "ClickHouse commands match the proven fixture" $ do
        blocks <- fixture "clickhouse"
        let ch = hashPassword ClickHouse
            access db on = DatabaseAccess ClickHouse "" db "alpha_migration" "alpha_runtime" on []
        mapM_
          (uncurry (matches blocks))
          [ ("create-user alpha_migration", renderCreateUser ClickHouse "alpha_migration" (ch salt0 "pw-alpha_migration") "alpha")
          , ("create-user alpha_runtime", renderCreateUser ClickHouse "alpha_runtime" (ch salt0 "pw-alpha_runtime") "alpha")
          , ("user-access alpha_migration on", renderUserAccess ClickHouse MigrationRole "alpha_migration" True noUserAccess)
          , ("user-access alpha_migration off", renderUserAccess ClickHouse MigrationRole "alpha_migration" False noUserAccess)
          , ("user-access alpha_runtime on", renderUserAccess ClickHouse RuntimeRole "alpha_runtime" True noUserAccess)
          , ("user-access alpha_runtime off", renderUserAccess ClickHouse RuntimeRole "alpha_runtime" False noUserAccess)
          , ("user-access alpha_runtime on with declared access", renderUserAccess ClickHouse RuntimeRole "alpha_runtime" True chRuntimeAccess)
          , ("user-access alpha_runtime off with declared access", renderUserAccess ClickHouse RuntimeRole "alpha_runtime" False chRuntimeAccess)
          , ("user-access alpha_migration on with declared access", renderUserAccess ClickHouse MigrationRole "alpha_migration" True chMigrationAccess)
          , ("create-database alpha", renderCreateDatabase ClickHouse "alpha" "alpha_migration")
          , ("create-database alpha_ledger", renderCreateDatabase ClickHouse "alpha_ledger" "alpha_migration")
          , ("database-access alpha on", renderDatabaseAccess (access "alpha" True))
          , ("database-access alpha off", renderDatabaseAccess (access "alpha" False))
          , ("database-access alpha_ledger on", renderDatabaseAccess (access "alpha_ledger" True))
          , ("database-access alpha_ledger off", renderDatabaseAccess (access "alpha_ledger" False))
          , ("set-password alpha_runtime", renderSetPassword "alpha_runtime" (ch salt1 "pw2-alpha_runtime"))
          , ("observe", renderObserveClickHouse ["alpha_migration", "alpha_runtime"] ["alpha", "alpha_ledger"])
          , ("restore-scratch", renderScratchRestore ClickHouse [("alpha", "alpha_restore_r1"), ("alpha_ledger", "alpha_ledger_restore_r1")] "alpha-ch-backup-r1.zip" "alpha_migration" "alpha_runtime")
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
        incomplete (classifyDatabase (DatabaseAccess ClickHouse "" "gamma" "gamma_migration" "gamma_runtime" True []) drifted)
        drift (classifyDatabase (DatabaseAccess ClickHouse "" "alpha" "gamma_migration" "gamma_runtime" True []) drifted)
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
pgAccess app db on = DatabaseAccess Postgres "smoke_pg" db (app <> "_migration") (app <> "_runtime") on []

chAccess :: Text -> Bool -> DatabaseAccess
chAccess db on = DatabaseAccess ClickHouse "" db "alpha_migration" "alpha_runtime" on []

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
roleName RuntimeRole = "runtime"
roleName MigrationRole = "migration"

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
