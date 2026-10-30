-- | EP-185: a status run's snapshot reads each kind and namespace once and
-- answers the single-object reads of observation and the readiness probe.
module InventoryKubernetesSnapshotSpec
  ( inventoryKubernetesSnapshotTests
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Generics.Labels ()
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.KubernetesRuntime (objectReadArguments)
import Nagare.Inventory.KubernetesSnapshot (beginPhase, chunkBytes, newPhaseEpoch, phaseRuntime, snapshotAnswers, snapshotReads, snapshotRuntime)
import Nagare.Inventory.KubernetesTransport (KubectlRequest (..), KubectlResult, KubernetesRuntimeConfig (..), invokeKubectl, runKubectlWith, withKubectlInterpreter)
import Nagare.Resource.Types
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

inventoryKubernetesSnapshotTests :: TestTree
inventoryKubernetesSnapshotTests =
  testGroup
    "kubernetes snapshot"
    [ testCase "one read per kind and namespace answers every single-object read" $ do
        requests <- newIORef []
        let cluster request = do
              atomicModifyIORef' requests (\seen -> (request ^. #arguments : seen, ()))
              pure $ case request ^. #arguments of
                "get" : "deployment.apps" : _ -> Right (ExitSuccess, list [item "web"], "")
                "get" : "configmap" : _ -> Right (ExitSuccess, "", "")
                "get" : "clusterrole.rbac.authorization.k8s.io" : _ -> Right (ExitSuccess, BLC.unpack (encode (item "reader")), "")
                _ -> Right (ExitFailure 1, "", "unexpected request")
        runtime <- snapshotRuntime (fake cluster) [web, worker, settings, reader]
        let read address = invokeKubectl runtime (single address) ""
        webRead <- read web
        _ <- read web
        workerRead <- read worker
        settingsRead <- read settings
        readerRead <- read reader
        named webRead @?= Just "web"
        workerRead @?= Right (ExitSuccess, "", "")
        settingsRead @?= Right (ExitSuccess, "", "")
        named readerRead @?= Just "reader"
        seen <- readIORef requests
        sort seen
          @?= [ ["get", "clusterrole.rbac.authorization.k8s.io", "reader", "-o", "json", "--ignore-not-found"]
              , ["get", "configmap", "settings", "--namespace", "apps", "-o", "json", "--ignore-not-found"]
              , ["get", "deployment.apps", "web", "worker", "--namespace", "apps", "-o", "json", "--ignore-not-found"]
              ]
    , testCase "an unknown kind fails each member as it fails one read" $ do
        let failed = Right (ExitFailure 1, "", "error: the server doesn't have a resource type \"widgets\"")
        Map.elems (snapshotAnswers [("web", single web), ("worker", single worker)] failed) @?= [failed, failed]
    , testCase "a failed grouped read is retried once, then each member is unavailable, never read alone" $ do
        requests <- newIORef (0 :: Int)
        let cluster _ = do
              atomicModifyIORef' requests (\count -> (count + 1, ()))
              pure (Right (ExitFailure 1, "", "Unable to connect to the server"))
        runtime <- snapshotRuntime (fake cluster) [web, worker]
        answers <- traverse (\address -> invokeKubectl runtime (single address) "") [web, worker]
        assertBool "a member of a failed read was answered" (all (either ("grouped read unavailable" `T.isInfixOf`) (const False)) answers)
        readIORef requests >>= (@?= 2)
        snapshotAnswers [("web", single web)] (Right (ExitSuccess, "not json", "")) @?= Map.empty
        snapshotAnswers [("web", single web)] (Left "could not invoke kubectl") @?= Map.empty
    , testCase "several names answered without a List prove nothing" $
        snapshotAnswers [("web", single web), ("worker", single worker)] (Right (ExitSuccess, BLC.unpack (encode (item "web")), "")) @?= Map.empty
    , testCase "unrecognized answers fall back to at most eight single reads per epoch" $ do
        requests <- newIORef []
        let names = ["app-" <> T.pack (show n) | n <- [1 .. 12 :: Int]]
            addresses = [Kubernetes cluster "" (known "configmap") (Just (known ("ns-" <> name))) (known name) | name <- names]
            respond request = do
              atomicModifyIORef' requests (\seen -> (request ^. #arguments : seen, ()))
              pure (Right (ExitSuccess, "not json", ""))
        runtime <- snapshotRuntime (fake respond) addresses
        answers <- traverse (\address -> invokeKubectl runtime (single address) "") addresses
        -- Twelve grouped reads, one per namespace; eight members then read alone.
        length <$> readIORef requests >>= (@?= 20)
        length [() | Left reason <- answers, "fallback is spent" `T.isInfixOf` reason] @?= 4
    , testCase "names are chunked at 128 per read" $ do
        let addresses = [Kubernetes cluster "" (known "configmap") (Just (known "apps")) (known ("member-" <> T.pack (show n))) | n <- [1 .. 300 :: Int]]
        map (length . snd) (snapshotReads addresses) @?= [128, 128, 44]
        let long = [Kubernetes cluster "" (known "configmap") (Just (known "apps")) (known (T.replicate 250 "x" <> T.pack (show n))) | n <- [1 .. 200 :: Int]]
        assertBool "a chunk exceeded 32 KiB of names" (all (\(_, members) -> sum [T.length name + 1 | (name, _) <- members] <= chunkBytes) (snapshotReads long))
    , testCase "an epoch over two clusters refuses every member" $ do
        let other = Kubernetes (clusterNamed "other-cluster") "" (known "configmap") (Just (known "apps")) (known "settings")
            unexpected _ = assertFailure "an epoch over two clusters read the cluster" >> pure (Left "unreachable")
        runtime <- snapshotRuntime (fake unexpected) [settings, other]
        answer <- invokeKubectl runtime (single settings) ""
        assertBool "a mixed-cluster member was answered" (either ("several" `T.isInfixOf`) (const False) answer)
    , testCase "a plan's later reads are answered from the epoch its observation began" $ do
        requests <- newIORef (0 :: Int)
        let cluster _ = do
              atomicModifyIORef' requests (\count -> (count + 1, ()))
              pure (Right (ExitSuccess, list [item "web", item "worker"], ""))
            config = fake cluster
        phase <- newPhaseEpoch
        let runtime = phaseRuntime config phase
        beginPhase config phase [web, worker]
        _ <- traverse (\address -> invokeKubectl runtime (single address) "") [web, worker, web]
        readIORef requests >>= (@?= 1)
        -- The next observation begins a new epoch.
        beginPhase config phase [web]
        readIORef requests >>= (@?= 2)
    ]
  where
    web = deployment "web"
    worker = deployment "worker"
    deployment = Kubernetes cluster "apps" (known "deployment") (Just (known "apps")) . known
    settings = Kubernetes cluster "" (known "configmap") (Just (known "apps")) (known "settings")
    reader = Kubernetes cluster "rbac.authorization.k8s.io" (known "clusterrole") Nothing (known "reader")
    cluster = clusterNamed "cluster"
    clusterNamed key = mintResourceId (ok (mkScopeId Platform "foundation")) (ok (mkLogicalKey key)) (ok (mkName "resource"))
    single = fromMaybe (error "not a Kubernetes address") . objectReadArguments
    known = ok . mkName
    fake :: (KubectlRequest -> IO KubectlResult) -> KubernetesRuntimeConfig
    fake cluster' = withKubectlInterpreter (runKubectlWith cluster') (KubernetesRuntimeConfig (ok (mkContextId "test")) "test" (pure (Right ())))
    item :: Text -> Value
    item name = object ["kind" .= ("Deployment" :: Text), "metadata" .= object ["name" .= name, "uid" .= ("uid-" <> name)]]
    list items = BLC.unpack (encode (object ["kind" .= ("List" :: Text), "items" .= items]))
    named = \case
      Right (ExitSuccess, output, _) -> case eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)) of
        Right (Object root) | Just (Object metadata) <- KM.lookup "metadata" root, Just (String name) <- KM.lookup "name" metadata -> Just name
        _ -> Nothing
      _ -> Nothing
    ok :: (Show e) => Either e a -> a
    ok = either (error . show) id
