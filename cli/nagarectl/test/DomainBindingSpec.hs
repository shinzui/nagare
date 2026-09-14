module DomainBindingSpec (domainBindingTests) where

import Data.ByteString.Char8 qualified as BC
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Nagare.Domain.Binding
import Nagare.Dsl.Prelude
import Test.Tasty
import Test.Tasty.HUnit

domainBindingTests :: TestTree
domainBindingTests =
  testGroup
    "Nagare.Domain.Binding"
    [ testCase "extracts cluster claims and all-namespace routes" $
        extractExistingBindings claimJson routeJson
          @?= Right
            [ ExistingClaim "same.example.test" "personal"
            , ExistingClaim "other.example.test" "other"
            , ExistingRoute "same.example.test" "personal" "notes"
            , ExistingRoute "other.example.test" "other" "shop"
            ]
    , testCase "a different claim owner conflicts" $
        bindingConflict target [ExistingClaim "same.example.test" "other"]
          @?= Just (ClaimedByNamespace "other")
    , testCase "a different route owner conflicts" $
        bindingConflict target [ExistingRoute "same.example.test" "personal" "other-service"]
          @?= Just (RoutedToService "personal" "other-service")
    , testCase "the intended existing claim and route are idempotent" $
        bindingConflict
          target
          [ ExistingClaim "same.example.test" "personal"
          , ExistingRoute "same.example.test" "personal" "notes"
          ]
          @?= Nothing
    , testCase "conflict performs no apply" $ do
        applications <- newIORef (0 :: Int)
        result <-
          applyAfterPreflight
            ( preflightDomainBindingsWith
                (pure (Right [ExistingClaim "same.example.test" "other"]))
                [target]
            )
            (modifyIORef' applications (+ 1))
        assertLeftContains "claimed by namespace other" result
        readIORef applications >>= (@?= 0)
    , testCase "unreadable ownership performs no apply" $ do
        applications <- newIORef (0 :: Int)
        result <-
          applyAfterPreflight
            (preflightDomainBindingsWith (pure (Left "kubectl unavailable")) [target])
            (modifyIORef' applications (+ 1))
        result @?= Left "kubectl unavailable"
        readIORef applications >>= (@?= 0)
    , testCase "same-owner redeploy applies once" $ do
        applications <- newIORef (0 :: Int)
        result <-
          applyAfterPreflight
            ( preflightDomainBindingsWith
                ( pure
                    ( Right
                        [ ExistingClaim "same.example.test" "personal"
                        , ExistingRoute "same.example.test" "personal" "notes"
                        ]
                    )
                )
                [target]
            )
            (modifyIORef' applications (+ 1))
        result @?= Right ()
        readIORef applications >>= (@?= 1)
    ]

target :: BindingTarget
target = BindingTarget "same.example.test" "personal" "notes"

claimJson :: BC.ByteString
claimJson =
  BC.pack
    "{\"items\":[{\"metadata\":{\"name\":\"same.example.test\"},\"spec\":{\"namespace\":\"personal\"}},{\"metadata\":{\"name\":\"other.example.test\"},\"spec\":{\"namespace\":\"other\"}}]}"

routeJson :: BC.ByteString
routeJson =
  BC.pack
    "{\"items\":[{\"metadata\":{\"name\":\"same.example.test\",\"namespace\":\"personal\"},\"spec\":{\"ref\":{\"name\":\"notes\"}}},{\"metadata\":{\"name\":\"other.example.test\",\"namespace\":\"other\"},\"spec\":{\"ref\":{\"name\":\"shop\"}}}]}"

assertLeftContains :: Text -> Either Text a -> Assertion
assertLeftContains needle (Left message)
  | needle `T.isInfixOf` message = pure ()
  | otherwise = assertFailure ("expected Left containing " <> show needle <> ", got " <> show message)
assertLeftContains needle (Right _) = assertFailure ("expected Left containing " <> show needle <> ", got Right")
