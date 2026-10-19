-- | App-database command options (EP-202). Executable-private CLI boundary:
-- every option type the @db app-database@ subcommands parse.
module Nagare.Cli.Options.AppDatabase
  ( AppDatabaseCommand (..)
  , AppDatabasePlanOpts (..)
  , AppDatabaseNameOpts (..)
  )
where

import Nagare.Dsl.Prelude

data AppDatabaseCommand
  = AppDatabasePlan AppDatabasePlanOpts
  | AppDatabaseRotate AppDatabaseNameOpts String
  | AppDatabaseRetire AppDatabaseNameOpts
  | AppDatabaseList (Maybe String)
  deriving stock (Generic, Show)

data AppDatabasePlanOpts = AppDatabasePlanOpts
  { config :: !FilePath
  , recoveryBackup :: !(Maybe String)
  , recoveryKeyVersion :: !(Maybe String)
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

data AppDatabaseNameOpts = AppDatabaseNameOpts
  { name :: !String
  , namespace :: !(Maybe String)
  , scopeKey :: !(Maybe String)
  , savePlan :: !FilePath
  }
  deriving stock (Generic, Show)
