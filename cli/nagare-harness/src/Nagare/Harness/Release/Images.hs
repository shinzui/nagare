-- | The release's four service images (EP-237, IR-39). @prepare@ builds them
-- on the x86_64-linux builder and writes their digests into root
-- @release.json@ for the @chore(release): prepare@ commit. The candidate
-- builds them again from its revision, refuses unless they are the committed
-- digests, uploads each by digest only when the registry lacks it, proves an
-- anonymous linux/amd64 pull, pushes their store paths to the binary cache
-- and proves a fresh consumer can substitute them. Publication verifies the
-- same objects and adds release-version tags only when absent or identical.
--
-- Every registry answer is read, never assumed: an upload that fails is
-- followed by a query, and only a registry that says "manifest unknown" is
-- absent; any other failure stops the run. Nothing is deleted or retagged.
-- Credentials stay with skopeo's login and cachix's environment; nothing here
-- reads, passes or records them.
module Nagare.Harness.Release.Images
  ( PublishImages (..)
  , RegistryState (..)
  , ImagesReceipt (..)
  , imagePackage
  , readReleaseImages
  , registryState
  , prepareReleaseImages
  , publishReleaseImages
  , verifyReleaseImages
  , aliasReleaseImages
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
import Data.Text.Encoding.Error qualified as TE
import Nagare.Contract.ReleaseImages
import Nagare.Harness.Prelude
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Records (writeSorted)
import System.Directory (createDirectoryIfMissing, removePathForcibly)
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

data PublishImages = PublishImages
  { flake :: !String
  -- ^ @git+file://REPO?rev=REV@
  , revision :: !Text
  , images :: !ReleaseImages
  , work :: !FilePath
  -- ^ Where the receipt and scratch pulls go.
  }
  deriving stock (Generic)

data RegistryState = Present | Absent | Unknown !Text
  deriving stock (Eq, Show, Generic)

-- | What the candidate proved, without when or whether this run uploaded:
-- a repeat run over the same objects writes the same receipt.
data ImagesReceipt = ImagesReceipt
  { schemaVersion :: !Int
  , candidate :: !Text
  , images :: !(Map Text ReleaseImage)
  , anonymousPull :: !Bool
  , cache :: !Text
  , cachePaths :: ![Text]
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

-- | Ask the registry for an exact reference. Only "manifest unknown" is
-- absence; a timeout, a denial or any other failure is unknown.
registryState :: Runtime -> [String] -> Text -> IO RegistryState
registryState runtime credentials reference = do
  result <- invoke runtime (skopeo (["inspect", "--raw"] <> credentials <> ["docker://" <> T.unpack reference]) & #stdoutTo .~ Capture & #stderrTo .~ SameAsStdout)
  let said = TE.decodeUtf8With TE.lenientDecode (result ^. #output)
  pure $
    if result ^. #exit == 0
      then Present
      else
        if any (`T.isInfixOf` T.toLower said) ["manifest unknown", "manifest_unknown"]
          then Absent
          else Unknown (lastLines 1 (trimEnd said))

skopeo :: [String] -> Invocation
skopeo = invocation "skopeo"

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
    (runtime ^. #say) ("release images: " <> releaseImageKeyText key <> " " <> image ^. #reference)
  (runtime ^. #say) "release images: release.json updated; commit it with the release version"

-- | The candidate's image step. Refuses before any registry mutation unless
-- every image it builds is the digest its release.json names.
publishReleaseImages :: Runtime -> PublishImages -> IO ImagesReceipt
publishReleaseImages runtime options = do
  let manifest = options ^. #images
      entries = Map.toList (manifest ^. #images)
  either refuse pure (validateReleaseImages manifest)
  layouts <- forM entries $ \(key, image) -> do
    layout <-
      T.unpack
        <$> captureText runtime ("the x86_64-linux " <> T.pack (imagePackage key) <> " build failed") (invocation "nix" ["build", "--no-link", "--print-out-paths", "--max-jobs", "0", options ^. #flake <> "#packages.x86_64-linux." <> imagePackage key])
    built <- captureText runtime ("the " <> releaseImageKeyText key <> " layout has no digest") (invocation "cat" [layout </> "digest"])
    unless (built == image ^. #digest) $
      refuse ("the candidate builds " <> releaseImageKeyText key <> " as " <> built <> ", but its release.json names " <> image ^. #digest <> "; prepare the release again")
    pure (key, image, layout)
  createDirectoryIfMissing True (options ^. #work)
  let policy = options ^. #work </> "skopeo-policy.json"
  BS.writeFile policy "{\"default\":[{\"type\":\"insecureAcceptAnything\"}]}"
  forM_ layouts $ \(key, image, layout) -> do
    let name = releaseImageKeyText key
        reference = image ^. #reference
    before <- registryState runtime [] reference
    case before of
      Present -> (runtime ^. #say) ("release images: " <> name <> " is already published as " <> reference)
      Unknown why -> refuse ("cannot tell whether " <> reference <> " is published (" <> why <> "); an unknown answer is not absence")
      Absent -> do
        (runtime ^. #say) ("release images: uploading " <> name <> " as " <> reference)
        uploaded <- succeeds runtime (skopeo ["--policy", policy, "copy", "--preserve-digests", "oci:" <> layout, "docker://" <> T.unpack reference])
        -- The copy's own exit is not the answer; the registry's is.
        after <- registryState runtime [] reference
        case after of
          Present -> unless uploaded ((runtime ^. #warn) ("release images: the " <> name <> " upload reported failure but the registry holds it"))
          Absent -> refuse ("the " <> name <> " upload did not reach the registry; run the candidate again")
          Unknown why -> refuse ("cannot tell whether the " <> name <> " upload reached the registry (" <> why <> ")")
  verifyReleaseImages runtime (options ^. #work) manifest
  -- The binary cache: push the layouts, then read them back from the cache
  -- the way a fresh consumer substitutes.
  case lookupVariable runtime "CACHIX_AUTH_TOKEN" of
    Nothing -> refuse "CACHIX_AUTH_TOKEN is not set; the image closures go to the binary cache before any rehearsal"
    Just _ -> pure ()
  let paths = [layout | (_, _, layout) <- layouts]
  require runtime "cachix push failed" (invocation "cachix" (["push", fst binaryCache] <> paths))
  forM_ paths $ \path ->
    require runtime ("the binary cache does not serve " <> T.pack path) $
      invocation "nix" ["path-info", "--store", snd binaryCache, path] & #stdoutTo .~ Discard
  let receipt =
        ImagesReceipt
          { schemaVersion = 1
          , candidate = options ^. #revision
          , images = Map.mapKeys releaseImageKeyText (manifest ^. #images)
          , anonymousPull = True
          , cache = T.pack (snd binaryCache)
          , cachePaths = map T.pack paths
          }
  writeSorted True (options ^. #work </> "release-images.json") (toJSON receipt)
  pure receipt

-- | Every image is published as its digest, is linux/amd64, and pulls
-- completely without credentials.
verifyReleaseImages :: Runtime -> FilePath -> ReleaseImages -> IO ()
verifyReleaseImages runtime work manifest = do
  either refuse pure (validateReleaseImages manifest)
  createDirectoryIfMissing True work
  let policy = work </> "skopeo-policy.json"
  BS.writeFile policy "{\"default\":[{\"type\":\"insecureAcceptAnything\"}]}"
  forM_ (Map.toList (manifest ^. #images)) $ \(key, image) -> do
    let name = releaseImageKeyText key
        reference = T.unpack (image ^. #reference)
        public = "make " <> image ^. #repository <> " public in its GitHub package settings, then run again"
    remote <-
      invoke runtime (skopeo ["inspect", "--no-creds", "--format", "{{.Digest}}", "docker://" <> reference] & #stdoutTo .~ Capture & #stderrTo .~ Discard)
    unless (remote ^. #exit == 0) (refuse (name <> " does not resolve without credentials; " <> public))
    let digest = trimEnd (TE.decodeUtf8With TE.lenientDecode (remote ^. #output))
    unless (digest == image ^. #digest) (refuse (name <> " resolves to " <> digest <> ", not " <> image ^. #digest))
    config <- capture runtime (name <> " has no readable image configuration") (skopeo ["inspect", "--no-creds", "--config", "docker://" <> reference])
    platform <- case Aeson.decodeStrict' config of
      Just (Aeson.Object fields)
        | Just (Aeson.String os) <- KeyMap.lookup "os" fields
        , Just (Aeson.String architecture) <- KeyMap.lookup "architecture" fields ->
            pure (os <> "/" <> architecture)
      _ -> refuse (name <> " has an unreadable image configuration")
    unless (platform == releaseImagePlatform) (refuse (name <> " is " <> platform <> ", not " <> releaseImagePlatform))
    let scratch = work </> "pull" </> T.unpack name
    removePathForcibly scratch
    require runtime (name <> " does not pull without credentials; " <> public) $
      skopeo ["--policy", policy, "copy", "--src-no-creds", "--preserve-digests", "docker://" <> reference, "dir:" <> scratch]
    removePathForcibly scratch
    (runtime ^. #say) ("release images: " <> name <> " " <> platform <> " " <> image ^. #digest <> " pulls anonymously")

-- | Publication: each image gets the tag @v<version>@ unless the registry
-- already holds that tag at the same digest; another digest refuses.
aliasReleaseImages :: Runtime -> FilePath -> Text -> ReleaseImages -> IO ()
aliasReleaseImages runtime work version manifest = do
  verifyReleaseImages runtime work manifest
  let policy = work </> "skopeo-policy.json"
  forM_ (Map.toList (manifest ^. #images)) $ \(key, image) -> do
    let name = releaseImageKeyText key
        tag = image ^. #repository <> ":v" <> version
    state <- registryState runtime [] tag
    case state of
      Absent -> do
        require runtime ("tagging " <> name <> " as " <> tag <> " failed") $
          skopeo ["--policy", policy, "copy", "--preserve-digests", "docker://" <> T.unpack (image ^. #reference), "docker://" <> T.unpack tag]
        tagged <- registryDigest tag
        unless (tagged == Just (image ^. #digest)) (refuse (tag <> " does not name " <> image ^. #digest <> " after tagging"))
      Present -> do
        tagged <- registryDigest tag
        unless (tagged == Just (image ^. #digest)) (refuse (tag <> " already names another image; a published tag is never moved"))
      Unknown why -> refuse ("cannot tell whether " <> tag <> " exists (" <> why <> ")")
    (runtime ^. #say) ("release images: " <> tag <> " names " <> image ^. #digest)
  where
    registryDigest tag = do
      result <- invoke runtime (skopeo ["inspect", "--format", "{{.Digest}}", "docker://" <> T.unpack tag] & #stdoutTo .~ Capture & #stderrTo .~ Discard)
      pure (if result ^. #exit == 0 then Just (trimEnd (TE.decodeUtf8With TE.lenientDecode (result ^. #output))) else Nothing)

encodeText :: Value -> Text
encodeText = TE.decodeUtf8 . BL.toStrict . Aeson.encode
