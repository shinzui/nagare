module InventoryUpstreamSpec (inventoryUpstreamTests) where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.Upstream
import Nagare.Inventory.Components.ControllerImage (compileControllerImage, controllerImageDeclaration)
import Nagare.Inventory.Bootstrap (BootstrapInput (..), compileBootstrapCandidate, compileConfiguredBootstrap, compileIssuerBootstrap, compilePinnedBootstrap)
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
import Nagare.Inventory.KubernetesSources (validateSuppliedKubernetesMembers)
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

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
          servingMembers = [resource | Managed resource <- declarations (fst serving)]
          servingDeployments = [resource ^. #identity | resource <- servingMembers,
            case resource ^. #address of
              Kubernetes _ "apps" kind (Just _) _ -> nameText kind == "deployment"
              _ -> False]
          servingCustomResources = [resource | resource <- servingMembers,
            case resource ^. #address of
              Kubernetes _ group _ _ _ -> group `elem`
                ["caching.internal.knative.dev", "networking.internal.knative.dev", "serving.knative.dev"]
              _ -> False]
      assertBool "upstream release members were dropped" (length resources > 100)
      assertBool "cert-manager release lacks expected readiness fixtures" (not (null certCrds) && not (null certDeployments) && not (null certServiceAccounts))
      assertBool "cert-manager direct objects precede CRD consumers"
        (all (\resource -> all (\crd -> OrderedAfter crd `elem` resource ^. #dependencies) certCrds)
          [resource | resource <- certMembers, resource ^. #identity `notElem` certCrds])
      assertBool "cert-manager Deployment starts after its prerequisites"
        (all (\resource -> all (\account -> OrderedAfter account `elem` resource ^. #dependencies) certServiceAccounts)
          certDeployments)
      assertBool "Knative custom resources start after webhook deployments"
        (not (null servingCustomResources) && all (\resource ->
          all (\deployment -> OrderedAfter deployment `elem` resource ^. #dependencies) servingDeployments)
          servingCustomResources)
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
        (BootstrapInput foundation Nothing [certInput] []) >>= expectRight
      Map.size (inventoryScopes (candidateInventory bootstrap)) @?= 2
      Map.size bootstrapNative @?= Map.size (snd cert) + 3
      (servingBootstrap, _) <- compileBootstrapCandidate snapshot
        (BootstrapInput foundation Nothing [servingInput, netInput] []) >>= expectRight
      let allMembers = [resource | Managed resource <- inventoryDeclarations (candidateInventory servingBootstrap)]
          servingMembers = [resource ^. #identity | resource <- allMembers,
            resource ^. #owner == componentOwner "serving"]
          namespaceIds = [resource ^. #identity | resource <- allMembers,
            resource ^. #address == Kubernetes fixtureCluster "" (known "namespace") Nothing (known "knative-serving")]
          netMembers = [resource | resource <- allMembers,
            resource ^. #owner == componentOwner "net-certmanager",
            case resource ^. #address of Kubernetes _ _ _ (Just name) _ -> name == known "knative-serving"; _ -> False]
          certConfig = [resource | resource <- netMembers,
            case resource ^. #address of
              Kubernetes _ "" kind _ name -> nameText kind == "configmap" && nameText name == "config-certmanager"
              _ -> False]
          laterNetMembers = [resource | resource <- netMembers, resource `notElem` certConfig]
          servingDeployments = [resource | resource <- allMembers,
            resource ^. #owner == componentOwner "serving",
            case resource ^. #address of
              Kubernetes _ "apps" kind (Just _) _ -> nameText kind == "deployment"
              _ -> False]
          servingCertificates = [resource | resource <- allMembers,
            resource ^. #owner == componentOwner "serving",
            case resource ^. #address of
              Kubernetes _ "networking.internal.knative.dev" kind (Just _) _ -> nameText kind == "certificate"
              _ -> False]
          netControllers = [resource | resource <- allMembers,
            resource ^. #owner == componentOwner "net-certmanager",
            case resource ^. #address of
              Kubernetes _ "apps" kind (Just _) _ -> nameText kind == "deployment"
              _ -> False]
          netCaIssuers = [resource | resource <- allMembers,
            resource ^. #owner == componentOwner "net-certmanager",
            case resource ^. #address of
              Kubernetes _ "cert-manager.io" kind Nothing name ->
                nameText kind == "clusterissuer" && nameText name == "knative-selfsigned-issuer"
              _ -> False]
      assertBool "ordered upstream scope does not wait for prior operator readiness"
        (not (null servingMembers) && not (null laterNetMembers)
          && all (\resource -> all (\prior ->
            prior `elem` map (^. #identity) servingCertificates
              || OrderedAfter prior `elem` resource ^. #dependencies) servingMembers) laterNetMembers)
      assertBool "Serving Deployments wait for the transferred certificate ConfigMap"
        (case certConfig of
          [config] -> not (null servingDeployments)
            && all (elem (OrderedAfter (config ^. #identity)) . (^. #dependencies)) servingDeployments
            && all (\deployment -> OrderedAfter (deployment ^. #identity) `notElem` (config ^. #dependencies)) servingDeployments
          _ -> False)
      assertBool "Serving certificates wait for net-certmanager without forming a phase cycle"
        (not (null servingCertificates) && not (null netControllers) && length netCaIssuers == 1
          && all (\certificate -> all (\controller ->
            OrderedAfter (controller ^. #identity) `elem` certificate ^. #dependencies) netControllers) servingCertificates
          && all (\certificate -> all (\issuer ->
            OrderedAfter (issuer ^. #identity) `elem` certificate ^. #dependencies) netCaIssuers) servingCertificates
          && all (\controller -> all (\certificate ->
            OrderedAfter (certificate ^. #identity) `notElem` (controller ^. #dependencies)) servingCertificates) netControllers)
      case namespaceIds of
        [namespaceId] -> assertBool "net-certmanager lacks the serving Namespace prerequisite"
          (not (null netMembers) && all (elem (OrderedAfter namespaceId) . (^. #dependencies)) netMembers)
        _ -> assertFailure "serving Namespace is missing or duplicated"
      (fullBootstrap, fullNative) <- compilePinnedBootstrap snapshot foundation Nothing "../.." >>= expectRight
      Map.size (inventoryScopes (candidateInventory fullBootstrap)) @?= 5
      Map.size fullNative @?= Map.size native + 3
  , testCase "Kourier gateway waits for its xDS controller" $ do
      configured <- configuredUpstreamInputs fixtureCluster "../.." "example.test"
        "registry.example.test" "cluster/bootstrap/knative-serving/config-certmanager.yaml"
        >>= expectRight
      kourierInput <- case configured of
        [_, _, input, _] -> pure input
        _ -> assertFailure "configured Kourier component is missing" >> pure (error "unreachable")
      (bundle, _) <- compileUpstream kourierInput >>= expectRight
      let workloads = [resource | Managed resource <- declarations bundle,
            case resource ^. #address of
              Kubernetes _ "apps" kind (Just _) _ -> nameText kind == "deployment"
              _ -> False]
          gateway = [resource | resource <- workloads,
            case resource ^. #address of Kubernetes _ _ _ _ name -> nameText name == "3scale-kourier-gateway"; _ -> False]
          controller = [resource | resource <- workloads,
            case resource ^. #address of Kubernetes _ _ _ _ name -> nameText name == "net-kourier-controller"; _ -> False]
      assertBool "Kourier gateway can start before its xDS controller"
        (case (gateway, controller) of
          ([oneGateway], [oneController]) ->
            OrderedAfter (oneController ^. #identity) `elem` oneGateway ^. #dependencies
          _ -> False)
  , testCase "net-certmanager CA waits for its issuer before certificate readiness" $ do
      configured <- configuredUpstreamInputs fixtureCluster "../.." "example.test"
        "registry.example.test" "cluster/bootstrap/knative-serving/config-certmanager.yaml"
        >>= expectRight
      netInput <- case configured of
        [_, _, _, input] -> pure input
        _ -> assertFailure "configured net-certmanager component is missing" >> pure (error "unreachable")
      (bundle, _) <- compileUpstream netInput >>= expectRight
      let members = [resource | Managed resource <- declarations bundle]
          named kind wanted = [resource | resource <- members,
            case resource ^. #address of
              Kubernetes _ "cert-manager.io" actualKind _ name ->
                nameText actualKind == kind && nameText name == wanted
              _ -> False]
      case (named "clusterissuer" "selfsigned-cluster-issuer",
            named "certificate" "knative-selfsigned-ca",
            named "clusterissuer" "knative-selfsigned-issuer") of
        ([selfSigned], [certificate], [caIssuer]) -> do
          assertBool "CA certificate precedes its self-signed issuer"
            (OrderedAfter (selfSigned ^. #identity) `elem` certificate ^. #dependencies)
          assertBool "CA-backed issuer precedes its certificate"
            (OrderedAfter (certificate ^. #identity) `elem` caIssuer ^. #dependencies)
        _ -> assertFailure "net-certmanager CA chain is incomplete"
  , testCase "changed asset digest refuses before review" $ do
      result <- compileUpstream (component "cert-manager"
        [("cluster/bootstrap/vendor/cert-manager-v1.20.2.yaml", digest (replicateText 64 "0"))])
      assertBool "changed pinned asset was accepted" (either (const True) (const False) result)
  , testCase "patched net-certmanager controller image is in reviewed native bytes" $ do
      let image = "registry.example.test/net-certmanager@sha256:" <> T.replicate 64 "a"
          publication = mintResourceId (componentOwner "image")
            (ok (mkLogicalKey "image")) (ok (mkName "publish"))
      selected <- either (assertFailure . T.unpack) pure
        (bindNetCertManagerControllerImage fixtureCluster image publication
          (pinnedUpstreamInputs fixtureCluster "../.."))
      net <- case selected of
        [_, _, _, componentInput] -> pure componentInput
        _ -> assertFailure "net-certmanager scope is absent" >> pure (error "unreachable")
      (_, native) <- compileUpstream net >>= expectRight
      let matching = [(resource, bytes) | (resource, bytes) <- Map.elems native,
            case resource ^. #address of
              Kubernetes _ "apps" kind (Just namespace) name ->
                nameText kind == "deployment" && nameText namespace == "knative-serving"
                  && nameText name == "net-certmanager-controller"
              _ -> False]
      case matching of
        [(controller, bytes)] -> do
          assertBool "patched image is not in reviewed Deployment"
            (image `T.isInfixOf` TE.decodeUtf8 bytes)
          assertBool "controller does not wait for image publication"
            (OrderedAfter publication `elem` controller ^. #dependencies)
        _ -> assertFailure "reviewed controller Deployment is missing"
      mutable <- either (assertFailure . T.unpack) pure
        (bindNetCertManagerControllerImage fixtureCluster "registry.example.test/net-certmanager:mutable" publication
          (pinnedUpstreamInputs fixtureCluster "../.."))
      case mutable of
        [_, _, _, componentInput] -> do
          refused <- compileUpstream componentInput
          assertBool "mutable controller image was accepted" (case refused of Left _ -> True; Right _ -> False)
        _ -> assertFailure "net-certmanager scope is absent"
  , testCase "released controller archive is required before image review" $
      withSystemTempDirectory "controller-image-payload" $ \root -> do
        let directory = root </> "cluster/bootstrap/net-certmanager"
        createDirectoryIfMissing True directory
        BS.writeFile (directory </> "image-reference")
          "nagare/net-certmanager-controller:v1.14.0-nagare.1\n"
        missing <- compileControllerImage root "registry.example.test"
        assertBool "controller image archive absence was accepted"
          (case missing of Left _ -> True; Right _ -> False)
        (scope, image, publication) <- expectRight
          (controllerImageDeclaration "registry.example.test"
            (ok (mkContentDigest (T.replicate 64 "a")))
            (ok (mkContentDigest (T.replicate 64 "b"))))
        assertBool "controller image was not digest-addressed"
          ("@sha256:" `T.isInfixOf` image)
        assertBool "image publication operation is absent"
          (any (any ((== publication) . (^. #identity)) . operations) (scopeBundles scope))
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
      let networkAddress = ok (kubernetesAddress fixtureCluster "v1" "ConfigMap" (Just "knative-serving") "config-network")
          networkData native = [entries | (resource, bytes) <- Map.elems native,
            resource ^. #address == networkAddress,
            Right (Object root) <- [eitherDecodeStrict bytes],
            Just (Object entries) <- [KM.lookup "data" root]]
      case (networkData cloudNative, networkData localNative) of
        ([cloudNetwork], [localNetwork]) -> do
          KM.lookup "external-domain-tls" cloudNetwork @?= Nothing
          KM.lookup "external-domain-tls" localNetwork @?= Just (String "Enabled")
          assertBool "local namespace wildcard selector is missing"
            (KM.member "namespace-wildcard-cert-selector" localNetwork)
        _ -> assertFailure "cloud/local config-network is not uniquely owned"
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
component name files = UpstreamInput (componentOwner name) fixtureCluster (ok (mkLogicalKey name)) "../.." files Map.empty Set.empty Map.empty Map.empty [] Map.empty Map.empty True

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
