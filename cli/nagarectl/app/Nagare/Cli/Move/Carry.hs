-- | EP-246 D5 at deploy time: while a base move is open, or the context still keeps its old base, a
-- redeployed site keeps the protected routes it dropped ('Nagare.Context.MoveRoutes'), with the
-- native bytes of each carried route. Every other context plans its scope unchanged.
module Nagare.Cli.Move.Carry (withMovedRoutes) where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Context.BaseFlip (baseMoveKind)
import Nagare.Context.MoveRoutes (carryOldRoutes, routesToCarry)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command (openTargetStoreReadOnly)
import Nagare.Inventory.Plan qualified as Plan
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store (HeadManifest (..), readHead)
import Nagare.Inventory.Store.Manifest (MoveMarker (..))
import Nagare.Resource.Inventory (ManagedResource, ScopeDeclaration, ScopeSnapshot, composeSnapshot, scopeId, snapshotScopes)
import Nagare.Resource.Types (ResourceId)
import Nagare.Target (ActiveTarget, Mode (Local))

-- | The scope with its carried routes, and its native members with the carried routes' bytes.
withMovedRoutes ::
  ActiveTarget ->
  ScopeSnapshot ->
  (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)) ->
  IO (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
withMovedRoutes active snapshot (scope, native) = do
  carrying <- baseMoveCarrying active
  let accepted = snd <$> Map.lookup (scopeId scope) (snapshotScopes snapshot)
      wanted = routesToCarry accepted scope
  if not carrying || Set.null wanted
    then pure (scope, native)
    else do
      store <- openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
      history <- Plan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
      inventory <- either (dieT . T.pack . show) pure (composeSnapshot snapshot)
      (acceptedNative, _) <- Status.loadAcceptedNativeSelected wanted store history inventory >>= either dieT pure
      (carried, routes) <- either dieT pure (carryOldRoutes (Map.map snd acceptedNative) accepted scope)
      pure (carried, Map.union routes native)

baseMoveCarrying :: ActiveTarget -> IO Bool
baseMoveCarrying active
  | profile ^. #mode == Local = pure False
  | not (T.null retained) && retained /= profile ^. #baseDomain = pure True
  | otherwise = do
      store <- openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
      marker <- readHead store >>= either (dieT . T.pack . show) (pure . (>>= headMove))
      pure (maybe False ((== baseMoveKind) . moveKind) marker)
  where
    profile = active ^. #profile
    retained = profile ^. #retainedDnsName
