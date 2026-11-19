-- | EP-246 D5's carrier with its inputs read from the store: the accepted bytes of the routes a
-- redeployed scope drops, through the loader every review uses ('Nagare.Context.MoveRoutes').
module Nagare.Context.MoveCarry
  ( carryWithAcceptedRoutes
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Context.MoveRoutes (carryOldRoutes, routesToCarry)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Plan (loadInventoryHistory)
import Nagare.Inventory.Status (loadAcceptedNativeSelected)
import Nagare.Inventory.Store (InventoryStore)
import Nagare.Resource.Inventory (ManagedResource, ScopeDeclaration, ScopeSnapshot, composeSnapshot, scopeId, snapshotScopes)
import Nagare.Resource.Types (ResourceId)

-- | The redeployed scope with the accepted routes it dropped, and its native members with theirs.
carryWithAcceptedRoutes ::
  InventoryStore ->
  ScopeSnapshot ->
  (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)) ->
  IO (Either Text (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)))
carryWithAcceptedRoutes store snapshot (scope, native)
  | Set.null wanted = pure (Right (scope, native))
  | otherwise = do
      history <- loadInventoryHistory store
      case (,) <$> first (T.pack . show) history <*> first (T.pack . show) (composeSnapshot snapshot) of
        Left reason -> pure (Left reason)
        Right (loaded, inventory) -> do
          acceptedNative <- loadAcceptedNativeSelected wanted store loaded inventory
          pure $ do
            (routes, _) <- acceptedNative
            (carried, carriedNative) <- carryOldRoutes (Map.map snd routes) accepted scope
            pure (carried, Map.union carriedNative native)
  where
    accepted = snd <$> Map.lookup (scopeId scope) (snapshotScopes snapshot)
    wanted = routesToCarry accepted scope
