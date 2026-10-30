-- | One-command static site publication, as a sequence of independently
-- recoverable stages: preflight, unchanged-content check, package, reviewed
-- image publication, reviewed site deployment.
--
-- The coordinator knows no provider. Every effect is an injected operation in
-- 'PublishOps', so the ordering, the no-op, and each failure boundary are
-- checked without Docker, a cluster or an inventory store. A private versioned
-- receipt in the release directory records the stage reached; it is local
-- coordination metadata, never authority to mutate a provider. Accepted
-- inventory and its transaction journals stay authoritative: a resumed stage
-- re-enters the same reviewed operation, which is idempotent over identical
-- content and refuses (naming inventory recovery) when a transaction is pending.
module Nagare.Static.Publish
  ( Stage (..)
  , Receipt (..)
  , PublishOps (..)
  , PublishRequest (..)
  , PublishFailure (..)
  , PublishOutcome (..)
  , publishKey
  , publicationImageId
  , configDigestOf
  , contentSource
  , sourceContent
  , receiptPath
  , readReceipt
  , writeReceipt
  , unfinishedReleases
  , runPublish
  , resumePublish
  , renderPublishFailure
  )
where

import Control.Monad (forM, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecodeStrict, encode, object, withObject, withText, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding (Context)
import Nagare.Resource.Types qualified as Resource
import Nagare.Static.ContentDigest (ContentDigest (..), contentDigestText)
import Nagare.Static.Package (PackageError, PackageResult (..), renderPackageError)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, renameFile)
import System.FilePath ((</>))

-- | How far a release got. Each stage's effect is complete before the next
-- begins; the receipt names the last one proved.
data Stage = Packaged | ImagePublished | Deployed
  deriving stock (Eq, Ord, Show)

stageText :: Stage -> Text
stageText = \case
  Packaged -> "packaged"
  ImagePublished -> "image-published"
  Deployed -> "deployed"

instance ToJSON Stage where
  toJSON = toJSON . stageText

instance FromJSON Stage where
  parseJSON = withText "stage" $ \case
    "packaged" -> pure Packaged
    "image-published" -> pure ImagePublished
    "deployed" -> pure Deployed
    other -> fail ("unknown publish stage: " <> T.unpack other)

