-- | EP-180 M7 (G7): the API server stores resource quantities in canonical
-- form (RES-4 U7, experiments E11 and E15), so a declared quantity in another
-- spelling is not drift.
module InventoryKubernetesFieldsSpec (inventoryKubernetesFieldsTests) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Key (fromText)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.KubernetesRuntime (desiredFieldsMatch)
import Test.Tasty
import Test.Tasty.HUnit

inventoryKubernetesFieldsTests :: TestTree
inventoryKubernetesFieldsTests =
  testGroup
    "Kubernetes field matching (G7)"
    [ testCase "a resource list's quantities compare in the server's canonical form" $ do
        assertBool "container memory 1024Mi against 1Gi drifted" (desiredFieldsMatch (container "memory" "1024Mi") (container "memory" "1Gi"))
        assertBool "container CPU 1.5 against 1500m drifted" (desiredFieldsMatch (container "cpu" "1.5") (container "cpu" "1500m"))
        assertBool "PVC storage 0.5Gi against 512Mi drifted" (desiredFieldsMatch (claim "0.5Gi") (claim "512Mi"))
        assertBool "quota requests.memory 2048Mi against 2Gi drifted" (desiredFieldsMatch (quota "2048Mi") (quota "2Gi"))
    , testCase "a different quantity, or a quantity-like string outside a resource list, is drift" $ do
        assertBool "1Gi against 2Gi matched" (not (desiredFieldsMatch (container "memory" "1Gi") (container "memory" "2Gi")))
        assertBool "a malformed quantity matched" (not (desiredFieldsMatch (container "memory" "lots") (container "memory" "1Gi")))
        assertBool "ConfigMap data was normalised" (not (desiredFieldsMatch (settings "1024Mi") (settings "1Gi")))
    ]

container :: Text -> Text -> Value
container resource quantity =
  object
    [ "spec"
        .= object
          [ "template"
              .= object
                [ "spec"
                    .= object
                      [ "containers"
                          .= [object ["name" .= ("web" :: Text), "resources" .= object ["requests" .= object [fromText resource .= quantity], "limits" .= object [fromText resource .= quantity]]]]
                      ]
                ]
          ]
    ]

claim :: Text -> Value
claim quantity = object ["spec" .= object ["resources" .= object ["requests" .= object ["storage" .= quantity]]]]

quota :: Text -> Value
quota quantity = object ["spec" .= object ["hard" .= object ["requests.memory" .= quantity]]]

settings :: Text -> Value
settings quantity = object ["data" .= object ["memory" .= quantity]]
