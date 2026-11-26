-- | EP-286 M3: a workload binds a key set only when one of that name is
-- accepted in its namespace. A signer mounts the public and private files, a
-- verifier only the public one, and each is ordered after the key set's
-- first-run Job, so the files exist when it starts.
module KeySetBindingSpec (keySetBindingTests) where

import Control.Monad (forM_)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import InventoryTransactionSpec (fixtureBinding)
import KeySetSpec (compileKeySet, rotatorImage, viewGrants)
import ManagedEnvScopeSpec (input, scopedApp, workloadObjects)
import Nagare.App.Deploy (RolloutEnv (..))
import Nagare.Dsl.KeySet.Binding
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (webWorker)
import Nagare.Inventory.Application (ApplicationScopeInput (..), DatabaseBinding, acceptedKeySetBindings, compileApplicationDeployment, compileStandaloneWorkerWithDependencies)
import Nagare.Inventory.KeySet (keySetFirstRunJob)
import Nagare.Inventory.KubernetesSources (validateSuppliedKubernetesMembers)
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Test.Support.Profiles (tnbProfile)
import Test.Tasty
import Test.Tasty.HUnit

keySetBindingTests :: TestTree
keySetBindingTests =
  testGroup
    "key set binding"
    [ testCase "a signer mounts both files, names the directory and waits for the first run" $ do
        (snapshot, native, firstRun) <- accepted
        bindings <- either (assertFailure . T.unpack) pure (acceptedKeySetBindings snapshot native "personal" (service "content-app") [signs])
        Map.keys bindings @?= [ok (Dsl.mkDatabaseName "keyset-view-grants")]
        (_, compiled) <- either (assertFailure . show) pure (compileWorker [signs] bindings)
        let (deployment, bytes) = deploymentOf compiled
        sourcesOf bytes @?= [("keyset-view-grants", "/var/run/nagare/keysets/view-grants", [("configMap", "nagare-keyset-view-grants-public"), ("secret", "nagare-keyset-view-grants")])]
        Map.lookup "NAGARE_KEYSET_VIEW_GRANTS_DIR" (envOf bytes) @?= Just "/var/run/nagare/keysets/view-grants"
        assertBool "the worker is ordered after the first-run Job" (OrderedAfter firstRun `elem` deployment ^. #dependencies)
    , testCase "a verifier mounts only the public file and its manifest never names the key set's Secret" $ do
        (snapshot, native, firstRun) <- accepted
        bindings <- either (assertFailure . T.unpack) pure (acceptedKeySetBindings snapshot native "personal" (service "content-app") [verifies])
        (_, compiled) <- either (assertFailure . show) pure (compileWorker [verifies] bindings)
        let (deployment, bytes) = deploymentOf compiled
        sourcesOf bytes @?= [("keyset-view-grants", "/var/run/nagare/keysets/view-grants", [("configMap", "nagare-keyset-view-grants-public")])]
        assertBool "the manifest names the private Secret" (not ("name: nagare-keyset-view-grants\n" `BS.isInfixOf` bytes))
        assertBool "the worker is ordered after the first-run Job" (OrderedAfter firstRun `elem` deployment ^. #dependencies)
    , testCase "a key set that is not accepted in the workload's namespace is refused" $ do
        (snapshot, native, _) <- accepted
        acceptedKeySetBindings snapshot native "elsewhere" (service "content-app") [signs]
          @?= Left "keyset-missing: key set view-grants is not accepted in namespace elsewhere, which workload content-app runs in; plan and apply it first with nagarectl keyset plan"
        acceptedKeySetBindings snapshot native "personal" (service "content-app") [KeySetBinding (ok (mkKeySetName "drafts")) Sign]
          @?= Left "keyset-missing: key set drafts is not accepted in namespace personal, which workload content-app runs in; plan and apply it first with nagarectl keyset plan"
        acceptedKeySetBindings snapshot native "personal" (service "content-app") [signs, verifies]
          @?= Left "key set bindings repeat a key set"
    , testCase "a binding without its accepted key set does not compile" $
        either (map (^. #message) . NE.toList) (const []) (compileWorker [signs] Map.empty)
          @?= ["database dependencies must cover exactly the workload bindings"]
    , testCase "a worker that binds no key set renders no mount and no key set variable" $ do
        (_, compiled) <- either (assertFailure . show) pure (compileWorker [] Map.empty)
        assertBool "a key set name in the manifest" (not (any (BS.isInfixOf "keyset" . snd) (Map.elems compiled)))
    , testCase "an Application's service signs and its worker verifies, each after the first run" $ do
        (snapshot, native, firstRun) <- accepted
        let app = scopedApp Dsl.NoManagedEnv & #service %~ fmap (#keySets .~ [signs]) & #workers %~ map (#keySets .~ [verifies])
            resolve (name, use') = (service name,) <$> acceptedKeySetBindings snapshot native "personal" (service name) [KeySetBinding (viewGrants ^. #name) use']
        bindings <- either (assertFailure . T.unpack) (pure . Map.fromList) (traverse resolve [("scoped-web", Sign), ("scoped-worker", Verify)])
        (scopes, compiled) <- either (assertFailure . show) pure (compileApplicationDeployment ((input app) {scopeBucketBindings = bindings}))
        let objects = workloadObjects scopes compiled
            secretsOf kind = [[name | (sourceKind, name) <- sources, sourceKind == "secret"] | (objectKind, _, bytes) <- objects, objectKind == kind, (_, _, sources) <- sourcesOf bytes]
        secretsOf "service" @?= [["nagare-keyset-view-grants"]]
        secretsOf "deployment" @?= [[]]
        forM_ ["service", "deployment"] $ \kind ->
          assertBool (T.unpack kind <> " is ordered after the first-run Job") (any (\(objectKind, resource, _) -> objectKind == kind && OrderedAfter firstRun `elem` resource ^. #dependencies) objects)
        validateSuppliedKubernetesMembers (map fst (Map.elems compiled)) compiled @?= Right ()
        either (map (^. #message) . NE.toList) (const []) (compileApplicationDeployment (input app))
          @?= ["database dependencies must cover exactly the workload bindings"]
    ]
  where
    signs = KeySetBinding (viewGrants ^. #name) Sign
    verifies = KeySetBinding (viewGrants ^. #name) Verify

-- | The accepted key set scope, its native objects and its first-run Job.
accepted :: IO (ScopeSnapshot, Map ResourceId (ManagedResource, ByteString), ResourceId)
accepted = do
  (scope, native) <- either (assertFailure . show) pure (compileKeySet rotatorImage viewGrants)
  firstRun <- maybe (assertFailure "no first-run Job") pure (keySetFirstRunJob native (scopeId scope))
  pure (ok (mkScopeSnapshot fixtureBinding (Map.singleton (scopeId scope) (ok (mkScopeGeneration 1), scope)) Map.empty), native, firstRun)

compileWorker :: [KeySetBinding] -> Map Dsl.DatabaseName DatabaseBinding -> Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileWorker keySets bindings =
  compileStandaloneWorkerWithDependencies
    (ok (mkScopeId Standalone "worker-content-app"))
    (either error id (webWorker "content-app" "registry.example.com/content") & #keySets .~ keySets)
    RolloutEnv
      { appName = "content-app"
      , qualifiedImage = ok (Dsl.mkImageRef "registry.example.com/content")
      , imageTag = "v1"
      , effectiveTag = "v1"
      , taggedAppImage = "registry.example.com/content:v1"
      , appEnv = Map.empty
      , namespace = "personal"
      , baseDomain = "apps.example.com"
      , targetProfile = tnbProfile
      }
    (mintResourceId (ok (mkScopeId Platform "cluster")) (ok (mkLogicalKey "cluster")) (ok (mkName "cluster")))
    (mintResourceId (ok (mkScopeId Platform "foundation")) (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-personal")))
    (mintResourceId (ok (mkScopeId Platform "foundation")) (ok (mkLogicalKey "image")) (ok (mkName "publication")))
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    bindings
    (SourceLocation "test" "worker")

service :: Text -> Dsl.ServiceName
service = ok . Dsl.mkServiceName

deploymentOf :: Map ResourceId (ManagedResource, ByteString) -> (ManagedResource, ByteString)
deploymentOf native = case [pair | pair@(resource, _) <- Map.elems native, isDeployment resource] of
  [found] -> found
  other -> error ("deployments: " <> show (length other))
  where
    isDeployment resource = case resource ^. #address of
      Kubernetes _ "apps" kind _ _ -> nameText kind == "deployment"
      _ -> False

-- | Each projected volume that some container mounts: its name, the mount
-- path, and its sources as (kind, object name).
sourcesOf :: ByteString -> [(Text, Text, [(Text, Text)])]
sourcesOf bytes =
  [ (name, path, sources)
  | Right manifest <- [Yaml.decodeEither' bytes :: Either Yaml.ParseException Value]
  , pod <- podSpecs manifest
  , Object volume <- fieldsAt ["volumes"] pod >>= list
  , Just (String name) <- [KM.lookup "name" volume]
  , Object projected <- maybe [] pure (KM.lookup "projected" volume)
  , let sources = [(kind, objectName) | Object source <- maybe [] list (KM.lookup "sources" projected), (kind, Just (Object ref)) <- [("configMap", KM.lookup "configMap" source), ("secret", KM.lookup "secret" source)], Just (String objectName) <- [KM.lookup "name" ref]]
  , Object container <- fieldsAt ["containers"] pod >>= list
  , Object mount <- maybe [] list (KM.lookup "volumeMounts" container)
  , KM.lookup "name" mount == Just (String name)
  , Just (String path) <- [KM.lookup "mountPath" mount]
  ]

-- | A Deployment's or a Knative Service's container env literals.
envOf :: ByteString -> Map Text Text
envOf bytes =
  Map.fromList
    [ (name, literal)
    | Right manifest <- [Yaml.decodeEither' bytes :: Either Yaml.ParseException Value]
    , pod <- podSpecs manifest
    , Object container <- fieldsAt ["containers"] pod >>= list
    , Object entry <- maybe [] list (KM.lookup "env" container)
    , Just (String name) <- [KM.lookup "name" entry]
    , Just (String literal) <- [KM.lookup "value" entry]
    ]

podSpecs :: Value -> [Value]
podSpecs manifest = fieldsAt ["spec", "template", "spec"] manifest

list :: Value -> [Value]
list = \case
  Array found -> foldr (:) [] found
  _ -> []

fieldsAt :: [Text] -> Value -> [Value]
fieldsAt keys value = foldl (\found key -> [next | Object object' <- found, Just next <- [KM.lookup (Key.fromText key) object']]) [value] keys

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
