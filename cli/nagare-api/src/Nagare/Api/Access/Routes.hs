{-# LANGUAGE DataKinds #-}

-- | Recorded host grants: direct and team viewer relationships the
-- inventory accepted. They are not an effective-access check.
module Nagare.Api.Access.Routes
  ( AccessRoutes (..)
  )
where

import Nagare.Api.Page (Paginated)
import Nagare.Api.Response (IfNoneMatch, Paged, Snapshot)
import Nagare.Contract.Prelude
import Nagare.Contract.V1 (Grant)
import Servant.API ((:>))
import Servant.API.Generic ((:-))

newtype AccessRoutes mode = AccessRoutes
  { grants :: mode :- "grants" :> Paginated (IfNoneMatch :> Snapshot (Paged Grant))
  }
  deriving stock (Generic)
