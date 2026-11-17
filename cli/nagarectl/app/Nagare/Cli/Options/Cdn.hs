-- | Options / Cdn. Option records for the @cdn@ commands; parsing-only.
module Nagare.Cli.Options.Cdn
  ( CdnCommand (..)
  , CdnListOpts (..)
  , CdnStatusOpts (..)
  , CdnPurgeOpts (..)
  , CdnDisableOpts (..)
  )
where

import Nagare.Dsl.Prelude

data CdnCommand
  = CdnList CdnListOpts
  | CdnStatus CdnStatusOpts
  | CdnPurge CdnPurgeOpts
  | CdnDisable CdnDisableOpts
  deriving stock (Generic, Show)

data CdnListOpts = CdnListOpts
  { namespace :: !(Maybe String)
  , allNamespaces :: !Bool
  , baseDomain :: !(Maybe String)
  }
  deriving stock (Generic, Show)

data CdnStatusOpts = CdnStatusOpts
  { host :: !String
  , namespace :: !(Maybe String)
  , baseDomain :: !(Maybe String)
  }
  deriving stock (Generic, Show)

data CdnPurgeOpts = CdnPurgeOpts
  { host :: !String
  , paths :: ![String]
  , namespace :: !(Maybe String)
  , dryRun :: !Bool
  , savePlan :: !(Maybe FilePath)
  , purgeId :: !(Maybe String)
  , wholeZone :: !Bool
  }
  deriving stock (Generic, Show)

data CdnDisableOpts = CdnDisableOpts
  { host :: !String
  , namespace :: !(Maybe String)
  , dryRun :: !Bool
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)
