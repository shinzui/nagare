{-# LANGUAGE OverloadedStrings #-}

-- | The queue-worker example (EP-71): a long-running background worker, not a
-- request-driven app. It renders to a plain @apps/v1@ Deployment (NOT a Knative
-- Service), so it runs continuously, never scales to zero, and needs no HTTP
-- port. A real worker would consume a queue (Redis, a DB table, a message bus);
-- this example uses a public, pullable image with a @command@ override that
-- turns it into a visible "worker" (it prints "working" every 5 seconds), so the
-- @examples-compile@ flake check needs no private registry.
--
-- Note: a config run by the loader's @runghc@ compiles under @-XGHC2024@, which
-- does not enable @OverloadedLabels@, so this uses plain record updates
-- (@base {replicas = ...}@) rather than @#replicas@ lenses.
--
-- Provision it with:
--   nagarectl worker deploy -f cluster/examples/queue-worker/nagare/Config.hs
module Main (main) where

import Nagare.Dsl.Config (emitWorker)
import Nagare.Dsl.Worker (Worker (..), mkCommand, mkReplicas, webWorker)

worker :: Either String Worker
worker = do
  base <- webWorker "queue-worker" "gcr.io/knative-samples/helloworld-go"
  cmd <- mapLeft show (mkCommand ["sh", "-c", "while true; do echo working; sleep 5; done"])
  reps <- mapLeft show (mkReplicas 2)
  Right base {command = Just cmd, replicas = reps}
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case worker of
  Left err -> ioError (userError err)
  Right w -> emitWorker w
