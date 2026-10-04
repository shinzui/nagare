{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Claims responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.Claims
  ( acquireResumeClaim
  , executorStillClaimed
  , observeCurrentHead
  , releaseAbortedClaim
  , releaseClaim
  , releaseClaimWith
  , releaseStoppedApplicationClaim
  )
where

import Data.Either (isRight)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Nagare.Dsl.Prelude
import Nagare.Inventory.Execute.Incarnations (IncarnationBinding, bindIncarnations)
import Nagare.Inventory.Execute.Types
  ( AdmissionError (..)
  , failure
  , showText
  , timestamp
  )
import Nagare.Inventory.Journal
  ( TransactionId
  , transactionIdText
  )
import Nagare.Inventory.Plan
  ( ReviewDocument (reviewBaseRevisions, reviewDesiredRevisions)
  )
import Nagare.Inventory.Store
  ( ExecutorClaim
      ( ExecutorClaim
      , claimClientIdentity
      , claimEpoch
      , claimTransaction
      )
  , HeadManifest
    ( headAccepted
    , headActiveTransaction
    , headClientIdentity
    , headCollected
    , headConverged
    , headDataFence
    , headExecutorClaim
    , headGeneration
    , headIncarnations
    , headRetained
    )
  , InventoryStore
  , LockedStore
  , ObservedHead
  , ScopeRevision
  , StoreError
  , lockedStore
  , observeHead
  , observedHeadManifest
  , readHead
  , replaceObservedHead
  , storeClientIdentity
  )
import Nagare.Resource.Types (ResourceId, ScopeId)

executorStillClaimed :: LockedStore s -> TransactionId -> IO Bool
executorStillClaimed locked transaction = do
  let store = lockedStore locked
  current <- readHead store
  pure $ case current of
    Right (Just headValue) -> case headExecutorClaim headValue of
      Just claim ->
        claimTransaction claim == transactionIdText transaction
          && claimClientIdentity claim == maybe (headClientIdentity headValue) id (storeClientIdentity store)
      Nothing -> False
    _ -> False

-- Keep the provider generation captured by each authority check for its CAS.
-- The next check still observes afresh; this is not a command-wide head cache.
observeCurrentHead :: InventoryStore -> IO (Either StoreError (ObservedHead, Maybe HeadManifest))
observeCurrentHead store =
  fmap (\observed -> (observed, observedHeadManifest observed)) <$> observeHead store

acquireResumeClaim :: InventoryStore -> TransactionId -> ObservedHead -> HeadManifest -> Bool -> IO (Either (NonEmpty AdmissionError) ())
acquireResumeClaim store transaction observed headValue takeOver = do
  now <- timestamp
  case headExecutorClaim headValue of
    Just claim
      | claimClientIdentity claim /= localClient && not takeOver ->
          pure (failure "executor-claim" "transaction is claimed by a different store client; explicit takeover is required")
    claim -> do
      let epoch = maybe 1 ((+ 1) . claimEpoch) claim
          replacement = headValue {headGeneration = headGeneration headValue + 1, headExecutorClaim = Just (ExecutorClaim (transactionIdText transaction) localClient epoch now)}
      result <- replaceObservedHead observed replacement
      pure $ case result of Left err -> failure "head-condition" (showText err); Right () -> Right ()
  where
    localClient = maybe (headClientIdentity headValue) id (storeClientIdentity store)

releaseClaim :: LockedStore s -> TransactionId -> Maybe ReviewDocument -> IO Bool
releaseClaim locked transaction completedReview = releaseClaimWith locked transaction completedReview Map.empty

-- | Release the claim; a converged review also records the incarnations it
-- established or proved (F49). Retained and collected members drop theirs.
releaseClaimWith :: LockedStore s -> TransactionId -> Maybe ReviewDocument -> Map ResourceId IncarnationBinding -> IO Bool
releaseClaimWith locked transaction completedReview bindings = do
  let converged = isJust completedReview
  let store = lockedStore locked
  headResult <- observeCurrentHead store
  case headResult of
    Right (observed, Just headValue)
      | headActiveTransaction headValue == Just (transactionIdText transaction)
      , maybe True (\client -> maybe False ((== client) . claimClientIdentity) (headExecutorClaim headValue)) (storeClientIdentity store) -> do
          if converged && isJust (headDataFence headValue)
            then pure False
            else do
              let replacement =
                    headValue
                      { headGeneration = headGeneration headValue + 1
                      , headExecutorClaim = Nothing
                      , headActiveTransaction = if converged then Nothing else headActiveTransaction headValue
                      , headConverged =
                          maybe
                            (headConverged headValue)
                            (convergedSelectedScopes (headConverged headValue))
                            completedReview
                      , headIncarnations =
                          if converged
                            then
                              Map.withoutKeys
                                (bindIncarnations bindings (headIncarnations headValue))
                                (Map.keysSet (headRetained headValue) <> Map.keysSet (headCollected headValue))
                            else headIncarnations headValue
                      }
              isRight <$> replaceObservedHead observed replacement
    _ -> pure False

-- A completed review proves only the scopes it changed. An unrelated stopped
-- application may retain accepted ownership without readiness or convergence.
convergedSelectedScopes ::
  Map ScopeId ScopeRevision ->
  ReviewDocument ->
  Map ScopeId ScopeRevision
convergedSelectedScopes previous document =
  Map.union
    changed
    (Map.withoutKeys previous retired)
  where
    desired = reviewDesiredRevisions document
    base = reviewBaseRevisions document
    changed =
      Map.differenceWith
        (\next old -> if next == old then Nothing else Just next)
        desired
        base
    retired = Map.keysSet base `Set.difference` Map.keysSet desired

-- Stopping an incomplete application is neither rollback nor convergence.
-- Keep its admitted ownership (including created retained data) and the prior
-- converged vector. A subsequent review observes these same owned resources.
releaseStoppedApplicationClaim :: LockedStore s -> TransactionId -> IO Bool
releaseStoppedApplicationClaim locked transaction = do
  let store = lockedStore locked
  current <- observeCurrentHead store
  case current of
    Right (observed, Just headValue)
      | headActiveTransaction headValue == Just (transactionIdText transaction)
      , isNothing (headDataFence headValue)
      , maybe
          True
          ( \client ->
              maybe
                False
                ((== client) . claimClientIdentity)
                (headExecutorClaim headValue)
          )
          (storeClientIdentity store) ->
          isRight
            <$> replaceObservedHead
              observed
              headValue
                { headGeneration = headGeneration headValue + 1
                , headExecutorClaim = Nothing
                , headActiveTransaction = Nothing
                }
    _ -> pure False

-- | A proved rollback abandons the reviewed candidate. The accepted map was
-- advanced at admission, so restore the prior converged map as well as
-- clearing the claim. Callers require a review with no other mutating work.
releaseAbortedClaim :: LockedStore s -> TransactionId -> IO Bool
releaseAbortedClaim locked transaction = do
  let store = lockedStore locked
  headResult <- observeCurrentHead store
  case headResult of
    Right (observed, Just headValue)
      | headActiveTransaction headValue == Just (transactionIdText transaction)
      , isNothing (headDataFence headValue)
      , maybe
          True
          ( \client ->
              maybe
                False
                ((== client) . claimClientIdentity)
                (headExecutorClaim headValue)
          )
          (storeClientIdentity store) -> do
          let replacement =
                headValue
                  { headGeneration = headGeneration headValue + 1
                  , headExecutorClaim = Nothing
                  , headActiveTransaction = Nothing
                  , headAccepted = headConverged headValue
                  }
          isRight <$> replaceObservedHead observed replacement
    _ -> pure False
