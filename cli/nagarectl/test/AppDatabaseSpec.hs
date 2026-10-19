-- | EP-202 M2: app-database declarations load and validate, and compile into
-- their own standalone scopes against an accepted shared server.
module AppDatabaseSpec
  ( appDatabaseTests
  , Server
  , alpha
  , beta
  , pgServer
  , chServer
  , scopeOf
  , serverStateful
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.App.Deploy (RolloutEnv (..))
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Database.Secret (b64decode)
import Nagare.Dsl.AppDatabase
import Nagare.Dsl.Config (encodeAppDatabases, encodeWorker)
import Nagare.Dsl.Database (Database (Database), Engine (..), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Load (LoadError (..), decodeAppDatabases, decodeWorker)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (webWorker)
import Nagare.Inventory.Adapters.AppDatabaseRuntime (clickHouseLoginVerdict)
import Nagare.Inventory.Adapters.CredentialTemplate (credentialDataMatches, materializeCredential)
import Nagare.Inventory.AppDatabase
import Nagare.Inventory.AppDatabaseRestore (AppDatabaseRestoreRequest (..), RestoreTarget (..), compileAppDatabaseRestoreScope)
import Nagare.Inventory.Application (DatabaseBinding, acceptedAppDatabaseBindings, acceptedDatabaseBindings, compileStandaloneWorkerWithDependencies)
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (HourlyRecoveryPoint))
import Nagare.Inventory.BackupReceipt (ScheduledBackupReceipt (..), ScheduledReceiptExpectation (..), scheduledAppDatabaseReceiptExpectationFromCronJob)
import Nagare.Inventory.DataService (compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Restore (manualRestoreTargetProof)
import Nagare.Inventory.ScheduledIngest (ScheduledIngestRequest (..), ScheduledIngestSource (..), compileScheduledIngestScope)
import Nagare.Inventory.ScheduledReceipt (ScheduledReceiptEvidence (..))
import Nagare.Inventory.ScheduledStatus (ScheduledStatusKind (..), scheduledStatusSources)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Ops.Probe (Probe (..), ProbeStatus (StatusOk), retiredRecoveryPointProbe)
import Nagare.Resource.AppDatabase (appDatabaseCredentialTemplate)
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), RecoveryIntent (..), Sensitivity (Private), mkSecretRef)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Support.Profiles (tnbProfile)
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

