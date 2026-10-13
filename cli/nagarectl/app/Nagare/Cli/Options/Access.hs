-- | Access and team command options. Executable-private CLI boundary
-- (MasterPlan 27): every option type the @access@ subcommands parse.
module Nagare.Cli.Options.Access
  ( AccessCheckOpts (..)
  , AccessCommand (..)
  , AccessGrantOpts (..)
  , AccessListOpts (..)
  , PortalCommand (..)
  , TeamCommand (..)
  , TeamListOpts (..)
  , TeamMemberOpts (..)
  )
where

import Nagare.Dsl.Prelude

data AccessCommand
  = AccessGrant AccessGrantOpts
  | AccessRevoke AccessGrantOpts
  | AccessList AccessListOpts
  | AccessCheck AccessCheckOpts
  | AccessTeam TeamCommand
  | AccessPortal PortalCommand
  deriving stock (Generic, Show)

-- | Team membership (EP-187): a team is a named group with flat user
-- membership; changes are always reviewed.
data TeamCommand
  = TeamAddMember TeamMemberOpts
  | TeamRemoveMember TeamMemberOpts
  | TeamListMembers TeamListOpts
  deriving stock (Generic, Show)

data TeamMemberOpts = TeamMemberOpts
  { savePlan :: !(Maybe FilePath)
  , enApiKey :: !(Maybe String)
  , team :: !String
  , user :: !String
  }
  deriving stock (Generic, Show)

data TeamListOpts = TeamListOpts
  { enUrl :: !(Maybe String)
  , enApiKey :: !(Maybe String)
  , team :: !String
  , json :: !Bool
  }
  deriving stock (Generic, Show)

data PortalCommand
  = PortalShow
  | PortalSync !(Maybe FilePath)
  deriving stock (Generic, Show)

data AccessGrantOpts = AccessGrantOpts
  { savePlan :: !(Maybe FilePath)
  , enUrl :: !(Maybe String)
  , enApiKey :: !(Maybe String)
  , host :: !String
  , user :: !(Maybe String)
  , team :: !(Maybe String)
  -- ^ Exactly one of @user@ and @team@; a team grant is always reviewed.
  }
  deriving stock (Generic, Show)

-- | @access check@: one user's effective access on one protected host.
data AccessCheckOpts = AccessCheckOpts
  { enApiKey :: !(Maybe String)
  , host :: !String
  , user :: !String
  , json :: !Bool
  }
  deriving stock (Generic, Show)

data AccessListOpts = AccessListOpts
  { enUrl :: !(Maybe String)
  , enApiKey :: !(Maybe String)
  , host :: !String
  , json :: !Bool
  }
  deriving stock (Generic, Show)
