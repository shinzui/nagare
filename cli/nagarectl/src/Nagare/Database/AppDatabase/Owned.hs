-- | What a PostgreSQL server says about an app-owned app database (EP-257),
-- parsed from 'Nagare.Database.AppDatabase.Sql.renderObserveOwned', and the
-- classification of its two members.
--
-- Nagare judges nothing inside an app-owned database: the roles the app
-- created, their memberships among themselves, schema and object owners,
-- grants and default privileges are the app's. It checks only the boundary:
-- that none of the app's roles holds a server-wide attribute, is a member of
-- a role outside the app, or reaches another database, and that no role
-- outside the app is a member of the app's roles or holds a privilege on its
-- database. Each such reach is drift and refuses at planning, as drift does
-- for every app database.
--
-- __The app's roles__ are the owner user and every role reachable from it by
-- following admin-option memberships. A role created by a @CREATEROLE@ role
-- is granted to its creator with the admin option by the bootstrap
-- superuser, and the creator cannot revoke that grant (EP-257 M1, on
-- PostgreSQL 18), so a role the app made never leaves the set.
module Nagare.Database.AppDatabase.Owned
  ( OwnedCatalog (..)
  , OwnedRole (..)
  , OwnedMembership (..)
  , OwnedDatabase (..)
  , parseOwnedCatalog
  , reachableRoles
  , appRoles
  , OwnerDeclaration (..)
  , classifyOwner
  , ownerReach
  , OwnedDatabaseDeclaration (..)
  , classifyOwnedDatabase
  )
where

import Data.Aeson (Value, eitherDecodeStrict, withObject, (.:))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Database.AppDatabase.Catalog (MemberState (..))
import Nagare.Database.AppDatabase.Sql (ownerSetting)
import Nagare.Dsl.Prelude

data OwnedRole = OwnedRole
  { name :: !Text
  , physical :: !Text
  , login :: !Bool
  , elevated :: ![Text]
  -- ^ of SUPERUSER, CREATEROLE, CREATEDB, REPLICATION and BYPASSRLS, those held
  , connectionLimit :: !Int
  , settings :: ![Text]
  -- ^ server-wide role settings, as @createrole_self_grant=set, inherit@
  }
  deriving stock (Generic, Eq, Show)

-- | One @pg_auth_members@ row: @member@ belongs to @role@, granted by
-- @grantor@, with its options.
data OwnedMembership = OwnedMembership
  { role :: !Text
  , member :: !Text
  , grantor :: !Text
  , admin :: !Bool
  , inherit :: !Bool
  , set :: !Bool
  }
  deriving stock (Generic, Eq, Ord, Show)

data OwnedDatabase = OwnedDatabase
  { physical :: !Text
  , owner :: !Text
  , grants :: ![(Text, Text)]
  -- ^ (grantee, privilege), PUBLIC as @PUBLIC@
  }
  deriving stock (Generic, Eq, Show)

data OwnedCatalog = OwnedCatalog
  { app :: ![Text]
  -- ^ the app's roles, as the server's recursive reading returned them
  , roles :: !(Map Text OwnedRole)
  -- ^ the app's roles and the declared owning role, if it exists
  , memberships :: ![OwnedMembership]
  -- ^ every membership naming one of the app's roles on either side
  , databases :: !(Map Text OwnedDatabase)
  -- ^ the app's database and every database the app's roles own or hold a
  -- privilege on
  , publicSystemAccess :: !Bool
  }
  deriving stock (Generic, Eq, Show)

parseOwnedCatalog :: ByteString -> Either Text OwnedCatalog
parseOwnedCatalog bytes = do
  value <- first (const "app-owned database observation is malformed") (eitherDecodeStrict (BC.strip bytes) :: Either String Value)
  first T.pack (parseEither parser value)
  where
    parser :: Value -> Parser OwnedCatalog
    parser = withObject "app-owned observation" $ \o -> do
      app' <- o .: "app"
      roles' <- o .: "roles" >>= traverse (withObject "role" (\r -> OwnedRole <$> r .: "name" <*> (("postgres-role:" <>) <$> r .: "oid") <*> r .: "login" <*> r .: "elevated" <*> r .: "connectionLimit" <*> r .: "settings"))
      memberships' <- o .: "memberships" >>= traverse (withObject "membership" (\m -> OwnedMembership <$> m .: "role" <*> m .: "member" <*> m .: "grantor" <*> m .: "admin" <*> m .: "inherit" <*> m .: "set"))
      databases' <-
        o .: "databases"
          >>= traverse
            ( withObject "database" $ \d -> do
                grants' <- d .: "grants" >>= traverse (withObject "grant" (\g -> (,) <$> g .: "grantee" <*> g .: "privilege"))
                (,) <$> d .: "name" <*> (OwnedDatabase <$> (("postgres-database:" <>) <$> d .: "oid") <*> d .: "owner" <*> pure grants')
            )
      OwnedCatalog app' (Map.fromList [(r ^. #name, r) | r <- roles']) memberships' (Map.fromList databases') <$> o .: "publicSystemAccess"

