-- | EP-273: an accepted route to the access enforcer rendered before v0.24.5 lacks Kourier's HTTP/1.1
-- annotation ('disableHttp2Annotation'). Kourier gives every route to the enforcer one Envoy cluster,
-- so one such route can make that cluster HTTP/2 and fail every WebSocket upgrade to every protected
-- host. A release transition re-declares each of them from its accepted bytes with the annotation
-- added: the same identity and address, so every grant bound to the route is unchanged (ADR 29), and
-- no site's config is compiled.
module Nagare.Access.ProtectedRouteRefresh
  ( refreshProtectedRoutes
  , refreshAcceptedProtectedRoutes
  , unrefreshedRouteRefusal
  )
where

import Data.Aeson (Value (..), decodeStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Access.Resolve (RouteTarget (..), backendConfigMapNamespace, disableHttp2Annotation, isCentralEnforcer)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Plan (loadInventoryHistory)
import Nagare.Inventory.Status (loadAcceptedNativeSelected)
import Nagare.Inventory.Store (InventoryStore)
import Nagare.Resource.Canonical (canonicalValue)
import Nagare.Resource.Inventory
import Nagare.Resource.Types

-- | The scope with each of its routes to the enforcer that lacks the annotation re-declared with it,
-- and those routes with their new bytes, given the accepted bytes of the scope's DomainMappings.
-- 'Nothing' when the scope has no such route. Every other member, the scope's overrides and its
-- config digest are unchanged.
refreshProtectedRoutes ::
  Map ResourceId ByteString ->
  ScopeDeclaration ->
  Either Text (Maybe (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)))
refreshProtectedRoutes acceptedBytes scope = do
  refreshed <- Map.fromList . catMaybes <$> traverse refresh (routeMembers scope)
  if Map.null refreshed
    then Right Nothing
    else do
      let declare = \case
            Managed m | Just (annotated, _) <- Map.lookup (m ^. #identity) refreshed -> Managed annotated
            other -> other
      rebuilt <-
        first
          (T.pack . show)
          ( withScopeOverrides (scopeOverrides scope)
              . maybe id withScopeConfigDigest (scopeConfigDigest scope)
              <$> mkScopeDeclaration (scopeId scope) [bundle & #declarations %~ map declare | bundle <- scopeBundles scope]
          )
      Right (Just (rebuilt, refreshed))
  where
    refresh m = do
      bytes <- maybe (Left ("protected route lacks its accepted native bytes: " <> resourceIdText (m ^. #identity))) Right (Map.lookup (m ^. #identity) acceptedBytes)
      fmap (\annotated -> (m ^. #identity, (m & #spec .~ NativeObject (contentDigest annotated), annotated))) <$> withHttp1Hop bytes

-- | A route's bytes with the annotation, or 'Nothing' when its target is not the enforcer or it
-- already carries the annotation. Every other annotation is kept.
withHttp1Hop :: ByteString -> Either Text (Maybe ByteString)
withHttp1Hop bytes = case decodeStrict bytes of
  Just (Object root) | Just (Object metadata) <- KM.lookup "metadata" root -> do
    annotations <- case KM.lookup "annotations" metadata of
      Nothing -> Right KM.empty
      Just (Object existing) -> Right existing
      Just _ -> Left "protected route's annotations are not an object"
    if targetsEnforcer root && KM.lookup key annotations /= Just (String "true")
      then Just <$> canonicalValue (Object (KM.insert "metadata" (Object (KM.insert "annotations" (Object (KM.insert key (String "true") annotations)) metadata)) root))
      else Right Nothing
  _ -> Left "protected route's native bytes are not a Kubernetes object"
  where
    key = Key.fromText disableHttp2Annotation
    targetsEnforcer root = case KM.lookup "spec" root of
      Just (Object spec)
        | Just (Object ref) <- KM.lookup "ref" spec ->
            isCentralEnforcer (RouteTarget (field "apiVersion" ref) (field "kind" ref) (field "name" ref) (field "namespace" ref))
      _ -> False
    field name object = case KM.lookup name object of
      Just (String value) -> value
      _ -> ""

-- | The scope's DomainMappings in the enforcer's namespace, where every protected route lives.
routeMembers :: ScopeDeclaration -> [ManagedResource]
routeMembers scope = [m | bundle <- scopeBundles scope, Managed m <- bundle ^. #declarations, isRoute (m ^. #address)]
  where
    isRoute = \case
      Kubernetes _ "serving.knative.dev" kind (Just namespace) _ -> nameText kind == "domainmapping" && nameText namespace == backendConfigMapNamespace
      _ -> False

-- | 'refreshProtectedRoutes' over every accepted scope, with the accepted bytes read from the store
-- through the loader every review uses: the scopes to re-declare, and the refreshed routes' bytes.
refreshAcceptedProtectedRoutes ::
  InventoryStore ->
  ScopeSnapshot ->
  IO (Either Text ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString)))
refreshAcceptedProtectedRoutes store snapshot
  | Set.null wanted = pure (Right ([], Map.empty))
  | otherwise = do
      history <- loadInventoryHistory store
      case (,) <$> first (T.pack . show) history <*> first (T.pack . show) (composeSnapshot snapshot) of
        Left reason -> pure (Left reason)
        Right (loaded, inventory) -> do
          acceptedNative <- loadAcceptedNativeSelected wanted store loaded inventory
          pure $ do
            (routes, _) <- acceptedNative
            refreshed <- catMaybes <$> traverse (refreshProtectedRoutes (Map.map snd routes)) scopes
            pure (map fst refreshed, Map.unions (map snd refreshed))
  where
    scopes = map snd (Map.elems (snapshotScopes snapshot))
    wanted = Set.fromList [m ^. #identity | scope <- scopes, m <- routeMembers scope]

-- | Why `platform transition commit` may not pin the context yet, given the routes
-- 'refreshAcceptedProtectedRoutes' would still re-declare: the pin is the transition's last write
-- (ADR 6), so it waits for every accepted route to the enforcer to carry the annotation.
unrefreshedRouteRefusal :: Map ResourceId (ManagedResource, ByteString) -> Maybe Text
unrefreshedRouteRefusal pending = case Map.elems pending of
  [] -> Nothing
  (route, _) : _ ->
    Just
      ( "accepted protected route "
          <> host (route ^. #address)
          <> " lacks "
          <> disableHttp2Annotation
          <> " ("
          <> T.pack (show (Map.size pending))
          <> " in all); review the transition's next stage before committing"
      )
  where
    host = \case
      Kubernetes _ _ _ _ name -> nameText name
      _ -> ""
