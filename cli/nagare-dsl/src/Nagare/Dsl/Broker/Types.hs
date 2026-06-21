-- | Leaf broker reference types shared by the top-level broker resource and
-- workload bindings.
module Nagare.Dsl.Broker.Types
  ( -- * BrokerName
    BrokerName
  , mkBrokerName
  , brokerNameText

    -- * TopicName
  , TopicName
  , mkTopicName
  , topicNameText

    -- * BrokerBinding
  , BrokerBinding (..)
  )
where

import Data.Char (isDigit, isLower)
import Data.Text qualified as Text
import Nagare.Dsl.Prelude

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

-- | A workload binding to an existing broker plus the topics it consumes or
-- produces. An empty topic list means the workload only needs bootstrap
-- connection details.
data BrokerBinding = BrokerBinding
  { name :: !BrokerName
  , topics :: ![TopicName]
  }
  deriving stock (Generic, Eq, Show)

validLabelChar :: Char -> Bool
validLabelChar c = isLower c || isDigit c || c == '-'

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
