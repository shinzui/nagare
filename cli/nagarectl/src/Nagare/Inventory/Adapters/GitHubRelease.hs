{-# LANGUAGE OverloadedStrings #-}

-- | Provider-durable, reviewed publication of a GitHub release. The provider
-- operations are injected so the recovery protocol can be fault-tested without
-- treating a runner's filesystem as publication authority.
module Nagare.Inventory.Adapters.GitHubRelease
  ( ProductAsset (..)
  , PublicationReview
  , publicationBody
  , publicationDigest
  , publicationRepository
  , publicationTag
  , publicationTagObject
  , publicationCommit
  , publicationPayload
  , PublicationAsset (..)
  , PublicationRelease (..)
  , GitHubReleaseOps (..)
  , compilePublicationReview
  , publishReviewedRelease
  , cleanupReviewedStarter
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (traverse_)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Nagare.Dsl.Prelude hiding (review)
import Nagare.Inventory.Artifact
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types (digestText)
import Nagare.Resource.Wire (canonicalValue)

data ProductAsset = ProductAsset
  { productName :: !Text
  , productSpec :: !ArtifactExecutionSpec
  , productBytes :: !ByteString
  }
  deriving stock (Eq, Show)

data PublicationReview = PublicationReview
  { publicationRepository :: !Text
  , publicationTag :: !Text
  , publicationTagObject :: !Text
  , publicationCommit :: !Text
  , publicationPayload :: !Text
  , publicationBody :: !Text
  , publicationDigest :: !Text
  , publicationProducts :: ![ProductAsset]
  }
  deriving stock (Eq, Show)

data PublicationAsset = PublicationAsset
  { providerAssetId :: !Integer
  , providerAssetName :: !Text
  , providerAssetState :: !Text
  , providerAssetSize :: !Integer
  , providerAssetDigest :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data PublicationRelease = PublicationRelease
  { providerReleaseId :: !Integer
  , providerReleaseTag :: !Text
  , providerReleaseBody :: !Text
  , providerReleaseDraft :: !Bool
  , providerReleaseAssets :: ![PublicationAsset]
  }
  deriving stock (Eq, Show)

data GitHubReleaseOps = GitHubReleaseOps
  { readProviderTag :: !(Text -> Text -> IO (Either Text (Text, Text)))
  , listProviderReleases :: !(Text -> IO (Either Text [PublicationRelease]))
  , createProviderDraft :: !(PublicationReview -> IO (Either Text ()))
  , uploadProviderAsset :: !(Integer -> Text -> ByteString -> IO (Either Text ()))
  , downloadProviderAsset :: !(Integer -> IO (Either Text ByteString))
  , publishProviderDraft :: !(Integer -> PublicationReview -> IO (Either Text ()))
  , deleteProviderAsset :: !(Integer -> IO (Either Text ()))
  }

-- | Candidate bytes and the EP-146 artifact declarations are checked before
-- producing the body that the first provider write must persist unchanged.
compilePublicationReview ::
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  [ProductAsset] ->
  Either Text PublicationReview
compilePublicationReview repository tag tagObject commit payload notes products = do
  unlessText (validRepository repository) "invalid release repository"
  unlessText (validTag tag) "invalid release tag"
  unlessText (validSha tagObject && validSha commit) "tag object and commit must be full Git SHA-1 identities"
  unlessText (not (T.null payload)) "release payload identity is missing"
  unlessText (not (null products) && length products <= 999) "release requires 1–999 product assets"
  let names = map productName products
  unlessText
    (length names == Map.size (Map.fromList [(name, ()) | name <- names]))
    "release asset names must be unique"
  traverse_ (validateProduct repository tag) products
  let members = sortOn (productName . fst) [(item, digestText (contentDigest (productBytes item))) | item <- products]
      intent =
        Aeson.object
          [ "schemaVersion" Aeson..= (1 :: Int)
          , "repository" Aeson..= repository
          , "tag" Aeson..= tag
          , "tagObject" Aeson..= tagObject
          , "commit" Aeson..= commit
          , "payloadId" Aeson..= payload
          , "notesSha256" Aeson..= digestText (contentDigest (encodeUtf8 notes))
          , "assets" Aeson..= [Aeson.object ["name" Aeson..= productName item, "sha256" Aeson..= digest] | (item, digest) <- members]
          ]
  intentBytes <- canonicalValue intent
  let body = notes <> "\n\n<!-- nagare-release-intent-v1\n" <> decodeUtf8 intentBytes <> "\n-->\n"
  unlessText (BS.length (encodeUtf8 body) <= 32768) "release notes and intent exceed the reviewed 32 KiB body bound"
  pure
    PublicationReview
      { publicationRepository = repository
      , publicationTag = tag
      , publicationTagObject = tagObject
      , publicationCommit = commit
      , publicationPayload = payload
      , publicationBody = body
      , publicationDigest = digestText (contentDigest intentBytes)
      , publicationProducts = map fst members
      }

validateProduct :: Text -> Text -> ProductAsset -> Either Text ()
validateProduct repository tag item = do
  let name = productName item
      spec = productSpec item
      bytes = productBytes item
      expectedDestination = "github-release://" <> repository <> "/" <> tag <> "/" <> name
  unlessText (validName name) ("invalid release asset name: " <> name)
  unlessText (BS.length bytes < 2 * 1024 * 1024 * 1024) ("release asset exceeds GitHub's 2 GiB limit: " <> name)
  unlessText (executionArtifactKind spec == ReleasePayloadArtifact) ("release asset has a different artifact kind: " <> name)
  unlessText (executionArtifactDestination spec == expectedDestination) ("release asset destination does not bind repository, tag, and name: " <> name)
  unlessText (executionArtifactContentDigest spec == contentDigest bytes) ("release asset bytes differ from the reviewed digest: " <> name)

-- | Every retry starts from provider observations. A query failure is unknown,
-- and a draft with the right body but a changed tag is a refusal.
publishReviewedRelease :: GitHubReleaseOps -> PublicationReview -> IO (Either Text PublicationRelease)
publishReviewedRelease ops review = do
  tagIdentity <- readProviderTag ops (publicationRepository review) (publicationTag review)
  case tagIdentity of
    Left err -> pure (Left ("could not verify release tag: " <> err))
    Right (tagObject, commit)
      | tagObject /= publicationTagObject review || commit /= publicationCommit review ->
          pure (Left "release tag object or commit differs from the reviewed candidate")
    Right _ -> publishVerifiedTag
  where
    publishVerifiedTag = do
      initial <- findRelease ops review
      case initial of
        Left err -> pure (Left err)
        Right Nothing -> do
          created <- createProviderDraft ops review
          found <- findRelease ops review
          case (created, found) of
            (_, Left err) -> pure (Left err)
            (_, Right (Just release)) -> continue release
            (Left err, Right Nothing) -> pure (Left ("draft create outcome is unknown: " <> err))
            (Right (), Right Nothing) -> pure (Left "created draft is not yet visible; retry after the provider listing converges")
        Right (Just release) -> continue release
    continue release = do
      let expectedProducts = map productName (publicationProducts review)
          extra =
            [ providerAssetName asset
            | asset <- providerReleaseAssets release
            , providerAssetName asset `notElem` expectedProducts
            , not ("nagare-verification-" `T.isPrefixOf` providerAssetName asset)
            ]
          receiptNames =
            [ providerAssetName asset
            | asset <- providerReleaseAssets release
            , "nagare-verification-" `T.isPrefixOf` providerAssetName asset
            ]
      if not (null extra)
        then pure (Left ("unreviewed release assets are present: " <> T.intercalate ", " extra))
        else do
          prechecked <- traverse (verifyExistingProduct release) (publicationProducts review)
          case sequence prechecked of
            Left err -> pure (Left err)
            Right existing
              | not (null receiptNames) && any (== Nothing) existing ->
                  pure (Left "verification receipt exists before every reviewed product is present")
              | otherwise -> do
                  verified <- traverse (ensureProduct release) (publicationProducts review)
                  case sequence verified of
                    Left err -> pure (Left err)
                    Right assets -> do
                      receiptResult <- receiptFor review release assets
                      case receiptResult of
                        Left err -> pure (Left err)
                        Right (receiptName, receiptBytes)
                          | any (/= receiptName) receiptNames ->
                              pure (Left "unreviewed verification receipt is present")
                          | otherwise -> do
                              receipt <- ensureAsset release receiptName receiptBytes
                              case receipt of
                                Left err -> pure (Left err)
                                Right _ -> finish release receiptName receiptBytes
    verifyExistingProduct release item =
      case matchingAssets (productName item) (providerReleaseAssets release) of
        [] -> pure (Right Nothing)
        [asset] -> fmap (fmap Just) (verifyAsset ops asset (productBytes item))
        _ -> pure (Left ("duplicate provider assets named " <> productName item))
    ensureProduct release item = ensureAsset release (productName item) (productBytes item)
    ensureAsset release name bytes =
      case matchingAssets name (providerReleaseAssets release) of
        []
          | not (providerReleaseDraft release) ->
              pure (Left ("published release is missing reviewed asset: " <> name))
        [] -> do
          uploaded <- uploadProviderAsset ops (providerReleaseId release) name bytes
          observed <- findRelease ops review
          case observed of
            Left err -> pure (Left err)
            Right Nothing -> pure (Left "release disappeared after asset upload")
            Right (Just current)
              | providerReleaseId current /= providerReleaseId release ->
                  pure (Left "release physical ID changed after asset upload")
            Right (Just current) ->
              case matchingAssets name (providerReleaseAssets current) of
                [asset] -> verifyAsset ops asset bytes
                [] -> pure (Left (maybe "uploaded asset is not yet visible; retry" ("asset upload outcome is unknown: " <>) (either Just (const Nothing) uploaded)))
                _ -> pure (Left ("duplicate provider assets named " <> name))
        [asset] -> verifyAsset ops asset bytes
        _ -> pure (Left ("duplicate provider assets named " <> name))
    finish original receiptName receiptBytes = do
      observed <- findRelease ops review
      case observed of
        Left err -> pure (Left err)
        Right Nothing -> pure (Left "release disappeared before publication")
        Right (Just current)
          | providerReleaseId current /= providerReleaseId original ->
              pure (Left "release physical ID changed before publication")
        Right (Just current) -> do
          let expectedNames = map productName (publicationProducts review) <> [receiptName]
              actualNames = map providerAssetName (providerReleaseAssets current)
          if sortOn id actualNames /= sortOn id expectedNames
            then pure (Left "release asset set changed after verification")
            else do
              verified <- traverse (\item -> verifyNamed current (productName item) (productBytes item)) (publicationProducts review)
              receiptVerified <- verifyNamed current receiptName receiptBytes
              case sequence verified *> receiptVerified of
                Left err -> pure (Left err)
                Right _ | not (providerReleaseDraft current) -> pure (Right current)
                Right _ -> do
                  tagIdentity <- readProviderTag ops (publicationRepository review) (publicationTag review)
                  let bound = tagIdentity == Right (publicationTagObject review, publicationCommit review)
                  if not bound
                    then pure (Left "release tag changed before publication")
                    else do
                      published <- publishProviderDraft ops (providerReleaseId original) review
                      final <- findRelease ops review
                      case final of
                        Left err -> pure (Left err)
                        Right Nothing -> pure (Left "release disappeared after publish request")
                        Right (Just result)
                          | providerReleaseId result /= providerReleaseId original -> pure (Left "release physical ID changed")
                          | providerReleaseDraft result ->
                              pure (Left (maybe "publish outcome is unknown; retry" ("publish outcome is unknown: " <>) (either Just (const Nothing) published)))
                          | sortOn providerAssetName (providerReleaseAssets result) /= sortOn providerAssetName (providerReleaseAssets current) ->
                              pure (Left "published release asset identities changed")
                          | otherwise -> do
                              finalProducts <- traverse (\item -> verifyNamed result (productName item) (productBytes item)) (publicationProducts review)
                              finalReceipt <- verifyNamed result receiptName receiptBytes
                              pure (sequence finalProducts *> finalReceipt *> Right result)
    verifyNamed release name bytes =
      case matchingAssets name (providerReleaseAssets release) of
        [asset] -> verifyAsset ops asset bytes
        _ -> pure (Left ("reviewed release asset is missing or duplicated: " <> name))

-- | Cleanup is a separate, exact reviewed action. Only a draft placeholder
-- bearing the supplied physical ID can be removed. A verification-receipt
-- placeholder is eligible only after all product assets verify and its name
-- can be reconstructed from their provider identities.
cleanupReviewedStarter ::
  GitHubReleaseOps ->
  PublicationReview ->
  Integer ->
  Integer ->
  Text ->
  IO (Either Text ())
cleanupReviewedStarter ops review releaseId assetId assetName = do
  identity <- readProviderTag ops (publicationRepository review) (publicationTag review)
  if identity /= Right (publicationTagObject review, publicationCommit review)
    then pure (Left "release tag identity is unknown or changed")
    else do
      found <- findRelease ops review
      case found of
        Left err -> pure (Left err)
        Right Nothing -> pure (Left "reviewed release draft is absent")
        Right (Just release)
          | providerReleaseId release /= releaseId -> pure (Left "release physical ID differs from the cleanup review")
          | not (providerReleaseDraft release) -> pure (Left "published release assets cannot be cleaned up")
          | otherwise -> case matchingAssets assetName (providerReleaseAssets release) of
              [asset]
                | providerAssetId asset /= assetId -> pure (Left "asset physical ID differs from the cleanup review")
                | providerAssetState asset /= "starter" -> pure (Left "asset is not a failed upload placeholder")
                | otherwise -> do
                    eligible <- cleanupNameEligible release assetName
                    case eligible of
                      Left err -> pure (Left err)
                      Right () -> do
                        deleted <- deleteProviderAsset ops assetId
                        observed <- findRelease ops review
                        pure $ case observed of
                          Left err -> Left err
                          Right Nothing -> Left "release disappeared after cleanup"
                          Right (Just current)
                            | providerReleaseId current /= releaseId -> Left "release physical ID changed after cleanup"
                            | null (matchingAssets assetName (providerReleaseAssets current)) -> Right ()
                            | otherwise -> Left (maybe "starter cleanup outcome is unknown" ("starter cleanup outcome is unknown: " <>) (either Just (const Nothing) deleted))
              _ -> pure (Left "failed upload placeholder is absent or duplicated")
  where
    cleanupNameEligible release name
      | name `elem` map productName (publicationProducts review) = pure (Right ())
      | otherwise = do
          products <- traverse (verifyProduct release) (publicationProducts review)
          case sequence products of
            Left err -> pure (Left err)
            Right assets -> do
              expected <- receiptFor review release assets
              pure $ do
                (receiptName, _) <- expected
                unlessText (name == receiptName) "asset is not the reviewed verification receipt"
    verifyProduct release item =
      case matchingAssets (productName item) (providerReleaseAssets release) of
        [asset] -> verifyAsset ops asset (productBytes item)
        _ -> pure (Left ("reviewed product is missing before receipt cleanup: " <> productName item))

receiptFor :: PublicationReview -> PublicationRelease -> [PublicationAsset] -> IO (Either Text (Text, ByteString))
receiptFor review release assets =
  pure $ do
    bytes <-
      canonicalValue $
        Aeson.object
          [ "schemaVersion" Aeson..= (1 :: Int)
          , "repository" Aeson..= publicationRepository review
          , "tag" Aeson..= publicationTag review
          , "releaseId" Aeson..= providerReleaseId release
          , "reviewDigest" Aeson..= publicationDigest review
          , "bodySha256" Aeson..= digestText (contentDigest (encodeUtf8 (publicationBody review)))
          , "assets"
              Aeson..= [ Aeson.object
                           [ "id" Aeson..= providerAssetId asset
                           , "name" Aeson..= providerAssetName asset
                           , "sha256" Aeson..= digestText (contentDigest (productBytes item))
                           ]
                       | (asset, item) <- sortOn (providerAssetName . fst) (zip assets (publicationProducts review))
                       ]
          ]
    let name = "nagare-verification-" <> digestText (contentDigest bytes) <> ".json"
    pure (name, bytes)

findRelease :: GitHubReleaseOps -> PublicationReview -> IO (Either Text (Maybe PublicationRelease))
findRelease ops review = do
  listed <- listProviderReleases ops (publicationRepository review)
  pure $ do
    releases <- listed
    let related =
          filter
            ( \release ->
                providerReleaseTag release == publicationTag review
                  || providerReleaseBody release == publicationBody review
            )
            releases
    case related of
      [] -> Right Nothing
      [release]
        | providerReleaseTag release /= publicationTag review -> Left "reviewed release body is attached to another tag"
        | providerReleaseBody release /= publicationBody review -> Left "release tag exists with different intent or notes"
        | otherwise -> Right (Just release)
      _ -> Left "more than one release matches the reviewed tag or body"

verifyAsset :: GitHubReleaseOps -> PublicationAsset -> ByteString -> IO (Either Text PublicationAsset)
verifyAsset ops asset expected
  | providerAssetState asset /= "uploaded" = pure (Left ("release asset is not uploaded: " <> providerAssetName asset))
  | providerAssetSize asset /= fromIntegral (BS.length expected) = pure (Left ("release asset has different size: " <> providerAssetName asset))
  | maybe False (/= digest) (providerAssetDigest asset) = pure (Left ("release asset has different provider digest: " <> providerAssetName asset))
  | otherwise = do
      downloaded <- downloadProviderAsset ops (providerAssetId asset)
      pure $ case downloaded of
        Left err -> Left ("could not verify release asset " <> providerAssetName asset <> ": " <> err)
        Right bytes
          | bytes == expected -> Right asset
          | otherwise -> Left ("release asset has different downloaded bytes: " <> providerAssetName asset)
  where
    digest = "sha256:" <> digestText (contentDigest expected)

matchingAssets :: Text -> [PublicationAsset] -> [PublicationAsset]
matchingAssets name = filter ((== name) . providerAssetName)

unlessText :: Bool -> Text -> Either Text ()
unlessText condition err = if condition then Right () else Left err

validRepository :: Text -> Bool
validRepository value = case T.splitOn "/" value of
  [owner, repo] -> validToken owner && validToken repo
  _ -> False

validTag :: Text -> Bool
validTag value = not (T.null value) && T.all safeChar value && not (".." `T.isInfixOf` value)

validSha :: Text -> Bool
validSha value = T.length value == 40 && T.all (\c -> isDigit c || c `elem` ("abcdef" :: String)) value

validName :: Text -> Bool
validName value =
  not (T.null value)
    && T.length value <= 200
    && T.all safeChar value
    && T.head value /= '.'
    && T.last value /= '.'

validToken :: Text -> Bool
validToken value = not (T.null value) && T.all safeChar value

safeChar :: Char -> Bool
safeChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("._-" :: String)
