{-# LANGUAGE OverloadedStrings #-}

-- | A harmless one-shot Job example. The command proves the local hardening
-- properties available without network access: UID 65532, a read-only root,
-- writable ephemeral scratch, and no mounted Kubernetes API token.
module Main (main) where

import Data.Bifunctor (first)
import Data.Map qualified as Map
import Nagare.Dsl.Build (BuildSpec (PrebuiltImage), mkTag)
import Nagare.Dsl.Command (mkCommand)
import Nagare.Dsl.Config (emitJob)
import Nagare.Dsl.Job
import Nagare.Dsl.Types
  ( EnvVar (EnvLiteral)
  , mkEnvName
  , runtimeScoped
  )

job :: Either String Job
job = do
  base <- oneShotJob "agent-run-example" "busybox"
  tag <- first show (mkTag "1.37.0")
  command <-
    first
      show
      ( mkCommand
          [ "sh"
          , "-c"
          , "set -eu; test \"$(id -u)\" = 65532; if touch /etc/nagare-write-test 2>/dev/null; then echo 'unexpected writable root' >&2; exit 1; fi; touch /scratch/nagare-write-test; test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token; echo 'uid=65532 root=readonly scratch=writable api-token=absent'"
          ]
      )
  repoRef <- first show (mkEnvName "REPO_REF")
  runId <- first show (mkEnvName "NAGARE_RUN_ID")
  Right
    base
      { jobBuild = PrebuiltImage tag
      , jobCommand = Just command
      , jobEnv =
          Map.fromList
            [ ( repoRef
              , runtimeScoped
                  (EnvLiteral "repo_01kt4eyz65ehts693sy0zhe34v@fd8aa1c000000000000000000000000000000000")
              )
            , (runId, runtimeScoped (EnvLiteral "example-run-change-me"))
            ]
      }

main :: IO ()
main = either (ioError . userError) emitJob job
