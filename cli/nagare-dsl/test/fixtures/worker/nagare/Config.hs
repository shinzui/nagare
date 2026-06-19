{-# LANGUAGE OverloadedStrings #-}

-- | A queue-consumer worker fixture (EP-71): a long-running background process
-- that is not request-driven. It uses a public, pullable image with a `command`
-- override that turns it into a visible worker, and runs two replicas.
--
-- Note: a config run by the loader's @runghc@ compiles under @-XGHC2024@, which
-- does not enable @OverloadedLabels@, so this uses plain record updates
-- (@base {replicas = ...}@) rather than @#replicas@ lenses.
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Config (emitWorker)
import Nagare.Dsl.Worker (Worker (..), mkCommand, mkReplicas, webWorker)

worker :: Either String Worker
worker = do
  base <- webWorker "queue-consumer" "gcr.io/knative-samples/helloworld-go"
  cmd <- first show (mkCommand ["sh", "-c", "while true; do echo working; sleep 5; done"])
  reps <- first show (mkReplicas 2)
  Right base {command = Just cmd, replicas = reps}

main :: IO ()
main = either (ioError . userError) emitWorker worker
