-- | Publication responsibilities; internal implementation behind Nagare.Inventory.Plan.
module Nagare.Inventory.Plan.Publication
  ( loadPublishedReview
  , loadReviewBundle
  , publishObservationMembers
  , publishReview
  , writeReviewBundle
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import Data.Aeson (eitherDecodeStrict')
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ObservationNative
  ( observationBytesFromMutation
  )
import Nagare.Inventory.Plan.Types
  ( ReviewBundle (..)
  , ReviewDocument (..)
  , ReviewOperation (..)
  , encodeReviewDocument
  , fenceMembersValid
  , reviewDigest
  , reviewPrivateDigests
  )
import Nagare.Inventory.Store
  ( InventoryStore
  , ScopeRevision (revisionDigest)
  , StoreError (StoreInvalidObject)
  , objectKeyFor
  , publishIfAbsent
  , readObject
  , reviewKey
  , scopeKey
  )
import Nagare.Resource.Types
  ( ContentDigest
  , digestText
  , mkContentDigest
  )
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , doesPathExist
  , listDirectory
  , pathIsSymbolicLink
  , renameDirectory
  )
import System.FilePath
  ( takeDirectory
  , takeFileName
  , (<.>)
  , (</>)
  )
import System.IO.Temp (withTempDirectory)
import System.Posix.Files (setFileMode)

publishReview :: InventoryStore -> ReviewBundle -> IO (Either StoreError ContentDigest)
publishReview store bundle = do
  scopeResults <- traverse (\(digest, bytes) -> publishIfAbsent store (scopeKey digest) bytes) (Map.toAscList (bundleScopes bundle))
  case sequence scopeResults of
    Left err -> pure (Left err)
    Right _ -> do
      nativeResults <- traverse (\(digest, bytes) -> publishIfAbsent store (nativeKey digest) bytes) (Map.toAscList (bundleNative bundle))
      case sequence nativeResults of
        Left err -> pure (Left err)
        Right _ -> do
          observations <- publishObservationMembers store bundle
          case observations of
            Left err -> pure (Left err)
            Right () ->
              publishIfAbsent
                store
                (reviewKey (reviewDigest bundle))
                (encodeReviewDocument (bundleDocument bundle))

-- | Add only immutable, digest-addressed observation bytes. This never changes
-- a head, accepted scope, operation, or admission decision. Repeating after an
-- interruption is safe. The caller must supply an original prepared/loaded review.
publishObservationMembers :: InventoryStore -> ReviewBundle -> IO (Either StoreError ())
publishObservationMembers store bundle = case traverse extract (reviewOperations document) of
  Left reason -> pure (Left (StoreInvalidObject (reviewKey (reviewDigest bundle)) reason))
  Right values -> do
    results <-
      traverse
        (\bytes -> publishIfAbsent store (nativeKey (contentDigest bytes)) bytes)
        (Map.elems (Map.fromList [(contentDigest bytes, bytes) | Just bytes <- values]))
    pure (() <$ sequence results)
  where
    document = bundleDocument bundle
    extract operation = case reviewNativeDigest operation of
      Nothing -> Right Nothing
      Just digest -> do
        bytes <-
          maybe
            (Left "review native member is missing")
            Right
            (Map.lookup digest (bundleNative bundle))
        unless (contentDigest bytes == digest) (Left "review native member digest mismatch")
        observationBytesFromMutation
          (reviewContextBinding document ^. #identity)
          (reviewAdapterIdentity operation)
          (reviewAdapterVersion operation)
          (reviewPlannedOperation operation)
          bytes

loadPublishedReview :: InventoryStore -> ContentDigest -> IO (Either StoreError ReviewBundle)
loadPublishedReview store digest = do
  documentResult <- readObject store (reviewKey digest)
  case documentResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Left (StoreInvalidObject (reviewKey digest) "published review is missing"))
    Right (Just bytes) -> case eitherDecodeStrict' bytes of
      Left err -> pure (Left (StoreInvalidObject (reviewKey digest) (T.pack err)))
      Right document
        | encodeReviewDocument document /= bytes -> pure (Left (StoreInvalidObject (reviewKey digest) "published review is not canonical"))
        | contentDigest bytes /= digest -> pure (Left (StoreInvalidObject (reviewKey digest) "published review digest mismatch"))
        | otherwise -> do
            scopeResults <- traverse (readRequired store . scopeKey) [revisionDigest revision | revision <- Map.elems (reviewDesiredRevisions document)]
            nativeResults <-
              traverse
                (readRequired store . nativeKey)
                (reviewPrivateDigests document)
            pure $ do
              scopes <- sequence scopeResults
              native <- sequence nativeResults
              let scopeMap = Map.fromList [(contentDigest member, member) | member <- scopes]
                  nativeMap = Map.fromList [(contentDigest member, member) | member <- native]
              if fenceMembersValid document nativeMap
                then pure (ReviewBundle document scopeMap nativeMap)
                else
                  Left
                    ( StoreInvalidObject
                        (reviewKey digest)
                        "published data fence member is malformed"
                    )
  where
    readRequired inventoryStore key = do
      loaded <- readObject inventoryStore key
      pure (loaded >>= maybe (Left (StoreInvalidObject key "published review member is missing")) Right)

writeReviewBundle :: FilePath -> ReviewBundle -> IO (Either Text ContentDigest)
writeReviewBundle output bundle = do
  attempted <- try $ do
    exists <- doesPathExist output
    when exists (ioError (userError "review output already exists"))
    let parent = takeDirectory output
    createDirectoryIfMissing True parent
    withTempDirectory parent ".inventory-review-" $ \staging -> do
      setFileMode staging 0o700
      createPrivateDirectory (staging </> "scopes")
      let documentBytes = encodeReviewDocument (bundleDocument bundle)
          digest = reviewDigest bundle
      writePrivate (staging </> "review.json") documentBytes
      writePrivate (staging </> "review.sha256") (BC.pack (T.unpack (digestText digest)) <> "\n")
      forM_ (Map.toAscList (bundleScopes bundle)) $ \(memberDigest, bytes) -> writePrivate (staging </> scopeMemberPath memberDigest) bytes
      renameDirectory staging output
  pure $ case attempted of
    Left (err :: IOException) -> Left (T.pack (show err))
    Right () -> Right (reviewDigest bundle)
  where
    createPrivateDirectory path = createDirectory path >> setFileMode path 0o700
    writePrivate path bytes = BS.writeFile path bytes >> setFileMode path 0o600

loadReviewBundle :: FilePath -> IO (Either Text ReviewBundle)
loadReviewBundle directory = do
  attempted <- try $ do
    rejectLink directory
    documentBytes <- readRegular (directory </> "review.json")
    checksum <- readRegular (directory </> "review.sha256")
    document <- either (ioError . userError) pure (eitherDecodeStrict' documentBytes)
    let canonical = encodeReviewDocument document
        digest = contentDigest canonical
    unless (canonical == documentBytes) (ioError (userError "review document is not canonical"))
    unless (checksum == BC.pack (T.unpack (digestText digest)) <> "\n") (ioError (userError "review checksum mismatch"))
    scopes <- loadMembers directory scopeMemberPath [revisionDigest revision | revision <- Map.elems (reviewDesiredRevisions document)]
    let expectedRoot = sort ["review.json", "review.sha256", "scopes"]
    rootEntries <- sort <$> listDirectory directory
    unless (rootEntries == expectedRoot) (ioError (userError "review directory has unexpected members"))
    pure (ReviewBundle document scopes Map.empty)
  pure $ first (T.pack . show) (attempted :: Either IOException ReviewBundle)
  where
    loadMembers root memberPath digests = do
      let uniqueDigests = Set.toAscList (Set.fromList digests)
          subdirectory = takeDirectory (memberPath (headOrZero uniqueDigests))
          expected = sort [takeFileName (memberPath digest) | digest <- uniqueDigests]
      rejectLink (root </> subdirectory)
      actual <- sort <$> listDirectory (root </> subdirectory)
      unless (actual == expected) (ioError (userError (subdirectory <> " members differ from review")))
      fmap Map.fromList $ forM uniqueDigests $ \digest -> do
        bytes <- readRegular (root </> memberPath digest)
        unless (contentDigest bytes == digest) (ioError (userError "review member digest mismatch"))
        pure (digest, bytes)
    headOrZero [] = either (error . T.unpack) id (mkContentDigest (T.replicate 64 "0"))
    headOrZero (value : _) = value
    rejectLink path = pathIsSymbolicLink path >>= (`when` ioError (userError (path <> " is a symlink")))
    readRegular path = rejectLink path >> BS.readFile path

nativeKey :: ContentDigest -> FilePath
nativeKey = objectKeyFor "native"

scopeMemberPath :: ContentDigest -> FilePath
scopeMemberPath digest = "scopes" </> T.unpack (digestText digest) <.> "json"
