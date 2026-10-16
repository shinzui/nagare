{-# LANGUAGE DataKinds #-}

-- | The recorded inventory: the checked head, accepted scopes and image
-- publications. The head and scope routes read no scope object.
module Nagare.Api.Inventory.Routes
  ( InventoryRoutes (..)
  )
where

import Nagare.Api.Page (Paginated)
import Nagare.Api.Response (IfNoneMatch, Paged, Snapshot)
import Nagare.Contract.Prelude
import Nagare.Contract.V1 (HeadSummary, Publication, ScopeState)
import Servant.API (Capture', Description, (:>))
import Servant.API.Generic ((:-))

data InventoryRoutes mode = InventoryRoutes
  { head :: !(mode :- "head" :> IfNoneMatch :> Snapshot HeadSummary)
  , scopes :: !(mode :- "scopes" :> Paginated (IfNoneMatch :> Snapshot (Paged ScopeState)))
  , scope ::
      !( mode
           :- "scopes"
             :> Capture' '[Description "A scope ID, kind:name, for example application:kizashi."] "scopeId" Text
             :> IfNoneMatch
             :> Snapshot ScopeState
       )
  , publications :: !(mode :- "publications" :> Paginated (IfNoneMatch :> Snapshot (Paged Publication)))
  }
  deriving stock (Generic)
