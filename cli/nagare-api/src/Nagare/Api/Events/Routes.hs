{-# LANGUAGE DataKinds #-}

-- | The lifecycle event feed (EP-231): published events, oldest first, and
-- one event by ID; and, transport-neutral (EP-234, ADR 33), the
-- subscriptions the sender applies and their deliveries. They read only the
-- lifecycle state beside the inventory, never the inventory itself, and
-- carry that state's own revision; they are not an atomic snapshot with the
-- inventory head.
module Nagare.Api.Events.Routes
  ( EventsRoutes (..)
  )
where

import Nagare.Api.Page (Paginated)
import Nagare.Api.Response (EventsSnapshot, IfNoneMatch, Paged)
import Nagare.Contract.Delivery (Delivery, DeliverySubscription)
import Nagare.Contract.Events (LifecycleFeedEntry)
import Nagare.Contract.Prelude
import Servant.API (Capture', Description, Optional, QueryFlag, QueryParam', QueryParams, Required, Strict, (:>))
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
  , subscriptions ::
      !( mode
           :- "subscriptions"
             :> IfNoneMatch
             :> EventsSnapshot [DeliverySubscription]
       )
  , deliveries ::
      !( mode
           :- "deliveries"
             :> Paginated
                  ( QueryParam' '[Required, Strict, Description "The subscription whose deliveries to list."] "subscription" Text
                      :> IfNoneMatch
                      :> EventsSnapshot (Paged Delivery)
                  )
       )
  , delivery ::
      !( mode
           :- "deliveries"
             :> Capture' '[Description "A delivery ID, dl- and 32 hexadecimal digits."] "deliveryId" Text
             :> IfNoneMatch
             :> EventsSnapshot Delivery
       )
  , event ::
      !( mode
           :- Capture' '[Description "An event ID, ev- and 32 hexadecimal digits."] "eventId" Text
             :> IfNoneMatch
             :> EventsSnapshot LifecycleFeedEntry
       )
  }
  deriving stock (Generic)
