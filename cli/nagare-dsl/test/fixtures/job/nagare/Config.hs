{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text qualified as Text
import Nagare.Dsl.Command (mkCommand)
import Nagare.Dsl.Config (emitJob)
import Nagare.Dsl.Job

main :: IO ()
main = either (ioError . userError) emitJob config

config :: Either String Job
config = do
  job <- oneShotJob "agent-run" "busybox"
  command <- either (Left . Text.unpack) Right (mkCommand ["sh", "-c", "echo one-shot job"])
  Right job {jobCommand = Just command}
