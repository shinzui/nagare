-- | Database responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Database
  ( connectionEnvTests
  , databaseTests
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cluster.Namespace
  ( NamespacePurpose (ApplicationNamespace)
  )
import Nagare.Database.Connection
  ( ConnIdentity (..)
  , connectionEnv
  , mergeConnectionEnvs
  )
import Nagare.Database.Create
  ( DbCreateParams (..)
  , buildDatabase
  , classifyPasswordObservation
  , ensureCredential
  , passwordKey
  )
import Nagare.Database.Discover
  ( DbRow (..)
  , dbLabelSelector
  , extractDbRows
  , formatDbTable
  )
import Nagare.Database.Secret
  ( ConnectionParts (..)
  , b64decode
  , composeConnectionUrl
  , percentEncode
  , secretKeysFor
  )
import Nagare.Dsl.Database
  ( Engine (..)
  , engineToken
  , mkDatabaseName
  )
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Render (renderService)
import Nagare.Dsl.Types
  ( EnvName
  , EnvVar (EnvLiteral, EnvSecretRef)
  , ScopedEnvVar (ScopedEnvVar, value)
  , envNameText
  , mkEnvName
  , mkNamespace
  , runtimeScoped
  , secretNameText
  )
import Nagare.Env.Store (extractSecretData)
import Nagare.Test.Environment (mkDemoDep)
import Nagare.Test.Support.Assertions (assertLeftText, unsafe)
import Nagare.Test.Support.Profiles (tnbProfile)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

-- ---------------------------------------------------------------------------
-- EP-45: managed-database CLI pure helpers.

databaseTests :: [TestTree]
databaseTests =
  [ testGroup
      "Nagare.Database.Secret"
      [ testCase "composeConnectionUrl postgres" $
          composeConnectionUrl Postgres parts
            @?= "postgresql://nagare:pw@pg-main.personal.svc.cluster.local:5432/pg_main"
      , testCase "composeConnectionUrl redis" $
          composeConnectionUrl Redis parts
            @?= "redis://:pw@pg-main.personal.svc.cluster.local:6379"
      , testCase "composeConnectionUrl clickhouse" $
          composeConnectionUrl ClickHouse parts
            @?= "clickhouse://nagare:pw@pg-main.personal.svc.cluster.local:9000"
      , testCase "percentEncode escapes reserved userinfo characters" $
          percentEncode "a+b/c=:@ ~" @?= "a%2Bb%2Fc%3D%3A%40%20~"
      , testCase "composeConnectionUrl percent-encodes hostile credentials" $ do
          let hostile = parts & #user .~ "user:name@host" & #password .~ "a+b/c="
          composeConnectionUrl Postgres hostile
            @?= "postgresql://user%3Aname%40host:a%2Bb%2Fc%3D@pg-main.personal.svc.cluster.local:5432/pg_main"
          composeConnectionUrl Redis hostile
            @?= "redis://:a%2Bb%2Fc%3D@pg-main.personal.svc.cluster.local:6379"
          composeConnectionUrl ClickHouse hostile
            @?= "clickhouse://user%3Aname%40host:a%2Bb%2Fc%3D@pg-main.personal.svc.cluster.local:9000"
      , testCase "secretKeysFor keeps the raw password alongside the encoded URL" $ do
          let hostile = parts & #password .~ "a+b/c="
          lookup "POSTGRES_PASSWORD" (secretKeysFor Postgres hostile) @?= Just "a+b/c="
          lookup "DATABASE_URL" (secretKeysFor Postgres hostile)
            @?= Just "postgresql://nagare:a%2Bb%2Fc%3D@pg-main.personal.svc.cluster.local:5432/pg_main"
      , testCase "b64decode rejects invalid UTF-8 without throwing" $
          assertLeftText (b64decode "/w==")
      , testCase "secret store rejects invalid UTF-8 without throwing" $
          assertLeftText (extractSecretData "{\"data\":{\"BAD\":\"/w==\"}}")
      , testCase "secretKeysFor postgres has the four keys" $
          map fst (secretKeysFor Postgres parts)
            @?= ["POSTGRES_PASSWORD", "POSTGRES_USER", "POSTGRES_DB", "DATABASE_URL"]
      , testCase "secretKeysFor redis has two keys" $
          map fst (secretKeysFor Redis parts) @?= ["REDIS_PASSWORD", "REDIS_URL"]
      , testCase "engineToken maps the three engines" $
          map engineToken [Postgres, Redis, ClickHouse] @?= ["postgres", "redis", "clickhouse"]
      , testCase "passwordKey per engine" $
          map passwordKey [Postgres, Redis, ClickHouse]
            @?= ["POSTGRES_PASSWORD", "REDIS_PASSWORD", "CLICKHOUSE_PASSWORD"]
      ]
  , testGroup
      "Nagare.Database.Create.buildDatabase"
      [ testCase "builds postgres with defaults" $
          case buildDatabase Postgres "pg-main" (mkParams Nothing Nothing) of
            Right _ -> pure ()
            Left e -> assertFailure (T.unpack e)
      , testCase "rejects a bad name" $
          assertBool "should reject" (isLeft (buildDatabase Postgres "Bad_Name" (mkParams Nothing Nothing)))
      , testCase "rejects latest version" $
          assertBool "should reject" (isLeft (buildDatabase Postgres "pg" (mkParams (Just "latest") Nothing)))
      , testCase "only a confirmed absent Secret can generate a password" $ do
          classifyPasswordObservation Postgres ExitSuccess "" @?= Right Nothing
          assertLeftText (classifyPasswordObservation Postgres (ExitFailure 1) "")
          assertLeftText (classifyPasswordObservation Postgres ExitSuccess "{\"data\":{}}")
          assertLeftText (classifyPasswordObservation Postgres ExitSuccess "invalid json")
      , testCase "a concurrent Secret creator wins without credential overwrite" $ do
          observations <- newIORef [Right Nothing, Right (Just "winner")]
          generated <- newIORef (0 :: Int)
          writes <- newIORef ([] :: [Text])
          let observe = do
                pending <- readIORef observations
                case pending of
                  next : rest -> writeIORef observations rest >> pure next
                  [] -> pure (Left "unexpected read")
              generate = modifyIORef' generated (+ 1) >> pure "candidate"
              createOnly candidate = modifyIORef' writes (candidate :) >> pure False
          ensureCredential observe generate createOnly >>= (@?= Right "winner")
          readIORef generated >>= (@?= 1)
          readIORef writes >>= (@?= ["candidate"])
      , testCase "unknown Secret observation never generates a credential" $ do
          generated <- newIORef (0 :: Int)
          let generate = modifyIORef' generated (+ 1) >> pure "candidate"
          ensureCredential (pure (Left "API unavailable")) generate (const (pure True)) >>= (@?= Left "API unavailable")
          readIORef generated >>= (@?= 0)
      ]
  , testGroup
      "Nagare.Database.Discover"
      [ testCase "dbLabelSelector" $
          dbLabelSelector @?= "nagare.dev/managed-by=nagarectl,nagare.dev/database"
      , testCase "extractDbRows parses a statefulset list" $
          extractDbRows stsListJson
            @?= Right [DbRow "pg-main" "postgres" "18" "10Gi" "Retain" "pg-main.personal.svc.cluster.local" True]
      , testCase "extractDbRows on empty items is Right []" $
          extractDbRows "{\"items\":[]}" @?= Right []
      , testCase "extractDbRows on malformed JSON is Left" $
          assertBool "should be Left" (isLeft (extractDbRows "not json"))
      , testCase "formatDbTable renders a header" $
          assertBool
            "has NAME header"
            ( "NAME"
                `T.isInfixOf` formatDbTable
                  [DbRow "pg-main" "postgres" "18" "10Gi" "Retain" "pg-main.personal.svc.cluster.local" True]
            )
      ]
  ]
  where
    parts =
      ConnectionParts
        { user = "nagare"
        , password = "pw"
        , host = "pg-main.personal.svc.cluster.local"
        , database = "pg_main"
        }
    mkParams ver sz =
      DbCreateParams
        { namespace = "personal"
        , namespacePurpose = ApplicationNamespace
        , version = ver
        , size = sz
        , cpu = Nothing
        , memory = Nothing
        , config = Nothing
        , dryRun = True
        , targetProfile = tnbProfile
        }
    stsListJson =
      BC.pack
        "{\"items\":[{\"metadata\":{\"name\":\"pg-main\",\"namespace\":\"personal\",\"labels\":{\"nagare.dev/engine\":\"postgres\",\"nagare.dev/managed-by\":\"nagarectl\"},\"annotations\":{\"nagare.dev/version\":\"18\",\"nagare.dev/size\":\"10Gi\",\"nagare.dev/retention\":\"Retain\"}},\"status\":{\"readyReplicas\":1}}]}"

-- ---------------------------------------------------------------------------
-- EP-46: app -> database connection-env injection.

connEnvTestPg :: Map.Map EnvName ScopedEnvVar
connEnvTestPg =
  connectionEnv
    Postgres
    (unsafe (mkDatabaseName "notes-db"))
    (unsafe (mkNamespace "personal"))
    (ConnIdentity {user = Just "app", database = Just "notes"})

connEnvTestRedis :: Map.Map EnvName ScopedEnvVar
connEnvTestRedis =
  connectionEnv
    Redis
    (unsafe (mkDatabaseName "cache"))
    (unsafe (mkNamespace "personal"))
    (ConnIdentity {user = Nothing, database = Nothing})

-- | Classify a generated entry: Left literal-value, or Right secret-name.
classifyConn :: Map.Map EnvName ScopedEnvVar -> Text -> Maybe (Either Text Text)
classifyConn m name = do
  en <- either (const Nothing) Just (mkEnvName name)
  ScopedEnvVar {value = v} <- Map.lookup en m
  pure $ case v of
    EnvLiteral t -> Left t
    EnvSecretRef s -> Right (secretNameText s)

connectionEnvTests :: [TestTree]
connectionEnvTests =
  [ testGroup
      "connectionEnv per engine"
      [ testCase "Postgres host/port/user/db are literals" $ do
          classifyConn connEnvTestPg "POSTGRES_HOST" @?= Just (Left "notes-db.personal.svc.cluster.local")
          classifyConn connEnvTestPg "POSTGRES_PORT" @?= Just (Left "5432")
          classifyConn connEnvTestPg "POSTGRES_USER" @?= Just (Left "app")
          classifyConn connEnvTestPg "POSTGRES_DB" @?= Just (Left "notes")
      , testCase "Postgres password and DATABASE_URL are secret refs to nagare-db-notes-db" $ do
          classifyConn connEnvTestPg "POSTGRES_PASSWORD" @?= Just (Right "nagare-db-notes-db")
          classifyConn connEnvTestPg "DATABASE_URL" @?= Just (Right "nagare-db-notes-db")
      , testCase "Postgres has exactly these six keys" $
          sort (map envNameText (Map.keys connEnvTestPg))
            @?= sort ["POSTGRES_HOST", "POSTGRES_PORT", "POSTGRES_USER", "POSTGRES_DB", "POSTGRES_PASSWORD", "DATABASE_URL"]
      , testCase "Redis host/port literals; password/URL secret refs" $ do
          classifyConn connEnvTestRedis "REDIS_HOST" @?= Just (Left "cache.personal.svc.cluster.local")
          classifyConn connEnvTestRedis "REDIS_PORT" @?= Just (Left "6379")
          classifyConn connEnvTestRedis "REDIS_PASSWORD" @?= Just (Right "nagare-db-cache")
          classifyConn connEnvTestRedis "REDIS_URL" @?= Just (Right "nagare-db-cache")
      , testCase "every entry is Runtime-scoped" $
          mapM_ (\sev -> sev ^. #scopes @?= runtimeScoped (EnvLiteral "x") ^. #scopes) (Map.elems connEnvTestPg)
      ]
  , testGroup
      "mergeConnectionEnvs"
      [ testCase "two same-engine maps collide" $
          assertBool "should be Left" (isLeft (mergeConnectionEnvs [connEnvTestPg, pgOther]))
      , testCase "different engines merge cleanly" $
          case mergeConnectionEnvs [connEnvTestPg, connEnvTestRedis] of
            Right m -> assertBool "has both" (Map.size m == Map.size connEnvTestPg + Map.size connEnvTestRedis)
            Left e -> assertFailure (T.unpack e)
      ]
  , testGroup
      "rendered Service carries DB env (IP5)"
      [ testCase "literals and a DATABASE_URL secretKeyRef appear" $ do
          let dep' = mkDemoDep connEnvTestPg
              yaml = TE.decodeUtf8 (renderService dep' "20260602-120000")
          assertBool "POSTGRES_HOST" ("POSTGRES_HOST" `T.isInfixOf` yaml)
          assertBool "host literal" ("notes-db.personal.svc.cluster.local" `T.isInfixOf` yaml)
          assertBool "DATABASE_URL" ("DATABASE_URL" `T.isInfixOf` yaml)
          assertBool "secretKeyRef" ("secretKeyRef" `T.isInfixOf` yaml)
          assertBool "secret name" ("nagare-db-notes-db" `T.isInfixOf` yaml)
      , testCase "generated connection var overrides a user value (precedence)" $ do
          let userUrl = Map.singleton (unsafe (mkEnvName "DATABASE_URL")) (runtimeScoped (EnvLiteral "user-wrote-this"))
              merged = Map.union connEnvTestPg userUrl -- mergeGenerated is left-biased
          classifyConn merged "DATABASE_URL" @?= Just (Right "nagare-db-notes-db")
      ]
  ]
  where
    pgOther =
      connectionEnv
        Postgres
        (unsafe (mkDatabaseName "other-db"))
        (unsafe (mkNamespace "personal"))
        (ConnIdentity {user = Just "app", database = Just "other"})
