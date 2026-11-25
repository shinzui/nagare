-- | EP-286 M3: a key set document and a workload's binding to it, through
-- their JSON and back.
module KeySetSpec (keySetTests) where

import Control.Lens ((&), (.~))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy (toStrict)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Config (encodeKeySets, encodeTask, encodeWorker)
import Nagare.Dsl.KeySet
import Nagare.Dsl.Load (decodeKeySets, decodeTask, decodeWorker)
import Nagare.Dsl.Prelude hiding ((&), (.~))
import Nagare.Dsl.Task (scheduledTask)
import Nagare.Dsl.Types (mkNamespace)
import Nagare.Dsl.Worker (webWorker)
import Test.Tasty
import Test.Tasty.HUnit

keySetTests :: TestTree
keySetTests =
  testGroup
    "key set (EP-286)"
    [ testCase "a key set name is a DNS label of at most 30 characters that starts with a letter" $ do
        assertBool "a digit start was accepted" (isLeft (mkKeySetName "1grants"))
        assertBool "a trailing - was accepted" (isLeft (mkKeySetName "grants-"))
        assertBool "31 characters were accepted" (isLeft (mkKeySetName (Text.replicate 31 "a")))
        fmap keySetNameText (mkKeySetName "view-grants") @?= Right "view-grants"
        keySetEnvPrefix (ok (mkKeySetName "view-grants")) @?= "NAGARE_KEYSET_VIEW_GRANTS"
    , testCase "a period under ten minutes, an overlap under five and an overlap over the period are refused" $ do
        let policy p o = mkRotationPolicy (ok (mkMinutes p)) (ok (mkMinutes o))
        assertBool "a nine-minute period was accepted" (isLeft (policy 9 5))
        assertBool "a four-minute overlap was accepted" (isLeft (policy 60 4))
        assertBool "an overlap over the period was accepted" (isLeft (policy 10 11))
        assertBool "a ten-minute period with a five-minute overlap was refused" (not (isLeft (policy 10 5)))
    , testCase "a key set document round-trips, and one declared twice is refused" $ do
        decodeKeySets (toStrict (encodeKeySets [viewGrants])) @?= Right [viewGrants]
        assertBool "a repeat was accepted" (isLeft (decodeKeySets (toStrict (encodeKeySets [viewGrants, viewGrants]))))
    , testCase "a signing worker and a verifying task round-trip their bindings" $ do
        let worker = ok' (webWorker "content-gateway" "registry.example/gateway") & #keySets .~ [binding Verify]
            task = ok (scheduledTask "issue" "0 * * * *" "registry.example/api" "issue") & #keySets .~ [binding Sign]
        decodeWorker (toStrict (encodeWorker worker)) @?= Right worker
        decodeTask (toStrict (encodeTask task)) @?= Right task
    , testCase "a workload that binds no key set has no keySets key" $
        assertBool "keySets emitted" (not (BS.isInfixOf "keySets" (toStrict (encodeWorker (ok' (webWorker "content-gateway" "registry.example/gateway"))))))
    ]
  where
    binding = KeySetBinding (ok (mkKeySetName "view-grants"))
    ok' = either error id

viewGrants :: KeySet
viewGrants =
  KeySet
    { name = ok (mkKeySetName "view-grants")
    , logicalKey = Nothing
    , namespace = ok (mkNamespace "personal")
    , rotation = ok (mkRotationPolicy (ok (mkMinutes 1440)) (ok (mkMinutes 120)))
    }

ok :: Either Text a -> a
ok = either (error . Text.unpack) id
