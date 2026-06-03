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
  ) where

import "generic-lens" Data.Generics.Labels ()

import Nagare.Dsl.Prelude hiding ((.=))

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Types

-- | Serialize a 'Deployment' to JSON and write it to stdout. Call this as the
-- last line of your @Config.hs@ @main@.
emitDeployment :: Deployment -> IO ()
emitDeployment dep = LBS.putStr (encode (deploymentJSON dep))

-- | The JSON shape the loader reads back (see 'Nagare.Dsl.Load').
deploymentJSON :: Deployment -> Value
deploymentJSON dep =
  object
    [ "name" .= serviceNameText (dep ^. #name)
    , "namespace" .= namespaceText (dep ^. #namespace)
    , "image" .= imageRefText (dep ^. #image)
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

    envJSON (n, EnvLiteral lit) =
      object
        [ "varName" .= envNameText n
        , "kind" .= ("Literal" :: Text)
        , "value" .= lit
        ]
    envJSON (n, EnvSecretRef sn) =
      object
        [ "varName" .= envNameText n
        , "kind" .= ("SecretRef" :: Text)
        , "secretName" .= secretNameText sn
        ]
