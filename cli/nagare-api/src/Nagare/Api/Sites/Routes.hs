{-# LANGUAGE DataKinds #-}

-- | Recorded sites: user-facing Knative Services and their declared
-- hostnames. Recorded convergence is not live workload health.
module Nagare.Api.Sites.Routes
  ( SitesRoutes (..)
  )
where

import Nagare.Api.Page (Paginated)
import Nagare.Api.Response (IfNoneMatch, Paged, Snapshot)
import Nagare.Contract.Prelude
import Nagare.Contract.V1 (SiteSummary)
import Servant.API (Description, Optional, QueryParam', Strict, (:>))
import Servant.API.Generic ((:-))

newtype SitesRoutes mode = SitesRoutes
  { sites ::
      mode
        :- QueryParam' '[Optional, Strict, Description "Only sites whose origin Service is in this namespace."] "namespace" Text
          :> QueryParam' '[Optional, Strict, Description "Include site previews; false by default."] "includePreviews" Bool
          :> Paginated (IfNoneMatch :> Snapshot (Paged SiteSummary))
  }
  deriving stock (Generic)
