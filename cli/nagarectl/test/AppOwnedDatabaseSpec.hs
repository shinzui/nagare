-- | EP-257: an app-owned app database. Its rendered statements and its
-- observation are the ones PostgreSQL 18 ran in
-- @test/fixtures/app-database/app-owned.sql@; its members converge, the app's
-- own SQL inside its database is never drift, and each reach beyond it is;
-- planning refuses what ownership cannot become.
module AppOwnedDatabaseSpec
  ( appOwnedDatabaseTests
  )
where

import AppDatabaseSpec (acceptedServerAt, alpha, beta, compileAgainst, ingestedWith, known, pgServer, scopeAndNative, scopeOf, snapshot, snapshotWith)
import AppDatabaseWorldSpec (applySession, converge, convergeAgainst, observeAll, replan, replanAgainst, sessionReviewFor, setup, setupWith)
import Control.Monad (forM_)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft, isRight)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Database.AppDatabase.Catalog (CatalogGrant (..), MemberState (..), grantDriftCode)
import Nagare.Database.AppDatabase.Owned
import Nagare.Database.AppDatabase.Sql
import Nagare.Dsl.AppDatabase
import Nagare.Dsl.Config (encodeAppDatabases)
import Nagare.Dsl.Database (Engine (..), mkEngineVersion)
import Nagare.Dsl.Load (decodeAppDatabases)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.Adapters.AppDatabase (MemberKind (..), appDatabaseMembersFromDeclarations)
import Nagare.Inventory.Adapters.AppDatabaseSessions (SessionStep (..))
import Nagare.Inventory.AppDatabase (closeOwnedLogins, quiesceAppDatabaseScope, resumeAppDatabaseScope, retireAppDatabaseScope)
import Nagare.Inventory.AppDatabaseRestore (AppDatabaseRestoreRequest (..), RestoreRun (..), RestoreTarget (..), compileAppDatabaseRestoreScope)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Test.World.Adversary
import Nagare.Test.World.AppDatabase
import Test.Tasty
import Test.Tasty.HUnit

appOwnedDatabaseTests :: TestTree
appOwnedDatabaseTests =
  testGroup
    "app-owned database (EP-257)"
    [ sqlTests
    , observationTests
    , declarationTests
    , compileTests
    , backupTests
    , worldTests
    ]

fixtureDir :: FilePath
fixtureDir = "test/fixtures/app-database/"

-- | The text of each @-- operation: NAME@ block in app-owned.sql.
fixtureOperations :: IO (Map.Map Text Text)
fixtureOperations = do
  text <- TE.decodeUtf8 <$> BS.readFile (fixtureDir <> "app-owned.sql")
  let blocks = drop 1 (T.splitOn "-- operation: " text)
  pure (Map.fromList [(T.strip name, T.unlines (takeWhile (not . T.isPrefixOf "--") (drop 1 (T.lines body)))) | block <- blocks, let (name, body) = T.breakOn "\n" block])

verifier :: Text -> PasswordHash
verifier password' = PostgresVerifier (scramVerifier (BS.pack [0 .. 15]) password')

sqlTests :: TestTree
sqlTests =
  testGroup
    "SQL is the PostgreSQL 18 fixture's"
    [ testCase "the owner, its database and its boundary render as proven" $ do
        ops <- fixtureOperations
        let block name = Map.findWithDefault ("missing operation " <> name) name ops
        block "create-owner alpha_owner" @?= renderCreateOwner "alpha_owner" (verifier "pw-alpha_owner")
        block "owner-access alpha_owner on" @?= renderOwnerAccess "alpha_owner" LoginOpen
        block "create-owned-database alpha kotei_maintenance" @?= renderCreateOwnedDatabase "alpha" "alpha_owner" (Just "kotei_maintenance")
        block "owned-database-access alpha kotei_maintenance" @?= renderOwnedDatabaseAccess "smoke_pg" "alpha" "alpha_owner" (Just "kotei_maintenance") [] []
        block "create-owner beta_owner" @?= renderCreateOwner "beta_owner" (verifier "pw-beta_owner")
        block "create-owned-database beta" @?= renderCreateOwnedDatabase "beta" "beta_owner" Nothing
        block "owned-database-access beta" @?= renderOwnedDatabaseAccess "smoke_pg" "beta" "beta_owner" Nothing [] []
    , testCase "the observation query is the one the fixture ran" $ do
        alphaQuery <- TE.decodeUtf8 <$> BS.readFile (fixtureDir <> "app-owned-observe-alpha.sql")
        betaQuery <- TE.decodeUtf8 <$> BS.readFile (fixtureDir <> "app-owned-observe-beta.sql")
        alphaQuery @?= renderObserveOwned "alpha_owner" (Just "kotei_maintenance") "alpha" "smoke_pg"
        betaQuery @?= renderObserveOwned "beta_owner" Nothing "beta" "smoke_pg"
    , testCase "a closed owner login ends its sessions" $
        assertBool "terminates" ("pg_terminate_backend" `T.isInfixOf` renderOwnerAccess "alpha_owner" LoginClosed)
    , testCase "names the app chose are quoted and escaped" $ do
        quoteIdent "kotei_runtime" @?= "\"kotei_runtime\""
        quoteIdent "we\"ird" @?= "\"we\"\"ird\""
        quoteLiteral "it's" @?= "'it''s'"
        quoteLiteral "a\\b" @?= "'a\\b'"
    ]

