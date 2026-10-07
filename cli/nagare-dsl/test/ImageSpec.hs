module ImageSpec (imageTests) where

import Data.Either (isLeft)
import Nagare.Dsl.Image (imageRefFromName, mkImageName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (imageRefText)
import Test.Tasty
import Test.Tasty.HUnit

-- | EP-62 M3: the registry-prefix derivation that turns a short image NAME plus
-- a deploy-time prefix into a fully-qualified 'ImageRef'. The prefix is supplied
-- by nagarectl from the target profile; the DSL stays environment-agnostic.
imageTests :: TestTree
imageTests =
  testGroup "Nagare.Dsl.Image (EP-62)" $
    [ testCase "imageRefFromName joins <prefix>/<name>" $
        fmap imageRefText (imageRefFromName "us-west1-docker.pkg.dev/tan-nb-exp/nagare" "notes")
          @?= Right "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"
    , testCase "imageRefFromName tolerates a trailing slash on the prefix" $
        fmap imageRefText (imageRefFromName "host/proj/repo/" "app")
          @?= Right "host/proj/repo/app"
    , testCase "imageRefFromName derives a different prefix purely from inputs" $
        fmap imageRefText (imageRefFromName "europe-west1-docker.pkg.dev/acme-prod/nagare" "notes")
          @?= Right "europe-west1-docker.pkg.dev/acme-prod/nagare/notes"
    , testCase "mkImageName accepts a bare name (deferring the prefix)" $
        fmap imageRefText (mkImageName "notes") @?= Right "notes"
    , testCase "mkImageName rejects a tagged name (no ':' allowed)" $
        assertBool "Left on a tag" (isLeft (mkImageName "notes:tag"))
    ]
