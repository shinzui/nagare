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
import Nagare.Dsl.AppDatabase (AppDatabaseRole (..))
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
            access on = DatabaseAccess Postgres "smoke_pg" "alpha" "alpha_migration" "alpha_runtime" on
        mapM_
          (uncurry (matches blocks))
          [ ("create-user alpha_migration", renderCreateUser Postgres "alpha_migration" (pg salt0 "pw-alpha_migration") "alpha")
          , ("create-user alpha_runtime", renderCreateUser Postgres "alpha_runtime" (pg salt0 "pw-alpha_runtime") "alpha")
          , ("create-database alpha", renderCreateDatabase Postgres "alpha" "alpha_migration")
          , ("database-access alpha on", renderDatabaseAccess (access True))
          , ("database-access alpha off", renderDatabaseAccess (access False))
          , ("user-access alpha_runtime on", renderUserAccess Postgres RuntimeRole "alpha_runtime" True)
          , ("user-access alpha_runtime off", renderUserAccess Postgres RuntimeRole "alpha_runtime" False)
          , ("user-access alpha_migration on", renderUserAccess Postgres MigrationRole "alpha_migration" True)
          , ("user-access alpha_migration off", renderUserAccess Postgres MigrationRole "alpha_migration" False)
          , ("set-password alpha_runtime", renderSetPassword "alpha_runtime" (pg salt1 "pw2-alpha_runtime"))
          , ("observe-server", renderObserveServer ["alpha_migration", "alpha_runtime"] ["alpha"] "smoke_pg")
          , ("observe-database alpha", renderObserveDatabase)
          , ("observe-password alpha_runtime", renderObservePassword "alpha_runtime")
          , ("restore-scratch", renderScratchRestore Postgres [("alpha", "alpha_restore_r1")] "" "alpha_migration" "alpha_runtime")
          ]
    , testCase "ClickHouse commands match the proven fixture" $ do
        blocks <- fixture "clickhouse"
        let ch = hashPassword ClickHouse
            access db on = DatabaseAccess ClickHouse "" db "alpha_migration" "alpha_runtime" on
        mapM_
          (uncurry (matches blocks))
          [ ("create-user alpha_migration", renderCreateUser ClickHouse "alpha_migration" (ch salt0 "pw-alpha_migration") "alpha")
          , ("create-user alpha_runtime", renderCreateUser ClickHouse "alpha_runtime" (ch salt0 "pw-alpha_runtime") "alpha")
          , ("user-access alpha_migration on", renderUserAccess ClickHouse MigrationRole "alpha_migration" True)
          , ("user-access alpha_migration off", renderUserAccess ClickHouse MigrationRole "alpha_migration" False)
          , ("user-access alpha_runtime on", renderUserAccess ClickHouse RuntimeRole "alpha_runtime" True)
          , ("user-access alpha_runtime off", renderUserAccess ClickHouse RuntimeRole "alpha_runtime" False)
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
        classifyUser Postgres RuntimeRole True "alpha_runtime" catalog @?= MemberComplete "postgres-role:16386"
        classifyUser Postgres MigrationRole True "alpha_migration" catalog @?= MemberComplete "postgres-role:16385"
        classifyDatabase (pgAccess "alpha" "alpha" True) catalog @?= MemberComplete "postgres-database:16387"
        incomplete (classifyUser Postgres RuntimeRole False "alpha_runtime" catalog)
        incomplete (classifyDatabase (pgAccess "alpha" "alpha" False) catalog)
    , testCase "a fresh PostgreSQL database is incomplete and elevated roles are drift" $ do
        catalog <- postgresCatalog "fresh" "gamma"
        drift (classifyUser Postgres RuntimeRole True "gamma_runtime" catalog)
        classifyUser Postgres MigrationRole True "gamma_migration" catalog @?= MemberComplete "postgres-role:16407"
        incomplete (classifyDatabase (pgAccess "gamma" "gamma" True) catalog)
        classifyUser Postgres RuntimeRole True "absent_runtime" catalog @?= MemberAbsent
    , testCase "ClickHouse converged access is complete and foreign grants are drift" $ do
        converged <- clickHouseCatalog "converged" ["alpha_migration", "alpha_runtime"] ["alpha", "alpha_ledger"]
        mapM_ (\role -> complete (classifyUser ClickHouse role True ("alpha_" <> roleName role) converged)) [RuntimeRole, MigrationRole]
        mapM_ (\db -> complete (classifyDatabase (chAccess db True) converged)) ["alpha", "alpha_ledger"]
        incomplete (classifyDatabase (chAccess "alpha" False) converged)
        drifted <- clickHouseCatalog "drifted" ["gamma_migration", "gamma_runtime"] ["gamma", "alpha"]
        drift (classifyUser ClickHouse RuntimeRole True "gamma_runtime" drifted)
        drift (classifyUser ClickHouse MigrationRole True "gamma_migration" drifted)
        incomplete (classifyDatabase (DatabaseAccess ClickHouse "" "gamma" "gamma_migration" "gamma_runtime" True) drifted)
        drift (classifyDatabase (DatabaseAccess ClickHouse "" "alpha" "gamma_migration" "gamma_runtime" True) drifted)
    , testCase "a stored verifier matches only the password it was made from" $ do
        let verifier = scramVerifier salt1 "pw2-alpha_runtime"
        scramVerifierMatches "pw2-alpha_runtime" verifier @?= True
        scramVerifierMatches "pw-alpha_runtime" verifier @?= False
        scramVerifierMatches "pw2-alpha_runtime" "md5abc" @?= False
    ]

postgresCatalog :: Text -> Text -> IO Catalog
postgresCatalog state db = do
  server <- BS.readFile ("test/fixtures/app-database/observed/postgres-server-" <> T.unpack state <> ".json")
  inside <- BS.readFile ("test/fixtures/app-database/observed/postgres-database-" <> T.unpack state <> ".json")
  either (assertFailure . T.unpack) pure (parsePostgresCatalog server (Map.singleton db inside))

clickHouseCatalog :: Text -> [Text] -> [Text] -> IO Catalog
clickHouseCatalog state users dbs = do
  bytes <- BS.readFile ("test/fixtures/app-database/observed/clickhouse-" <> T.unpack state <> ".jsonl")
  either (assertFailure . T.unpack) pure (parseClickHouseCatalog users dbs bytes)

pgAccess :: Text -> Text -> Bool -> DatabaseAccess
pgAccess app db = DatabaseAccess Postgres "smoke_pg" db (app <> "_migration") (app <> "_runtime")

chAccess :: Text -> Bool -> DatabaseAccess
chAccess db = DatabaseAccess ClickHouse "" db "alpha_migration" "alpha_runtime"

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
