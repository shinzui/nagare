{-# LANGUAGE OverloadedStrings #-}

{- | A worker that binds to the managed broker `events` and topic `jobs`.

The binding does not create the broker or topic. Provision them first, then
dry-run this worker to see the generated Kafka-compatible env:

  nagarectl broker create redpanda events --namespace personal --topic jobs
  nagarectl worker deploy -f cluster/examples/broker-worker/nagare/Config.hs --dry-run
-}
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Broker (BrokerBinding (..), mkBrokerName, mkTopicName)
import Nagare.Dsl.Config (emitWorker)
import Nagare.Dsl.Worker (Worker (..), mkCommand, mkReplicas, webWorker)

worker :: Either String Worker
worker = do
    base <- webWorker "broker-worker" "gcr.io/knative-samples/helloworld-go"
    broker <- first show (mkBrokerName "events")
    topic <- first show (mkTopicName "jobs")
    cmd <- first show (mkCommand ["sh", "-c", "while true; do echo consuming jobs; sleep 5; done"])
    reps <- first show (mkReplicas 1)
    Right
        base
            { command = Just cmd
            , replicas = reps
            , brokers = [BrokerBinding{name = broker, topics = [topic]}]
            }

main :: IO ()
main = either (ioError . userError) emitWorker worker
