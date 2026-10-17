module InventoryAdminApiSpec (inventoryAdminApiTests) where

import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.BackendMap (compileContributedBackendMaps)
import Nagare.Inventory.Components.AdminApi
import Nagare.Inventory.Components.Auth
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (Sensitivity (Secret))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope, encodeCanonicalScope)
import Test.Tasty
import Test.Tasty.HUnit

inventoryAdminApiTests :: TestTree
inventoryAdminApiTests =
  testGroup
    "admin API inventory component"
    [ testCase "a local scope binds a gateway-only Deployment on the mounted store, its Service and policy, and a protected route" $ do
        auth <- authScope
        (scope, native) <- compileWith auth LocalMountedStore >>= expectRight
        scopeId scope @?= adminOwner
        kinds native @?= ["deployment", "domainmapping", "networkpolicy", "service"]
        deployment <- objectOf "deployment" native
        let pod = field ["spec", "template", "spec"] deployment
            container = headOf (field ["containers"] pod)
        field ["automountServiceAccountToken"] pod @?= Bool False
        field ["securityContext", "readOnlyRootFilesystem"] container @?= Bool True
        field ["resources", "limits", "memory"] container @?= String "512Mi"
        field ["image"] container @?= String fixtureImage
        assertBool "the local server does not read its mounted store" (String "/var/lib/nagare/inventory" `elem` arrayOf (field ["args"] container))
        assertBool "the local server binds loopback" (String "0.0.0.0" `elem` arrayOf (field ["args"] container))
        let mount = headOf (field ["volumes"] pod `except` "tmp")
        field ["hostPath", "type"] mount @?= String "Directory"
        policy <- objectOf "networkpolicy" native
        -- One peer holding both selectors is a conjunction; two peers would
        -- admit either the namespace or the label.
        [peer] <- pure (arrayOf (field ["from"] (headOf (field ["spec", "ingress"] policy))))
        field ["namespaceSelector", "matchLabels", "kubernetes.io/metadata.name"] peer @?= String "nagare-system"
        field ["podSelector", "matchLabels", "serving.knative.dev/service"] peer @?= String "nagare-access"
        length (arrayOf (field ["spec", "egress"] policy)) @?= 1
        route <- memberOf "domainmapping" native
        route ^. #aliases @?= [Hostname (ok (mkName "admin.example.test"))]
        assertBool "the route is not ordered after the backend map" (OrderedAfter (backendMapResourceId fixtureOwner) `elem` route ^. #dependencies)
        assertBool "the route is not ordered after the enforcer" (OrderedAfter (enforcerId auth) `elem` route ^. #dependencies)
        -- The scope, with its API backend role, survives the store's wire.
        decodeScope (encodeCanonicalScope scope) @?= Right scope
        [bundle] <- pure (scopeBundles scope)
        bundle ^. #contributions
          @?= [ RegisterBackend
                  fixtureOwner
                  fixtureCluster
                  (ok (mkName "admin.example.test"))
                  "http://nagare-admin-api.nagare-system.svc.cluster.local"
                  ApiBackend
                  (ok (mkLogicalKey "admin.example.test"))
              ]
    , testCase "a cloud scope binds the reader Secret privately and serves the context's GCS prefix" $ do
        auth <- authScope
        (_, native) <- compileWith auth (cloudStore fixtureReader) >>= expectRight
        kinds native @?= ["deployment", "domainmapping", "networkpolicy", "secret", "service"]
        secret <- memberOf "secret" native
        secret ^. #sensitivity @?= Secret
        secretObject <- objectOf "secret" native
        KM.member "stringData" (objectFields secretObject) @?= False
        field ["data", "key.json"] secretObject @?= String "eyJ0eXBlIjoic2VydmljZV9hY2NvdW50In0="
        deployment <- memberOf "deployment" native
        assertBool "the Deployment is not ordered after its credential" (OrderedAfter (secret ^. #identity) `elem` deployment ^. #dependencies)
        deploymentObject <- objectOf "deployment" native
        let args = arrayOf (field ["args"] (headOf (field ["spec", "template", "spec", "containers"] deploymentObject)))
        assertBool "the store URL is not passed" (String "gs://project-nagare-pulumi-state/nagare/ctx/inventory" `elem` args)
        assertBool "the project number is not passed" (String "123456789012" `elem` args)
        rotated <- compileWith auth (cloudStore (secretNamed "nagare-admin-api-reader" [("key.json", "{\"type\":\"rotated\"}")])) >>= expectRight
        rotatedObject <- objectOf "deployment" (snd rotated)
        assertBool "a rotated key leaves the pod template unchanged" (field ["spec", "template"] rotatedObject /= field ["spec", "template"] deploymentObject)
        policy <- objectOf "networkpolicy" native
        let https = field ["to"] (arrayOf (field ["spec", "egress"] policy) !! 1)
            excluded = arrayOf (field ["ipBlock", "except"] (headOf https))
        assertBool "the metadata server's link-local range is reachable" (String "169.254.0.0/16" `elem` excluded)
        assertBool "cluster-internal addresses are reachable" (String "10.0.0.0/8" `elem` excluded)
    , testCase "unusable inputs are refused before any member is bound" $ do
        auth <- authScope
        let refused label result = case result of
              Left errors -> assertBool label (any ((== "invalid-admin-api") . (^. #code)) (toList errors))
              Right _ -> assertFailure (label <> ": accepted")
        compileAdminApi (input LocalMountedStore & #image .~ "registry.example.test/nagare-admin-api:latest") (declarationsOf auth) >>= refused "a mutable image tag"
        compileWith auth (CloudReaderStore "gs://project-nagare-pulumi-state/nagare/ctx/inventory" "" fixtureReader) >>= refused "an empty project number"
        compileWith auth (cloudStore (secretNamed "grafana-admin" [("key.json", "{}")])) >>= refused "another Secret"
        compileWith auth (cloudStore (secretNamed "nagare-admin-api-reader" [("key.json", "{}"), ("token", "x")])) >>= refused "an extra key"
        compileAdminApi (input LocalMountedStore) [] >>= refused "no auth enforcer"
    , testCase "the composed backend map routes the admin host as an API" $ do
        auth <- authScope
        (scope, _) <- compileWith auth LocalMountedStore >>= expectRight
        let scopes = Map.fromList [(fixtureOwner, auth), (adminOwner, scope)]
        effective <- expectRight (composedDeclarations scopes)
        [(_, (_, bytes))] <- pure (Map.toList (ok (compileContributedBackendMaps effective)))
        backendObject <- expectRight (eitherDecodeStrict bytes)
        backends <- case field ["data", "backends.json"] backendObject of
          String encoded -> expectRight (eitherDecodeStrict (TE.encodeUtf8 encoded))
          other -> assertFailure ("backend map data: " <> show other)
        field ["admin.example.test"] backends
          @?= object
            [ "upstream" .= ("http://nagare-admin-api.nagare-system.svc.cluster.local" :: Text)
            , "role" .= ("protected" :: Text)
            , "apiPrefix" .= ("/v1" :: Text)
            , "timeoutSeconds" .= (15 :: Int)
            ]
    , testCase "no other platform scope may contribute a backend" $ do
        auth <- authScope
        let other = ok (mkScopeId Platform "observability-extra")
            route = RegisterBackend fixtureOwner fixtureCluster (ok (mkName "admin.example.test")) "http://elsewhere.nagare-system.svc.cluster.local" ApiBackend (ok (mkLogicalKey "admin.example.test"))
            scopes = Map.fromList [(fixtureOwner, auth), (other, ok (mkScopeDeclaration other [ResourceBundle [] [] [] [route] [] []]))]
        case composedDeclarations scopes of
          Left errors -> assertBool "refused for another reason" (any ((== "unauthorized-contribution") . (^. #code)) (toList errors))
          Right _ -> assertFailure "a platform scope other than the admin API contributed a backend"
    ]

compileWith :: ScopeDeclaration -> AdminApiStore -> IO (Either (NonEmpty InventoryError) (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString)))
compileWith auth store = compileAdminApi (input store) (declarationsOf auth)

input :: AdminApiStore -> AdminApiInput
input store =
  AdminApiInput
    { root = "../.."
    , foundation = FoundationInput fixtureOwner fixtureCluster "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
    , baseDomain = "example.test"
    , context = "ctx"
    , project = "project"
    , image = fixtureImage
    , store = store
    }

cloudStore :: (SourceLocation, Value) -> AdminApiStore
cloudStore = CloudReaderStore "gs://project-nagare-pulumi-state/nagare/ctx/inventory" "123456789012"

fixtureReader :: (SourceLocation, Value)
fixtureReader = secretNamed "nagare-admin-api-reader" [("key.json", "{\"type\":\"service_account\"}")]

secretNamed :: Text -> [(Text, Text)] -> (SourceLocation, Value)
secretNamed name entries =
  ( SourceLocation "admin-api-reader.yaml" "encrypted-admin-api-reader-secret"
  , object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("Secret" :: Text)
      , "metadata" .= object ["name" .= name, "namespace" .= ("nagare-system" :: Text)]
      , "stringData" .= object [Key.fromText key .= value | (key, value) <- entries]
      ]
  )

fixtureImage :: Text
fixtureImage = "registry.example.test/nagare-admin-api@sha256:" <> T.replicate 64 "c"

-- | The auth scope the admin API orders after: the packaged cloud auth plane.
authScope :: IO ScopeDeclaration
authScope = do
  (bundle, _) <-
    compileAuth
      AuthInput
        { authOwner = fixtureOwner
        , authCluster = fixtureCluster
        , authNamespace = mintResourceId fixtureOwner (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-nagare-system"))
        , authRoot = "../.."
        , authImages = Map.fromList [(name, "registry.example.test/" <> name <> "@sha256:" <> T.replicate 64 "a") | name <- ["en", "shomei", "nagare-access"]]
        , authBaseDomain = "example.test"
        , authDatabasePrerequisites = Map.fromList [(name, mintResourceId fixtureOwner (ok (mkLogicalKey name)) (ok (mkName "database"))) | name <- ["en", "shomei"]]
        , authExtraPrerequisites = []
        , authMode = CloudAuth
        }
      >>= expectRight
  expectRight (mkScopeDeclaration fixtureOwner [bundle])

enforcerId :: ScopeDeclaration -> ResourceId
enforcerId auth =
  case [ resource ^. #identity
       | Managed resource <- declarationsOf auth
       , resource ^. #address == ok (kubernetesAddress fixtureCluster "serving.knative.dev/v1" "Service" (Just "nagare-system") "nagare-access")
       ] of
    one : _ -> one
    [] -> error "the auth fixture has no enforcer"

adminOwner :: ScopeId
adminOwner = ok (mkScopeId Platform "admin-api")

fixtureOwner :: ScopeId
fixtureOwner = ok (mkScopeId Platform "auth")

fixtureCluster :: ResourceId
fixtureCluster = mintResourceId fixtureOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

kinds :: Map.Map ResourceId (ManagedResource, ByteString) -> [Text]
kinds native =
  sort
    [ nameText kind
    | (resource, _) <- Map.elems (Map.fromList [(resource ^. #address, member) | member@(resource, _) <- Map.elems native])
    , Kubernetes _ _ kind _ _ <- [resource ^. #address]
    ]

memberOf :: Text -> Map.Map ResourceId (ManagedResource, ByteString) -> IO ManagedResource
memberOf kind native = fst <$> nativeOf kind native

objectOf :: Text -> Map.Map ResourceId (ManagedResource, ByteString) -> IO Value
objectOf kind native = do
  (_, bytes) <- nativeOf kind native
  expectRight (eitherDecodeStrict bytes)

nativeOf :: Text -> Map.Map ResourceId (ManagedResource, ByteString) -> IO (ManagedResource, ByteString)
nativeOf wanted native = case [member | member@(resource, _) <- Map.elems native, Kubernetes _ _ kind _ _ <- [resource ^. #address], nameText kind == wanted] of
  [one] -> pure one
  other -> assertFailure ("expected one " <> T.unpack wanted <> ", found " <> show (length other))

objectFields :: Value -> KM.KeyMap Value
objectFields (Object value) = value
objectFields _ = KM.empty

field :: [Text] -> Value -> Value
field [] value = value
field (key : rest) value = field rest (fromMaybe Null (KM.lookup (Key.fromText key) (objectFields value)))

arrayOf :: Value -> [Value]
arrayOf (Array values) = toList values
arrayOf _ = []

headOf :: Value -> Value
headOf value = case arrayOf value of
  one : _ -> one
  [] -> Null

-- | The named entries of an array other than @name@.
except :: Value -> Text -> Value
except value name = Array (foldMap pure [entry | entry <- arrayOf value, field ["name"] entry /= String name])

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure

declarationsOf :: ScopeDeclaration -> [Declaration]
declarationsOf = concatMap (^. #declarations) . scopeBundles
