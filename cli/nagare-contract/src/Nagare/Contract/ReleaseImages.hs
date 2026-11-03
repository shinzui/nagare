-- | The @releaseImages@ member of root @release.json@ (EP-237, IR-39): the
-- four linux/amd64 service images a Nagare release carries, named by their
-- manifest digests and the OCI layout store paths that hold them. Nothing here
-- names a registry: each context derives its own reference from the digest.
-- The release tooling writes and verifies this member and nagarectl selects
-- images from it, so both decode it with these types; this package never
-- links nagarectl.
module Nagare.Contract.ReleaseImages
  ( ReleaseImages (..)
  , ReleaseImage (..)
  , ReleaseImageKey (..)
  , releaseImageKeys
  , releaseImageKeyText
  , releaseImagesSchemaVersion
  , releaseImagePlatform
  , releaseImageReference
  , overrideVariable
  , lookupReleaseImage
  , validateReleaseImages
  , immutableReference
  , referenceDigest
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Contract.Prelude hiding ((.=))

-- | The four images, in the order releases list them.
data ReleaseImageKey
  = EnImage
  | ShomeiImage
  | AccessImage
  | AdminApiImage
  | CloudflaredImage
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

releaseImageKeys :: [ReleaseImageKey]
releaseImageKeys = [minBound .. maxBound]

-- | The key in @releaseImages.images@, which is also the workload name.
releaseImageKeyText :: ReleaseImageKey -> Text
releaseImageKeyText = \case
  EnImage -> "en"
  ShomeiImage -> "shomei"
  AccessImage -> "nagare-access"
  AdminApiImage -> "nagare-admin-api"
  CloudflaredImage -> "cloudflared"

releaseImagesSchemaVersion :: Int
releaseImagesSchemaVersion = 1

releaseImagePlatform :: Text
releaseImagePlatform = "linux/amd64"

-- | The environment variable that overrides one image.
overrideVariable :: ReleaseImageKey -> Text
overrideVariable = \case
  EnImage -> "NAGARE_AUTH_EN_IMAGE"
  ShomeiImage -> "NAGARE_AUTH_SHOMEI_IMAGE"
  AccessImage -> "NAGARE_AUTH_ACCESS_IMAGE"
  AdminApiImage -> "NAGARE_ADMIN_API_IMAGE"
  CloudflaredImage -> "NAGARE_CLOUDFLARED_IMAGE"

-- | The reference of a release image in a context's registry.
releaseImageReference :: Text -> ReleaseImageKey -> ReleaseImage -> Text
releaseImageReference registry key ReleaseImage {digest} =
  registry <> "/" <> releaseImageKeyText key <> "@" <> digest

-- | One release image. @storePath@ is its OCI layout in the binary cache, which
-- a workstation fetches without evaluating any Linux derivation; @sources@ maps
-- each upstream project to the revision the image was built from (the Nagare
-- source of nagare-access and the admin API is the release commit itself,
-- which the payload's @sourceRevision@ names).
data ReleaseImage = ReleaseImage
  { platform :: !Text
  , digest :: !Text
  , storePath :: !Text
  , sources :: !(Map Text Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ReleaseImages = ReleaseImages
  { schemaVersion :: !Int
  , images :: !(Map ReleaseImageKey ReleaseImage)
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON ReleaseImages where
  parseJSON = withObject "ReleaseImages" $ \o -> do
    version <- o .: "schemaVersion"
    raw <- o .: "images" :: Aeson.Parser (Map Text ReleaseImage)
    keyed <- traverse keyFor (Map.toList raw)
    let decoded = ReleaseImages version (Map.fromList keyed)
    either (fail . T.unpack) (const (pure decoded)) (validateReleaseImages decoded)
    where
      keyFor (name, image) = case [key | key <- releaseImageKeys, releaseImageKeyText key == name] of
        [key] -> pure (key, image)
        _ -> fail ("releaseImages names an unknown image " <> show name)

instance ToJSON ReleaseImages where
  toJSON ReleaseImages {schemaVersion, images} =
    Aeson.object
      [ "schemaVersion" .= schemaVersion
      , "images" .= Map.mapKeys releaseImageKeyText images
      ]

lookupReleaseImage :: ReleaseImageKey -> ReleaseImages -> Maybe ReleaseImage
lookupReleaseImage key ReleaseImages {images} = Map.lookup key images

-- | A complete manifest: this schema version, every image a release has always carried (a release before
-- v0.16.0 names no connector, and an upgrade still reads its payload), each
-- linux/amd64 and named by its SHA-256 manifest digest and store path.
validateReleaseImages :: ReleaseImages -> Either Text ()
validateReleaseImages ReleaseImages {schemaVersion, images} = do
  unless
    (schemaVersion == releaseImagesSchemaVersion)
    (Left ("releaseImages schemaVersion " <> T.pack (show schemaVersion) <> " is not supported"))
  let missing = [releaseImageKeyText key | key <- releaseImageKeys, key /= CloudflaredImage, Map.notMember key images]
  unless (null missing) (Left ("releaseImages lacks " <> T.intercalate ", " missing))
  mapM_ checkImage (Map.toList images)
  where
    checkImage (key, ReleaseImage {platform, digest, storePath}) = do
      let name = releaseImageKeyText key
      unless
        (platform == releaseImagePlatform)
        (Left ("releaseImages." <> name <> " is not " <> releaseImagePlatform))
      unless
        (referenceDigest ("image@" <> digest) == Just digest)
        (Left ("releaseImages." <> name <> " digest is not sha256:<64 lowercase hex>"))
      unless
        ("/nix/store/" `T.isPrefixOf` storePath && T.length storePath > T.length "/nix/store/" && not (T.any (<= ' ') storePath))
        (Left ("releaseImages." <> name <> " storePath is not a Nix store path"))

-- | @repository\@sha256:<64 lowercase hex>@ with a non-empty repository.
immutableReference :: Text -> Bool
immutableReference = isJust . referenceDigest

-- | The @sha256:…@ digest of an immutable reference.
referenceDigest :: Text -> Maybe Text
referenceDigest reference = case T.breakOnEnd "@" reference of
  (prefix, digestPart)
    | T.length prefix > 1
    , T.all (\c -> c > ' ' && c /= '"' && c /= '@') (T.dropEnd 1 prefix)
    , Just hexadecimal <- T.stripPrefix "sha256:" digestPart
    , T.length hexadecimal == 64
    , T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) hexadecimal ->
        Just digestPart
  _ -> Nothing
