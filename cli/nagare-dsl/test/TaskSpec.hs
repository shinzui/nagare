-- | Tests for the typed task model (MasterPlan 10, EP-50) and its
-- release-only trigger (EP-269): smart constructors, the JSON round trip and
-- its refusals, and the rendered CronJob goldens.
module TaskSpec (taskTests, appTask, releaseTask) where

import Control.Lens ((&), (.~))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Config (encodeDeployment, encodeTask)
import Nagare.Dsl.Load (LoadError (..), decodeDeployment, decodeTask)
import Nagare.Dsl.Prelude hiding (Text, (&), (.~))
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task
import Nagare.Dsl.Task.Render (renderTask)
import Nagare.Dsl.Types
import Nagare.Resource.Application (taskResourceId)
import Nagare.Resource.Types (ScopeKind (..), mkLogicalKey, mkName, mkScopeId)
import Test.Tasty
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit

-- | A standalone scheduled task, assembled through smart constructors. Mirrors
-- test/fixtures/task/standalone/nagare/Config.hs.
standaloneTask :: Task
standaloneTask =
  unsafe $
    mkTask
      Task
        { name = unsafe (mkServiceName "cleanup")
        , logicalKey = Nothing
        , namespace = unsafe (mkNamespace "personal")
        , trigger = OnSchedule (unsafe (mkSchedule "0 3 * * *"))
        , image = Just (unsafe (mkImageRef "gcr.io/myproject/notes"))
        , app = Nothing
        , command = ["python", "manage.py", "cleanup"]
        , args = []
        , env = Map.fromList [(unsafe (mkEnvName "DRY_RUN"), runtimeScoped (EnvLiteral "false"))]
        , resources = Nothing
        , timeoutSeconds = Just 600
        , concurrencyPolicy = Forbid
        , restartPolicy = Never
        , backoffLimit = 0
        , successfulJobsHistoryLimit = 3
        , failedJobsHistoryLimit = 1
        , startingDeadlineSeconds = Nothing
        , serviceAccount = Nothing
        , managedEnv = InheritManagedEnv
        , appDatabases = []
        , buckets = []
        }

-- | A task associated with the @notes@ app: it inherits @notes@'s image
-- (image = Nothing) and its runtime env/secret (rendered as envFrom), and
-- carries the nagare.dev/app label.
appTask :: Task
appTask =
  unsafe . mkTask $
    standaloneTask
      & #name .~ unsafe (mkServiceName "sync")
      & #trigger .~ OnSchedule (unsafe (mkSchedule "*/15 * * * *"))
      & #image .~ Nothing
      & #app .~ Just (unsafe (mkServiceName "notes"))
      & #command .~ ["python", "manage.py", "sync"]
      & #env .~ Map.empty
      & #timeoutSeconds .~ Nothing
      & #backoffLimit .~ 2

-- | A release-only pre-deploy hook (EP-269): the CronJob renders suspended
-- with a schedule that never fires.
releaseTask :: Task
releaseTask =
  unsafe (releaseHook "migrate" "notes" "python manage.py migrate")
    & #env .~ Map.fromList [(unsafe (mkEnvName "DRY_RUN"), runtimeScoped (EnvLiteral "false"))]

taskObject :: Task -> Aeson.Object
taskObject t = either error id (Aeson.eitherDecode (encodeTask t))

taskJsonWith :: Text -> BS.ByteString
taskJsonWith extra =
  TE.encodeUtf8
    ( "{\"kind\":\"Task\",\"name\":\"x\",\"namespace\":\"personal\",\"app\":\"notes\",\"command\":[\"echo\"]"
        <> extra
        <> "}"
    )

