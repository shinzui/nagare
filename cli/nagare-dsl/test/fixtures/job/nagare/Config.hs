{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text qualified as Text
import Data.Map qualified as Map
import Nagare.Dsl.Command (mkCommand)
import Nagare.Dsl.Config (emitJob)
import Nagare.Dsl.Job
import Nagare.Dsl.Types
  ( EnvVar (EnvLiteral)
  , mkEnvName
  , runtimeScoped
  )

main :: IO ()
main = either (ioError . userError) emitJob config

config :: Either String Job
config = do
  job <- oneShotJob "agent-run" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/agent-run"
  command <- textError (mkCommand ["/app/agent-run"])
  runId <- textError (mkEnvName "NAGARE_RUN_ID")
  repoRef <- textError (mkEnvName "REPO_REF")
  Right
    job
      { jobCommand = Just command
      , jobEnv =
          Map.fromList
            [ (runId, runtimeScoped (EnvLiteral "01k3qz212e989078m6ssetr2b"))
            , ( repoRef
              , runtimeScoped
                  (EnvLiteral "repo_01ktrw3em3emg8b6zxrtqh843h@6f1c2b0a9d4e8f7c6b5a4938271605f4e3d2c1b0")
              )
            ]
      }
  where
    textError = either (Left . Text.unpack) Right
