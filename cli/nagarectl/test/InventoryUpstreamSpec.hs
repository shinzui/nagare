module InventoryUpstreamSpec (inventoryUpstreamTests) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.Upstream
import Nagare.Inventory.Bootstrap (BootstrapInput (..), compileBootstrapCandidate)
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
import Nagare.Inventory.KubernetesSources (validateSuppliedKubernetesMembers)
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

inventoryUpstreamTests :: TestTree
inventoryUpstreamTests = testGroup "pinned upstream bootstrap manifests"
  [ testCase "release assets compile to one exact reviewed membership" $ do
      (certInput, servingInput, kourierInput, netInput) <-
        case pinnedUpstreamInputs fixtureCluster "../.." of
          [certInput, servingInput, kourierInput, netInput] ->
            pure (certInput, servingInput, kourierInput, netInput)
          _ -> assertFailure "pinned upstream release set must have four ordered components"
            >> pure (error "unreachable")
      cert <- compileUpstream certInput >>= expectRight
      serving <- compileUpstream servingInput >>= expectRight
      kourier <- compileUpstream kourierInput >>= expectRight
      net <- compileUpstream netInput >>= expectRight
      let components = zip ["cert-manager", "serving", "kourier", "net-certmanager"] [cert, serving, kourier, net]
          scopes = [ok (mkScopeDeclaration (componentOwner name) [bundle]) | (name, (bundle, _)) <- components]
          members = concat [declarations bundle | (_, (bundle, _)) <- components]
          native = Map.unions [values | (_, (_, values)) <- components]
          resources = [resource | Managed resource <- members]
          binding = ContextBinding (ok (mkContextId "fixture")) (known "project")
          certMembers = [resource | Managed resource <- declarations (fst cert)]
          certCrds = [resource ^. #identity | resource <- certMembers,
            case resource ^. #address of
              Kubernetes _ "apiextensions.k8s.io" kind Nothing _ -> nameText kind == "customresourcedefinition"
              _ -> False]
          certDeployments = [resource | resource <- certMembers,
            case resource ^. #address of
              Kubernetes _ "apps" kind (Just _) _ -> nameText kind == "deployment"
              _ -> False]
          certServiceAccounts = [resource ^. #identity | resource <- certMembers,
            case resource ^. #address of
              Kubernetes _ "" kind (Just _) _ -> nameText kind == "serviceaccount"
              _ -> False]
      assertBool "upstream release members were dropped" (length resources > 100)
      assertBool "cert-manager release lacks expected readiness fixtures" (not (null certCrds) && not (null certDeployments) && not (null certServiceAccounts))
      assertBool "cert-manager direct objects precede CRD consumers"
        (all (\resource -> all (\crd -> OrderedAfter crd `elem` resource ^. #dependencies) certCrds)
          [resource | resource <- certMembers, resource ^. #identity `notElem` certCrds])
      assertBool "cert-manager Deployment starts after its prerequisites"
        (all (\resource -> all (\account -> OrderedAfter account `elem` resource ^. #dependencies) certServiceAccounts)
          certDeployments)
      Map.size native @?= length resources
      _ <- expectRight (validateSuppliedKubernetesMembers resources native)
      case scopes of
        firstScope : remaining -> do
          let candidate = composeInventory (ok (mkScopeSnapshot binding Map.empty Map.empty))
                (ReplaceScope firstScope :| map ReplaceScope remaining)
          assertBool (show candidate) (either (const False) (const True) candidate)
        [] -> assertFailure "upstream fixture has no scopes"
      let foundation = FoundationInput (componentOwner "foundation") fixtureCluster
            "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
      (bootstrap, bootstrapNative) <- compileBootstrapCandidate snapshot
        (BootstrapInput foundation Nothing [certInput]) >>= expectRight
      Map.size (inventoryScopes (candidateInventory bootstrap)) @?= 2
      Map.size bootstrapNative @?= Map.size (snd cert) + 3
      (servingBootstrap, _) <- compileBootstrapCandidate snapshot
        (BootstrapInput foundation Nothing [servingInput, netInput]) >>= expectRight
      let allMembers = [resource | Managed resource <- inventoryDeclarations (candidateInventory servingBootstrap)]
          servingMembers = [resource ^. #identity | resource <- allMembers,
            resource ^. #owner == componentOwner "serving"]
          namespaceIds = [resource ^. #identity | resource <- allMembers,
            resource ^. #address == Kubernetes fixtureCluster "" (known "namespace") Nothing (known "knative-serving")]
          netMembers = [resource | resource <- allMembers,
            resource ^. #owner == componentOwner "net-certmanager",
            case resource ^. #address of Kubernetes _ _ _ (Just name) _ -> name == known "knative-serving"; _ -> False]
      assertBool "ordered upstream scope does not wait for prior operator readiness"
        (not (null servingMembers) && not (null netMembers)
          && all (\resource -> all (\prior -> OrderedAfter prior `elem` resource ^. #dependencies) servingMembers) netMembers)
      case namespaceIds of
        [namespaceId] -> assertBool "net-certmanager lacks the serving Namespace prerequisite"
          (not (null netMembers) && all (elem (OrderedAfter namespaceId) . (^. #dependencies)) netMembers)
        _ -> assertFailure "serving Namespace is missing or duplicated"
      (fullBootstrap, fullNative) <- compilePinnedBootstrap snapshot foundation Nothing "../.." >>= expectRight
      Map.size (inventoryScopes (candidateInventory fullBootstrap)) @?= 5
      Map.size fullNative @?= Map.size native + 3
  , testCase "changed asset digest refuses before review" $ do
      result <- compileUpstream (component "cert-manager"
        [("cluster/bootstrap/vendor/cert-manager-v1.20.2.yaml", digest (replicateText 64 "0"))])
      assertBool "changed pinned asset was accepted" (either (const True) (const False) result)
  ]

component :: Text -> [(FilePath, ContentDigest)] -> UpstreamInput
component name files = UpstreamInput (componentOwner name) fixtureCluster (ok (mkLogicalKey name)) "../.." files Map.empty Set.empty

componentOwner :: Text -> ScopeId
componentOwner name = ok (mkScopeId Platform name)

fixtureCluster :: ResourceId
fixtureCluster = mintResourceId (componentOwner "foundation") (ok (mkLogicalKey "cluster")) (known "cluster")

digest :: Text -> ContentDigest
digest = ok . mkContentDigest

replicateText :: Int -> Text -> Text
replicateText count value = mconcat (replicate count value)

known :: Text -> Name
known = ok . mkName

ok :: Show e => Either e a -> a
ok = either (error . show) id

expectRight :: Show e => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure
