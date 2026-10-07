-- | EP-180 M7 (G7): the API server stores a resource quantity in canonical
-- form (RES-4 U7, experiment E11), so a quantity is compared, and emitted,
-- in that form.
module QuantitySpec (quantityTests) where

import Data.Either (isRight)
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Prelude
import Nagare.Dsl.Quantity (canonicalQuantity)
import Nagare.Dsl.Types (mkQuantity, quantityText)
import Test.Tasty
import Test.Tasty.HUnit

quantityTests :: TestTree
quantityTests =
  testGroup
    "Nagare.Dsl.Quantity (G7)"
    [ testCase "what the API server stored, as RES-4 E11 and experiment E15 recorded it" $
        canonicalTable
          [ ("1024Mi", "1Gi")
          , ("2048Mi", "2Gi")
          , ("1000M", "1G")
          , ("1000m", "1")
          , ("1.5", "1500m")
          , ("0.5", "500m")
          , ("1.5Gi", "1536Mi")
          , ("0.5Gi", "512Mi")
          , ("1536Mi", "1536Mi")
          , ("1.1Ki", "1126400m")
          , ("2000m", "2")
          , ("1500m", "1500m")
          , ("1024", "1024")
          , ("512Ki", "512Ki")
          , ("1000Ki", "1000Ki")
          , ("1Ei", "1Ei")
          , -- A resource list is rounded up to milli.
            ("0.1m", "1m")
          , ("100u", "1m")
          , -- The exponent family keeps the text as written.
            ("1e3", "1e3")
          , ("1e-3", "1e-3")
          , ("1500e0", "1500e0")
          ]
    , testCase "apimachinery's rules on cases E15 did not record" $
        canonicalTable [("0", "0"), ("100m", "100m"), ("0.25", "250m"), ("12000k", "12M"), ("0.5Ki", "512"), ("1000e0", "1e3"), ("1500u", "2m")]
    , testCase "malformed quantities have no canonical form" $
        mapM_ (\text -> canonicalQuantity text @?= Nothing) ["", "Mi", "1Xi", "1.2.3", "abc"]
    , testCase "the DSL emits the canonical form" $
        fmap quantityText (mkQuantity "1024Mi") @?= Right "1Gi"
    , testGroup
        "mkQuantity"
        ( [testCase ("accepts " <> Text.unpack given) (assertBool "refused" (isRight (mkQuantity given))) | given <- ["250m", "512Mi", "1", "2Gi", "1.5"]]
            <> [ testCase name (either (\refusal -> assertBool (Text.unpack refusal) (reason `Text.isInfixOf` refusal)) (const (assertFailure "accepted")) (mkQuantity given))
               | (name, given, reason) <- [("rejects empty", "", "empty"), ("rejects abc", "abc", "digit"), ("rejects 100x", "100x", "suffix"), ("rejects space", "100 Mi", "suffix")]
               ]
        )
    ]
  where
    canonicalTable :: [(Text, Text)] -> Assertion
    canonicalTable = mapM_ (\(given, stored) -> assertEqual (Text.unpack given) (Just stored) (canonicalQuantity given))
