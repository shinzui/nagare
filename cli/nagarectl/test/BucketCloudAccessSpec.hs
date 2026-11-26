-- | EP-284 M1: the derived config that federates each bucket grant's workload.
module BucketCloudAccessSpec (bucketCloudAccessTests) where

import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Dsl.ObjectBucket
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkNamespace, mkServiceName)
import Nagare.Inventory.BucketCloudAccess
import ObjectBucketSpec (apiGrant, compile, gatewayGrant, publications)
import Test.Tasty
import Test.Tasty.HUnit

bucketCloudAccessTests :: TestTree
bucketCloudAccessTests =
  testGroup
    "bucket cloud access"
    [ testCase "a bucket's Google name is project, context and name, and a long one ends in a digest" $ do
        googleBucketName "tan-nb-exp" "ep285" (publications ^. #name) @?= "tan-nb-exp-ep285-publications"
        let longName bucket = googleBucketName "a-very-long-project-identifier-x" "a-rather-long-context-name" (ok (mkBucketName bucket))
            long = longName "publications"
        assertBool (T.unpack long) (T.length long <= 63)
        assertBool "two long names differ" (long /= longName "publicationz")
    , testCase "a grant's account is one per workload, 30 characters, and its subject is the workload's account" $ do
        let account = grantAccountId (apiGrant ^. #namespace) (apiGrant ^. #workload)
        T.length account @?= 30
        assertBool (T.unpack account) ("nagare-wl-" `T.isPrefixOf` account)
        assertBool "two workloads share an account" (account /= grantAccountId (gatewayGrant ^. #namespace) (gatewayGrant ^. #workload))
        grantAccountId (ok (mkNamespace "other")) (apiGrant ^. #workload) /= account @?= True
        grantSubject (apiGrant ^. #namespace) (apiGrant ^. #workload) @?= "system:serviceaccount:personal:nagare-wl-content-app"
        grantAccountEmail "tan-nb-exp" (apiGrant ^. #namespace) (apiGrant ^. #workload) @?= account <> "@tan-nb-exp.iam.gserviceaccount.com"
    , testCase "no bucket derives no key; a bucket derives both, and needs the cluster's issuer and JWKS" $ do
        appBucketConfigKeys "tan-nb-exp" "ep285" Nothing [] @?= Right []
        assertBool "a bucket without federation inputs was accepted" (either (const True) (const False) (appBucketConfigKeys "tan-nb-exp" "ep285" Nothing [publications]))
        keys <- either (assertFailure . T.unpack) pure (appBucketConfigKeys "tan-nb-exp" "ep285" (Just ("https://kubernetes.default.svc.cluster.local", jwks)) [publications])
        map fst keys @?= ["nagare:appBuckets", "nagare:workloadIdentity"]
        buckets <- decoded "nagare:appBuckets" keys
        case buckets of
          Array found | [Object bucket] <- V.toList found -> do
            KM.lookup "bucket" bucket @?= Just (String "tan-nb-exp-ep285-publications")
            KM.lookup "retired" bucket @?= Just (Bool False)
            KM.lookup "expire" bucket @?= Just (toArray [object ["prefix" .= ("staging/" :: Text), "afterDays" .= (1 :: Int)]])
            case KM.lookup "grants" bucket of
              Just (Array grants) -> do
                length grants @?= 2
                [g | Object g <- foldr (:) [] grants, KM.lookup "access" g == Just (String "read-write"), KM.lookup "signUrls" g == Just (Bool True), KM.lookup "subject" g == Just (String "system:serviceaccount:personal:nagare-wl-content-app")] /= [] @?= True
              other -> assertFailure (show other)
          other -> assertFailure (show other)
        identity <- decoded "nagare:workloadIdentity" keys
        identity @?= object ["issuer" .= ("https://kubernetes.default.svc.cluster.local" :: Text), "jwks" .= jwks]
    , testCase "a retired bucket is kept, retired, with no grant" $ do
        keys <- either (assertFailure . T.unpack) pure (appBucketConfigKeys "tan-nb-exp" "ep285" (Just ("https://issuer", jwks)) [publications & #grants .~ []])
        buckets <- decoded "nagare:appBuckets" keys
        case buckets of
          Array found | [Object bucket] <- V.toList found -> do
            KM.lookup "retired" bucket @?= Just (Bool True)
            KM.lookup "grants" bucket @?= Just (toArray [])
          other -> assertFailure (show other)
    , testCase "cloudAppBuckets reads the accepted bucket scopes" $ do
        (scope, _) <- either (assertFailure . show) pure (compile [] publications)
        map (^. #name) (cloudAppBuckets [scope]) @?= [publications ^. #name]
    ]
  where
    jwks = object ["keys" .= [object ["kty" .= ("RSA" :: Text), "kid" .= ("k" :: Text)]]]
    decoded key keys = case lookup key keys of
      Just text -> either (\e -> assertFailure e >> pure Null) pure (eitherDecodeStrict (TE.encodeUtf8 text))
      Nothing -> assertFailure ("no " <> T.unpack key) >> pure Null
    toArray = Array . V.fromList

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
