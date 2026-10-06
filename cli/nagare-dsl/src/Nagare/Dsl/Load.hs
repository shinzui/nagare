-- | Load a 'Deployment' from a config-as-program source file.
--
-- The chosen substrate (EP-8) is the native Haskell eDSL: an app ships a
-- @Config.hs@ that binds and emits a 'Deployment' (via
-- 'Nagare.Dsl.Config.emitDeployment'). 'loadDeployment' compiles-and-runs that
-- file with @runghc@, captures the JSON it prints, and decodes it back into a
-- validated 'Deployment'. Every failure mode maps to a precise 'LoadError'.
module Nagare.Dsl.Load
  ( LoadError (..)
  , renderLoadError
  , ConfigTimeout (..)
  , defaultConfigTimeout
  , runConfigWith
  , runConfigUntil
  , loadDeployment
  , decodeDeployment
  , loadBroker
  , decodeBroker
  , loadDatabase
  , decodeDatabase
  , loadStaticSite
  , loadStaticSiteWith
  , decodeStaticSite
  , loadServerSite
  , decodeServerSite
  , loadTask
  , decodeTask
  , loadJob
  , decodeJob
  , loadWorker
  , decodeWorker
  , loadApplication
  , decodeApplication
  , SiteConfig (..)
  , loadSite
  )
where

import Nagare.Dsl.Load.Application (decodeApplication)
import Nagare.Dsl.Load.Broker (decodeBroker)
import Nagare.Dsl.Load.Database (decodeDatabase)
import Nagare.Dsl.Load.Deployment (decodeDeployment)
import Nagare.Dsl.Load.Error
  ( ConfigTimeout (..)
  , LoadError (..)
  , defaultConfigTimeout
  , renderLoadError
  )
import Nagare.Dsl.Load.File
  ( loadApplication
  , loadBroker
  , loadDatabase
  , loadDeployment
  , loadJob
  , loadServerSite
  , loadSite
  , loadStaticSite
  , loadStaticSiteWith
  , loadTask
  , loadWorker
  )
import Nagare.Dsl.Load.Job (decodeJob)
import Nagare.Dsl.Load.Process (runConfigUntil, runConfigWith)
import Nagare.Dsl.Load.ServerSite (decodeServerSite)
import Nagare.Dsl.Load.Site (SiteConfig (..))
import Nagare.Dsl.Load.StaticSite (decodeStaticSite)
import Nagare.Dsl.Load.Task (decodeTask)
import Nagare.Dsl.Load.Worker (decodeWorker)
import Nagare.Dsl.Prelude
