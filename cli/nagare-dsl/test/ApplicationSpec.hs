-- | Tests for the EP-1 multi-workload 'Application' aggregate (MasterPlan 14).
--
-- M1: 'mkApplication' accepts a valid multi-workload app and rejects each
-- illegal cross-workload shape (image disagreement, an undeclared database
-- reference, a duplicate workload name, a duplicate database name). M2 (JSON
-- emit/decode round-trip + kind discrimination) and M3 (config-as-program load)
-- are added to the groups below as those milestones land.
module ApplicationSpec (applicationTests) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Application
import Nagare.Dsl.Database (Database (..), Engine (..), mkDatabaseName, mkEngineVersion)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task
import Nagare.Dsl.Types
import Nagare.Dsl.Worker (Worker (..), webWorker)
import Test.Tasty
import Test.Tasty.HUnit

applicationTests :: TestTree
applicationTests =
  testGroup
    "Nagare.Dsl.Application (EP-1)"
    [ testGroup "mkApplication" mkApplicationTests
    ]

-- ---------------------------------------------------------------------------
-- Shared fixtures: a kizashi-shaped app — one service, two workers (both
-- referencing the managed Postgres), one managed Postgres, one image-inheriting
-- migration task — all on the one shared image.

sharedImage :: Text
sharedImage = "gcr.io/knative-samples/helloworld-go"

dbNameKizashi :: DatabaseName
dbNameKizashi = unsafe (mkDatabaseName "kizashi-db")

kizashiDb :: Database
kizashiDb =
  Database
    { dbName = dbNameKizashi
    , engine = Postgres
    , version = unsafe (mkEngineVersion Postgres "18")
    , namespace = unsafe (mkNamespace "personal")
    , size = unsafe (mkQuantity "10Gi")
    , resources = Nothing
    , retention = Retain
    }

kizashiServe :: Deployment
kizashiServe = unsafe (webService "kizashi-serve" sharedImage)

worker1, worker2 :: Worker
worker1 = (unsafeStr (webWorker "kizashi-worker" sharedImage)) {databases = [dbNameKizashi]}
worker2 = (unsafeStr (webWorker "kizashi-agent-worker" sharedImage)) {databases = [dbNameKizashi]}

-- | The migration task that EP-2 will run as a pre-deploy hook. It inherits the
-- app's image (taskImage = Nothing, taskApp = Just the app) and so is exempt
-- from the image-agreement check.
migrateTask :: Task
migrateTask =
  unsafe $
    mkTask
      Task
        { taskName = unsafe (mkServiceName "kizashi-migrate")
        , taskNamespace = unsafe (mkNamespace "personal")
        , taskSchedule = unsafe (mkSchedule "0 0 * * *")
        , taskImage = Nothing
        , taskApp = Just (unsafe (mkServiceName "kizashi"))
        , taskCommand = ["python", "manage.py", "migrate"]
        , taskArgs = []
        , taskEnv = Map.empty
        , taskResources = Nothing
        , taskTimeoutSeconds = Nothing
        , taskConcurrencyPolicy = Forbid
        , taskRestartPolicy = Never
        , taskBackoffLimit = 0
        , taskSuccessfulJobsHistoryLimit = 3
        , taskFailedJobsHistoryLimit = 1
        , taskStartingDeadlineSeconds = Nothing
        }

-- | The raw (unvalidated) record for the valid multi-workload app. 'mkApplication'
-- on it must return 'Right'; the negative cases below mutate one field of it.
multiAppRec :: Application
multiAppRec =
  Application
    { appName = unsafe (mkServiceName "kizashi")
    , namespace = unsafe (mkNamespace "personal")
    , image = unsafe (mkImageRef sharedImage)
    , env = Map.fromList [(unsafe (mkEnvName "LOG_LEVEL"), runtimeScoped (EnvLiteral "info"))]
    , appDatabases = [kizashiDb]
    , service = Just kizashiServe
    , workers = [worker1, worker2]
    , tasks = [migrateTask]
    }

-- ---------------------------------------------------------------------------
-- M1: mkApplication

mkApplicationTests :: [TestTree]
mkApplicationTests =
  [ testCase "accepts a valid multi-workload application" $
      assertRight (mkApplication multiAppRec)
  , testCase "rejects a worker disagreeing on the shared image" $
      assertLeftContains
        "shared image"
        (mkApplication multiAppRec {workers = [worker1 & #image .~ unsafe (mkImageRef "gcr.io/other/img"), worker2]})
  , testCase "rejects a reference to an undeclared database" $
      assertLeftContains
        "not declared"
        (mkApplication multiAppRec {appDatabases = []})
  , testCase "rejects two workloads with the same name" $
      assertLeftContains
        "duplicate workload name"
        (mkApplication multiAppRec {workers = [worker1, worker1]})
  , testCase "rejects two databases with the same name" $
      assertLeftContains
        "duplicate database name"
        (mkApplication multiAppRec {appDatabases = [kizashiDb, kizashiDb]})
  , testCase "rejects a workload in a different namespace" $
      assertLeftContains
        "namespace"
        (mkApplication multiAppRec {workers = [worker1 & #namespace .~ unsafe (mkNamespace "other"), worker2]})
  ]

-- ---------------------------------------------------------------------------
-- Helpers (mirroring the other spec modules).

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> Text.unpack e)

unsafeStr :: Either String a -> a
unsafeStr (Right a) = a
unsafeStr (Left e) = error ("test fixture invalid: " <> e)

assertRight :: (Show e) => Either e a -> Assertion
assertRight (Right _) = pure ()
assertRight (Left err) = assertFailure ("expected Right, got Left: " <> show err)

assertLeftContains :: Text -> Either Text a -> Assertion
assertLeftContains needle (Left msg)
  | needle `Text.isInfixOf` msg = pure ()
  | otherwise =
      assertFailure ("expected Left containing " <> show needle <> ", got: " <> Text.unpack msg)
assertLeftContains needle (Right _) =
  assertFailure ("expected Left containing " <> show needle <> ", got Right")
