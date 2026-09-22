module InventoryFoundationSpec (inventoryFoundationTests) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.Foundation
import Nagare.Inventory.KubernetesSources (validateSuppliedKubernetesMembers)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit
import System.FilePath ((</>))

inventoryFoundationTests :: TestTree
inventoryFoundationTests = testGroup "cluster foundation inventory"
  [ testCase "five namespaces and personal Job quota form one bound bundle" $ do
      (bundle, native) <- compileFoundation foundationInput >>= expectRight
      length (declarations bundle) @?= 6
      Map.size native @?= 6
      let resources = [member | Managed member <- declarations bundle]
      _ <- expectRight (validateSuppliedKubernetesMembers resources native)
      let quota = [member | member <- resources, member ^. #address == Kubernetes fixtureCluster "" (known "resourcequota") (Just (known "personal")) (known "nagare-terminating-jobs")]
      length quota @?= 1
      let binding = ContextBinding (ok (mkContextId "fixture")) (known "project")
          scope = ok (mkScopeDeclaration fixtureOwner [bundle])
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
      assertBool "foundation scope failed claim validation" (either (const False) (const True)
        (composeInventory snapshot (ReplaceScope scope :| [])))
  , testCase "missing quota source refuses before any native mutation" $ do
      result <- compileFoundation (foundationInput {foundationQuotaPath = "../../cluster/bootstrap/missing-quota.yaml"})
      assertBool "missing quota was accepted" (either (const True) (const False) result)
  ]

foundationInput :: FoundationInput
foundationInput = FoundationInput fixtureOwner fixtureCluster ("../../cluster/bootstrap/job-runs" </> "resourcequota.yaml")

fixtureOwner :: ScopeId
fixtureOwner = ok (mkScopeId Platform "foundation")

fixtureCluster :: ResourceId
fixtureCluster = mintResourceId fixtureOwner (ok (mkLogicalKey "cluster")) (known "cluster")

known :: Text -> Name
known = ok . mkName

ok :: Show e => Either e a -> a
ok = either (error . show) id

expectRight :: Show e => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure
