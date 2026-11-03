-- | Which images the release workloads actually run (EP-237 M4, IR-39). The
-- cluster version marker can be right while a workload is stale, so status
-- compares each enabled workload's reviewed image, its recorded selection
-- and the image its ready replicas report against the payload's
-- @releaseImages@, by digest alone, whatever registry an image was pulled
-- from. Any read that fails, and any identity that cannot be parsed, is
-- unknown, never success.
module Nagare.Platform.ImageStatus
  ( ImageClassification (..)
  , WorkloadObservation (..)
  , WorkloadImageStatus (..)
  , imageClassificationToken
  , observeWorkloads
  , assessWorkloadImage
  , assessWorkloadImages
  , imageIdDigest
  , imageStatusValue
  , renderImageStatusLine
  , imagesAreExact
  )
where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Contract.ReleaseImages
  ( ReleaseImageKey (..)
  , ReleaseImages
  , lookupReleaseImage
  , referenceDigest
  , releaseImageKeyText
  , releaseImageKeys
  )
import Nagare.Dsl.Prelude
import Nagare.Platform.ReleaseImages (imageSourceAnnotation, releaseImageAnnotation)

data ImageClassification
  = -- | Ready replicas run the payload's release image.
    ImageRelease
  | -- | A reviewed override other than the release image.
    ImageOverride
  | -- | The release image of the release that reviewed it, not this payload's.
    ImageOtherRelease
  | -- | Neither the release nor a recorded intent explains the image.
    ImageDrift
  | ImageUnknown
  | ImageNotEnabled
  deriving stock (Eq, Show, Generic)

imageClassificationToken :: ImageClassification -> Text
imageClassificationToken = \case
  ImageRelease -> "release"
  ImageOverride -> "override"
  ImageOtherRelease -> "other-release"
  ImageDrift -> "drift"
  ImageUnknown -> "unknown"
  ImageNotEnabled -> "not-enabled"