observed :: FilePath -> IO OwnedCatalog
observed name = BS.readFile (fixtureDir <> "observed/" <> name) >>= either (assertFailure . T.unpack) pure . parseOwnedCatalog

observationTests :: TestTree
observationTests =
  testGroup
    "the server's own observation"
    [ testCase "the app's roles are the owner and every role it administers, and nothing else" $ do
        converged <- observed "postgres-app-owned-converged.json"
        appRoles converged @?= ["alpha_owner", "kotei_admin", "kotei_app", "kotei_erasure", "kotei_inspection", "kotei_maintenance", "kotei_nested", "kotei_runtime"]
        beta' <- observed "postgres-app-owned-beta-converged.json"
        appRoles beta' @?= ["beta_app", "beta_owner", "beta_reader"]
        reachableRoles "alpha_owner" (converged ^. #memberships) @?= appRoles converged
    , testCase "after the app's privilege script both members are complete" $ do
        converged <- observed "postgres-app-owned-converged.json"
        assertComplete (classifyOwner (OwnerDeclaration "alpha_owner" "alpha" True) converged)
        assertComplete (classifyOwnedDatabase (OwnedDatabaseDeclaration "alpha" "alpha_owner" (Just "kotei_maintenance") True [] []) converged)
        beta' <- observed "postgres-app-owned-beta-converged.json"
        assertComplete (classifyOwner (OwnerDeclaration "beta_owner" "beta" True) beta')
        assertComplete (classifyOwnedDatabase (OwnedDatabaseDeclaration "beta" "beta_owner" Nothing True [] []) beta')
    , testCase "sharing a role or the database with another app is drift on both sides" $ do
        drifted <- observed "postgres-app-owned-drifted.json"
        assertDriftNaming
          ["beta_owner, which is not the app's, is a member of kotei_inspection", "beta_reader, which is not the app's, holds CONNECT on database alpha"]
          (classifyOwner (OwnerDeclaration "alpha_owner" "alpha" True) drifted)
        beta' <- observed "postgres-app-owned-beta-drifted.json"
        assertDriftNaming ["beta_owner is a member of kotei_inspection, which is not the app's"] (classifyOwner (OwnerDeclaration "beta_owner" "beta" True) beta')
    ]

assertComplete :: MemberState -> Assertion
assertComplete = \case
  MemberComplete _ -> pure ()
  other -> assertFailure ("not complete: " <> show other)

assertDriftNaming :: [Text] -> MemberState -> Assertion
assertDriftNaming expected = \case
  MemberDrift reason -> forM_ expected $ \e -> assertBool (T.unpack (reason <> " names " <> e)) (e `T.isInfixOf` reason)
  other -> assertFailure ("not drift: " <> show other)

-- | alpha-pg, app-owned through kotei_maintenance, its hook task the owner.
owned :: AppDatabase -> AppDatabase
owned db =
  db
    & #ownership
    .~ AppOwned (Just (known (mkRoleName "kotei_maintenance")))
    & #access
    . #owners
    .~ [known (mkServiceName "migrate")]

declarationTests :: TestTree
declarationTests =
  testGroup
    "the declaration"
    [ testCase "an app database that does not opt in emits its earlier bytes" $ do
        let bytes = LBS.toStrict (encodeAppDatabases [alpha Postgres])
        assertBool "no ownership key" (not ("ownership" `BS.isInfixOf` bytes))
    , testCase "an app-owned declaration round-trips" $ do
        let db = owned (alpha Postgres)
        decodeAppDatabases (LBS.toStrict (encodeAppDatabases [db])) @?= Right [db]
        appDatabaseRoles db @?= [OwnerRole]
        appDatabaseSecretName (db ^. #name) OwnerRole @?= "alpha-pg-owner"
        appDatabaseUser (db ^. #name) OwnerRole @?= "alpha_pg_owner"
        appDatabaseOwningRole db @?= Just "kotei_maintenance"
        parseAppDatabaseRole "owner" @?= Just OwnerRole
    , testCase "ownership is refused off PostgreSQL, with access, and with an unusable owning role" $ do
        refused (owned (alpha ClickHouse))
        refused (owned (alpha Postgres) & #access . #monitoring .~ [PgMonitor])
        refused (alpha Postgres & #ownership .~ AppOwned (Just (known (mkRoleName "alpha_pg_owner"))))
        refused (alpha Postgres & #ownership .~ AppOwned (Just (known (mkRoleName "postgres"))))
        assertBool "pg_ prefix" (isLeft (mkRoleName "pg_monitor"))
    ]
  where
    refused db = assertBool (show db) (isLeft (validateAppDatabase db))

compileTests :: TestTree
compileTests =
  testGroup
    "planning"
    [ testCase "an app-owned database has one owner, its database, and a schedule run as the administrator" $ do
        let (scope, native) = scopeAndNative pgServer (owned (alpha Postgres))
            members = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]
        [role | member <- members, DatabaseUserSpec _ role _ _ _ <- [member ^. #spec]] @?= ["owner"]
        [(nameText owner', nameText <$> role) | member <- members, AppOwnedDatabase _ owner' role True _ [] <- [member ^. #spec]] @?= [("alpha_pg_owner", Just "kotei_maintenance")]
        [extension ^. #owners | member <- members, DatabaseUserSpec _ "owner" _ _ extension <- [member ^. #spec]] @?= [[known (mkServiceName "migrate")]]
        let schedules = [bytes | (member, bytes) <- Map.elems native, Kubernetes _ "batch" _ _ _ <- [member ^. #address]]
        case schedules of
          [bytes] -> do
            assertBool "reads the administrator's Secret" ("nagare-db-smoke-pg" `BS.isInfixOf` bytes)
            assertBool "no migration Secret" (not ("alpha-pg-migration" `BS.isInfixOf` bytes))
            assertBool "dumps its own database" ("-d alpha >" `BS.isInfixOf` bytes)
          _ -> assertFailure "one schedule"
    , testCase "a Nagare-managed schedule still dumps with the migration credential" $ do
        let (_, native) = scopeAndNative pgServer (alpha Postgres)
        case [bytes | (member, bytes) <- Map.elems native, Kubernetes _ "batch" _ _ _ <- [member ^. #address]] of
          [bytes] -> do
            assertBool "migration Secret" ("alpha-pg-migration" `BS.isInfixOf` bytes)
            assertBool "server Secret not read" (not ("nagare-db-smoke-pg" `BS.isInfixOf` bytes))
          _ -> assertFailure "one schedule"
    , testCase "a server below PostgreSQL 18 is refused" $ do
        let old = acceptedServerAt "smoke-pg" Postgres (known (mkEngineVersion Postgres "17"))
        refusedWith "app-database-owned-server-version" (compileAgainst (snapshot [old]) [old] (owned (alpha Postgres)))
    , testCase "ownership is fixed at creation" $ do
        let managed = scopeOf pgServer (alpha Postgres)
            appOwned' = scopeOf pgServer (owned (alpha Postgres))
        refusedWith "app-database-ownership-fixed" (compileAgainst (snapshotWith [pgServer] [managed]) [pgServer] (owned (alpha Postgres)))
        refusedWith "app-database-ownership-fixed" (compileAgainst (snapshotWith [pgServer] [appOwned']) [pgServer] (alpha Postgres))
        refusedWith "app-database-ownership-fixed" (compileAgainst (snapshotWith [pgServer] [appOwned']) [pgServer] (alpha Postgres & #ownership .~ AppOwned Nothing))
        assertBool "unchanged ownership plans" (isRight (compileAgainst (snapshotWith [pgServer] [appOwned']) [pgServer] (owned (alpha Postgres))))
    , testCase "an owning role may not be a name another app database derives, nor the reverse" $ do
        let betaScope = scopeOf pgServer (beta Postgres)
            taken = alpha Postgres & #ownership .~ AppOwned (Just (known (mkRoleName "beta_pg_runtime")))
        refusedWith "app-database-owning-role-taken" (compileAgainst (snapshotWith [pgServer] [betaScope]) [pgServer] taken)
        let ownedBeta = scopeOf pgServer (beta Postgres & #ownership .~ AppOwned (Just (known (mkRoleName "alpha_pg_runtime"))))
        refusedWith "app-database-owning-role-taken" (compileAgainst (snapshotWith [pgServer] [ownedBeta]) [pgServer] (alpha Postgres))
    ]
  where
    refusedWith code = \case
      Left errors -> assertBool (show errors) (any ((== code) . (^. #code)) (NE.toList errors))
      Right _ -> assertFailure ("planned; expected " <> T.unpack code)

-- EP-258 ----------------------------------------------------------------------

-- | Every text leaf of a rendered object, so a shell inside it can be searched.
leaves :: Value -> [Text]
leaves = \case
  String t -> [t]
  Object o -> concatMap leaves (KM.elems o)
  Array a -> concatMap leaves (toList a)
  _ -> []

nativeText :: BS.ByteString -> Text
nativeText bytes = either (error . show) (T.unlines . leaves) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)

backupTests :: TestTree
backupTests =
  testGroup
    "backups and restores carry the app's roles (EP-258)"
    [ testCase "the role file and its restore are the SQL the fixture ran" $ do
        roles <- TE.decodeUtf8 <$> BS.readFile (fixtureDir <> "app-owned-roles-alpha.sql")
        rebuilt <- TE.decodeUtf8 <$> BS.readFile (fixtureDir <> "app-owned-restore-alpha-rebuilt.sql")
        scratch <- TE.decodeUtf8 <$> BS.readFile (fixtureDir <> "app-owned-restore-alpha-scratch.sql")
        roles @?= renderRoleFile "alpha_owner" "alpha"
        rebuilt @?= renderRestoreRoles "/tmp/postgres-app-owned-roles.json" (RoleRestore "alpha_owner" "kotei_maintenance" "alpha" True)
        scratch @?= renderRestoreRoles "/tmp/postgres-app-owned-roles.json" (RoleRestore "alpha_owner" "kotei_maintenance" "alpha_restore_r1" False)
    , testCase "after a rebuilt restore the role file equals the source's, verifiers included" $ do
        source <- BS.readFile (fixtureDir <> "observed/postgres-app-owned-roles.json")
        restored <- BS.readFile (fixtureDir <> "observed/postgres-app-owned-roles-restored.json")
        restored @?= source
        assertBool "the file holds a login's verifier" ("SCRAM-SHA-256$" `BS.isInfixOf` source || "\"verifier\" : null" `BS.isInfixOf` source)
        after <- observed "postgres-app-owned-restored.json"
        assertComplete (classifyOwner (OwnerDeclaration "alpha_owner" "alpha" True) after)
        assertComplete (classifyOwnedDatabase (OwnedDatabaseDeclaration "alpha" "alpha_owner" (Just "kotei_maintenance") True [] []) after)
    , testCase "an app-owned schedule writes the dump and the role file as one tar.gz" $ do
        let (_, native) = scopeAndNative pgServer (owned (alpha Postgres))
        case [nativeText bytes | (member, bytes) <- Map.elems native, Kubernetes _ "batch" _ _ _ <- [member ^. #address]] of
          [text] -> do
            assertBool "role file" (renderRoleFile "alpha_pg_owner" "alpha" `T.isInfixOf` text)
            assertBool "tar" ("tar -C /dump -cf /dump/backup.tar backup.dump roles.json" `T.isInfixOf` text)
            assertBool "format" ("tar.gz" `T.isInfixOf` text)
          _ -> assertFailure "one schedule"
    , testCase "an app-owned run ingests and restores to scratch and onto a rebuilt server with its role file first" $ do
        (appScope, serverScope, native, receiptScope, _, _) <- ingestedWith (owned (alpha Postgres))
        let request target' = AppDatabaseRestoreRequest "alpha-pg" "personal" "r1" appScope serverScope (IngestedRun receiptScope) (known (mkPhysicalIdentity "sts")) (known (mkPhysicalIdentity "pvc")) (GcsBackend "project" "bucket") (SourceLocation "test" "restore") target' (ScopeRevision (known (mkScopeGeneration 2)) (contentDigest "server"))
            shellOf target' = do
              (_, restoreNative) <- either (assertFailure . show) pure (compileAppDatabaseRestoreScope (request target') native)
              pure (T.concat [nativeText bytes | (_, bytes) <- Map.elems restoreNative])
        scratch <- shellOf ScratchTarget
        assertBool "scratch owned by the owning role" ("CREATE DATABASE \"alpha_restore_r1\" OWNER \"kotei_maintenance\";" `T.isInfixOf` scratch)
        assertBool "scratch role file" (renderRestoreRoles "/dump/app/roles.json" (RoleRestore "alpha_pg_owner" "kotei_maintenance" "alpha_restore_r1" False) `T.isInfixOf` scratch)
        assertBool "then the data" ("pg_restore --exit-on-error -h smoke-pg -U \"$POSTGRES_USER\" -d alpha_restore_r1 /dump/app/backup.dump" `T.isInfixOf` scratch)
        rebuilt <- shellOf RebuiltTarget
        assertBool "refuses over data" ("refusing to restore over data" `T.isInfixOf` rebuilt)
        assertBool "rebuilt role file creates roles" (renderRestoreRoles "/dump/app/roles.json" (RoleRestore "alpha_pg_owner" "kotei_maintenance" "alpha" True) `T.isInfixOf` rebuilt)
        assertBool "no scratch database" (not ("CREATE DATABASE" `T.isInfixOf` rebuilt))
    ]

-- World ---------------------------------------------------------------------

ownerName, databaseName' :: Text
ownerName = "alpha_pg_owner"
databaseName' = "alpha"

-- | What Kotei's privilege script does as the owner, in the world's terms:
-- roles and a login, memberships among them, ownership moved to the owning
-- role, CONNECT for its roles, and a role that creates a role in turn.
appScript :: World -> World
appScript =
  appCreatesRole "kotei_admin" "kotei_nested" False
    . appCreatesRole ownerName "kotei_admin" False
    . (#users %~ Map.adjust (#elevated .~ ["CREATEROLE"]) "kotei_admin")
    . (#databases %~ Map.adjust (#grants %~ Set.union (Set.fromList [CatalogGrant r "database" "CONNECT" | r <- ["kotei_runtime", "kotei_erasure"]])) databaseName')
    . appGrantsRole ownerName "kotei_runtime" "kotei_app" False
    . appGrantsRole ownerName "kotei_runtime" "kotei_erasure" False
    . appCreatesRole ownerName "kotei_app" True
    . appCreatesRole ownerName "kotei_erasure" False
    . appCreatesRole ownerName "kotei_runtime" False

worldTests :: TestTree
worldTests =
  testGroup
    "against the interpreter world"
    [ testCase "the owner and its database converge and re-plan to no operations" $ do
        (world, ops, members) <- setup Postgres owned []
        converge ops members >>= expectRight
        replan ops members >>= (@?= [])
        after <- readIORef world
        (^. #elevated) <$> Map.lookup ownerName (after ^. #users) @?= Just ["CREATEROLE"]
        (^. #owner) <$> Map.lookup databaseName' (after ^. #databases) @?= Just "kotei_maintenance"
        assertBool "owner holds the owning role fully" (Set.member (OwnedMembership "kotei_maintenance" ownerName "postgres" True True True) (after ^. #roleGrants))
        -- beta, which did not opt in, keeps its two users.
        assertBool "beta keeps runtime and migration" (all (`Map.member` (after ^. #users)) ["beta_pg_runtime", "beta_pg_migration"])
    , testCase "the app's own roles, memberships, ownership and grants are never drift" $ do
        (world, ops, members) <- setup Postgres owned []
        converge ops members >>= expectRight
        modifyIORef' world appScript
        replan ops members >>= (@?= [])
        observeAll ops members >>= (@?= [])
        -- The app drops a login and adds another: still nothing to do.
        modifyIORef' world (appCreatesRole ownerName "kotei_app2" True . (#users %~ Map.delete "kotei_app"))
        replan ops members >>= (@?= [])
        -- A scratch restore of its own database is the app's own.
        modifyIORef' world (#databases %~ Map.insert "alpha_restore_r1" (WorldDatabase "database:scratch" "kotei_maintenance" Set.empty "" [] Map.empty [] []))
        observeAll ops members >>= (@?= [])
    , testCase "every interruption resumes to the declared state" $
        forM_ [(n, fault) | n <- [1 .. 6 :: Int], fault <- [RefusedBeforeEffect, LostAcknowledgement, Interrupt]] $ \(n, fault) -> do
          (_, ops, members, _) <- setupWith Postgres owned [(Boundary MutateCall n, fault)]
          converge ops members >>= either (\reason -> assertFailure (show (n, fault) <> ": " <> T.unpack reason)) pure
          replan ops members >>= (@?= [])
    , testCase "PUBLIC on the app's database is closed again by an update" $ do
        (world, ops, members) <- setup Postgres owned []
        converge ops members >>= expectRight
        modifyIORef' world (#databases %~ Map.adjust (#grants %~ Set.insert (CatalogGrant "PUBLIC" "database" "CONNECT")) databaseName')
        replan ops members >>= assertBool "an update is planned" . not . null
        converge ops members >>= expectRight
        replan ops members >>= (@?= [])
    , testGroup
        "each reach beyond the app's database is drift naming it"
        [ reach "a server-wide attribute" (#users %~ Map.adjust (#elevated .~ ["BYPASSRLS"]) "kotei_runtime") "kotei_runtime holds BYPASSRLS"
        , reach "membership in a Nagare user" (appGrantsRole "postgres" "beta_pg_runtime" "kotei_runtime" False) "kotei_runtime is a member of beta_pg_runtime, which is not the app's"
        , reach "membership in a predefined role" (appGrantsRole "postgres" "pg_read_all_data" "kotei_app" False) "kotei_app is a member of pg_read_all_data, which is not the app's"
        , reach "another app's role in the app's" (appGrantsRole ownerName "kotei_runtime" "beta_pg_runtime" False) "beta_pg_runtime, which is not the app's, is a member of kotei_runtime"
        , reach "another app's role administering the app's" (appGrantsRole ownerName "kotei_runtime" "beta_pg_migration" True) "beta_pg_migration, which is not the app's, administers kotei_runtime"
        , reach "a privilege on another database" (#databases %~ Map.adjust (#grants %~ Set.insert (CatalogGrant "kotei_runtime" "database" "CONNECT")) "beta") "kotei_runtime holds CONNECT on database beta"
        , reach "owning another database" (#databases %~ Map.insert "elsewhere" (WorldDatabase "database:elsewhere" "kotei_runtime" Set.empty "" [] Map.empty [] [])) "elsewhere is owned by kotei_runtime"
        , reach "a role outside the app on its database" (#databases %~ Map.adjust (#grants %~ Set.insert (CatalogGrant "beta_pg_runtime" "database" "CONNECT")) databaseName') "beta_pg_runtime, which is not the app's, holds CONNECT on database alpha"
        , reach "a database owned by another role" (#databases %~ Map.adjust (#owner .~ ownerName) databaseName') "alpha: owned by alpha_pg_owner, declared kotei_maintenance"
        ]
    , testCase "an owning role that already exists and is not the app's refuses before anything is created" $ do
        (world, ops, members) <- setup Postgres owned []
        modifyIORef' world (#users %~ Map.insert "kotei_maintenance" (WorldUser "user:other" (PostgresVerifier "") False [] [] [] [] (-1) [] []))
        result <- converge ops members
        assertBool (show result) (either (grantDriftCode `T.isInfixOf`) (const False) result)
        after <- readIORef world
        assertBool "no database" (Map.notMember databaseName' (after ^. #databases))
        assertBool "not granted" (not (any ((== "kotei_maintenance") . (^. #role)) (Set.toList (after ^. #roleGrants))))
    , testCase "retirement closes the owner's login and keeps the database" $ do
        (world, ops, members) <- setup Postgres owned []
        converge ops members >>= expectRight
        let alphaMember member = case member ^. #kind of
              UserMember OwnerRole _ _ _ _ -> True
              OwnedDatabaseMember {} -> True
              _ -> False
            retired = Map.map (\member -> if alphaMember member then member & #enabled .~ False else member) members
        converge ops retired >>= expectRight
        replan ops retired >>= (@?= [])
        after <- readIORef world
        (^. #login) <$> Map.lookup ownerName (after ^. #users) @?= Just False
        assertBool "database kept" (Map.member databaseName' (after ^. #databases))
    , testGroup "quiesce, resume and retirement reach the app's logins (EP-258 M3)" lifecycleTests
    ]
  where
    expectRight = either (assertFailure . T.unpack) pure
    reach label change expected = testCase label $ do
      (world, ops, members) <- setup Postgres owned []
      converge ops members >>= expectRight
      modifyIORef' world (change . appScript)
      refusals <- observeAll ops members
      assertBool (T.unpack (T.intercalate " | " refusals) <> " names " <> T.unpack expected) (any (\r -> grantDriftCode `T.isPrefixOf` r && expected `T.isInfixOf` r) refusals)

lifecycleTests :: [TestTree]
lifecycleTests =
  [ testCase "quiesce closes and drains the app's logins and keeps the owner open; resume reopens exactly them" $ do
      (world, ops, members, quiesced, paused, native) <- quiescedWith [] ["kotei_app"]
      modifyIORef' world (#sessions %~ Map.insert "kotei_app" 2)
      drain <- sessionReviewFor Postgres members quiesced DrainStep
      applySession ops drain >>= expectRight
      during <- readIORef world
      loginOf during "kotei_app" @?= Just False
      loginOf during ownerName @?= Just True
      Map.lookup "kotei_app" (during ^. #sessions) @?= Just 0
      (resumed, _) <- either (assertFailure . show) pure (resumeAppDatabaseScope (Map.union paused native) quiesced "t2")
      resume <- sessionReviewFor Postgres (drain ^. #after) resumed ResumeStep
      applySession ops resume >>= expectRight
      after <- readIORef world
      loginOf after "kotei_app" @?= Just True
      -- A role that never had login stays without it.
      loginOf after "kotei_runtime" @?= Just False
      replanAgainst (resume ^. #after) ops (resume ^. #after) >>= (@?= [])
  , testCase "quiesce with the owner closes it too" $ do
      (world, ops, members, quiesced, _, _) <- quiescedWith ["owner"] ["kotei_app"]
      drain <- sessionReviewFor Postgres members quiesced DrainStep
      applySession ops drain >>= expectRight
      during <- readIORef world
      loginOf during ownerName @?= Just False
      loginOf during "kotei_app" @?= Just False
  , testCase "a login the app opened after the review refuses the drain, naming it" $ do
      (_, ops, members, quiesced, _, _) <- quiescedWith ["owner"] []
      drain <- sessionReviewFor Postgres members quiesced DrainStep
      result <- applySession ops drain
      assertBool (show result) (either ("kotei_app" `T.isInfixOf`) (const False) result)
  , testCase "retirement closes the owner and every login of the app; re-planning reopens them" $ do
      (world, ops, members) <- setup Postgres owned []
      converge ops members >>= expectRight
      modifyIORef' world appScript
      let (scope, native) = scopeAndNative pgServer (owned (alpha Postgres))
      (retired0, _) <- either (assertFailure . show) pure (retireAppDatabaseScope (snapshotWith [pgServer] [scope]) native scope)
      retired <- either (assertFailure . show) pure (closeOwnedLogins ["kotei_app"] retired0)
      retiredMembers <- membersWith retired
      convergeAgainst members ops retiredMembers >>= expectRight
      during <- readIORef world
      (loginOf during ownerName, loginOf during "kotei_app") @?= (Just False, Just False)
      replanAgainst retiredMembers ops retiredMembers >>= (@?= [])
      convergeAgainst retiredMembers ops members >>= expectRight
      after <- readIORef world
      (loginOf after ownerName, loginOf after "kotei_app") @?= (Just True, Just True)
  ]
  where
    expectRight = either (assertFailure . T.unpack) pure
    loginOf world' name' = (^. #login) <$> Map.lookup name' (world' ^. #users)
    quiescedWith roles logins = do
      (world, ops, members) <- setup Postgres owned []
      converge ops members >>= expectRight
      modifyIORef' world appScript
      let (scope, native) = scopeAndNative pgServer (owned (alpha Postgres))
      (quiesced0, paused) <- either (assertFailure . show) pure (quiesceAppDatabaseScope native scope roles "t1")
      quiesced <- either (assertFailure . show) pure (closeOwnedLogins logins quiesced0)
      pure (world, ops, members, quiesced, paused, native)
    membersWith scope =
      either (assertFailure . T.unpack) pure $
        appDatabaseMembersFromDeclarations (concat [declarations bundle | s' <- [fst pgServer, scope, scopeOf pgServer (beta Postgres)], bundle <- scopeBundles s'])
