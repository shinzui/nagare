-- | EP-237 M4: status names the image each release workload runs, and is
-- exact only when every enabled workload's ready replicas run this release's
-- image. It needs no image environment input and writes nothing.
module ImageStatusSpec (imageStatusTests) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Contract.ReleaseImages
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Ops.Probe (Probe (..), ProbeStatus (StatusWarn))
import Nagare.Platform.Deployment (DeploymentState (..))
import Nagare.Platform.ImageStatus
import Nagare.Platform.Status
import Nagare.Version (Compatibility (..))
import Test.Tasty
import Test.Tasty.HUnit

imageStatusTests :: TestTree
imageStatusTests =
  testGroup
    "release image status"
    [ testCase "ready replicas of every workload on this release's images are exact" $ do
        let statuses = assess True (current (release 'b'))
        map (^. #classification) statuses @?= replicate 4 ImageRelease
        withImageAssessment (Just (release 'b')) statuses exact ^. #compatibility @?= Exact
    , testCase "a previous release's live digest is skew although every version marker agrees" $ do
        let observed = Map.insert ShomeiImage (Right (Just (seenAs ShomeiImage 'a' "release" 'a' ['a']))) (current (release 'b'))
            statuses = assess True observed
            status = withImageAssessment (Just (release 'b')) statuses exact
        classificationOf ShomeiImage statuses @?= ImageOtherRelease
        status ^. #compatibility @?= ImageSkew
        platformProbe status ^. #status @?= StatusWarn
        assertBool "the probe does not name the stale workload" ("shomei other-release" `T.isInfixOf` (platformProbe status ^. #detail))
        guardPlatformMutation status @?= Right ()
        guardTransitionMutation status @?= Right ()
    , testCase "a reviewed override is named and non-exact; one equal to the release is the release" $ do
        let overridden = assess True (Map.insert AdminApiImage (Right (Just (seenAs AdminApiImage 'f' "override" 'b' ['f']))) (current (release 'b')))
            same = assess True (Map.insert AdminApiImage (Right (Just (seenAs AdminApiImage 'b' "override" 'b' ['b']))) (current (release 'b')))
        classificationOf AdminApiImage overridden @?= ImageOverride
        [classificationOf key overridden | key <- [EnImage, ShomeiImage, AccessImage]] @?= replicate 3 ImageRelease
        withImageAssessment (Just (release 'b')) overridden exact ^. #compatibility @?= ImageSkew
        classificationOf AdminApiImage same @?= ImageRelease
        sourceOf AdminApiImage same @?= Just "override"
    , testCase "an image no release or reviewed selection explains is drift, not a guessed version" $ do
        let edited = assess True (Map.insert EnImage (Right (Just (seenAs EnImage 'e' "release" 'b' ['e']))) (current (release 'b')))
            unrecorded = assess True (Map.insert EnImage (Right (Just (WorkloadObservation (ref EnImage 'e') Nothing Nothing [imageId EnImage 'e']))) (current (release 'b')))
        classificationOf EnImage edited @?= ImageDrift
        classificationOf EnImage unrecorded @?= ImageDrift
    , testCase "mixed, missing, unreadable and unparseable observations are unknown, never release" $ do
        let with key observation = classificationOf key (assess True (Map.insert key observation (current (release 'b'))))
        with EnImage (Right (Just (seenAs EnImage 'b' "release" 'b' ['a', 'b']))) @?= ImageUnknown
        with EnImage (Right (Just (seenAs EnImage 'b' "release" 'b' ['a']))) @?= ImageUnknown
        with EnImage (Right (Just (seenAs EnImage 'b' "release" 'b' []))) @?= ImageUnknown
        with EnImage (Right (Just (WorkloadObservation (ref EnImage 'b') (Just "release") Nothing ["sha256:" <> T.replicate 64 "b"]))) @?= ImageUnknown
        with ShomeiImage (Right Nothing) @?= ImageUnknown
        with AccessImage (Left "cannot read workload objects: forbidden") @?= ImageUnknown
        withImageAssessment
          (Just (release 'b'))
          (assess True (Map.insert ShomeiImage (Left "timeout") (current (release 'b'))))
          exact
          ^. #compatibility
          @?= ImageSkew
    , testCase "restoration is exact only once every ready replica runs the release image" $ do
        let rolling = assess True (Map.insert EnImage (Right (Just (seenAs EnImage 'b' "release" 'b' ['a', 'b']))) (current (release 'b')))
            settled = assess True (current (release 'b'))
        withImageAssessment (Just (release 'b')) rolling exact ^. #compatibility @?= ImageSkew
        withImageAssessment (Just (release 'b')) settled exact ^. #compatibility @?= Exact
    , testCase "a disabled admin API is not enabled and does not force skew; an enabled absent one does" $ do
        let absentAdmin = Map.insert AdminApiImage (Right Nothing) (current (release 'b'))
        classificationOf AdminApiImage (assess False absentAdmin) @?= ImageNotEnabled
        withImageAssessment (Just (release 'b')) (assess False absentAdmin) exact ^. #compatibility @?= Exact
        classificationOf AdminApiImage (assess True absentAdmin) @?= ImageUnknown
    , testCase "version diagnoses stay stronger, and a payload without release images keeps its aggregate" $ do
        let stale = assess True (Map.insert EnImage (Right (Just (seenAs EnImage 'a' "release" 'a' ['a']))) (current (release 'b')))
            patch = assessPlatformStatus identity identity (ReleaseIdentity (Just "1.2.4") Nothing Nothing) identity Deployed identity Deployed
        withImageAssessment (Just (release 'b')) stale patch ^. #compatibility @?= PatchSkew
        let legacy = assessWorkloadImages True Nothing (current (release 'b'))
        withImageAssessment Nothing legacy exact ^. #compatibility @?= Exact
    , testCase "kubectl lists decode into workload observations by exact container and ready replica" $ do
        let observations = observeWorkloads (Right deploymentsJson) (Right servicesJson) (Right podsJson)
        Map.lookup EnImage observations
          @?= Just (Right (Just (WorkloadObservation (ref EnImage 'b') (Just "release") (Just (ref EnImage 'b')) [imageId EnImage 'b'])))
        Map.lookup AccessImage observations
          @?= Just (Right (Just (WorkloadObservation (ref AccessImage 'b') (Just "override") Nothing ["docker-pullable://" <> imageId AccessImage 'b'])))
        Map.lookup AdminApiImage observations @?= Just (Right Nothing)
        classificationOf AccessImage (assessWorkloadImages True (Just (release 'b')) observations) @?= ImageRelease
        case Map.lookup ShomeiImage (observeWorkloads (Left "forbidden") (Right servicesJson) (Right podsJson)) of
          Just (Left _) -> pure ()
          other -> assertFailure ("an unreadable Deployment list was " <> show other)
    , testCase "status JSON names each workload's expected, selected and observed image" $ do
        let statuses = assess True (Map.insert AdminApiImage (Right (Just (seenAs AdminApiImage 'f' "override" 'b' ['f']))) (current (release 'b')))
            value = platformStatusValue (withImageAssessment (Just (release 'b')) statuses exact)
            encoded = LBS.toStrict (Aeson.encode value)
        assertBool "status JSON lacks the image-skew aggregate" ("\"compatibility\":\"image-skew\"" `isInfix` encoded)
        assertBool "status JSON lacks the override classification" ("\"classification\":\"override\"" `isInfix` encoded)
        assertBool "status JSON lacks the observed override" (ref AdminApiImage 'f' `isInfix` encoded)
    ]

-- Fixtures

release :: Char -> ReleaseImages
release c = ReleaseImages releaseImagesSchemaVersion (Map.fromList [(key, image key) | key <- releaseImageKeys])
  where
    image key = ReleaseImage releaseImagePlatform (digestOf c) ("/nix/store/" <> releaseImageKeyText key <> "-oci") Map.empty

repositoryOf :: ReleaseImageKey -> Text
repositoryOf key = "registry.example.test/nagare/" <> releaseImageKeyText key

digestOf :: Char -> Text
digestOf c = "sha256:" <> T.replicate 64 (T.singleton c)

ref :: ReleaseImageKey -> Char -> Text
ref key c = repositoryOf key <> "@" <> digestOf c

imageId :: ReleaseImageKey -> Char -> Text
imageId = ref

-- | A workload naming image @spec@, recorded with @source@ against release
-- image @recorded@, whose ready replicas run @running@.
seenAs :: ReleaseImageKey -> Char -> Text -> Char -> [Char] -> WorkloadObservation
seenAs key spec source recorded running =
  WorkloadObservation (ref key spec) (Just source) (Just (ref key recorded)) (map (imageId key) running)

current :: ReleaseImages -> Map.Map ReleaseImageKey (Either Text (Maybe WorkloadObservation))
current images =
  Map.fromList
    [ (key, Right (Just (seenAs key c "release" c [c])))
    | key <- releaseImageKeys
    , let c = maybe 'x' (T.last . (^. #digest)) (lookupReleaseImage key images)
    ]

assess :: Bool -> Map.Map ReleaseImageKey (Either Text (Maybe WorkloadObservation)) -> [WorkloadImageStatus]
assess adminEnabled = assessWorkloadImages adminEnabled (Just (release 'b'))

classificationOf :: ReleaseImageKey -> [WorkloadImageStatus] -> ImageClassification
classificationOf key statuses = case [value ^. #classification | value <- statuses, value ^. #workload == releaseImageKeyText key] of
  [one] -> one
  _ -> error "no status for workload"

sourceOf :: ReleaseImageKey -> [WorkloadImageStatus] -> Maybe Text
sourceOf key statuses = case [value ^. #source | value <- statuses, value ^. #workload == releaseImageKeyText key] of
  [one] -> one
  _ -> error "no status for workload"

identity :: ReleaseIdentity
identity = ReleaseIdentity (Just "1.2.3") Nothing (Just 1)

exact :: PlatformStatus
exact = assessPlatformStatus identity identity identity identity Deployed identity Deployed

isInfix :: Text -> ByteString -> Bool
isInfix needle haystack = needle `T.isInfixOf` TE.decodeUtf8 haystack

listOf :: [Value] -> ByteString
listOf values = LBS.toStrict (Aeson.encode (object ["apiVersion" .= ("v1" :: Text), "kind" .= ("List" :: Text), "items" .= values]))

deploymentsJson :: ByteString
deploymentsJson =
  listOf
    [ deployment "en" (ref EnImage 'b') [("nagare.dev/image-source", "release"), ("nagare.dev/release-image", ref EnImage 'b')]
    , deployment "shomei" (ref ShomeiImage 'b') [("nagare.dev/image-source", "release")]
    ]
  where
    deployment :: Text -> Text -> [(Text, Text)] -> Value
    deployment name image annotations =
      object
        [ "kind" .= ("Deployment" :: Text)
        , "metadata" .= object ["name" .= name, "annotations" .= Map.fromList annotations]
        , "spec"
            .= object
              [ "template"
                  .= object
                    [ "spec"
                        .= object
                          [ "containers"
                              .= [ object ["name" .= ("sidecar" :: Text), "image" .= ("busybox:latest" :: Text)]
                                 , object ["name" .= name, "image" .= image]
                                 ]
                          ]
                    ]
              ]
        ]

servicesJson :: ByteString
servicesJson =
  listOf
    [ object
        [ "kind" .= ("Service" :: Text)
        , "metadata" .= object ["name" .= ("nagare-access" :: Text), "annotations" .= object ["nagare.dev/image-source" .= ("override" :: Text)]]
        , "spec" .= object ["template" .= object ["spec" .= object ["containers" .= [object ["image" .= ref AccessImage 'b']]]]]
        ]
    ]

podsJson :: ByteString
podsJson =
  listOf
    [ pod [("app.kubernetes.io/name", "en")] True [("en", imageId EnImage 'b'), ("sidecar", "docker.io/library/busybox@sha256:" <> T.replicate 64 "9")]
    , pod [("app.kubernetes.io/name", "en")] False [("en", imageId EnImage 'a')]
    , pod [("serving.knative.dev/service", "nagare-access")] True [("user-container", "docker-pullable://" <> imageId AccessImage 'b'), ("queue-proxy", "gcr.io/knative@sha256:" <> T.replicate 64 "8")]
    ]
  where
    pod :: [(Text, Text)] -> Bool -> [(Text, Text)] -> Value
    pod labels ready containers =
      object
        [ "kind" .= ("Pod" :: Text)
        , "metadata" .= object ["name" .= ("pod" :: Text), "labels" .= Map.fromList labels]
        , "status"
            .= object
              [ "conditions" .= [object ["type" .= ("Ready" :: Text), "status" .= (if ready then "True" else "False" :: Text)]]
              , "containerStatuses" .= [object ["name" .= name, "imageID" .= image] | (name, image) <- containers]
              ]
        ]
