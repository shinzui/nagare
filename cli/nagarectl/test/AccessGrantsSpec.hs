module AccessGrantsSpec (accessGrantsTests) where

import Data.Aeson (Value, encode, (.=))
import Data.Aeson qualified as Aeson
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
    , testCase "SubjectIdWire uses en-servant's generic JSON shape" $
        jsonValue (SubjectIdWire (ObjectRefWire "user" "alice"))
          @?= Aeson.object
            [ "tag" .= ("SubjectIdWire" :: String)
            , "contents" .= Aeson.object ["objectType" .= ("user" :: String), "objectId" .= ("alice" :: String)]
            ]
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
                }
        collectExpandedSubjects tree @?= ["alice", "bob", "user:*"]
    ]

jsonValue :: (Aeson.ToJSON a) => a -> Value
jsonValue =
  either (error . ("invalid encoded JSON: " <>)) id . Aeson.eitherDecode . encode
