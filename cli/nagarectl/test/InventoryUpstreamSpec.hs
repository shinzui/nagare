module InventoryUpstreamSpec (inventoryUpstreamTests) where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.Upstream
import Nagare.Inventory.Bootstrap (BootstrapInput (..), compileBootstrapCandidate, compileConfiguredBootstrap, compileIssuerBootstrap, compilePinnedBootstrap)
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
  , testCase "reviewed upstream ConfigMap overlay changes one owned native member" $ do
      servingInput <- case pinnedUpstreamInputs fixtureCluster "../.." of
        _ : serving : _ -> pure serving
        _ -> assertFailure "serving release is absent" >> pure (error "unreachable")
      let address = ok (kubernetesAddress fixtureCluster "v1" "ConfigMap" (Just "knative-serving") "config-network")
          overlaid = servingInput {upstreamConfigMapData = Map.singleton address
            (Map.singleton "ingress-class" (Just "kourier.ingress.networking.knative.dev"))}
      (_, original) <- compileUpstream servingInput >>= expectRight
      (_, changed) <- compileUpstream overlaid >>= expectRight
      let boundAt native = [(resource ^. #identity, bytes) | (resource, bytes) <- Map.elems native,
            resource ^. #address == address]
      case (boundAt original, boundAt changed) of
        ([(priorId, priorBytes)], [(nextId, nextBytes)]) -> do
          priorId @?= nextId
          assertBool "ConfigMap overlay did not change retained native bytes" (priorBytes /= nextBytes)
        _ -> assertFailure "config-network was not uniquely bound"
      missing <- compileUpstream servingInput {upstreamConfigMapData = Map.singleton
        (ok (kubernetesAddress fixtureCluster "v1" "ConfigMap" (Just "knative-serving") "absent"))
        (Map.singleton "key" (Just "value"))}
      assertBool "absent upstream ConfigMap overlay was accepted" (either (const True) (const False) missing)
  , testCase "packaged cloud and local Knative policy bind into upstream scopes" $ do
      let foundation = FoundationInput (componentOwner "foundation") fixtureCluster
            "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
          snapshot = ok (mkScopeSnapshot
            (ContextBinding (ok (mkContextId "fixture")) (known "project")) Map.empty Map.empty)
          compileWith certificatePatch = compileConfiguredBootstrap snapshot foundation Nothing
            "../.." "example.test" "registry.example.test" certificatePatch >>= expectRight
      (cloud, cloudNative) <- compileWith "cluster/bootstrap/knative-serving/config-certmanager.yaml"
      (local, localNative) <- compileWith "cluster/bootstrap/local-tls/config-certmanager-local.yaml"
      Map.size (inventoryScopes (candidateInventory cloud)) @?= 5
      Map.size (inventoryScopes (candidateInventory local)) @?= 5
      Map.size cloudNative @?= Map.size localNative
      assertBool "cloud/local issuer policy did not change retained native members" (cloudNative /= localNative)
      let domainAddress = ok (kubernetesAddress fixtureCluster "v1" "ConfigMap" (Just "knative-serving") "config-domain")
          domainObjects = [bytes | (resource, bytes) <- Map.elems cloudNative,
            resource ^. #address == domainAddress]
      case domainObjects of
        [bytes] -> case eitherDecodeStrict bytes of
          Right (Object root) -> case KM.lookup "data" root of
            Just (Object entries) -> do
              KM.lookup "example.test" entries @?= Just (String "")
              KM.lookup "svc.cluster.local" entries @?= Nothing
            _ -> assertFailure "configured domain has no data"
          _ -> assertFailure "configured domain native member is malformed"
        _ -> assertFailure "configured domain is not uniquely owned"
      invalidPatch <- configuredUpstreamInputs fixtureCluster "../.." "example.test"
        "registry.example.test" "../outside.yaml"
      assertBool "non-packaged certificate policy was accepted" (either (const True) (const False) invalidPatch)
  , testCase "pinned local CA and cloud issuer compile between cert-manager and Serving" $ do
      let foundation = FoundationInput (componentOwner "foundation") fixtureCluster
            "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
          snapshot = ok (mkScopeSnapshot
            (ContextBinding (ok (mkContextId "fixture")) (known "project")) Map.empty Map.empty)
          compileWith mode = compileIssuerBootstrap snapshot foundation Nothing "../.."
            "example.test" "registry.example.test" mode >>= expectRight
      (local, localNative) <- compileWith LocalIssuer
      (cloud, cloudNative) <- compileWith
        (CloudIssuer "https://acme-staging-v02.api.letsencrypt.org/directory" "admin@example.test" "project")
      Map.size (inventoryScopes (candidateInventory local)) @?= 6
      Map.size (inventoryScopes (candidateInventory cloud)) @?= 6
      Map.size localNative @?= Map.size cloudNative + 2
      let issuerMembers = [resource | Managed resource <- inventoryDeclarations (candidateInventory local),
            resource ^. #owner == componentOwner "certificate-issuer"]
          issuerId name = [resource ^. #identity | resource <- issuerMembers,
            case resource ^. #address of
              Kubernetes _ "cert-manager.io" kind Nothing resourceName ->
                nameText kind == "clusterissuer" && nameText resourceName == name
              _ -> False]
          certificates = [resource | resource <- issuerMembers,
            case resource ^. #address of
              Kubernetes _ "cert-manager.io" kind (Just _) _ -> nameText kind == "certificate"
              _ -> False]
      case (issuerId "nagare-local-selfsigned", issuerId "nagare-local-ca", certificates) of
        ([selfSigned], [_], [certificate]) ->
          assertBool "local CA Certificate does not wait for the self-signed issuer"
            (OrderedAfter selfSigned `elem` certificate ^. #dependencies)
        _ -> assertFailure "local issuer chain is incomplete"
  ]

component :: Text -> [(FilePath, ContentDigest)] -> UpstreamInput
component name files = UpstreamInput (componentOwner name) fixtureCluster (ok (mkLogicalKey name)) "../.." files Map.empty Set.empty Map.empty [] Map.empty True

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
