-- | Options / Move. The @context move@ subcommands (EP-243); parsing-only.
module Nagare.Cli.Options.Move
  ( MoveCommand (..)
  )
where

import Nagare.Dsl.Prelude

data MoveCommand
  = MoveStart
  | MoveApply Bool
  | MoveStatus
  | MoveRollback Bool
  | -- | D2: retire the Cloud DNS set a committed move kept.
    MoveRetireDns Bool
  deriving stock (Generic, Show)
