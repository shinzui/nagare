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
  deriving stock (Generic, Show)
