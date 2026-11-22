{-# LANGUAGE OverloadedStrings #-}

-- | @change.applied@ (EP-276): one event for every converged reviewed
-- transaction, whatever it changed.
--
-- A scope is changed when its desired declaration differs from the one
-- converged before this release (a review that accepts the same
-- declaration again moves only its generation, and changes nothing), or
-- when the review retires it (it is in the review's base and not in its
-- desired revisions, the rule the release itself applies). The event is about the single changed scope; when
-- several changed, about the single changed release subject, so a deploy
-- that also moves a publication scope is about its application; otherwise,
-- and when nothing changed, about @platform:context@. The producer reads no
-- member bytes and no scope, so it cannot fail on any review.
module Nagare.Events.Change
  ( changeProducer
  , changeKey
  , changedScopes
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Events.Source
import Nagare.Inventory.Journal (TransactionId, transactionIdText)
import Nagare.Inventory.Store (ScopeRevision (revisionDigest))
import Nagare.Resource.Types

changeProducer :: SourceProducer
changeProducer = sourceProducer applied

-- | One key per transaction: a resumed or retried release names it again.
changeKey :: TransactionId -> Either Text SourceKey
changeKey transaction = mkSourceKey ("change.applied:" <> transactionIdText transaction)

applied :: SourceInput -> [SourceItem]
applied input = case changeKey (input ^. #transaction) of
  Left _ -> []
  Right key ->
    [ PublicCandidate
        EventCandidate
          { key
          , resource = ResourceRef (primaryScope changes) Nothing Nothing Nothing
          , occurredAt = Nothing
          , evidence = [Evidence "review" (input ^. #review)]
          , payload =
              ChangeAppliedPayload
                ChangeApplication
                  { transaction = input ^. #transaction
                  , review = input ^. #review
                  , actor = input ^. #actor
                  , source = changeSource (input ^. #source)
                  , scopes = changes
                  , operations =
                      [ ActionCount action count
                      | (action, count) <- Map.toAscList (Map.fromListWith (+) [(step ^. #action, 1) | step <- input ^. #steps])
                      ]
                  }
          }
    ]
  where
    changes = changedScopes input

-- | The scopes a converged transaction changed, in scope order.
changedScopes :: SourceInput -> [ScopeChange]
changedScopes input =
  Map.elems
    ( Map.union
        ( Map.fromList
            [ (scope, ScopeChange scope (if isJust before then ScopeUpdated else ScopeCreated) before (Just revision))
            | (scope, revision) <- Map.toAscList desired
            , let before = Map.lookup scope converged
            , fmap revisionDigest before /= Just (revisionDigest revision)
            ]
        )
        ( Map.fromList
            [ (scope, ScopeChange scope ScopeRetired (Map.lookup scope converged <|> Just accepted) Nothing)
            | (scope, accepted) <- Map.toAscList (input ^. #baseRevisions)
            , Map.notMember scope desired
            ]
        )
    )
  where
    desired = input ^. #desiredRevisions
    converged = input ^. #convergedBefore

primaryScope :: [ScopeChange] -> ScopeId
primaryScope = primaryScopeOf . map (^. #scope)
