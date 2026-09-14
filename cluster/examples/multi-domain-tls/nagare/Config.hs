{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Focused EP-131 origin-TLS fixture. Local mode uses the base apex plus two
-- loopback names. The environment-gated cloud smoke supplies a unique prefix
-- and receives two first-level names under the active context's base zone.
module Main (main) where

import Control.Lens ((%~), (&), (.~))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Build (BuildSpec (PrebuiltImage), mkTag)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types
import System.Environment (lookupEnv)

deployment :: Text -> Maybe Text -> Either String Deployment
deployment base cloudPrefix = do
  app <- first show (webService "multi-domain-tls" "gcr.io/knative-samples/helloworld-go")
  tag <- first show (mkTag "latest")
  domains' <- first show (mkDomains (hostnames base cloudPrefix))
  target <- first show (mkEnvName "TARGET")
  Right
    ( app
        & #build .~ PrebuiltImage tag
        & #domains .~ domains'
        & #env %~ Map.insert target (runtimeScoped (EnvLiteral "multi-domain fixture"))
    )

hostnames :: Text -> Maybe Text -> [(Text, Bool)]
hostnames base Nothing =
  [ (base, True)
  , ("www." <> base, False)
  , ("alternate." <> base, False)
  ]
hostnames base (Just prefix) =
  [ (prefix <> "." <> base, True)
  , (prefix <> "-alternate." <> base, False)
  ]

main :: IO ()
main = do
  base <- maybe "127-0-0-1.sslip.io" T.pack <$> lookupEnv "NAGARE_BASE_DOMAIN"
  prefix <- fmap T.pack <$> lookupEnv "NAGARE_MULTI_DOMAIN_CLOUD_PREFIX"
  case deployment base prefix of
    Left err -> ioError (userError err)
    Right dep -> emitDeployment dep
