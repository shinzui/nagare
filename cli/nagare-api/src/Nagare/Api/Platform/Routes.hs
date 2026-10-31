{-# LANGUAGE DataKinds #-}

-- | The serving build, and the versions the context has installed and runs.
-- @version@ describes the binary and its packaged platform version, not
-- what the context has installed; @versions@ reports both (EP-236).
module Nagare.Api.Platform.Routes
  ( PlatformRoutes (..)
  )
where

import Nagare.Api.Response (Build, IfNoneMatch)
import Nagare.Contract.Prelude
import Nagare.Contract.V1 (VersionInfo)
import Nagare.Contract.Versions (PlatformVersions)
import Servant.API ((:>))
import Servant.API.Generic ((:-))

data PlatformRoutes mode = PlatformRoutes
  { version :: !(mode :- "version" :> IfNoneMatch :> Build VersionInfo)
  , versions :: !(mode :- "versions" :> IfNoneMatch :> Build PlatformVersions)
  }
  deriving stock (Generic)
