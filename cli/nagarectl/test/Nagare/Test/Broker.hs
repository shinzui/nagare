-- | Broker responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Broker
  ( brokerConnectionEnvTests
  , brokerTests
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Broker.Connection
  ( brokerConnectionEnv
  , mergeBrokerConnectionEnvs
  )
import Nagare.Broker.Create (BrokerCreateParams (..), buildBroker)
import Nagare.Broker.Discover
  ( BrokerRow (..)
  , brokerLabelSelector
  , extractBrokerRows
  , formatBrokerTable
  )
import Nagare.Broker.Health (parsePodReady, parseVictoriaUp)
import Nagare.Broker.Topic
  ( TopicStatus (..)
  , parseTopicDescription
  , renderTopicPlan
  , rpkTopicCreateArgs
  )
import Nagare.Dsl.Broker
  ( Broker (..)
  , BrokerBinding (..)
  , BrokerProvider (..)
  , BrokerSizing (..)
  , BrokerTopic (..)
  , brokerNameText
  , defaultBrokerSizing
  , defaultBrokerVersion
  , mkBrokerName
  , mkTopicName
  , topicNameText
  )
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Types (quantityText)
import Nagare.Test.Environment
  ( eventsBinding
  , eventsConn
  , genLit
  )
import Nagare.Test.Support.Assertions (unsafe)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

brokerConnectionEnvTests :: [TestTree]
brokerConnectionEnvTests =
  [ testCase "brokerConnectionEnv emits Kafka bootstrap and topic variables" $ do
      let env = unsafe (brokerConnectionEnv eventsBinding eventsConn)
      genLit env "KAFKA_BOOTSTRAP_SERVERS" @?= Just "events.personal.svc.cluster.local:9092"
      genLit env "KAFKA_SECURITY_PROTOCOL" @?= Just "PLAINTEXT"
      genLit env "NAGARE_BROKER_NAME" @?= Just "events"
      genLit env "NAGARE_TOPIC_JOBS" @?= Just "jobs"
      genLit env "NAGARE_TOPIC_USER_CREATED" @?= Just "user.created"
  , testCase "identical broker env maps merge without conflict" $ do
      let env = unsafe (brokerConnectionEnv eventsBinding eventsConn)
      mergeBrokerConnectionEnvs [env, env] @?= Right env
  , testCase "different bootstrap targets are rejected" $ do
      let env1 = unsafe (brokerConnectionEnv eventsBinding eventsConn)
          otherConn = eventsConn & #bootstrapServers .~ "other.personal.svc.cluster.local:9092"
          env2 = unsafe (brokerConnectionEnv eventsBinding otherConn)
      assertBool "should be Left" (isLeft (mergeBrokerConnectionEnvs [env1, env2]))
  , testCase "topics that normalize to the same env key are rejected" $ do
      let binding =
            BrokerBinding
              { name = unsafe (mkBrokerName "events")
              , topics = [unsafe (mkTopicName "user.created"), unsafe (mkTopicName "user-created")]
              }
      assertBool "should be Left" (isLeft (brokerConnectionEnv binding eventsConn))
  ]

-- ---------------------------------------------------------------------------
-- EP-78: broker lifecycle command helpers.

brokerTests :: [TestTree]
brokerTests =
  [ testGroup
      "Nagare.Broker.Create.buildBroker"
      [ testCase "builds Redpanda with defaults" $
          case buildBroker Redpanda "events" (mkParams Nothing Nothing Nothing) of
            Right Broker {name = brokerName, version = brokerVersion, sizing = BrokerSizing {smp, memory}} -> do
              let BrokerSizing {smp = defaultSmp, memory = defaultMemory} = defaultBrokerSizing
              brokerNameText brokerName @?= "events"
              brokerVersion @?= defaultBrokerVersion Redpanda
              smp @?= defaultSmp
              memory @?= defaultMemory
            Left e -> assertFailure (T.unpack e)
      , testCase "rejects latest version" $
          assertBool "should reject" (isLeft (buildBroker Redpanda "events" (mkParams (Just "latest") Nothing Nothing)))
      , testCase "honors Redpanda sizing flags" $
          case buildBroker Redpanda "events" (mkParams Nothing (Just 2) (Just "4Gi")) of
            Right Broker {sizing = BrokerSizing {smp, memory}} -> do
              smp @?= 2
              quantityText memory @?= "4Gi"
            Left e -> assertFailure (T.unpack e)
      , testCase "builds topics from CLI flags" $
          case buildBroker Redpanda "events" (mkParams Nothing Nothing Nothing) {topics = ["jobs"], topicPartitions = Just 3, topicRetentionMs = Just 86400000} of
            Right Broker {topics = [BrokerTopic {name = topicName, partitions, replicationFactor, retentionMs}]} -> do
              topicNameText topicName @?= "jobs"
              partitions @?= 3
              replicationFactor @?= 1
              retentionMs @?= Just 86400000
            Right other -> assertFailure ("unexpected broker topics: " <> show other)
            Left e -> assertFailure (T.unpack e)
      ]
  , testGroup
      "Nagare.Broker.Topic"
      [ testCase "rpkTopicCreateArgs includes idempotence, sizing, retention, and brokers" $
          let topic =
                BrokerTopic
                  { name = unsafe (mkTopicName "jobs")
                  , partitions = 3
                  , replicationFactor = 1
                  , retentionMs = Just 86400000
                  }
           in rpkTopicCreateArgs "events.personal.svc.cluster.local:9092" topic
                @?= [ "topic"
                    , "create"
                    , "--if-not-exists"
                    , "-p"
                    , "3"
                    , "-r"
                    , "1"
                    , "-c"
                    , "retention.ms=86400000"
                    , "jobs"
                    , "-X"
                    , "brokers=events.personal.svc.cluster.local:9092"
                    ]
      , testCase "parseTopicDescription reads rpk summary and retention" $
          parseTopicDescription topicDescribeOutput
            @?= Right (TopicStatus "jobs" 3 1 (Just 86400000))
      , testCase "renderTopicPlan includes declared topics" $
          case buildBroker Redpanda "events" (mkParams Nothing Nothing Nothing) {topics = ["jobs"], topicPartitions = Just 3, topicRetentionMs = Just 86400000} of
            Right broker ->
              assertBool
                "contains topic plan"
                ("jobs partitions=3 replicationFactor=1 retentionMs=86400000" `T.isInfixOf` renderTopicPlan broker)
            Left e -> assertFailure (T.unpack e)
      ]
  , testGroup
      "Nagare.Broker.Discover"
      [ testCase "brokerLabelSelector" $
          brokerLabelSelector @?= "nagare.dev/managed-by=nagarectl,nagare.dev/broker"
      , testCase "extractBrokerRows parses a statefulset list" $
          extractBrokerRows brokerStsListJson
            @?= Right [BrokerRow "events" "redpanda" "v25.2.1" "5Gi" "events.personal.svc.cluster.local:9092" True]
      , testCase "extractBrokerRows falls back to image version" $
          extractBrokerRows brokerStsImageVersionJson
            @?= Right [BrokerRow "events" "redpanda" "v25.2.1" "?" "events.personal.svc.cluster.local:9092" False]
      , testCase "extractBrokerRows on empty items is Right []" $
          extractBrokerRows "{\"items\":[]}" @?= Right []
      , testCase "extractBrokerRows on malformed JSON is Left" $
          assertBool "should be Left" (isLeft (extractBrokerRows "not json"))
      , testCase "formatBrokerTable renders a header" $
          assertBool
            "has NAME header"
            ( "NAME"
                `T.isInfixOf` formatBrokerTable
                  [BrokerRow "events" "redpanda" "v25.2.1" "5Gi" "events.personal.svc.cluster.local:9092" True]
            )
      ]
  , testGroup
      "Nagare.Broker.Health"
      [ testCase "parsePodReady reads Ready=True" $
          parsePodReady readyPodJson @?= Just True
      , testCase "parsePodReady reads Ready=False" $
          parsePodReady notReadyPodJson @?= Just False
      , testCase "parseVictoriaUp matches broker up sample" $
          parseVictoriaUp "events" victoriaUpJson @?= Right True
      , testCase "parseVictoriaUp returns False when broker has no up sample" $
          parseVictoriaUp "events" victoriaEmptyJson @?= Right False
      ]
  ]
  where
    mkParams ver smp' memory' =
      BrokerCreateParams
        { namespace = "personal"
        , version = ver
        , size = Nothing
        , cpu = Nothing
        , memory = Nothing
        , config = Nothing
        , dryRun = True
        , redpandaSmp = smp'
        , redpandaMemory = memory'
        , topics = []
        , topicPartitions = Nothing
        , topicRetentionMs = Nothing
        }
    topicDescribeOutput =
      BC.pack
        "SUMMARY\n=======\nNAME        jobs\nPARTITIONS  3\nREPLICAS    1\nCONFIGS\n=======\nKEY           VALUE     SOURCE\nretention.ms  86400000  DYNAMIC_TOPIC_CONFIG\n"
    brokerStsListJson =
      BC.pack
        "{\"items\":[{\"metadata\":{\"name\":\"events\",\"namespace\":\"personal\",\"labels\":{\"nagare.dev/broker\":\"events\",\"nagare.dev/broker-provider\":\"redpanda\",\"nagare.dev/managed-by\":\"nagarectl\"},\"annotations\":{\"nagare.dev/version\":\"v25.2.1\",\"nagare.dev/size\":\"5Gi\"}},\"status\":{\"readyReplicas\":1}}]}"
    brokerStsImageVersionJson =
      BC.pack
        "{\"items\":[{\"metadata\":{\"name\":\"events\",\"namespace\":\"personal\",\"labels\":{\"nagare.dev/broker\":\"events\",\"nagare.dev/broker-provider\":\"redpanda\",\"nagare.dev/managed-by\":\"nagarectl\"}},\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"image\":\"docker.redpanda.com/redpandadata/redpanda:v25.2.1\"}]} }},\"status\":{\"readyReplicas\":0}}]}"
    readyPodJson =
      BC.pack
        "{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}"
    notReadyPodJson =
      BC.pack
        "{\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"False\"}]}}"
    victoriaUpJson =
      BC.pack
        "{\"status\":\"success\",\"data\":{\"result\":[{\"metric\":{\"nagare_broker\":\"events\"},\"value\":[1710000000,\"1\"]}]}}"
    victoriaEmptyJson =
      BC.pack
        "{\"status\":\"success\",\"data\":{\"result\":[]}}"
