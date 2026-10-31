-- | Select the image each enabled release workload runs (EP-237, IR-39). An
-- explicit immutable override wins; otherwise the target payload's
-- @releaseImages@ supplies the image. A payload without that metadata keeps
-- the earlier rule: the operator must name every image. The selection, with
-- the release image it was compared against, is written into the reviewed
-- workload's metadata, so apply executes the reviewed choice and a later
-- status reads the intent without any environment input.
module Nagare.Platform.ReleaseImages
  ( ImageSource (..)
  , ImageSelection (..)
  , ImageSelectionError (..)
  , imageSourceToken
  , overrideVariable
  , resolveImage
  , selectImage
  , explicitSelection
  , renderImageSelectionError
  , imageSourceAnnotation
  , releaseImageAnnotation
  , annotateImageSelection
  )
where

import Control.Monad (mfilter)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Contract.ReleaseImages
  ( ReleaseImageKey (..)
  , ReleaseImages
  , immutableReference
  , lookupReleaseImage
  , releaseImageKeyText
  )
import Nagare.Dsl.Prelude
import System.Environment (lookupEnv)

data ImageSource = ReleaseSource | OverrideSource
  deriving stock (Eq, Show, Generic)

imageSourceToken :: ImageSource -> Text
imageSourceToken = \case
  ReleaseSource -> "release"
  OverrideSource -> "override"

-- | @expected@ is the payload's release image when it has one; @selected@ is
-- what the workload runs.
data ImageSelection = ImageSelection
  { expected :: !(Maybe Text)
  , selected :: !Text
  , source :: !ImageSource
  }
  deriving stock (Eq, Show, Generic)

data ImageSelectionError
  = MutableOverride !ReleaseImageKey !Text
  | NoReleaseImage !ReleaseImageKey
  deriving stock (Eq, Show, Generic)

-- | The environment variable that overrides one image.
overrideVariable :: ReleaseImageKey -> Text
overrideVariable = \case
  EnImage -> "NAGARE_AUTH_EN_IMAGE"
  ShomeiImage -> "NAGARE_AUTH_SHOMEI_IMAGE"
  AccessImage -> "NAGARE_AUTH_ACCESS_IMAGE"
  AdminApiImage -> "NAGARE_ADMIN_API_IMAGE"

resolveImage :: ReleaseImageKey -> Maybe ReleaseImages -> Maybe Text -> Either ImageSelectionError ImageSelection
resolveImage key release override = case override of
  Just reference
    | immutableReference reference -> Right (ImageSelection releaseReference reference OverrideSource)
    | otherwise -> Left (MutableOverride key reference)
  Nothing -> case releaseReference of
    Just reference -> Right (ImageSelection (Just reference) reference ReleaseSource)
    Nothing -> Left (NoReleaseImage key)
  where
    releaseReference = (^. #reference) <$> (release >>= lookupReleaseImage key)

-- | Resolve one image from the process environment; an empty variable is
-- treated as unset, so @VAR=@ removes an override.
selectImage :: Maybe ReleaseImages -> ReleaseImageKey -> IO (Either ImageSelectionError ImageSelection)
selectImage release key = do
  value <- lookupEnv (T.unpack (overrideVariable key))
  let override = mfilter (not . T.null) (T.strip . T.pack <$> value)
  pure (resolveImage key release override)

-- | An image named by a caller that has no release metadata to compare with.
explicitSelection :: Text -> ImageSelection
explicitSelection reference = ImageSelection Nothing reference OverrideSource

renderImageSelectionError :: ImageSelectionError -> Text
renderImageSelectionError = \case
  MutableOverride key reference ->
    overrideVariable key
      <> " must be an immutable registry/repository@sha256:<digest> reference; "
      <> reference
      <> " is not"
  NoReleaseImage key ->
    "this payload names no release image for "
      <> releaseImageKeyText key
      <> "; set "
      <> overrideVariable key
      <> " to an immutable registry/repository@sha256:<digest> reference"

imageSourceAnnotation :: Text
imageSourceAnnotation = "nagare.dev/image-source"

releaseImageAnnotation :: Text
releaseImageAnnotation = "nagare.dev/release-image"

-- | Record a selection on a workload object's own metadata, not its Pod
-- template, so recording intent never rolls the workload by itself.
annotateImageSelection :: ImageSelection -> Value -> Either Text Value
annotateImageSelection selection (Object root) = do
  metadata <- case KM.lookup "metadata" root of
    Just (Object fields) -> Right fields
    _ -> Left "workload has no metadata"
  annotations <- case KM.lookup "annotations" metadata of
    Nothing -> Right KM.empty
    Just (Object fields) -> Right fields
    Just _ -> Left "workload annotations are malformed"
  let recorded =
        KM.insert (key imageSourceAnnotation) (String (imageSourceToken (selection ^. #source)))
          . maybe id (KM.insert (key releaseImageAnnotation) . String) (selection ^. #expected)
          $ KM.delete (key releaseImageAnnotation) annotations
  pure (Object (KM.insert "metadata" (Object (KM.insert "annotations" (Object recorded) metadata)) root))
  where
    key = Key.fromText
annotateImageSelection _ _ = Left "workload is not an object"
