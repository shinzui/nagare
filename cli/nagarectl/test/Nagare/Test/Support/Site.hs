-- | Support.Site responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Support.Site
  ( baseSite
  , buildSite
  , demoServerSite
  , demoServerSiteWith
  , noBuildSite
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map qualified as Map
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Server.Types
  ( ServerBuild (ServerBuild, command, outputDirs)
  , ServerSite (..)
  , defaultServerRuntime
  )
import Nagare.Dsl.Static.Types
  ( StaticBuild (..)
  , StaticSite (..)
  , defaultCachePolicy
  , mkFilePathText
  , mkSiteName
  )
import Nagare.Dsl.Types (defaultPort, mkImageRef, mkNamespace)
import Nagare.Test.Support.Assertions (unsafe, unsafeS)

demoServerSite :: ServerSite
demoServerSite = demoServerSiteWith "npm run build"

demoServerSiteWith :: Text -> ServerSite
demoServerSiteWith buildCmd =
  ServerSite
    { name = unsafeS (mkSiteName "demo")
    , namespace = unsafeS (mkNamespace "personal")
    , image = unsafeS (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo")
    , build = ServerBuild {command = buildCmd, outputDirs = unsafeS (mkFilePathText ".output") :| []}
    , runtime = defaultServerRuntime
    , port = defaultPort
    , env = Map.empty
    , resources = Nothing
    , scale = Nothing
    , domains = []
    , volumes = []
    , cdn = Nothing
    }

noBuildSite :: Text -> StaticSite
noBuildSite dir = baseSite (NoBuild (unsafe (mkFilePathText dir)))

buildSite :: Text -> Text -> StaticSite
buildSite command outDir =
  baseSite
    ( BuildCommand
        { command = command
        , outputDirectory = unsafe (mkFilePathText outDir)
        }
    )

baseSite :: StaticBuild -> StaticSite
baseSite b =
  StaticSite
    { name = unsafe (mkSiteName "demo")
    , namespace = unsafe (mkNamespace "personal")
    , image = unsafe (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo")
    , build = b
    , domains = []
    , redirects = []
    , headers = []
    , cache = defaultCachePolicy
    , notFound = Nothing
    , cdn = Nothing
    }
