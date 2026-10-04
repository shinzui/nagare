{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Accepted incarnations of durable members (F49). The physical identity of a
-- durable Kubernetes member is recorded when the review that created, adopted,
-- updated or verified it converges, so that status and receipt ingestion can
-- tell a same-name replacement made outside Nagare from the accepted object.
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
  | -- | Nagare updated or verified this object; bind it only if nothing is recorded.
    Proved !PhysicalIdentity
  deriving stock (Eq, Show)

-- | Observe the data-bearing Kubernetes members a converging review touched:
-- durable members (a database's PVC and credential) and StatefulSets, the
-- controllers that own that data. An unavailable observation records nothing;
-- it never blocks convergence, so a later update or verification may be the
-- first to bind that member.
convergedIncarnations :: LockedStore s -> AdapterRegistry -> ReviewDocument -> IO (Map ResourceId IncarnationBinding)
convergedIncarnations locked registry document = do
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
      touched =
        Map.fromListWith
          max
          [ (resource, establishes (plannedAction planned))
          | reviewOperation <- reviewOperations document
          , let planned = reviewPlannedOperation reviewOperation
          , plannedExecutor planned == KubernetesExecutor
          , plannedAction planned `elem` [CreateResource, AdoptResource, UpdateResource, VerifyResource]
          , resource <- NE.toList (plannedResources planned)
          , Set.member resource durable
          ]
  case lookupAdapter registry KubernetesExecutor of
    Left _ -> pure Map.empty
    Right adapter
      | Map.null touched -> pure Map.empty
      | otherwise -> do
          observed <- adapterObserve adapter (Map.keys touched)
          pure $ case observed of
            Left _ -> Map.empty
            Right facts ->
              Map.fromList
                [ (resource, if established then Established physical else Proved physical)
                | (resource, established) <- Map.toList touched
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
    establishes action = action `elem` [CreateResource, AdoptResource]
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
