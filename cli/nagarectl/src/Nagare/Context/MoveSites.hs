-- | The grant half of EP-246 D5: what @carry-sites@ still waits for. Every host in the manifest needs
-- its new route accepted, which the operator's redeploy from the site's config provides; then each
-- grant on the old host is declared again on the new one, as its own reviewed scope beside the old,
-- which nothing here touches. Team memberships name no host and are not rewritten.
module Nagare.Context.MoveSites
  ( SiteProgress (..)
  , siteProgress
  , renderUnrouted
  )
where

import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Access.ShomeiUser (ShomeiUser (..))
import Nagare.Context.BaseMove (HostKind (..), MovedHost (..), hostKindToken)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Access (acceptedProtectedHost, compileAccessScope, compileTeamAccessScope)
import Nagare.Resource.Access (mkTeamKey)
import Nagare.Resource.Inventory
import Nagare.Resource.Types

data SiteProgress = SiteProgress
  { unrouted :: ![MovedHost]
  -- ^ Hosts whose new name has no accepted route yet: redeploy the site from its config.
  , grants :: ![ScopeDeclaration]
  -- ^ Grant scopes on new names that are not accepted as declared yet.
  }
  deriving stock (Eq, Show, Generic)

siteProgress :: ScopeSnapshot -> [MovedHost] -> Either Text SiteProgress
siteProgress snapshot hosts = do
  declarations <- first (T.pack . show) (inventoryDeclarations <$> composeSnapshot snapshot)
  let routed h = case h ^. #kind of
        -- Default names follow Knative's domain template; nothing declares them.
        DefaultHost | not (h ^. #protected) && null (h ^. #users) && null (h ^. #teams) -> True
        AuthPortalHost -> any (\(host, role) -> host == h ^. #newName && role == PortalBackend) (backendHosts declarations)
        _
          | h ^. #protected || not (null (h ^. #users) && null (h ^. #teams)) -> isRight (acceptedProtectedHost snapshot (h ^. #newName))
          | otherwise -> (h ^. #newName) `elem` routeNames declarations
      (ready, waiting) = partitionWith routed hosts
  wanted <- concat <$> traverse grantScopes ready
  pure
    SiteProgress
      { unrouted = waiting
      , grants = [scope | scope <- wanted, (snd <$> Map.lookup (scopeId scope) (snapshotScopes snapshot)) /= Just scope]
      }
  where
    grantScopes h =
      (<>)
        <$> traverse (\user -> compileAccessScope snapshot (h ^. #newName) (ShomeiUser user Nothing) True) (h ^. #users)
        <*> traverse (\team -> mkTeamKey team >>= \key -> compileTeamAccessScope snapshot (h ^. #newName) key True) (h ^. #teams)
    partitionWith p = foldr (\h (yes, no) -> if p h then (h : yes, no) else (yes, h : no)) ([], [])

backendHosts :: [Declaration] -> [(Text, BackendRole)]
backendHosts declarations = [(nameText host, role) | Managed r <- declarations, BackendMapSpec entries <- [r ^. #spec], BackendEntry host _ role _ <- entries]

-- | Names an accepted DomainMapping or a host claim answers on.
routeNames :: [Declaration] -> [Text]
routeNames declarations =
  [nameText name | Managed r <- declarations, Kubernetes _ "serving.knative.dev" kind _ name <- [r ^. #address], nameText kind == "domainmapping"]
    <> [nameText host | Managed r <- declarations, Hostname host <- r ^. #aliases]

renderUnrouted :: Text -> [MovedHost] -> Text
renderUnrouted new waiting =
  "redeploy these sites from their configs on "
    <> new
    <> " (deploy -f with the updated config; old protected routes are kept beside the new ones): "
    <> T.intercalate ", " [h ^. #newName <> " (" <> hostKindToken (h ^. #kind) <> ", was " <> h ^. #oldName <> ")" | h <- sortOn order waiting]
  where
    -- The auth portal first, so people can sign in, then the apex, then the rest.
    order h = (case h ^. #kind of AuthPortalHost -> 0 :: Int; ApexHost -> 1; _ -> 2, h ^. #newName)
