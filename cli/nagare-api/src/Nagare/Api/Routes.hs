{-# LANGUAGE DataKinds #-}

-- | The read-only admin API of one context, served at
-- @https://admin.<base domain>/v1/…@ behind the access gateway. @/@ is
-- reserved for the admin UI on the same origin. Health probes are internal
-- and carry no gateway security requirement.
module Nagare.Api.Routes
  ( AdminApi (..)
  , OpenApiDocument
  , adminApi
  )
where

import Data.Aeson (Value)
import Data.Proxy (Proxy (..))
import Nagare.Api.Access.Routes (AccessRoutes)
import Nagare.Api.Inventory.Routes (InventoryRoutes)
import Nagare.Api.Platform.Routes (PlatformRoutes)
import Nagare.Api.Response (Build, IfNoneMatch)
import Nagare.Api.Sites.Routes (SitesRoutes)
import Nagare.Contract.Prelude
import Servant.API (NamedRoutes, (:>))
import Servant.API.Generic ((:-))
import Servant.Health (HealthApi)

-- | The generated OpenAPI document, served as its checked-in bytes.
type OpenApiDocument = Value

data AdminApi mode = AdminApi
  { platform :: !(mode :- "v1" :> "platform" :> NamedRoutes PlatformRoutes)
  , inventory :: !(mode :- "v1" :> "inventory" :> NamedRoutes InventoryRoutes)
  , sites :: !(mode :- "v1" :> "sites" :> NamedRoutes SitesRoutes)
  , access :: !(mode :- "v1" :> "access" :> NamedRoutes AccessRoutes)
  , openapi :: !(mode :- "v1" :> "openapi.json" :> IfNoneMatch :> Build OpenApiDocument)
  , health :: !(mode :- "health" :> NamedRoutes HealthApi)
  }
  deriving stock (Generic)

adminApi :: Proxy (NamedRoutes AdminApi)
adminApi = Proxy
