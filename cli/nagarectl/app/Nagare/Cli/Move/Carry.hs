-- | EP-246 D5 at deploy time: while a base move is open, or the context still keeps its old base, a
-- redeployed site keeps the protected routes its accepted grants still name
-- ('Nagare.Context.MoveRoutes'). Every other context plans its scope unchanged.
module Nagare.Cli.Move.Carry (withMovedRoutes) where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Context.BaseFlip (baseMoveKind)
import Nagare.Context.MoveRoutes (carryOldRoutes)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command (openTargetStoreReadOnly)
import Nagare.Inventory.Store (HeadManifest (..), readHead)
import Nagare.Inventory.Store.Manifest (MoveMarker (..))
import Nagare.Resource.Inventory (ScopeDeclaration, ScopeSnapshot, scopeId, snapshotScopes)
import Nagare.Target (ActiveTarget, Mode (Local))

withMovedRoutes :: ActiveTarget -> ScopeSnapshot -> ScopeDeclaration -> IO ScopeDeclaration
withMovedRoutes active snapshot scope = do
  carrying <- baseMoveCarrying active
  if not carrying
    then pure scope
    else do
      let accepted = snd <$> Map.lookup (scopeId scope) (snapshotScopes snapshot)
      either dieT pure (carryOldRoutes accepted scope)

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
