-- | EP-181 (RES-4 G3): the pod that blocks a member StatefulSet's rollout.
-- The fixtures follow RES-4's experiments E6e and E6f
-- (docs/audits/k8s-semantics-2026-10-06/experiments/e6e.out).
module InventoryStuckPodSpec (inventoryStuckPodTests) where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Generics.Labels ()
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.KubernetesStuckPod
import Nagare.Inventory.KubernetesTransport (KubectlRequest (..), KubernetesRuntimeConfig (..), runKubectlWith, withKubectlInterpreter)
import Nagare.Resource.Types (PhysicalIdentity, mkPhysicalIdentity)
import Nagare.Test.Model.Fixtures (databaseNative, statefulId)
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

inventoryStuckPodTests :: TestTree
inventoryStuckPodTests =
  testGroup
    "stuck pod"
    [ testCase "observation: E6f's final state (a correction landed over a pod that is not Ready) is stuck" $ do
        found <- expectRight (stuckPod (statefulSet 3 (Just 3) (Just "pg-d9d6d")) (pods [pgPod "pg-0" "pg-9d647" False]))
        fmap (^. #pod) found @?= Just "pg-0"
        fmap (^. #podRevision) found @?= Just "pg-9d647"
        fmap (^. #updateRevision) found @?= Just "pg-d9d6d"
        fmap (^. #podResourceVersion) found @?= Just "rv-pg-0"
        fmap (^. #statefulSetUid) found @?= Just (identity "sts-uid")
    , testCase "observation: the same pod, once Ready, is not stuck" $
        stuckPod (statefulSet 3 (Just 3) (Just "pg-d9d6d")) (pods [pgPod "pg-0" "pg-9d647" True]) @?= Right Nothing
    , testCase "observation: nothing is stuck while the controller has not observed the latest spec" $
        stuckPod (statefulSet 3 (Just 2) (Just "pg-9d647")) (pods [pgPod "pg-0" "pg-9d647" False]) @?= Right Nothing
    , testCase "observation: a broken create (E6e: the pod is at the update revision) is not stuck" $
        stuckPod (statefulSet 1 (Just 1) (Just "pg-9dc98")) (pods [pgPod "pg-0" "pg-9dc98" False]) @?= Right Nothing
    , testCase "observation: a pod being deleted is not stuck" $
        stuckPod (statefulSet 3 (Just 3) (Just "pg-d9d6d")) (pods [terminating (pgPod "pg-0" "pg-9d647" False)]) @?= Right Nothing
    , testCase "observation: a pod the StatefulSet does not control is not stuck" $
        stuckPod (statefulSet 3 (Just 3) (Just "pg-d9d6d")) (pods [podWith "other-uid" "pg-0" (Just "pg-9d647") False False]) @?= Right Nothing
    , testCase "observation: the lowest ordinal is the stuck pod" $ do
        found <- expectRight (stuckPod (statefulSet 3 (Just 3) (Just "pg-d9d6d")) (pods [pgPod "pg-1" "pg-9d647" False, pgPod "pg-0" "pg-9d647" False]))
        fmap (^. #pod) found @?= Just "pg-0"
    , testCase "observation: an observed StatefulSet without updateRevision is an error, not 'not stuck'" $
        assertLeft (stuckPod (statefulSet 3 (Just 3) Nothing) (pods [pgPod "pg-0" "pg-9d647" False]))
    , testCase "observation: a controlled pod without a revision label is an error, not 'not stuck'" $
        assertLeft (stuckPod (statefulSet 3 (Just 3) (Just "pg-d9d6d")) (pods [podWith "sts-uid" "pg-0" Nothing False False]))
    , testCase "observation: without pod access nothing is ever stuck" $
        readStuckPod noPodOps (error "noPodOps reads no resource") >>= (@?= Right Nothing)
    , testCase "runtime: a Ready StatefulSet costs one read and no pod list" $ do
        (found, requests) <- runtimeRead (Right ()) (readyStatefulSet, pods [])
        found @?= Right Nothing
        map (take 2) requests @?= [["get", "statefulset.apps"]]
    , testCase "runtime: a StatefulSet that is not Ready lists its pods by its selector" $ do
        (found, requests) <- runtimeRead (Right ()) (statefulSet 3 (Just 3) (Just "pg-d9d6d"), pods [pgPod "pg-0" "pg-9d647" False])
        fmap (fmap (^. #pod)) found @?= Right (Just "pg-0")
        requests @?= [["get", "statefulset.apps", "pg", "--namespace", "personal", "-o", "json", "--ignore-not-found"], ["get", "pods", "--namespace", "personal", "-l", "app=pg", "-o", "json"]]
    , testCase "runtime: a refusing cluster guard reads nothing" $ do
        (found, requests) <- runtimeRead (Left "wrong cluster") (readyStatefulSet, pods [])
        either (const (pure ())) (\value -> assertFailure ("read past the guard: " <> show value)) found
        requests @?= []
    ]

-- | Read the database fixture's stuck pod through a stubbed kubectl that
-- answers with these objects, and return what was asked.
runtimeRead :: Either Text () -> (Value, Value) -> IO (Either Text (Maybe StuckPod), [[String]])
runtimeRead guard' (set, listed) = do
  asked <- newIORef []
  let answer request = do
        modifyIORef' asked (<> [request ^. #arguments])
        pure $ case request ^. #arguments of
          "get" : "statefulset.apps" : _ -> Right (ExitSuccess, BLC.unpack (encode set), "")
          "get" : "pods" : _ -> Right (ExitSuccess, BLC.unpack (encode listed), "")
          other -> Left ("unexpected kubectl call " <> T.pack (show other))
      config = withKubectlInterpreter (runKubectlWith answer) (KubernetesRuntimeConfig (fixtureBinding ^. #identity) "stuck-pod" (pure guard'))
  found <- readStuckPod (runtimePodOps config databaseNative) statefulId
  (found,) <$> readIORef asked

readyStatefulSet :: Value
readyStatefulSet =
  object
    [ "apiVersion" .= ("apps/v1" :: Text)
    , "kind" .= ("StatefulSet" :: Text)
    , "metadata" .= object ["name" .= ("pg" :: Text), "namespace" .= ("personal" :: Text), "uid" .= ("sts-uid" :: Text), "generation" .= (2 :: Int)]
    , "spec" .= object ["replicas" .= (1 :: Int), "selector" .= object ["matchLabels" .= object ["app" .= ("pg" :: Text)]]]
    , "status" .= object ["observedGeneration" .= (2 :: Int), "replicas" .= (1 :: Int), "readyReplicas" .= (1 :: Int), "updatedReplicas" .= (1 :: Int), "updateRevision" .= ("pg-d9d6d" :: Text), "currentRevision" .= ("pg-d9d6d" :: Text)]
    ]

statefulSet :: Integer -> Maybe Integer -> Maybe Text -> Value
statefulSet generation observed revision =
  object
    [ "apiVersion" .= ("apps/v1" :: Text)
    , "kind" .= ("StatefulSet" :: Text)
    , "metadata" .= object ["name" .= ("pg" :: Text), "namespace" .= ("personal" :: Text), "uid" .= ("sts-uid" :: Text), "generation" .= generation]
    , "spec" .= object ["replicas" .= (1 :: Int), "selector" .= object ["matchLabels" .= object ["app" .= ("pg" :: Text)]]]
    , "status" .= object (["observedGeneration" .= value | Just value <- [observed]] <> ["updateRevision" .= value | Just value <- [revision]] <> ["replicas" .= (1 :: Int)])
    ]

pods :: [Value] -> Value
pods items = object ["apiVersion" .= ("v1" :: Text), "kind" .= ("List" :: Text), "items" .= items]

pgPod :: Text -> Text -> Bool -> Value
pgPod name revision ready = podWith "sts-uid" name (Just revision) ready False

terminating :: Value -> Value
terminating _ = podWith "sts-uid" "pg-0" (Just "pg-9d647") False True

podWith :: Text -> Text -> Maybe Text -> Bool -> Bool -> Value
podWith owner name revision ready deleting =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Pod" :: Text)
    , "metadata"
        .= object
          ( [ "name" .= name
            , "namespace" .= ("personal" :: Text)
            , "uid" .= ("uid-" <> name)
            , "resourceVersion" .= ("rv-" <> name)
            , "labels" .= object (["app" .= ("pg" :: Text)] <> ["controller-revision-hash" .= value | Just value <- [revision]])
            , "ownerReferences" .= [object ["apiVersion" .= ("apps/v1" :: Text), "kind" .= ("StatefulSet" :: Text), "name" .= ("pg" :: Text), "uid" .= owner, "controller" .= True]]
            ]
              <> ["deletionTimestamp" .= ("2026-10-06T00:00:00Z" :: Text) | deleting]
          )
    , "status" .= object ["phase" .= ("Running" :: Text), "conditions" .= [object ["type" .= ("Ready" :: Text), "status" .= (if ready then "True" else "False" :: Text)]]]
    ]

identity :: Text -> PhysicalIdentity
identity = either (error . show) id . mkPhysicalIdentity

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> error "unreachable") pure

assertLeft :: (Show a) => Either e a -> Assertion
assertLeft = either (const (pure ())) (\found -> assertFailure ("expected an error, got " <> show found))
