-- | Options / Events. Option records for the @events@ commands; parsing-only.
module Nagare.Cli.Options.Events
  ( EventsListOpts (..)
  )
where

import Nagare.Dsl.Prelude

-- | @events list@: one page of the active context's published lifecycle
-- events, oldest first (EP-231).
data EventsListOpts = EventsListOpts
  { first :: !(Maybe Int)
  , after :: !(Maybe String)
  , refresh :: !Bool
  , types :: ![String]
  , scope :: !(Maybe String)
  , member :: !(Maybe String)
  , json :: !Bool
  , contract :: !(Maybe Int)
  }
  deriving stock (Generic, Show)
