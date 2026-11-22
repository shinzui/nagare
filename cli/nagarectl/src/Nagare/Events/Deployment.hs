{-# LANGUAGE OverloadedStrings #-}

-- | @app.deployed@ (EP-232): one event per production release subject whose
-- release this converged transaction established.
--
-- A release subject (an application, a standalone service or a production
-- site) keeps its release log in one release-history member. The event's
-- subject is the release its desired log makes current; it is announced only
-- when that differs from the release current at the scope's revision
-- converged before this transaction. So a verification-only rerun, a
-- provenance refresh that leaves the release alone, a preview (which has no
-- release log) and an image publication announce nothing, while a
-- transaction that first establishes a release an earlier stopped one had
-- already accepted does. A rollback is a log whose records are unchanged and
-- whose current release moved, which is what a reviewed rollback
-- ('SelectRelease') compiles to; a deploy adds or refreshes a record.
module Nagare.Events.Deployment
  ( deploymentProducer
  , isReleaseHistory
  , deploymentKey
  , subjectOf
  )
where

import Data.Aeson (toJSON)
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Events.Source
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (JournalEvent (eventOperation, eventState, eventTimestamp, eventTransaction), OperationState (Completed), TransactionId, operationIdText, transactionIdText)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Static.Release (StaticReleaseLog, extractReleaseLog)

deploymentProducer :: SourceProducer
deploymentProducer = SourceProducer isReleaseHistory [] deployments

-- | A release log member: @SCOPE/APP/release-history@ for an application
-- or a standalone service, @SCOPE/release-history/configmap@ for a site.
isReleaseHistory :: ResourceId -> Bool
isReleaseHistory resource = case T.splitOn "/" (resourceIdText resource) of
  [_, key, role] -> role == "release-history" || key == "release-history"
  _ -> False

-- | The source key of a subject's deployment in a transaction: stable
-- across resumes, distinct for a later deployment of the same release.
deploymentKey :: TransactionId -> ScopeId -> Either Text SourceKey
deploymentKey transaction scope = mkSourceKey ("app.deployed:" <> transactionIdText transaction <> ":" <> scopeIdText scope)

deployments :: SourceInput -> [SourceItem]
deployments input =
  [ PublicCandidate candidate
  | (resource, view) <- Map.toAscList (input ^. #members)
  , Just subject <- [subjectOf (view ^. #owner)]
  , Just desiredBytes <- [view ^. #desired]
  , Right desiredLog <- [extractReleaseLog desiredBytes]
  , Just release <- [desiredLog ^. #current]
  , let previousLog = either (const Nothing) Just . extractReleaseLog =<< (view ^. #previous)
        previousRelease = previousLog >>= (^. #current)
  , previousRelease /= Just release
  , Just revision <- [Map.lookup (view ^. #owner) (input ^. #desiredRevisions)]
  , Right key <- [deploymentKey (input ^. #transaction) (view ^. #owner)]
  , let namespace = listToMaybe [record ^. #namespace | record <- desiredLog ^. #releases, record ^. #releaseId == release]
        readiness = readinessProof input (view ^. #owner)
        candidate =
          EventCandidate
            { key
            , resource = ResourceRef (view ^. #owner) (Just resource) namespace Nothing
            , occurredAt = Nothing
            , evidence =
                [ Evidence "review" (input ^. #review)
                , Evidence "readiness" readiness
                , Evidence "release-history" (contentDigest desiredBytes)
                ]
            , payload =
                AppDeployedPayload
                  AppDeployment
                    { subject
                    , action = if isRollback previousLog desiredLog then RollbackAction else DeployAction
                    , release
                    , previousRelease
                    , scopeRevision = revision
                    , transaction = input ^. #transaction
                    , review = input ^. #review
                    , readiness
                    }
            }
  ]
  where
    listToMaybe = \case
      value : _ -> Just value
      [] -> Nothing

-- | Which release subject a scope is, if any. Site previews and the
-- environment and hook scopes hold no release log, so they never reach here;
-- a preview is refused by name as well.
subjectOf :: ScopeId -> Maybe DeploymentSubject
subjectOf scope = case T.breakOn ":" (scopeIdText scope) of
  ("application", _) -> Just ApplicationSubject
  ("standalone", rest)
    | "site-preview-" `T.isPrefixOf` T.drop 1 rest -> Nothing
    | "site-" `T.isPrefixOf` T.drop 1 rest -> Just SiteSubject
    | "service-" `T.isPrefixOf` T.drop 1 rest -> Just ServiceSubject
  _ -> Nothing

-- | A rollback re-selects a recorded release: the records are those the
-- converged log had, and only the current release moved.
isRollback :: Maybe StaticReleaseLog -> StaticReleaseLog -> Bool
isRollback previous desired = case previous of
  Just earlier -> earlier ^. #releases == desired ^. #releases && earlier ^. #current /= desired ^. #current
  Nothing -> False

-- | A digest over the completion proofs of this transaction's operations on
-- the scope: the readiness every workload and hook proved.
readinessProof :: SourceInput -> ScopeId -> ContentDigest
readinessProof input scope =
  contentDigest . either (error . T.unpack) id . canonicalValue . toJSON $
    sortOn
      fst
      [ (operationIdText operation, digestText proof)
      | event <- input ^. #journal
      , eventTransaction event == input ^. #transaction
      , Just operation <- [eventOperation event]
      , Completed proof <- [eventState event]
      , Just resources <- [Map.lookup operation (input ^. #operations)]
      , any (\resource -> (scopeIdText scope <> "/") `T.isPrefixOf` resourceIdText resource) resources
      ]
