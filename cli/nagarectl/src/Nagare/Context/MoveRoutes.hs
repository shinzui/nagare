-- | The route half of EP-246 D5. A site redeployed from its config on the new base declares its new
-- names, and a grant binds to the exact accepted protected route of its host (ADR 29), so a redeploy
-- that dropped an old protected route would orphan its grants. While a base move is open, or the
-- context still keeps its old base, the redeployed scope carries every accepted protected route an
-- accepted grant still names: the same DomainMapping and the same backend registration, unchanged.
-- Only retirement, which revokes and then retires those grants, lets a later deploy drop them.
module Nagare.Context.MoveRoutes
  ( carryGrantedRoutes
  , grantedHosts
  )
where

import Data.Generics.Labels ()
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Types

-- | Hosts an accepted direct or team grant names, present or revoked: either binds its route.
grantedHosts :: [Declaration] -> Set.Set Name
grantedHosts declarations =
  Set.fromList
    ( [host | Managed r <- declarations, AccessTuple _ host _ <- [r ^. #address]]
        <> [host | Managed r <- declarations, TeamAccessTuple _ host _ <- [r ^. #address]]
    )

-- | The redeployed scope with each accepted protected route it dropped and a grant still names.
carryGrantedRoutes :: Set.Set Name -> Maybe ScopeDeclaration -> ScopeDeclaration -> Either Text ScopeDeclaration
carryGrantedRoutes granted accepted redeployed = case accepted of
  Nothing -> Right redeployed
  Just before
    | null carried -> Right redeployed
    | otherwise ->
        first
          (T.pack . show)
          ( withScopeOverrides (scopeOverrides redeployed)
              . maybe id withScopeConfigDigest (scopeConfigDigest redeployed)
              <$> mkScopeDeclaration (scopeId redeployed) (scopeBundles redeployed <> carried)
          )
    where
      kept = registeredHosts redeployed
      carried =
        [ ResourceBundle
            [Managed m | m <- mappings before, isMappingOf (m ^. #address) host]
            []
            []
            [c | c <- contributions before, backendHost c == Just host]
            []
            []
        | host <- Set.toList (registeredHosts before)
        , host `Set.member` granted
        , host `Set.notMember` kept
        ]
  where
    contributions scope = concatMap (^. #contributions) (scopeBundles scope)
    mappings scope = [m | bundle <- scopeBundles scope, Managed m <- bundle ^. #declarations, isMapping (m ^. #address)]
    registeredHosts scope = Set.fromList [h | Just h <- map backendHost (contributions scope)]
    backendHost = \case
      RegisterBackend {host = h} -> Just h
      _ -> Nothing
    isMapping = \case
      Kubernetes _ "serving.knative.dev" kind _ _ -> nameText kind == "domainmapping"
      _ -> False
    isMappingOf address host = case address of
      Kubernetes _ "serving.knative.dev" kind _ name -> nameText kind == "domainmapping" && name == host
      _ -> False
