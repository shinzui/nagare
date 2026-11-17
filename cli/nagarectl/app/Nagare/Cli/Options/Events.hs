-- | Options / Events. Option records for the @events@ commands; parsing-only.
module Nagare.Cli.Options.Events
  ( EventsListOpts (..)
  , EventsCollectBackupsOpts (..)
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

-- | @events collect-backups --once@: one bounded backup collection cycle
-- for disposable fixtures and diagnostics (EP-233).
data EventsCollectBackupsOpts = EventsCollectBackupsOpts
  { once :: !Bool
  , activate :: !Bool
  , bucket :: !(Maybe String)
  }
  deriving stock (Generic, Show)
