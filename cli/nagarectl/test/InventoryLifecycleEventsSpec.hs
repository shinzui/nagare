module InventoryLifecycleEventsSpec (inventoryLifecycleEventsTests) where

import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (isInfixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
import Nagare.Inventory.Components.LifecycleEvents
import Nagare.Platform.ReleaseImages (explicitSelection)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

-- | The lifecycle worker's platform scope (EP-235 M2), compiled from the
-- packaged templates for each mode.
inventoryLifecycleEventsTests :: TestTree
inventoryLifecycleEventsTests =
  testGroup
    "lifecycle events inventory component"
    [ testCase "a local scope binds the worker, its signing-Secret role and policy, and no worker key Secret" $ do
        (scope, native) <- compileLifecycleEvents (input localStore ["nagare-dbbackup-app-signing", "hook-key"] False) >>= expectRight
        scopeId scope @?= ok (mkScopeId Platform "lifecycle-events")
        let named = names native
        assertBool "the worker members are bound" (all (`elem` named) workerMembers)
        assertBool "a local context binds no worker key Secret" (("secret", "nagare-events-worker") `notElem` named)
        role <- objectOf "clusterrole" "nagare-events-signing-keys" native
        resourceNames role @?= [String "hook-key", String "nagare-dbbackup-app-signing"]
        deployment <- objectOf "deployment" "nagare-events" native
        let args = deploymentArgs deployment
        assertBool "delivery off is passed" ([String "--delivery", String "off"] `isInfixOf` args)
        assertBool "the local backup endpoint is passed" (String "http://minio.nagare-system.svc.cluster.local:9000" `elem` args)
        field ["image"] (container deployment) @?= String fixtureImage
    , testCase "a cloud scope binds the worker key Secret privately and passes the context's GCS prefix" $ do
        (_, native) <- compileLifecycleEvents (input cloudStore [] True) >>= expectRight
        let named = names native
        assertBool "the worker members are bound" (all (`elem` named) workerMembers)
        assertBool "a cloud context binds the worker key Secret" (("secret", "nagare-events-worker") `elem` named)
        role <- objectOf "clusterrole" "nagare-events-signing-keys" native
        -- An empty resourceNames would grant every Secret.
        resourceNames role @?= [String "nagare-events-no-signing-secret"]
        deployment <- objectOf "deployment" "nagare-events" native
        let args = deploymentArgs deployment
        assertBool "delivery on is passed" ([String "--delivery", String "on"] `isInfixOf` args)
        assertBool "the store URL is passed" (String "gs://project-nagare-pulumi-state/nagare/ctx/inventory" `elem` args)
    , testCase "a local scope with no signing Secrets names a placeholder, never every Secret" $ do
        (_, native) <- compileLifecycleEvents (input localStore [] False) >>= expectRight
        role <- objectOf "clusterrole" "nagare-events-signing-keys" native
        resourceNames role @?= [String "nagare-events-no-signing-secret"]
    , testCase "a mutable worker image is refused before any member is bound" $ do
        result <- compileLifecycleEvents ((input localStore [] False) & #image .~ explicitSelection "registry.example.test/nagare-admin-api:latest")
        case result of
          Left errors -> assertBool "refused for another reason" (any ((== "invalid-lifecycle-events") . (^. #code)) (toList errors))
          Right _ -> assertFailure "a mutable image tag was accepted"
    ]

workerMembers :: [(Text, Text)]
workerMembers =
  [ ("serviceaccount", "nagare-events")
  , ("clusterrole", "nagare-events-signing-keys")
  , ("clusterrolebinding", "nagare-events-signing-keys")
  , ("networkpolicy", "nagare-events")
  , ("deployment", "nagare-events")
  ]

input :: LifecycleStore -> [Text] -> Bool -> LifecycleEventsInput
input store signing delivery =
  LifecycleEventsInput
    { root = "../.."
    , foundation = FoundationInput fixtureOwner fixtureCluster "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
    , context = "ctx"
    , project = "project"
    , image = explicitSelection fixtureImage
    , imagePublication = Nothing
    , store = store
    , delivery = delivery
    , signingSecrets = signing
    }

localStore :: LifecycleStore
localStore =
  LocalLifecycle
    "http://minio.nagare-system.svc.cluster.local:9000"
    "nagare-backups"
    ("registry.example.test/nagare-mc@sha256:" <> T.replicate 64 "d")

cloudStore :: LifecycleStore
cloudStore =
  CloudLifecycle
    "gs://project-nagare-pulumi-state/nagare/ctx/inventory"
    "123456789012"
    "project-nagare-backups"
    ( SourceLocation "lifecycle-worker.yaml" "encrypted-lifecycle-worker-secret"
    , object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("Secret" :: Text)
        , "metadata" .= object ["name" .= ("nagare-events-worker" :: Text), "namespace" .= ("nagare-system" :: Text)]
        , "stringData" .= object ["key.json" .= ("{\"type\":\"service_account\"}" :: Text)]
        ]
    )

fixtureImage :: Text
fixtureImage = "registry.example.test/nagare-admin-api@sha256:" <> T.replicate 64 "c"

fixtureOwner :: ScopeId
fixtureOwner = ok (mkScopeId Platform "foundation")

fixtureCluster :: ResourceId
fixtureCluster = mintResourceId fixtureOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

names :: Map.Map ResourceId (ManagedResource, ByteString) -> [(Text, Text)]
names native =
  sort
    [ (nameText kind, nameText name)
    | (resource, _) <- Map.elems native
    , Kubernetes _ _ kind _ name <- [resource ^. #address]
    ]

objectOf :: Text -> Text -> Map.Map ResourceId (ManagedResource, ByteString) -> IO Value
objectOf wanted wantedName native =
  case [bytes | (resource, bytes) <- Map.elems native, Kubernetes _ _ kind _ name <- [resource ^. #address], nameText kind == wanted, nameText name == wantedName] of
    [bytes] -> expectRight (eitherDecodeStrict bytes)
    other -> assertFailure ("expected one " <> T.unpack wanted <> " " <> T.unpack wantedName <> ", found " <> show (length other))

resourceNames :: Value -> [Value]
resourceNames role = sort (arrayOf (field ["resourceNames"] (headOf (field ["rules"] role))))

container :: Value -> Value
container deployment = headOf (field ["spec", "template", "spec", "containers"] deployment)

deploymentArgs :: Value -> [Value]
deploymentArgs = arrayOf . field ["args"] . container

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

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure
