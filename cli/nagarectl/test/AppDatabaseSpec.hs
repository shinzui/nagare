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
  , snapshot
  , snapshotWith
  , scopeAndNative
  , kansokuPg
  , kansokuCh
  , kansokuPgAccess
  , kansokuChAccess
  , kansokuPgReader
  , compileWorker
  , secretKeyRefs
  , acceptedNative
  , testCluster
  , known
  , assertLeftContaining
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
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
import Nagare.Database.AppDatabase.Sql (renderScratchRestore)
import Nagare.Database.Secret (b64decode)
import Nagare.Dsl.AppDatabase
import Nagare.Dsl.Config (encodeAppDatabases, encodeWorker)
import Nagare.Dsl.Database (Database (Database), Engine (..), EngineVersion, defaultEngineVersion, mkDatabaseName, mkEngineVersion)
import Nagare.Dsl.Load (LoadError (..), decodeAppDatabases, decodeWorker)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (webWorker)
import Nagare.Inventory.Adapters.AppDatabaseRuntime (clickHouseLoginVerdict)
import Nagare.Inventory.Adapters.CredentialTemplate (credentialDataMatches, materializeCredential)
import Nagare.Inventory.AppDatabase
import Nagare.Inventory.AppDatabaseBackup (AppDatabaseBackupRequest (..), compileAppDatabaseOnDemandBackupScope, onDemandBackupJobName, validOnDemandBackupId)
import Nagare.Inventory.AppDatabaseRestore (AppDatabaseRestoreRequest (..), RestoreTarget (..), compileAppDatabaseRestoreScope)
import Nagare.Inventory.Application (DatabaseBinding, acceptedAppDatabaseBindings, acceptedAppDatabaseReaderBindings, acceptedDatabaseBindings, compileStandaloneWorkerWithDependencies)
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (HourlyRecoveryPoint))
import Nagare.Inventory.BackupReceipt (ScheduledBackupReceipt (..), ScheduledReceiptExpectation (..), scheduledAppDatabaseReceiptExpectationFromCronJob)
import Nagare.Inventory.DataService (compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (..), JournalEvent (..), OperationState (..), mkOperationId, mkTransactionId)
import Nagare.Inventory.Restore (manualRestoreTargetProof)
import Nagare.Inventory.ScheduleHistory (convergedReviews)
import Nagare.Inventory.ScheduledIngest (ScheduledIngestRequest (..), ScheduledIngestSource (..), compileScheduledIngestScope, compileScheduledIngestScopeWithHistory)
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
import Nagare.Resource.Wire (canonicalValue, decodeScope, encodeCanonicalScope)
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
        , testCase "readers, their objects and a workload's reader bindings round-trip; none emits no key (EP-206 M2)" $ do
            decodeAppDatabases (LBS.toStrict (encodeAppDatabases [kansokuPgReader, kansokuChReader])) @?= Right [kansokuPgReader, kansokuChReader]
            let retiredReader = kansokuPgReader & #access . #readers . traverse . #retired .~ True
            decodeAppDatabases (LBS.toStrict (encodeAppDatabases [retiredReader])) @?= Right [retiredReader]
            assertBool "an active reader emits no retired key" (not ("retired" `T.isInfixOf` TE.decodeUtf8 (LBS.toStrict (encodeAppDatabases [kansokuPgReader]))))
            assertBool "no reader emits no readers key" (not ("readers" `T.isInfixOf` TE.decodeUtf8 (LBS.toStrict (encodeAppDatabases [kansokuPgAccess, kansokuChAccess]))))
            let plain = either error id (webWorker "probe" "registry.example.com/probe")
                bound = plain & #appDatabaseReaders .~ [Dsl.AppDatabaseReaderRef (known (mkAppDatabaseName "kansoku-ch")) (known (Dsl.mkReaderName "dashboards"))]
            decodeWorker (LBS.toStrict (encodeWorker bound)) @?= Right bound
            assertBool "an unbound worker keeps its bytes" (not ("appDatabaseReaders" `T.isInfixOf` TE.decodeUtf8 (LBS.toStrict (encodeWorker plain))))
            appDatabaseUser (known (mkAppDatabaseName "kansoku-ch")) (ReaderRole (known (Dsl.mkReaderName "dashboards"))) @?= "kansoku_ch_reader_dashboards"
            appDatabaseSecretName (known (mkAppDatabaseName "kansoku-ch")) (ReaderRole (known (Dsl.mkReaderName "dashboards"))) @?= "kansoku-ch-reader-dashboards"
            parseAppDatabaseRole "reader-dashboards" @?= Just (ReaderRole (known (Dsl.mkReaderName "dashboards")))
            mapM_ (\token -> parseAppDatabaseRole token @?= Nothing) ["reader-", "reader-runtime", "reader-Bad", "reader-a-b", "admin"]
        , testCase "a reader outside the app's databases, the engine's objects or its required ceilings refuses before planning (IR-33 AC-1)" $ do
            let onReader f db = db & #access . #readers . traverse %~ f
                otherDb = ReaderRelation (logical "elsewhere") Nothing (known (mkRelationName "v"))
                schemaView = ReaderSchemaViews (logical "analytics") (known (mkSchemaName "reporting"))
            refused (kansokuChReader & onReader (#objects .~ (otherDb :| []))) "outside the app's own databases"
            refused (kansokuChReader & onReader (#objects .~ (schemaView :| []))) "without a schema"
            refused (kansokuChReader & onReader (#limits . #maxThreads .~ Nothing)) "missing maxThreads"
            refused (kansokuChReader & onReader (#limits . #maxResultRows ?~ 0)) "must be positive"
            refused (kansokuPgReader & onReader (#limits . #connectionLimit .~ Nothing)) "sets a connection limit"
            refused (kansokuPgReader & onReader (#objects %~ \(o :| _) -> o :| [o])) "repeats an object"
            refused (kansokuPgReader & #access . #readers %~ \rs -> rs <> rs) "repeats a reader"
            mapM_ (\name -> isRight' (Dsl.mkReaderName name) @?= False) ["runtime", "migration", "has-hyphen", "Upper", "", T.replicate 17 "a"]
        ]
    , testGroup
        "scope"
        [ testCase "v0.7.1 app-database scope records decode, re-encode byte-identically and equal an unchanged compile (EP-204)" $
            forM_ [("appdb-alpha-pg", scopeOf pgServer (alpha Postgres)), ("appdb-alpha-ch", scopeOf chServer (alpha ClickHouse))] $ \(file, compiled) -> do
              bytes <- BS.readFile ("test/fixtures/app-database/v0.7.1/" <> file <> ".json")
              decoded <- either (assertFailure . show) pure (decodeScope bytes)
              assertBool (file <> " re-encodes byte-identically") (encodeCanonicalScope decoded == bytes)
              assertBool (file <> " compiles unchanged") (encodeCanonicalScope compiled == bytes)
        , testCase "v0.7.1 app-database scopes accepted on a native context decode and re-encode byte-identically (EP-204)" $
            -- From the review the v0.7.1 smoke applied on the local context transition;
            -- each file is named by its content digest there.
            forM_ ["native-appdb-alpha-pg", "native-appdb-alpha-ch"] $ \file -> do
              bytes <- BS.readFile ("test/fixtures/app-database/v0.7.1/" <> file <> ".json")
              decoded <- either (assertFailure . show) pure (decodeScope bytes)
              assertBool (file <> " re-encodes byte-identically") (encodeCanonicalScope decoded == bytes)
        , testCase "declared access rides in the specs and round-trips through the wire (EP-204)" $ do
            let scope = scopeOf chServer (alpha ClickHouse & #access . #runtime . #exceptions .~ [SystemParts])
                pgScope = scopeOf pgServer (alpha Postgres & #access . #monitoring .~ [PgMonitor])
                specsOf s' = [member ^. #spec | bundle <- scopeBundles s', Managed member <- declarations bundle, member ^. #executor == AppDatabaseExecutor]
            forM_ [scope, pgScope] $ \s' -> (encodeCanonicalScope <$> decodeScope (encodeCanonicalScope s')) @?= Right (encodeCanonicalScope s')
            assertBool "the runtime extension is on the wire" ("system-parts" `T.isInfixOf` TE.decodeUtf8 (encodeCanonicalScope scope))
            [access | DatabaseUserSpec _ "runtime" _ _ access <- specsOf scope] @?= [noUserExtension & #access . #exceptions .~ [SystemParts]]
            [monitoring | LogicalDatabase _ _ _ _ _ monitoring _ <- specsOf pgScope] @?= [[PgMonitor]]
            assertBool "the extension changes the user's digest" ([d | DatabaseUserSpec _ "runtime" _ d _ <- specsOf scope] /= [d | DatabaseUserSpec _ "runtime" _ d _ <- specsOf (scopeOf chServer (alpha ClickHouse))])
        , testCase "declared access keeps the backup schedule's revision (EP-204)" $
            forM_ [(chServer, alpha ClickHouse & #access . #runtime . #exceptions .~ [SystemParts]), (pgServer, alpha Postgres & #access . #monitoring .~ [PgMonitor])] $ \(server', declared) -> do
              let cronOf db = [bytes | (member, bytes) <- Map.elems (snd (scopeAndNative server' db)), Kubernetes _ "batch" kind _ _ <- [member ^. #address], nameText kind == "cronjob"]
              cronOf declared @?= cronOf (declared & #access .~ noAppDatabaseAccess)
        , testCase "quiesce closes the chosen logins, pauses the schedule and declares a drain; resume gives the accepted bytes back (EP-205)" $
            forM_ [(pgServer, alpha Postgres), (chServer, alpha ClickHouse)] $ \(server', db) -> do
              let (scope, native) = scopeAndNative server' db
                  cronOf s' = head [m | bundle <- scopeBundles s', Managed m <- declarations bundle, Kubernetes _ "batch" kind _ _ <- [m ^. #address], nameText kind == "cronjob"]
                  logins s' = [(role, login) | DatabaseUserSpec _ role login _ _ <- specs' s']
                  specs' s' = [m ^. #spec | bundle <- scopeBundles s', Managed m <- declarations bundle]
                  kinds s' = [(op ^. #operationKind, last (T.splitOn "/" (resourceIdText (op ^. #identity)))) | bundle <- scopeBundles s', op <- bundle ^. #operations]
              (quiesced, paused) <- either (assertFailure . show) pure (quiesceAppDatabaseScope native scope ["runtime"] "t1")
              logins quiesced @?= [("runtime", LoginQuiesced), ("migration", LoginOpen)]
              kinds quiesced @?= [(DrainSessions, "drain")]
              [bytes | (_, bytes) <- Map.elems paused] `forM_` \bytes -> assertBool "the schedule is suspended" (scheduleSuspended bytes)
              -- The logical databases' specs are untouched: on ClickHouse their
              -- grants are withheld from the quiesced users, derived from the users.
              [spec | spec@LogicalDatabase {} <- specs' quiesced] @?= [spec | spec@LogicalDatabase {} <- specs' scope]
              let afterQuiesce = Map.union paused native
              (resumed, unpaused) <- either (assertFailure . show) pure (resumeAppDatabaseScope afterQuiesce quiesced "t2")
              logins resumed @?= [("runtime", LoginOpen), ("migration", LoginOpen)]
              kinds resumed @?= [(ResumeSessions, "resume"), (DrainSessions, "drain")]
              map snd (Map.elems unpaused) @?= [snd (native Map.! (cronOf scope ^. #identity))]
              cronOf resumed ^. #spec @?= cronOf scope ^. #spec
        , testCase "quiesce refuses a quiesced or retired app database and a user set without the runtime user; rotation refuses while quiesced (EP-205)" $ do
            let (scope, native) = scopeAndNative pgServer (alpha Postgres)
                code = either (map (^. #code) . NE.toList) (const [])
            (quiesced, paused) <- either (assertFailure . show) pure (quiesceAppDatabaseScope native scope ["runtime", "migration"] "t1")
            code (quiesceAppDatabaseScope (Map.union paused native) quiesced ["runtime"] "t2") @?= ["app-database-quiesced"]
            code (quiesceAppDatabaseScope native scope ["migration"] "t1") @?= ["invalid-app-database-quiesce"]
            code (rotateAppDatabaseScope quiesced "runtime" "t3") @?= ["app-database-quiesced"]
            code (resumeAppDatabaseScope native scope "t1") @?= ["invalid-app-database-resume"]
            (retired, retiredNative) <- either (assertFailure . show) pure (retireAppDatabaseScope (snapshotWith [pgServer] [scope]) native scope)
            code (quiesceAppDatabaseScope (Map.union retiredNative native) retired ["runtime"] "t1") @?= ["invalid-app-database-quiesce"]
            [row ^. #quiesced | row <- appDatabaseRows (snapshotWith [pgServer] [quiesced])] @?= [True]
            -- The quiesced login is the third state on the wire; v0.7 wrote a Bool.
            assertBool "quiesced on the wire" ("\"quiesced\"" `T.isInfixOf` TE.decodeUtf8 (encodeCanonicalScope quiesced))
            (encodeCanonicalScope <$> decodeScope (encodeCanonicalScope quiesced)) @?= Right (encodeCanonicalScope quiesced)
        , testCase "alpha and beta share one server per engine (AC-1)" $ do
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
        , testCase "a scratch restore extends no reader to the scratch databases (IR-33 AC-8)" $ do
            let reader = AppDatabaseReader (known (Dsl.mkReaderName "dash")) (ReaderRelation (logical "alpha") Nothing (known (mkRelationName "v1")) :| []) (defaultReaderLimits Postgres) [known (Dsl.mkServiceName "gamma")] False
            (appScope, serverScope, native, receiptScope, _, _) <- ingestedWith (alpha Postgres & #access . #readers .~ [reader])
            let request = AppDatabaseRestoreRequest "alpha-pg" "personal" "r1" appScope serverScope receiptScope (known (mkPhysicalIdentity "sts")) (known (mkPhysicalIdentity "pvc")) (GcsBackend "project" "bucket") (SourceLocation "test" "restore") ScratchTarget (ScopeRevision (known (mkScopeGeneration 2)) (contentDigest "server"))
            (_, restoreNative) <- either (assertFailure . show) pure (compileAppDatabaseRestoreScope request native)
            [bytes] <- pure (map snd (Map.elems restoreNative))
            let text = TE.decodeUtf8 bytes
            -- PUBLIC loses CONNECT on the scratch database and only the runtime user gets it, so
            -- the reader cannot connect to it whatever ACLs the dump restores inside.
            assertBool "revokes PUBLIC on the scratch database" ("REVOKE ALL ON DATABASE \\\"alpha_restore_r1\\\" FROM PUBLIC" `T.isInfixOf` text)
            assertBool "grants nothing to the reader" (not ("reader" `T.isInfixOf` text))
            assertBool "the ClickHouse scratch restore grants nothing to a reader" (not ("reader" `T.isInfixOf` renderScratchRestore ClickHouse noDatabasePrivileges [("alpha", "alpha_restore_r1")] "a.zip" "alpha_ch_migration" "alpha_ch_runtime"))
        , testCase "a run signed under an earlier converged schedule revision ingests and restores its own databases (EP-207)" $ do
            let cronOf native' = head [bytes | (m, bytes) <- Map.elems native', Kubernetes _ "batch" k _ _ <- [m ^. #address], nameText k == "cronjob"]
                changes =
                  [ -- The server's image moved, so the schedule's client did.
                    (Postgres, pgServer, acceptedServerAt "smoke-pg" Postgres (known (mkEngineVersion Postgres "17")), alpha Postgres, alpha Postgres)
                  , -- A logical database was added after the run.
                    (ClickHouse, chServer, chServer, alpha ClickHouse & #logicalDatabases .~ (logical "alpha" :| []), alpha ClickHouse)
                  ]
            forM_ changes $ \(engine', oldServer, newServer, earlier, later) -> do
              let (oldScope, oldNative) = scopeAndNative oldServer earlier
                  (newScope, newNative) = scopeAndNative newServer later
                  native = Map.unions [newNative, snd newServer]
                  request = ingestRequestFor engine' (fst newServer) oldNative oldScope
                  appName = if engine' == Postgres then "alpha-pg" else "alpha-ch"
                  digestOf native' = digestText (scheduledMetadataDigest (known (scheduledAppDatabaseReceiptExpectationFromCronJob (GcsBackend "project" "bucket") "personal" appName (known (mkPhysicalIdentity "sts")) (known (mkPhysicalIdentity "pvc")) (cronOf native'))))
                  -- The ingest Job re-verifies the receipt against this digest in the cluster.
                  jobMetadata compiled = case compiled of
                    Right (_, jobNative) ->
                      [ value
                      | (_, bytes) <- Map.elems jobNative
                      , Right decoded <- [eitherDecodeStrict bytes :: Either String Value]
                      , Just (Array containers) <- [path ["spec", "template", "spec", "containers"] decoded]
                      , container <- V.toList containers
                      , Just (Array env) <- [path ["env"] container]
                      , entry <- V.toList env
                      , path ["name"] entry == Just (String "METADATA_SHA256")
                      , Just (String value) <- [path ["value"] entry]
                      ]
                    Left _ -> []
                  path keys value = foldl (\v k -> case v of Just (Object o) -> KM.lookup k o; _ -> Nothing) (Just value) keys
              assertBool "the schedule changed" (cronOf oldNative /= cronOf newNative)
              -- Without its history the run is checked against the current revision, which it fails.
              jobMetadata (compileScheduledIngestScope request newScope native) @?= [digestOf newNative]
              -- A revision that never converged authorizes nothing.
              let (_, betaNative) = scopeAndNative newServer (beta engine')
              jobMetadata (compileScheduledIngestScopeWithHistory [cronOf betaNative] request newScope native) @?= [digestOf newNative]
              jobMetadata (compileScheduledIngestScopeWithHistory [cronOf oldNative] request newScope native) @?= [digestOf oldNative]
              (receiptScope, _) <- either (assertFailure . show) pure (compileScheduledIngestScopeWithHistory [cronOf oldNative] request newScope native)
              Map.lookup "scheduled.backup.databases" (scopeOverrides receiptScope) @?= Just "alpha"
              let restoreRequest = AppDatabaseRestoreRequest (if engine' == Postgres then "alpha-pg" else "alpha-ch") "personal" "r1" newScope (fst newServer) receiptScope (known (mkPhysicalIdentity "sts")) (known (mkPhysicalIdentity "pvc")) (GcsBackend "project" "bucket") (SourceLocation "test" "restore") ScratchTarget (ScopeRevision (known (mkScopeGeneration 2)) (contentDigest "server"))
              (restoreScope, _) <- either (assertFailure . show) pure (compileAppDatabaseRestoreScope restoreRequest native)
              -- Only the databases the run holds are restored.
              Map.lookup "restore.target.databases" (scopeOverrides restoreScope) @?= Just "alpha_restore_r1"
              -- A run naming a database the app no longer declares is refused.
              let foreign' = withScopeOverrides (Map.insert "scheduled.backup.databases" "alpha,gone" (scopeOverrides receiptScope)) receiptScope
              assertBool "a run naming an undeclared database is refused" (isLeft (compileAppDatabaseRestoreScope (restoreRequest & #receiptScope .~ foreign') native))
        , testCase "only a converged transaction's review authorizes a schedule revision (EP-207)" $ do
            let tx name = known (mkTransactionId ("tx-" <> name))
                event n transaction operation state = JournalEvent 1 n Nothing (tx transaction) operation state "t" "" Nothing
                operation' = Just (known (mkOperationId "op-1"))
                events =
                  [ event 1 "a" Nothing Pending
                  , event 2 "a" operation' (Completed (contentDigest "a-op"))
                  , event 3 "a" Nothing (Completed (contentDigest "review-a"))
                  , event 4 "b" Nothing Pending
                  , event 5 "b" operation' (Failed (KnownNoEffect "refused"))
                  , event 6 "c" Nothing Pending
                  , event 7 "d" Nothing (OperatorResolved "abandoned")
                  , event 8 "e" Nothing (Completed (contentDigest "review-e"))
                  , event 9 "e" Nothing (Completed (contentDigest "review-e"))
                  ]
            convergedReviews events @?= [contentDigest "review-a", contentDigest "review-e"]
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
            [on | LogicalDatabase _ _ _ on _ _ _ <- specs retired] @?= [False]
            [login | DatabaseUserSpec _ _ login _ _ <- specs retired] @?= [LoginClosed, LoginClosed]
            let runtime = head [member ^. #identity | bundle <- scopeBundles scope, Managed member <- declarations bundle, DatabaseUserSpec _ "runtime" _ _ _ <- [member ^. #spec]]
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
              bindings <- either (assertFailure . T.unpack) pure (acceptedAppDatabaseBindings accepted native testCluster "personal" (known (Dsl.mkServiceName app)) names)
              (scope, workerNative) <- either (assertFailure . show) pure (compileWorker app (Just names) bindings)
              let refs = nub (sort (concatMap (secretKeyRefs . snd) (Map.elems workerNative)))
              refs @?= [app <> "-ch-runtime", app <> "-pg-runtime"]
              let users = [member ^. #identity | (s', _) <- compiled, ("appdb-" <> app) `T.isPrefixOf` nameText (scopeName (scopeId s')), bundle <- scopeBundles s', Managed member <- declarations bundle, member ^. #executor == AppDatabaseExecutor]
                  workloadDependencies = concat [member ^. #dependencies | bundle <- scopeBundles scope, Managed member <- declarations bundle]
              assertBool "the workload is ordered after its app databases" (all (\user -> OrderedAfter user `elem` workloadDependencies) users)
            case acceptedDatabaseBindings accepted native testCluster "personal" [dbServer "smoke-pg"] of
              Left reason -> assertBool (T.unpack reason) ("shared-server-direct-binding" `T.isPrefixOf` reason)
              Right _ -> assertFailure "a shared server was bound directly"
            twoPostgres <- either (assertFailure . T.unpack) pure (acceptedAppDatabaseBindings accepted native testCluster "personal" (known (Dsl.mkServiceName "alpha")) [known (mkAppDatabaseName "alpha-pg"), known (mkAppDatabaseName "beta-pg")])
            case compileWorker "alpha" (Just (Map.keys twoPostgres & map (known . mkAppDatabaseName . Dsl.databaseNameText))) twoPostgres of
              Left _ -> pure ()
              Right _ -> assertFailure "a workload bound two PostgreSQL databases"
        , testCase "a reader binds its own Secret for a declared consumer only, after its user and databases, until it is retired (IR-33 AC-6, AC-7)" $
            forM_ [(pgServer, alpha Postgres, "pg"), (chServer, alpha ClickHouse, "ch")] $ \(server', db, short) -> do
              let dash retired' =
                    AppDatabaseReader
                      (known (Dsl.mkReaderName "dash"))
                      (ReaderRelation (known (mkLogicalDatabaseName "alpha")) Nothing (known (mkRelationName "v1")) :| [])
                      (defaultReaderLimits (db ^. #engine))
                      [known (Dsl.mkServiceName "gamma-probe")]
                      retired'
                  ref = Dsl.AppDatabaseReaderRef (db ^. #name) (known (Dsl.mkReaderName "dash"))
                  bindingsFor retired' consumer =
                    let (compiled, native') = scopeAndNative server' (db & #access . #readers .~ [dash retired'])
                     in ( compiled
                        , acceptedAppDatabaseReaderBindings (snapshotWith [server'] [compiled]) (Map.union (acceptedNative [server']) native') testCluster "personal" (known (Dsl.mkServiceName consumer)) [ref]
                        )
                  secretName = "alpha-" <> short <> "-reader-dash"
                  (scope, accepted) = bindingsFor False "gamma-probe"
              bindings <- either (assertFailure . T.unpack) pure accepted
              Map.keys bindings @?= [known (Dsl.mkDatabaseName secretName)]
              (workerScope, workerNative) <- either (assertFailure . show) pure (compileWorkerWith "gamma" Nothing [ref] bindings)
              nub (sort (concatMap (secretKeyRefs . snd) (Map.elems workerNative))) @?= [secretName]
              let members = [m | bundle <- scopeBundles scope, Managed m <- declarations bundle]
                  dependencies = concat [m ^. #dependencies | bundle <- scopeBundles workerScope, Managed m <- declarations bundle]
                  readerMembers = [m ^. #identity | m <- members, DatabaseUserSpec _ "reader-dash" _ _ _ <- [m ^. #spec]] <> [m ^. #identity | m <- members, Kubernetes _ "" _ _ n <- [m ^. #address], nameText n == secretName]
                  runtimeUser = [m ^. #identity | m <- members, DatabaseUserSpec _ "runtime" _ _ _ <- [m ^. #spec]]
              assertBool "ordered after the reader's user and credential" (all (\r -> OrderedAfter r `elem` dependencies) readerMembers && length readerMembers == 2)
              assertBool "not ordered after the runtime user" (not (any (\r -> OrderedAfter r `elem` dependencies) runtimeUser))
              case snd (bindingsFor False "delta-probe") of
                Left reason -> assertBool (T.unpack reason) ("app-database-reader-not-a-consumer" `T.isPrefixOf` reason)
                Right _ -> assertFailure "a workload that is not a declared consumer bound the reader"
              case snd (bindingsFor True "gamma-probe") of
                Left reason -> assertBool (T.unpack reason) ("app-database-reader-retired" `T.isPrefixOf` reason)
                Right _ -> assertFailure "a retired reader was bound"
              -- A runtime binder of the same app database is not one of its binders.
              runtimeBindings <- either (assertFailure . T.unpack) pure (acceptedAppDatabaseBindings (snapshotWith [server'] [scope]) (Map.union (acceptedNative [server']) (snd (scopeAndNative server' (db & #access . #readers .~ [dash False])))) testCluster "personal" (known (Dsl.mkServiceName "alpha")) [db ^. #name])
              (runtimeWorker, _) <- either (assertFailure . show) pure (compileWorker "alpha" (Just [db ^. #name]) runtimeBindings)
              let runtimeDependencies = concat [m ^. #dependencies | bundle <- scopeBundles runtimeWorker, Managed m <- declarations bundle]
              assertBool "a runtime binder is not ordered after the reader" (not (any (\r -> OrderedAfter r `elem` runtimeDependencies) readerMembers))
              either (assertFailure . show) (const (pure ())) (compileAgainst (snapshotWith [server'] [scope, runtimeWorker]) [server'] (db & #access . #readers .~ [dash True]))
              -- Declaring it retired while a workload binds it is refused (EP-206).
              case compileAgainst (snapshotWith [server'] [scope, workerScope]) [server'] (db & #access . #readers .~ [dash True]) of
                Left errs -> assertBool (show errs) (any ((== "app-database-reader-in-use") . (^. #code)) (NE.toList errs))
                Right _ -> assertFailure "a bound reader was retired"
        , testCase "an app database's own on-demand backup is not a binding: it reads no reader's Secret and blocks no retirement (EP-205, EP-206)" $
            forM_ [(pgServer, alpha Postgres), (chServer, alpha ClickHouse)] $ \(server', base) -> do
              let dash retired' = AppDatabaseReader (known (Dsl.mkReaderName "dash")) (ReaderRelation (logical "alpha") Nothing (known (mkRelationName "v1")) :| []) (defaultReaderLimits (base ^. #engine)) [known (Dsl.mkServiceName "gamma")] retired'
                  (scope, native) = scopeAndNative server' (base & #access . #readers .~ [dash False])
                  uid = known . mkPhysicalIdentity
                  serverMembers = [m | bundle <- scopeBundles (fst server'), Managed m <- declarations bundle]
                  pick kind = head [m ^. #identity | m <- serverMembers, Kubernetes _ _ k _ _ <- [m ^. #address], nameText k == kind]
                  (statefulId, pvcId) = (pick "statefulset", pick "persistentvolumeclaim")
                  pins = Map.fromList [(statefulId, uid "sts"), (pvcId, uid "pvc")]
                  request = AppDatabaseBackupRequest scope "personal" (appDatabaseNameText (base ^. #name)) "r1" statefulId pvcId (uid "sts") (uid "pvc") pins (SourceLocation "test" "backup")
              (backupScope, _) <- either (assertFailure . show) pure (compileAppDatabaseOnDemandBackupScope request native)
              let jobDependencies = concat [m ^. #dependencies | bundle <- scopeBundles backupScope, Managed m <- declarations bundle]
                  readerSecrets = [m ^. #identity | bundle <- scopeBundles scope, Managed m <- declarations bundle, Kubernetes _ "" _ _ n <- [m ^. #address], "-reader-dash" `T.isSuffixOf` nameText n]
              length readerSecrets @?= 1
              assertBool "the Job is not ordered after the reader's Secret" (all (\r -> OrderedAfter r `notElem` jobDependencies) readerSecrets)
              let accepted = snapshotWith [server'] [scope, backupScope]
              either (assertFailure . show) (const (pure ())) (retireAppDatabaseScope accepted (Map.union (acceptedNative [server']) native) scope)
              either (assertFailure . show) (const (pure ())) (compileAgainst accepted [server'] (base & #access . #readers .~ [dash True]))
        , testCase "an on-demand backup is the schedule's own Job, ingests like a scheduled run, and needs the migration user (IR-31 AC-5)" $
            forM_ [(pgServer, alpha Postgres), (chServer, alpha ClickHouse)] $ \(server', db) -> do
              let (scope, native) = scopeAndNative server' db
                  uid = known . mkPhysicalIdentity
                  serverMembers = [m | bundle <- scopeBundles (fst server'), Managed m <- declarations bundle]
                  pick kind = head [m ^. #identity | m <- serverMembers, Kubernetes _ _ k _ _ <- [m ^. #address], nameText k == kind]
                  (statefulId, pvcId) = (pick "statefulset", pick "persistentvolumeclaim")
                  pins = Map.fromList [(statefulId, uid "sts"), (pvcId, uid "pvc")]
                  request scope' backup = AppDatabaseBackupRequest scope' "personal" (appDatabaseNameText (db ^. #name)) backup statefulId pvcId (uid "sts") (uid "pvc") pins (SourceLocation "test" "backup")
                  cronBytes native' = head [bytes | (m, bytes) <- Map.elems native', Kubernetes _ "batch" k _ _ <- [m ^. #address], nameText k == "cronjob"]
                  field path bytes = foldl (\v k -> case v of Just (Object o) -> KM.lookup k o; _ -> Nothing) (either (const Nothing) Just (eitherDecodeStrict bytes)) path
              (backupScope, jobNative) <- either (assertFailure . show) pure (compileAppDatabaseOnDemandBackupScope (request scope "r1") native)
              [jobBytes] <- pure (map snd (Map.elems jobNative))
              field ["spec"] jobBytes @?= field ["spec", "jobTemplate", "spec"] (cronBytes native)
              field ["metadata", "name"] jobBytes @?= Just (String ("nagare-appdb-" <> appDatabaseNameText (db ^. #name) <> "-r1"))
              nameText (scopeName (scopeId backupScope)) @?= "appdb-backup-personal-" <> appDatabaseNameText (db ^. #name) <> "-r1"
              -- Never read as a direct database's manual backup.
              Map.keys (Map.filterWithKey (\k _ -> "backup." `T.isPrefixOf` k) (scopeOverrides backupScope)) @?= []
              -- A suspended schedule signs and is expected exactly as before.
              (quiesced, paused) <- either (assertFailure . show) pure (quiesceAppDatabaseScope native scope ["runtime"] "t1")
              let expectation bytes = scheduledAppDatabaseReceiptExpectationFromCronJob (GcsBackend "project" "bucket") "personal" (appDatabaseNameText (db ^. #name)) (uid "sts") (uid "pvc") bytes
              expectation (cronBytes paused) @?= expectation (cronBytes native)
              (_, quiescedJob) <- either (assertFailure . show) pure (compileAppDatabaseOnDemandBackupScope (request quiesced "r2") (Map.union paused native))
              map (field ["spec"] . snd) (Map.elems quiescedJob) @?= [field ["spec"] jobBytes]
              (both, bothPaused) <- either (assertFailure . show) pure (quiesceAppDatabaseScope native scope ["runtime", "migration"] "t1")
              either (map (^. #code) . NE.toList) (const []) (compileAppDatabaseOnDemandBackupScope (request both "r3") (Map.union bothPaused native)) @?= ["app-database-quiesced"]
              either (map (^. #code) . NE.toList) (const []) (compileAppDatabaseOnDemandBackupScope (request scope "R1") native) @?= ["invalid-app-database-backup"]
              either (map (^. #code) . NE.toList) (const []) (compileAppDatabaseOnDemandBackupScope (request scope "r1" & #statefulUid .~ uid "other") native) @?= ["invalid-app-database-backup"]
        , testCase "the longest app database and backup ID name a Job within the job-name label (EP-205)" $ do
            let longest = T.replicate 36 "a"
            assertBool "within the 63-character job-name label" (T.length (onDemandBackupJobName ("nagare-appdb-" <> longest) (T.replicate 12 "9")) <= 63)
            assertBool "an ID longer than 12 is refused" (not (validOnDemandBackupId (T.replicate 13 "9")))
        , testCase "a quiesced app database still binds; a retired one does not (EP-205)" $ do
            let (scope, native) = scopeAndNative pgServer (alpha Postgres)
                names = [known (mkAppDatabaseName "alpha-pg")]
                bindIn s' extra = acceptedAppDatabaseBindings (snapshotWith [pgServer] [s']) (Map.unions [acceptedNative [pgServer], extra, native]) testCluster "personal" (known (Dsl.mkServiceName "alpha")) names
            (quiesced, paused) <- either (assertFailure . show) pure (quiesceAppDatabaseScope native scope ["runtime"] "t1")
            either (assertFailure . T.unpack) (const (pure ())) (bindIn quiesced paused)
            (retired, retiredNative) <- either (assertFailure . show) pure (retireAppDatabaseScope (snapshotWith [pgServer] [scope]) native scope)
            case bindIn retired retiredNative of
              Left reason -> assertBool (T.unpack reason) ("retired" `T.isInfixOf` reason)
              Right _ -> assertFailure "a retired app database was bound"
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

-- | Kansoku's dashboards reader on each engine (EP-206).
kansokuChReader, kansokuPgReader :: AppDatabase
kansokuChReader =
  kansokuCh
    & #access
    . #readers
    .~ [AppDatabaseReader (known (Dsl.mkReaderName "dashboards")) (ReaderRelation (logical "analytics") Nothing (known (mkRelationName "events_by_day")) :| [ReaderRelation (logical "analytics") Nothing (known (mkRelationName "sessions_view"))]) (defaultReaderLimits ClickHouse) [known (Dsl.mkServiceName "grafana")] False]
kansokuPgReader =
  kansokuPg
    & #access
    . #readers
    .~ [AppDatabaseReader (known (Dsl.mkReaderName "grafana")) (ReaderSchemaViews (logical "kansoku") (known (mkSchemaName "reporting")) :| [ReaderRelation (logical "kansoku") Nothing (known (mkRelationName "daily_totals"))]) (defaultReaderLimits Postgres) [known (Dsl.mkServiceName "grafana")] False]

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
acceptedServer name engine = acceptedServerAt name engine (defaultEngineVersion engine)

-- | A server on the given engine version, whose image its app databases'
-- schedules use as their client.
acceptedServerAt :: Text -> Engine -> EngineVersion -> Server
acceptedServerAt name engine version =
  known
    ( compileStandaloneDatabase
        ( DatabaseDirectInput
            (Database (dbServer name) Nothing engine version personal (known (Dsl.mkQuantity "1Gi")) Nothing Dsl.Retain)
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
ingested = ingestedWith (alpha Postgres)

ingestedWith :: AppDatabase -> IO (ScopeDeclaration, ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString), ScopeDeclaration, ManagedResource, ManagedResource)
ingestedWith db = do
  let (appScope, appNative) = scopeAndNative pgServer db
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
ingestRequest = ingestRequestFor Postgres

-- | alpha's run on its engine's server, its evidence signed under the
-- schedule in @native@.
ingestRequestFor :: Engine -> ScopeDeclaration -> Map.Map ResourceId (ManagedResource, ByteString) -> ScopeDeclaration -> ScheduledIngestRequest
ingestRequestFor engine' server native appScope =
  ScheduledIngestRequest
    { ingestSourceKind = IngestAppDatabase appName serverName server (uid "sts")
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
    (appName, serverName) = if engine' == Postgres then ("alpha-pg", "smoke-pg") else ("alpha-ch", "smoke-ch")
    -- The pins are the engine's own server's, whatever server the request names.
    ownServer = fst (if engine' == Postgres then pgServer else chServer)
    stateful = pick ownServer "statefulset" serverName
    pvc = pick ownServer "persistentvolumeclaim" ("nagare-db-" <> serverName <> "-data")
    cron = pick appScope "cronjob" ("nagare-appdb-" <> appName)
    signing = pick appScope "secret" ("nagare-appdb-" <> appName <> "-signing")
    expectation = known (scheduledAppDatabaseReceiptExpectationFromCronJob (GcsBackend "project" "bucket") "personal" appName (uid "sts") (uid "pvc") (snd (native Map.! (cron ^. #identity))))

-- | A standalone worker bound to the named app databases.
compileWorker ::
  Text ->
  Maybe [AppDatabaseName] ->
  Map.Map Dsl.DatabaseName DatabaseBinding ->
  Either (NonEmpty InventoryError) (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compileWorker app names = compileWorkerWith app names []

-- | A probe worker binding app databases and readers (EP-206).
compileWorkerWith ::
  Text ->
  Maybe [AppDatabaseName] ->
  [Dsl.AppDatabaseReaderRef] ->
  Map.Map Dsl.DatabaseName DatabaseBinding ->
  Either (NonEmpty InventoryError) (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
compileWorkerWith app names readers bindings =
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
    worker = either error id (webWorker (app <> "-probe") "registry.example.com/probe") & #appDatabases .~ fromMaybe [] names & #appDatabaseReaders .~ readers
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
