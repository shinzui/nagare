module InventoryCloudflareTunnelSpec (inventoryCloudflareTunnelTests) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Deploy.Host
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (domainText)
import Nagare.Inventory.Components.CloudflareTunnel
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
import Nagare.Inventory.ProtectedRoute (protectedHosts)
import Nagare.Ops.CloudflareTunnel
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (parseKubernetesManifest)
import Nagare.Resource.Policy (Sensitivity (Secret))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope, encodeCanonicalScope)
import Nagare.Static.Preview (previewDomain, previewDomainFor)
import Nagare.Target.Kinds (IngressMode (..), hostShapeFor)
import Test.Tasty
import Test.Tasty.HUnit

inventoryCloudflareTunnelTests :: TestTree
inventoryCloudflareTunnelTests =
  testGroup
    "Cloudflare Tunnel connector component"
    [ testCase "the connector is hardened, pinned and starts only after its policy and token" $ do
        (scope, native) <- compileWith fixtureSecret >>= expectRight
        scopeId scope @?= ok (mkScopeId Platform "cloudflare-tunnel")
        decodeScope (encodeCanonicalScope scope) @?= Right scope
        Map.keys (kindCounts native) @?= ["deployment", "namespace", "networkpolicy", "secret"]
        deployment <- objectOf "deployment" native
        let pod = field ["spec", "template", "spec"] deployment
            container = headOf (field ["containers"] pod)
        field ["automountServiceAccountToken"] pod @?= Bool False
        field ["hostNetwork"] pod @?= Null
        field ["securityContext", "runAsNonRoot"] pod @?= Bool True
        field ["securityContext", "readOnlyRootFilesystem"] container @?= Bool True
        field ["securityContext", "allowPrivilegeEscalation"] container @?= Bool False
        field ["securityContext", "capabilities", "drop"] container @?= toJSONList ["ALL"]
        field ["image"] container @?= String connectorImage
        field ["readinessProbe", "httpGet", "path"] container @?= String "/ready"
        assertBool "bounded memory" (field ["resources", "limits", "memory"] container /= Null)
        member <- memberOf "deployment" native
        policy <- memberOf "networkpolicy" native
        secret <- memberOf "secret" native
        assertBool "after its policy" (OrderedAfter (policy ^. #identity) `elem` member ^. #dependencies)
        assertBool "after its token" (OrderedAfter (secret ^. #identity) `elem` member ^. #dependencies)
    , testCase "the policy allows only the external gateway, cluster DNS and port 7844 to public addresses" $ do
        (_, native) <- compileWith fixtureSecret >>= expectRight
        policy <- objectOf "networkpolicy" native
        field ["spec", "ingress"] policy @?= Array mempty
        field ["spec", "policyTypes"] policy @?= toJSONList ["Ingress", "Egress"]
        [gateway, dns, edge] <- pure (arrayOf (field ["spec", "egress"] policy))
        let gatewayPeer = headOf (field ["to"] gateway)
        field ["namespaceSelector", "matchLabels", "kubernetes.io/metadata.name"] gatewayPeer @?= String "kourier-system"
        field ["podSelector", "matchLabels", "app"] gatewayPeer @?= String "3scale-kourier-gateway"
        arrayOf (field ["ports"] gateway) @?= [object ["protocol" .= ("TCP" :: Text), "port" .= (8080 :: Int)]]
        field ["namespaceSelector", "matchLabels", "kubernetes.io/metadata.name"] (headOf (field ["to"] dns)) @?= String "kube-system"
        arrayOf (field ["ports"] edge)
          @?= [ object ["protocol" .= ("TCP" :: Text), "port" .= (7844 :: Int)]
              , object ["protocol" .= ("UDP" :: Text), "port" .= (7844 :: Int)]
              ]
        let excepted = arrayOf (field ["ipBlock", "except"] (headOf (field ["to"] edge)))
        mapM_
          (\range -> assertBool (T.unpack range) (String range `elem` excepted))
          ["10.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"]
    , testCase "the token stays a private member, and only its digest reaches the Deployment" $ do
        (scope, native) <- compileWith fixtureSecret >>= expectRight
        secret <- memberOf "secret" native
        secret ^. #sensitivity @?= Secret
        deployment <- memberBytesOf "deployment" native
        assertBool "token absent from the Deployment" (not (fixtureToken `BS.isInfixOf` deployment))
        assertBool "token absent from the public scope" (not (fixtureToken `BS.isInfixOf` encodeCanonicalScope scope))
    , testCase "a changed token changes the Deployment so the pods roll" $ do
        (_, first') <- compileWith fixtureSecret >>= expectRight
        (_, second') <- compileWith (secretWith "token" "rotated-token-value") >>= expectRight
        a <- memberBytesOf "deployment" first'
        b <- memberBytesOf "deployment" second'
        assertBool "the Deployment must change" (a /= b)
    , testCase "the token command's Secret is the shape the scope binds, and errors never quote the token" $ do
        let token = T.replicate 60 "a"
            bytes = TE.encodeUtf8 (tokenSecretYaml token)
        (_, native) <- case parseKubernetesManifest fixtureLocation bytes of
          Right [secret] -> compileWith secret >>= expectRight
          _ -> assertFailure "the Secret does not parse"
        _ <- memberOf "secret" native
        let response = "{\"success\":true,\"result\":\"" <> TE.encodeUtf8 token <> "\"}"
        parseTunnelToken 200 response @?= Right token
        case parseTunnelToken 403 response of
          Left reason -> assertBool "the error quotes the token" (not (token `T.isInfixOf` reason))
          Right _ -> assertFailure "a refused request yielded a token"
        assertBool "a short result is not a token" (isLeftOf (parseTunnelToken 200 "{\"success\":true,\"result\":\"short\"}"))
    , testCase "the connector check fails on a wrong count and on a foreign address" $ do
        let connector identifier origin = Connector identifier "2026.10.7" [origin]
            mine = connector "a" "136.87.131.238"
            two = [mine, connector "b" "136.87.131.238"]
        connectorProblems 2 "136.87.131.238" two @?= []
        length (connectorProblems 2 "136.87.131.238" [mine]) @?= 1
        -- A connector started elsewhere with the token is what this check exists for.
        length (connectorProblems 2 "136.87.131.238" [mine, connector "stolen" "203.0.113.9"]) @?= 1
        length (connectorProblems 2 "136.87.131.238" (two <> [connector "stolen" "203.0.113.9"])) @?= 2
        parseConnectors 200 "{\"success\":true,\"result\":[{\"id\":\"c1\",\"version\":\"v\",\"conns\":[{\"origin_ip\":\"1.2.3.4\"},{\"origin_ip\":\"1.2.3.4\"}]}]}"
          @?= Right [Connector "c1" "v" ["1.2.3.4"]]
        parseTunnelId "nagare-x" 200 "{\"success\":true,\"result\":[{\"id\":\"t1\",\"name\":\"nagare-x\"}]}" @?= Right "t1"
        assertBool "an absent tunnel is an error" (isLeftOf (parseTunnelId "nagare-x" 200 "{\"success\":true,\"result\":[]}"))
    , testCase "a tunnel context's default names are one label, and a direct context's are unchanged" $ do
        defaultHostName NestedHosts "site" "personal" "example.test" @?= "site.personal.example.test"
        defaultHostName FlatHosts "site" "personal" "example.test" @?= "site-personal.example.test"
        previewHostName NestedHosts "pr1" "site" "example.test" @?= "pr1.site.preview.example.test"
        previewHostName FlatHosts "pr1" "site" "example.test" @?= "pr1-site-preview.example.test"
        hostShapeFor IngressDirect @?= NestedHosts
        hostShapeFor IngressCloudflareTunnel @?= FlatHosts
        previewDomainFor FlatHosts "site" "Pr1" "example.test" @?= Right "pr1-site-preview.example.test"
        previewDomain "site" "Pr1" "example.test" @?= Right "pr1.site.preview.example.test"
        -- Both flattened and declared protected hostnames stay one label below the base.
        flat <- either (assertFailure . T.unpack) pure (protectedHosts FlatHosts "site" "personal" "example.test" [])
        map (domainText . (^. #domain)) flat @?= ["site-personal.example.test"]
        nested <- either (assertFailure . T.unpack) pure (protectedHosts NestedHosts "site" "personal" "example.test" [])
        map (domainText . (^. #domain)) nested @?= ["site.personal.example.test"]
    , testCase "a misfiled token and a mutable image refuse at planning" $ do
        expectRefused (compileWith (secretWith "other" "value"))
        expectRefused (compileInput (fixtureInput (fixtureLocation, renamedSecret)))
        expectRefused (compileInput ((fixtureInput fixtureSecret) & #image .~ "docker.io/cloudflare/cloudflared:latest"))
    ]

compileInput :: CloudflareTunnelInput -> IO (Either NonEmpty' (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString)))
compileInput input = first (const Refused) <$> compileCloudflareTunnel input

data NonEmpty' = Refused deriving stock (Eq, Show)

compileWith :: (SourceLocation, Value) -> IO (Either NonEmpty' (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString)))
compileWith = compileInput . fixtureInput

expectRefused :: IO (Either NonEmpty' a) -> Assertion
expectRefused action = action >>= either (const (pure ())) (const (assertFailure "expected a refusal"))

expectRight :: Either NonEmpty' a -> IO a
expectRight = either (const (assertFailure "unexpected refusal")) pure

fixtureInput :: (SourceLocation, Value) -> CloudflareTunnelInput
fixtureInput secret =
  CloudflareTunnelInput
    { root = "../.."
    , foundation = FoundationInput (ok (mkScopeId Platform "foundation")) fixtureCluster "cluster/bootstrap/job-runs/resourcequota.yaml" []
    , image = connectorImage
    , tokenSecret = secret
    }

fixtureCluster :: ResourceId
fixtureCluster =
  mintResourceId (ok (mkScopeId Platform "cluster")) (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

fixtureLocation :: SourceLocation
fixtureLocation = SourceLocation "cluster-secrets" "cloudflare-tunnel-token"

fixtureToken :: ByteString
fixtureToken = "fixture-tunnel-token-value"

fixtureSecret :: (SourceLocation, Value)
fixtureSecret = secretWith "token" (TE.decodeUtf8 fixtureToken)

secretWith :: Text -> Text -> (SourceLocation, Value)
secretWith key value =
  ( fixtureLocation
  , object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("Secret" :: Text)
      , "metadata" .= object ["name" .= ("cloudflare-tunnel-token" :: Text), "namespace" .= ("cloudflare-tunnel" :: Text)]
      , "stringData" .= object [Key.fromText key .= value]
      ]
  )

renamedSecret :: Value
renamedSecret =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Secret" :: Text)
    , "metadata" .= object ["name" .= ("other" :: Text), "namespace" .= ("cloudflare-tunnel" :: Text)]
    , "stringData" .= object ["token" .= ("x" :: Text)]
    ]

isLeftOf :: Either a b -> Bool
isLeftOf = either (const True) (const False)

ok :: Either Text a -> a
ok = either (error . T.unpack) id

kindOf :: ManagedResource -> Text
kindOf resource = case resource ^. #address of
  Kubernetes _ _ kind _ _ -> nameText kind
  _ -> ""

kindCounts :: Map.Map ResourceId (ManagedResource, ByteString) -> Map.Map Text Int
kindCounts native = Map.fromListWith (+) [(kindOf resource, 1) | (resource, _) <- Map.elems native]

entryOf :: Text -> Map.Map ResourceId (ManagedResource, ByteString) -> IO (ManagedResource, ByteString)
entryOf kind native = case [entry | entry@(resource, _) <- Map.elems native, kindOf resource == kind] of
  [one] -> pure one
  _ -> assertFailure ("expected one " <> T.unpack kind)

memberOf :: Text -> Map.Map ResourceId (ManagedResource, ByteString) -> IO ManagedResource
memberOf kind native = fst <$> entryOf kind native

memberBytesOf :: Text -> Map.Map ResourceId (ManagedResource, ByteString) -> IO ByteString
memberBytesOf kind native = snd <$> entryOf kind native

objectOf :: Text -> Map.Map ResourceId (ManagedResource, ByteString) -> IO Value
objectOf kind native = do
  bytes <- memberBytesOf kind native
  case parseKubernetesManifest fixtureLocation bytes of
    Right [(_, value)] -> pure value
    _ -> assertFailure ("could not read the " <> T.unpack kind)

field :: [Text] -> Value -> Value
field [] value = value
field (key : rest) (Object fields) = maybe Null (field rest) (KM.lookup (Key.fromText key) fields)
field _ _ = Null

arrayOf :: Value -> [Value]
arrayOf (Array values) = toList values
arrayOf _ = []

headOf :: Value -> Value
headOf value = case arrayOf value of
  one : _ -> one
  [] -> Null

toJSONList :: [Text] -> Value
toJSONList = Array . foldMap (pure . String)
