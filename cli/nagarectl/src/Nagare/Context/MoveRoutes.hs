-- | The route half of EP-246 D5. A site redeployed from its config on the new base declares its new
-- names, and a grant binds to the exact accepted protected route of its host (ADR 29), so a redeploy
-- that dropped an old protected route would orphan its grants. While a base move is open, or the
-- context still keeps its old base, the redeployed scope carries every accepted route it dropped,
-- granted or not (the auth portal's has no grant): the same DomainMapping and the same backend
-- registration. Only retirement, which revokes and retires the grants and then the routes, lets a
-- later deploy drop them.
--
-- A carried route is on the base the context is not serving, which the move never serves (old names
-- stop at the flip; a rollback stops the new ones), so it declares no origin TLS: Knative's
-- per-route opt-out, otherwise its bytes unchanged. With the opt-out the route is ready whichever
-- way the cluster's external-domain TLS is set; without it, a rollback that turns that TLS back on
-- leaves each new-base route requesting a certificate the old issuer cannot solve, never ready. The
-- opt-out keeps the route's address, so its identity and every grant on it are unchanged.
module Nagare.Context.MoveRoutes
  ( carryOldRoutes
  , routesToCarry
  , withoutOriginTls
  )
where

import Data.Aeson (Value (..), decodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Canonical (canonicalValue)
import Nagare.Resource.Inventory
import Nagare.Resource.Types

-- | The redeployed scope with each accepted route it dropped, and the native bytes of each carried
-- DomainMapping, given the accepted bytes of those mappings ('routesToCarry').
carryOldRoutes ::
  Map ResourceId ByteString ->
  Maybe ScopeDeclaration ->
  ScopeDeclaration ->
  Either Text (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
carryOldRoutes acceptedBytes accepted redeployed = case accepted of
  Nothing -> Right (redeployed, Map.empty)
  Just before
    | null (droppedHosts before redeployed) -> Right (redeployed, Map.empty)
    | otherwise -> do
        routes <- traverse optedOut [m | m <- mappings before, any (isMappingOf (m ^. #address)) (droppedHosts before redeployed)]
        let carried =
              [ ResourceBundle
                  [Managed m | (m, _) <- routes, isMappingOf (m ^. #address) host]
                  []
                  []
                  [c | c <- contributionsOf before, backendHost c == Just host, not (isPortal c)]
                  []
                  []
              | host <- droppedHosts before redeployed
              ]
        scope <-
          first
            (T.pack . show)
            ( withScopeOverrides (scopeOverrides redeployed)
                . maybe id withScopeConfigDigest (scopeConfigDigest redeployed)
                <$> mkScopeDeclaration (scopeId redeployed) (scopeBundles redeployed <> carried)
            )
        pure (scope, Map.fromList [(m ^. #identity, route) | route@(m, _) <- routes])
  where
    optedOut m = do
      bytes <- maybe (Left ("carried route lacks its accepted native bytes: " <> resourceIdText (m ^. #identity))) Right (Map.lookup (m ^. #identity) acceptedBytes)
      carriedBytes <- withoutOriginTls bytes
      pure (m & #spec .~ NativeObject (contentDigest carriedBytes), carriedBytes)
    isPortal = \case
      RegisterBackend {role = PortalBackend} -> True
      _ -> False

-- | The accepted DomainMappings a redeploy would carry.
routesToCarry :: Maybe ScopeDeclaration -> ScopeDeclaration -> Set ResourceId
routesToCarry accepted redeployed = case accepted of
  Nothing -> Set.empty
  Just before -> Set.fromList [m ^. #identity | m <- mappings before, any (isMappingOf (m ^. #address)) (droppedHosts before redeployed)]

-- | A DomainMapping's bytes with Knative's per-route external-domain TLS opt-out.
withoutOriginTls :: ByteString -> Either Text ByteString
withoutOriginTls bytes = case decodeStrict bytes of
  Just (Object root) | Just (Object metadata) <- KM.lookup "metadata" root -> do
    annotations <- case KM.lookup "annotations" metadata of
      Nothing -> Right KM.empty
      Just (Object existing) -> Right existing
      Just _ -> Left "carried route's annotations are not an object"
    let optOut = KM.insert "networking.knative.dev/disable-external-domain-tls" (String "true") annotations
    canonicalValue (Object (KM.insert "metadata" (Object (KM.insert "annotations" (Object optOut) metadata)) root))
  _ -> Left "carried route's native bytes are not a Kubernetes object"

-- | The hosts the accepted scope routes that the redeploy no longer does.
droppedHosts :: ScopeDeclaration -> ScopeDeclaration -> [Name]
droppedHosts before redeployed = Set.toList (routedHosts before `Set.difference` routedHosts redeployed)

routedHosts :: ScopeDeclaration -> Set Name
routedHosts scope =
  Set.fromList ([h | Just h <- map backendHost (contributionsOf scope)] <> [n | m <- mappings scope, Kubernetes _ _ _ _ n <- [m ^. #address]])

contributionsOf :: ScopeDeclaration -> [Contribution]
contributionsOf scope = concatMap (^. #contributions) (scopeBundles scope)

mappings :: ScopeDeclaration -> [ManagedResource]
mappings scope = [m | bundle <- scopeBundles scope, Managed m <- bundle ^. #declarations, isMapping (m ^. #address)]
  where
    isMapping = \case
      Kubernetes _ "serving.knative.dev" kind _ _ -> nameText kind == "domainmapping"
      _ -> False

backendHost :: Contribution -> Maybe Name
backendHost = \case
  RegisterBackend {host = h} -> Just h
  _ -> Nothing

isMappingOf :: ProviderAddress -> Name -> Bool
isMappingOf address host = case address of
  Kubernetes _ "serving.knative.dev" kind _ name -> nameText kind == "domainmapping" && name == host
  _ -> False
