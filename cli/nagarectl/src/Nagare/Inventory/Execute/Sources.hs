-- | Lifecycle source facts of a converged release (EP-231, EP-232); internal
-- implementation behind Nagare.Inventory.Execute.
--
-- The producers see the converging transaction and, for each member some
-- producer wants that the transaction operated, its native object bytes at
-- the desired scope revision and at the revision converged before this
-- release. Only those members are read, so a transaction no producer cares
-- about reads nothing.
module Nagare.Inventory.Execute.Sources
  ( builtinProducers
  , convergedSourceFacts
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Events.Backup (backupProducer)
import Nagare.Events.Change (changeProducer)
import Nagare.Events.ChangeOutcome (operationActionName)
import Nagare.Events.Deployment (deploymentProducer)
import Nagare.Events.Source (MemberView (..), OperationView (..), ScopeView (..), SourceFacts, SourceInput (..), SourceProducer, assembleFacts)
import Nagare.Events.Subscription (subscriptionProducer)
import Nagare.Inventory.Adapter (PlannedOperation (plannedAction, plannedOperationId, plannedResources))
import Nagare.Inventory.Execute.Types (reviewDocumentDigest)
import Nagare.Inventory.Journal (JournalEvent (eventTransaction), TransactionId)
import Nagare.Inventory.Plan
  ( RetentionProof (retentionOwner)
  , ReviewDocument (reviewActor, reviewBaseRevisions, reviewCollections, reviewDesiredRevisions, reviewOperations, reviewPayloadIdentity, reviewRetentions, reviewSource)
  , ReviewOperation (reviewAdapterIdentity, reviewPlannedOperation, reviewPublicSummary)
  , ReviewedPlan
  , reviewedDocument
  )
import Nagare.Inventory.ScopeMember (decodeScopeMember)
import Nagare.Inventory.Store (HeadManifest (headBinding, headConverged), InventoryStore, ScopeRevision (revisionDigest), objectKeyFor, readObject, scopeKey)
import Nagare.Resource.Inventory (Declaration (Managed), DesiredSpec (..), ScopeDeclaration, scopeBundles, scopeOverrides)
import Nagare.Resource.Types

-- | The producers every converged release runs, whichever command applied
-- or resumed it, ahead of any the registry adds. 'changeProducer' yields one
-- candidate for every converged transaction (EP-276), so every one commits
-- a facts object.
builtinProducers :: [SourceProducer]
builtinProducers = [deploymentProducer, backupProducer, subscriptionProducer, changeProducer]

-- | The facts @producers@ return for a converged release that replaces
-- @headValue@. A member whose earlier bytes cannot be read stops the
-- release, so the transaction stays resumable.
convergedSourceFacts :: InventoryStore -> [SourceProducer] -> TransactionId -> ReviewedPlan -> [JournalEvent] -> HeadManifest -> IO (Either Text (Maybe SourceFacts))
convergedSourceFacts store producers transaction reviewed events headValue = do
  let document = reviewedDocument reviewed
      wanted resource = any (\producer -> (producer ^. #wants) resource) producers
      operated =
        [ (plannedOperationId planned, resource)
        | operation <- reviewOperations document
        , let planned = reviewPlannedOperation operation
        , resource <- NE.toList (plannedResources planned)
        , wanted resource
        ]
      before = headConverged headValue
      keys = concatMap (^. #scopeKeys) producers
      changed = [(owner, revision) | not (null keys), (owner, revision) <- Map.toAscList (reviewDesiredRevisions document), Map.lookup owner before /= Just revision]
  views <- traverse (view (reviewDesiredRevisions document) before) operated
  scopeViews <- traverse (scopeView keys before) changed
  pure $ do
    members <- Map.fromList <$> sequence views
    scopes <- Map.fromList . catMaybes <$> sequence scopeViews
    let input =
          SourceInput
            { context = headBinding headValue ^. #identity
            , transaction
            , review = reviewDocumentDigest document
            , payloadIdentity = reviewPayloadIdentity document
            , baseRevisions = reviewBaseRevisions document
            , desiredRevisions = reviewDesiredRevisions document
            , convergedBefore = before
            , operations =
                Map.fromList
                  [ (plannedOperationId planned, plannedResources planned)
                  | operation <- reviewOperations document
                  , let planned = reviewPlannedOperation operation
                  ]
            , steps =
                [ OperationView
                    { operation = plannedOperationId planned
                    , action = operationActionName (plannedAction planned)
                    , adapter = reviewAdapterIdentity operation
                    , summary = reviewPublicSummary operation
                    , resources = plannedResources planned
                    }
                | operation <- reviewOperations document
                , let planned = reviewPlannedOperation operation
                ]
            , actor = reviewActor document
            , source = reviewSource document
            , retained = Map.map retentionOwner (reviewRetentions document)
            , collected = Map.map retentionOwner (reviewCollections document)
            , journal = [event | event <- events, eventTransaction event == transaction]
            , members
            , scopes
            }
    assembleFacts input producers
  where
    -- A changed scope whose desired overrides hold a key some producer
    -- names, with its overrides converged before; any other is not read
    -- further.
    scopeView keys before (owner, revision) = do
      desired <- declarationAt owner revision
      case desired of
        Left reason -> pure (Left reason)
        Right declaration
          | not (any (`Map.member` scopeOverrides declaration) keys) -> pure (Right Nothing)
          | otherwise -> do
              earlier <- maybe (pure (Right Nothing)) (fmap (fmap Just) . declarationAt owner) (Map.lookup owner before)
              pure (fmap (\previous -> Just (owner, ScopeView revision (scopeOverrides declaration) (scopeOverrides <$> previous))) earlier)
    declarationAt :: ScopeId -> ScopeRevision -> IO (Either Text ScopeDeclaration)
    declarationAt owner revision = do
      loaded <- readObject store (scopeKey (revisionDigest revision))
      pure (first (\err -> "the converged scope " <> scopeIdText owner <> " cannot be read: " <> T.pack (show err)) (loaded >>= decodeScopeMember owner (revisionDigest revision)))
    view desiredRevisions before (operationId, resource) = case ownerOf resource of
      Left reason -> pure (Left reason)
      Right owner -> do
        now' <- maybe (pure (Right Nothing)) (nativeAt owner resource) (Map.lookup owner desiredRevisions)
        earlier <- maybe (pure (Right Nothing)) (nativeAt owner resource) (Map.lookup owner before)
        pure $ do
          desired <- now'
          previous <- earlier
          pure (resource, MemberView owner operationId desired previous)
    -- A member's native object bytes at a scope revision: the reviewed
    -- observation evidence its review published, by the object's digest.
    nativeAt :: ScopeId -> ResourceId -> ScopeRevision -> IO (Either Text (Maybe ByteString))
    nativeAt owner resource revision = do
      loaded <- readObject store (scopeKey (revisionDigest revision))
      case loaded >>= decodeScopeMember owner (revisionDigest revision) of
        Left err -> pure (Left ("the converged scope " <> scopeIdText owner <> " cannot be read: " <> T.pack (show err)))
        Right declaration -> case [spec | bundle <- scopeBundles declaration, Managed member <- bundle ^. #declarations, member ^. #identity == resource, spec <- [member ^. #spec]] of
          NativeObject digest : _ -> do
            bytes <- readObject store (objectKeyFor "native" digest)
            pure $ case bytes of
              Left err -> Left ("the converged native object of " <> resourceIdText resource <> " cannot be read: " <> T.pack (show err))
              Right found -> Right found
          _ -> pure (Right Nothing)

-- | The scope a resource ID names: the part before its first @/@.
ownerOf :: ResourceId -> Either Text ScopeId
ownerOf resource = case T.splitOn ":" (T.takeWhile (/= '/') (resourceIdText resource)) of
  [kind, name] -> case lookup kind [("platform", Platform), ("application", Application), ("standalone", Standalone), ("publication", Publication)] of
    Just scopeKind -> mkScopeId scopeKind name
    Nothing -> Left ("unknown scope kind in " <> resourceIdText resource)
  _ -> Left ("no scope in " <> resourceIdText resource)