-- | The private record of one release.
data Receipt = Receipt
  { site :: !Text
  , namespace :: !Text
  , context :: !Text
  , releaseId :: !Text
  , tag :: !Text
  , key :: !Text
  , platform :: !Text
  , destination :: !Text
  , archive :: !FilePath
  , source :: !Text
  -- ^ the @content=…;config=…@ identity recorded with the release
  , stage :: !Stage
  , imageResource :: !(Maybe Text)
  , url :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Receipt where
  toJSON r =
    object
      [ "version" Aeson..= (1 :: Int)
      , "site" Aeson..= (r ^. #site)
      , "namespace" Aeson..= (r ^. #namespace)
      , "context" Aeson..= (r ^. #context)
      , "releaseId" Aeson..= (r ^. #releaseId)
      , "tag" Aeson..= (r ^. #tag)
      , "key" Aeson..= (r ^. #key)
      , "platform" Aeson..= (r ^. #platform)
      , "destination" Aeson..= (r ^. #destination)
      , "archive" Aeson..= (r ^. #archive)
      , "source" Aeson..= (r ^. #source)
      , "stage" Aeson..= (r ^. #stage)
      , "imageResource" Aeson..= (r ^. #imageResource)
      , "url" Aeson..= (r ^. #url)
      ]

instance FromJSON Receipt where
  parseJSON = withObject "receipt" $ \o -> do
    version <- o .: "version"
    when (version /= (1 :: Int)) (fail ("unsupported receipt version " <> show version))
    Receipt
      <$> o .: "site"
      <*> o .: "namespace"
      <*> o .: "context"
      <*> o .: "releaseId"
      <*> o .: "tag"
      <*> o .: "key"
      <*> o .: "platform"
      <*> o .: "destination"
      <*> o .: "archive"
      <*> o .: "source"
      <*> o .: "stage"
      <*> o .:? "imageResource"
      <*> o .:? "url"

receiptPath :: FilePath -> FilePath
receiptPath releaseDir = releaseDir </> "receipt.json"

-- | Write the receipt atomically: a crash leaves the previous receipt intact.
writeReceipt :: FilePath -> Receipt -> IO ()
writeReceipt releaseDir receipt = do
  createDirectoryIfMissing True releaseDir
  let final = receiptPath releaseDir
      staging = final <> ".new"
  LBS.writeFile staging (encode receipt)
  renameFile staging final

readReceipt :: FilePath -> IO (Either Text Receipt)
readReceipt releaseDir = do
  present <- doesFileExist (receiptPath releaseDir)
  if not present
    then pure (Left ("no publish receipt in " <> T.pack releaseDir))
    else do
      bytes <- BS.readFile (receiptPath releaseDir)
      pure $ case eitherDecodeStrict bytes of
        Left e -> Left ("unreadable publish receipt in " <> T.pack releaseDir <> ": " <> T.pack e)
        Right r -> Right r

-- | Release directories under @siteRoot@ whose receipt stopped short of
-- 'Deployed', oldest first (release ids sort by time).
unfinishedReleases :: FilePath -> IO [(FilePath, Receipt)]
unfinishedReleases siteRoot = do
  present <- doesDirectoryExist siteRoot
  if not present
    then pure []
    else do
      names <- listDirectory siteRoot
      found <- forM names $ \name -> do
        let dir = siteRoot </> name
        receipt <- readReceipt dir
        pure [(dir, r) | Right r <- [receipt], r ^. #stage /= Deployed]
      pure (sortOn (view #releaseId . snd) (concat found))

-- | The publication key for a release: unique per release identifier, so an
-- explicit repeated tag never reuses an accepted key with different content.
publishKey :: Text -> Text -> Text
publishKey siteName release = T.toLower (siteName <> "-" <> release)

-- | The image resource the reviewed publication of @key@ mints, computed with
-- the same constructors the publication uses so no console output is parsed.
publicationImageId :: Text -> Either Text Resource.ResourceId
publicationImageId keyText = do
  logical <- Resource.mkLogicalKey keyText
  owner <- Resource.mkScopeId Resource.Publication ("app-image-" <> Resource.logicalKeyText logical)
  role <- Resource.mkName "oci-image"
  pure (Resource.mintResourceId owner logical role)

-- | A digest of a typed config's value, stable across runs: it changes when
-- any declared field does, so a config-only change is never reported unchanged.
configDigestOf :: (Show a) => a -> Text
configDigestOf value = "sha256:" <> T.pack (show (hash (TE.encodeUtf8 (T.pack (show value))) :: Digest SHA256))

-- | The identity recorded as a release's provenance and compared by the
-- unchanged check: the context content digest and the config digest.
contentSource :: Text -> ContentDigest -> Text
contentSource configDigest content =
  "content=" <> contentDigestText content <> ";config=" <> configDigest

-- | The content digest inside a recorded @source@, when it carries one.
sourceContent :: Text -> Maybe Text
sourceContent recorded = case T.splitOn ";" recorded of
  (first' : _) -> T.stripPrefix "content=" first'
  [] -> Nothing

data PublishOps = PublishOps
  { preflight :: !(IO (Either Text ()))
  -- ^ every accepted prerequisite, checked before anything is built
  , servingSource :: !(IO (Maybe (Text, Text)))
  -- ^ the latest accepted release's (tag, recorded source)
  , package :: !(FilePath -> Text -> (ContentDigest -> IO Bool) -> IO (Either PackageError (Maybe PackageResult)))
  -- ^ archive path, tag, and a gate called with the content digest before any
  -- build; the gate answering 'False' skips the build
  , publishImage :: !(Receipt -> IO (Either Text Text))
  -- ^ converge the reviewed image publication; the accepted image resource
  , deploy :: !(Receipt -> IO (Either Text Text))
  -- ^ converge the reviewed site deployment; the served URL
  }

data PublishRequest = PublishRequest
  { releaseDir :: !FilePath
  , releaseId :: !Text
  , tag :: !Text
  , site :: !Text
  , namespace :: !Text
  , context :: !Text
  , platform :: !Text
  , destination :: !Text
  , configDigest :: !Text
  , newRelease :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | Why a release stopped, and where it can resume.
data PublishFailure
  = -- | stage name, message
    PublishFailure !Text !Text
  deriving stock (Eq, Show)

renderPublishFailure :: PublishFailure -> Text
renderPublishFailure (PublishFailure stageName message) = stageName <> ": " <> message

data PublishOutcome
  = -- | the serving release already has these bytes and config
    Unchanged !Text
  | Released !Receipt
  deriving stock (Eq, Show)

failAt :: Text -> Text -> Either PublishFailure a
failAt stageName = Left . PublishFailure stageName

-- | The ordered path for a new release.
runPublish :: PublishOps -> PublishRequest -> IO (Either PublishFailure PublishOutcome)
runPublish ops request = do
  checked <- preflight ops
  case checked of
    Left message -> pure (failAt "preflight" message)
    Right () -> do
      serving <- servingSource ops
      decision <- newIORef Nothing
      let archivePath = (request ^. #releaseDir) </> "site.tar"
          gate content = do
            let identity = contentSource ((request ^. #configDigest)) content
                same = fmap snd serving == Just identity
            if same && not ((request ^. #newRelease))
              then writeIORef decision (Just (maybe "" fst serving)) >> pure False
              else pure True
      packaged <- package ops archivePath ((request ^. #tag)) gate
      case packaged of
        Left e -> pure (failAt "package" (renderPackageError e))
        Right Nothing -> do
          servingTag <- readIORef decision
          pure (Right (Unchanged (maybe "" id servingTag)))
        Right (Just result) -> do
          let receipt =
                Receipt
                  { site = (request ^. #site)
                  , namespace = (request ^. #namespace)
                  , context = (request ^. #context)
                  , releaseId = (request ^. #releaseId)
                  , tag = (request ^. #tag)
                  , key = publishKey ((request ^. #site)) ((request ^. #releaseId))
                  , platform = (request ^. #platform)
                  , destination = (request ^. #destination)
                  , archive = (result ^. #path)
                  , source = contentSource ((request ^. #configDigest)) ((result ^. #digest))
                  , stage = Packaged
                  , imageResource = Nothing
                  , url = Nothing
                  }
          writeReceipt ((request ^. #releaseDir)) receipt
          continueFrom ops ((request ^. #releaseDir)) receipt

-- | Continue a retained release from the stage its receipt proves. The caller
-- has already checked the receipt against the current context and content.
resumePublish :: PublishOps -> FilePath -> Receipt -> IO (Either PublishFailure PublishOutcome)
resumePublish = continueFrom

continueFrom :: PublishOps -> FilePath -> Receipt -> IO (Either PublishFailure PublishOutcome)
continueFrom ops releaseDir' receipt0 = do
  imaged <- case (receipt0 ^. #stage, receipt0 ^. #imageResource) of
    (Packaged, _) -> do
      published <- publishImage ops receipt0
      case published of
        Left message -> pure (failAt "image" message)
        Right resource -> do
          let next = receipt0 & #stage .~ ImagePublished & #imageResource ?~ resource
          writeReceipt releaseDir' next
          pure (Right next)
    _ -> pure (Right receipt0)
  case imaged of
    Left failure -> pure (Left failure)
    Right receipt1
      | receipt1 ^. #stage == Deployed -> pure (Right (Released receipt1))
      | otherwise -> do
          deployed <- deploy ops receipt1
          case deployed of
            Left message -> pure (failAt "deploy" message)
            Right served -> do
              let done = receipt1 & #stage .~ Deployed & #url ?~ served
              writeReceipt releaseDir' done
              pure (Right (Released done))
