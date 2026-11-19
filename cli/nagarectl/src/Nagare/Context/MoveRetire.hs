-- | What @context move retire@ does next to the names of the base a context no longer serves (EP-246 D7):
-- the old names after a commit, the new ones after a rollback. It is read from the accepted snapshot and
-- the retained members, so every run reviews one phase and a rerun picks up where the last stopped:
-- revoke the grants on those names, retire the grant scopes, make their routes deletable (a packaged
-- route is declared Retain), retire them, each by its own decision, then collect them. After a commit the old Cloud DNS zone goes next.
module Nagare.Context.MoveRetire
  ( RetirePhase (..)
  , retirePhase
  , zoneRetirement
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Nagare.Access.ShomeiUser (ShomeiUser (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Access (compileAccessScope, compileTeamAccessScope)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (LifecyclePolicy (DeleteWhenUnreferenced))
import Nagare.Resource.Types

data RetirePhase
  = -- | Grant scopes on old names, declared absent.
    RevokeGrants ![ScopeDeclaration]
  | -- | Revoked grant scopes to retire, which frees the routes they bound.
    RetireGrants ![ScopeId]
  | -- | Scopes whose routes of the names become deletable, so their retirement can collect them.
    RouteDeletionPolicy ![ScopeDeclaration]
  | -- | Scopes with the names' routes removed, and the routes they drop, each retained by its own decision.
    RetireRoutes ![ScopeDeclaration] ![ResourceId]
  | -- | A retained route of the names, to collect with its controller descendants: a review collects
    -- one DomainMapping, so each run collects the next.
    CollectRoute !ResourceId
  | -- | Nothing on the names is left in the ledger.
    NamesRetired
  deriving stock (Eq, Show)

-- | @hosts@ are the names to retire; @retained@ the members earlier reviews retained.
retirePhase :: [Text] -> [ManagedResource] -> ScopeSnapshot -> Either Text RetirePhase
retirePhase hosts retained snapshot
  | not (null present) = RevokeGrants <$> traverse revoke present
  | not (null grantScopes) = Right (RetireGrants (map fst grantScopes))
  | not (null undeletable) = RouteDeletionPolicy <$> traverse (revise deletable . snd) undeletable
  | not (null routed) = (\trimmed -> RetireRoutes trimmed [m ^. #identity | (_, scope) <- routed, m <- membersOf scope, oldRoute m]) <$> traverse (trim . snd) routed
  | route : _ <- retainedRoutes = Right (CollectRoute route)
  | otherwise = Right NamesRetired
  where
    old = map T.toLower hosts
    retainedRoutes = [m ^. #identity | m <- retained, oldRoute m]
    scopes = Map.toList (Map.map snd (snapshotScopes snapshot))
    membersOf scope = [m | bundle <- scopeBundles scope, Managed m <- bundle ^. #declarations]
    -- An accepted grant on an old name, with its subject and whether it is present.
    grantOf m = case (m ^. #address, m ^. #spec) of
      (AccessTuple _ host user, AccessGrantSpec _ isPresent) | nameText host `elem` old -> Just (Left (nameText host, user), isPresent)
      (TeamAccessTuple _ host team, AccessGrantSpec _ isPresent) | nameText host `elem` old -> Just (Right (nameText host, team), isPresent)
      _ -> Nothing
    grantScopes = [(owner, grants) | (owner, scope) <- scopes, let grants = mapMaybe grantOf (membersOf scope), not (null grants)]
    present = [subject | (_, grants) <- grantScopes, (subject, True) <- grants]
    revoke = \case
      Left (host, user) -> compileAccessScope snapshot host (ShomeiUser user Nothing) False
      Right (host, team) -> compileTeamAccessScope snapshot host team False
    oldRoute m = case m ^. #address of
      Kubernetes _ "serving.knative.dev" kind _ name -> nameText kind == "domainmapping" && nameText name `elem` old
      _ -> False
    oldBackend = \case
      RegisterBackend {host = h} -> nameText h `elem` old
      _ -> False
    routed =
      [ (owner, scope)
      | (owner, scope) <- scopes
      , scopeKind owner /= Platform || scopeIdText owner == "platform:admin-api"
      , any oldRoute (membersOf scope) || any oldBackend (concatMap (^. #contributions) (scopeBundles scope))
      ]
    undeletable = [routedScope | routedScope@(_, scope) <- routed, any (\m -> oldRoute m && m ^. #lifecycle /= DeleteWhenUnreferenced) (membersOf scope)]
    deletable bundle = bundle & #declarations %~ map (\case Managed m | oldRoute m -> Managed (m & #lifecycle .~ DeleteWhenUnreferenced); other -> other)
    trim = revise (\bundle -> bundle & #declarations %~ filter (\case Managed m -> not (oldRoute m); _ -> True) & #contributions %~ filter (not . oldBackend))
    revise change scope =
      first
        (T.pack . show)
        ( withScopeOverrides (scopeOverrides scope)
            . maybe id withScopeConfigDigest (scopeConfigDigest scope)
            <$> mkScopeDeclaration
              (scopeId scope)
              [ kept
              | bundle <- scopeBundles scope
              , let kept = change bundle
              , not (null (kept ^. #declarations) && null (kept ^. #contributions))
              ]
        )

-- | The old Cloud DNS zone goes only once the parent no longer delegates the old base: a delegation
-- naming a deleted zone leaves the name open to takeover.
zoneRetirement :: Text -> Bool -> Either Text ()
zoneRetirement old delegated
  | delegated =
      Left ("the parent zone still delegates " <> old <> "; remove its NS records there first, or the name is open to takeover once the Cloud DNS zone is gone")
  | otherwise = Right ()
