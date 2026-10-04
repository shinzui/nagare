-- | Pulumi responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Pulumi
  ( pulumiBackendBootstrapTests
  )
where

import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Ops.PulumiBackend
  ( GcloudOps (..)
  , bootstrapCommands
  , bootstrapPulumiStateBucketWith
  , bucketCreateArgs
  , bucketOwnershipVerdict
  , bucketProjectNumberArgs
  , bucketUpdateArgs
  , gcsBucketOfUrl
  , projectNumberArgs
  , pulumiStateBucket
  , readProjectNumber
  )
import Nagare.Target
  ( InventoryStoreKind (InventoryStoreGcs)
  , PulumiBackendKind (PulumiBackendGcs)
  )
import Nagare.Test.Support.Profiles (initProfile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

pulumiBackendBootstrapTests :: TestTree
pulumiBackendBootstrapTests =
  testGroup
    "Nagare.Ops.PulumiBackend (EP-93, EP-113)"
    [ testCase "gcsBucketOfUrl parses the bucket out of a gs:// URL" $ do
        gcsBucketOfUrl "gs://acme-prod-nagare-pulumi-state/nagare/labs" @?= Just "acme-prod-nagare-pulumi-state"
        gcsBucketOfUrl "gs://just-a-bucket" @?= Just "just-a-bucket"
        gcsBucketOfUrl "file:///tmp/x" @?= Nothing
        gcsBucketOfUrl "gs://" @?= Nothing
    , testCase "pulumiStateBucket uses the default state bucket for a gcs context" $
        pulumiStateBucket "labs" (initProfile & #pulumiBackend .~ PulumiBackendGcs)
          @?= Just "acme-prod-nagare-pulumi-state"
    , testCase "pulumiStateBucket honors an explicit backend URL's bucket" $
        pulumiStateBucket
          "labs"
          ( initProfile
              & #pulumiBackend
              .~ PulumiBackendGcs
              & #pulumiBackendUrl
              .~ "gs://custom-bucket/state/labs"
          )
          @?= Just "custom-bucket"
    , testCase "inventory-only GCS context bootstraps its state bucket" $ do
        calls <- newIORef ([] :: [[String]])
        let record args = modifyIORef' calls (<> [args])
            ops =
              GcloudOps
                { capture = \args -> do
                    record args
                    pure (Just "12345")
                , execute = \_ args -> record args >> pure (Right ())
                }
            profile = initProfile & #inventoryStore .~ InventoryStoreGcs
        bootstrapPulumiStateBucketWith ops False "labs" profile Nothing >>= (@?= Right ())
        observed <- readIORef calls
        assertBool
          "inventory GCS bucket was checked"
          ( any
              (\args -> take 3 args == ["storage", "buckets", "describe"])
              observed
          )
    , testCase "bucketCreateArgs sets location, uniform access, and public-access prevention" $
        bucketCreateArgs "acme-prod-nagare-pulumi-state" "acme-prod" "us-west1"
          @?= [ "storage"
              , "buckets"
              , "create"
              , "gs://acme-prod-nagare-pulumi-state"
              , "--project=acme-prod"
              , "--location=us-west1"
              , "--uniform-bucket-level-access"
              , "--public-access-prevention"
              ]
    , testCase "bucketUpdateArgs enables versioning idempotently (no retention lock)" $
        bucketUpdateArgs "b"
          @?= ["storage", "buckets", "update", "gs://b", "--versioning", "--uniform-bucket-level-access", "--public-access-prevention"]
    , testCase "bootstrapCommands appends an IAM grant only when a member is given" $ do
        -- create + the two EP-113 project-number reads + update = 4.
        length (bootstrapCommands "b" "p" "us-west1" Nothing) @?= 4
        let withMember = bootstrapCommands "b" "p" "us-west1" (Just "serviceAccount:ci@p.iam.gserviceaccount.com")
        length withMember @?= 5
        last withMember
          @?= [ "storage"
              , "buckets"
              , "add-iam-policy-binding"
              , "gs://b"
              , "--member=serviceAccount:ci@p.iam.gserviceaccount.com"
              , "--role=roles/storage.objectAdmin"
              ]
    , testCase "bucketProjectNumberArgs reads the bucket's owning project number" $
        bucketProjectNumberArgs "acme-prod-nagare-pulumi-state"
          @?= [ "storage"
              , "buckets"
              , "describe"
              , "gs://acme-prod-nagare-pulumi-state"
              , "--raw"
              , "--format=value(projectNumber)"
              ]
    , testCase "projectNumberArgs reads the target project's number" $
        projectNumberArgs "acme-prod"
          @?= ["projects", "describe", "acme-prod", "--format=value(projectNumber)"]
    , testCase "bucketOwnershipVerdict fails closed on absent or differing numbers" $ do
        bucketOwnershipVerdict "b" "p" (Just "999999999999") (Just "999999999999") @?= Right ()
        -- Whitespace around a captured value must not defeat the comparison.
        bucketOwnershipVerdict "b" "p" (Just "999999999999\n") (Just " 999999999999") @?= Right ()
        assertBool "differing numbers refuse" $
          isLeft (bucketOwnershipVerdict "b" "p" (Just "111111111111") (Just "999999999999"))
        assertBool "an absent bucket number refuses" $
          isLeft (bucketOwnershipVerdict "b" "p" Nothing (Just "999999999999"))
        assertBool "an absent target number refuses" $
          isLeft (bucketOwnershipVerdict "b" "p" (Just "999999999999") Nothing)
        assertBool "an empty bucket number refuses" $
          isLeft (bucketOwnershipVerdict "b" "p" (Just "  ") (Just "999999999999"))
        case bucketOwnershipVerdict "b" "acme-prod" (Just "111111111111") (Just "999999999999") of
          Right () -> assertFailure "expected a refusal"
          Left msg -> do
            assertBool "names the bucket" ("gs://b" `T.isInfixOf` msg)
            assertBool "names the observed owner" ("111111111111" `T.isInfixOf` msg)
            assertBool "names the target project" ("acme-prod" `T.isInfixOf` msg)
        case bucketOwnershipVerdict "b" "acme-prod" Nothing (Just "999999999999") of
          Right () -> assertFailure "expected a refusal"
          Left msg -> do
            assertBool "reports the unreadable number" ("<unknown>" `T.isInfixOf` msg)
            assertBool "says the read failed, not that the bucket is foreign" ("could not read" `T.isInfixOf` msg)
    , testCase "one failed project-number read is retried before the guard refuses (F50)" $ do
        answers <- newIORef [Nothing, Just "882581411903\n"]
        pauses <- newIORef []
        let capture _ = do
              next <- readIORef answers
              case next of
                (a : rest) -> modifyIORef' answers (const rest) >> pure a
                [] -> pure Nothing
        number <- readProjectNumber (\n -> modifyIORef' pauses (n :)) capture (projectNumberArgs "tan-ng-labs")
        number @?= Just "882581411903"
        readIORef pauses >>= (@?= [1])
        calls <- newIORef (0 :: Int)
        missing <- readProjectNumber (const (pure ())) (\_ -> modifyIORef' calls (+ 1) >> pure Nothing) (projectNumberArgs "p")
        missing @?= Nothing
        readIORef calls >>= (@?= 3)
    , testCase "bootstrap refuses a foreign bucket before update or IAM" $ do
        (result, calls) <-
          runFakeBootstrap (Just "111111111111") (Just "999999999999")
        case result of
          Right () -> assertFailure "expected a refusal for a foreign bucket"
          Left msg -> assertBool "refusal message" ("refusing: gs://" `T.isInfixOf` msg)
        -- The point of the test: no mutation was ATTEMPTED, not merely that an
        -- error came back.
        assertBool "no buckets update was attempted" (not (any (isPrefix ["storage", "buckets", "update"]) calls))
        assertBool
          "no IAM binding was attempted"
          (not (any (isPrefix ["storage", "buckets", "add-iam-policy-binding"]) calls))
    , testCase "bootstrap refuses when the bucket's project number is unreadable" $ do
        (result, calls) <- runFakeBootstrap Nothing (Just "999999999999")
        assertBool "unreadable number refuses" (isLeft result)
        assertBool "no buckets update was attempted" (not (any (isPrefix ["storage", "buckets", "update"]) calls))
    , testCase "bootstrap proceeds to update and IAM when the numbers match" $ do
        (result, calls) <- runFakeBootstrap (Just "999999999999") (Just "999999999999")
        result @?= Right ()
        let mutations =
              [ c
              | c <- calls
              , isPrefix ["storage", "buckets", "update"] c
                  || isPrefix ["storage", "buckets", "add-iam-policy-binding"] c
              ]
        map (take 3) mutations
          @?= [ ["storage", "buckets", "update"]
              , ["storage", "buckets", "add-iam-policy-binding"]
              ]
    ]
  where
    isPrefix p xs = take (length p) xs == p
    -- Drive the real bootstrap sequence through a recording fake gcloud, so a
    -- test can assert on which commands were ATTEMPTED. The bucket exists (the
    -- describe probe answers), which is the dangerous case: the create is
    -- skipped and only the ownership assertion stands between the operator and a
    -- foreign bucket's reconfiguration.
    runFakeBootstrap mBucketNumber mTargetNumber = do
      ref <- newIORef ([] :: [[String]])
      let record args = modifyIORef' ref (<> [args])
          capture args = do
            record args
            pure $ case args of
              ("storage" : "buckets" : "describe" : _ : "--raw" : "--format=value(projectNumber)" : _) -> mBucketNumber
              ("storage" : "buckets" : "describe" : _) -> Just "acme-prod-nagare-pulumi-state"
              ("projects" : "describe" : _) -> mTargetNumber
              _ -> Nothing
          execute _ args = record args >> pure (Right ())
          ops = GcloudOps {capture = capture, execute = execute}
          gcsProfile = initProfile & #pulumiBackend .~ PulumiBackendGcs
      result <-
        bootstrapPulumiStateBucketWith
          ops
          False
          "labs"
          gcsProfile
          (Just "serviceAccount:ci@acme-prod.iam.gserviceaccount.com")
      calls <- readIORef ref
      pure (result, calls)
