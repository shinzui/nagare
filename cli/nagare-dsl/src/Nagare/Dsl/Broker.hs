-- | Provider-neutral messaging broker model for Nagare.
--
-- A 'Broker' is a top-level resource, like a managed database. The public
-- contract is Kafka-compatible: applications bind to broker names, topic names,
-- and bootstrap servers. Redpanda is the first provider; Tansu is reserved so
-- later lifecycle code has to preserve the provider boundary.
module Nagare.Dsl.Broker
  ( -- * BrokerProvider
    BrokerProvider (..)
  , brokerProviderToken
  , parseBrokerProvider
  , brokerProviderImage
  , brokerProviderKafkaPort
  , brokerProviderAdminPort
  , brokerProviderMetricsPath

    -- * BrokerName
  , BrokerName
  , mkBrokerName
  , brokerNameText

    -- * TopicName
  , TopicName
  , mkTopicName
  , topicNameText

    -- * BrokerVersion
  , BrokerVersion
  , mkBrokerVersion
  , brokerVersionText
  , defaultBrokerVersion

    -- * BrokerSizing
  , BrokerSizing (..)
  , defaultBrokerSizing
  , mkBrokerSizing

    -- * BrokerTopic
  , BrokerTopic (..)
  , mkBrokerTopic

    -- * Broker
  , Broker (..)
  )
where

import Data.Char (isDigit, isLower)
import Data.Text qualified as Text
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (Namespace, Quantity, Resources, mkQuantity)

data BrokerProvider = Redpanda | Tansu
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

brokerProviderToken :: BrokerProvider -> Text
brokerProviderToken Redpanda = "redpanda"
brokerProviderToken Tansu = "tansu"

parseBrokerProvider :: Text -> Maybe BrokerProvider
parseBrokerProvider "redpanda" = Just Redpanda
parseBrokerProvider "tansu" = Just Tansu
parseBrokerProvider _ = Nothing

brokerProviderImage :: BrokerProvider -> Text
brokerProviderImage Redpanda = "docker.redpanda.com/redpandadata/redpanda"
brokerProviderImage Tansu = "ghcr.io/tansu-io/tansu"

brokerProviderKafkaPort :: BrokerProvider -> Int
brokerProviderKafkaPort Redpanda = 9092
brokerProviderKafkaPort Tansu = 9092

brokerProviderAdminPort :: BrokerProvider -> Maybe Int
brokerProviderAdminPort Redpanda = Just 9644
brokerProviderAdminPort Tansu = Nothing

brokerProviderMetricsPath :: BrokerProvider -> Maybe Text
brokerProviderMetricsPath Redpanda = Just "/public_metrics"
brokerProviderMetricsPath Tansu = Just "/metrics"

newtype BrokerName = BrokerName Text
  deriving stock (Generic, Eq, Ord, Show)

mkBrokerName :: Text -> Either Text BrokerName
mkBrokerName t
  | Text.null t = Left "broker name must not be empty"
  | Text.length t > 63 =
      Left ("broker name too long (" <> tshow (Text.length t) <> " chars, max 63)")
  | Text.isPrefixOf "-" t = Left "broker name must not start with a hyphen"
  | Text.isSuffixOf "-" t = Left "broker name must not end with a hyphen"
  | not (Text.all validLabelChar t) =
      Left ("broker name contains invalid characters (allowed: a-z, 0-9, -): " <> t)
  | otherwise = Right (BrokerName t)

brokerNameText :: BrokerName -> Text
brokerNameText (BrokerName t) = t

newtype TopicName = TopicName Text
  deriving stock (Generic, Eq, Ord, Show)

mkTopicName :: Text -> Either Text TopicName
mkTopicName t
  | Text.null t = Left "topic name must not be empty"
  | Text.isPrefixOf "." t = Left "topic name must not start with a dot"
  | Text.elem ' ' t = Left ("topic name must not contain spaces: " <> t)
  | Text.elem '/' t = Left ("topic name must not contain '/': " <> t)
  | Text.elem ':' t = Left ("topic name must not contain ':': " <> t)
  | otherwise = Right (TopicName t)

topicNameText :: TopicName -> Text
topicNameText (TopicName t) = t

newtype BrokerVersion = BrokerVersion Text
  deriving stock (Generic, Eq, Ord, Show)

mkBrokerVersion :: BrokerProvider -> Text -> Either Text BrokerVersion
mkBrokerVersion provider t
  | Text.null t = Left "broker version must not be empty"
  | t == "latest" = Left "broker version must be pinned, not 'latest'"
  | Text.elem ' ' t = Left ("broker version must not contain spaces: " <> t)
  | Text.elem ':' t = Left ("broker version must not contain ':': " <> t)
  | not (Text.any isDigit t) =
      Left ("broker version must contain a digit (e.g. \"v26.1.8\"): " <> t)
  | otherwise = Right (BrokerVersion t)
  where
    _ = provider

brokerVersionText :: BrokerVersion -> Text
brokerVersionText (BrokerVersion t) = t

defaultBrokerVersion :: BrokerProvider -> BrokerVersion
defaultBrokerVersion Redpanda = BrokerVersion "v26.1.8"
defaultBrokerVersion Tansu = BrokerVersion "0.0.0-reserved"

data BrokerSizing = BrokerSizing
  { resources :: !(Maybe Resources)
  , smp :: !Int
  , memory :: !Quantity
  }
  deriving stock (Generic, Eq, Show)

defaultBrokerSizing :: BrokerSizing
defaultBrokerSizing =
  BrokerSizing
    { resources = Nothing
    , smp = 1
    , memory = unsafeQuantity "1G"
    }

mkBrokerSizing :: Maybe Quantity -> Maybe Resources -> Maybe Int -> Maybe Quantity -> Either Text BrokerSizing
mkBrokerSizing _storage resources smp memory = do
  smp' <- case fromMaybe 1 smp of
    n | n < 1 -> Left ("redpanda smp must be >= 1, got: " <> tshow n)
    n -> Right n
  Right
    BrokerSizing
      { resources = resources
      , smp = smp'
      , memory = fromMaybe (unsafeQuantity "1G") memory
      }

data BrokerTopic = BrokerTopic
  { name :: !TopicName
  , partitions :: !Int
  , replicationFactor :: !Int
  , retentionMs :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

mkBrokerTopic :: TopicName -> Int -> Int -> Maybe Int -> Either Text BrokerTopic
mkBrokerTopic name partitions replicationFactor retentionMs
  | partitions < 1 = Left ("topic partitions must be >= 1, got: " <> tshow partitions)
  | replicationFactor < 1 =
      Left ("topic replication factor must be >= 1, got: " <> tshow replicationFactor)
  | Just n <- retentionMs
  , n < 1 =
      Left ("topic retention ms must be >= 1, got: " <> tshow n)
  | otherwise =
      Right
        BrokerTopic
          { name = name
          , partitions = partitions
          , replicationFactor = replicationFactor
          , retentionMs = retentionMs
          }

data Broker = Broker
  { name :: !BrokerName
  , provider :: !BrokerProvider
  , version :: !BrokerVersion
  , namespace :: !Namespace
  , storageSize :: !Quantity
  , sizing :: !BrokerSizing
  , topics :: ![BrokerTopic]
  }
  deriving stock (Generic, Eq, Show)

validLabelChar :: Char -> Bool
validLabelChar c = isLower c || isDigit c || c == '-'

unsafeQuantity :: Text -> Quantity
unsafeQuantity q =
  case mkQuantity q of
    Right x -> x
    Left e -> error ("invalid built-in broker quantity: " <> Text.unpack e)

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