taskTests :: [TestTree]
taskTests =
  [ testGroup
      "mkSchedule"
      [ testCase "accepts 0 3 * * *" $ assertRight (mkSchedule "0 3 * * *")
      , testCase "accepts a step */15 * * * *" $ assertRight (mkSchedule "*/15 * * * *")
      , testCase "accepts a list and range 1,15 0-6 * * 1-5" $
          assertRight (mkSchedule "1,15 0-6 * * 1-5")
      , testCase "rejects empty" $ assertLeftContains "empty" (mkSchedule "")
      , testCase "rejects 4 fields" $ assertLeftContains "5" (mkSchedule "0 3 * *")
      , testCase "rejects out-of-range minute" $ assertLeftContains "minute" (mkSchedule "60 3 * * *")
      , testCase "rejects garbage" $ assertLeftContains "minute" (mkSchedule "x 3 * * *")
      ]
  , testGroup
      "mkTask invariants"
      [ testCase "rejects inheriting image with no app" $
          assertLeftContains "inherit" (mkTask (standaloneTask & #image .~ Nothing & #app .~ Nothing))
      , testCase "rejects negative backoffLimit" $
          assertLeftContains ">= 0" (mkTask (standaloneTask & #backoffLimit .~ -1))
      , testCase "rejects non-positive timeout" $
          assertLeftContains "> 0" (mkTask (standaloneTask & #timeoutSeconds .~ Just 0))
      , testCase "rejects a release-only task with no app" $
          assertLeftContains "release-only" (mkTask (standaloneTask & #trigger .~ ReleaseOnly))
      , testCase "releaseHook inherits the app image and no managed store" $ do
          releaseTask ^. #trigger @?= ReleaseOnly
          releaseTask ^. #image @?= Nothing
          releaseTask ^. #managedEnv @?= NoManagedEnv
      ]
  , testGroup
      "release-only trigger JSON (EP-269)"
      [ testCase "a release-only task emits a null schedule and trigger release-only" $ do
          let value = taskObject releaseTask
          KeyMap.lookup "schedule" value @?= Just Aeson.Null
          KeyMap.lookup "trigger" value @?= Just (Aeson.String "release-only")
      , testCase "a scheduled task emits no trigger key" $ do
          KeyMap.lookup "trigger" (taskObject standaloneTask) @?= Nothing
      , testCase "a standalone release-only task is refused at decode" $
          case decodeTask (taskJsonWith ",\"schedule\":null,\"trigger\":\"release-only\"") of
            Left (MarshalError "trigger" msg) -> assertBool (show msg) ("pre-deploy hook" `Text.isInfixOf` msg)
            other -> assertFailure ("expected MarshalError trigger, got: " <> show other)
      , testCase "a task naming both a schedule and a trigger is refused" $
          case decodeTask (taskJsonWith ",\"schedule\":\"0 3 * * *\",\"trigger\":\"release-only\"") of
            Left (MarshalError "trigger" _) -> pure ()
            other -> assertFailure ("expected MarshalError trigger, got: " <> show other)
      , testCase "a task naming neither a schedule nor a trigger is refused" $
          case decodeTask (taskJsonWith "") of
            Left (MarshalError "trigger" _) -> pure ()
            other -> assertFailure ("expected MarshalError trigger, got: " <> show other)
      , testCase "an unknown trigger is refused" $
          case decodeTask (taskJsonWith ",\"schedule\":null,\"trigger\":\"nightly\"") of
            Left (MarshalError "trigger" _) -> pure ()
            other -> assertFailure ("expected MarshalError trigger, got: " <> show other)
      ]
  , testGroup
      "JSON round-trip and kind discrimination"
      [ testCase "standalone task survives emit -> decode round-trip" $
          decodeTask (toStrict (encodeTask standaloneTask)) @?= Right standaloneTask
      , testCase "pinned task key survives rename and JSON round-trip" $ do
          let key = unsafe (mkLogicalKey "cleanup")
              pinned = standaloneTask & #logicalKey .~ Just key
              renamed = pinned & #name .~ unsafe (mkServiceName "cleanup-new")
              owner = unsafe (mkScopeId Application "notes")
              role = unsafe (mkName "cronjob")
          decodeTask (toStrict (encodeTask renamed)) @?= Right renamed
          taskResourceId owner role pinned @?= taskResourceId owner role renamed
      , testCase "app-associated task round-trips" $
          decodeTask (toStrict (encodeTask appTask)) @?= Right appTask
      , testCase "decoding a Task as a Deployment is UnexpectedKind" $
          case decodeDeployment (toStrict (encodeTask standaloneTask)) of
            Left (UnexpectedKind "Deployment" "Task") -> pure ()
            other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
      , testCase "decoding a Deployment as a Task is UnexpectedKind" $
          case decodeTask (toStrict (encodeDeployment (unsafe (webService "hello" "gcr.io/knative-samples/helloworld-go")))) of
            Left (UnexpectedKind "Task" "<none>") -> pure ()
            other -> assertFailure ("expected UnexpectedKind, got: " <> show other)
      , testCase "a task with its own command and no app decodes" $
          case decodeTask
            "{\"kind\":\"Task\",\"name\":\"x\",\"namespace\":\"personal\",\"schedule\":\"0 3 * * *\",\"image\":\"gcr.io/p/x\",\"command\":[\"echo\"]}" of
            Right _ -> pure ()
            other -> assertFailure ("expected Right (own command, no app), got: " <> show other)
      , testCase "an inheriting task with no app fails to decode (MarshalError task)" $
          case decodeTask
            "{\"kind\":\"Task\",\"name\":\"x\",\"namespace\":\"personal\",\"schedule\":\"0 3 * * *\",\"command\":[\"echo\"]}" of
            Left (MarshalError "task" _) -> pure ()
            other -> assertFailure ("expected MarshalError task, got: " <> show other)
      ]
  , testGroup
      "renderer goldens"
      [ goldenVsString "renderTask standalone" "test/golden/task-standalone.cronjob.yaml" $
          pure (fromStrict (renderTask standaloneTask))
      , goldenVsString "renderTask app-associated" "test/golden/task-app-associated.cronjob.yaml" $
          pure (fromStrict (renderTask appTask))
      , goldenVsString "renderTask release-only" "test/golden/task-release-only.cronjob.yaml" $
          pure (fromStrict (renderTask releaseTask))
      ]
  ]

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> Text.unpack e)

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
