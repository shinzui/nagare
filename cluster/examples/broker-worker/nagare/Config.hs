{-# LANGUAGE OverloadedStrings #-}

-- | A worker that binds to the managed broker `events` and topic `jobs`.
--
-- The binding does not create the broker or topic. Provision them first, then
-- dry-run this worker to see the generated Kafka-compatible env:
--
--   nagarectl broker create redpanda events --namespace personal --topic jobs
--   nagarectl worker deploy -f cluster/examples/broker-worker/nagare/Config.hs --dry-run
module Main (main) where

import Data.Bifunctor (first)
import qualified Data.Map as Map
import Nagare.Dsl.Broker (BrokerBinding (..), mkBrokerName, mkTopicName)
import Nagare.Dsl.Build (BuildSpec (..), mkTag)
import Nagare.Dsl.Config (emitWorker)
import Nagare.Dsl.Types (defaultNamespace, mkImageRef, mkServiceName)
import Nagare.Dsl.Worker (Worker (..), mkCommand, mkReplicas)

worker :: Either String Worker
worker = do
  name' <- first show (mkServiceName "broker-worker")
  image' <- first show (mkImageRef "docker.redpanda.com/redpandadata/redpanda")
  tag' <- first show (mkTag "v26.1.8")
  broker <- first show (mkBrokerName "events")
  topic <- first show (mkTopicName "jobs")
  cmd <-
    first
      show
      ( mkCommand
          [ "sh"
          , "-c"
          , "while true; do rpk topic consume \"$NAGARE_TOPIC_JOBS\" --offset start -n 1 -X brokers=\"$KAFKA_BOOTSTRAP_SERVERS\" || true; sleep 5; done"
          ]
      )
  reps <- first show (mkReplicas 1)
  Right
    Worker
      { name = name'
      , namespace = defaultNamespace
      , image = image'
      , build = PrebuiltImage tag'
      , command = Just cmd
      , replicas = reps
      , env = Map.empty
      , resources = Nothing
      , volumes = []
      , databases = []
      , brokers = [BrokerBinding {name = broker, topics = [topic]}]
      , liveness = Nothing
      }

main :: IO ()
main = either (ioError . userError) emitWorker worker
