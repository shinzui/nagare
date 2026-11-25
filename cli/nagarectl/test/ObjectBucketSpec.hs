-- | EP-283 M3: an app object bucket's standalone scope on the local object
-- store. The members, their order, the absence of any key in the reviewed
-- bytes, and how a changed or dropped grant changes the scope.
module ObjectBucketSpec
  ( objectBucketTests
  , compile
  , publications
  , apiGrant
  , gatewayGrant
  , values
  , member
  , located
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (..))
import Nagare.Dsl.ObjectBucket
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (mkNamespace, mkServiceName)
import Nagare.Inventory.Adapters.CredentialTemplate (generatedCredentialTemplate, minioUserCopyKind, minioUserCredentialKind)
import Nagare.Inventory.ObjectBucket
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (LifecyclePolicy (Protect, Retain))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

objectBucketTests :: TestTree
objectBucketTests =
  testGroup
    "bucket scope"
    [ testCase "a bucket compiles to its Job and, per grant, a user template, the workload's copy and a grant Job" $ do
        (scope, native) <- expectRight (compile [] publications)
        scopeId scope @?= ok (mkScopeId Standalone "bucket-publications")
        scopeBucket scope @?= Just publications
        sort (map (located . fst) (Map.elems native))
          @?= sort
            [ ("job", "nagare-system", "nagare-bucket-publications-make-" <> suffix "make" native)
            , ("secret", "nagare-system", apiUser)
            , ("secret", "nagare-system", gatewayUser)
            , ("secret", "personal", "nagare-bucket-publications-content-app")
            , ("secret", "personal", "nagare-bucket-publications-content-gateway")
            , ("job", "nagare-system", apiUser <> "-grant-" <> suffix ("grant-" <> T.drop 14 apiUser) native)
            , ("job", "nagare-system", gatewayUser <> "-grant-" <> suffix ("grant-" <> T.drop 14 gatewayUser) native)
            ]
        [resource ^. #lifecycle | (resource, _) <- Map.elems native, isRole "make" resource] @?= [Protect]
        all ((== Retain) . (^. #lifecycle)) [resource | (resource, _) <- Map.elems native, not (isRole "make" resource)] @? "every other member is Retain"
    , testCase "no reviewed byte holds a key, and each Secret is a template the adapter fills" $ do
        (_, native) <- expectRight (compile [] publications)
        let secrets = [bytes | (resource, bytes) <- Map.elems native, kindOf resource == "secret"]
        length secrets @?= 4
        mapM_ (\bytes -> generatedCredentialTemplate (TE.decodeUtf8 bytes) @?= Right True) secrets
        mapM_ (\bytes -> assertBool "a Secret carries no data" (not (KM.member "data" (root bytes)) && not (KM.member "stringData" (root bytes)))) secrets
        sort [user | bytes <- secrets, Right (Just user) <- [minioUserCredentialKind (Object (root bytes))]] @?= sort [apiUser, gatewayUser]
        sort [user | bytes <- secrets, Right (Just user) <- [minioUserCopyKind (Object (root bytes))]] @?= sort [apiUser, gatewayUser]
    , testCase "the copy names its user's own Secret, and each grant Job runs after the bucket and that Secret" $ do
        (_, native) <- expectRight (compile [] publications)
        let userId = member ("user-" <> T.drop 14 gatewayUser) native ^. #identity
            makeId = member "make" native ^. #identity
            copy = [bytes | (resource, bytes) <- Map.elems native, located resource == ("secret", "personal", "nagare-bucket-publications-content-gateway")]
        [annotation "nagare.dev/minio-source-resource-id" bytes | bytes <- copy] @?= [Just (resourceIdText userId)]
        (member ("credential-" <> T.drop 14 gatewayUser) native ^. #dependencies) @?= [OrderedAfter personal, OrderedAfter userId]
        (member ("grant-" <> T.drop 14 gatewayUser) native ^. #dependencies) @?= [OrderedAfter makeId, OrderedAfter userId]
        (member "make" native ^. #dependencies) @?= [OrderedAfter systemNs, OrderedAfter storeJob]
    , testCase "a read-only grant may only get objects; a read-write grant may also put, delete and list" $ do
        bucketPolicy "nagare-app-publications" ReadOnly
          @?= Right "{\"Statement\":[{\"Action\":[\"s3:GetObject\"],\"Effect\":\"Allow\",\"Resource\":[\"arn:aws:s3:::nagare-app-publications/*\"]}],\"Version\":\"2012-10-17\"}"
        bucketPolicy "nagare-app-publications" ReadWrite
          @?= Right "{\"Statement\":[{\"Action\":[\"s3:DeleteObject\",\"s3:GetObject\",\"s3:PutObject\"],\"Effect\":\"Allow\",\"Resource\":[\"arn:aws:s3:::nagare-app-publications/*\"]},{\"Action\":[\"s3:ListBucket\"],\"Effect\":\"Allow\",\"Resource\":[\"arn:aws:s3:::nagare-app-publications\"]}],\"Version\":\"2012-10-17\"}"
        (_, native) <- expectRight (compile [] publications)
        let script user = T.unwords [text | (resource, bytes) <- Map.elems native, isRole ("grant-" <> T.drop 14 user) resource, text <- command bytes]
        assertBool "the gateway's Job attaches the read-only policy" ("s3:GetObject" `T.isInfixOf` script gatewayUser && not ("s3:PutObject" `T.isInfixOf` script gatewayUser))
        assertBool "the API's Job attaches the read-write policy" ("s3:PutObject" `T.isInfixOf` script apiUser)
    , testCase "the same declaration compiles to the same scope, whatever was accepted before" $ do
        first' <- expectRight (compile [] publications)
        again <- expectRight (compile (values (snd first')) publications)
        again @?= first'
    , testCase "a changed expiry rule is a new bucket Job and nothing else" $ do
        (_, before) <- expectRight (compile [] publications)
        (_, after) <- expectRight (compile (values before) (publications & #expire .~ [ExpireRule (ok (mkObjectPrefix "staging/")) (ok (mkPositiveDays 7))]))
        Map.keysSet after `Set.difference` Map.keysSet before @?= Set.singleton (member "make" after ^. #identity)
        Map.keysSet before `Set.difference` Map.keysSet after @?= Set.singleton (member "make" before ^. #identity)
        assertBool "the rule is in the new Job" (any ("\"Days\":7" `T.isInfixOf`) (command (snd (after Map.! (member "make" after ^. #identity)))))
    , testCase "a changed access level is a new grant Job; the user and its credential stay" $ do
        (_, before) <- expectRight (compile [] publications)
        (_, after) <- expectRight (compile (values before) (publications & #grants .~ [apiGrant, gatewayGrant & #access .~ ReadWrite]))
        let changed = Map.keysSet after `Set.difference` Map.keysSet before
        changed @?= Set.singleton (member ("grant-" <> T.drop 14 gatewayUser) after ^. #identity)
        Set.size (Map.keysSet before `Set.difference` Map.keysSet after) @?= 1
    , testCase "a dropped grant leaves its members and adds a revoke Job, which later plans keep" $ do
        (_, before) <- expectRight (compile [] publications)
        dropped@(_, after) <- expectRight (compile (values before) (publications & #grants .~ [apiGrant]))
        sort (map (located . fst) (Map.elems after))
          @?= sort
            [ located (member "make" before)
            , ("secret", "nagare-system", apiUser)
            , ("secret", "personal", "nagare-bucket-publications-content-app")
            , located (member ("grant-" <> T.drop 14 apiUser) before)
            , ("job", "nagare-system", gatewayUser <> "-revoke-" <> suffix ("revoke-" <> T.drop 14 gatewayUser) after)
            ]
        let revoke = T.unwords (command (snd (after Map.! (member ("revoke-" <> T.drop 14 gatewayUser) after ^. #identity))))
        assertBool "the Job removes the user" (("mc admin user remove root " <> gatewayUser) `T.isInfixOf` revoke)
        assertBool "the Job touches no bucket" (not ("mc rb" `T.isInfixOf` revoke) && not ("mc rm" `T.isInfixOf` revoke))
        again <- expectRight (compile (values after) (publications & #grants .~ [apiGrant]))
        again @?= dropped
    , testCase "a grant after a revoke is a new Job, and the revoke Job leaves" $ do
        (_, before) <- expectRight (compile [] publications)
        (_, revoked) <- expectRight (compile (values before) (publications & #grants .~ [apiGrant]))
        (_, regranted) <- expectRight (compile (values revoked) publications)
        let grantOf native = member ("grant-" <> T.drop 14 gatewayUser) native
        assertBool "the new grant Job is not the one that ran before the revoke" (located (grantOf regranted) /= located (grantOf before))
        [resource | (resource, _) <- Map.elems regranted, isRole "revoke" resource] @?= []
    , testCase "a grant in a namespace that is not accepted, and a cloud store, are refused" $ do
        let elsewhere = publications & #grants .~ [apiGrant & #namespace .~ ok (mkNamespace "elsewhere")]
        either (map (^. #code) . NE.toList) (const []) (compile [] elsewhere) @?= ["invalid-object-bucket"]
        either (^. #code) (const "") (bucketStoreFor (GcsBackend "project" "bucket") "client") @?= "bucket-backend-unsupported"
        bucketStoreFor (MinioBackend (MinioRef "http://minio.nagare-system.svc.cluster.local:9000" "nagare-backups" "nagare-minio-credentials")) "client"
          @?= Right (BucketStore "http://minio.nagare-system.svc.cluster.local:9000" "client")
    , testCase "a review lists each workload that loses access, and a retirement says the objects are kept" $ do
        accepted@(_, native) <- expectRight (compile [] publications)
        let snapshot = snapshotOf [fst accepted]
            credential workload' = resourceIdText (member' ("secret", "personal", "nagare-bucket-publications-" <> workload') native ^. #identity)
            lines' declared = [resourceIdText (effect ^. #resource) <> ": " <> (effect ^. #loses) | effect <- bucketReviewEffects snapshot (fst (ok (compile (values native) declared)))]
        lines' publications @?= []
        lines' (publications & #expire .~ []) @?= []
        lines' (publications & #grants .~ [apiGrant])
          @?= [credential "content-gateway" <> ": workload content-gateway in personal loses read-only access to bucket publications"]
        lines' (publications & #grants .~ [apiGrant & #access .~ ReadOnly, gatewayGrant])
          @?= [credential "content-app" <> ": workload content-app in personal loses write access to bucket publications and keeps read-only access"]
        retiredBucket publications @?= (publications & #grants .~ [])
        lines' (retiredBucket publications)
          @?= [ credential "content-app" <> ": workload content-app in personal loses read-write access to bucket publications"
              , credential "content-gateway" <> ": workload content-gateway in personal loses read-only access to bucket publications"
              , resourceIdText (member "make" native ^. #identity) <> ": no object: bucket nagare-app-publications and its objects are kept"
              ]
        bucketReviewEffects (snapshotOf []) (fst accepted) @?= []
    , testCase "a bucket is bound while another scope's member is ordered after one of its members" $ do
        (scope, native) <- expectRight (compile [] publications)
        let grant = member ("grant-" <> T.drop 14 gatewayUser) native ^. #identity
            consumerOwner = ok (mkScopeId Application "content")
            consumer after = member "make" native & #identity .~ mintResourceId consumerOwner (ok (mkLogicalKey "content")) (ok (mkName "worker")) & #owner .~ consumerOwner & #dependencies .~ after
            other after = ok (mkScopeDeclaration consumerOwner [ResourceBundle [Managed (consumer after)] [] [] [] [] []])
        boundBy (snapshotOf [scope]) scope @?= []
        boundBy (snapshotOf [scope, other [OrderedAfter personal]]) scope @?= []
        boundBy (snapshotOf [scope, other [OrderedAfter grant]]) scope @?= [consumer [] ^. #identity]
    ]
  where
    apiUser = bucketUser (publications ^. #name) (apiGrant ^. #namespace) (apiGrant ^. #workload)
    gatewayUser = bucketUser (publications ^. #name) (gatewayGrant ^. #namespace) (gatewayGrant ^. #workload)

compile :: [Value] -> ObjectBucket -> Either (NE.NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compile previous declared =
  compileStandaloneBucket
    BucketInput
      { bucket = declared
      , store = BucketStore "http://minio.nagare-system.svc.cluster.local:9000" ("k3d-registry.localhost:5000/nagare-mc@sha256:" <> T.replicate 64 "b")
      , cluster = fixtureCluster
      , systemNamespace = systemNs
      , namespaces = Map.singleton "personal" personal
      , storeReady = storeJob
      , previous = previous
      , source = SourceLocation "Buckets.hs" "publications"
      }

publications :: ObjectBucket
publications =
  ObjectBucket
    { name = ok (mkBucketName "publications")
    , logicalKey = Nothing
    , expire = [ExpireRule (ok (mkObjectPrefix "staging/")) (ok (mkPositiveDays 1))]
    , grants = [apiGrant, gatewayGrant]
    }

apiGrant, gatewayGrant :: BucketGrant
apiGrant = BucketGrant (ok (mkNamespace "personal")) (ok (mkServiceName "content-app")) ReadWrite True
gatewayGrant = BucketGrant (ok (mkNamespace "personal")) (ok (mkServiceName "content-gateway")) ReadOnly False

fixtureCluster, systemNs, personal, storeJob :: ResourceId
fixtureCluster = mintResourceId (ok (mkScopeId Platform "cluster")) (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
systemNs = mintResourceId (ok (mkScopeId Platform "foundation")) (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-nagare-system"))
personal = mintResourceId (ok (mkScopeId Platform "foundation")) (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-personal"))
storeJob = mintResourceId (ok (mkScopeId Platform "local-object-store")) (ok (mkLogicalKey "local-object-store")) (ok (mkName "bucket"))

snapshotOf :: [ScopeDeclaration] -> ScopeSnapshot
snapshotOf scopes = ok (mkScopeSnapshot fixtureBinding (Map.fromList [(scopeId scope, (ok (mkScopeGeneration 1), scope)) | scope <- scopes]) Map.empty)

member' :: (Text, Text, Text) -> Map ResourceId (ManagedResource, ByteString) -> ManagedResource
member' wanted native = case [resource | (resource, _) <- Map.elems native, located resource == wanted] of
  [found] -> found
  other -> error ("member at " <> show wanted <> ": " <> show (map (^. #identity) other))

values :: Map ResourceId (ManagedResource, ByteString) -> [Value]
values native = [Object (root bytes) | (_, bytes) <- Map.elems native]

root :: ByteString -> KM.KeyMap Value
root bytes = case Yaml.decodeEither' bytes of
  Right (Object found) -> found
  other -> error ("native object: " <> show other)

kindOf :: ManagedResource -> Text
kindOf resource = case resource ^. #address of
  Kubernetes _ _ kind _ _ -> nameText kind
  _ -> ""

located :: ManagedResource -> (Text, Text, Text)
located resource = case resource ^. #address of
  Kubernetes _ _ kind ns name -> (nameText kind, maybe "" nameText ns, nameText name)
  _ -> ("", "", "")

-- | Whether the member's role starts with the prefix.
isRole :: Text -> ManagedResource -> Bool
isRole prefix resource = ("/" <> prefix) `T.isInfixOf` resourceIdText (resource ^. #identity)

member :: Text -> Map ResourceId (ManagedResource, ByteString) -> ManagedResource
member prefix native = case [resource | (resource, _) <- Map.elems native, isRole prefix resource] of
  [found] -> found
  other -> error ("member " <> T.unpack prefix <> ": " <> show (map (^. #identity) other))

-- | The digest a member's Job name ends in.
suffix :: Text -> Map ResourceId (ManagedResource, ByteString) -> Text
suffix prefix native = let (_, _, name) = located (member prefix native) in T.takeEnd 8 name

annotation :: Text -> ByteString -> Maybe Text
annotation key bytes = case KM.lookup "metadata" (root bytes) of
  Just (Object metadata) | Just (Object annotations) <- KM.lookup "annotations" metadata, Just (String found) <- KM.lookup (Key.fromText key) annotations -> Just found
  _ -> Nothing

-- | The container command of a Job.
command :: ByteString -> [Text]
command bytes = [text | String text <- concatMap list (path ["spec", "template", "spec", "containers"] (Object (root bytes)) >>= list >>= path ["command"])]
  where
    list = \case
      Array found -> foldr (:) [] found
      _ -> []
    path keys value = foldl (\found key -> [next | Object object' <- found, Just next <- [KM.lookup key object']]) [value] keys

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
