{-# LANGUAGE OverloadedStrings #-}

-- | @app.deleted@, @app.stopped@ and @app.restarted@ (EP-276): what a
-- converged transaction did to a release subject (an application, a
-- standalone service or a production site) besides deploying it.
--
-- A deletion is a release subject's scope the review retired. A stop and a
-- restart are what @app stop@ and @app restart@ record on the scope:
-- @operational.visibility@ set to @cluster-local@, and a new
-- @operational.restart@ stamp. The producers read those overrides, desired
-- and converged before, and the release log member a deletion retired; no
-- other bytes. A scope with no earlier converged view is neither stopped nor
-- restarted, and a change that also moved the release is only a deployment.
module Nagare.Events.Application
  ( deletionProducer
  , operationalProducer
  , deletionKey
  , stopKey
  , restartKey
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Events.Deployment (deploymentProducer, isReleaseHistory)
import Nagare.Events.Source
import Nagare.Inventory.Journal (TransactionId, transactionIdText)
import Nagare.Resource.Types
import Nagare.Static.Release (extractReleaseLog)

deletionProducer :: SourceProducer
deletionProducer = SourceProducer isReleaseHistory [] deletions

operationalProducer :: SourceProducer
operationalProducer = SourceProducer (const False) [visibilityKey, restartStampKey] operational

visibilityKey, restartStampKey :: Text
visibilityKey = "operational.visibility"
restartStampKey = "operational.restart"

deletionKey, stopKey, restartKey :: TransactionId -> ScopeId -> Either Text SourceKey
deletionKey = keyed "app.deleted"
stopKey = keyed "app.stopped"
restartKey = keyed "app.restarted"

keyed :: Text -> TransactionId -> ScopeId -> Either Text SourceKey
keyed kind transaction scope = mkSourceKey (kind <> ":" <> transactionIdText transaction <> ":" <> scopeIdText scope)

deletions :: SourceInput -> [SourceItem]
deletions input =
  [ PublicCandidate
      EventCandidate
        { key
        , resource = ResourceRef scope Nothing Nothing Nothing
        , occurredAt = Nothing
        , evidence = [Evidence "review" (input ^. #review)]
        , payload =
            AppDeletedPayload
              AppDeletion
                { subject
                , transaction = input ^. #transaction
                , review = input ^. #review
                , scopeRevision = revision
                , retainedMembers = length [() | owner <- Map.elems (input ^. #retained), owner == scope]
                , lastRelease
                }
        }
  | (scope, accepted) <- Map.toAscList (input ^. #baseRevisions)
  , Map.notMember scope (input ^. #desiredRevisions)
  , Just subject <- [releaseSubject scope]
  , Right key <- [deletionKey (input ^. #transaction) scope]
  , let revision = fromMaybe accepted (Map.lookup scope (input ^. #convergedBefore))
        lastRelease =
          listToMaybe
            [ release
            | view <- Map.elems (input ^. #members)
            , view ^. #owner == scope
            , Just bytes <- [view ^. #previous]
            , Right logValue <- [extractReleaseLog bytes]
            , Just release <- [logValue ^. #current]
            ]
  ]
  where
    listToMaybe = \case
      value : _ -> Just value
      [] -> Nothing

operational :: SourceInput -> [SourceItem]
operational input =
  concat
    [ stops <> restarts
    | (scope, view) <- Map.toAscList (input ^. #scopes)
    , Just subject <- [releaseSubject scope]
    , scope `notElem` deployed
    , Just previous <- [view ^. #previous]
    , let desired = view ^. #desired
          candidate key payload =
            PublicCandidate
              EventCandidate
                { key
                , resource = ResourceRef scope Nothing Nothing Nothing
                , occurredAt = Nothing
                , evidence = [Evidence "review" (input ^. #review)]
                , payload
                }
          stops =
            [ candidate key (AppStoppedPayload (AppStop subject (input ^. #transaction) (input ^. #review) (view ^. #revision)))
            | Map.lookup visibilityKey desired == Just "cluster-local"
            , Map.lookup visibilityKey previous /= Just "cluster-local"
            , Right key <- [stopKey (input ^. #transaction) scope]
            ]
          restarts =
            [ candidate key (AppRestartedPayload (AppRestart subject (input ^. #transaction) (input ^. #review) (view ^. #revision) stamp))
            | Just stamp <- [Map.lookup restartStampKey desired]
            , Map.lookup restartStampKey previous /= Just stamp
            , Right key <- [restartKey (input ^. #transaction) scope]
            ]
    ]
  where
    -- The scopes whose release this transaction moved: only a deployment.
    deployed = [candidate ^. #resource . #scope | PublicCandidate candidate <- (deploymentProducer ^. #produce) input]
