{-# LANGUAGE DataKinds #-}

-- | The serving build. It describes the binary and its packaged platform
-- version, not what the context has installed.
module Nagare.Api.Platform.Routes
  ( PlatformRoutes (..)
  )
where

import Nagare.Api.Response (Build, IfNoneMatch)
import Nagare.Contract.Prelude
import Nagare.Contract.V1 (VersionInfo)
import Servant.API ((:>))
import Servant.API.Generic ((:-))

newtype PlatformRoutes mode = PlatformRoutes
  { version :: mode :- "version" :> IfNoneMatch :> Build VersionInfo
  }
  deriving stock (Generic)
