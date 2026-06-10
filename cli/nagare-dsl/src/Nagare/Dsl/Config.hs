{-# LANGUAGE PackageImports #-}

-- | Serialization helpers for config-as-program files.
--
-- An app's @Config.hs@ imports this module and calls 'emitDeployment' as the
-- last action of @main@ to hand its already-validated 'Deployment' value to
-- @nagarectl@/the loader over stdout, encoded as JSON. The loader
-- ('Nagare.Dsl.Load.loadDeployment') decodes that JSON and re-runs the smart
-- constructors as defence in depth.
module Nagare.Dsl.Config
  ( emitDeployment
  , encodeDeployment
  , emitStaticSite
  , emitServerSite
  ) where

import "generic-lens" Data.Generics.Labels ()

import Nagare.Dsl.Prelude hiding ((.=))

import Data.Aeson (Value, encode, object, toJSON, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Build
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types

-- | Serialize a 'Deployment' to JSON and write it to stdout. Call this as the
-- last line of your @Config.hs@ @main@.
emitDeployment :: Deployment -> IO ()
emitDeployment dep = LBS.putStr (encodeDeployment dep)

-- | The exact JSON bytes 'emitDeployment' writes. Exposed so the emit→decode
-- round-trip can be exercised in-process (without capturing stdout or spawning
-- @runghc@).
encodeDeployment :: Deployment -> LBS.ByteString
encodeDeployment = encode . deploymentJSON

-- | The JSON shape the loader reads back (see 'Nagare.Dsl.Load').
deploymentJSON :: Deployment -> Value
deploymentJSON dep =
  object
    [ "name" .= serviceNameText (dep ^. #name)
    , "namespace" .= namespaceText (dep ^. #namespace)
    , "image" .= imageRefText (dep ^. #image)
    , "build" .= buildJSON (dep ^. #build)
    , "domain" .= fmap domainText (dep ^. #domain)
    , "port" .= portInt (dep ^. #port)
    , "env" .= map envJSON (Map.toAscList (dep ^. #env))
    , "cpuRequest" .= fmap quantityText (resources >>= (^. #cpu))
    , "memoryRequest" .= fmap quantityText (resources >>= (^. #memory))
    , "scaleMin" .= fmap (^. #minScale) scale
    , "scaleMax" .= fmap (^. #maxScale) scale
    ]
  where
    resources = dep ^. #resources
    scale = dep ^. #scale

    buildJSON (PrebuiltImage t) =
      object
        [ "kind" .= ("PrebuiltImage" :: Text)
        , "tag" .= tagText t
        ]
    buildJSON (DockerfileBuild df ctx args) =
      object
        [ "kind" .= ("DockerfileBuild" :: Text)
        , "dockerfile" .= filePathText df
        , "context" .= filePathText ctx
        , "buildArgs" .= args
        ]
    buildJSON (NixpacksBuild ctx args) =
      object
        [ "kind" .= ("NixpacksBuild" :: Text)
        , "context" .= filePathText ctx
        , "buildArgs" .= args
        ]

    envJSON (n, sev) = case sev ^. #value of
      EnvLiteral lit ->
        object
          [ "varName" .= envNameText n
          , "kind" .= ("Literal" :: Text)
          , "value" .= lit
          ]
      EnvSecretRef sn ->
        object
          [ "varName" .= envNameText n
          , "kind" .= ("SecretRef" :: Text)
          , "secretName" .= secretNameText sn
          ]

-- | Serialize a 'StaticSite' to JSON and write it to stdout. Call this as the
-- last line of a static project's @Config.hs@ @main@. The top-level
-- @"kind": "StaticSite"@ discriminator lets the loader report a precise error if
-- a config emits the wrong shape under @nagarectl site deploy@.
emitStaticSite :: StaticSite -> IO ()
emitStaticSite site = LBS.putStr (encode (staticSiteJSON site))

-- | The JSON shape the loader reads back (see 'Nagare.Dsl.Load.decodeStaticSite').
staticSiteJSON :: StaticSite -> Value
staticSiteJSON site =
  object
    [ "kind" .= ("StaticSite" :: Text)
    , "name" .= siteNameText (site ^. #name)
    , "namespace" .= namespaceText (site ^. #namespace)
    , "image" .= imageRefText (site ^. #image)
    , "build" .= buildJSON (site ^. #build)
    , "domains" .= map domainText (site ^. #domains)
    , "redirects" .= map redirectJSON (site ^. #redirects)
    , "headers" .= map headerJSON (site ^. #headers)
    , "cache" .= cacheJSON (site ^. #cache)
    , "notFound" .= fmap filePathText (site ^. #notFound)
    ]
  where
    buildJSON (NoBuild dir) =
      object
        [ "kind" .= ("NoBuild" :: Text)
        , "directory" .= filePathText dir
        ]
    buildJSON (BuildCommand cmd outDir) =
      object
        [ "kind" .= ("BuildCommand" :: Text)
        , "command" .= cmd
        , "outputDirectory" .= filePathText outDir
        ]

    redirectJSON r =
      object
        [ "from" .= (r ^. #from)
        , "to" .= (r ^. #to)
        , "status" .= (r ^. #status)
        ]

    headerJSON h =
      object
        [ "path" .= (h ^. #path)
        , "name" .= (h ^. #name)
        , "value" .= (h ^. #value)
        ]

    cacheJSON cp =
      object
        [ "immutableAssets" .= immutableAssets cp
        , "defaultMaxAge" .= defaultMaxAge cp
        ]

-- | Serialize a 'ServerSite' to JSON and write it to stdout (EP-18). Call this
-- as the last line of a server project's @Config.hs@ @main@. The top-level
-- @"kind": "ServerSite"@ discriminator lets the loader dispatch and report a
-- precise error if the wrong shape is deployed.
emitServerSite :: ServerSite -> IO ()
emitServerSite site = LBS.putStr (encode (serverSiteJSON site))

serverSiteJSON :: ServerSite -> Value
serverSiteJSON site =
  object
    [ "kind" .= ("ServerSite" :: Text)
    , "name" .= siteNameText (site ^. #name)
    , "namespace" .= namespaceText (site ^. #namespace)
    , "image" .= imageRefText (site ^. #image)
    , "build" .= buildJSON (site ^. #build)
    , "runtime" .= runtimeJSON (site ^. #runtime)
    , "port" .= portInt (site ^. #port)
    , "env" .= map envEntryJSON (Map.toAscList (site ^. #env))
    , "cpuRequest" .= fmap quantityText (resources >>= (^. #cpu))
    , "memoryRequest" .= fmap quantityText (resources >>= (^. #memory))
    , "scaleMin" .= fmap (^. #minScale) scale
    , "scaleMax" .= fmap (^. #maxScale) scale
    , "domains" .= map domainText (site ^. #domains)
    ]
  where
    resources = site ^. #resources
    scale = site ^. #scale

    buildJSON b =
      object
        [ "command" .= (b ^. #command)
        , "outputDirs" .= map filePathText (NE.toList (b ^. #outputDirs))
        ]
    runtimeJSON r =
      object
        [ "baseImage" .= runtimeImageText (r ^. #baseImage)
        , "startCommand" .= toJSON (NE.toList (r ^. #startCommand))
        ]

    envEntryJSON (n, sev) = case sev ^. #value of
      EnvLiteral lit ->
        object
          [ "varName" .= envNameText n
          , "kind" .= ("Literal" :: Text)
          , "value" .= lit
          ]
      EnvSecretRef sn ->
        object
          [ "varName" .= envNameText n
          , "kind" .= ("SecretRef" :: Text)
          , "secretName" .= secretNameText sn
          ]
