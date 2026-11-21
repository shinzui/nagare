-- | Publishing a prepared review to the store: its scope and native members,
-- the observation bytes its mutation envelopes carry, then the review itself.
-- Internal implementation behind Nagare.Inventory.Plan.
module Nagare.Inventory.Plan.Publish
  ( publishObservationMembers
  , publishReview
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ObservationNative.Mutation (observationBytesFromMutation)
import Nagare.Inventory.Plan.Publication (nativeKey)
import Nagare.Inventory.Plan.Types
  ( ReviewBundle (..)
  , ReviewDocument (..)
  , ReviewOperation (..)
  , encodeReviewDocument
  , reviewAdapterOperations
  , reviewDigest
  )
import Nagare.Inventory.Store
  ( InventoryStore
  , StoreError (StoreInvalidObject)
  , publishIfAbsent
  , reviewKey
  , scopeKey
  )
import Nagare.Resource.Types (ContentDigest)

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
publishObservationMembers store bundle = case traverse extract (reviewAdapterOperations document) of
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