-- | One workload as the cluster reports it: the image its reviewed object
-- names, the recorded selection, and the image each ready replica runs.
data WorkloadObservation = WorkloadObservation
  { specImage :: !Text
  , imageSource :: !(Maybe Text)
  , recordedRelease :: !(Maybe Text)
  , readyImageIds :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

data WorkloadImageStatus = WorkloadImageStatus
  { workload :: !Text
  , expected :: !(Maybe Text)
  , selected :: !(Maybe Text)
  , observed :: ![Text]
  , source :: !(Maybe Text)
  , classification :: !ImageClassification
  , reason :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | The workload object and the container that runs the image.
workloadTarget :: ReleaseImageKey -> (Text, Text, Text, (Text, Text))
workloadTarget = \case
  EnImage -> ("Deployment", "en", "en", ("app.kubernetes.io/name", "en"))
  ShomeiImage -> ("Deployment", "shomei", "shomei", ("app.kubernetes.io/name", "shomei"))
  AccessImage -> ("Service", "nagare-access", "user-container", ("serving.knative.dev/service", "nagare-access"))
  AdminApiImage -> ("Deployment", "nagare-admin-api", "nagare-admin-api", ("app.kubernetes.io/name", "nagare-admin-api"))
  CloudflaredImage -> ("Deployment", "cloudflared", "cloudflared", ("app.kubernetes.io/name", "cloudflared"))

-- | Decode @kubectl get … -o json@ lists of the Deployments, Knative Services
-- and Pods in nagare-system. @Left@ is a failed or unreadable read;
-- @Right Nothing@ is a workload that does not exist.
observeWorkloads ::
  Either Text ByteString ->
  Either Text ByteString ->
  Either Text ByteString ->
  Map ReleaseImageKey (Either Text (Maybe WorkloadObservation))
observeWorkloads deployments services pods =
  Map.fromList [(key, observe key) | key <- releaseImageKeys]
  where
    observe key = do
      let (kind, name, container, selector) = workloadTarget key
      objects <- items "workload" (if kind == "Deployment" then deployments else services)
      case [object | object <- objects, metadataText "name" object == Just name] of
        [] -> Right Nothing
        [object] -> do
          spec <- maybe (Left (name <> " names no image for container " <> container)) Right (templateImage container object)
          podObjects <- items "Pod" pods
          let ready =
                [ imageId
                | pod <- podObjects
                , labelValue (fst selector) pod == Just (snd selector)
                , current object pod
                , podReady pod
                , Just imageId <- [containerImageId container pod]
                ]
          Right
            ( Just
                WorkloadObservation
                  { specImage = spec
                  , imageSource = annotation imageSourceAnnotation object
                  , recordedRelease = annotation releaseImageAnnotation object
                  , readyImageIds = ready
                  }
            )
        _ -> Left ("more than one " <> kind <> " is named " <> name)
    items label = \case
      Left failure -> Left ("cannot read " <> label <> " objects: " <> failure)
      Right bytes -> case Aeson.decodeStrict' bytes of
        Just (Object root) | Just (Array values) <- KM.lookup "items" root -> Right (V.toList values)
        _ -> Left (label <> " list is not a Kubernetes List")
    metadata (Object root) = case KM.lookup "metadata" root of
      Just (Object fields) -> fields
      _ -> KM.empty
    metadata _ = KM.empty
    metadataText field object = case KM.lookup field (metadata object) of
      Just (String value) -> Just value
      _ -> Nothing
    nested field object = case KM.lookup field (metadata object) of
      Just (Object values) -> values
      _ -> KM.empty
    annotation key object = case KM.lookup (fromText key) (nested "annotations" object) of
      Just (String value) -> Just value
      _ -> Nothing
    labelValue key object = case KM.lookup (fromText key) (nested "labels" object) of
      Just (String value) -> Just value
      _ -> Nothing
    templateImage container object =
      case [ (containerName, image)
           | Object entry <- path ["spec", "template", "spec", "containers"] object
           , Just (String image) <- [KM.lookup "image" entry]
           , let containerName = case KM.lookup "name" entry of
                   Just (String value) -> value
                   _ -> "user-container"
           ] of
        [(_, image)] -> Just image
        many -> lookup container many
    path [] value = case value of
      Array values -> V.toList values
      _ -> []
    path (field : rest) (Object fields) = maybe [] (path rest) (KM.lookup field fields)
    path _ _ = []
    -- A Pod shutting down serves nothing new, and a Knative Service keeps its
    -- previous revision's Pods until they scale away after the route has moved,
    -- so neither says what the workload runs. A Service counts only the Pods of
    -- its latest ready revision.
    current object pod =
      isNothing (KM.lookup "deletionTimestamp" (metadata pod))
        && case [revision | Just (Object status) <- [objectField "status" object], Just (String revision) <- [KM.lookup "latestReadyRevisionName" status]] of
          [revision] -> labelValue "serving.knative.dev/revision" pod == Just revision
          _ -> True
    objectField field (Object fields) = KM.lookup field fields
    objectField _ _ = Nothing
    podReady pod =
      not (null [() | Object condition <- path ["status", "conditions"] pod, KM.lookup "type" condition == Just (String "Ready"), KM.lookup "status" condition == Just (String "True")])
    containerImageId container pod =
      case [ imageId
           | Object entry <- path ["status", "containerStatuses"] pod
           , KM.lookup "name" entry == Just (String container)
           , Just (String imageId) <- [KM.lookup "imageID" entry]
           ] of
        [imageId] -> Just imageId
        _ -> Nothing
    fromText = Key.fromText

-- | The manifest digest in a container runtime image ID
-- (@[docker-pullable://]repository\@sha256:…@); a bare local image ID
-- names no manifest and is not an identity this check can compare.
imageIdDigest :: Text -> Maybe Text
imageIdDigest imageId =
  referenceDigest (foldr (\prefix value -> fromMaybe value (T.stripPrefix prefix value)) imageId ["docker-pullable://", "docker://"])

-- | Classify one workload. @enabled@ is whether the context runs it.
assessWorkloadImage ::
  ReleaseImageKey ->
  Bool ->
  Maybe ReleaseImages ->
  Either Text (Maybe WorkloadObservation) ->
  WorkloadImageStatus
assessWorkloadImage key enabled release observation
  | not enabled = status Nothing ImageNotEnabled "the context does not enable it"
  | otherwise = case observation of
      Left failure -> status Nothing ImageUnknown failure
      Right Nothing -> status Nothing ImageUnknown "the workload does not exist"
      Right (Just seen) -> classify seen
  where
    name = releaseImageKeyText key
    expectedDigest = (^. #digest) <$> (release >>= lookupReleaseImage key)
    status seen classification why =
      WorkloadImageStatus
        { workload = name
        , expected = expectedDigest
        , selected = (^. #specImage) <$> seen
        , observed = maybe [] (^. #readyImageIds) seen
        , source = seen >>= (^. #imageSource)
        , classification = classification
        , reason = why
        }
    classify seen =
      let running = map imageIdDigest (seen ^. #readyImageIds)
          specDigest = referenceDigest (seen ^. #specImage)
          at = status (Just seen)
       in case specDigest of
            Nothing -> at ImageUnknown "the workload does not name an immutable image"
            Just wanted
              | null running -> at ImageUnknown "no ready replica reports its image"
              | Nothing `elem` running -> at ImageUnknown "a ready replica's image ID names no manifest digest"
              | otherwise -> case nub (catMaybes running) of
                  [runningDigest]
                    | runningDigest /= wanted -> at ImageUnknown "ready replicas do not run the workload's image yet"
                    | Just runningDigest == expectedDigest -> at ImageRelease "ready replicas run this release's image"
                    | seen ^. #imageSource == Just "override" ->
                        at ImageOverride "a reviewed override differs from this release's image"
                    | seen ^. #imageSource == Just "release"
                    , Just runningDigest == ((seen ^. #recordedRelease) >>= referenceDigest) ->
                        at ImageOtherRelease "the release that reviewed it selected this image; this payload selects another"
                    | isNothing expectedDigest -> at ImageUnknown "this payload names no release image to compare with"
                    | otherwise -> at ImageDrift "no release or reviewed selection names this image"
                  _ -> at ImageUnknown "ready replicas run more than one image; a rollout has not finished"

assessWorkloadImages ::
  (ReleaseImageKey -> Bool) ->
  Maybe ReleaseImages ->
  Map ReleaseImageKey (Either Text (Maybe WorkloadObservation)) ->
  [WorkloadImageStatus]
assessWorkloadImages enabled release observations =
  [ assessWorkloadImage key (enabled key) release (Map.findWithDefault (Left "not observed") key observations)
  | key <- releaseImageKeys
  ]

-- | Exact only when every enabled workload runs this release's image. A
-- payload without release images has nothing to be exact against, so its
-- image report never changes the aggregate.
imagesAreExact :: Maybe ReleaseImages -> [WorkloadImageStatus] -> Bool
imagesAreExact Nothing _ = True
imagesAreExact (Just _) statuses =
  all ((`elem` [ImageRelease, ImageNotEnabled]) . (^. #classification)) statuses

imageStatusValue :: WorkloadImageStatus -> Value
imageStatusValue value =
  Aeson.object
    [ "workload" Aeson..= (value ^. #workload)
    , "expected" Aeson..= (value ^. #expected)
    , "selected" Aeson..= (value ^. #selected)
    , "observed" Aeson..= (value ^. #observed)
    , "source" Aeson..= (value ^. #source)
    , "classification" Aeson..= imageClassificationToken (value ^. #classification)
    , "reason" Aeson..= (value ^. #reason)
    ]

renderImageStatusLine :: WorkloadImageStatus -> Text
renderImageStatusLine value =
  "  "
    <> value ^. #workload
    <> ": "
    <> imageClassificationToken (value ^. #classification)
    <> maybe "" (" " <>) (value ^. #selected)
    <> " ("
    <> value ^. #reason
    <> ")"
