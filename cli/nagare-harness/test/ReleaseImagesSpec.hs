-- | EP-237 M2: the release images step, interpreted with a recording fake
-- registry. Only "manifest unknown" is absence; uploads are settled by asking
-- the registry; nothing is replaced or retagged.
module ReleaseImagesSpec
  ( releaseImagesTests
  , digestFor
  , fixtureImages
  , imageOrder
  , publishedRegistry
  )
where

import Control.Exception (try)
import Control.Monad (void)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Contract.ReleaseImages (ReleaseImages)
import Nagare.Harness.Prelude hiding ((.=))
import Nagare.Harness.Release.Images
import Nagare.Harness.Release.Process
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

type Responder = Invocation -> IO (Int, Text)

-- | Each call's program and arguments, newest first.
newtype World = World (IORef [(FilePath, [String])])

fake :: [(String, String)] -> Responder -> IO (Runtime, World)
fake environment' respond = do
  calls' <- newIORef []
  let answer command = do
        modifyIORef' calls' ((command ^. #program, command ^. #arguments) :)
        (code, out) <- respond command
        pure (Result code (if command ^. #stdoutTo == Capture then TE.encodeUtf8 out else ""))
  pure
    ( Runtime
        { transport = Transport {run = answer, spawn = \command -> answer command >>= \result -> pure (Background (pure (result ^. #exit)) (pure ()))}
        , now = pure (UTCTime (fromGregorian 2026 10 31) 0)
        , pause = const (pure ())
        , say = const (pure ())
        , warn = const (pure ())
        , variables = environment'
        , harness = "/harness/bin/nagare-harness"
        , locate = const (pure Nothing)
        }
    , World calls'
    )

recorded :: World -> IO [(FilePath, [String])]
recorded (World calls') = reverse <$> readIORef calls'

refused :: IO () -> IO Text
refused action =
  try action >>= \case
    Left (Refusal reason) -> pure reason
    Right () -> assertFailure "expected a refusal" >> pure ""

assertMentions :: Text -> Text -> Assertion
assertMentions needle haystack = assertBool (T.unpack ("expected \"" <> needle <> "\" in: " <> haystack)) (needle `T.isInfixOf` haystack)

rev :: Text
rev = "0123456789abcdef0123456789abcdef01234567"

version' :: Text
version' = "9.8.7"

-- * release images (EP-237)

-- | (key, flake output, repository) in the manifest's order.
imageKeys :: [(Text, String, Text)]
imageKeys =
  [ ("en", "release-image-en", "ghcr.io/shinzui/nagare-en")
  , ("shomei", "release-image-shomei", "ghcr.io/shinzui/nagare-shomei")
  , ("nagare-access", "release-image-access", "ghcr.io/shinzui/nagare-access")
  , ("nagare-admin-api", "release-image-admin-api", "ghcr.io/shinzui/nagare-admin-api")
  ]

digestFor :: Char -> Text
digestFor c = "sha256:" <> T.replicate 64 (T.singleton c)

referenceFor :: Text -> Char -> Text
referenceFor repository c = repository <> "@" <> digestFor c

fixtureImages :: Char -> Value
fixtureImages c =
  object
    [ "schemaVersion" .= (1 :: Int)
    , "images"
        .= object
          [ Key.fromText key
              .= object
                [ "repository" .= repository
                , "platform" .= ("linux/amd64" :: Text)
                , "digest" .= digestFor c
                , "reference" .= referenceFor repository c
                , "sources" .= object []
                ]
          | (key, _, repository) <- imageKeys
          ]
    ]

releaseImagesOf :: Char -> ReleaseImages
releaseImagesOf c = either error id (parseEither Aeson.parseJSON (fixtureImages c))

-- | A registry that already holds every image publicly.
publishedRegistry :: Char -> [String] -> IO (Int, Text)
publishedRegistry c = \case
  ["inspect", "--raw", _] -> pure (0, "{}")
  ["inspect", "--no-creds", "--format", _, _] -> pure (0, digestFor c <> "\n")
  ["inspect", "--no-creds", "--config", _] -> pure (0, "{\"os\":\"linux\",\"architecture\":\"amd64\"}")
  _ -> pure (0, "")

-- | The image step of a candidate whose registry already holds every image.
imageOrder :: String -> String -> Bool -> [String]
imageOrder flake work _ =
  concat
    [ [ "nix build --no-link --print-out-paths --max-jobs 0 " <> flake <> "#packages.x86_64-linux." <> package
      , "cat /nix/store/out-" <> package <> "/digest"
      ]
    | (_, package, _) <- imageKeys
    ]
    <> ["skopeo inspect --raw docker://" <> T.unpack (referenceFor repository 'a') | (_, _, repository) <- imageKeys]
    <> concat
      [ [ "skopeo inspect --no-creds --format {{.Digest}} docker://" <> reference
        , "skopeo inspect --no-creds --config docker://" <> reference
        , "skopeo --policy " <> work <> "/skopeo-policy.json copy --src-no-creds --preserve-digests docker://" <> reference <> " dir:" <> work <> "/pull/" <> T.unpack key
        ]
      | (key, _, repository) <- imageKeys
      , let reference = T.unpack (referenceFor repository 'a')
      ]
    <> ["cachix push shinzui " <> unwords ["/nix/store/out-" <> package | (_, package, _) <- imageKeys]]
    <> ["nix path-info --store https://shinzui.cachix.org /nix/store/out-" <> package | (_, package, _) <- imageKeys]

data ImageKnobs = ImageKnobs
  { built :: !Char
  -- ^ The digest letter every layout reports.
  , copyExit :: !Int
  , copyLands :: !Bool
  , unknownRefs :: ![Text]
  , platformSeen :: !Text
  , remoteDigest :: !(Maybe Text)
  , anonymous :: !Bool
  }
  deriving stock (Generic)

calmImages :: ImageKnobs
calmImages = ImageKnobs 'a' 0 True [] "amd64" Nothing True

-- | A registry held in @registry@ (reference to digest) that uploads change.
registryWorld :: IORef (Map.Map Text Text) -> ImageKnobs -> Responder
registryWorld registry knobs command = case (command ^. #program, command ^. #arguments) of
  ("nix", "build" : rest) -> pure (0, "/nix/store/out-" <> T.takeWhileEnd (/= '.') (T.pack (last rest)) <> "\n")
  ("cat", [_]) -> pure (0, digestFor (knobs ^. #built) <> "\n")
  ("skopeo", ["inspect", "--raw", target]) -> do
    let reference = T.drop 9 (T.pack target)
    held <- Map.member reference <$> readIORef registry
    pure $
      if reference `elem` knobs ^. #unknownRefs
        then (1, "pinging container registry ghcr.io: dial tcp: i/o timeout")
        else if held then (0, "{}") else (1, "reading manifest: manifest unknown")
  ("skopeo", ["inspect", "--no-creds", "--format", _, target]) ->
    if knobs ^. #anonymous
      then pure (0, fromMaybe (T.takeWhileEnd (/= '@') (T.pack target)) (knobs ^. #remoteDigest) <> "\n")
      else pure (1, "")
  ("skopeo", ["inspect", "--format", _, target]) -> do
    held <- Map.lookup (T.drop 9 (T.pack target)) <$> readIORef registry
    pure (maybe (1, "") (\digest -> (0, digest <> "\n")) held)
  ("skopeo", ["inspect", "--no-creds", "--config", _]) -> pure (0, "{\"os\":\"linux\",\"architecture\":\"" <> knobs ^. #platformSeen <> "\"}")
  ("skopeo", ["--policy", _, "copy", "--src-no-creds", _, _, _]) -> pure (if knobs ^. #anonymous then 0 else 1, "")
  ("skopeo", ["--policy", _, "copy", "--preserve-digests", source, target]) -> do
    let destination = T.drop 9 (T.pack target)
    when (knobs ^. #copyLands) $ do
      digest <-
        if "oci:" `isPrefixOf` source
          then pure (T.takeWhileEnd (/= '@') destination)
          else fromMaybe "" . Map.lookup (T.drop 9 (T.pack source)) <$> readIORef registry
      modifyIORef' registry (Map.insert destination digest)
    pure (knobs ^. #copyExit, "")
  _ -> pure (0, "")

publishWith :: FilePath -> ImageKnobs -> [Text] -> IO (Runtime, World, IORef (Map.Map Text Text), PublishImages)
publishWith root' knobs held = do
  registry <- newIORef (Map.fromList [(reference, T.takeWhileEnd (/= '@') reference) | reference <- held])
  (runtime, world) <- fake [("CACHIX_AUTH_TOKEN", "secret")] (registryWorld registry knobs)
  pure (runtime, world, registry, PublishImages "git+file:///repo?rev=abc" rev (releaseImagesOf 'a') (root' </> "work"))

allReferences :: Char -> [Text]
allReferences c = [referenceFor repository c | (_, _, repository) <- imageKeys]

uploads :: World -> IO [String]
uploads world = do
  calls' <- recorded world
  pure [unwords arguments' | (program', arguments') <- calls', program' == "skopeo", "copy" `elem` arguments', any ("oci:" `isPrefixOf`) arguments']

releaseImagesTests :: TestTree
releaseImagesTests =
  testGroup
    "release images"
    [ testCase "only a missing image is uploaded, then every image is verified anonymously and cached" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, world, registry, options) <- publishWith root' calmImages (drop 1 (allReferences 'a'))
          receipt <- publishReleaseImages runtime options
          uploaded <- uploads world
          length uploaded @?= 1
          assertBool "the upload was not En by digest" (any ("docker://ghcr.io/shinzui/nagare-en@sha256:" `isPrefixOf`) (words (concat uploaded)))
          held <- readIORef registry
          Map.keys held @?= sort (allReferences 'a')
          receipt ^. #anonymousPull @?= True
          length (receipt ^. #cachePaths) @?= 4
    , testCase "a repeat run uploads nothing and writes the same receipt" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, world, _, options) <- publishWith root' calmImages (allReferences 'a')
          _ <- publishReleaseImages runtime options
          first' <- BS.readFile (root' </> "work/release-images.json")
          _ <- publishReleaseImages runtime options
          second' <- BS.readFile (root' </> "work/release-images.json")
          second' @?= first'
          uploads world >>= (@?= [])
    , testCase "a lost acknowledgement is settled by asking the registry, not by retrying blindly" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, world, _, options) <- publishWith root' calmImages {copyExit = 1} (drop 1 (allReferences 'a'))
          _ <- publishReleaseImages runtime options
          uploads world >>= (@?= ["--policy " <> root' </> "work/skopeo-policy.json copy --preserve-digests oci:/nix/store/out-release-image-en docker://" <> T.unpack (referenceFor "ghcr.io/shinzui/nagare-en" 'a')])
    , testCase "an upload the registry never received refuses" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, _, _, options) <- publishWith root' calmImages {copyExit = 1, copyLands = False} []
          refused (void (publishReleaseImages runtime options)) >>= assertMentions "did not reach the registry"
    , testCase "an unknown registry answer is not absence: nothing is uploaded" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, world, _, options) <- publishWith root' calmImages {unknownRefs = [referenceFor "ghcr.io/shinzui/nagare-en" 'a']} []
          refused (void (publishReleaseImages runtime options)) >>= assertMentions "an unknown answer is not absence"
          uploads world >>= (@?= [])
    , testCase "a candidate that builds another digest refuses before any registry call" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, world, _, options) <- publishWith root' calmImages {built = 'c'} []
          refused (void (publishReleaseImages runtime options)) >>= assertMentions "prepare the release again"
          calls' <- recorded world
          [call | call@(program', _) <- calls', program' == "skopeo"] @?= []
    , testCase "a wrong platform, a mismatched remote digest and a private package each refuse" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, _, _, options) <- publishWith root' calmImages {platformSeen = "arm64"} (allReferences 'a')
          refused (void (publishReleaseImages runtime options)) >>= assertMentions "linux/arm64, not linux/amd64"
          (runtime', _, _, options') <- publishWith root' calmImages {remoteDigest = Just (digestFor 'd')} (allReferences 'a')
          refused (void (publishReleaseImages runtime' options')) >>= assertMentions ("resolves to " <> digestFor 'd')
          (runtime'', _, _, options'') <- publishWith root' calmImages {anonymous = False} (allReferences 'a')
          refused (void (publishReleaseImages runtime'' options'')) >>= assertMentions "public in its GitHub package settings"
    , testCase "the cache step refuses without its token, after the registry is verified" $
        withSystemTempDirectory "images" $ \root' -> do
          registry <- newIORef (Map.fromList [(reference, T.takeWhileEnd (/= '@') reference) | reference <- allReferences 'a'])
          (runtime, _) <- fake [] (registryWorld registry calmImages)
          refused (void (publishReleaseImages runtime (PublishImages "git+file:///repo?rev=abc" rev (releaseImagesOf 'a') (root' </> "work")))) >>= assertMentions "CACHIX_AUTH_TOKEN"
    , testCase "publication tags each image once and never moves a tag" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, world, registry, _) <- publishWith root' calmImages (allReferences 'a')
          aliasReleaseImages runtime (root' </> "work") version' (releaseImagesOf 'a')
          held <- readIORef registry
          [Map.lookup (repository <> ":v" <> version') held | (_, _, repository) <- imageKeys] @?= replicate 4 (Just (digestFor 'a'))
          before <- length <$> recorded world
          aliasReleaseImages runtime (root' </> "work") version' (releaseImagesOf 'a')
          after <- recorded world
          [call | call@(_, arguments') <- drop before after, "copy" `elem` arguments', any ("docker://ghcr.io/shinzui/nagare-en:" `isPrefixOf`) arguments'] @?= []
          modifyIORef' registry (Map.insert ("ghcr.io/shinzui/nagare-shomei:v" <> version') (digestFor 'e'))
          refused (aliasReleaseImages runtime (root' </> "work") version' (releaseImagesOf 'a')) >>= assertMentions "a published tag is never moved"
    , testCase "a release.json without releaseImages names the prepare step" $
        case readReleaseImages "{\"platformVersion\":\"9.8.7\"}" of
          Left reason -> assertMentions "release images prepare" reason
          Right _ -> assertFailure "a release without images decoded"
    ]
