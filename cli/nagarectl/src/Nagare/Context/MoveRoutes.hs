-- | The route half of EP-246 D5. A site redeployed from its config on the new base declares its new
-- names, and a grant binds to the exact accepted protected route of its host (ADR 29), so a redeploy
-- that dropped an old protected route would orphan its grants. While a base move is open, or the
-- context still keeps its old base, the redeployed scope carries every accepted route it dropped,
-- granted or not (the auth portal's has no grant): the same DomainMapping and the same backend
-- registration, unchanged. Only retirement, which revokes and retires the grants and then the routes,
-- lets a later deploy drop them.
module Nagare.Context.MoveRoutes
  ( carryOldRoutes
  )
where

import Data.Generics.Labels ()
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Types

-- | The redeployed scope with each accepted route it dropped.
carryOldRoutes :: Maybe ScopeDeclaration -> ScopeDeclaration -> Either Text ScopeDeclaration
carryOldRoutes accepted redeployed = case accepted of
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
      kept = routedHosts redeployed
      carried =
        [ ResourceBundle
            [Managed m | m <- mappings before, isMappingOf (m ^. #address) host]
            []
            []
            [c | c <- contributions before, backendHost c == Just host, not (isPortal c)]
            []
            []
        | host <- Set.toList (routedHosts before)
        , host `Set.notMember` kept
        ]
  where
    contributions scope = concatMap (^. #contributions) (scopeBundles scope)
    mappings scope = [m | bundle <- scopeBundles scope, Managed m <- bundle ^. #declarations, isMapping (m ^. #address)]
    routedHosts scope =
      Set.fromList ([h | Just h <- map backendHost (contributions scope)] <> [n | m <- mappings scope, Kubernetes _ _ _ _ n <- [m ^. #address]])
    -- A context has one portal: the old portal's mapping is carried, its registration is not.
    isPortal = \case
      RegisterBackend {role = PortalBackend} -> True
      _ -> False
    backendHost = \case
      RegisterBackend {host = h} -> Just h
      _ -> Nothing
    isMapping = \case
      Kubernetes _ "serving.knative.dev" kind _ _ -> nameText kind == "domainmapping"
      _ -> False
    isMappingOf address host = case address of
      Kubernetes _ "serving.knative.dev" kind _ name -> nameText kind == "domainmapping" && name == host
      _ -> False
