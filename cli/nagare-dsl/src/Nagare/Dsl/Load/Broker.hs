-- | Broker responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Broker
  ( JsonBrokerBinding (..)
  , decodeBroker
  , toBrokerBinding
  )
where

import Data.Aeson
  ( FromJSON (..)
  , eitherDecodeStrict
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  )
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Nagare.Dsl.Broker
  ( Broker (..)
  , BrokerBinding (..)
  , BrokerTopic
  , mkBrokerName
  , mkBrokerSizing
  , mkBrokerTopic
  , mkBrokerVersion
  , mkTopicName
  , parseBrokerProvider
  )
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields (JsonKindEnvelope (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (Resources (..), mkNamespace, mkQuantity)
import Nagare.Resource.Types (mkLogicalKey)

-- ---------------------------------------------------------------------------
-- JSON intermediate for brokers (mirrors Nagare.Dsl.Config's emitted shape)

data JsonBrokerTopic = JsonBrokerTopic
  { name :: !Text
  , partitions :: !Int
  , replicationFactor :: !Int
  , retentionMs :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonBrokerTopic where
  parseJSON = withObject "BrokerTopic" $ \o ->
    JsonBrokerTopic
      <$> o .: "name"
      <*> o .:? "partitions" .!= 1
      <*> o .:? "replicationFactor" .!= 1
      <*> o .:? "retentionMs"

data JsonBrokerBinding = JsonBrokerBinding
  { name :: !Text
  , topics :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonBrokerBinding where
  parseJSON = withObject "BrokerBinding" $ \o ->
    JsonBrokerBinding
      <$> o .: "name"
      <*> o .:? "topics" .!= []

data JsonBroker = JsonBroker
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , provider :: !Text
  , version :: !Text
  , namespace :: !Text
  , storageSize :: !Text
  , cpuRequest :: !(Maybe Text)
  , memoryRequest :: !(Maybe Text)
  , cpuLimit :: !(Maybe Text)
  , memoryLimit :: !(Maybe Text)
  , redpandaSmp :: !(Maybe Int)
  , redpandaMemory :: !(Maybe Text)
  , topics :: ![JsonBrokerTopic]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonBroker where
  parseJSON = withObject "Broker" $ \o ->
    JsonBroker
      <$> o .: "name"
      <*> o .:? "logicalKey"
      <*> o .: "provider"
      <*> o .: "version"
      <*> o .: "namespace"
      <*> o .: "storageSize"
      <*> o .:? "cpuRequest"
      <*> o .:? "memoryRequest"
      <*> o .:? "cpuLimit"
      <*> o .:? "memoryLimit"
      <*> o .:? "redpandaSmp"
      <*> o .:? "redpandaMemory"
      <*> o .:? "topics" .!= []

toBroker :: JsonBroker -> Either LoadError Broker
toBroker j = do
  name' <- first (MarshalError "name") $ mkBrokerName (j ^. #name)
  logicalKey' <- traverse (first (MarshalError "logicalKey") . mkLogicalKey) (j ^. #logicalKey)
  provider' <- case parseBrokerProvider (j ^. #provider) of
    Just p -> Right p
    Nothing -> Left (MarshalError "provider" ("unknown broker provider: " <> j ^. #provider))
  version' <- first (MarshalError "version") $ mkBrokerVersion provider' (j ^. #version)
  namespace' <- first (MarshalError "namespace") $ mkNamespace (j ^. #namespace)
  storageSize' <- first (MarshalError "storageSize") $ mkQuantity (j ^. #storageSize)
  resources' <- toBrokerResources j
  redpandaMemory' <- traverse (first (MarshalError "redpandaMemory") . mkQuantity) (j ^. #redpandaMemory)
  sizing' <- first (MarshalError "sizing") $ mkBrokerSizing (Just storageSize') resources' (j ^. #redpandaSmp) redpandaMemory'
  topics' <- traverse toBrokerTopic (j ^. #topics)
  Right
    Broker
      { name = name'
      , logicalKey = logicalKey'
      , provider = provider'
      , version = version'
      , namespace = namespace'
      , storageSize = storageSize'
      , sizing = sizing'
      , topics = topics'
      }

toBrokerTopic :: JsonBrokerTopic -> Either LoadError BrokerTopic
toBrokerTopic j = do
  name' <- first (MarshalError "topics.name") $ mkTopicName (j ^. #name)
  first (MarshalError "topics") $
    mkBrokerTopic name' (j ^. #partitions) (j ^. #replicationFactor) (j ^. #retentionMs)

toBrokerBinding :: Text -> JsonBrokerBinding -> Either LoadError BrokerBinding
toBrokerBinding path (JsonBrokerBinding rawName rawTopics) = do
  name' <- first (MarshalError (path <> ".name")) $ mkBrokerName rawName
  topics' <- traverse (first (MarshalError (path <> ".topics")) . mkTopicName) rawTopics
  Right BrokerBinding {name = name', topics = topics'}

toBrokerResources :: JsonBroker -> Either LoadError (Maybe Resources)
toBrokerResources j =
  case (j ^. #cpuRequest, j ^. #memoryRequest, j ^. #cpuLimit, j ^. #memoryLimit) of
    (Nothing, Nothing, Nothing, Nothing) -> Right Nothing
    (c, m, cl, ml) -> do
      c' <- traverse (first (MarshalError "cpuRequest") . mkQuantity) c
      m' <- traverse (first (MarshalError "memoryRequest") . mkQuantity) m
      cl' <- traverse (first (MarshalError "cpuLimit") . mkQuantity) cl
      ml' <- traverse (first (MarshalError "memoryLimit") . mkQuantity) ml
      Right (Just Resources {cpu = c', memory = m', cpuLimit = cl', memoryLimit = ml'})

decodeBroker :: ByteString -> Either LoadError Broker
decodeBroker bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "Broker" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode broker: " <> Text.pack perr))
        Right jb -> toBroker jb
      Just other -> Left (UnexpectedKind "Broker" other)
      Nothing -> Left (UnexpectedKind "Broker" "<none>")
