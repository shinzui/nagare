-- | The typed server-site model (EP-18): a full-stack JavaScript app (the
-- TanStack Start case) packaged as a Node image and run as a Knative Service.
--
-- A 'ServerSite' is the third top-level shape beside 'Nagare.Dsl.Types.Deployment'
-- (run a prebuilt image) and 'Nagare.Dsl.Static.Types.StaticSite' (serve a folder
-- of files with Nginx). It is "build from source, then run the resulting Node
-- server": it carries a build command, the self-contained output directories to
-- copy, a runtime (base image + start command), and the runtime concerns a server
-- needs — container port, env, resources, scale — but none of the Nginx
-- redirect/header/cache concepts a static site carries.
--
-- Leaf types are shared, not duplicated: 'SiteName' and 'FilePathText' come from
-- 'Nagare.Dsl.Static.Types'; 'Namespace', 'ImageRef', 'Port', 'EnvVar',
-- 'Resources', 'Scale', and 'Domain' come from 'Nagare.Dsl.Types'. The runtime
-- defaults ('defaultServerRuntime', 'tanstackStartBuild') make the common
-- TanStack Start config tiny.
module Nagare.Dsl.Server.Types
  ( ServerSite (..)
  , ServerBuild (..)
  , ServerRuntime (..)
  , RuntimeImage
  , mkRuntimeImage
  , runtimeImageText
  , defaultServerRuntime
  , tanstackStartBuild
  ) where

import Nagare.Dsl.Prelude

import Data.Char (isSpace)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map (Map)
import Data.Text qualified as Text
import Nagare.Dsl.Cdn.Types (Cdn)
import Nagare.Dsl.Static.Types (FilePathText, SiteName, mkFilePathText)
import Nagare.Dsl.Types
  ( Domain
  , EnvName
  , EnvVar
  , ImageRef
  , Namespace
  , Port
  , Resources
  , Scale
  , ScopedEnvVar
  , Volume
  )

-- | A base image reference for the runtime, e.g. @"node:22-alpine"@. Unlike
-- 'Nagare.Dsl.Types.ImageRef' (the registry repo for the built image, which
-- forbids a tag), a base image /may/ carry a tag. Constructor hidden; use
-- 'mkRuntimeImage'.
newtype RuntimeImage = RuntimeImage Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'RuntimeImage': non-empty, no spaces, no URI scheme.
mkRuntimeImage :: Text -> Either Text RuntimeImage
mkRuntimeImage t
  | Text.null t = Left "runtime base image must not be empty"
  | Text.any isSpace t = Left ("runtime base image must not contain spaces: " <> t)
  | "://" `Text.isInfixOf` t =
      Left ("runtime base image must not include a URI scheme: " <> t)
  | otherwise = Right (RuntimeImage t)

runtimeImageText :: RuntimeImage -> Text
runtimeImageText (RuntimeImage t) = t

-- | How to produce the runtime output from source: a build command and the
-- self-contained directories to copy into the image. @outputDirs@ is 'NonEmpty'
-- so an empty copy set cannot be constructed, and each entry is a 'FilePathText'
-- so absolute paths and @..@ escapes are rejected at construction.
data ServerBuild = ServerBuild
  { command :: !Text
  , outputDirs :: !(NonEmpty FilePathText)
  }
  deriving stock (Generic, Eq, Show)

-- | How to package and start the output: the base image and the start command as
-- argv. @startCommand@ is 'NonEmpty' so an empty command cannot be constructed.
data ServerRuntime = ServerRuntime
  { baseImage :: !RuntimeImage
  , startCommand :: !(NonEmpty Text)
  }
  deriving stock (Generic, Eq, Show)

-- | The TanStack Start (and Nuxt/SolidStart/SvelteKit-node) default runtime:
-- @node:22-alpine@ starting @node .output/server/index.mjs@.
defaultServerRuntime :: ServerRuntime
defaultServerRuntime =
  ServerRuntime
    { baseImage = RuntimeImage "node:22-alpine"
    , startCommand = "node" :| [".output/server/index.mjs"]
    }

-- | The TanStack Start default build: @npm ci && npm run build@ producing the
-- self-contained @.output@ directory.
tanstackStartBuild :: ServerBuild
tanstackStartBuild =
  ServerBuild
    { command = "npm ci && npm run build"
    , outputDirs = forceFilePath ".output" :| []
    }
  where
    -- ".output" is a known-valid relative path, so this never errors.
    forceFilePath t =
      either (\e -> error ("invalid default path: " <> Text.unpack e)) id (mkFilePathText t)

-- | A full-stack server site: build from source, package the output into a Node
-- image, and run it as a Knative Service. Assemble with a record literal after
-- constructing each field through its smart constructor. @scale = Nothing@ means
-- the platform default (scale-to-zero).
data ServerSite = ServerSite
  { name :: !SiteName
  , namespace :: !Namespace
  , image :: !ImageRef
  , build :: !ServerBuild
  , runtime :: !ServerRuntime
  , port :: !Port
  , env :: !(Map EnvName ScopedEnvVar)
  , resources :: !(Maybe Resources)
  , scale :: !(Maybe Scale)
  , domains :: ![Domain]
  -- | Durable disks attached to the site (same model as
  -- 'Nagare.Dsl.Types.Deployment'). Empty means a stateless site.
  , volumes :: ![Volume]
  -- | An optional edge CDN fronting the origin (MasterPlan 11, EP-55). 'Nothing'
  -- (the backward-compatible default) means no CDN.
  , cdn :: !(Maybe Cdn)
  }
  deriving stock (Generic, Eq, Show)
