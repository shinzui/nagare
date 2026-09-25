{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded GitHub CLI transport for the reviewed release protocol. All
-- observations address release or asset IDs; failures remain unknown.
module Nagare.Inventory.Adapters.GitHubReleaseRuntime (githubReleaseOps) where

import Control.Exception (IOException, try)
import Data.Aeson ((.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Nagare.Dsl.Prelude hiding (review)
import Nagare.Inventory.Adapters.GitHubRelease
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hFlush)
import System.IO.Temp (withSystemTempDirectory, withSystemTempFile)
import System.Process
  ( CreateProcess (..)
  , StdStream (..)
  , createProcess
  , proc
  , readProcessWithExitCode
  , waitForProcess
  )

githubReleaseOps :: PublicationReview -> GitHubReleaseOps
githubReleaseOps review =
  GitHubReleaseOps
    { readProviderTag = readTag
    , listProviderReleases = listReleases
    , createProviderDraft = createDraft
    , uploadProviderAsset = uploadAsset (publicationRepository review)
    , downloadProviderAsset = downloadAsset (publicationRepository review)
    , publishProviderDraft = publishDraft
    , deleteProviderAsset = deleteAsset (publicationRepository review)
    }

readTag :: Text -> Text -> IO (Either Text (Text, Text))
readTag repository tag = do
  reference <- ghJson ["repos/" <> unpack repository <> "/git/ref/tags/" <> unpack tag]
  case reference >>= parseValue parseRef of
    Left err -> pure (Left err)
    Right (objectType, objectSha)
      | objectType == "commit" -> pure (Right (objectSha, objectSha))
      | objectType == "tag" -> do
          object <- ghJson ["repos/" <> unpack repository <> "/git/tags/" <> unpack objectSha]
          pure $ do
            (targetType, commit) <- object >>= parseValue parseTagObject
            if targetType == "commit"
              then Right (objectSha, commit)
              else Left "release tag does not point directly to a commit"
      | otherwise -> pure (Left "release tag has an unsupported object type")

listReleases :: Text -> IO (Either Text [PublicationRelease])
listReleases repository = do
  listed <- ghJson ["repos/" <> unpack repository <> "/releases?per_page=100", "--paginate", "--slurp"]
  case listed >>= parseValue Aeson.parseJSON of
    Left err -> pure (Left err)
    Right pages -> do
      loaded <- traverse (loadRelease repository) (concat (pages :: [[Aeson.Value]]))
      pure (sequence loaded)

loadRelease :: Text -> Aeson.Value -> IO (Either Text PublicationRelease)
loadRelease repository value = case parseValue parseRelease value of
  Left err -> pure (Left err)
  Right release -> do
    assets <-
      ghJson
        [ "repos/"
            <> unpack repository
            <> "/releases/"
            <> show (providerReleaseId release)
            <> "/assets?per_page=100"
        , "--paginate"
        , "--slurp"
        ]
    pure $ do
      pages <- assets >>= parseValue Aeson.parseJSON
      members <- traverse (parseValue parseAsset) (concat (pages :: [[Aeson.Value]]))
      Right release {providerReleaseAssets = members}

createDraft :: PublicationReview -> IO (Either Text ())
createDraft review = withJsonInput payload $ \path ->
  ghNoOutput
    [ "-X"
    , "POST"
    , "repos/" <> unpack (publicationRepository review) <> "/releases"
    , "--input"
    , path
    , "--silent"
    ]
  where
    payload =
      Aeson.object
        [ "tag_name" Aeson..= publicationTag review
        , "target_commitish" Aeson..= publicationCommit review
        , "name" Aeson..= releaseTitle review
        , "body" Aeson..= publicationBody review
        , "draft" Aeson..= True
        , "generate_release_notes" Aeson..= False
        , "make_latest" Aeson..= ("false" :: Text)
        ]

uploadAsset :: Text -> Integer -> Text -> ByteString -> IO (Either Text ())
uploadAsset repository releaseId name bytes =
  withSystemTempDirectory "nagare-release-upload" $ \root -> do
    let path = root </> unpack name
        endpoint =
          "https://uploads.github.com/repos/"
            <> unpack repository
            <> "/releases/"
            <> show releaseId
            <> "/assets?name="
            <> unpack name
    BS.writeFile path bytes
    ghNoOutput
      [ "-X"
      , "POST"
      , "-H"
      , "Content-Type: application/octet-stream"
      , endpoint
      , "--input"
      , path
      , "--silent"
      ]

downloadAsset :: Text -> Integer -> IO (Either Text ByteString)
downloadAsset repository identifier =
  withSystemTempFile "nagare-release-download" $ \path handle -> do
    withSystemTempFile "nagare-release-download-error" $ \errorPath errorHandle -> do
      attempted <- try $ do
        (_, _, _, process) <-
          createProcess
            ( proc
                "gh"
                [ "api"
                , "-H"
                , "Accept: application/octet-stream"
                , "repos/" <> unpack repository <> "/releases/assets/" <> show identifier
                ]
            )
              { std_out = UseHandle handle
              , std_err = UseHandle errorHandle
              }
        code <- waitForProcess process
        case code of
          ExitSuccess -> Right <$> BS.readFile path
          ExitFailure _ -> do
            details <- BC.readFile errorPath
            pure (Left (T.pack (take 1000 (BC.unpack details))))
      pure (either (Left . T.pack . show) id (attempted :: Either IOException (Either Text ByteString)))

publishDraft :: Integer -> PublicationReview -> IO (Either Text ())
publishDraft releaseId review = withJsonInput payload $ \path ->
  ghNoOutput
    [ "-X"
    , "PATCH"
    , "repos/"
        <> unpack (publicationRepository review)
        <> "/releases/"
        <> show releaseId
    , "--input"
    , path
    , "--silent"
    ]
  where
    payload =
      Aeson.object
        [ "tag_name" Aeson..= publicationTag review
        , "target_commitish" Aeson..= publicationCommit review
        , "name" Aeson..= releaseTitle review
        , "body" Aeson..= publicationBody review
        , "draft" Aeson..= False
        , "generate_release_notes" Aeson..= False
        , "make_latest" Aeson..= ("true" :: Text)
        ]

deleteAsset :: Text -> Integer -> IO (Either Text ())
deleteAsset repository assetId =
  ghNoOutput
    [ "-X"
    , "DELETE"
    , "repos/" <> unpack repository <> "/releases/assets/" <> show assetId
    , "--silent"
    ]

releaseTitle :: PublicationReview -> Text
releaseTitle review =
  "Nagare "
    <> maybe
      (publicationTag review)
      id
      (T.stripPrefix "v" (publicationTag review))

withJsonInput :: Aeson.Value -> (FilePath -> IO a) -> IO a
withJsonInput value action =
  withSystemTempFile "nagare-release-request.json" $ \path handle -> do
    LBS.hPut handle (Aeson.encode value)
    hFlush handle
    action path

ghNoOutput :: [String] -> IO (Either Text ())
ghNoOutput args = fmap (fmap (const ())) (ghBytes args)

ghJson :: [String] -> IO (Either Text Aeson.Value)
ghJson args = do
  result <- ghBytes args
  pure $ result >>= either (Left . T.pack) Right . Aeson.eitherDecodeStrict'

ghBytes :: [String] -> IO (Either Text ByteString)
ghBytes args = do
  attempted <- try (readProcessWithExitCode "gh" ("api" : apiHeader <> args) "")
  pure $ case attempted of
    Left (err :: IOException) -> Left (T.pack (show err))
    Right (ExitSuccess, output, _) -> Right (encodeUtf8 (T.pack output))
    Right (ExitFailure _, _, details) -> Left (T.pack (take 1000 details))
  where
    apiHeader = ["-H", "X-GitHub-Api-Version: 2026-03-10"]

parseValue :: (Aeson.Value -> Parser a) -> Aeson.Value -> Either Text a
parseValue parser = either (Left . T.pack) Right . parseEither parser

parseRef :: Aeson.Value -> Parser (Text, Text)
parseRef = Aeson.withObject "release tag reference" $ \root -> do
  object <- root .: "object"
  (,) <$> object .: "type" <*> object .: "sha"

parseTagObject :: Aeson.Value -> Parser (Text, Text)
parseTagObject = Aeson.withObject "annotated release tag" $ \root -> do
  object <- root .: "object"
  (,) <$> object .: "type" <*> object .: "sha"

parseRelease :: Aeson.Value -> Parser PublicationRelease
parseRelease = Aeson.withObject "GitHub release" $ \root ->
  PublicationRelease
    <$> root .: "id"
    <*> root .: "tag_name"
    <*> (root .:? "body" >>= pure . maybe "" id)
    <*> root .: "draft"
    <*> pure []

parseAsset :: Aeson.Value -> Parser PublicationAsset
parseAsset = Aeson.withObject "GitHub release asset" $ \root ->
  PublicationAsset
    <$> root .: "id"
    <*> root .: "name"
    <*> root .: "state"
    <*> root .: "size"
    <*> root .:? "digest"

unpack :: Text -> String
unpack = T.unpack
