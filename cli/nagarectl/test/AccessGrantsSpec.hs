module AccessGrantsSpec (accessGrantsTests) where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy (ByteString)
import Nagare.Access.Grants
import Test.Tasty
import Test.Tasty.HUnit

accessGrantsTests :: TestTree
accessGrantsTests =
  testGroup
    "Nagare.Access.Grants"
    [ testCase "accessTuple grants app viewer to a shomei user and canonicalizes host" $
        accessTuple "Tools.Example.com." "alice"
          @?= TupleWire
            { object = ObjectRefWire "app" "tools.example.com"
            , relation = "viewer"
            , subject = SubjectIdWire (ObjectRefWire "user" "alice")
            , caveat = Nothing
            }
    , testCase "access tuple JSON matches en-servant byte for byte" $
        encode (accessTuple "Tools.Example.com." "alice")
          @?= "{\"object\":{\"objectType\":\"app\",\"objectId\":\"tools.example.com\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"caveat\":null}"
    , testCase "expand request JSON matches en-servant byte for byte" $
        encode (expandRequest "Tools.Example.com.")
          @?= "{\"consistency\":{\"mode\":\"minimizeLatency\"},\"object\":{\"objectType\":\"app\",\"objectId\":\"tools.example.com\"},\"permission\":\"access\",\"context\":{\"values\":{}},\"limit\":1000,\"cursor\":null}"
    , testCase "collectExpandedSubjects extracts direct users from nested expand output" $ do
        let tree =
              ExpandTreeWire
                { root = ObjectRefWire "app" "tools.example.com"
                , permission = "access"
                , children =
                    [ ExpandUsersetWire
                        (ObjectRefWire "app" "tools.example.com")
                        "viewer"
                        [ ExpandSubjectWire (SubjectIdWire (ObjectRefWire "user" "alice"))
                        , ExpandSubjectWire (SubjectIdWire (ObjectRefWire "user" "bob"))
                        ]
                    , ExpandCaveatedWire "during-hours" [ExpandSubjectWire (SubjectWildcardWire "user")]
                    ]
                , state = ExpandExhaustedWire
                , checkedAt = "checked-at"
                }
        collectExpandedSubjects tree @?= ["alice", "bob", "user:*"]
    , testCase "expand decoder walks unions and intersections but excludes subtracted subjects" $ do
        tree <-
          case eitherDecode compositeExpandTreeJson of
            Left err -> assertFailure ("failed to decode expand tree: " <> err)
            Right value -> pure value
        collectExpandedSubjects tree @?= ["alice", "bob", "carol"]
    ]

compositeExpandTreeJson :: ByteString
compositeExpandTreeJson =
  "{\"root\":{\"objectType\":\"app\",\"objectId\":\"tools.example.com\"},"
    <> "\"permission\":\"access\",\"children\":["
    <> "{\"kind\":\"union\",\"children\":["
    <> "{\"kind\":\"subject\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"}},"
    <> "{\"kind\":\"exclusion\",\"granted\":[{\"kind\":\"subject\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"bob\"}}],"
    <> "\"subtracted\":[{\"kind\":\"subject\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"mallory\"}}]}]},"
    <> "{\"kind\":\"intersection\",\"children\":[{\"kind\":\"subject\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"carol\"}}]}],"
    <> "\"state\":{\"status\":\"exhausted\"},\"checkedAt\":\"checked-at\"}"
