module AppDeployPhaseSpec (phaseTests) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.App.Deploy (Phase (..), PhaseResult (..), RolloutEnv, phaseTag, planPhases, renderServiceObjects, renderWorkerObjects, runPhases)
import Nagare.Dsl.Load (loadApplication)
import Nagare.Dsl.Prelude
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

phaseTests :: FilePath -> RolloutEnv -> [TestTree]
phaseTests fixturePath configured =
  [ testCase "a reviewed digest is the exact Service and worker image despite a display tag" $ do
      app <- loadApplication fixturePath >>= either (fail . show) pure
      service <- maybe (fail "fixture lacks its Service") pure (app ^. #service)
      let reference = "registry.example.test/team/kizashi@sha256:" <> T.replicate 64 "a"
          rollout = configured & #taggedAppImage .~ reference & #imageTag .~ "display-tag"
      serviceObjects <- (either (fail . T.unpack) pure) (renderServiceObjects rollout service)
      workerObjects <- concat <$> traverse ((either (fail . T.unpack) pure) . renderWorkerObjects rollout) (app ^. #workers)
      assertBool "fixture lacks a worker Deployment" (any (BS.isInfixOf "kind: Deployment" . snd) workerObjects)
      forM_ (serviceObjects <> workerObjects) $ \(_, bytes) ->
        when (any (`BS.isInfixOf` bytes) ["kind: Service", "kind: Deployment"]) $ do
          assertBool "workload does not reference accepted digest" (TE.encodeUtf8 ("image: " <> reference) `BS.isInfixOf` bytes)
          assertBool "workload still uses the mutable display tag" (not ("display-tag" `BS.isInfixOf` bytes))
  , testCase "planPhases is hooks, databases, service, workers" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app ->
          map phaseTag (planPhases app) @?= ["hook", "database", "service", "worker"]
  , testCase "a failed hook aborts before any later phase runs" $ do
      ran <- newIORef ([] :: [Text])
      let phases =
            [ PhaseHooks []
            , PhaseDatabases []
            , PhaseWorkers []
            ]
          exec p = do
            modifyIORef' ran (<> [phaseTag p])
            pure $ case p of
              PhaseHooks _ -> PhaseFailed "migration failed"
              _ -> PhaseOk
      result <- runPhases exec phases
      order <- readIORef ran
      result @?= PhaseFailed "migration failed"
      -- only the hook phase ran; databases/workers were never invoked.
      order @?= ["hook"]
  , testCase "all phases run in order when each succeeds" $ do
      result <- loadApplication fixturePath
      case result of
        Left err -> assertFailure ("loadApplication returned Left: " <> show err)
        Right app -> do
          ran <- newIORef ([] :: [Text])
          let exec p = modifyIORef' ran (<> [phaseTag p]) >> pure PhaseOk
          r <- runPhases exec (planPhases app)
          order <- readIORef ran
          r @?= PhaseOk
          order @?= ["hook", "database", "service", "worker"]
  ]
