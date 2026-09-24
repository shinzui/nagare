-- | Stable inventory identity for a declared broker. Provider renames keep
-- the same identity only when the operator pins an explicit logical key.
module Nagare.Resource.Broker (brokerResourceId, compileBrokerTopics) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Nagare.Dsl.Broker (Broker (..), brokerNameText, topicNameText)
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types

brokerResourceId :: ScopeId -> Name -> Broker -> Either Text ResourceId
brokerResourceId owner role broker =
  mintResourceId owner <$> key <*> pure role
  where
    key = maybe (mkLogicalKey (brokerNameText (broker ^. #name))) Right
      (broker ^. #logicalKey)

-- | A topic is a durable logical resource in the broker's own collision
-- domain. Its identity follows the broker's stable key and the declared topic
-- name, while its address is tied to the broker StatefulSet incarnation.
compileBrokerTopics
  :: ScopeId -> Broker -> ResourceId -> RecoveryIntent -> SourceLocation
  -> Either (NonEmpty InventoryError) [Declaration]
compileBrokerTopics owner broker stateful recovery source = traverse compileOne (broker ^. #topics)
  where
    invalid message = inventoryError "invalid-broker-topic" message
      & #scopes .~ [owner]
      & #sources .~ [source]
      & (:| [])
    compileOne topic = do
      let topicText = topicNameText (topic ^. #name)
      nativeName <- first invalid (mkName topicText)
      role <- first invalid (mkName ("topic-" <> topicText))
      resourceId <- first invalid (brokerResourceId owner role broker)
      pure (Managed ManagedResource
        { identity = resourceId
        , owner = owner
        , executor = BrokerExecutor
        , address = BrokerTopic stateful nativeName
        , aliases = []
        , spec = LogicalBrokerTopic (topic ^. #partitions)
            (topic ^. #replicationFactor) (topic ^. #retentionMs)
        , lifecycle = Retain
        , dataPolicy = Durable recovery
        , sensitivity = Private
        , dependencies = [OrderedAfter stateful]
        , delegations = []
        , source = source {path = path source <> "/broker/topics/" <> topicText}
        })
