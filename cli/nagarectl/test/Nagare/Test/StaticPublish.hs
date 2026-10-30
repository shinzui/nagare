-- | Static publication coordinator tests, with every provider operation faked.
module Nagare.Test.StaticPublish
  ( publishTests
  )
where

import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef, newIORef, readIORef)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding (Context)
import Nagare.Static.ContentDigest (ContentDigest (..))
import Nagare.Static.Package (PackageResult (..))
import Nagare.Static.Publish
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | Calls are recorded in order; each failure switch names the stage it breaks.
data Fake = Fake
  { calls :: !(IORef [Text])
  , missing :: !(Maybe Text)
  , serving :: !(Maybe (Text, Text))
  , failImage :: !(IORef Bool)
  , failDeploy :: !(IORef Bool)
  }

digestA :: ContentDigest
digestA = ContentDigest "sha256:aaa"

identityA :: Text
identityA = contentSource "sha256:cfg" digestA

newFake :: Maybe Text -> Maybe (Text, Text) -> IO Fake
newFake missing' serving' =
  Fake <$> newIORef [] <*> pure missing' <*> pure serving' <*> newIORef False <*> newIORef False

ops :: Fake -> PublishOps
ops fake =
  PublishOps
    { preflight = note "preflight" >> pure (maybe (Right ()) Left (missing fake))
    , servingSource = pure (serving fake)
    , package = \archive tag' gate -> do
        proceed <- gate digestA
        if proceed
          then do
            note "package"
            pure (Right (Just PackageResult {path = archive, digest = digestA, image = Just "reg/x", tag = Just tag', platform = Just "linux/arm64"}))
          else pure (Right Nothing)
    , publishImage = \_ -> do
        note "image"
        bad <- readIORef (failImage fake)
        pure (if bad then Left "registry refused" else Right "publication:notes/image/main")
    , deploy = \_ -> do
        note "deploy"
        bad <- readIORef (failDeploy fake)
        pure (if bad then Left "readiness timed out" else Right "https://notes.example")
    }
  where
    note what = modifyIORef (calls fake) (<> [what])

request :: FilePath -> Bool -> PublishRequest
request dir new =
  PublishRequest
    { releaseDir = dir
    , releaseId = "20261030-120000-000001"
    , tag = "20261030-120000-000001"
    , site = "notes"
    , namespace = "personal"
    , context = "test"
    , platform = "linux/arm64"
    , destination = "reg/x:t"
    , configDigest = "sha256:cfg"
    , newRelease = new
    }

withFake :: Maybe Text -> Maybe (Text, Text) -> (Fake -> FilePath -> IO a) -> IO a
withFake missing' serving' action = withSystemTempDirectory "nagare-publish" $ \dir -> do
  fake <- newFake missing' serving'
  action fake (dir </> "release")

history :: Fake -> IO [Text]
history = readIORef . calls

publishTests :: [TestTree]
publishTests =
  [ testCase "a first release runs preflight, package, image, deploy in order and records each stage" $
      withFake Nothing Nothing $ \fake dir -> do
        outcome <- runPublish (ops fake) (request dir False)
        history fake >>= (@?= ["preflight", "package", "image", "deploy"])
        case outcome of
          Right (Released receipt) -> do
            receipt ^. #stage @?= Deployed
            receipt ^. #imageResource @?= Just "publication:notes/image/main"
            receipt ^. #url @?= Just "https://notes.example"
            receipt ^. #key @?= "notes-20261030-120000-000001"
          other -> assertFailure (show other)
  , testCase "unchanged content and config report the serving release without building or mutating" $
      withFake Nothing (Just ("old-tag", identityA)) $ \fake dir -> do
        outcome <- runPublish (ops fake) (request dir False)
        outcome @?= Right (Unchanged "old-tag")
        history fake >>= (@?= ["preflight"])
  , testCase "--new-release publishes unchanged content anyway" $
      withFake Nothing (Just ("old-tag", identityA)) $ \fake dir -> do
        outcome <- runPublish (ops fake) (request dir True)
        history fake >>= (@?= ["preflight", "package", "image", "deploy"])
        either (assertFailure . show) (const (pure ())) outcome
  , testCase "changed content or changed config releases again" $ do
      withFake Nothing (Just ("old-tag", contentSource "sha256:cfg" (ContentDigest "sha256:bbb"))) $ \fake dir -> do
        _ <- runPublish (ops fake) (request dir False)
        history fake >>= (@?= ["preflight", "package", "image", "deploy"])
      withFake Nothing (Just ("old-tag", contentSource "sha256:other" digestA)) $ \fake dir -> do
        _ <- runPublish (ops fake) (request dir False)
        history fake >>= (@?= ["preflight", "package", "image", "deploy"])
  , testCase "a missing prerequisite is refused before the package operation runs" $
      withFake (Just "foundation Namespace personal is not accepted; run `nagarectl inventory apply`") Nothing $ \fake dir -> do
        outcome <- runPublish (ops fake) (request dir False)
        outcome @?= Left (PublishFailure "preflight" "foundation Namespace personal is not accepted; run `nagarectl inventory apply`")
        history fake >>= (@?= ["preflight"])
  , testCase "an image failure never deploys, and resume re-enters at the image without repackaging" $
      withFake Nothing Nothing $ \fake dir -> do
        writeIORefTrue (failImage fake)
        outcome <- runPublish (ops fake) (request dir False)
        outcome @?= Left (PublishFailure "image" "registry refused")
        history fake >>= (@?= ["preflight", "package", "image"])
        Right receipt <- readReceipt dir
        receipt ^. #stage @?= Packaged
        writeIORefFalse (failImage fake)
        resumed <- resumePublish (ops fake) dir receipt
        history fake >>= (@?= ["preflight", "package", "image", "image", "deploy"])
        either (assertFailure . show) (const (pure ())) resumed
        readReceipt dir >>= \r -> fmap (view #stage) r @?= Right Deployed
  , testCase "a deploy failure keeps the accepted image, and resume deploys without republishing" $
      withFake Nothing Nothing $ \fake dir -> do
        writeIORefTrue (failDeploy fake)
        outcome <- runPublish (ops fake) (request dir False)
        outcome @?= Left (PublishFailure "deploy" "readiness timed out")
        Right receipt <- readReceipt dir
        receipt ^. #stage @?= ImagePublished
        receipt ^. #imageResource @?= Just "publication:notes/image/main"
        writeIORefFalse (failDeploy fake)
        _ <- resumePublish (ops fake) dir receipt
        history fake >>= (@?= ["preflight", "package", "image", "deploy", "deploy"])
  , testCase "unfinished releases are listed oldest first and finished ones are not" $
      withSystemTempDirectory "nagare-publish-list" $ \root -> do
        let receipt id' stage' =
              Receipt
                { site = "notes"
                , namespace = "personal"
                , context = "test"
                , releaseId = id'
                , tag = id'
                , key = publishKey "notes" id'
                , platform = "linux/arm64"
                , destination = "d"
                , archive = "a"
                , source = "s"
                , stage = stage'
                , imageResource = Nothing
                , url = Nothing
                }
        writeReceipt (root </> "b") (receipt "b" Packaged)
        writeReceipt (root </> "a") (receipt "a" ImagePublished)
        writeReceipt (root </> "c") (receipt "c" Deployed)
        found <- unfinishedReleases root
        map (view #releaseId . snd) found @?= ["a", "b"]
  , testCase "publication keys are unique per release and the image id is computed, not parsed" $ do
      publishKey "notes" "r1" == publishKey "notes" "r2" @?= False
      case publicationImageId (publishKey "notes" "20261030-120000-000001") of
        Right resource -> assertBool "resource id empty" (not (T.null (T.pack (show resource))))
        Left e -> assertFailure (T.unpack e)
      sourceContent identityA @?= Just "sha256:aaa"
  ]
  where
    writeIORefTrue ref = modifyIORef ref (const True)
    writeIORefFalse ref = modifyIORef ref (const False)
