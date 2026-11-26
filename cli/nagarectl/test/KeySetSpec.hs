-- | EP-286 M3: a key set's compiled scope, and the adapter's rule for the
-- rotator's field ownership.
module KeySetSpec
  ( keySetTests
  , compileKeySet
  , viewGrants
  , keySetNamespace
  , rotatorImage
  , objectAt
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, addUTCTime)
import Data.Vector qualified as V
import Data.Yaml qualified as Yaml
import Nagare.Dsl.KeySet
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkNamespace)
import Nagare.Inventory.Adapters.CredentialTemplate (generatedCredentialTemplate)
import Nagare.Inventory.KeySet
import Nagare.Inventory.KubernetesConfiguration (foreignFieldManagers)
import Nagare.KeySet (KeyPair (..), emptyKeySet, encodePublicKeySet, rotateStep)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

keySetTests :: TestTree
keySetTests =
  testGroup
    "key set scope"
    [ testCase "a key set is seven members in its namespace, all retained and stateless" $ do
        (scope, native) <- expectRight (compileKeySet rotatorImage viewGrants)
        scopeIdText (scopeId scope) @?= "standalone:keyset-view-grants"
        sort [located resource | (resource, _) <- Map.elems native]
          @?= sort
            [ ("configmap", "personal", "nagare-keyset-view-grants-public")
            , ("cronjob", "personal", "nagare-keyset-view-grants")
            , ("job", "personal", "nagare-keyset-view-grants-first-" <> firstSuffix native)
            , ("role", "personal", "nagare-keyset-view-grants")
            , ("rolebinding", "personal", "nagare-keyset-view-grants")
            , ("secret", "personal", "nagare-keyset-view-grants")
            , ("serviceaccount", "personal", "nagare-keyset-view-grants")
            ]
        forM_ (Map.elems native) $ \(resource, _) -> do
          resource ^. #lifecycle @?= Retain
          resource ^. #dataPolicy @?= Stateless
        scopeKeySet scope @?= Just viewGrants
    , testCase "no reviewed byte holds a key: the Secret has no data and the ConfigMap only the policy" $ do
        (_, native) <- expectRight (compileKeySet rotatorImage viewGrants)
        let secret = objectAt "secret" native
            configMap = objectAt "configmap" native
        KM.member "data" secret @?= False
        KM.member "stringData" secret @?= False
        KM.lookup "data" configMap @?= Just (object ["policy.json" .= ("{\"overlapMinutes\":10,\"periodMinutes\":60}" :: Text)])
        -- An ordinary Secret: its reviewed metadata updates in place, and the rotator's key survives it.
        generatedCredentialTemplate (bytesAt "secret" native) @?= Right False
    , testCase "the rotator may get and update only its two objects" $ do
        (_, native) <- expectRight (compileKeySet rotatorImage viewGrants)
        KM.lookup "rules" (objectAt "role" native)
          @?= Just
            ( toJSONList
                [ object ["apiGroups" .= [("" :: Text)], "resources" .= [("secrets" :: Text)], "resourceNames" .= [("nagare-keyset-view-grants" :: Text)], "verbs" .= (["get", "update"] :: [Text])]
                , object ["apiGroups" .= [("" :: Text)], "resources" .= [("configmaps" :: Text)], "resourceNames" .= [("nagare-keyset-view-grants-public" :: Text)], "verbs" .= (["get", "update"] :: [Text])]
                ]
            )
    , testCase "the first-run Job waits for the objects, the account and its grant, and keySetFirstRunJob finds it" $ do
        (scope, native) <- expectRight (compileKeySet rotatorImage viewGrants)
        let job = memberOf "job" native
            producers = [producer | OrderedAfter producer <- job ^. #dependencies]
        sort (map (kindOf . fst . (native Map.!)) producers) @?= ["configmap", "role", "rolebinding", "secret", "serviceaccount"]
        keySetFirstRunJob native (scopeId scope) @?= Just (job ^. #identity)
    , testCase "a new image is a new first-run Job; a policy change changes only the ConfigMap" $ do
        (_, before) <- expectRight (compileKeySet rotatorImage viewGrants)
        (_, image') <- expectRight (compileKeySet ("k3d-registry.localhost:5000/nagare-admin-api@sha256:" <> T.replicate 64 "d") viewGrants)
        assertBool "the Job is renamed" (firstSuffix before /= firstSuffix image')
        let slower = viewGrants & #rotation .~ ok (mkRotationPolicy (ok (mkMinutes 120)) (ok (mkMinutes 10)))
        (_, policy') <- expectRight (compileKeySet rotatorImage slower)
        [located resource | (identity, (resource, bytes)) <- Map.toList policy', Just (_, earlier) <- [Map.lookup identity before], earlier /= bytes] @?= [("configmap", "personal", "nagare-keyset-view-grants-public")]
        Map.keys policy' @?= Map.keys before
    , testCase "status reads the public file: the policy, each key and the rotations" $ do
        let now = read "2026-12-01 00:00:00 UTC" :: UTCTime
            later = addUTCTime (61 * 60) now
            pair n = KeyPair (BS.replicate 32 n) (BS.replicate 32 (n + 1))
            policy = viewGrants ^. #rotation
            (first', _) = rotateStep now policy [pair 1, pair 3] emptyKeySet
            (second', _) = rotateStep later policy [pair 5] first'
        lines' <- expectRight (keySetStatusLines viewGrants (LBS.toStrict (encodePublicKeySet policy second')))
        lines'
          @?= [ "view-grants  period 1h  overlap 10m"
              , "  next      k3  published 2026-12-01T01:01:00Z"
              , "  active    k2  since     2026-12-01T01:01:00Z"
              , "  previous  k1  until     2026-12-01T01:11:00Z"
              , "rotations: k2 2026-12-01T01:01:00Z, k1 2026-12-01T00:00:00Z"
              ]
        -- A private file is never what status reads, but it parses the same.
        assertBool "a malformed file is refused" (either (const True) (const False) (keySetStatusLines viewGrants "{}"))
    , testCase "a mutable image is refused" $
        case compileKeySet "k3d-registry.localhost:5000/nagare-admin-api:latest" viewGrants of
          Left errors -> map (^. #code) (NE.toList errors) @?= ["invalid-key-set"]
          Right _ -> assertFailure "a mutable image compiled"
    , testGroup
        "the rotator's field ownership"
        [ testCase "the rotator owning its key file is no foreign writer" $ do
            foreignFieldManagers (Just secretAddress) (owned "nagare-keyset" [["f:data", "."], ["f:data", "f:private.json"]]) @?= Right []
            foreignFieldManagers (Just publicAddress) (owned "nagare-keyset" [["f:data", "f:public.json"]]) @?= Right []
        , testCase "the rotator owning any other field, or the other object's key, is foreign" $ do
            let foreignOf address paths = either (const 0) length (foreignFieldManagers (Just address) (owned "nagare-keyset" paths))
            foreignOf publicAddress [["f:data", "f:public.json"], ["f:data", "f:policy.json"]] @?= (1 :: Int)
            foreignOf publicAddress [["f:data", "f:private.json"]] @?= 1
            foreignOf secretAddress [["f:data", "f:public.json"]] @?= 1
            foreignOf secretAddress [["f:data", "f:private.json"], ["f:metadata", "f:labels", "f:x"]] @?= 1
            foreignOf secretAddress [["f:data", "."]] @?= 1
            foreignOf otherSecret [["f:data", "f:private.json"]] @?= 1
        , testCase "another writer of the key file is foreign" $
            either (const 0) length (foreignFieldManagers (Just publicAddress) (owned "kubectl-edit" [["f:data", "f:public.json"]])) @?= (1 :: Int)
        ]
    ]
  where
    secretAddress = address' "secret" "nagare-keyset-view-grants"
    publicAddress = address' "configmap" "nagare-keyset-view-grants-public"
    otherSecret = address' "secret" "app-secrets"
    address' kind name = Kubernetes clusterId "" (ok (mkName kind)) (Just (ok (mkName "personal"))) (ok (mkName name))
    clusterId = mintResourceId (ok (mkScopeId Platform "cluster")) (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
    owned manager paths =
      object
        [ "metadata"
            .= object
              [ "managedFields"
                  .= [ object ["manager" .= ("nagare-inventory" :: Text), "operation" .= ("Apply" :: Text), "fieldsV1" .= object ["f:metadata" .= object ["f:name" .= object []]]]
                     , object ["manager" .= (manager :: Text), "operation" .= ("Update" :: Text), "fieldsV1" .= tree paths]
                     ]
              ]
        ]
    tree :: [[Text]] -> Value
    tree paths = Object (KM.fromMapText (Map.fromListWith merge [(h, tree [rest | not (null rest)]) | h : rest <- paths]))
    merge (Object a) (Object b) = Object (KM.unionWith merge a b)
    merge a _ = a
    toJSONList = Array . V.fromList

compileKeySet :: Text -> KeySet -> Either (NE.NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileKeySet image' declared =
  compileStandaloneKeySet
    KeySetInput
      { keySet = declared
      , image = image'
      , imagePublication = Nothing
      , cluster = mintResourceId (ok (mkScopeId Platform "cluster")) (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      , namespace = keySetNamespace
      , source = SourceLocation "KeySets.hs" "view-grants"
      }

viewGrants :: KeySet
viewGrants =
  KeySet
    { name = ok (mkKeySetName "view-grants")
    , logicalKey = Nothing
    , namespace = ok (mkNamespace "personal")
    , rotation = ok (mkRotationPolicy (ok (mkMinutes 60)) (ok (mkMinutes 10)))
    }

keySetNamespace :: ResourceId
keySetNamespace = mintResourceId (ok (mkScopeId Platform "foundation")) (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-personal"))

rotatorImage :: Text
rotatorImage = "k3d-registry.localhost:5000/nagare-admin-api@sha256:" <> T.replicate 64 "c"

memberOf :: Text -> Map ResourceId (ManagedResource, ByteString) -> ManagedResource
memberOf kind native = case [resource | (resource, _) <- Map.elems native, kindOf resource == kind] of
  [found] -> found
  other -> error ("member of kind " <> T.unpack kind <> ": " <> show (map (^. #identity) other))

bytesAt :: Text -> Map ResourceId (ManagedResource, ByteString) -> Text
bytesAt kind native = TE.decodeUtf8 (snd (native Map.! (memberOf kind native ^. #identity)))

-- | The native object of the one member of a kind.
objectAt :: Text -> Map ResourceId (ManagedResource, ByteString) -> KM.KeyMap Value
objectAt kind native = case Yaml.decodeEither' (snd (native Map.! (memberOf kind native ^. #identity))) of
  Right (Object found) -> found
  other -> error ("native object: " <> show other)

firstSuffix :: Map ResourceId (ManagedResource, ByteString) -> Text
firstSuffix native = let (_, _, name) = located (memberOf "job" native) in T.takeEnd 8 name

kindOf :: ManagedResource -> Text
kindOf resource = case resource ^. #address of
  Kubernetes _ _ kind _ _ -> nameText kind
  _ -> ""

located :: ManagedResource -> (Text, Text, Text)
located resource = case resource ^. #address of
  Kubernetes _ _ kind ns name -> (nameText kind, maybe "" nameText ns, nameText name)
  _ -> ("", "", "")

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
