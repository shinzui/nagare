-- | EP-284 M3: an app bucket on a cloud context compiles to each grant's
-- Kubernetes account and credential configuration, binds only once the cloud
-- review federated the grant, and runs the bound worker as that account with
-- the identity mount and no key.
module BucketCloudScopeSpec (bucketCloudScopeTests) where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import InventoryTransactionSpec (fixtureBinding)
import Nagare.App.Deploy (RolloutEnv (..))
import Nagare.Dsl.Mounts (MountSource (..))
import Nagare.Dsl.ObjectBucket
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (Worker, webWorker)
import Nagare.Inventory.Application (CloudBucketBound (..), DatabaseBinding, acceptedBucketBindings, cloudBucketBound, cloudBucketIdentity, compileStandaloneWorkerWithDependencies)
import Nagare.Inventory.BucketCloudAccess (CloudAppBucket (..), cloudAppBuckets, grantAccountEmail, grantAccountId, retiredGrantsKey)
import Nagare.Inventory.BucketCloudScope
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Test.Support.Profiles (tnbProfile)
import ObjectBucketSpec (apiGrant, gatewayGrant, publications)
import Test.Tasty
import Test.Tasty.HUnit

bucketCloudScopeTests :: TestTree
bucketCloudScopeTests =
  testGroup
    "bucket cloud scope"
    [ testCase "the pool ID and audience match the Pulumi component's derivation" $ do
        workloadIdentityPoolId "ep285" @?= "nagare-ep285"
        -- sha256("Bad_Context") starts 4abf53cd09343ff7.
        workloadIdentityPoolId "Bad_Context" @?= "nagare-4abf53cd09343ff7"
        workloadIdentityAudience ep285Target @?= "//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/nagare-ep285/providers/kubernetes"
        identityTokenAudience ep285Target @?= "https://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/nagare-ep285/providers/kubernetes"
    , testCase "each grant gets its own account and credential configuration, and no member holds a key" $ do
        (scope, native) <- compiled
        let kinds = [located resource | (resource, _) <- Map.elems native]
        sortOn id kinds
          @?= sortOn
            id
            [ ("configmap", "personal", "nagare-bucket-publications-content-app")
            , ("configmap", "personal", "nagare-bucket-publications-content-gateway")
            , ("serviceaccount", "personal", "nagare-wl-content-app")
            , ("serviceaccount", "personal", "nagare-wl-content-gateway")
            ]
        Map.lookup "bucket.backend" (scopeOverrides scope) @?= Just "gcs"
        Map.lookup cloudBucketGoogleNameKey (scopeOverrides scope) @?= Just "tan-nb-exp-ep285-publications"
        Map.lookup cloudBucketProjectKey (scopeOverrides scope) @?= Just "tan-nb-exp"
        let account = objectAt ("serviceaccount", "personal", "nagare-wl-content-gateway") native
        KM.lookup "automountServiceAccountToken" account @?= Just (Bool False)
        configuration <- credentialsOf ("configmap", "personal", "nagare-bucket-publications-content-gateway") native
        KM.lookup "type" configuration @?= Just (String "external_account")
        KM.lookup "audience" configuration @?= Just (String (workloadIdentityAudience ep285Target))
        KM.lookup "service_account_impersonation_url" configuration
          @?= Just (String ("https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/" <> gatewayEmail <> ":generateAccessToken"))
        assertBool "a member is a Secret" (all (\(resource, _) -> let (kind, _, _) = located resource in kind /= "secret") (Map.elems native))
        assertBool "a member names a key" (not (any (\(_, bytes) -> any (`BS.isInfixOf` bytes) ["private_key", "AWS_SECRET_ACCESS_KEY"]) (Map.elems native)))
    , testCase "a grant binds only once the cloud review federated it" $ do
        (scope, native) <- compiled
        acceptedBucketBindings (snapshotOf [scope]) native testCluster "personal" (service "content-gateway") [binding "publications"]
          @?= Left "bucket-cloud-identity-missing: the cloud review has not created bucket publications's identity for workload content-gateway in namespace personal; plan and apply the platform bootstrap (its cloud stage) first"
        -- Another grant's federation does not stand in for this one.
        acceptedBucketBindings (snapshotOf [scope, cloudScope [federation apiGrant]]) native testCluster "personal" (service "content-gateway") [binding "publications"]
          @?= Left "bucket-cloud-identity-missing: the cloud review has not created bucket publications's identity for workload content-gateway in namespace personal; plan and apply the platform bootstrap (its cloud stage) first"
        bindings <- either (assertFailure . T.unpack) pure (acceptedBucketBindings (snapshotOf [scope, cloudScope [federation gatewayGrant]]) native testCluster "personal" (service "content-gateway") [binding "publications"])
        case map cloudBucketBound (Map.elems bindings) of
          [Just bound] -> do
            cloudBucketGoogleName bound @?= "tan-nb-exp-ep285-publications"
            cloudBucketAccountEmail bound @?= gatewayEmail
            cloudBucketTokenAudience bound @?= identityTokenAudience ep285Target
          other -> assertFailure (show other)
    , testCase "a bound worker runs as its grant's account with the identity mount and no Secret" $ do
        bindings <- bound
        (_, objects) <- either (assertFailure . show) pure (compileWorker [binding "publications"] bindings)
        let (deployment, bytes) = deploymentOf objects
            manifest = decodeYaml bytes
            podSpec = pathTo ["spec", "template", "spec"] manifest
            env = envOf manifest
        lookupText "serviceAccountName" podSpec @?= Just "nagare-wl-content-gateway"
        Map.lookup "NAGARE_BUCKET_PUBLICATIONS_BACKEND" env @?= Just (Right "gcs")
        Map.lookup "NAGARE_BUCKET_PUBLICATIONS_NAME" env @?= Just (Right "tan-nb-exp-ep285-publications")
        Map.lookup "NAGARE_BUCKET_PUBLICATIONS_SERVICE_ACCOUNT" env @?= Just (Right gatewayEmail)
        Map.lookup "NAGARE_BUCKET_PUBLICATIONS_CREDENTIALS" env @?= Just (Right "/var/run/nagare/identity/credentials.json")
        Map.lookup "GOOGLE_APPLICATION_CREDENTIALS" env @?= Just (Right "/var/run/nagare/identity/credentials.json")
        assertBool "the worker reads a Secret" (null [() | Left _ <- Map.elems env])
        assertBool "no bucket key variable" (not (any ("ACCESS_KEY" `T.isInfixOf`) (Map.keys env)))
        assertBool "the identity volume is projected from the ConfigMap and an audience-bound token" ("nagare-bucket-publications-content-gateway" `BS.isInfixOf` bytes && TE.encodeUtf8 (identityTokenAudience ep285Target) `BS.isInfixOf` bytes && "/var/run/nagare/identity" `BS.isInfixOf` bytes)
        let after = [producer | OrderedAfter producer <- deployment ^. #dependencies]
        (_, native) <- compiled
        assertBool "the worker waits for its account and credential configuration" (all (`elem` after) [member' ("serviceaccount", "personal", "nagare-wl-content-gateway") native, member' ("configmap", "personal", "nagare-bucket-publications-content-gateway") native])
    , testCase "retiring a cloud bucket keeps its grants for the cloud review and says which accounts are disabled" $ do
        (accepted, _) <- compiled
        (retired, native) <-
          either (assertFailure . show) pure $
            compileStandaloneCloudBucket (input' (publications & #grants .~ []) (publications ^. #grants))
        assertBool "a retired scope holds a member" (Map.null native)
        Map.member retiredGrantsKey (scopeOverrides retired) @?= True
        cloudAppBuckets [retired] @?= [CloudAppBucket publications True]
        map (^. #loses) (cloudBucketReviewEffects (snapshotOf [accepted]) retired)
          @?= [ "workload content-app in personal loses read-write access to bucket publications; the next cloud review disables its Google account " <> grantAccountEmail "tan-nb-exp" (publications ^. #name) (apiGrant ^. #namespace) (apiGrant ^. #workload)
              , "workload content-gateway in personal loses read-only access to bucket publications; the next cloud review disables its Google account " <> gatewayEmail
              , "no object: Google bucket tan-nb-exp-ep285-publications and its objects are kept; Nagare never deletes a bucket"
              ]
        -- A dropped grant's account is deleted, not disabled, and the bucket keeps no record.
        (dropped, _) <- either (assertFailure . show) pure (compileStandaloneCloudBucket (input' (publications & #grants .~ [apiGrant]) (publications ^. #grants)))
        Map.member retiredGrantsKey (scopeOverrides dropped) @?= False
        map (^. #loses) (cloudBucketReviewEffects (snapshotOf [accepted]) dropped)
          @?= ["workload content-gateway in personal loses read-only access to bucket publications; the next cloud review deletes its Google account " <> gatewayEmail]
    , testCase "a workload naming its own account, or binding two cloud buckets, is refused" $ do
        bindings <- bound
        ownAccount <- either (assertFailure . T.unpack) pure (Dsl.mkServiceAccountName "mine")
        cloudBucketIdentity (Just ownAccount) bindings
          @?= Left "a workload bound to a cloud bucket runs as its bucket account and cannot name its own serviceAccount"
        let twice = Map.fromList [(ok (Dsl.mkDatabaseName name), value) | (name, value) <- zip ["bucket-a", "bucket-b"] (Map.elems bindings <> Map.elems bindings)]
        either id (const "accepted") (cloudBucketIdentity Nothing twice) @?= "a workload can bind one cloud bucket: it runs as one account"
        case cloudBucketIdentity Nothing bindings of
          Right (Just (account, mount)) -> do
            Dsl.serviceAccountNameText account @?= "nagare-wl-content-gateway"
            mount ^. #mountPath @?= identityMountPath
            NE.toList (mount ^. #sources) @?= [ConfigMapSource "nagare-bucket-publications-content-gateway", ServiceAccountTokenSource (identityTokenAudience ep285Target) 3600]
          other -> assertFailure (show other)
        either (map (^. #message) . NE.toList) (const []) (compileWorkerWith (#serviceAccount .~ Just ownAccount) bindings)
          @?= ["a workload bound to a cloud bucket runs as its bucket account and cannot name its own serviceAccount"]
    ]
  where
    gatewayEmail = grantAccountEmail "tan-nb-exp" (publications ^. #name) (gatewayGrant ^. #namespace) (gatewayGrant ^. #workload)

ep285Target :: CloudBucketTarget
ep285Target = CloudBucketTarget {project = "tan-nb-exp", context = "ep285", projectNumber = "123456789"}

compiled :: IO (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compiled = either (assertFailure . show) pure (compileStandaloneCloudBucket (input' publications []))

input' :: ObjectBucket -> [BucketGrant] -> CloudBucketInput
input' declared keptGrants =
  CloudBucketInput
    { bucket = declared
    , target = ep285Target
    , cluster = testCluster
    , namespaces = Map.singleton "personal" personal
    , source = SourceLocation "test" "bucket"
    , kept = keptGrants
    }

-- | The gateway's accepted binding, with its grant federated.
bound :: IO (Map Dsl.DatabaseName DatabaseBinding)
bound = do
  (scope, native) <- compiled
  either (assertFailure . T.unpack) pure (acceptedBucketBindings (snapshotOf [scope, cloudScope [federation gatewayGrant]]) native testCluster "personal" (service "content-gateway") [binding "publications"])

-- | The cloud review's federation member for a grant of @publications@.
federation :: BucketGrant -> ManagedResource
federation grant =
  ManagedResource
    (mintResourceId cloudOwner (ok (mkLogicalKey "cloud")) (ok (mkName ("federation-" <> Dsl.serviceNameText (grant ^. #workload)))))
    cloudOwner
    PulumiExecutor
    (PulumiUrn ("urn:pulumi:ep285::nagare::nagare:env:NagareAppBucket$gcp:serviceaccount/iAMMember:IAMMember::nagare-bucket-publications-" <> grantAccountId (publications ^. #name) (grant ^. #namespace) (grant ^. #workload) <> "-federation"))
    []
    (NativeObject (contentDigest "federation"))
    Retain
    Stateless
    Private
    []
    []
    (SourceLocation "test" "cloud")

cloudOwner :: ScopeId
cloudOwner = ok (mkScopeId Platform "cloud")

cloudScope :: [ManagedResource] -> ScopeDeclaration
cloudScope members = ok (mkScopeDeclaration cloudOwner [ResourceBundle (map Managed members) [] [] [] [] []])

snapshotOf :: [ScopeDeclaration] -> ScopeSnapshot
snapshotOf scopes = ok (mkScopeSnapshot fixtureBinding (Map.fromList [(scopeId scope, (ok (mkScopeGeneration 1), scope)) | scope <- scopes]) Map.empty)

compileWorker :: [Dsl.BucketBinding] -> Map Dsl.DatabaseName DatabaseBinding -> Either (NE.NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileWorker buckets = compileWorkerWith (#buckets .~ buckets)

compileWorkerWith :: (Worker -> Worker) -> Map Dsl.DatabaseName DatabaseBinding -> Either (NE.NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileWorkerWith adjust bindings =
  compileStandaloneWorkerWithDependencies
    (ok (mkScopeId Standalone "worker-content-gateway"))
    (either error id (webWorker "content-gateway" "registry.example.com/content") & #buckets .~ [binding "publications"] & adjust)
    RolloutEnv
      { appName = "content-gateway"
      , qualifiedImage = ok (Dsl.mkImageRef "registry.example.com/content")
      , imageTag = "v1"
      , effectiveTag = "v1"
      , taggedAppImage = "registry.example.com/content:v1"
      , appEnv = Map.empty
      , namespace = "personal"
      , baseDomain = "apps.example.com"
      , targetProfile = tnbProfile
      , platformMounts = mempty
      }
    testCluster
    personal
    (mintResourceId (ok (mkScopeId Platform "foundation")) (ok (mkLogicalKey "image")) (ok (mkName "publication")))
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    bindings
    (SourceLocation "test" "worker")

testCluster, personal :: ResourceId
testCluster = mintResourceId (ok (mkScopeId Platform "cluster")) (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
personal = mintResourceId (ok (mkScopeId Platform "foundation")) (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-personal"))

service :: Text -> Dsl.ServiceName
service = ok . Dsl.mkServiceName

binding :: Text -> Dsl.BucketBinding
binding = Dsl.BucketBinding . ok . mkBucketName

located :: ManagedResource -> (Text, Text, Text)
located resource = case resource ^. #address of
  Kubernetes _ _ kind ns name -> (T.toLower (nameText kind), maybe "" nameText ns, nameText name)
  _ -> ("", "", "")

member' :: (Text, Text, Text) -> Map ResourceId (ManagedResource, ByteString) -> ResourceId
member' wanted native = case [resource ^. #identity | (resource, _) <- Map.elems native, located resource == wanted] of
  [found] -> found
  other -> error ("member at " <> show wanted <> ": " <> show other)

objectAt :: (Text, Text, Text) -> Map ResourceId (ManagedResource, ByteString) -> KM.KeyMap Value
objectAt wanted native = case [bytes | (resource, bytes) <- Map.elems native, located resource == wanted] of
  [bytes] | Right (Object root) <- eitherDecodeStrict bytes -> root
  _ -> error ("object at " <> show wanted)

credentialsOf :: (Text, Text, Text) -> Map ResourceId (ManagedResource, ByteString) -> IO (KM.KeyMap Value)
credentialsOf wanted native = case KM.lookup "data" (objectAt wanted native) of
  Just (Object fields)
    | Just (String configuration) <- KM.lookup (Key.fromText credentialsFileKey) fields
    , Right (Object parsed) <- eitherDecodeStrict (TE.encodeUtf8 configuration) ->
        pure parsed
  other -> assertFailure ("credentials: " <> show other)

deploymentOf :: Map ResourceId (ManagedResource, ByteString) -> (ManagedResource, ByteString)
deploymentOf native = case [pair | pair@(resource, _) <- Map.elems native, let (kind, _, _) = located resource, kind == "deployment"] of
  [found] -> found
  other -> error ("deployments: " <> show (map (located . fst) other))

decodeYaml :: ByteString -> [Value]
decodeYaml bytes = [value | Right value <- [Yaml.decodeEither' bytes]]

pathTo :: [Text] -> [Value] -> [Value]
pathTo keys found = foldl (\values key -> [next | Object object' <- values, Just next <- [KM.lookup (Key.fromText key) object']]) found keys

lookupText :: Text -> [Value] -> Maybe Text
lookupText key values = case pathTo [key] values of
  [String found] -> Just found
  _ -> Nothing

-- | The container's env: a literal value, or the Secret and key it is read from.
envOf :: [Value] -> Map Text (Either (Text, Text) Text)
envOf manifest =
  Map.fromList
    [ (name, value)
    | Array containers <- pathTo ["spec", "template", "spec", "containers"] manifest
    , Object container <- foldr (:) [] containers
    , Just (Array entries) <- [KM.lookup "env" container]
    , Object entry <- foldr (:) [] entries
    , Just (String name) <- [KM.lookup "name" entry]
    , value <- case (KM.lookup "value" entry, KM.lookup "valueFrom" entry) of
        (Just (String literal), _) -> [Right literal]
        (_, Just _) -> [Left (name, "")]
        _ -> []
    ]

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