-- | The app's roles computed from memberships, as the observation's
-- recursive query computes them on the server: the owner, then every role a
-- role in the set holds with the admin option. The interpreter world builds
-- its observation with it.
reachableRoles :: Text -> [OwnedMembership] -> [Text]
reachableRoles owner memberships' = sort (Set.toList (go (Set.singleton owner)))
  where
    go found =
      let next = found <> Set.fromList [m ^. #role | m <- memberships', m ^. #admin, Set.member (m ^. #member) found]
       in if next == found then found else go next

-- | The one reading of the app's roles that the boundary checks, backups and
-- quiesce use (MasterPlan 35).
appRoles :: OwnedCatalog -> [Text]
appRoles = (^. #app)

-- | The owner member: its user, the app's database, and whether it may log in.
data OwnerDeclaration = OwnerDeclaration
  { user :: !Text
  , database :: !Text
  , enabled :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | Every reach of the app's roles beyond their own database, named by role.
ownerReach :: Text -> OwnedCatalog -> [Text]
ownerReach database' catalog =
  [ r <> " holds " <> attribute
  | r <- own
  , Just found <- [Map.lookup r (catalog ^. #roles)]
  , attribute <- found ^. #elevated
  , attribute `elem` ["SUPERUSER", "CREATEDB", "REPLICATION", "BYPASSRLS"]
  ]
    <> nub [m ^. #member <> " is a member of " <> m ^. #role <> ", which is not the app's" | m <- catalog ^. #memberships, inApp (m ^. #member), not (inApp (m ^. #role))]
    <> nub [m ^. #member <> ", which is not the app's, " <> (if m ^. #admin then "administers " else "is a member of ") <> m ^. #role | m <- catalog ^. #memberships, inApp (m ^. #role), not (inApp (m ^. #member))]
    <> [ db <> " is owned by " <> facts ^. #owner
       | (db, facts) <- Map.toList (catalog ^. #databases)
       , foreignDatabase db
       , inApp (facts ^. #owner)
       ]
    <> nub
      [ grantee <> " holds " <> privilege' <> " on database " <> db
      | (db, facts) <- Map.toList (catalog ^. #databases)
      , foreignDatabase db
      , (grantee, privilege') <- facts ^. #grants
      , inApp grantee
      ]
    <> nub
      [ grantee <> ", which is not the app's, holds " <> privilege' <> " on database " <> database'
      | Just facts <- [Map.lookup database' (catalog ^. #databases)]
      , (grantee, privilege') <- facts ^. #grants
      , grantee /= "PUBLIC"
      , not (inApp grantee)
      ]
  where
    own = catalog ^. #app
    inApp r = r `elem` own
    -- The app's own scratch restores (@<db>_restore_<id>@) are its own.
    foreignDatabase db = db /= database' && not (scratchOf db)
    scratchOf db = case T.stripPrefix (database' <> "_restore_") db of
      Just restoreId -> not (T.null restoreId) && T.length restoreId <= 20 && T.all (\c -> isAsciiLower c || isDigit c) restoreId
      Nothing -> False

-- | The owner user: present with its attributes and setting, and its login
-- as declared. Its member also carries the app's boundary, since every role
-- the app made is reachable from it.
classifyOwner :: OwnerDeclaration -> OwnedCatalog -> MemberState
classifyOwner declaration catalog = case Map.lookup user' (catalog ^. #roles) of
  Nothing -> MemberAbsent
  Just owner'
    | not (null reach) -> MemberDrift (user' <> ": " <> T.intercalate "; " reach)
    | not (null extraSettings) -> MemberDrift (user' <> ": role setting " <> T.intercalate ", " extraSettings)
    | owner' ^. #login /= declaration ^. #enabled -> MemberIncomplete (owner' ^. #physical) (user' <> (if declaration ^. #enabled then ": cannot log in" else ": can still log in"))
    | "CREATEROLE" `notElem` owner' ^. #elevated -> MemberIncomplete (owner' ^. #physical) (user' <> ": lacks CREATEROLE")
    | owner' ^. #connectionLimit /= -1 -> MemberIncomplete (owner' ^. #physical) (user' <> ": connection limit is " <> T.show (owner' ^. #connectionLimit))
    | ownerSetting `notElem` owner' ^. #settings -> MemberIncomplete (owner' ^. #physical) (user' <> ": lacks role setting " <> ownerSetting)
    | otherwise -> MemberComplete (owner' ^. #physical)
    where
      extraSettings = filter (/= ownerSetting) (owner' ^. #settings)
  where
    user' = declaration ^. #user
    reach = ownerReach (declaration ^. #database) catalog

-- | The database member: the database, its owner user, and the declared
-- owning role.
data OwnedDatabaseDeclaration = OwnedDatabaseDeclaration
  { database :: !Text
  , owner :: !Text
  , owningRole :: !(Maybe Text)
  , enabled :: !Bool
  , closed :: ![Text]
  -- ^ the app's logins a reviewed quiesce or retirement closed (EP-258)
  , reopened :: ![Text]
  -- ^ those the accepted scope closed and the declaration no longer does
  }
  deriving stock (Generic, Eq, Show)

-- | The database: owned by the owning role (or the owner), that role held by
-- the owner with the admin, inherit and set options, and PUBLIC kept out of
-- it and of the system databases. An owning role that already exists and is
-- not the app's refuses before anything is created, so Nagare never hands
-- another app's role to this one.
classifyOwnedDatabase :: OwnedDatabaseDeclaration -> OwnedCatalog -> MemberState
classifyOwnedDatabase declaration catalog = case Map.lookup database' (catalog ^. #databases) of
  Nothing
    | Just role' <- owningRole'
    , Map.member role' (catalog ^. #roles)
    , role' `notElem` catalog ^. #app ->
        MemberDrift (database' <> ": role " <> role' <> " already exists and is not this app's")
    | otherwise -> MemberAbsent
  Just facts
    | facts ^. #owner /= declaredOwner -> MemberDrift (database' <> ": owned by " <> facts ^. #owner <> ", declared " <> declaredOwner)
    | Just role' <- owningRole', role' `notElem` catalog ^. #app -> MemberDrift (database' <> ": owning role " <> role' <> " is not administered by " <> owner')
    | Just role' <- owningRole', not (heldFully role') -> MemberIncomplete (facts ^. #physical) (database' <> ": " <> owner' <> " does not hold " <> role' <> " with the admin, inherit and set options")
    | any ((== "PUBLIC") . fst) (facts ^. #grants) -> MemberIncomplete (facts ^. #physical) (database' <> ": PUBLIC holds " <> T.intercalate ", " (nub [p | ("PUBLIC", p) <- facts ^. #grants]))
    | catalog ^. #publicSystemAccess -> MemberIncomplete (facts ^. #physical) (database' <> ": PUBLIC may connect to a system database")
    | not (null stillOpen) -> MemberIncomplete (facts ^. #physical) (database' <> ": still open: " <> T.intercalate ", " stillOpen)
    | not (null stillClosed) -> MemberIncomplete (facts ^. #physical) (database' <> ": still closed: " <> T.intercalate ", " stillClosed)
    | otherwise -> MemberComplete (facts ^. #physical)
  where
    database' = declaration ^. #database
    owner' = declaration ^. #owner
    owningRole' = declaration ^. #owningRole
    declaredOwner = fromMaybe owner' owningRole'
    heldFully role' = or [m ^. #admin && m ^. #inherit && m ^. #set | m <- catalog ^. #memberships, m ^. #role == role', m ^. #member == owner']
    canLogin login' = maybe False (^. #login) (Map.lookup login' (catalog ^. #roles))
    -- A login the app has dropped since is neither open nor closed.
    stillOpen = [login' | login' <- declaration ^. #closed, canLogin login']
    stillClosed = [login' | login' <- declaration ^. #reopened, Map.member login' (catalog ^. #roles), not (canLogin login')]
