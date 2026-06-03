-- | Hello app deployment descriptor — Prototype 1 / Prototype 2 shared input.
--
-- This is the file an imagined app author ships in the "config-as-program"
-- and "interpreter" substrates. @nagarectl@ compiles-and-runs it (P1) or
-- interprets it at runtime (P2) to obtain the 'Deployment' value.
module Config (deployment) where

import Data.Map.Strict (fromList)
import Spike.Types

deployment :: Deployment
deployment =
  Deployment
    { depName = "hello"
    , depNamespace = "personal"
    , depImage = "us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello"
    , depPort = 8080
    , depEnv =
        fromList
          [ ("DATABASE_URL", EnvSecretRef "hello-db-url")
          , ("LOG_LEVEL", EnvLiteral "info")
          ]
    , depResources = Just (Resources (Just "250m") (Just "512Mi"))
    , depScale = Just (Scale 0 3)
    , depDomain = Nothing
    }
