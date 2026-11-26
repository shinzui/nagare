-- | EP-283 M4: a workload binds an app object bucket only through an accepted
-- grant, and a bound standalone worker gets the bucket's variables, its own
-- credential Secret and an ordering edge after the Job that granted it.
module ObjectBucketBindingSpec (objectBucketBindingTests) where

import Control.Monad (forM_)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import InventoryTransactionSpec (fixtureBinding)
import ManagedEnvScopeSpec (input, scopedApp, workloadObjects)
import Nagare.App.Deploy (RolloutEnv (..))
import Nagare.Dsl.ObjectBucket
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (webWorker)
import Nagare.Inventory.Application (ApplicationScopeInput (..), DatabaseBinding, acceptedBucketBindings, compileApplicationDeployment, compileStandaloneWorkerWithDependencies)
import Nagare.Inventory.ObjectBucket (boundBy, bucketUser)
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Test.Support.Profiles (tnbProfile)
import ObjectBucketSpec (apiGrant, compile, gatewayGrant, located, member, publications)
import Test.Tasty
import Test.Tasty.HUnit

objectBucketBindingTests :: TestTree
objectBucketBindingTests =
  testGroup
    "bucket binding"
    [ testCase "a granted worker gets the bucket's variables from its own Secret and waits for its grant" $ do
        (snapshot, native) <- accepted
        bindings <- either (assertFailure . T.unpack) pure (acceptedBucketBindings snapshot native testCluster "personal" (service "content-gateway") [binding "publications"])
        Map.keys bindings @?= [ok (Dsl.mkDatabaseName "bucket-publications")]
        (scope, compiled) <- either (assertFailure . show) pure (compileWorker "content-gateway" [binding "publications"] bindings)
        let deployment = deploymentOf compiled
            env = envOf (snd deployment)
            fromSecret key = Just (Left ("nagare-bucket-publications-content-gateway", key))
        Map.lookup "NAGARE_BUCKET_PUBLICATIONS_BACKEND" env @?= Just (Right "s3")
        Map.lookup "NAGARE_BUCKET_PUBLICATIONS_NAME" env @?= Just (Right "nagare-app-publications")
        Map.lookup "NAGARE_BUCKET_PUBLICATIONS_ENDPOINT" env @?= Just (Right "http://minio.nagare-system.svc.cluster.local:9000")
        Map.lookup "NAGARE_BUCKET_PUBLICATIONS_ACCESS_KEY_ID" env @?= fromSecret "AWS_ACCESS_KEY_ID"
        Map.lookup "NAGARE_BUCKET_PUBLICATIONS_SECRET_ACCESS_KEY" env @?= fromSecret "AWS_SECRET_ACCESS_KEY"
        let grantJob = member ("grant-" <> T.drop 14 gatewayUser) native ^. #identity
            credential = member ("credential-" <> T.drop 14 gatewayUser) native ^. #identity
            after = [producer | OrderedAfter producer <- fst deployment ^. #dependencies]
        assertBool "the worker is ordered after its grant Job" (grantJob `elem` after)
        assertBool "the worker is ordered after its credential" (credential `elem` after)
        -- The scope's own members are the worker's; the bucket's stay in the bucket scope.
        assertBool "the worker scope holds no bucket member" (all ((== scopeId scope) . (^. #owner) . fst) (Map.elems compiled))
    , testCase "a workload the bucket does not grant, and a bucket that is not accepted, are refused" $ do
        (snapshot, native) <- accepted
        acceptedBucketBindings snapshot native testCluster "personal" (service "stranger") [binding "publications"]
          @?= Left "bucket-grant-missing: bucket publications grants no access to workload stranger in namespace personal"
        acceptedBucketBindings snapshot native testCluster "elsewhere" (service "content-gateway") [binding "publications"]
          @?= Left "bucket-grant-missing: bucket publications grants no access to workload content-gateway in namespace elsewhere"
        acceptedBucketBindings snapshot native testCluster "personal" (service "content-gateway") [binding "drafts"]
          @?= Left "bucket-grant-missing: bucket drafts is not an accepted bucket; plan and apply it first with nagarectl bucket plan"
        acceptedBucketBindings snapshot native testCluster "personal" (service "content-gateway") [binding "publications", binding "publications"]
          @?= Left "bucket bindings repeat a bucket"
    , testCase "a binding without its accepted grant does not compile" $
        either (map (^. #message) . NE.toList) (const []) (compileWorker "content-gateway" [binding "publications"] Map.empty)
          @?= ["database dependencies must cover exactly the workload bindings"]
    , testCase "a worker that binds no bucket names no bucket Secret" $ do
        (_, compiled) <- either (assertFailure . show) pure (compileWorker "content-gateway" [] Map.empty)
        assertBool "no bucket name in the manifest" (not (any (BS.isInfixOf "nagare-bucket-" . snd) (Map.elems compiled)))
        assertBool "no bucket variable in the manifest" (not (any (BS.isInfixOf "NAGARE_BUCKET_" . snd) (Map.elems compiled)))
    , testCase "an Application's service and worker each bind the bucket through their own grant" $ do
        let app = scopedApp Dsl.NoManagedEnv & #service %~ fmap (#buckets .~ [binding "publications"]) & #workers %~ map (#buckets .~ [binding "publications"])
            granted = publications & #grants .~ [apiGrant & #workload .~ service "scoped-web", gatewayGrant & #workload .~ service "scoped-worker"]
        (bucketScope, native) <- either (assertFailure . show) pure (compile [] granted)
        let snapshot = snapshotOf [bucketScope]
            resolve workload' = (service workload',) <$> acceptedBucketBindings snapshot native testCluster "personal" (service workload') [binding "publications"]
        bindings <- either (assertFailure . T.unpack) (pure . Map.fromList) (traverse resolve ["scoped-web", "scoped-worker"])
        (scopes, compiled) <- either (assertFailure . show) pure (compileApplicationDeployment ((input app) {scopeBucketBindings = bindings}))
        let objects = workloadObjects scopes compiled
            secretOf kind = [Map.lookup "NAGARE_BUCKET_PUBLICATIONS_SECRET_ACCESS_KEY" (envOf bytes) | (objectKind, _, bytes) <- objects, objectKind == kind]
        secretOf "service" @?= [Just (Left ("nagare-bucket-publications-scoped-web", "AWS_SECRET_ACCESS_KEY"))]
        secretOf "deployment" @?= [Just (Left ("nagare-bucket-publications-scoped-worker", "AWS_SECRET_ACCESS_KEY"))]
        [Map.lookup "NAGARE_BUCKET_PUBLICATIONS_NAME" (envOf bytes) | (objectKind, _, bytes) <- objects, objectKind `elem` ["service", "deployment"]]
          @?= [Just (Right "nagare-app-publications"), Just (Right "nagare-app-publications")]
        -- The hook binds nothing, so it gets no bucket variable.
        assertBool "the hook names no bucket" (not (any (\(objectKind, _, bytes) -> objectKind `elem` ["cronjob", "job"] && BS.isInfixOf "NAGARE_BUCKET_" bytes) objects))
        -- Each workload depends on its own credential, which is how a retirement sees the bucket is bound.
        let credentialOf workload' = head [resource ^. #identity | (resource, _) <- Map.elems native, located resource == ("secret", "personal", "nagare-bucket-publications-" <> workload')]
        forM_ [("service", "scoped-web"), ("deployment", "scoped-worker")] $ \(kind, workload') ->
          assertBool (T.unpack workload' <> " is ordered after its credential") (any (\(objectKind, resource, _) -> objectKind == kind && OrderedAfter (credentialOf workload') `elem` resource ^. #dependencies) objects)
        assertBool "the bucket is bound" (not (null (boundBy (snapshotOf (bucketScope : scopes)) bucketScope)))
    , testCase "an Application workload that binds a bucket without its accepted grant does not compile" $ do
        let app = scopedApp Dsl.NoManagedEnv & #workers %~ map (#buckets .~ [binding "publications"])
        either (map (^. #message) . NE.toList) (const []) (compileApplicationDeployment (input app))
          @?= ["database dependencies must cover exactly the workload bindings"]
        (bucketScope, native) <- either (assertFailure . show) pure (compile [] publications)
        bound <- either (assertFailure . T.unpack) pure (acceptedBucketBindings (snapshotOf [bucketScope]) native testCluster "personal" (service "content-gateway") [binding "publications"])
        either (map (^. #message) . NE.toList) (const []) (compileApplicationDeployment ((input (scopedApp Dsl.NoManagedEnv)) {scopeBucketBindings = Map.singleton (service "content-gateway") bound}))
          @?= ["bucket or key set dependencies name a workload that binds neither"]
    ]
  where
    gatewayUser = bucketUser (publications ^. #name) (gatewayGrant ^. #namespace) (gatewayGrant ^. #workload)

-- | The accepted bucket scope and its native objects.
accepted :: IO (ScopeSnapshot, Map ResourceId (ManagedResource, ByteString))
accepted = do
  (scope, native) <- either (assertFailure . show) pure (compile [] publications)
  pure (snapshotOf [scope], native)

snapshotOf :: [ScopeDeclaration] -> ScopeSnapshot
snapshotOf scopes = ok (mkScopeSnapshot fixtureBinding (Map.fromList [(scopeId scope, (ok (mkScopeGeneration 1), scope)) | scope <- scopes]) Map.empty)

compileWorker :: Text -> [Dsl.BucketBinding] -> Map Dsl.DatabaseName DatabaseBinding -> Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileWorker name buckets bindings =
  compileStandaloneWorkerWithDependencies
    (ok (mkScopeId Standalone ("worker-" <> name)))
    (either error id (webWorker name "registry.example.com/content") & #buckets .~ buckets)
    RolloutEnv
      { appName = name
      , qualifiedImage = ok (Dsl.mkImageRef "registry.example.com/content")
      , imageTag = "v1"
      , effectiveTag = "v1"
      , taggedAppImage = "registry.example.com/content:v1"
      , appEnv = Map.empty
      , namespace = "personal"
      , baseDomain = "apps.example.com"
      , targetProfile = tnbProfile
      }
    testCluster
    (mintResourceId (ok (mkScopeId Platform "foundation")) (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-personal")))
    (mintResourceId (ok (mkScopeId Platform "foundation")) (ok (mkLogicalKey "image")) (ok (mkName "publication")))
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    bindings
    (SourceLocation "test" "worker")

testCluster :: ResourceId
testCluster = mintResourceId (ok (mkScopeId Platform "cluster")) (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

service :: Text -> Dsl.ServiceName
service = ok . Dsl.mkServiceName

binding :: Text -> Dsl.BucketBinding
binding = Dsl.BucketBinding . ok . mkBucketName

-- | The worker's Deployment.
deploymentOf :: Map ResourceId (ManagedResource, ByteString) -> (ManagedResource, ByteString)
deploymentOf native = case [pair | pair@(resource, _) <- Map.elems native, let (kind, _, _) = located resource, kind == "deployment"] of
  [found] -> found
  other -> error ("deployments: " <> show (map (located . fst) other))

-- | A container's env: a literal value, or the Secret and key it is read from.
envOf :: ByteString -> Map Text (Either (Text, Text) Text)
envOf bytes =
  Map.fromList
    [ (name, value)
    | Right manifest <- [Yaml.decodeEither' bytes :: Either Yaml.ParseException Value]
    , container <- at ["spec", "template", "spec", "containers"] manifest >>= list
    , Object entry <- at ["env"] container >>= list
    , Just (String name) <- [KM.lookup "name" entry]
    , value <- case (KM.lookup "value" entry, KM.lookup "valueFrom" entry) of
        (Just (String literal), _) -> [Right literal]
        (_, Just from) -> [Left (secret, key) | Object ref <- at ["secretKeyRef"] from, Just (String secret) <- [KM.lookup "name" ref], Just (String key) <- [KM.lookup "key" ref]]
        _ -> []
    ]
  where
    list = \case
      Array found -> foldr (:) [] found
      _ -> []
    at keys value = foldl (\found key -> [next | Object object' <- found, Just next <- [KM.lookup key object']]) [value] keys

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
