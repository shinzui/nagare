-- | Prepare responsibilities; internal implementation behind Nagare.Inventory.Plan.
module Nagare.Inventory.Plan.Prepare
  ( prepareReview
  , prepareReviewWithPayloadIdentity
  )
where

import Control.Monad (forM)
import Data.Aeson (ToJSON (toJSON))
import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Inventory.Adapter
  ( Adapter (adapterIdentity, adapterPrepare, adapterVersion)
  , AdapterFence (fenceCapability, fenceForOperation)
  , AdapterRegistry
  , OperationAction (OpenMaintenanceSession, RestoreLiveDatabase)
  , PlannedOperation
    ( plannedAction
    , plannedExecutor
    , plannedOperationId
    )
  , PrepareError (..)
  , PreparedNative (preparedNativeBytes, preparedPublicSummary)
  , lookupAdapter
  , lookupAdapterFences
  )
import Nagare.Inventory.DataFence (dataFenceIntentDigest)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Plan.Types
  ( ChangeProposal (..)
  , ReviewBundle (..)
  , ReviewDocument (..)
  , ReviewOperation (..)
  )
import Nagare.Inventory.Store
  ( DataFenceRecord
      ( fenceAffected
      , fenceRecoveryDigest
      , fenceSession
      , fenceTargets
      )
  , HeadManifest (headGeneration, headSequence)
  , StoreSnapshot (storeSnapshotHead)
  )
import Nagare.Resource.Types (digestText, resourceIdText)
import Nagare.Resource.Wire (canonicalValue)

prepareReview :: AdapterRegistry -> StoreSnapshot -> ChangeProposal -> IO (Either (NonEmpty PrepareError) ReviewBundle)
prepareReview = prepareReviewWithPayloadIdentity "operator-cli"

prepareReviewWithPayloadIdentity :: Text -> AdapterRegistry -> StoreSnapshot -> ChangeProposal -> IO (Either (NonEmpty PrepareError) ReviewBundle)
prepareReviewWithPayloadIdentity payloadIdentity registry snapshot proposal = do
  prepared <- traverse prepareOne (proposalOperations proposal)
  let (errors, successes) = partitionEithers prepared
  case errors of
    firstError : rest -> pure (Left (firstError :| rest))
    [] -> do
      let operations = [operation | (operation, _, _) <- successes]
          native =
            Map.fromList
              [ member
              | (_, members, _) <- successes
              , member <- members
              ]
          barriers = [barrier | (_, _, Just barrier) <- successes]
          headValue = storeSnapshotHead snapshot
          document =
            ReviewDocument
              { reviewSchemaVersion = 1
              , reviewContextBinding = proposalBinding proposal
              , reviewHeadGeneration = headGeneration headValue
              , reviewHeadSequence = headSequence headValue
              , reviewBaseRevisions = proposalBase proposal
              , reviewDesiredRevisions = proposalDesired proposal
              , reviewCandidateDigest = proposalCandidateDigest proposal
              , reviewPayloadIdentity = payloadIdentity
              , reviewPolicyVersion =
                  if Map.null (proposalMigrations proposal)
                    then "inventory-policy-v1"
                    else "inventory-policy-v2-migration"
              , reviewOperations = operations
              , reviewBarriers = barriers
              , reviewRetentions = proposalRetentions proposal
              , reviewCollections = proposalCollections proposal
              , reviewAbsences = proposalAbsences proposal
              , reviewMigrations = proposalMigrations proposal
              , reviewRebinds = proposalRebinds proposal
              }
      pure (Right (ReviewBundle document (proposalScopes proposal) native))
  where
    prepareOne operation = case lookupAdapter registry (plannedExecutor operation) of
      Left err -> pure (Left (PrepareRefused (plannedOperationId operation) err))
      Right adapter -> do
        result <- adapterPrepare adapter operation
        case result of
          Left (PreparationBlocked barrier) ->
            pure
              ( Right
                  ( ReviewOperation
                      operation
                      (adapterIdentity adapter)
                      (adapterVersion adapter)
                      Nothing
                      "review barrier"
                      Nothing
                      Nothing
                      Nothing
                  , []
                  , Just barrier
                  )
              )
          Left err -> pure (Left err)
          Right prepared -> do
            captures <- forM
              ( lookupAdapterFences
                  registry
                  (plannedExecutor operation)
              )
              $ \fence -> do
                captured <- fenceForOperation fence operation prepared
                pure $ case captured of
                  Left reason -> Left (PrepareRefused (plannedOperationId operation) reason)
                  Right Nothing -> Right Nothing
                  Right (Just record) -> Right (Just (fenceCapability fence, record))
            let selected = do
                  matches <- mapMaybe id <$> sequence captures
                  case matches of
                    [] -> Right Nothing
                    [single] -> Right (Just single)
                    _ ->
                      Left
                        ( PrepareRefused
                            (plannedOperationId operation)
                            "operation selected multiple data fence capabilities"
                        )
            pure $ do
              selectedFence <- selected
              when
                ( plannedAction operation
                    `elem` [OpenMaintenanceSession, RestoreLiveDatabase]
                    && isNothing selectedFence
                )
                ( Left
                    ( PrepareRefused
                        (plannedOperationId operation)
                        "database data operation requires a reviewed data fence"
                    )
                )
              let bytes = preparedNativeBytes prepared
                  digest = contentDigest bytes
              fenceMember <-
                traverse
                  ( \(_, record) -> do
                      fenceBytes <-
                        first
                          (PrepareRefused (plannedOperationId operation))
                          (canonicalValue (toJSON record))
                      let fenceDigest = dataFenceIntentDigest record
                      unless
                        (contentDigest fenceBytes == fenceDigest)
                        ( Left
                            ( PrepareRefused
                                (plannedOperationId operation)
                                "data fence private member differs from reviewed digest"
                            )
                        )
                      pure (fenceDigest, fenceBytes)
                  )
                  selectedFence
              Right
                ( ReviewOperation
                    operation
                    (adapterIdentity adapter)
                    (adapterVersion adapter)
                    (Just digest)
                    (preparedPublicSummary prepared)
                    (fmap fst selectedFence)
                    (dataFenceIntentDigest . snd <$> selectedFence)
                    (publicFenceSummary . snd <$> selectedFence)
                , (digest, bytes) : maybe [] (: []) fenceMember
                , Nothing
                )

    publicFenceSummary record =
      "data fence: acquire, verify, release; session="
        <> fenceSession record
        <> "; targets="
        <> T.intercalate
          ","
          ( map
              resourceIdText
              (Set.toAscList (fenceTargets record))
          )
        <> "; affected="
        <> T.intercalate
          ","
          ( map
              resourceIdText
              (Set.toAscList (fenceAffected record))
          )
        <> "; recovery-sha256="
        <> digestText (fenceRecoveryDigest record)
        <> "; intent-sha256="
        <> digestText (dataFenceIntentDigest record)
