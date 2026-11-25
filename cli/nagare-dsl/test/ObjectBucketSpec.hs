-- | EP-283 M2: the app object bucket declaration and workload bindings.
module ObjectBucketSpec (objectBucketTests) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy (toStrict)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Nagare.Dsl.Config (encodeApplication, encodeDeployment, encodeObjectBuckets, encodeTask, encodeWorker)
import Nagare.Dsl.Load (LoadError (..), decodeApplication, decodeDeployment, decodeObjectBuckets, decodeTask, decodeWorker, loadApplication, loadObjectBuckets)
import Nagare.Dsl.ObjectBucket
import Nagare.Dsl.Prelude
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (mkNamespace, mkServiceName)
import TaskSpec (appTask)
import Test.Tasty
import Test.Tasty.HUnit
import WorkerSpec (richWorker)

objectBucketTests :: TestTree
objectBucketTests =
  testGroup
    "object bucket"
    [ testCase "a bucket name is a DNS label of at most 30 characters that starts with a letter" $ do
        fmap bucketNameText (mkBucketName "publications") @?= Right "publications"
        fmap bucketNameText (mkBucketName (Text.replicate 30 "a")) @?= Right (Text.replicate 30 "a")
        mapM_
          (\bad -> assertBool (Text.unpack bad) (isLeft (mkBucketName bad)))
          ["", Text.replicate 31 "a", "Publications", "1st", "pub_s", "pubs-", "pub.s"]
    , testCase "an expiry prefix is not empty and ends in /" $ do
        fmap objectPrefixText (mkObjectPrefix "staging/") @?= Right "staging/"
        mapM_ (\bad -> assertBool (Text.unpack bad) (isLeft (mkObjectPrefix bad))) ["", "staging", "/staging/"]
    , testCase "an expiry is at least one day" $ do
        fmap positiveDaysInt (mkPositiveDays 1) @?= Right 1
        mapM_ (\bad -> assertBool (show bad) (isLeft (mkPositiveDays bad))) [0, -1]
    , testCase "two grants for one workload are refused" $
        validateObjectBucket (publications & #grants %~ (<> [readOnly "content-app"]))
          @?= Left "bucket publications grants workload content-app in personal twice"
    , testCase "two rules for one prefix are refused" $
        validateObjectBucket (publications & #expire %~ (<> (publications ^. #expire)))
          @?= Left "bucket publications has two expiry rules for prefix staging/"
    , testCase "the bucket's variables are prefixed with its upper-cased name" $
        fmap bucketEnvPrefix (mkBucketName "user-files") @?= Right "NAGARE_BUCKET_USER_FILES"
    , testCase "a bucket document round-trips" $
        decodeObjectBuckets (toStrict (encodeObjectBuckets [publications, publications & #name .~ ok (mkBucketName "drafts") & #logicalKey .~ Nothing]))
          @?= Right [publications, publications & #name .~ ok (mkBucketName "drafts")]
    , testCase "a bucket declared twice, an unknown access and another kind are refused" $ do
        assertLeftContaining "declared twice" (decodeObjectBuckets (toStrict (encodeObjectBuckets [publications, publications])))
        assertLeftContaining "unknown access" (decodeObjectBuckets "{\"kind\":\"ObjectBuckets\",\"buckets\":[{\"name\":\"p\",\"grants\":[{\"namespace\":\"personal\",\"workload\":\"w\",\"access\":\"admin\"}]}]}")
        decodeObjectBuckets "{\"kind\":\"AppDatabases\",\"appDatabases\":[]}" @?= Left (UnexpectedKind "ObjectBuckets" "AppDatabases")
    , testCase "a bound service, worker and task round-trip" $ do
        let service = ok (webService "content-app" "gcr.io/knative-samples/helloworld-go") & #buckets .~ [binding]
            worker = richWorker & #buckets .~ [binding]
            task = appTask & #buckets .~ [binding]
        decodeDeployment (toStrict (encodeDeployment service)) @?= Right service
        decodeWorker (toStrict (encodeWorker worker)) @?= Right worker
        decodeTask (toStrict (encodeTask task)) @?= Right task
    , testCase "a workload that binds no bucket has no buckets key" $ do
        let service = ok (webService "content-app" "gcr.io/knative-samples/helloworld-go")
        mapM_
          (\bytes -> assertBool "the document names no bucket" (not ("buckets" `BS.isInfixOf` toStrict bytes)))
          [encodeDeployment service, encodeWorker richWorker, encodeTask appTask]
    , testCase "the content-app example declares the bucket its workloads bind" $ do
        buckets <- loadObjectBuckets "../../cluster/examples/content-app/nagare/Buckets.hs" >>= either (assertFailure . show) pure
        buckets @?= [publications]
        app <- loadApplication "../../cluster/examples/content-app/nagare/Config.hs" >>= either (assertFailure . show) pure
        decodeApplication (toStrict (encodeApplication app)) @?= Right app
        let bound = [(workload', b ^. #name) | Just service <- [app ^. #service], let { workload' = service ^. #name }, b <- service ^. #buckets] <> [(worker ^. #name, b ^. #name) | worker <- app ^. #workers, b <- worker ^. #buckets]
        length bound @?= 2
        mapM_
          (\(workload', bucket) -> assertBool (show workload') (isJust (bucketGrantFor (app ^. #namespace) workload' =<< find' bucket buckets)))
          bound
    ]
  where
    find' bucket = foldr (\candidate rest -> if candidate ^. #name == bucket then Just candidate else rest) Nothing
    binding = BucketBinding (ok (mkBucketName "publications"))
    readOnly workload' = BucketGrant {namespace = ok (mkNamespace "personal"), workload = ok (mkServiceName workload'), access = ReadOnly, signUrls = False}
    publications =
      ObjectBucket
        { name = ok (mkBucketName "publications")
        , logicalKey = Nothing
        , expire = [ExpireRule {prefix = ok (mkObjectPrefix "staging/"), afterDays = ok (mkPositiveDays 1)}]
        , grants =
            [ BucketGrant {namespace = ok (mkNamespace "personal"), workload = ok (mkServiceName "content-app"), access = ReadWrite, signUrls = True}
            , readOnly "content-gateway"
            ]
        }

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

assertLeftContaining :: (Show a) => Text -> Either LoadError a -> Assertion
assertLeftContaining needle = \case
  Left err | needle `Text.isInfixOf` Text.pack (show err) -> pure ()
  other -> assertFailure ("expected a refusal containing " <> Text.unpack needle <> ", got " <> show other)
