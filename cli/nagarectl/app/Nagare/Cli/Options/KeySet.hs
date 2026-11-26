-- | Options / KeySet (EP-286). Executable-private CLI boundary.
module Nagare.Cli.Options.KeySet
  ( KeySetCommand (..)
  , KeySetPlanOpts (..)
  )
where

import Nagare.Dsl.Prelude

data KeySetCommand
  = KeySetPlan KeySetPlanOpts
  | -- | One key set by name, or every accepted key set.
    KeySetStatus (Maybe String)
  deriving stock (Generic, Show)

data KeySetPlanOpts = KeySetPlanOpts
  { file :: !FilePath
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)
