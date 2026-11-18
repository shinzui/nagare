-- | EP-269 M2: a release-only pre-deploy hook compiles to the same hook Job and
-- completion proof as its scheduled form, while the application scope accepts
-- its CronJob suspended and records the reviewed @hookTrigger/TASK@ override.
-- A release-only task is refused by every route that does not run it as a hook.
module ReleaseOnlyHookSpec (releaseOnlyHookTests) where

import AppDatabaseSpec (known, testCluster)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import ManagedEnvScopeSpec (input, scopedApp, workloadObjects)
import Nagare.Contract.Project (deployPreview)
import Nagare.Dsl.Application qualified as DslApp
import Nagare.Dsl.Prelude
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task (TaskTrigger (..), releaseHook)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Application
  ( ApplicationScopeInput (..)
  , compileApplicationDeployment
  , compileApplicationTasks
  , compileStandaloneService
  , hookTriggerOverrides
  )
import Nagare.Inventory.TaskLifecycle (taskSuspended)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

releaseOnlyHookTests :: TestTree
releaseOnlyHookTests =
  testGroup
    "Release-only pre-deploy hook (EP-269)"
    [ testCase "the release-only hook's CronJob is accepted suspended with a schedule that never fires" $ do
        (scopes, native) <- compiled (releaseInput released)
        (cron, bytes) <- hookCron scopes native
        taskSuspended (Just "scoped") cron bytes @?= Right True
        assertBool "release-only CronJob schedule" ("0 0 31 2 *" `BS.isInfixOf` bytes)
        (scheduledScopes, scheduledNative) <- compiled (input scheduled)
        (scheduledCron, scheduledBytes) <- hookCron scheduledScopes scheduledNative
        taskSuspended (Just "scoped") scheduledCron scheduledBytes @?= Right False
    , testCase "the scheduled-to-release-only change keeps the hook scope and Job and changes only the application's CronJob" $ do
        (scheduledScopes0, beforeNative) <- compiled (input scheduled)
        (releasedScopes0, afterNative) <- compiled (releaseInput released)
        case (scheduledScopes0, releasedScopes0) of
          (beforeApp : beforeHooks, afterApp : afterHooks) -> do
            afterHooks @?= beforeHooks
            jobs afterHooks afterNative @?= jobs beforeHooks beforeNative
            assertBool "the hook has a Job" (not (null (jobs afterHooks afterNative)))
            assertBool "config digest unchanged" (scopeConfigDigest beforeApp /= scopeConfigDigest afterApp)
            Map.difference (scopeOverrides afterApp) (scopeOverrides beforeApp) @?= Map.singleton "hookTrigger/scoped-migrate" "release-only"
            Map.difference (scopeOverrides beforeApp) (scopeOverrides afterApp) @?= Map.empty
            (beforeCron, _) <- hookCron scheduledScopes0 beforeNative
            (afterCron, _) <- hookCron releasedScopes0 afterNative
            afterCron ^. #identity @?= beforeCron ^. #identity
            assertBool "CronJob spec unchanged" (afterCron ^. #spec /= beforeCron ^. #spec)
            members beforeApp afterApp @?= [afterCron ^. #identity]
          _ -> assertFailure "expected an application scope and a hook scope"
    , testCase "an identical release-only deploy compiles the same scopes again" $ do
        first' <- compiled (releaseInput released)
        second' <- compiled (releaseInput released)
        fst second' @?= fst first'
    , testCase "only the hook's CronJob and Job reference its maintenance Secret key" $ do
        let isolated =
              released
                & #service
                %~ fmap (#env .~ Map.empty)
                & #workers
                %~ map (#env .~ Map.empty)
        (scopes, native) <- compiled (releaseInput isolated)
        let objects = workloadObjects scopes native
            references bytes = "MIGRATION_URL" `BS.isInfixOf` bytes || "nagare-secret-scoped-runtime" `BS.isInfixOf` bytes
        [kind | (kind, _, bytes) <- objects, references bytes] @?= ["cronjob", "job"]
        assertBool "service and worker are compiled" (all (`elem` [kind | (kind, _, _) <- objects]) ["service", "deployment"])
    , testCase "the deploy preview shows the trigger override under application.overrides" $ do
        (scopes, _) <- compiled (releaseInput released)
        case scopes of
          appScope : hooks ->
            Map.lookup "hookTrigger/scoped-migrate" (deployPreview appScope hooks ^. #application . #overrides) @?= Just "release-only"
          [] -> assertFailure "no scopes"
    , testCase "a missing, extra or wrong-valued trigger override is refused" $ do
        let withOverrides app f = (input app) {scopeInputOverrides = f (scopeInputOverrides (input app))}
        refusedWith "hookTrigger" (withOverrides released id)
        refusedWith "hookTrigger" (withOverrides scheduled (Map.insert "hookTrigger/scoped-migrate" "release-only"))
        refusedWith "hookTrigger" (withOverrides released (Map.insert "hookTrigger/scoped-migrate" "scheduled"))
        refusedWith "hookTrigger" (withOverrides released (Map.insert "hookTrigger/scoped-migrate" "release-only" . Map.insert "hookTrigger/other" "release-only"))
    , testCase "every route that does not run a hook refuses a release-only task" $ do
        -- An Application's service task: the base compile's mkApplication.
        let serviceTask =
              released
                & #tasks
                .~ []
                & #service
                %~ fmap (#tasks .~ [hook "scoped"])
        refusedWith "release-only" ((input serviceTask) {scopeInputOverrides = scopeInputOverrides (input (released & #tasks .~ []))})
        -- The application task compiler, reached without the hook route.
        expectRefusal "release-only" (compileApplicationTasks released rollout testCluster (scopeNamespace base) (scopeImage base) (scopeEnvSecrets base) source)
        -- A standalone Service's task.
        let service = known (webService "scoped-web" "registry.example.com/scoped") & #tasks .~ [hook "scoped-web"]
            standalone = known (mkScopeId Standalone "scoped-web")
        expectRefusal
          "release-only"
          ( compileStandaloneService
              standalone
              service
              (rollout & #appName .~ "scoped-web")
              testCluster
              (scopeNamespace base)
              (scopeImage base)
              Map.empty
              Map.empty
              Map.empty
              source
          )
    ]
  where
    scheduled = scopedApp Dsl.NoManagedEnv
    released = scheduled & #tasks %~ map (#trigger .~ ReleaseOnly)
    releaseInput app = (input app) {scopeInputOverrides = scopeInputOverrides (input app) <> hookTriggerOverrides app}
    base = input scheduled
    rollout = scopeRollout base
    source = scopeSource base
    hook app = known (releaseHook "scoped-maintenance" app "maintain")
    compiled = either (assertFailure . show) pure . compileApplicationDeployment
    refusedWith needle = expectRefusal needle . compileApplicationDeployment
    jobs scopes native = [bytes | (kind, _, bytes) <- workloadObjects scopes native, kind == "job"]
    members beforeApp afterApp =
      [ resource ^. #identity
      | resource <- managed afterApp
      , resource `notElem` managed beforeApp
      ]
    managed scope = [resource | bundle <- scopeBundles scope, Managed resource <- declarations bundle]

hookCron :: [ScopeDeclaration] -> Map.Map ResourceId (ManagedResource, ByteString) -> IO (ManagedResource, ByteString)
hookCron scopes native = case [(member, bytes) | (kind, member, bytes) <- workloadObjects scopes native, kind == "cronjob"] of
  [found] -> pure found
  other -> assertFailure ("expected one CronJob, found " <> show (length other))

expectRefusal :: (Show a) => T.Text -> Either (NonEmpty InventoryError) a -> Assertion
expectRefusal needle = \case
  Left errors -> assertBool (show errors) (any ((needle `T.isInfixOf`) . (^. #message)) errors)
  Right compiled -> assertFailure ("compiled: " <> take 200 (show compiled))
