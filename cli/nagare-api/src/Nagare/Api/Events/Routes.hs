{-# LANGUAGE DataKinds #-}

-- | The lifecycle event feed (EP-231): published events, oldest first, and
-- one event by ID. Both read only the feed, never the inventory, and carry
-- the feed's own revision; they are not an atomic snapshot with the
-- inventory head.
module Nagare.Api.Events.Routes
  ( EventsRoutes (..)
  )
where

import Nagare.Api.Page (Paginated)
import Nagare.Api.Response (EventsSnapshot, IfNoneMatch, Paged)
import Nagare.Contract.Events (LifecycleFeedEntry)
import Nagare.Contract.Prelude
import Servant.API (Capture', Description, Optional, QueryFlag, QueryParam', QueryParams, Strict, (:>))
import Servant.API.Generic ((:-))

data EventsRoutes mode = EventsRoutes
  { list ::
      !( mode
           :- Paginated
                ( QueryFlag "refresh"
                    :> QueryParams "type" Text
                    :> QueryParam' '[Optional, Strict, Description "Only events about this scope, kind:name, for example application:notes."] "scope" Text
                    :> QueryParam' '[Optional, Strict, Description "With scope, only events about this member."] "member" Text
                    :> IfNoneMatch
                    :> EventsSnapshot (Paged LifecycleFeedEntry)
                )
       )
  , event ::
      !( mode
           :- Capture' '[Description "An event ID, ev- and 32 hexadecimal digits."] "eventId" Text
             :> IfNoneMatch
             :> EventsSnapshot LifecycleFeedEntry
       )
  }
  deriving stock (Generic)
