-- | The route half of EP-246 D5. A site redeployed from its config on the new base declares its new
-- names, and a grant binds to the exact accepted protected route of its host (ADR 29), so a redeploy
-- that dropped an old protected route would orphan its grants. While a base move is open, or the
-- context keeps another base, the redeployed scope carries every accepted route on that other base it
-- dropped, granted or not (the auth portal's has no grant): the same DomainMapping and the same
-- backend registration. Only retirement, which revokes and retires the grants and then the routes,
-- lets a later deploy drop them. A dropped route on any other name (a removed custom domain) is not
-- carried: its scope asks for its retirement as before.
--
-- A carried route is on the base the context is not serving, which the move never serves (old names
-- stop at the flip; a rollback stops the new ones), so it declares no origin TLS: Knative's
-- per-route opt-out, otherwise its bytes unchanged. With the opt-out the route is ready whichever
-- way the cluster's external-domain TLS is set; without it, a rollback that turns that TLS back on
-- leaves each new-base route requesting a certificate the old issuer cannot solve, never ready. The
-- opt-out keeps the route's address, so its identity and every grant on it are unchanged.
--
-- A rollback closes the move but keeps the new zone and its connector so a later move finds them in
-- place; the sites redeployed from their old configs then drop their new-base routes, which only
-- retirement removes. So carrying lasts while an accepted tunnel config serves a base other than the
-- profile's ('servesOtherBase'), as it does while the profile keeps its old base after a commit.
module Nagare.Context.MoveRoutes
  ( carryOldRoutes
  , carryOldRoutesWhere
  , grantedHosts
  , otherBase
  , servesOtherBase
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
import Data.Maybe (listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Canonical (canonicalValue)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (LifecyclePolicy (DeleteWhenUnreferenced))
import Nagare.Resource.Types

-- | The base whose routes a redeploy carries, given the profile's base and retained name and an open
-- base move's old and target bases: during the move the one the profile is not on, after a commit
-- the retained old base, after a rollback the base the kept zone serves.
otherBase :: Text -> Text -> Maybe (Text, Text) -> [ScopeDeclaration] -> Maybe Text
otherBase base retained move scopes = case move of
  Just (old, target) -> Just (if base == target then old else target)
  Nothing
    | not (T.null retained) && retained /= base -> Just retained
    | otherwise -> listToMaybe (servedBases base scopes)

-- | The redeployed scope with each accepted route on the other base it dropped, and the native bytes
-- of each carried DomainMapping, given the accepted bytes of those mappings ('routesToCarry').
carryOldRoutes ::
  Text ->
  Map ResourceId ByteString ->
  Maybe ScopeDeclaration ->
  ScopeDeclaration ->
  Either Text (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
carryOldRoutes = carryOldRoutesWhere (const True)

-- | 'carryOldRoutes' for the hosts @keep@ admits: the admin API keeps its old route only while an
-- accepted grant names it, so a retirement that retired the grants lets a platform review drop it.
carryOldRoutesWhere ::
  (Name -> Bool) ->
  Text ->
  Map ResourceId ByteString ->
  Maybe ScopeDeclaration ->
  ScopeDeclaration ->
  Either Text (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
carryOldRoutesWhere keep other acceptedBytes accepted redeployed = case accepted of
  Nothing -> Right (redeployed, Map.empty)
  Just before
    | null (filter keep (droppedHosts other before redeployed)) -> Right (redeployed, Map.empty)
    | otherwise -> do
        routes <- traverse optedOut [m | m <- mappings before, any (isMappingOf (m ^. #address)) (filter keep (droppedHosts other before redeployed))]
        let carried =
              [ ResourceBundle
                  [Managed m | (m, _) <- routes, isMappingOf (m ^. #address) host]
                  []
                  []
                  [c | c <- contributionsOf before, backendHost c == Just host, not (isPortal c)]
                  []
                  []
              | host <- filter keep (droppedHosts other before redeployed)
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
      -- A carried route waits only for its retirement, which collects it: it is deletable.
      pure (m & #spec .~ NativeObject (contentDigest carriedBytes) & #lifecycle .~ DeleteWhenUnreferenced, carriedBytes)
    isPortal = \case
      RegisterBackend {role = PortalBackend} -> True
      _ -> False

-- | Whether an accepted tunnel config serves a base other than the profile's: a move to a new base
-- was rolled back and its zone kept.
servesOtherBase :: Text -> [ScopeDeclaration] -> Bool
servesOtherBase base = not . null . servedBases base

servedBases :: Text -> [ScopeDeclaration] -> [Text]
servedBases base scopes =
  [served | scope <- scopes, bundle <- scopeBundles scope, Managed m <- bundle ^. #declarations, CloudflareTunnelConfigSpec served _ <- [m ^. #spec], served /= base]

-- | The accepted DomainMappings on the other base a redeploy would carry.
routesToCarry :: Text -> Maybe ScopeDeclaration -> ScopeDeclaration -> Set ResourceId
routesToCarry other accepted redeployed = case accepted of
  Nothing -> Set.empty
  Just before -> Set.fromList [m ^. #identity | m <- mappings before, any (isMappingOf (m ^. #address)) (droppedHosts other before redeployed)]

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

-- | The hosts with a present accepted grant, direct or for a team.
grantedHosts :: [ScopeDeclaration] -> Set Name
grantedHosts scopes =
  Set.fromList
    [ host
    | scope <- scopes
    , bundle <- scopeBundles scope
    , Managed m <- bundle ^. #declarations
    , AccessGrantSpec _ True <- [m ^. #spec]
    , host <- case m ^. #address of
        AccessTuple _ h _ -> [h]
        TeamAccessTuple _ h _ -> [h]
        _ -> []
    ]

-- | The hosts on the other base the accepted scope routes that the redeploy no longer does.
droppedHosts :: Text -> ScopeDeclaration -> ScopeDeclaration -> [Name]
droppedHosts other before redeployed = filter onOther (Set.toList (routedHosts before `Set.difference` routedHosts redeployed))
  where
    onOther host = let h = T.toLower (nameText host); b = T.toLower other in h == b || ("." <> b) `T.isSuffixOf` h

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
