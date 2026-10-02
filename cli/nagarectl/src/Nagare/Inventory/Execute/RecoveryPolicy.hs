{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | RecoveryPolicy responsibilities; internal implementation behind Nagare.Inventory.Execute.
module Nagare.Inventory.Execute.RecoveryPolicy
  ( applicationStopMarker
  , databaseRestoreOnlyReview
  , fencedAction
  , recoverableState
  , sameReviewedFence
  , scheduledPruneOnlyReview
  , transactionDigest
  , volumeRestoreOnlyReview
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
  ( OperationAction (CreateResource, RunDeclaredOperation)
  , PlannedOperation (plannedAction, plannedResources)
  )
import Nagare.Inventory.Execute.Types (RecoveryAction (..))
import Nagare.Inventory.Journal
  ( FailureClass (PartialOrUnknown)
  , OperationState
    ( Ambiguous
    , Failed
    , IntentRecorded
    , OperatorResolved
    )
  , TransactionId
  , transactionIdText
  )
import Nagare.Inventory.OperationStep (bootstrapRecoveryMarker)
import Nagare.Inventory.Plan
  ( ReviewBundle
  , ReviewDocument (reviewOperations)
  , ReviewOperation (reviewPlannedOperation)
  , reviewBundleDocument
  , reviewBundleScopes
  )
import Nagare.Inventory.Store
  ( DataFenceRecord (fenceAcquiredAt, fencePhase, fenceTransaction)
  )
import Nagare.Resource.Inventory qualified as Resource
import Nagare.Resource.Types
  ( ContentDigest
  , mkContentDigest
  , resourceIdText
  )
import Nagare.Resource.Wire (decodeScope)

applicationStopMarker :: Text -> Maybe ContentDigest
applicationStopMarker marker = do
  token <- T.stripPrefix "stopped-incomplete-application:" marker
  either (const Nothing) Just (mkContentDigest token)

scheduledPruneOnlyReview :: ReviewBundle -> PlannedOperation -> Bool
scheduledPruneOnlyReview published operation =
  let reviewed = reviewOperations (reviewBundleDocument published)
      resource = NE.toList (plannedResources operation)
      actions = map (plannedAction . reviewPlannedOperation) reviewed
      oneResource = case resource of
        [selected] ->
          all
            ( \entry ->
                NE.toList
                  (plannedResources (reviewPlannedOperation entry))
                  == [selected]
            )
            reviewed
        _ -> False
      scopes =
        mapMaybe
          (either (const Nothing) Just . decodeScope)
          (Map.elems (reviewBundleScopes published))
      owns selected scope =
        any
          ( \bundle ->
              any
                ( \case
                    Resource.Managed member -> member ^. #identity == selected
                    _ -> False
                )
                (Resource.declarations bundle)
          )
          (Resource.scopeBundles scope)
      selectedScope = case resource of
        [selected] -> [scope | scope <- scopes, owns selected scope]
        _ -> []
   in plannedAction operation `elem` [CreateResource, RunDeclaredOperation]
        && length reviewed == 2
        && Set.fromList actions == Set.fromList [CreateResource, RunDeclaredOperation]
        && oneResource
        && case selectedScope of
          [scope] ->
            Map.member
              "scheduled.prune.backup.scope"
              (Resource.scopeOverrides scope)
          _ -> False

volumeRestoreOnlyReview :: ReviewBundle -> PlannedOperation -> Bool
volumeRestoreOnlyReview published operation =
  let reviewed =
        map
          reviewPlannedOperation
          (reviewOperations (reviewBundleDocument published))
      selected = NE.toList (plannedResources operation)
      scopes =
        mapMaybe
          (either (const Nothing) Just . decodeScope)
          (Map.elems (reviewBundleScopes published))
      owns member scope =
        any
          ( \bundle ->
              any
                ( \case
                    Resource.Managed resource -> resource ^. #identity == member
                    _ -> False
                )
                (Resource.declarations bundle)
          )
          (Resource.scopeBundles scope)
   in case selected of
        [job] ->
          let restoreScopes =
                [ scope
                | scope <- scopes
                , owns job scope
                , all
                    (\key -> Map.member key (Resource.scopeOverrides scope))
                    [ "volume-restore.id"
                    , "volume-restore.backup.job.uid"
                    , "volume-restore.target.pvc.uid"
                    , "volume-restore.scratch"
                    ]
                ]
              sameScope scope entry =
                all
                  (`owns` scope)
                  (NE.toList (plannedResources entry))
              actions = map plannedAction reviewed
              created =
                [ member
                | entry <- reviewed
                , plannedAction entry == CreateResource
                , member <- NE.toList (plannedResources entry)
                ]
           in case (restoreScopes, created) of
                ([scope], [firstCreated, secondCreated]) ->
                  let managed =
                        [ resource ^. #identity
                        | bundle <- Resource.scopeBundles scope
                        , Resource.Managed resource <- Resource.declarations bundle
                        ]
                   in plannedAction operation `elem` [CreateResource, RunDeclaredOperation]
                        && length reviewed == 3
                        && length (filter (== CreateResource) actions) == 2
                        && length (filter (== RunDeclaredOperation) actions) == 1
                        && job `elem` created
                        && T.isSuffixOf "/job" (resourceIdText job)
                        && any (T.isSuffixOf "/pvc" . resourceIdText) created
                        && firstCreated /= secondCreated
                        && length managed == 2
                        && Set.fromList managed == Set.fromList created
                        && all (sameScope scope) reviewed
                _ -> False
        _ -> False

databaseRestoreOnlyReview :: ReviewBundle -> PlannedOperation -> Bool
databaseRestoreOnlyReview published operation =
  let reviewed =
        map
          reviewPlannedOperation
          (reviewOperations (reviewBundleDocument published))
      selected = NE.toList (plannedResources operation)
      scopes =
        mapMaybe
          (either (const Nothing) Just . decodeScope)
          (Map.elems (reviewBundleScopes published))
      owns member scope =
        any
          ( \bundle ->
              any
                ( \case
                    Resource.Managed resource -> resource ^. #identity == member
                    _ -> False
                )
                (Resource.declarations bundle)
          )
          (Resource.scopeBundles scope)
   in case selected of
        [job] ->
          let restoreScopes =
                [ scope
                | scope <- scopes
                , owns job scope
                , all
                    (\key -> Map.member key (Resource.scopeOverrides scope))
                    [ "restore.id"
                    , "restore.target.database"
                    , "restore.backup.scope"
                    , "restore.target.statefulset.uid"
                    , "restore.target.pvc.uid"
                    ]
                ]
              sameJob entry = NE.toList (plannedResources entry) == [job]
              actions = map plannedAction reviewed
           in case restoreScopes of
                [scope] ->
                  let managed =
                        [ resource ^. #identity
                        | bundle <- Resource.scopeBundles scope
                        , Resource.Managed resource <- Resource.declarations bundle
                        ]
                   in plannedAction operation `elem` [CreateResource, RunDeclaredOperation]
                        && length reviewed == 2
                        && Set.fromList actions
                          == Set.fromList
                            [CreateResource, RunDeclaredOperation]
                        && T.isSuffixOf "/job" (resourceIdText job)
                        && managed == [job]
                        && all sameJob reviewed
                _ -> False
        _ -> False

fencedAction :: RecoveryAction -> Bool
fencedAction action =
  action
    `elem` [ ContinueFencedOperation
           , VerifyFencedEffect
           , RecoverFencedBackup
           , ForwardFencedRelease
           ]

sameReviewedFence :: TransactionId -> DataFenceRecord -> DataFenceRecord -> Bool
sameReviewedFence selectedTransaction saved active =
  fenceTransaction active == Just (transactionIdText selectedTransaction)
    && active
      { fenceTransaction = Nothing
      , fencePhase = fencePhase saved
      , fenceAcquiredAt = fenceAcquiredAt saved
      }
      == saved

recoverableState :: Maybe OperationState -> Bool
recoverableState state = case state of
  Just IntentRecorded -> True
  Just Ambiguous -> True
  Just (Failed (PartialOrUnknown _)) -> True
  Just (OperatorResolved marker) ->
    "fenced-recovery-proved:" `T.isPrefixOf` marker
      || isJust (bootstrapRecoveryMarker marker)
      || isJust (applicationStopMarker marker)
  _ -> False

transactionDigest :: TransactionId -> Maybe ContentDigest
transactionDigest token =
  either
    (const Nothing)
    Just
    (mkContentDigest (T.drop 3 (transactionIdText token)))
