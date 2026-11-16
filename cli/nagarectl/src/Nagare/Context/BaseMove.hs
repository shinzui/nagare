-- | The host map and manifest of a move to a new base domain (EP-246 D1).
--
-- Every hostname the context serves is read from its accepted declarations and given its name under
-- the new base: the apex stays the apex, a one-label name keeps its label, a nested default name
-- @<name>.<namespace>.<old>@ flattens to @<name>-<namespace>.<new>@, and a preview follows
-- 'previewHostName'. The new base is a Cloudflare zone whose free edge certificate covers the base
-- and one label below it, so nothing may land deeper. A host's grants travel with it (D5); team
-- memberships and delegation grants name no host and stay as they are.
module Nagare.Context.BaseMove
  ( HostKind (..)
  , MovedHost (..)
  , OAuthClient (..)
  , PasskeyHolder (..)
  , MoveManifest (..)
  , HostFacts (..)
  , hostFacts
  , movedHosts
  , grantDrift
  , renderManifest
  , hostKindToken
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Generics.Labels ()
import Data.List (nub, sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Deploy.Host (HostShape (..), defaultHostName, previewHostName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Resource.Access (teamKeyText)
import Nagare.Resource.Inventory
import Nagare.Resource.Types

data HostKind = ApexHost | AuthPortalHost | AdminApiHost | HooksHost | CustomHost | DefaultHost | PreviewHost
  deriving stock (Eq, Ord, Show, Enum, Bounded)

hostKindToken :: HostKind -> Text
hostKindToken = \case
  ApexHost -> "apex"
  AuthPortalHost -> "auth-portal"
  AdminApiHost -> "admin-api"
  HooksHost -> "hooks"
  CustomHost -> "custom"
  DefaultHost -> "default"
  PreviewHost -> "preview"

instance ToJSON HostKind where
  toJSON = toJSON . hostKindToken

-- | One hostname, its new name, and who may open it.
data MovedHost = MovedHost
  { oldName :: !Text
  , newName :: !Text
  , kind :: !HostKind
  , protected :: !Bool
  , users :: ![Text]
  , teams :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON MovedHost where
  toJSON h =
    object
      [ "old" .= (h ^. #oldName)
      , "new" .= (h ^. #newName)
      , "kind" .= (h ^. #kind)
      , "protected" .= (h ^. #protected)
      , "users" .= (h ^. #users)
      , "teams" .= (h ^. #teams)
      ]

-- | A Shomei OAuth client with a redirect URI under the old base; the operator updates it at Shomei.
data OAuthClient = OAuthClient
  { clientId :: !Text
  , displayName :: !Text
  , redirectUris :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON OAuthClient where
  toJSON c = object ["clientId" .= (c ^. #clientId), "displayName" .= (c ^. #displayName), "redirectUris" .= (c ^. #redirectUris)]

-- | An account holding a passkey, which the browser cannot use on the new domain (D4).
data PasskeyHolder = PasskeyHolder
  { userId :: !Text
  , email :: !Text
  , passkeys :: !Int
  , hasTotp :: !Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PasskeyHolder where
  toJSON p = object ["userId" .= (p ^. #userId), "email" .= (p ^. #email), "passkeys" .= (p ^. #passkeys), "totp" .= (p ^. #hasTotp)]

data MoveManifest = MoveManifest
  { oldBase :: !Text
  , newBase :: !Text
  , hosts :: ![MovedHost]
  , oauthClients :: ![OAuthClient]
  , passkeyHolders :: ![PasskeyHolder]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON MoveManifest where
  toJSON m =
    object
      [ "oldBase" .= (m ^. #oldBase)
      , "newBase" .= (m ^. #newBase)
      , "hosts" .= (m ^. #hosts)
      , "oauthClients" .= (m ^. #oauthClients)
      , "passkeyHolders" .= (m ^. #passkeyHolders)
      ]

-- | What the accepted declarations say about hostnames.
data HostFacts = HostFacts
  { services :: ![(Text, Text)]
  -- ^ Tenant Knative Services, as (namespace, name); each has a default name.
  , mappings :: ![Text]
  -- ^ DomainMapping names: custom domains, protected routes, the apex, @hooks@.
  , backends :: ![(Text, BackendRole)]
  -- ^ The auth backend map's hosts.
  , userGrants :: ![(Text, Text)]
  -- ^ Accepted direct grants, as (host, user).
  , teamGrants :: ![(Text, Text)]
  -- ^ Accepted team grants, as (host, team).
  }
  deriving stock (Eq, Show, Generic)

hostFacts :: [Declaration] -> HostFacts
hostFacts declarations =
  HostFacts
    { services =
        nub
          [ (nameText namespace, nameText name)
          | Kubernetes _ "serving.knative.dev" k (Just namespace) name <- addresses
          , nameText k == "service"
          , nameText namespace `notElem` platformNamespaces
          ]
    , mappings = nub [nameText name | Kubernetes _ "serving.knative.dev" k _ name <- addresses, nameText k == "domainmapping"]
    , backends =
        nub [(nameText host, role) | Managed r <- declarations, BackendMapSpec entries <- [r ^. #spec], BackendEntry host _ role _ <- entries]
    , userGrants = nub [(nameText host, user) | AccessTuple _ host user <- addresses]
    , teamGrants = nub [(nameText host, teamKeyText team) | TeamAccessTuple _ host team <- addresses]
    }
  where
    addresses = concat [r ^. #address : r ^. #aliases | Managed r <- declarations]
    platformNamespaces = ["nagare-system", "knative-serving", "kourier-system"]

-- | Every hostname with its new name, or every refusal, each naming its host.
movedHosts :: Text -> Text -> HostFacts -> Either [Text] [MovedHost]
movedHosts old new facts
  | normal old == normal new = Left ["the new base domain is the current one"]
  | (("." <> normal old) `T.isSuffixOf` normal new) || (("." <> normal new) `T.isSuffixOf` normal old) =
      Left ["the new base domain " <> new <> " and the current one " <> old <> " must not nest"]
  | not (null refusals) = Left refusals
  | otherwise = Right moved
  where
    names =
      sort . nub $
        map (\(namespace, name) -> defaultHostName NestedHosts name namespace old) (facts ^. #services)
          <> (facts ^. #mappings)
          <> map fst (facts ^. #backends)
          <> map fst (facts ^. #userGrants)
          <> map fst (facts ^. #teamGrants)
    classified = [(host, classify host) | host <- names]
    moved =
      [ MovedHost
          { oldName = host
          , newName = target
          , kind = k
          , protected = (host, ProtectedBackend) `elem` (facts ^. #backends)
          , users = sort [user | (h, user) <- facts ^. #userGrants, h == host]
          , teams = sort [team | (h, team) <- facts ^. #teamGrants, h == host]
          }
      | (host, Right (k, target)) <- classified
      ]
    refusals =
      [reason | (_, Left reason) <- classified]
        <> concatMap tooDeep moved
        <> collisions
        <> reserved
    defaults = Map.fromList [(defaultHostName NestedHosts name namespace old, (name, namespace)) | (namespace, name) <- facts ^. #services]
    roleOf host = lookup host (facts ^. #backends)
    classify host
      | host == old = Right (ApexHost, new)
      | Just (name, namespace) <- Map.lookup host defaults = Right (DefaultHost, defaultHostName FlatHosts name namespace new)
      | otherwise = case T.stripSuffix ("." <> old) host of
          Nothing -> Left (host <> " is outside the current base domain " <> old <> "; its route cannot move with it")
          Just label
            | Just site <- T.stripSuffix ".preview" label
            , [previewName, siteName] <- T.splitOn "." site ->
                Right (PreviewHost, previewHostName FlatHosts previewName siteName new)
            | T.any (== '.') label ->
                Left (host <> " is two labels below the base; under " <> new <> " it would need Advanced Certificate Manager: give it a one-label name first")
            | roleOf host == Just PortalBackend -> Right (AuthPortalHost, label <> "." <> new)
            | roleOf host == Just ApiBackend -> Right (AdminApiHost, label <> "." <> new)
            | label == "hooks" -> Right (HooksHost, label <> "." <> new)
            | otherwise -> Right (CustomHost, label <> "." <> new)
    tooDeep h = case T.stripSuffix ("." <> new) (h ^. #newName) of
      _ | h ^. #newName == new -> []
      Just label
        | T.any (== '.') label -> [h ^. #oldName <> " would become " <> h ^. #newName <> ", deeper than the edge certificate covers"]
        | T.length label > 63 -> [h ^. #oldName <> " would become " <> h ^. #newName <> ", whose first label is longer than 63 characters"]
        | otherwise -> []
      Nothing -> [h ^. #oldName <> " would become " <> h ^. #newName <> ", outside " <> new]
    collisions =
      [ T.intercalate " and " olds <> " would all become " <> target
      | (target, olds) <- Map.toList (Map.fromListWith (flip (<>)) [(h ^. #newName, [h ^. #oldName]) | h <- moved])
      , length olds > 1
      ]
    reserved =
      [ h ^. #oldName <> " would become " <> h ^. #newName <> ", which is reserved for the platform's own services"
      | h <- moved
      , h ^. #kind `elem` [DefaultHost, PreviewHost, CustomHost]
      , "-nagare-system." `T.isInfixOf` (h ^. #newName) || h ^. #newName `elem` platformNames
      ]
    platformNames = ["auth." <> new, "admin." <> new, "hooks." <> new]
    normal = T.toLower . T.dropWhileEnd (== '.')

-- | Where the stored grants in En disagree with the accepted ones for a host: a grant only En holds
-- would not be carried, and one only the ledger holds is not yet in effect.
grantDrift :: MovedHost -> ([Text], [Text]) -> [Text]
grantDrift h (storedUsers, storedTeams) =
  [h ^. #oldName <> ": En holds " <> u <> ", which no accepted grant declares" | u <- storedUsers, u `notElem` (h ^. #users)]
    <> [h ^. #oldName <> ": En holds team " <> t <> ", which no accepted grant declares" | t <- storedTeams, t `notElem` (h ^. #teams)]
    <> [h ^. #oldName <> ": the accepted grant to " <> u <> " is not in En" | u <- h ^. #users, u `notElem` storedUsers]
    <> [h ^. #oldName <> ": the accepted grant to team " <> t <> " is not in En" | t <- h ^. #teams, t `notElem` storedTeams]

-- | The changed-URL list, for the operator and the team's notice.
renderManifest :: MoveManifest -> Text
renderManifest m =
  T.unlines $
    ["Moving " <> m ^. #oldBase <> " to " <> m ^. #newBase <> ". Every URL changes:"]
      <> [ "  " <> h ^. #oldName <> " -> " <> h ^. #newName <> "  (" <> hostKindToken (h ^. #kind) <> protection h <> ")"
         | h <- sortOn (\h -> (h ^. #kind, h ^. #oldName)) (m ^. #hosts)
         ]
      <> section "OAuth clients to update at Shomei:" [c ^. #displayName <> " (" <> c ^. #clientId <> "): " <> T.intercalate ", " (c ^. #redirectUris) | c <- m ^. #oauthClients]
      <> section
        "Accounts whose passkeys stop working (they sign in with their password and register a new one):"
        [p ^. #email <> " (" <> T.pack (show (p ^. #passkeys)) <> (if p ^. #hasTotp then " passkeys, also TOTP)" else " passkeys)") | p <- m ^. #passkeyHolders]
      <> [ "Webhooks: GitHub repositories that post to https://hooks." <> m ^. #oldBase <> " must post to https://hooks." <> m ^. #newBase <> " instead."
         | any ((== HooksHost) . (^. #kind)) (m ^. #hosts)
         ]
  where
    protection h
      | h ^. #protected = ", protected, " <> T.pack (show (length (h ^. #users) + length (h ^. #teams))) <> " grants"
      | otherwise = ""
    section _ [] = []
    section title rows = title : map ("  " <>) rows
