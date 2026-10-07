-- | Accepted incarnations (F49, ADR 27). A Kubernetes member's record is the
-- identity the API server returned for the review's own write, read from the
-- journal; it is never taken from a later observation, so a replacement made
-- between a write and convergence is not laundered into the record (F60).
module Nagare.Inventory.Execute.Incarnations
  ( IncarnationBinding (..)
  , bindIncarnations
  , convergedIncarnations
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (JournalEvent (eventOperation, eventPhysical, eventTransaction), TransactionId)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
  ( LockedStore
  , ScopeRevision (revisionDigest)
  , lockedStore
  , readObject
  , scopeKey
  )
import Nagare.Resource.Inventory (Declaration (Managed), Executor (KubernetesExecutor), ScopeDeclaration, declarations, scopeBundles)
import Nagare.Resource.Policy (DataPolicy (Durable))
import Nagare.Resource.Types (PhysicalIdentity, ProviderAddress (Kubernetes), ResourceId, nameText)
import Nagare.Resource.Wire (decodeScope)

-- | How a converging review established a member's current object.
data IncarnationBinding
  = -- | Nagare created or adopted this object, so it is the accepted incarnation.
    Established !PhysicalIdentity
  | -- | Nagare updated this object; bind it only if nothing is recorded.
    Proved !PhysicalIdentity
  deriving stock (Eq, Show)

-- | Bind every Kubernetes member a converging review created, adopted or
-- updated to the identity its write returned. A verification writes nothing
-- and binds nothing, and a write whose response was lost leaves its member
-- unrecorded. A reviewed migration's destination (F52) is its new object:
-- bound from its write when the write returned one, otherwise from a
-- convergence observation, since a transfer Job writes data, not the object.
convergedIncarnations :: LockedStore s -> AdapterRegistry -> TransactionId -> [JournalEvent] -> ReviewDocument -> IO (Map ResourceId IncarnationBinding)
convergedIncarnations locked registry transaction events document = do
  migrated <- migrationDestinations locked registry document
  pure (Map.union written migrated)
  where
    -- The latest identity each operation's events carry.
    returned =
      Map.fromList
        [ (operation, physical)
        | event <- events
        , eventTransaction event == transaction
        , Just operation <- [eventOperation event]
        , Just physical <- [eventPhysical event]
        ]
    written =
      Map.fromList
        [ (resource, if plannedAction planned == UpdateResource then Proved physical else Established physical)
        | reviewOperation <- reviewOperations document
        , let planned = reviewPlannedOperation reviewOperation
        , plannedExecutor planned == KubernetesExecutor
        , plannedAction planned `elem` [CreateResource, AdoptResource, UpdateResource] || migrates (plannedAction planned)
        , [resource] <- [NE.toList (plannedResources planned)]
        , Just physical <- [Map.lookup (plannedOperationId planned) returned]
        ]

migrates :: OperationAction -> Bool
migrates (MigrateResource _) = True
migrates _ = False

migrationDestinations :: LockedStore s -> AdapterRegistry -> ReviewDocument -> IO (Map ResourceId IncarnationBinding)
migrationDestinations locked registry document = do
  scopes <- traverse loadScope (Map.elems (reviewDesiredRevisions document))
  let durable =
        Set.fromList
          [ member ^. #identity
          | Right scope <- scopes
          , bundle <- scopeBundles scope
          , Managed member <- declarations bundle
          , member ^. #executor == KubernetesExecutor
          , isDurable (member ^. #dataPolicy) || isStatefulSet (member ^. #address)
          ]
      -- Each member once: a migration has several stages per member, and an
      -- observation refuses a repeated resource.
      touched =
        Set.toList . Set.fromList $
          [ resource
          | reviewOperation <- reviewOperations document
          , let planned = reviewPlannedOperation reviewOperation
          , plannedExecutor planned == KubernetesExecutor
          , migrates (plannedAction planned)
          , resource <- NE.toList (plannedResources planned)
          , Set.member resource durable
          ]
  case lookupAdapter registry KubernetesExecutor of
    Left _ -> pure Map.empty
    Right adapter
      | null touched -> pure Map.empty
      | otherwise -> do
          observed <- adapterObserve adapter touched
          pure $ case observed of
            Left _ -> Map.empty
            Right facts ->
              Map.fromList
                [ (resource, Established physical)
                | resource <- touched
                , Just physical <- [present =<< Map.lookup resource (observationMap facts)]
                ]
  where
    loadScope :: ScopeRevision -> IO (Either Text ScopeDeclaration)
    loadScope revision = do
      result <- readObject (lockedStore locked) (scopeKey (revisionDigest revision))
      pure $ do
        bytes <- first showText result >>= maybe (Left "missing desired scope") Right
        if contentDigest bytes /= revisionDigest revision
          then Left "desired scope digest mismatch"
          else first showText (decodeScope bytes)
    isDurable (Durable _) = True
    isDurable _ = False
    isStatefulSet (Kubernetes _ "apps" kind _ _) = nameText kind == "statefulset"
    isStatefulSet _ = False
    present (ObservedPresent physical) = Just physical
    present (ObservedDrifted physical _) = Just physical
    present _ = Nothing
    showText :: (Show a) => a -> Text
    showText = T.pack . show

-- | Fold a converged review's bindings into the recorded incarnations. An
-- established object replaces the record; a proved one is recorded only when
-- no incarnation is known, so a later review never launders an out-of-band
-- replacement into the accepted record.
bindIncarnations :: Map ResourceId IncarnationBinding -> Map ResourceId PhysicalIdentity -> Map ResourceId PhysicalIdentity
bindIncarnations bindings recorded = Map.foldrWithKey bind recorded bindings
  where
    bind resource (Established physical) = Map.insert resource physical
    bind resource (Proved physical) = Map.insertWith (\_ old -> old) resource physical
