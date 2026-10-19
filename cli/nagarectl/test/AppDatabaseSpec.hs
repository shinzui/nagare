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

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Database.Secret (b64decode)
import Nagare.Dsl.AppDatabase
import Nagare.Dsl.Config (encodeAppDatabases)
import Nagare.Dsl.Database (Database (Database), Engine (..), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Load (LoadError (..), decodeAppDatabases)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Adapters.CredentialTemplate (credentialDataMatches, materializeCredential)
import Nagare.Inventory.AppDatabase
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (HourlyRecoveryPoint))
import Nagare.Inventory.DataService (compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Resource.AppDatabase (appDatabaseCredentialTemplate)
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), RecoveryIntent (..), Sensitivity (Private), mkSecretRef)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
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
        , testCase "loading refuses each invalid declaration with its reason" $ do
            refused (kansokuPg & #engine .~ Redis) "not supported on Redis"
            refused (kansokuPg & #logicalDatabases .~ (logical "a" :| [logical "b"])) "exactly one logical database"
            refused (kansokuCh & #logicalDatabases .~ (logical "a" :| [logical "a"])) "repeats a logical database"
            mapM_ (\reserved -> refused (kansokuPg & #logicalDatabases .~ (logical reserved :| [])) "reserved") ["postgres", "template0", "template1", "labs_postgres"]
            mapM_ (\reserved -> refused (kansokuCh & #logicalDatabases .~ (logical reserved :| [])) "reserved") ["default", "system", "information_schema"]
            assertLeftContaining "logicalDatabases" (decodeAppDatabases (rawJson "{\"name\":\"x\",\"server\":\"s\",\"engine\":\"postgres\",\"namespace\":\"personal\",\"logicalDatabases\":[\"Bad\"]}"))
            assertLeftContaining "declared twice" (decodeAppDatabases (LBS.toStrict (encodeAppDatabases [kansokuPg, kansokuPg])))
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
            Map.size native @?= 2
            [nameText user | DatabaseUser _ user <- map (^. #address) members] @?= ["alpha_ch_runtime", "alpha_ch_migration"]
            [nameText db | DatabaseName _ db <- map (^. #address) members] @?= ["alpha", "alpha_ledger"]
            [member ^. #executor | member <- members, isLogical member] @?= replicate 4 AppDatabaseExecutor
            assertBool "every logical member is ordered after the server StatefulSet" $
              all (\member -> OrderedAfter (serverStateful chServer ^. #identity) `elem` member ^. #dependencies) (filter isLogical members)
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
            retired <- either (assertFailure . show) pure (retireAppDatabaseScope accepted found)
            [on | LogicalDatabase _ _ _ on _ <- specs retired] @?= [False]
            [on | DatabaseUserSpec _ _ on _ <- specs retired] @?= [False, False]
            let runtime = head [member ^. #identity | bundle <- scopeBundles scope, Managed member <- declarations bundle, DatabaseUserSpec _ "runtime" _ _ <- [member ^. #spec]]
                bound = snapshotWith [pgServer] [scope, boundTo runtime]
            case retireAppDatabaseScope bound found of
              Left errors -> map (^. #code) (NE.toList errors) @?= ["app-database-in-use"]
              Right _ -> assertFailure "retirement of a bound app database was accepted"
            map (\row -> (row ^. #name, row ^. #server, row ^. #retired)) (appDatabaseRows accepted) @?= [("alpha-pg", "smoke-pg", False)]
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
        , testCase "the ClickHouse server enables SQL access management" $ do
            let (_, native) = chServer
            assertBool "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT is set" $
              any (T.isInfixOf "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT" . TE.decodeUtf8 . snd) (Map.elems native)
        ]
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
kansokuPg = AppDatabase (known (mkAppDatabaseName "kansoku-pg")) Nothing (dbServer "labs-postgres") Postgres personal (logical "kansoku" :| [])

kansokuCh :: AppDatabase
kansokuCh = AppDatabase (known (mkAppDatabaseName "kansoku-ch")) Nothing (dbServer "labs-clickhouse") ClickHouse personal (logical "analytics" :| [logical "kansoku_migration_ledger"])

alpha :: Engine -> AppDatabase
alpha Postgres = AppDatabase (known (mkAppDatabaseName "alpha-pg")) Nothing (dbServer "smoke-pg") Postgres personal (logical "alpha" :| [])
alpha _ = AppDatabase (known (mkAppDatabaseName "alpha-ch")) Nothing (dbServer "smoke-ch") ClickHouse personal (logical "alpha" :| [logical "alpha_ledger"])

beta :: Engine -> AppDatabase
beta Postgres = AppDatabase (known (mkAppDatabaseName "beta-pg")) Nothing (dbServer "smoke-pg") Postgres personal (logical "beta" :| [])
beta _ = AppDatabase (known (mkAppDatabaseName "beta-ch")) Nothing (dbServer "smoke-ch") ClickHouse personal (logical "beta" :| [])

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
  compileStandaloneAppDatabase accepted (acceptedNative servers) db testCluster Nothing testRecovery (SourceLocation "test" "app-database")

scopeAndNative :: Server -> AppDatabase -> (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
scopeAndNative s db = known (compileAgainst (snapshot [s]) [s] db)

scopeOf :: Server -> AppDatabase -> ScopeDeclaration
scopeOf s = fst . scopeAndNative s

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
