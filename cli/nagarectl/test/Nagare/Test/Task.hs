-- | Task responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Task
  ( taskDiscoverTests
  , taskResolveTests
  , taskRunTests
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Task
  ( ConcurrencyPolicy (Forbid)
  , RestartPolicy (Never)
  , Task (..)
  , mkSchedule
  , mkTask
  )
import Nagare.Dsl.Types
  ( envNameText
  , mkEnvName
  , mkImageRef
  , mkNamespace
  , mkServiceName
  )
import Nagare.Env.Generated (mergeGenerated)
import Nagare.Task.Discover
  ( AppScope (AnyApp, App, NoApp)
  , extractTaskRows
  , formatTaskTable
  , taskLabelSelector
  )
import Nagare.Task.Logs
  ( TaskLogTarget (..)
  , grafanaHint
  , taskLogArgs
  )
import Nagare.Task.Resolve
  ( predefinedTaskEnv
  , renderResolvedTask
  , resolveTaskImage
  )
import Nagare.Task.Run (oneOffJobName, runArgs)
import Nagare.Test.Support.Assertions (unsafe)
import Test.Tasty (TestTree)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

-- ---------------------------------------------------------------------------
-- Nagare.Task (MasterPlan 10, EP-51): the pure discovery/run/logs helpers.

taskDiscoverTests :: ByteString -> [TestTree]
taskDiscoverTests fixture =
  [ testCase "taskLabelSelector AnyApp omits the app term" $
      taskLabelSelector AnyApp
        @?= "nagare.dev/managed-by=nagarectl,nagare.dev/task"
  , testCase "taskLabelSelector (App notes) appends the app term" $
      taskLabelSelector (App "notes")
        @?= "nagare.dev/managed-by=nagarectl,nagare.dev/task,nagare.dev/app=notes"
  , testCase "taskLabelSelector NoApp appends the not-exists term" $
      taskLabelSelector NoApp
        @?= "nagare.dev/managed-by=nagarectl,nagare.dev/task,!nagare.dev/app"
  , testCase "extractTaskRows parses both managed tasks" $
      case extractTaskRows fixture of
        Left e -> assertFailure (T.unpack e)
        Right rows -> map (^. #name) rows @?= ["cleanup", "nightly-report"]
  , testCase "extractTaskRows reads schedule, app, and active count" $
      case extractTaskRows fixture of
        Left e -> assertFailure (T.unpack e)
        Right rows -> do
          let byName n = head (filter ((== n) . (^. #name)) rows)
          byName "cleanup" ^. #app @?= "notes"
          byName "cleanup" ^. #schedule @?= "0 3 * * *"
          byName "cleanup" ^. #active @?= 0
          byName "nightly-report" ^. #app @?= "-"
          byName "nightly-report" ^. #lastRun @?= "never"
          byName "nightly-report" ^. #active @?= 1
  , testCase "extractTaskRows on empty shape is Right []" $
      extractTaskRows "{\"items\":[]}" @?= Right []
  , testCase "formatTaskTable empty prints the placeholder" $
      formatTaskTable [] @?= "(no scheduled tasks)\n"
  ]

taskRunTests :: [TestTree]
taskRunTests =
  [ testCase "oneOffJobName is deterministic and prefixed" $
      oneOffJobName "cleanup" fixedTime
        @?= "nagare-task-cleanup-manual-20260610030012"
  , testCase "oneOffJobName lower-cases and truncates to 63 chars" $
      let n = oneOffJobName (T.replicate 80 "A") fixedTime
       in (T.length n <= 63 && n == T.toLower n) @?= True
  , testCase "runArgs builds the --from=cronjob create-job vector" $
      runArgs "personal" "cleanup" "nagare-task-cleanup-manual-20260610030012"
        @?= [ "create"
            , "job"
            , "nagare-task-cleanup-manual-20260610030012"
            , "--from=cronjob/nagare-task-cleanup"
            , "-n"
            , "personal"
            ]
  , testCase "taskLogArgs scopes by app and honours --tail/--follow" $
      taskLogArgs
        TaskLogTarget
          { namespace = "personal"
          , task = "cleanup"
          , scope = App "notes"
          , follow = True
          , tail = Just 20
          }
        @?= [ "logs"
            , "-l"
            , "nagare.dev/task=cleanup,nagare.dev/app=notes"
            , "-n"
            , "personal"
            , "--tail"
            , "20"
            , "--follow"
            ]
  , testCase "taskLogArgs NoApp uses the not-exists term, no tail/follow" $
      taskLogArgs
        TaskLogTarget
          { namespace = "personal"
          , task = "nightly-report"
          , scope = NoApp
          , follow = False
          , tail = Nothing
          }
        @?= [ "logs"
            , "-l"
            , "nagare.dev/task=nightly-report,!nagare.dev/app"
            , "-n"
            , "personal"
            ]
  , testCase "grafanaHint embeds the EP-49-verified LogsQL field" $
      grafanaHint "cleanup"
        @?= "For older runs, query VictoriaLogs in Grafana with: kubernetes.pod_labels.nagare.dev/task:=\"cleanup\""
  ]
  where
    fixedTime = UTCTime (fromGregorian 2026 6 10) (secondsToDiffTime (3 * 3600 + 12))

-- MasterPlan 10, EP-52: deploy-time image/env resolution for app-associated tasks.

taskResolveTests :: [TestTree]
taskResolveTests =
  [ testCase "inheriting task uses the app's resolved image:tag verbatim" $
      resolveTaskImage appImg tag inheritTask @?= "gcr.io/myproject/notes:20260602-120000"
  , testCase "explicit-image task is pinned to the deploy tag" $
      resolveTaskImage appImg tag ownImageTask @?= "gcr.io/myproject/other:20260602-120000"
  , testCase "predefined env keys for an app task" $
      Set.fromList (map envNameText (Map.keys (predefinedTaskEnv inheritTask)))
        @?= Set.fromList ["NAGARE_TASK_NAME", "NAGARE_NAMESPACE", "NAGARE_APP"]
  , testCase "standalone task gets no NAGARE_APP" $
      Map.member (unsafe (mkEnvName "NAGARE_APP")) (predefinedTaskEnv ownImageTask) @?= False
  , testCase "resolved CronJob shows tag, both envFrom, app label, NAGARE_RUN_ID" $ do
      let yaml = renderResolvedTask appImg tag withPredef inheritTask
      assertInfix "image: gcr.io/myproject/notes:20260602-120000" yaml
      assertInfix "nagare-env-notes-runtime" yaml
      assertInfix "nagare-secret-notes-runtime" yaml
      assertInfix "nagare.dev/app: notes" yaml
      assertInfix "NAGARE_TASK_NAME" yaml
      assertInfix "NAGARE_RUN_ID" yaml
      assertInfix "metadata.name" yaml
  , goldenVsString
      "renderResolvedTask app-associated"
      "test/golden/task-app-resolved.cronjob.yaml"
      (pure (LBS.fromStrict (renderResolvedTask appImg tag withPredef inheritTask)))
  ]
  where
    appImg = "gcr.io/myproject/notes:20260602-120000"
    tag = "20260602-120000"
    withPredef tk = tk & #env .~ mergeGenerated (predefinedTaskEnv tk) (tk ^. #env)
    assertInfix needle hay =
      assertBool
        ("expected " <> show needle <> " in:\n" <> T.unpack (TE.decodeUtf8 hay))
        (needle `T.isInfixOf` TE.decodeUtf8 hay)
    inheritTask =
      unsafe $
        mkTask
          Task
            { name = unsafe (mkServiceName "sync")
            , logicalKey = Nothing
            , namespace = unsafe (mkNamespace "personal")
            , schedule = unsafe (mkSchedule "*/15 * * * *")
            , image = Nothing
            , app = Just (unsafe (mkServiceName "notes"))
            , command = ["python", "manage.py", "sync"]
            , args = []
            , env = Map.empty
            , resources = Nothing
            , timeoutSeconds = Nothing
            , concurrencyPolicy = Forbid
            , restartPolicy = Never
            , backoffLimit = 2
            , successfulJobsHistoryLimit = 3
            , failedJobsHistoryLimit = 1
            , startingDeadlineSeconds = Nothing
            }
    ownImageTask =
      unsafe $
        mkTask
          ( inheritTask
              & #image
              .~ Just (unsafe (mkImageRef "gcr.io/myproject/other"))
              & #app
              .~ Nothing
          )
