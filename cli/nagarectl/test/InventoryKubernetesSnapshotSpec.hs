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
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.KubernetesRuntime (objectReadArguments)
import Nagare.Inventory.KubernetesSnapshot (snapshotAnswers, snapshotRuntime)
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
              modifyIORef requests (<> [request ^. #arguments])
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
        seen
          @?= [ ["get", "clusterrole.rbac.authorization.k8s.io", "reader", "-o", "json", "--ignore-not-found"]
              , ["get", "configmap", "settings", "--namespace", "apps", "-o", "json", "--ignore-not-found"]
              , ["get", "deployment.apps", "web", "worker", "--namespace", "apps", "-o", "json", "--ignore-not-found"]
              ]
    , testCase "an unknown kind fails each member as it fails one read" $ do
        let failed = Right (ExitFailure 1, "", "error: the server doesn't have a resource type \"widgets\"")
        Map.elems (snapshotAnswers [("web", single web), ("worker", single worker)] failed) @?= [failed, failed]
    , testCase "any other answer leaves the members to their own reads" $ do
        requests <- newIORef (0 :: Int)
        let cluster request = do
              modifyIORef requests (+ 1)
              pure $ case request ^. #arguments of
                "get" : "deployment.apps" : "web" : "worker" : _ -> Right (ExitFailure 1, "", "Unable to connect to the server")
                _ -> Right (ExitSuccess, BLC.unpack (encode (item "web")), "")
        runtime <- snapshotRuntime (fake cluster) [web, worker]
        answer <- invokeKubectl runtime (single web) ""
        named answer @?= Just "web"
        readIORef requests >>= (@?= 2)
        snapshotAnswers [("web", single web)] (Right (ExitSuccess, "not json", "")) @?= Map.empty
        snapshotAnswers [("web", single web)] (Left "could not invoke kubectl") @?= Map.empty
    ]
  where
    web = deployment "web"
    worker = deployment "worker"
    deployment = Kubernetes cluster "apps" (known "deployment") (Just (known "apps")) . known
    settings = Kubernetes cluster "" (known "configmap") (Just (known "apps")) (known "settings")
    reader = Kubernetes cluster "rbac.authorization.k8s.io" (known "clusterrole") Nothing (known "reader")
    cluster = ok (mkResourceId "cluster")
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
