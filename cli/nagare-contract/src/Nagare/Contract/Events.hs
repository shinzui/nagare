{-# LANGUAGE DataKinds #-}

-- | Lifecycle event documents (EP-231): the immutable event envelope, its
-- feed entry, and the CLI's event list. The envelope here is the public form
-- of the feed's canonical bytes: the same members, in the same encoding, for
-- the CLI, the admin API and any later delivery transport.
module Nagare.Contract.Events
  ( LifecycleScope (..)
  , LifecycleResource (..)
  , LifecycleEvidence (..)
  , LifecycleEvent (..)
  , LifecycleFeedEntry (..)
  , EventPageInfo (..)
  , EventList (..)
  )
where

import Data.Aeson
  ( FromJSON (..)
  , Options (fieldLabelModifier)
  , ToJSON (..)
  , Value
  , genericParseJSON
  , genericToJSON
  )
import Data.OpenApi (ToSchema (..), description, fromAesonOptions, genericDeclareNamedSchema, schema)
import Nagare.Contract.Prelude
import Nagare.Contract.Schema

-- | A scope: its kind and name.
data LifecycleScope = LifecycleScope
  { kind :: !Text
  , name :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | What an event is about: its scope, logical member, namespace and the
-- incarnation recorded for it.
data LifecycleResource = LifecycleResource
  { scope :: !LifecycleScope
  , member :: !(Nullable Text)
  , namespace :: !(Nullable Text)
  , incarnation :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | A named, digest-bound reference to the evidence an event rests on.
data LifecycleEvidence = LifecycleEvidence
  { name :: !Text
  , digest :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | One lifecycle event. @id@ is stable across retries and restarts; @type@
-- names the payload in @data@. Feed position is not part of the event.
data LifecycleEvent = LifecycleEvent
  { schemaVersion :: !Int
  , eventId :: !Text
  , eventType :: !Text
  , context :: !Text
  , resource :: !LifecycleResource
  , occurredAt :: !Text
  , observedAt :: !Text
  , publishedAt :: !Text
  , evidence :: ![LifecycleEvidence]
  , eventData :: !Value
  }
  deriving stock (Eq, Show, Generic)

-- | An event and its publication position in the context's feed.
data LifecycleFeedEntry = LifecycleFeedEntry
  { position :: !Integer
  , event :: !LifecycleEvent
  }
  deriving stock (Eq, Show, Generic)

data EventPageInfo = EventPageInfo
  { hasNextPage :: !Bool
  , endCursor :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | @nagarectl events list@: one page of the context's published events,
-- oldest first. @revision@ names the feed head the page was read at.
data EventList = EventList
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "event-list")
  , context :: !Text
  , revision :: !Text
  , events :: ![LifecycleFeedEntry]
  , pageInfo :: !EventPageInfo
  }
  deriving stock (Eq, Show, Generic)

-- | The event's wire members @id@, @type@ and @data@.
eventOptions :: Options
eventOptions = recordOptions {fieldLabelModifier = rename}
  where
    rename = \case
      "eventId" -> "id"
      "eventType" -> "type"
      "eventData" -> "data"
      other -> other

instance ToJSON LifecycleScope where toJSON = genericToJSON recordOptions

instance FromJSON LifecycleScope where parseJSON = genericParseJSON recordOptions

instance ToSchema LifecycleScope where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "A scope: its kind (Platform, Application, Standalone or Publication) and name."

instance ToJSON LifecycleResource where toJSON = genericToJSON recordOptions

instance FromJSON LifecycleResource where parseJSON = genericParseJSON recordOptions

instance ToSchema LifecycleResource where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The resource an event is about, by stable logical identity; a display name is never its only identity."

instance ToJSON LifecycleEvidence where toJSON = genericToJSON recordOptions

instance FromJSON LifecycleEvidence where parseJSON = genericParseJSON recordOptions

instance ToSchema LifecycleEvidence where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "A named, digest-bound reference to recorded evidence."

instance ToJSON LifecycleEvent where toJSON = genericToJSON eventOptions

instance FromJSON LifecycleEvent where parseJSON = genericParseJSON eventOptions

instance ToSchema LifecycleEvent where
  declareNamedSchema proxy =
    genericDeclareNamedSchema (fromAesonOptions eventOptions) proxy
      <&> schema
      . description
      ?~ "An immutable lifecycle event. Its id is stable across retries and restarts; delivery is at least once, so a consumer may see the same id again. type names the payload in data, whose schema is: app.deployed AppDeployedData, database.backup.completed BackupCompletedData, database.backup.accepted BackupAcceptedData, change.applied ChangeAppliedData. A type is never renamed and a payload member never removed; a reader that does not know a type may skip it."

instance ToJSON LifecycleFeedEntry where toJSON = genericToJSON recordOptions

instance FromJSON LifecycleFeedEntry where parseJSON = genericParseJSON recordOptions

instance ToSchema LifecycleFeedEntry where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "An event and its position in the context's feed, which orders publication, not real-world causality."

instance ToJSON EventPageInfo where toJSON = genericToJSON recordOptions

instance FromJSON EventPageInfo where parseJSON = genericParseJSON recordOptions

instance ToSchema EventPageInfo where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "Whether events remain below the traversal's pinned bound, and the cursor to continue from."

instance ToJSON EventList where toJSON = genericToJSON recordOptions

instance FromJSON EventList where parseJSON = genericParseJSON recordOptions

instance ToSchema EventList where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "One page of a context's published lifecycle events, oldest first."
