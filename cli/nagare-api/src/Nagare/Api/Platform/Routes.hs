{-# LANGUAGE DataKinds #-}

-- | The serving build, and the versions the context has installed and runs.
-- @version@ describes the serving image, not what the context has
-- installed; @versions@ reports both (EP-236).
module Nagare.Api.Platform.Routes
  ( PlatformRoutes (..)
  )
where

import Nagare.Api.Response (Build, IfNoneMatch)
import Nagare.Contract.Prelude
import Nagare.Contract.Versions (PlatformVersions, ServingBuild)
import Servant.API ((:>))
import Servant.API.Generic ((:-))

data PlatformRoutes mode = PlatformRoutes
  { version :: !(mode :- "version" :> IfNoneMatch :> Build ServingBuild)
  , versions :: !(mode :- "versions" :> IfNoneMatch :> Build PlatformVersions)
  }
  deriving stock (Generic)
