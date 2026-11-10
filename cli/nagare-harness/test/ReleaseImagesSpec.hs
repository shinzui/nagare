-- | EP-237: the release images step, interpreted with a recording fake. Nothing
-- is pushed unless the candidate builds the images its release.json names, and
-- a push counts only when the cache serves the result.
module ReleaseImagesSpec
  ( releaseImagesTests
  , digestFor
  , fixtureImages
  , imageKeys
  , storePathFor
  )
where

import Control.Exception (try)
import Control.Monad (void)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
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

-- | (key, flake output) in the manifest's order.
imageKeys :: [(Text, String)]
imageKeys =
  [ ("en", "release-image-en")
  , ("shomei", "release-image-shomei")
  , ("nagare-access", "release-image-access")
  , ("nagare-admin-api", "release-image-admin-api")
  , ("cloudflared", "release-image-cloudflared")
  ]

digestFor :: Char -> Text
digestFor c = "sha256:" <> T.replicate 64 (T.singleton c)

storePathFor :: String -> String
storePathFor package = "/nix/store/out-" <> package

fixtureImages :: Value
fixtureImages =
  object
    [ "schemaVersion" .= (1 :: Int)
    , "images"
        .= object
          [ Key.fromText key
              .= object
                [ "platform" .= ("linux/amd64" :: Text)
                , "digest" .= digestFor 'a'
                , "storePath" .= storePathFor package
                , "sources" .= object []
                ]
          | (key, package) <- imageKeys
          ]
    ]

releaseImagesOf :: ReleaseImages
releaseImagesOf = either error id (parseEither Aeson.parseJSON fixtureImages)

data Knobs = Knobs
  { builtDigest :: !Char
  , builtElsewhere :: !Bool
  , pushExit :: !Int
  , cacheServes :: !Bool
  }
  deriving stock (Generic)

calm :: Knobs
calm = Knobs 'a' False 0 True

world' :: Knobs -> Responder
world' knobs command = case (command ^. #program, command ^. #arguments) of
  ("nix", "build" : rest) ->
    let package = T.unpack (T.takeWhileEnd (/= '.') (T.pack (last rest)))
     in pure (0, T.pack (storePathFor (if knobs ^. #builtElsewhere then package <> "-other" else package)) <> "\n")
  ("cat", [_]) -> pure (0, digestFor (knobs ^. #builtDigest) <> "\n")
  ("cachix", _) -> pure (knobs ^. #pushExit, "")
  ("nix", "path-info" : _) -> pure (if knobs ^. #cacheServes then 0 else 1, "")
  _ -> pure (0, "")

pushWith :: FilePath -> [(String, String)] -> Knobs -> IO (Runtime, World, PushImages)
pushWith root' environment' knobs = do
  (runtime, world) <- fake environment' (world' knobs)
  pure (runtime, world, PushImages "git+file:///repo?rev=abc" rev releaseImagesOf (root' </> "work"))

withToken :: [(String, String)]
withToken = [("CACHIX_AUTH_TOKEN", "secret")]

programs :: World -> IO [FilePath]
programs world = map fst <$> recorded world

releaseImagesTests :: TestTree
releaseImagesTests =
  testGroup
    "release images"
    [ testCase "every image is built and checked, then pushed once and read back, with no registry call" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, world, options) <- pushWith root' withToken calm
          receipt <- pushReleaseImages runtime options
          calls' <- recorded world
          [arguments' | ("cachix", arguments') <- calls'] @?= [["push", "shinzui"] <> [storePathFor package | (_, package) <- imageKeys]]
          [arguments' | ("nix", arguments'@("path-info" : _)) <- calls']
            @?= [["path-info", "--store", "https://shinzui.cachix.org", storePathFor package] | (_, package) <- imageKeys]
          assertBool "the step called a registry" ("skopeo" `notElem` map fst calls')
          receipt ^. #cache @?= "https://shinzui.cachix.org"
    , testCase "a repeat run writes the same receipt" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, _, options) <- pushWith root' withToken calm
          _ <- pushReleaseImages runtime options
          first' <- BS.readFile (root' </> "work/release-images.json")
          _ <- pushReleaseImages runtime options
          second' <- BS.readFile (root' </> "work/release-images.json")
          second' @?= first'
    , testCase "another digest or store path refuses before anything is pushed" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, world, options) <- pushWith root' withToken calm {builtDigest = 'c'}
          refused (void (pushReleaseImages runtime options)) >>= assertMentions "prepare the release again"
          programs world >>= \seen -> assertBool "pushed" ("cachix" `notElem` seen)
          (runtime', world', options') <- pushWith root' withToken calm {builtElsewhere = True}
          refused (void (pushReleaseImages runtime' options')) >>= assertMentions "prepare the release again"
          programs world' >>= \seen -> assertBool "pushed" ("cachix" `notElem` seen)
    , testCase "a missing token refuses before any build" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, world, options) <- pushWith root' [] calm
          refused (void (pushReleaseImages runtime options)) >>= assertMentions "CACHIX_AUTH_TOKEN"
          programs world >>= (@?= [])
    , testCase "a failed push and a cache that does not serve the path each refuse" $
        withSystemTempDirectory "images" $ \root' -> do
          (runtime, _, options) <- pushWith root' withToken calm {pushExit = 1}
          refused (void (pushReleaseImages runtime options)) >>= assertMentions "cachix push failed"
          (runtime', _, options') <- pushWith root' withToken calm {cacheServes = False}
          refused (void (pushReleaseImages runtime' options')) >>= assertMentions "does not serve"
    , testCase "a release.json without releaseImages has none, and a malformed member refuses" $ do
        readReleaseImages "{\"platformVersion\":\"9.8.7\"}" @?= Right Nothing
        readReleaseImages (BL.toStrict (Aeson.encode (object ["releaseImages" .= fixtureImages]))) @?= Right (Just releaseImagesOf)
        case readReleaseImages "{\"releaseImages\":{\"schemaVersion\":2,\"images\":{}}}" of
          Left reason -> assertMentions "releaseImages" reason
          Right _ -> assertFailure "a malformed member decoded"
    , testCase "publication fetches each image locally, then pins it forever by a name that carries the version" $ do
        (runtime, world, _) <- pushWith "/unused" withToken calm
        pinReleaseImages runtime "9.8.7" releaseImagesOf
        recorded world
          >>= ( @?=
                  concat
                    [ [ ("nix", ["build", "--no-link", "--option", "extra-substituters", "https://shinzui.cachix.org", storePathFor package])
                      , ("cachix", ["pin", "shinzui", "nagare-v9.8.7-" <> T.unpack key, storePathFor package, "--keep-forever"])
                      ]
                    | (key, package) <- imageKeys
                    ]
              )
    ]