appDatabaseTests :: TestTree
appDatabaseTests =
  testGroup
    "AppDatabase"
    [ testGroup
        "declaration"
        [ testCase "names follow the SQL and DNS rules" $ do
            isRight' (mkAppDatabaseName "kansoku-pg") @?= True
            isRight' (mkAppDatabaseName "9lives") @?= False
            isRight' (mkAppDatabaseName (T.replicate 37 "a")) @?= False
            isRight' (mkLogicalDatabaseName "kansoku_migration_ledger") @?= True
            isRight' (mkLogicalDatabaseName "Analytics") @?= False
            isRight' (mkLogicalDatabaseName "has-hyphen") @?= False
            isRight' (mkLogicalDatabaseName (T.replicate 49 "a")) @?= False
        , testCase "users and Secrets derive from the app-database name" $ do
            let n = known (mkAppDatabaseName "kansoku-pg")
            appDatabaseUser n RuntimeRole @?= "kansoku_pg_runtime"
            appDatabaseUser n MigrationRole @?= "kansoku_pg_migration"
            appDatabaseSecretName n RuntimeRole @?= "kansoku-pg-runtime"
            appDatabaseSecretName n MigrationRole @?= "kansoku-pg-migration"
        , testCase "emitted declarations decode back unchanged" $
            decodeAppDatabases (LBS.toStrict (encodeAppDatabases [kansokuPg, kansokuCh])) @?= Right [kansokuPg, kansokuCh]
        , testCase "a workload's appDatabases round-trip, and an empty list emits nothing" $ do
            let plain = either error id (webWorker "probe" "registry.example.com/probe")
                bound = plain & #appDatabases .~ [known (mkAppDatabaseName "kansoku-pg")]
            decodeWorker (LBS.toStrict (encodeWorker bound)) @?= Right bound
            assertBool "an unbound worker keeps its pre-EP-202 bytes" (not ("appDatabases" `T.isInfixOf` TE.decodeUtf8 (LBS.toStrict (encodeWorker plain))))
        , testCase "loading refuses each invalid declaration with its reason" $ do
            refused (kansokuPg & #engine .~ Redis) "not supported on Redis"
            refused (kansokuPg & #logicalDatabases .~ (logical "a" :| [logical "b"])) "exactly one logical database"
            refused (kansokuCh & #logicalDatabases .~ (logical "a" :| [logical "a"])) "repeats a logical database"
            mapM_ (\reserved -> refused (kansokuPg & #logicalDatabases .~ (logical reserved :| [])) "reserved") ["postgres", "template0", "template1", "labs_postgres"]
            mapM_ (\reserved -> refused (kansokuCh & #logicalDatabases .~ (logical reserved :| [])) "reserved") ["default", "system", "information_schema"]
            assertLeftContaining "logicalDatabases" (decodeAppDatabases (rawJson "{\"name\":\"x\",\"server\":\"s\",\"engine\":\"postgres\",\"namespace\":\"personal\",\"logicalDatabases\":[\"Bad\"]}"))
            assertLeftContaining "declared twice" (decodeAppDatabases (LBS.toStrict (encodeAppDatabases [kansokuPg, kansokuPg])))
        , testCase "declared exceptions and limits round-trip, and no access emits no key (EP-204 M2)" $ do
            decodeAppDatabases (LBS.toStrict (encodeAppDatabases [kansokuPgAccess, kansokuChAccess])) @?= Right [kansokuPgAccess, kansokuChAccess]
            assertBool "a declaration without access keeps its pre-EP-204 bytes" (not ("access" `T.isInfixOf` TE.decodeUtf8 (LBS.toStrict (encodeAppDatabases [kansokuPg, kansokuCh]))))
            assertBool "only declared keys are emitted" (not (any (`T.isInfixOf` TE.decodeUtf8 (LBS.toStrict (encodeAppDatabases [kansokuChAccess]))) ["monitoring", "connectionLimit", "null"]))
        , testCase "access outside the allow-list or the engine refuses before planning (IR-30 AC-1, EP-204 M2)" $ do
            let entry engine' accessJson = "{\"name\":\"x\",\"server\":\"s\",\"engine\":\"" <> engine' <> "\",\"namespace\":\"personal\",\"logicalDatabases\":[\"x\"],\"access\":" <> accessJson <> "}"
            assertLeftContaining "system-query-log" (decodeAppDatabases (rawJson (entry "clickhouse" "{\"runtime\":{\"exceptions\":[\"system-query-log\"]}}")))
            assertLeftContaining "maxMemory" (decodeAppDatabases (rawJson (entry "clickhouse" "{\"runtime\":{\"limits\":{\"maxMemory\":1}}}")))
            assertLeftContaining "pg_read_all_data" (decodeAppDatabases (rawJson (entry "postgres" "{\"monitoring\":[\"pg_read_all_data\"]}")))
            refused (kansokuPg & #access . #runtime . #exceptions .~ [SystemParts]) "ClickHouse privileges"
            refused (kansokuPg & #access . #migration . #limits . #maxMemoryBytes ?~ 1) "ClickHouse limits"
            refused (kansokuCh & #access . #runtime . #limits . #connectionLimit ?~ 1) "PostgreSQL limits"
            refused (kansokuCh & #access . #monitoring .~ [PgMonitor]) "monitoring roles are PostgreSQL"
            refused (kansokuCh & #access . #runtime . #exceptions .~ [SystemDisks, SystemDisks]) "repeats a grant exception"
            refused (kansokuPg & #access . #monitoring .~ [PgMonitor, PgMonitor]) "repeats a monitoring role"
            refused (kansokuCh & #access . #runtime . #limits . #maxExecutionSeconds ?~ 0) "maxExecutionSeconds must be positive"
            refused (kansokuPg & #access . #runtime . #limits . #connectionLimit ?~ (-1)) "connectionLimit must be positive"
            refused (kansokuPg & #access . #runtime . #limits . #statementTimeoutSeconds ?~ 3000000) "statementTimeoutSeconds exceeds"
        ]
    , testGroup
        "scope"
        [ testCase "alpha and beta share one server per engine (AC-1)" $ do
            let inventory =
                  known
                    ( composeInventory
                        (snapshot [pgServer, chServer])
                        ( ReplaceScope (scopeOf pgServer (alpha Postgres))
                            :| [ ReplaceScope (scopeOf pgServer (beta Postgres))
                               , ReplaceScope (scopeOf chServer (alpha ClickHouse))
                               , ReplaceScope (scopeOf chServer (beta ClickHouse))
                               ]
                        )
                    )
                kinds =
                  [ (nameText kind, nameText name)
                  | Managed member <- inventoryDeclarations (candidateInventory inventory)
                  , Kubernetes _ _ kind _ name <- [member ^. #address]
                  , nameText kind `elem` ["statefulset", "persistentvolumeclaim", "service"]
                  ]
            length [() | ("statefulset", _) <- kinds] @?= 2
            length [() | ("persistentvolumeclaim", _) <- kinds] @?= 2
            length [() | ("service", _) <- kinds] @?= 2
            length [() | Managed member <- inventoryDeclarations (candidateInventory inventory), DatabaseName {} <- [member ^. #address]] @?= 5
        , testCase "an app database is two credentials, two users and its databases" $ do
            let (scope, native) = scopeAndNative chServer (alpha ClickHouse)
                members = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]
            nameText (scopeName (scopeId scope)) @?= "appdb-alpha-ch"
            Map.size native @?= 7
            [nameText user | DatabaseUser _ user <- map (^. #address) members] @?= ["alpha_ch_runtime", "alpha_ch_migration"]
            [nameText db | DatabaseName _ db <- map (^. #address) members] @?= ["alpha", "alpha_ledger"]
            [member ^. #executor | member <- members, isLogical member] @?= replicate 4 AppDatabaseExecutor
            assertBool "every logical member is ordered after the server StatefulSet" $
              all (\member -> OrderedAfter (serverStateful chServer ^. #identity) `elem` member ^. #dependencies) (filter isLogical members)
        , testCase "each app database has its own schedule, dumping with its migration credential (M5)" $ do
            let (_, native) = scopeAndNative chServer (alpha ClickHouse)
                cron = [bytes | (member, bytes) <- Map.elems native, Kubernetes _ "batch" kind _ name <- [member ^. #address], nameText kind == "cronjob", nameText name == "nagare-appdb-alpha-ch"]
                uid = known . mkPhysicalIdentity
            bytes <- case cron of
              [found] -> pure found
              _ -> assertFailure "the app database has no unique schedule"
            let text = TE.decodeUtf8 bytes
            assertBool "dumps with the migration Secret" ("alpha-ch-migration" `T.isInfixOf` text)
            assertBool "backs up both logical databases in one archive" ("BACKUP DATABASE alpha, DATABASE alpha_ledger TO File" `T.isInfixOf` text)
            nub (sort (secretKeyRefs bytes)) @?= ["alpha-ch-migration", "nagare-appdb-alpha-ch-signing"]
            assertNoServerLabel bytes
            case scheduledAppDatabaseReceiptExpectationFromCronJob (GcsBackend "project" "bucket") "personal" "alpha-ch" (uid "sts") (uid "pvc") bytes of
              Right expectation -> do
                assertBool "its own key space" ("app-databases/personal/alpha-ch/" `T.isSuffixOf` scheduledObjectPrefix expectation)
                scheduledFormat expectation @?= "zip.gz"
              Left reason -> assertFailure (T.unpack reason)
            case scheduledAppDatabaseReceiptExpectationFromCronJob (GcsBackend "project" "bucket") "personal" "beta-ch" (uid "sts") (uid "pvc") bytes of
              Left _ -> pure ()
              Right _ -> assertFailure "another app database's schedule was accepted"
        , testCase "a scheduled run ingests against the app database and its server's incarnations (M5)" $ do
            (appScope, _, native, receiptScope, stateful, _) <- ingested
            Map.lookup "scheduled.backup.source.kind" (scopeOverrides receiptScope) @?= Just "app-database"
            Map.lookup "scheduled.backup.source.statefulset" (scopeOverrides receiptScope) @?= Just (resourceIdText (stateful ^. #identity))
            assertBool "receipt scope names the app database" ("appdb-scheduled-receipt-personal-alpha-pg-" `T.isPrefixOf` nameText (scopeName (scopeId receiptScope)))
            case compileScheduledIngestScope (ingestRequest (fst chServer) native appScope) appScope native of
              Left _ -> pure ()
              Right _ -> assertFailure "a run ingested against another server"
        , testCase "a restore loads one app database into scratch names as the administrator (M5)" $ do
            (appScope, serverScope, native, receiptScope, _, _) <- ingested
            let request scope =
                  AppDatabaseRestoreRequest "alpha-pg" "personal" "r1" scope serverScope receiptScope (known (mkPhysicalIdentity "sts")) (known (mkPhysicalIdentity "pvc")) (GcsBackend "project" "bucket") (SourceLocation "test" "restore") ScratchTarget (ScopeRevision (known (mkScopeGeneration 2)) (contentDigest "server"))
            (restoreScope, restoreNative) <- either (assertFailure . show) pure (compileAppDatabaseRestoreScope (request appScope) native)
            [bytes] <- pure (map snd (Map.elems restoreNative))
            let text = TE.decodeUtf8 bytes
            assertBool "creates the scratch database owned by the migration user" ("CREATE DATABASE \\\"alpha_restore_r1\\\" OWNER \\\"alpha_pg_migration\\\"" `T.isInfixOf` text)
            assertBool "loads the custom-format dump" ("pg_restore --exit-on-error -h smoke-pg" `T.isInfixOf` text)
            assertBool "touches no other app" (not ("beta" `T.isInfixOf` text))
            nub (sort (secretKeyRefs bytes)) @?= ["nagare-db-smoke-pg"]
            assertNoServerLabel bytes
            Map.lookup "restore.target.databases" (scopeOverrides restoreScope) @?= Just "alpha_restore_r1"
            -- Admission re-checks the server scope's accepted revision and incarnations.
            either (assertFailure . T.unpack) (assertBool "no target proof" . isJust) (manualRestoreTargetProof restoreScope)
            let (betaScope, _) = scopeAndNative pgServer (beta Postgres)
            case compileAppDatabaseRestoreScope (request betaScope) native of
              Left _ -> pure ()
              Right _ -> assertFailure "another app database's backup was restored"
        , testCase "a rebuilt-server restore loads into the declared, still-empty databases (M6)" $ do
            (appScope, serverScope, native, receiptScope, _, _) <- ingested
            let request = AppDatabaseRestoreRequest "alpha-pg" "personal" "r1" appScope serverScope receiptScope (known (mkPhysicalIdentity "sts2")) (known (mkPhysicalIdentity "pvc2")) (GcsBackend "project" "bucket") (SourceLocation "test" "restore") RebuiltTarget (ScopeRevision (known (mkScopeGeneration 2)) (contentDigest "server"))
            (restoreScope, restoreNative) <- either (assertFailure . show) pure (compileAppDatabaseRestoreScope request native)
            [bytes] <- pure (map snd (Map.elems restoreNative))
            let text = TE.decodeUtf8 bytes
            assertBool "refuses a database that already holds relations" ("refusing to restore over data" `T.isInfixOf` text)
            assertBool "loads into the declared database" ("-d alpha /dump/backup.sql" `T.isInfixOf` text)
            assertBool "creates no scratch database" (not ("_restore_r1" `T.isInfixOf` text))
            nub (sort (secretKeyRefs bytes)) @?= ["nagare-db-smoke-pg"]
            Map.lookup "restore.target.kind" (scopeOverrides restoreScope) @?= Just "rebuilt"
            Map.lookup "restore.target.databases" (scopeOverrides restoreScope) @?= Just "alpha"
        , testCase "two app databases cannot claim one logical database on a server" $
            assertComposeRefused "claim-conflict" pgServer [alpha Postgres, beta Postgres & #logicalDatabases .~ (logical "alpha" :| [])]
        , testCase "two app databases cannot claim one user on a server" $
            assertComposeRefused "claim-conflict" pgServer [alpha Postgres, alpha Postgres & #logicalKey .~ Just (known (mkLogicalKey "other")) & #logicalDatabases .~ (logical "other" :| [])]
        , testCase "an app database needs an accepted server of its engine and namespace" $ do
            assertCompileRefused "app-database-server-absent" [] (alpha Postgres)
            assertCompileRefused "app-database-server-engine" [chServer] (alpha Postgres & #server .~ dbServer "smoke-ch")
            assertCompileRefused "app-database-server-engine" [pgServer] (alpha ClickHouse & #server .~ dbServer "smoke-pg")
            assertCompileRefused "app-database-server-namespace" [pgServer] (alpha Postgres & #namespace .~ known (Dsl.mkNamespace "other"))
        , testCase "an app database is refused on a server a workload binds directly" $ do
            let workload = boundWorkload (serverStateful pgServer)
            assertCompileRefusedWith "app-database-on-direct-server" (snapshotWith [pgServer] [workload]) (alpha Postgres)
        , testCase "retirement turns every member off and refuses while a workload binds it" $ do
            let scope = scopeOf pgServer (alpha Postgres)
                accepted = snapshotWith [pgServer] [scope]
                specs revised = [member ^. #spec | bundle <- scopeBundles revised, Managed member <- declarations bundle, member ^. #executor == AppDatabaseExecutor]
            found <- either (assertFailure . T.unpack) pure (namedAppDatabaseScope accepted "alpha-pg" Nothing)
            (retired, _) <- either (assertFailure . show) pure (retireAppDatabaseScope accepted (snd (scopeAndNative pgServer (alpha Postgres))) found)
            [on | LogicalDatabase _ _ _ on _ <- specs retired] @?= [False]
            [on | DatabaseUserSpec _ _ on _ <- specs retired] @?= [False, False]
            let runtime = head [member ^. #identity | bundle <- scopeBundles scope, Managed member <- declarations bundle, DatabaseUserSpec _ "runtime" _ _ <- [member ^. #spec]]
                bound = snapshotWith [pgServer] [scope, boundTo runtime]
            case retireAppDatabaseScope bound Map.empty found of
              Left errors -> map (^. #code) (NE.toList errors) @?= ["app-database-in-use"]
              Right _ -> assertFailure "retirement of a bound app database was accepted"
            map (\row -> (row ^. #name, row ^. #server, row ^. #retired)) (appDatabaseRows accepted) @?= [("alpha-pg", "smoke-pg", False)]
        , testCase "F131: retirement suspends the schedule, re-planning resumes it, and earlier runs still ingest and restore" $ do
            (appScope, serverScope, native, _, _, _) <- ingested
            let accepted = snapshotWith [pgServer] [appScope]
                cronOf scope = head [m | bundle <- scopeBundles scope, Managed m <- declarations bundle, Kubernetes _ _ k _ _ <- [m ^. #address], nameText k == "cronjob"]
                cron = cronOf appScope
            (retired, suspended) <- either (assertFailure . show) pure (retireAppDatabaseScope accepted native appScope)
            Map.keys suspended @?= [cron ^. #identity]
            let (retiredCron, retiredBytes) = suspended Map.! (cron ^. #identity)
            cronOf retired @?= retiredCron
            assertBool "the schedule is an update" (retiredCron ^. #spec /= cron ^. #spec)
            scheduleSuspended retiredBytes @?= True
            scheduleSuspended (snd (native Map.! (cron ^. #identity))) @?= False
            let expectationOf = scheduledAppDatabaseReceiptExpectationFromCronJob (GcsBackend "project" "bucket") "personal" "alpha-pg" (known (mkPhysicalIdentity "sts")) (known (mkPhysicalIdentity "pvc"))
            fmap scheduledPolicyRevision (expectationOf retiredBytes) @?= fmap scheduledPolicyRevision (expectationOf (snd (native Map.! (cron ^. #identity))))
            let retiredNative = Map.union suspended native
            (receiptScope, _) <- either (assertFailure . show) pure (compileScheduledIngestScope (ingestRequest serverScope native retired) retired retiredNative)
            let request = AppDatabaseRestoreRequest "alpha-pg" "personal" "r1" retired serverScope receiptScope (known (mkPhysicalIdentity "sts")) (known (mkPhysicalIdentity "pvc")) (GcsBackend "project" "bucket") (SourceLocation "test" "restore") ScratchTarget (ScopeRevision (known (mkScopeGeneration 2)) (contentDigest "server"))
            either (assertFailure . show) (const (pure ())) (compileAppDatabaseRestoreScope request retiredNative)
            (again, _) <- either (assertFailure . show) pure (retireAppDatabaseScope (snapshotWith [pgServer] [retired]) retiredNative retired)
            again @?= retired
            cronOf (scopeOf pgServer (alpha Postgres)) @?= cron
        , testCase "F132: status grades every app database's schedule, and a retired one as retired" $ do
            let (pgScope, _) = scopeAndNative pgServer (alpha Postgres)
                (chScope, _) = scopeAndNative chServer (alpha ClickHouse)
                accepted = snapshotWith [pgServer, chServer] [pgScope, chScope]
                appRows = [(status ^. #kind, status ^. #label, status ^. #source) | status <- scheduledStatusSources accepted, case status ^. #kind of AppDatabaseStatus _ -> True; _ -> False]
            appRows @?= [(AppDatabaseStatus "alpha-ch", "personal/alpha-ch", scopeId chScope), (AppDatabaseStatus "alpha-pg", "personal/alpha-pg", scopeId pgScope)]
            assertBool "the servers' own schedules are graded too" (any (\status -> status ^. #kind == DatabaseStatus "smoke-pg") (scheduledStatusSources accepted))
            retiredRecoveryPointProbe "personal/beta-ch" @?= Probe "recovery point" StatusOk "personal/beta-ch: retired; schedule suspended"
            source <- either (assertFailure . T.unpack) pure (appDatabaseScheduleSource accepted testCluster "personal" "alpha-pg")
            source ^. #scope @?= pgScope
            source ^. #serverScope @?= fst pgServer
        , testCase "a rotation is one forward-only operation per user, replaced by the next" $ do
            let scope = scopeOf pgServer (alpha Postgres)
                rotations revised = [operation | bundle <- scopeBundles revised, operation <- bundle ^. #operations, operation ^. #operationKind == RotateCredential]
            first' <- either (assertFailure . show) pure (rotateAppDatabaseScope scope "runtime" "2026-10-19T00:00:00Z")
            second' <- either (assertFailure . show) pure (rotateAppDatabaseScope first' "runtime" "2026-10-19T01:00:00Z")
            length (rotations first') @?= 1
            length (rotations second') @?= 1
            assertBool "a new stamp makes a new operation" (rotations first' /= rotations second')
            case rotateAppDatabaseScope scope "admin" "now" of
              Left _ -> pure ()
              Right _ -> assertFailure "rotation of an unknown role was accepted"
        , testCase "a workload receives only its own app databases' runtime Secrets (AC-2)" $ do
            let appScopes = [(s, db) | (s, db) <- [(pgServer, alpha Postgres), (chServer, alpha ClickHouse), (pgServer, beta Postgres), (chServer, beta ClickHouse)]]
                compiled = [scopeAndNative s db | (s, db) <- appScopes]
                accepted = snapshotWith [pgServer, chServer] (map fst compiled)
                native = Map.unions (acceptedNative [pgServer, chServer] : map snd compiled)
            forM_ ["alpha", "beta"] $ \app -> do
              let names = [known (mkAppDatabaseName (app <> "-pg")), known (mkAppDatabaseName (app <> "-ch"))]
              bindings <- either (assertFailure . T.unpack) pure (acceptedAppDatabaseBindings accepted native testCluster "personal" names)
              (scope, workerNative) <- either (assertFailure . show) pure (compileWorker app (Just names) bindings)
              let refs = nub (sort (concatMap (secretKeyRefs . snd) (Map.elems workerNative)))
              refs @?= [app <> "-ch-runtime", app <> "-pg-runtime"]
              let users = [member ^. #identity | (s', _) <- compiled, ("appdb-" <> app) `T.isPrefixOf` nameText (scopeName (scopeId s')), bundle <- scopeBundles s', Managed member <- declarations bundle, member ^. #executor == AppDatabaseExecutor]
                  workloadDependencies = concat [member ^. #dependencies | bundle <- scopeBundles scope, Managed member <- declarations bundle]
              assertBool "the workload is ordered after its app databases" (all (\user -> OrderedAfter user `elem` workloadDependencies) users)
            case acceptedDatabaseBindings accepted native testCluster "personal" [dbServer "smoke-pg"] of
              Left reason -> assertBool (T.unpack reason) ("shared-server-direct-binding" `T.isPrefixOf` reason)
              Right _ -> assertFailure "a shared server was bound directly"
            twoPostgres <- either (assertFailure . T.unpack) pure (acceptedAppDatabaseBindings accepted native testCluster "personal" [known (mkAppDatabaseName "alpha-pg"), known (mkAppDatabaseName "beta-pg")])
            case compileWorker "alpha" (Just (Map.keys twoPostgres & map (known . mkAppDatabaseName . Dsl.databaseNameText))) twoPostgres of
              Left _ -> pure ()
              Right _ -> assertFailure "a workload bound two PostgreSQL databases"
        , testCase "the ClickHouse server enables SQL access management" $ do
            let (_, native) = chServer
            assertBool "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT is set" $
              any (T.isInfixOf "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT" . TE.decodeUtf8 . snd) (Map.elems native)
        ]
    , testCase "a ClickHouse login proves the password even before the default database exists" $ do
        clickHouseLoginVerdict ExitSuccess "" @?= Right True
        clickHouseLoginVerdict (ExitFailure 81) "Code: 81. DB::Exception: Database beta does not exist. (UNKNOWN_DATABASE)" @?= Right True
        clickHouseLoginVerdict (ExitFailure 4) "Code: 516. Authentication failed (AUTHENTICATION_FAILED)" @?= Right False
        assertBool "an unknown failure is not a verdict" (isLeft (clickHouseLoginVerdict (ExitFailure 210) "Connection refused"))
    , testGroup
        "credential template"
        [ testCase "a runtime Secret is filled with its own user, database and URL path" $ do
            let template = appDatabaseCredentialTemplate (alpha ClickHouse) RuntimeRole
            native <- either (fail . T.unpack) (pure . TE.decodeUtf8) (canonicalValue template)
            filled <- materializeCredential native >>= either (fail . T.unpack) pure
            value <- either fail pure (eitherDecodeStrict (TE.encodeUtf8 filled))
            fields <- case value of
              Object root | Just (Object entries) <- KM.lookup "data" root -> pure entries
              _ -> fail "filled Secret has no data"
            let decoded key = case KM.lookup key fields of
                  Just (String encoded) -> either (const "") id (b64decode encoded)
                  _ -> ""
            decoded "CLICKHOUSE_USER" @?= "alpha_ch_runtime"
            decoded "CLICKHOUSE_DB" @?= "alpha"
            T.length (decoded "CLICKHOUSE_PASSWORD") @?= 48
            assertBool "URL path selects the database" ("@smoke-ch.personal.svc.cluster.local:9000/alpha" `T.isSuffixOf` decoded "CLICKHOUSE_URL")
            credentialDataMatches template value @?= True
            credentialDataMatches template template @?= False
        ]
    ]
  where
    isLogical member = member ^. #executor == AppDatabaseExecutor
    refused db reason = assertLeftContaining reason (decodeAppDatabases (LBS.toStrict (encodeAppDatabases [db])))
    rawJson entry = TE.encodeUtf8 ("{\"kind\":\"AppDatabases\",\"appDatabases\":[" <> entry <> "]}")

-- Fixtures ------------------------------------------------------------------

kansokuPg :: AppDatabase
kansokuPg = AppDatabase (known (mkAppDatabaseName "kansoku-pg")) Nothing (dbServer "labs-postgres") Postgres personal (logical "kansoku" :| []) noAppDatabaseAccess

kansokuCh :: AppDatabase
kansokuCh = AppDatabase (known (mkAppDatabaseName "kansoku-ch")) Nothing (dbServer "labs-clickhouse") ClickHouse personal (logical "analytics" :| [logical "kansoku_migration_ledger"]) noAppDatabaseAccess

-- | Kansoku's declarations as IR-30 and IR-32 ask for them.
kansokuPgAccess :: AppDatabase
kansokuPgAccess =
  kansokuPg
    & #access
    . #monitoring
    .~ [PgMonitor]
    & #access
    . #runtime
    . #limits
    .~ (noUserLimits & #connectionLimit ?~ 20 & #statementTimeoutSeconds ?~ 30)

kansokuChAccess :: AppDatabase
kansokuChAccess =
  kansokuCh
    & #access
    . #runtime
    .~ UserAccess [SystemParts, SystemMutations, ArbitraryTemporaryTables] (noUserLimits & #maxMemoryBytes ?~ 268435456 & #maxExecutionSeconds ?~ 30 & #maxConcurrentQueries ?~ 8)
    & #access
    . #migration
    .~ UserAccess [SystemDisks, SystemStoragePolicies] (noUserLimits & #maxExecutionSeconds ?~ 3600)

alpha :: Engine -> AppDatabase
alpha Postgres = AppDatabase (known (mkAppDatabaseName "alpha-pg")) Nothing (dbServer "smoke-pg") Postgres personal (logical "alpha" :| []) noAppDatabaseAccess
alpha _ = AppDatabase (known (mkAppDatabaseName "alpha-ch")) Nothing (dbServer "smoke-ch") ClickHouse personal (logical "alpha" :| [logical "alpha_ledger"]) noAppDatabaseAccess

beta :: Engine -> AppDatabase
beta Postgres = AppDatabase (known (mkAppDatabaseName "beta-pg")) Nothing (dbServer "smoke-pg") Postgres personal (logical "beta" :| []) noAppDatabaseAccess
beta _ = AppDatabase (known (mkAppDatabaseName "beta-ch")) Nothing (dbServer "smoke-ch") ClickHouse personal (logical "beta" :| []) noAppDatabaseAccess

logical :: Text -> LogicalDatabaseName
logical = known . mkLogicalDatabaseName

dbServer :: Text -> Dsl.DatabaseName
dbServer = known . mkDatabaseName

personal :: Dsl.Namespace
personal = known (Dsl.mkNamespace "personal")

-- | An accepted server: its scope and private native members.
type Server = (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))

pgServer :: Server
pgServer = acceptedServer "smoke-pg" Postgres

chServer :: Server
chServer = acceptedServer "smoke-ch" ClickHouse

acceptedServer :: Text -> Engine -> Server
acceptedServer name engine =
  known
    ( compileStandaloneDatabase
        ( DatabaseDirectInput
            (Database (dbServer name) Nothing engine (defaultEngineVersion engine) personal (known (Dsl.mkQuantity "1Gi")) Nothing Dsl.Retain)
            (known (mkScopeId Standalone ("database-" <> name)))
            testCluster
            Nothing
            testRecovery
            (SourceLocation "test" "database")
        )
        (DatabaseBackupTarget (GcsBackend "project" "bucket") HourlyRecoveryPoint)
    )

serverStateful :: Server -> ManagedResource
serverStateful (scope, _) =
  case [member | bundle <- scopeBundles scope, Managed member <- declarations bundle, Kubernetes _ "apps" kind _ _ <- [member ^. #address], nameText kind == "statefulset"] of
    [member] -> member
    _ -> error "server fixture has no unique StatefulSet"

testCluster :: ResourceId
testCluster = mintResourceId (known (mkScopeId Platform "cluster")) (known (mkLogicalKey "cluster")) (known (mkName "cluster"))

testRecovery :: RecoveryIntent
testRecovery = RecoveryIntent (known (mkName "backup")) (mkSecretRef (known (mkName "db-password")) (known (mkName "v1")) :| [])

testBinding :: ContextBinding
testBinding = ContextBinding (known (mkContextId "test")) (known (mkName "project"))

snapshot :: [Server] -> ScopeSnapshot
snapshot servers = snapshotWith servers []

snapshotWith :: [Server] -> [ScopeDeclaration] -> ScopeSnapshot
snapshotWith servers others =
  known
    ( mkScopeSnapshot
        testBinding
        (Map.fromList [(scopeId scope, (known (mkScopeGeneration 1), scope)) | scope <- map fst servers <> others])
        Map.empty
    )

acceptedNative :: [Server] -> Map.Map ResourceId (ManagedResource, ByteString)
acceptedNative = Map.unions . map snd

compileAgainst :: ScopeSnapshot -> [Server] -> AppDatabase -> Either (NonEmpty InventoryError) (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compileAgainst accepted servers db =
  compileStandaloneAppDatabase accepted (acceptedNative servers) (DatabaseBackupTarget (GcsBackend "project" "bucket") HourlyRecoveryPoint) db testCluster Nothing testRecovery (SourceLocation "test" "app-database")

scopeAndNative :: Server -> AppDatabase -> (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
scopeAndNative s db = known (compileAgainst (snapshot [s]) [s] db)

scopeOf :: Server -> AppDatabase -> ScopeDeclaration
scopeOf s = fst . scopeAndNative s

-- | alpha-pg's accepted scope with one ingested scheduled run.
ingested :: IO (ScopeDeclaration, ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString), ScopeDeclaration, ManagedResource, ManagedResource)
ingested = do
  let (appScope, appNative) = scopeAndNative pgServer (alpha Postgres)
      (serverScope, serverNative) = pgServer
      native = Map.union appNative serverNative
  (receiptScope, _) <- either (assertFailure . show) pure (compileScheduledIngestScope (ingestRequest serverScope native appScope) appScope native)
  pure (appScope, serverScope, native, receiptScope, member (named "statefulset" "smoke-pg") serverScope, member (named "persistentvolumeclaim" "nagare-db-smoke-pg-data") serverScope)
  where
    member predicate scope = head [m | bundle <- scopeBundles scope, Managed m <- declarations bundle, predicate m]
    named kind name m = case m ^. #address of
      Kubernetes _ _ k _ n -> nameText k == kind && nameText n == name
      _ -> False

-- | One verified scheduled run of alpha-pg against the given server scope.
ingestRequest :: ScopeDeclaration -> Map.Map ResourceId (ManagedResource, ByteString) -> ScopeDeclaration -> ScheduledIngestRequest
ingestRequest server native appScope =
  ScheduledIngestRequest
    { ingestSourceKind = IngestAppDatabase "alpha-pg" "smoke-pg" server (uid "sts")
    , ingestNamespace = "personal"
    , ingestBackupId = run
    , ingestSourceRevision = ScopeRevision (known (mkScopeGeneration 1)) (contentDigest "appdb")
    , ingestPvcUid = uid "pvc"
    , ingestScheduleUid = uid "cron"
    , ingestSigningUid = uid "signing"
    , ingestEvidence =
        ScheduledReceiptEvidence
          { scheduledReceipt = ScheduledBackupReceipt (uid run) (scheduledObjectPrefix expectation <> run <> "." <> scheduledFormat expectation) (T.replicate 64 "0") (scheduledPolicyRevision expectation) Nothing
          , scheduledObjectVersion = "1"
          , scheduledReceiptVersion = "1"
          , scheduledObjectLength = 1
          , scheduledReceiptLength = 1
          , scheduledReceiptDigest = contentDigest (TE.encodeUtf8 run)
          }
    , ingestBackend = GcsBackend "project" "bucket"
    , ingestSource = SourceLocation "test" run
    , ingestAcceptedIncarnations = Map.fromList [(stateful ^. #identity, uid "sts"), (pvc ^. #identity, uid "pvc"), (cron ^. #identity, uid "cron"), (signing ^. #identity, uid "signing")]
    }
  where
    run = "11111111-1111-1111-1111-111111111111"
    uid = known . mkPhysicalIdentity
    members scope = [m | bundle <- scopeBundles scope, Managed m <- declarations bundle]
    pick scope kind name = head [m | m <- members scope, Kubernetes _ _ k _ n <- [m ^. #address], nameText k == kind, nameText n == name]
    stateful = pick (fst pgServer) "statefulset" "smoke-pg"
    pvc = pick (fst pgServer) "persistentvolumeclaim" "nagare-db-smoke-pg-data"
    cron = pick appScope "cronjob" "nagare-appdb-alpha-pg"
    signing = pick appScope "secret" "nagare-appdb-alpha-pg-signing"
    expectation = known (scheduledAppDatabaseReceiptExpectationFromCronJob (GcsBackend "project" "bucket") "personal" "alpha-pg" (uid "sts") (uid "pvc") (snd (native Map.! (cron ^. #identity))))

-- | A standalone worker bound to the named app databases.
compileWorker ::
  Text ->
  Maybe [AppDatabaseName] ->
  Map.Map Dsl.DatabaseName DatabaseBinding ->
  Either (NonEmpty InventoryError) (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compileWorker app names bindings =
  compileStandaloneWorkerWithDependencies
    (known (mkScopeId Standalone ("worker-" <> app <> "-probe")))
    worker
    rollout
    testCluster
    (mintResourceId (known (mkScopeId Platform "foundation")) (known (mkLogicalKey "foundation")) (known (mkName "namespace-personal")))
    (mintResourceId (known (mkScopeId Platform "foundation")) (known (mkLogicalKey "image")) (known (mkName "publication")))
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    bindings
    (SourceLocation "test" "worker")
  where
    worker = either error id (webWorker (app <> "-probe") "registry.example.com/probe") & #appDatabases .~ fromMaybe [] names
    rollout =
      RolloutEnv
        { appName = app <> "-probe"
        , qualifiedImage = known (Dsl.mkImageRef "registry.example.com/probe")
        , imageTag = "v1"
        , effectiveTag = "v1"
        , taggedAppImage = "registry.example.com/probe:v1"
        , appEnv = Map.empty
        , namespace = "personal"
        , baseDomain = "apps.example.com"
        , targetProfile = tnbProfile
        }

-- | Every @secretKeyRef.name@ in a native object.
-- | Every pod template's labels in a rendered object.
podTemplateLabels :: ByteString -> [KM.KeyMap Value]
podTemplateLabels bytes = either (const []) collect (eitherDecodeStrict bytes)
  where
    collect = \case
      Object fields ->
        [labels | Just (Object template) <- [KM.lookup "template" fields], Just (Object metadata) <- [KM.lookup "metadata" template], Just (Object labels) <- [KM.lookup "labels" metadata]]
          <> concatMap collect (KM.elems fields)
      Array items -> concatMap collect (V.toList items)
      _ -> []

-- | A server's Service selects nagare.dev/database; a Job pod carrying it
-- would receive the server's connections (EP-202 M7).
assertNoServerLabel :: ByteString -> Assertion
assertNoServerLabel bytes = do
  assertBool "the object has a pod template" (not (null (podTemplateLabels bytes)))
  assertBool "a Job pod carries the server's Service label" (all (not . KM.member "nagare.dev/database") (podTemplateLabels bytes))

secretKeyRefs :: ByteString -> [Text]
secretKeyRefs bytes = either (const []) collect (eitherDecodeStrict bytes)
  where
    collect = \case
      Object fields ->
        [name | Just (Object ref) <- [KM.lookup "secretKeyRef" fields], Just (String name) <- [KM.lookup "name" ref]]
          <> concatMap collect (KM.elems fields)
      Array items -> concatMap collect (V.toList items)
      _ -> []

-- | A workload scope whose member is ordered after the server StatefulSet,
-- as a direct database binding is.
boundWorkload :: ManagedResource -> ScopeDeclaration
boundWorkload stateful = boundTo (stateful ^. #identity)

boundTo :: ResourceId -> ScopeDeclaration
boundTo producer =
  known
    ( mkScopeDeclaration
        owner
        [ ResourceBundle
            [ Managed
                ManagedResource
                  { identity = mintResourceId owner (known (mkLogicalKey "consumer")) (known (mkName "config"))
                  , owner = owner
                  , executor = KubernetesExecutor
                  , address = Kubernetes testCluster "" (known (mkName "configmap")) (Just (known (mkName "personal"))) (known (mkName "consumer"))
                  , aliases = []
                  , spec = NativeObject (known (mkContentDigest (T.replicate 64 "0")))
                  , lifecycle = DeleteWhenUnreferenced
                  , dataPolicy = Stateless
                  , sensitivity = Private
                  , dependencies = [OrderedAfter producer]
                  , delegations = []
                  , source = SourceLocation "test" "consumer"
                  }
            ]
            []
            []
            []
            []
            []
        ]
    )
  where
    owner = known (mkScopeId Standalone "service-consumer")

assertComposeRefused :: Text -> Server -> [AppDatabase] -> Assertion
assertComposeRefused code s dbs =
  case composeInventory (snapshot [s]) (NE.fromList (map (ReplaceScope . scopeOf s) dbs)) of
    Left errors -> assertBool (show errors) (any ((== code) . (^. #code)) (NE.toList errors))
    Right _ -> assertFailure ("composition was accepted; expected " <> T.unpack code)

assertCompileRefused :: Text -> [Server] -> AppDatabase -> Assertion
assertCompileRefused code servers = assertCompileRefusedWith code (snapshot servers)

assertCompileRefusedWith :: Text -> ScopeSnapshot -> AppDatabase -> Assertion
assertCompileRefusedWith code accepted db =
  case compileAgainst accepted [pgServer, chServer] db of
    Left errors -> assertBool (show errors) (any ((== code) . (^. #code)) (NE.toList errors))
    Right _ -> assertFailure ("app database was compiled; expected " <> T.unpack code)

assertLeftContaining :: Text -> Either LoadError a -> Assertion
assertLeftContaining needle = \case
  Left err -> assertBool (show err) (needle `T.isInfixOf` T.pack (show err))
  Right _ -> assertFailure ("decode succeeded; expected an error mentioning " <> T.unpack needle)

isRight' :: Either a b -> Bool
isRight' = either (const False) (const True)

known :: (Show e) => Either e a -> a
known = either (error . show) id
