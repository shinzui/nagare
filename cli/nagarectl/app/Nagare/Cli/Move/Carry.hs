-- | EP-246 D5 at deploy time: while a base move is open, the context still keeps its old base, or it
-- keeps the zone of a rolled-back move, a redeployed site keeps the routes it dropped, with the native
-- bytes of each carried route ('Nagare.Context.MoveCarry'). Every other context plans its scope unchanged.
module Nagare.Cli.Move.Carry (withMovedRoutes, withGrantedMovedRoutes) where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Context.BaseFlip (baseMoveKind)
import Nagare.Context.MoveCarry (carryWithAcceptedRoutesWhere)
import Nagare.Context.MoveRoutes (grantedHosts, otherBase)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command (openTargetStoreReadOnly)
import Nagare.Inventory.Store (HeadManifest (..), readHead)
import Nagare.Inventory.Store.Manifest (MoveMarker (..))
import Nagare.Resource.Inventory (ManagedResource, ScopeDeclaration, ScopeSnapshot, snapshotScopes)
import Nagare.Resource.Types (Name, ResourceId)
import Nagare.Target (ActiveTarget, Mode (Local))

-- | The scope with its carried routes, and its native members with the carried routes' bytes.
withMovedRoutes ::
  ActiveTarget ->
  ScopeSnapshot ->
  (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)) ->
  IO (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
withMovedRoutes = withMovedRoutesWhere (const True)

-- | The platform's admin API keeps an old route only while an accepted grant names it: once a base's
-- retirement retired its grants, a platform review drops it and retires it by decision.
withGrantedMovedRoutes ::
  ActiveTarget ->
  ScopeSnapshot ->
  (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)) ->
  IO (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
withGrantedMovedRoutes active snapshot = withMovedRoutesWhere (`Set.member` grantedHosts (map snd (Map.elems (snapshotScopes snapshot)))) active snapshot

withMovedRoutesWhere ::
  (Name -> Bool) ->
  ActiveTarget ->
  ScopeSnapshot ->
  (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)) ->
  IO (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
withMovedRoutesWhere keep active snapshot (scope, native) = do
  other <- carriedBase active snapshot
  case other of
    Nothing -> pure (scope, native)
    Just base -> do
      store <- openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
      carryWithAcceptedRoutesWhere keep base store snapshot (scope, native) >>= either dieT pure

-- | The other base whose routes a redeploy carries ('otherBase'); none for a local context.
carriedBase :: ActiveTarget -> ScopeSnapshot -> IO (Maybe Text)
carriedBase active snapshot
  | profile ^. #mode == Local = pure Nothing
  | otherwise = do
      store <- openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
      marker <- readHead store >>= either (dieT . T.pack . show) (pure . (>>= headMove))
      let move = [(moveRetainedDnsName m, moveTargetBase m) | Just m <- [marker], moveKind m == baseMoveKind]
      pure (otherBase (profile ^. #baseDomain) (profile ^. #retainedDnsName) (listToMaybe move) (map snd (Map.elems (snapshotScopes snapshot))))
  where
    profile = active ^. #profile
