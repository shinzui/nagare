-- | What @context move retire@ does next after a move to a new base domain (EP-246 D7), read from the
-- accepted snapshot, so every run reviews one phase and a rerun picks up where the last stopped: revoke
-- the grants on the old names, retire those grant scopes, drop the old routes they held, retire the old
-- Cloud DNS zone, then clear the profile's retained name and delete the passkey export.
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
import Nagare.Resource.Types

data RetirePhase
  = -- | Grant scopes on old names, declared absent.
    RevokeGrants ![ScopeDeclaration]
  | -- | Revoked grant scopes to retire, which frees the routes they bound.
    RetireGrants ![ScopeId]
  | -- | Scopes with their old routes removed.
    RetireRoutes ![ScopeDeclaration]
  | -- | Nothing on the old names is left in the ledger; the Cloud DNS set goes next.
    RetireDns
  deriving stock (Eq, Show)

-- | @oldHosts@ are the manifest's old names.
retirePhase :: [Text] -> ScopeSnapshot -> Either Text RetirePhase
retirePhase oldHosts snapshot
  | not (null present) = RevokeGrants <$> traverse revoke present
  | not (null grantScopes) = Right (RetireGrants (map fst grantScopes))
  | not (null routed) = RetireRoutes <$> traverse trim routed
  | otherwise = Right RetireDns
  where
    old = map T.toLower oldHosts
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
      [ scope
      | (owner, scope) <- scopes
      , scopeKind owner /= Platform || scopeIdText owner == "platform:admin-api"
      , any oldRoute (membersOf scope) || any oldBackend (concatMap (^. #contributions) (scopeBundles scope))
      ]
    trim scope =
      first
        (T.pack . show)
        ( withScopeOverrides (scopeOverrides scope)
            . maybe id withScopeConfigDigest (scopeConfigDigest scope)
            <$> mkScopeDeclaration
              (scopeId scope)
              [ kept
              | bundle <- scopeBundles scope
              , let kept =
                      bundle
                        & #declarations
                        %~ filter (\case Managed m -> not (oldRoute m); _ -> True)
                        & #contributions
                        %~ filter (not . oldBackend)
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
