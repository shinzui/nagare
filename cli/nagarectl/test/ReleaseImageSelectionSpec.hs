-- | EP-237 M3: release payloads select their service images unless an
-- immutable override names one, and the selection reaches the reviewed
-- workloads, their migration Jobs and their recorded intent.
module ReleaseImageSelectionSpec (releaseImageSelectionTests) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Contract.ReleaseImages
import Nagare.Dsl.Prelude
import Nagare.Inventory.Artifact (ArtifactExecutionSpec (..), artifactExecutionSpecsFromDeclarations)
import Nagare.Inventory.Components.AdminApi (AdminApiInput (..), AdminApiStore (LocalMountedStore), compileAdminApi)
import Nagare.Inventory.Components.Auth
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
import Nagare.Inventory.Components.ReleaseImage (compileReleaseImages)
import Nagare.Platform.ReleaseImages
import Nagare.Platform.Workspace (PayloadManifest)
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

releaseImageSelectionTests :: TestTree
releaseImageSelectionTests =
  testGroup
    "release image selection"
    [ testGroup
        "release.json releaseImages"
        [ testCase "a complete manifest decodes and a payload without one keeps the explicit path" $ do
            decoded <- expectRight (eitherDecodeStrict' (manifestJson (Just (imagesJson 'a'))) :: Either String PayloadManifest)
            decoded ^. #releaseImages @?= Just (release 'a')
            legacy <- expectRight (eitherDecodeStrict' (manifestJson Nothing) :: Either String PayloadManifest)
            legacy ^. #releaseImages @?= Nothing
        , testCase "a release missing an image, on another platform, or with a malformed digest or store path refuses" $ do
            let refused label value = case eitherDecodeStrict' (manifestJson (Just value)) :: Either String PayloadManifest of
                  Left _ -> pure ()
                  Right _ -> assertFailure (label <> ": accepted")
            refused "three images" (BC.pack (T.unpack (T.replace "\"nagare-admin-api\"" "\"other\"" (T.pack (BC.unpack (imagesJson 'a'))))))
            refused "linux/arm64" (BC.pack (T.unpack (T.replace "linux/amd64" "linux/arm64" (T.pack (BC.unpack (imagesJson 'a'))))))
            refused "schema 2" (BC.pack (T.unpack (T.replace "\"schemaVersion\":1" "\"schemaVersion\":2" (T.pack (BC.unpack (imagesJson 'a'))))))
            let withEn change = (release 'a') {images = Map.adjust change EnImage (images (release 'a'))}
            assertBool "a tag validated as a digest" (isLeftValue (validateReleaseImages (withEn (\image -> image {digest = "latest"}))))
            assertBool "a relative store path validated" (isLeftValue (validateReleaseImages (withEn (\image -> image {storePath = "nagare-en-oci"}))))
        ]
    , testGroup
        "resolution"
        [ testCase "the release image is the default and an immutable override wins" $ do
            resolveImage registry EnImage (Just (release 'a')) Nothing @?= Right (ImageSelection (Just (ref EnImage 'a')) (ref EnImage 'a') ReleaseSource)
            resolveImage "other.example.test/project/repo" EnImage (Just (release 'a')) Nothing
              @?= Right (let reference = "other.example.test/project/repo/en@" <> digestOf 'a' in ImageSelection (Just reference) reference ReleaseSource)
            resolveImage registry EnImage (Just (release 'a')) (Just (ref EnImage 'f'))
              @?= Right (ImageSelection (Just (ref EnImage 'a')) (ref EnImage 'f') OverrideSource)
        , testCase "a mutable override refuses and a payload without metadata requires every image" $ do
            resolveImage registry ShomeiImage (Just (release 'a')) (Just "registry.example.test/shomei:latest")
              @?= Left (MutableOverride ShomeiImage "registry.example.test/shomei:latest")
            resolveImage registry AdminApiImage Nothing Nothing @?= Left (NoReleaseImage AdminApiImage)
            assertBool
              "the refusal does not name the override variable"
              ("NAGARE_ADMIN_API_IMAGE" `T.isInfixOf` renderImageSelectionError (NoReleaseImage AdminApiImage))
            resolveImage registry AdminApiImage Nothing (Just (ref AdminApiImage 'f'))
              @?= Right (ImageSelection Nothing (ref AdminApiImage 'f') OverrideSource)
        ]
    , testGroup
        "reviewed workloads"
        [ testCase "a new release moves every auth workload and its migration Job, with no image input" $ do
            source <- compileFor (selections (release 'a') Map.empty)
            target <- compileFor (selections (release 'b') Map.empty)
            forM_ ["en", "shomei", "nagare-access"] $ \name -> do
              workloadImages source name @?= [ref (keyNamed name) 'a']
              workloadImages target name @?= [ref (keyNamed name) 'b']
              annotation target name imageSourceAnnotation @?= Just "release"
              annotation target name releaseImageAnnotation @?= Just (ref (keyNamed name) 'b')
            forM_ [("en", EnImage), ("shomei", ShomeiImage)] $ \(name, key) -> do
              let sourceJobs = migrationJobs source name
                  targetJobs = migrationJobs target name
              map snd targetJobs @?= [[ref key 'b']]
              assertBool (T.unpack name <> " migration Job kept its identity") (map fst sourceJobs /= map fst targetJobs)
            changedWorkloads source target
              @?= ["Deployment/en", "Deployment/shomei", "Job/en-migrate", "Job/shomei-migrate", "Service/nagare-access"]
        , testCase "an override moves only its workload and is recorded; removing it restores the release" $ do
            released <- compileFor (selections (release 'b') Map.empty)
            overridden <- compileFor (selections (release 'b') (Map.singleton EnImage (ref EnImage 'f')))
            workloadImages overridden "en" @?= [ref EnImage 'f']
            annotation overridden "en" imageSourceAnnotation @?= Just "override"
            annotation overridden "en" releaseImageAnnotation @?= Just (ref EnImage 'b')
            changedWorkloads released overridden @?= ["Deployment/en", "Job/en-migrate"]
            restored <- compileFor (selections (release 'b') Map.empty)
            snd restored @?= snd released
        , testCase "each server waits for the migration proof of its own selected image" $ do
            (bundle, native) <- compileFor (selections (release 'b') Map.empty)
            let members = [resource | Managed resource <- declarations bundle]
            forM_ [("en", EnImage), ("shomei", ShomeiImage)] $ \(name, key) -> do
              let jobIds = [identity | (identity, _) <- migrationJobs (bundle, native) name]
                  proofs =
                    [ operation ^. #identity
                    | operation <- operations bundle
                    , any (`elem` jobIds) (toList (operation ^. #affects))
                    ]
                  server = [resource | resource <- members, kindName resource == ("deployment", name)]
              map snd (migrationJobs (bundle, native) name) @?= [[ref key 'b']]
              case (proofs, server) of
                ([proof], [deployment]) ->
                  assertBool (T.unpack name <> " starts before its migration") (OrderedAfter proof `elem` deployment ^. #dependencies)
                _ -> assertFailure ("expected one proof and one server for " <> T.unpack name)
        , testCase "the admin API runs the release image unless overridden, and records which" $ do
            auth <- compileFor (selections (release 'b') Map.empty)
            authScope <- expectRight (mkScopeDeclaration fixtureOwner [fst auth])
            let declarationsOf = concatMap (^. #declarations) (scopeBundles authScope)
            forM_
              [ (resolveImage registry AdminApiImage (Just (release 'b')) Nothing, ref AdminApiImage 'b', "release")
              , (resolveImage registry AdminApiImage (Just (release 'b')) (Just (ref AdminApiImage 'f')), ref AdminApiImage 'f', "override")
              ]
              $ \(selection, expectedImage, token) -> do
                chosen <- expectRight selection
                (_, native) <- compileAdminApi (adminInput chosen) declarationsOf >>= expectRight
                let compiled = (fst auth, native)
                workloadImages compiled "nagare-admin-api" @?= [expectedImage]
                annotation compiled "nagare-admin-api" imageSourceAnnotation @?= Just token
                annotation compiled "nagare-admin-api" releaseImageAnnotation @?= Just (ref AdminApiImage 'b')
        ]
    , testGroup
        "publication"
        [ testCase "each enabled image is one artifact named by its digest, in the context's registry" $ do
            (scope, publications) <- expectRight (compileReleaseImages registry [EnImage, AccessImage] (release 'a'))
            Map.keys publications @?= [EnImage, AccessImage]
            let artifacts = artifactExecutionSpecsOf scope
            map executionArtifactDestination artifacts
              @?= [registry <> "/en:sha256-" <> T.replicate 64 "a", registry <> "/nagare-access:sha256-" <> T.replicate 64 "a"]
            map executionArtifactArchive artifacts @?= map (Just . T.unpack . storePathOf) [EnImage, AccessImage]
        , testCase "an image keeps one identity across digests, so a workload's dependency never moves" $ do
            (_, first') <- expectRight (compileReleaseImages registry [EnImage] (release 'a'))
            (_, next) <- expectRight (compileReleaseImages registry [EnImage] (release 'b'))
            next @?= first'
        , testCase "a workload waits only for its own image's publication, so moving one leaves the others alone" $ do
            let publish key = mintResourceId fixtureOwner (ok (mkLogicalKey key)) (ok (mkName "publish"))
                input = selections (release 'b') Map.empty
                waiting = Map.fromList [("en", publish "en"), ("nagare-access", publish "access")]
            (bundle, _) <- compileWith waiting input
            let members = [resource | Managed resource <- declarations bundle]
                dependsOn key resource = OrderedAfter (publish key) `elem` resource ^. #dependencies
                named kind name = [resource | resource <- members, kindName resource == (kind, name)]
            assertBool "En's server does not wait" (all (dependsOn "en") (named "deployment" "en"))
            assertBool "nagare-access does not wait" (all (dependsOn "access") (named "service" "nagare-access"))
            assertBool "Shomei waits for another image" (not (any (\resource -> dependsOn "en" resource || dependsOn "access" resource) (named "deployment" "shomei")))
            assertBool "En's server waits for another image" (not (any (dependsOn "access") (named "deployment" "en")))
        ]
    ]

-- Fixtures

release :: Char -> ReleaseImages
release c = ReleaseImages releaseImagesSchemaVersion (Map.fromList [(key, image key) | key <- releaseImageKeys])
  where
    image key = ReleaseImage releaseImagePlatform (digestOf c) (storePathOf key) (Map.singleton "fixture" (T.singleton c))

registry :: Text
registry = "registry.example.test/nagare"

storePathOf :: ReleaseImageKey -> Text
storePathOf key = "/nix/store/" <> releaseImageKeyText key <> "-oci"

digestOf :: Char -> Text
digestOf c = "sha256:" <> T.replicate 64 (T.singleton c)

ref :: ReleaseImageKey -> Char -> Text
ref key c = registry <> "/" <> releaseImageKeyText key <> "@" <> digestOf c

artifactExecutionSpecsOf :: ScopeDeclaration -> [ArtifactExecutionSpec]
artifactExecutionSpecsOf scope =
  sortOn executionArtifactDestination . Map.elems $
    either (error . T.unpack) id (artifactExecutionSpecsFromDeclarations (concatMap (^. #declarations) (scopeBundles scope)))

keyNamed :: Text -> ReleaseImageKey
keyNamed name = case [key | key <- releaseImageKeys, releaseImageKeyText key == name] of
  [key] -> key
  _ -> error ("no release image " <> T.unpack name)

imagesJson :: Char -> ByteString
imagesJson c = BC.pack (T.unpack (T.concat ["{\"schemaVersion\":1,\"images\":{", T.intercalate "," (map entry releaseImageKeys), "}}"]))
  where
    entry key =
      T.concat
        [ "\"" <> releaseImageKeyText key <> "\":{"
        , "\"platform\":\"linux/amd64\","
        , "\"digest\":\"" <> digestOf c <> "\","
        , "\"storePath\":\"" <> storePathOf key <> "\","
        , "\"sources\":{\"fixture\":\"" <> T.singleton c <> "\"}}"
        ]

manifestJson :: Maybe ByteString -> ByteString
manifestJson images =
  "{\"assetSchemaVersion\":1,\"payloadId\":\"p\",\"platformVersion\":\"0.15.0\",\"sourceRevision\":null"
    <> maybe "" (",\"releaseImages\":" <>) images
    <> "}"

selections :: ReleaseImages -> Map ReleaseImageKey Text -> Map Text ImageSelection
selections images overrides =
  Map.fromList
    [ (releaseImageKeyText key, either (error . show) id (resolveImage registry key (Just images) (Map.lookup key overrides)))
    | key <- [EnImage, ShomeiImage, AccessImage]
    ]

fixtureOwner :: ScopeId
fixtureOwner = ok (mkScopeId Platform "auth")

fixtureCluster :: ResourceId
fixtureCluster = mintResourceId fixtureOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

compileFor :: Map Text ImageSelection -> IO (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileFor = compileWith Map.empty

compileWith :: Map Text ResourceId -> Map Text ImageSelection -> IO (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileWith publications images =
  compileAuth
    AuthInput
      { authOwner = fixtureOwner
      , authCluster = fixtureCluster
      , authNamespace = mintResourceId fixtureOwner (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-nagare-system"))
      , authRoot = "../.."
      , authImages = images
      , authBaseDomain = "example.test"
      , authDatabasePrerequisites = Map.fromList [(name, mintResourceId fixtureOwner (ok (mkLogicalKey name)) (ok (mkName "database"))) | name <- ["en", "shomei"]]
      , authExtraPrerequisites = []
      , authImagePublications = publications
      , authMode = CloudAuth
      , authProxiedCacheControl = Nothing
      }
    >>= expectRight

adminInput :: ImageSelection -> AdminApiInput
adminInput selection =
  AdminApiInput
    { root = "../.."
    , foundation = FoundationInput (ok (mkScopeId Platform "foundation")) fixtureCluster "../../cluster/bootstrap/job-runs/resourcequota.yaml" []
    , baseDomain = "example.test"
    , context = "ctx"
    , project = "project"
    , image = selection
    , imagePublication = Nothing
    , store = LocalMountedStore
    }

-- Observing compiled objects

objects :: (ResourceBundle, Map ResourceId (ManagedResource, ByteString)) -> [(ResourceId, Text, Text, Value)]
objects (_, native) =
  [ (identity, kind, name, value)
  | (identity, (_, bytes)) <- Map.toList native
  , Right value@(Object root) <- [eitherDecodeStrict' bytes]
  , Just (String kind) <- [KM.lookup "kind" root]
  , Just (Object meta) <- [KM.lookup "metadata" root]
  , Just (String name) <- [KM.lookup "name" meta]
  ]

containerImages :: Value -> [Text]
containerImages value =
  [ image
  | Object root <- [value]
  , Just (Object spec) <- [KM.lookup "spec" root]
  , Just (Object template) <- [KM.lookup "template" spec]
  , Just (Object podSpec) <- [KM.lookup "spec" template]
  , Just (Array containers) <- [KM.lookup "containers" podSpec]
  , Object container <- V.toList containers
  , Just (String image) <- [KM.lookup "image" container]
  ]

workloadImages :: (ResourceBundle, Map ResourceId (ManagedResource, ByteString)) -> Text -> [Text]
workloadImages compiled name =
  concat [containerImages value | (_, kind, objectName, value) <- objects compiled, kind `elem` ["Deployment", "Service"], objectName == name]

annotation :: (ResourceBundle, Map ResourceId (ManagedResource, ByteString)) -> Text -> Text -> Maybe Text
annotation compiled name key =
  case [ text
       | (_, kind, objectName, Object root) <- objects compiled
       , kind `elem` ["Deployment", "Service"]
       , objectName == name
       , not (null (containerImages (Object root)))
       , Just (Object meta) <- [KM.lookup "metadata" root]
       , Just (Object annotations) <- [KM.lookup "annotations" meta]
       , Just (String text) <- [KM.lookup (Key.fromText key) annotations]
       ] of
    [text] -> Just text
    _ -> Nothing

migrationJobs :: (ResourceBundle, Map ResourceId (ManagedResource, ByteString)) -> Text -> [(ResourceId, [Text])]
migrationJobs compiled service =
  [ (identity, containerImages value)
  | (identity, kind, name, value) <- objects compiled
  , kind == "Job"
  , (service <> "-migrate-") `T.isPrefixOf` name
  ]

-- | The workloads whose reviewed bytes differ, a Job by its unrevised name.
changedWorkloads ::
  (ResourceBundle, Map ResourceId (ManagedResource, ByteString)) ->
  (ResourceBundle, Map ResourceId (ManagedResource, ByteString)) ->
  [Text]
changedWorkloads before after =
  Map.keys (Map.differenceWith same (keyed before) (keyed after) <> Map.difference (keyed after) (keyed before))
  where
    keyed compiled =
      Map.fromList
        [ (kind <> "/" <> stable kind name, value)
        | (_, kind, name, value) <- objects compiled
        , kind `elem` ["Deployment", "Service", "Job"]
        ]
    stable kind name
      | kind == "Job" = T.intercalate "-" (take 2 (T.splitOn "-" name))
      | otherwise = name
    same a b = if a == b then Nothing else Just a

kindName :: ManagedResource -> (Text, Text)
kindName resource = case resource ^. #address of
  Kubernetes _ _ kind _ name -> (nameText kind, nameText name)
  _ -> ("", "")

isLeftValue :: Either a b -> Bool
isLeftValue = either (const True) (const False)

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\failure -> assertFailure (show failure) >> error "unreachable") pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
