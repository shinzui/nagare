-- | Options / Move. The @context move@ subcommands (EP-243); parsing-only.
module Nagare.Cli.Options.Move
  ( MoveCommand (..)
  )
where

import Nagare.Dsl.Prelude

data MoveCommand
  = -- | EP-246 D1: list what a move to a new base domain changes, and write its manifest; mutates nothing.
    MoveList !Text !(Maybe FilePath)
  | -- | EP-243 with no base domain; EP-246 with the new one.
    MoveStart !(Maybe Text)
  | MoveApply Bool
  | MoveStatus
  | MoveRollback Bool
  | -- | D2: retire the Cloud DNS set a committed move kept.
    MoveRetireDns Bool
  | -- | EP-246 D7: after a move to a new base, retire the old names' grants, routes and Cloud DNS zone.
    MoveRetire Bool
  deriving stock (Generic, Show)
