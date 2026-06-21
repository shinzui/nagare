-- | Deploy-time generated broker connection environment variables (EP-77).
module Nagare.Broker.Connection
  ( BrokerConn (..)
  , lookupBrokerConnection
  , brokerConnectionEnv
  , mergeBrokerConnectionEnvs
  )
where

import Data.Char (isAlphaNum, toUpper)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Broker.Discover (checkBrokerTopic, getBroker)
import Nagare.Dsl.Broker
  ( BrokerBinding (..)
  , BrokerProvider
  , TopicName
  , brokerNameText
  , parseBrokerProvider
  , topicNameText
  )
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( EnvName
  , EnvVar (EnvLiteral)
  , Namespace
  , ScopedEnvVar
  , envNameText
  , mkEnvName
  , namespaceText
  , runtimeScoped
  )
import "generic-lens" Data.Generics.Labels ()

data BrokerConn = BrokerConn
  { provider :: !BrokerProvider
  , bootstrapServers :: !Text
  , topics :: ![TopicName]
  }
  deriving stock (Generic, Eq, Show)

lookupBrokerConnection :: Namespace -> BrokerBinding -> IO (Either Text BrokerConn)
lookupBrokerConnection ns binding = do
  found <- getBroker (namespaceText ns) (brokerNameText (binding ^. #name))
  case found of
    Left err -> pure (Left err)
    Right row -> case parseBrokerProvider (row ^. #provider) of
      Nothing -> pure (Left ("broker '" <> brokerNameText (binding ^. #name) <> "' has unknown provider '" <> row ^. #provider <> "'"))
      Just provider'
        | not (row ^. #ready) ->
            pure (Left ("broker '" <> brokerNameText (binding ^. #name) <> "' is not Ready"))
        | otherwise -> do
            checked <- traverse (checkBrokerTopic (namespaceText ns) row) (binding ^. #topics)
            pure $ do
              sequence_ checked
              Right
                BrokerConn
                  { provider = provider'
                  , bootstrapServers = row ^. #bootstrap
                  , topics = binding ^. #topics
                  }

brokerConnectionEnv :: BrokerBinding -> BrokerConn -> Either Text (Map EnvName ScopedEnvVar)
brokerConnectionEnv binding conn = do
  pairs <-
    traverse toEnv $
      [ ("KAFKA_BOOTSTRAP_SERVERS", conn ^. #bootstrapServers)
      , ("KAFKA_SECURITY_PROTOCOL", "PLAINTEXT")
      , ("NAGARE_BROKER_NAME", brokerNameText (binding ^. #name))
      ]
        <> map topicEntry (binding ^. #topics)
  case mergeBrokerConnectionEnvs (map (Map.fromList . pure) pairs) of
    Left err -> Left err
    Right m -> Right m
  where
    topicEntry topic =
      ("NAGARE_TOPIC_" <> normalizeTopicEnvSuffix (topicNameText topic), topicNameText topic)
    toEnv (key, value) = do
      name' <- first (\e -> "generated broker env name invalid: " <> e) (mkEnvName key)
      Right (name', runtimeScoped (EnvLiteral value))

mergeBrokerConnectionEnvs :: [Map EnvName ScopedEnvVar] -> Either Text (Map EnvName ScopedEnvVar)
mergeBrokerConnectionEnvs = go Map.empty
  where
    go acc [] = Right acc
    go acc (m : ms) =
      case conflicts acc m of
        [] -> go (Map.union acc m) ms
        (k : _) ->
          Left
            ( "multiple broker bindings inject incompatible '"
                <> envNameText k
                <> "'; only one bootstrap target per workload is supported in v1"
            )

    conflicts left right =
      [ k
      | k <- Set.toList (Map.keysSet left `Set.intersection` Map.keysSet right)
      , Map.lookup k left /= Map.lookup k right
      ]

normalizeTopicEnvSuffix :: Text -> Text
normalizeTopicEnvSuffix =
  T.dropWhileEnd (== '_')
    . T.dropWhile (== '_')
    . T.map normalize
  where
    normalize c
      | isAlphaNum c = toUpper c
      | otherwise = '_'
