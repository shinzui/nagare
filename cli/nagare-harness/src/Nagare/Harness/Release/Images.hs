-- | The release's four service images (EP-237, IR-39). @prepare@ builds them
-- on the x86_64-linux builder and writes their digests and store paths into
-- root @release.json@ for the @chore(release): prepare@ commit. The push step
-- builds them again from the candidate revision, refuses unless they are the
-- committed images, pushes their OCI layouts to the binary cache and reads them
-- back. It makes no registry call: each context publishes the images into its
-- own registry during its reviewed transition.
--
-- Credentials stay with cachix's environment; nothing here reads, passes or
-- records them.
module Nagare.Harness.Release.Images
  ( PushImages (..)
  , ImagesReceipt (..)
  , imagePackage
  , readReleaseImages
  , prepareReleaseImages
  , pushReleaseImages
  , binaryCache
  )
where

import Data.Aeson (FromJSON, ToJSON, Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Contract.ReleaseImages
import Nagare.Harness.Prelude
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Records (writeSorted)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

-- | The flake output that builds one image's OCI layout.
imagePackage :: ReleaseImageKey -> String
imagePackage = \case
  EnImage -> "release-image-en"
  ShomeiImage -> "release-image-shomei"
  AccessImage -> "release-image-access"
  AdminApiImage -> "release-image-admin-api"

-- | The public binary cache the flake names as a substituter.
binaryCache :: (String, String)
binaryCache = ("shinzui", "https://shinzui.cachix.org")

data PushImages = PushImages
  { flake :: !String
  -- ^ @git+file://REPO?rev=REV@
  , revision :: !Text
  , images :: !ReleaseImages
  , work :: !FilePath
  -- ^ Where the receipt goes.
  }
  deriving stock (Generic)

-- | What the candidate proved. A repeat run over the same objects writes the
-- same receipt.
data ImagesReceipt = ImagesReceipt
  { schemaVersion :: !Int
  , candidate :: !Text
  , images :: !(Map Text ReleaseImage)
  , cache :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The @releaseImages@ member of a @release.json@.
readReleaseImages :: ByteString -> Either Text ReleaseImages
readReleaseImages bytes = case Aeson.eitherDecodeStrict' bytes :: Either String Value of
  Left err -> Left ("release.json does not decode: " <> T.pack err)
  Right (Aeson.Object fields) -> case KeyMap.lookup "releaseImages" fields of
    Nothing -> Left "release.json has no releaseImages; run release images prepare before the chore(release) commit"
    Just value -> first (("release.json releaseImages: " <>) . T.pack) (Aeson.parseEither Aeson.parseJSON value)
  Right _ -> Left "release.json is not an object"

-- | Build the four images from the working tree on the builder and write
-- their manifest into root release.json. Run it once per release, after the
-- version is set and before the prepare commit.
prepareReleaseImages :: Runtime -> FilePath -> IO ()
prepareReleaseImages outer root = do
  let runtime = runningIn root outer
  manifestPath <-
    captureText runtime "the x86_64-linux image build failed" $
      invocation "nix" ["build", "--no-link", "--print-out-paths", "--max-jobs", "0", ".#packages.x86_64-linux.release-images-manifest"]
  manifestBytes <- capture runtime "reading the image manifest failed" (invocation "cat" [T.unpack manifestPath])
  images' <- either (refuse . ("the built image manifest: " <>) . T.pack) pure (Aeson.eitherDecodeStrict' manifestBytes :: Either String ReleaseImages)
  either refuse pure (validateReleaseImages images')
  updated <-
    capture runtime "writing releaseImages into release.json failed" $
      invocation "jq" ["--indent", "2", "--argjson", "images", T.unpack (encodeText (toJSON images')), ".releaseImages = $images", root </> "release.json"]
  BS.writeFile (root </> "release.json") updated
  require runtime "release.json does not carry the built images" $
    invocation "nix" ["build", "--no-link", "--max-jobs", "0", ".#packages.x86_64-linux.release-images-check"]
  forM_ (Map.toList (images' ^. #images)) $ \(key, image) ->
    (runtime ^. #say) ("release images: " <> releaseImageKeyText key <> " " <> image ^. #digest)
  (runtime ^. #say) "release images: release.json updated; commit it with the release version"

-- | The candidate's image step. Refuses before anything is pushed unless every
-- image it builds is the digest and store path its release.json names.
pushReleaseImages :: Runtime -> PushImages -> IO ImagesReceipt
pushReleaseImages runtime options = do
  let manifest = options ^. #images
      entries = Map.toList (manifest ^. #images)
  either refuse pure (validateReleaseImages manifest)
  case lookupVariable runtime "CACHIX_AUTH_TOKEN" of
    Nothing -> refuse "CACHIX_AUTH_TOKEN is not set; the image layouts go to the binary cache before any rehearsal"
    Just _ -> pure ()
  forM_ entries $ \(key, image) -> do
    layout <-
      captureText runtime ("the x86_64-linux " <> T.pack (imagePackage key) <> " build failed") $
        invocation "nix" ["build", "--no-link", "--print-out-paths", "--max-jobs", "0", options ^. #flake <> "#packages.x86_64-linux." <> imagePackage key]
    built <- captureText runtime ("the " <> releaseImageKeyText key <> " layout has no digest") (invocation "cat" [T.unpack layout </> "digest"])
    unless (built == image ^. #digest) $
      refuse ("the candidate builds " <> releaseImageKeyText key <> " as " <> built <> ", but its release.json names " <> image ^. #digest <> "; prepare the release again")
    unless (layout == image ^. #storePath) $
      refuse ("the candidate builds " <> releaseImageKeyText key <> " at " <> layout <> ", but its release.json names " <> image ^. #storePath <> "; prepare the release again")
  let paths = [T.unpack (image ^. #storePath) | (_, image) <- entries]
  require runtime "cachix push failed" (invocation "cachix" (["push", fst binaryCache] <> paths))
  forM_ paths $ \path ->
    require runtime ("the binary cache does not serve " <> T.pack path) $
      invocation "nix" ["path-info", "--store", snd binaryCache, path] & #stdoutTo .~ Discard
  let receipt =
        ImagesReceipt
          { schemaVersion = 1
          , candidate = options ^. #revision
          , images = Map.mapKeys releaseImageKeyText (manifest ^. #images)
          , cache = T.pack (snd binaryCache)
          }
  createDirectoryIfMissing True (options ^. #work)
  writeSorted True (options ^. #work </> "release-images.json") (toJSON receipt)
  pure receipt

encodeText :: Value -> Text
encodeText = TE.decodeUtf8 . BL.toStrict . Aeson.encode
