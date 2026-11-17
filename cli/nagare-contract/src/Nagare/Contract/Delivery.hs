{-# LANGUAGE DataKinds #-}

-- | Lifecycle delivery documents (EP-234): subscriptions as the sender
-- applies them and their deliveries, transport-neutral (ADR 33). A
-- @transport@ discriminator names the adapter; transport-specific detail
-- appears only as a delivery attempt's typed receipt. No URL, header,
-- signing key or response body is part of them.
module Nagare.Contract.Delivery
  ( DeliverySubscription (..)
  , DeliveryReceipt (..)
  , DeliveryAttempt (..)
  , Delivery (..)
  , SubscriptionList (..)
  , DeliveryList (..)
  , DeliveryDocument (..)
  , DeliveryPageInfo (..)
  )
where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , Value
  , genericParseJSON
  , genericToJSON
  )
import Data.OpenApi (ToSchema (..), description, schema)
import Nagare.Contract.Prelude
import Nagare.Contract.Schema

-- | One subscription as the sender applies it, and its progress.
data DeliverySubscription = DeliverySubscription
  { subscription :: !Text
  , revision :: !Int
  , status :: !Text
  , transport :: !Text
  , destination :: !Text
  , policy :: !Text
  , types :: ![Text]
  , scope :: !(Nullable Text)
  , member :: !(Nullable Text)
  , startAfter :: !Integer
  , matchedTo :: !Integer
  , deliveries :: !Integer
  , paused :: !(Nullable Text)
  , refusedReplay :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | A transport's evidence of an acknowledged attempt: its kind, the
-- version of its shape and its details.
data DeliveryReceipt = DeliveryReceipt
  { kind :: !Text
  , version :: !Int
  , details :: !Value
  }
  deriving stock (Eq, Show, Generic)

data DeliveryAttempt = DeliveryAttempt
  { number :: !Int
  , startedAt :: !Text
  , outcome :: !(Nullable Text)
  , detail :: !(Nullable Text)
  , finishedAt :: !(Nullable Text)
  , receipt :: !(Nullable DeliveryReceipt)
  }
  deriving stock (Eq, Show, Generic)

data Delivery = Delivery
  { deliveryId :: !Text
  , subscription :: !Text
  , destination :: !Text
  , transport :: !Text
  , policy :: !Text
  , revision :: !Int
  , eventId :: !Text
  , position :: !Integer
  , cycle :: !Text
  , state :: !Text
  , nextAttempt :: !(Nullable Text)
  , reason :: !(Nullable Text)
  , attempts :: ![DeliveryAttempt]
  }
  deriving stock (Eq, Show, Generic)

data DeliveryPageInfo = DeliveryPageInfo
  { hasNextPage :: !Bool
  , endCursor :: !(Nullable Text)
  }
  deriving stock (Eq, Show, Generic)

-- | @nagarectl events subscription list@: the subscriptions the sender applies.
data SubscriptionList = SubscriptionList
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "subscription-list")
  , context :: !Text
  , subscriptions :: ![DeliverySubscription]
  }
  deriving stock (Eq, Show, Generic)

-- | @nagarectl events delivery list@: one page of a subscription's deliveries.
data DeliveryList = DeliveryList
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "delivery-list")
  , context :: !Text
  , subscription :: !Text
  , deliveries :: ![Delivery]
  , pageInfo :: !DeliveryPageInfo
  }
  deriving stock (Eq, Show, Generic)

-- | @nagarectl events delivery inspect@: one delivery and its attempts.
data DeliveryDocument = DeliveryDocument
  { contractVersion :: !ContractVersion
  , document :: !(DocumentName "delivery")
  , context :: !Text
  , delivery :: !Delivery
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON DeliverySubscription where toJSON = genericToJSON recordOptions

instance FromJSON DeliverySubscription where parseJSON = genericParseJSON recordOptions

instance ToSchema DeliverySubscription where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "A subscription as the sender applies it: its revision, status, transport and filter, the feed position it has matched up to and its delivery count. paused names why it cannot be bound; refusedReplay the last replay it could not apply."

instance ToJSON DeliveryReceipt where toJSON = genericToJSON recordOptions

instance FromJSON DeliveryReceipt where parseJSON = genericParseJSON recordOptions

instance ToSchema DeliveryReceipt where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "A transport's evidence of an acknowledged attempt, of its own kind and version: a webhook's is its HTTP status."

instance ToJSON DeliveryAttempt where toJSON = genericToJSON recordOptions

instance FromJSON DeliveryAttempt where parseJSON = genericParseJSON recordOptions

instance ToSchema DeliveryAttempt where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "One attempt: recorded before the external call, finished after it. An attempt with outcome unknown may have been received."

instance ToJSON Delivery where toJSON = genericToJSON recordOptions

instance FromJSON Delivery where parseJSON = genericParseJSON recordOptions

instance ToSchema Delivery where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "One delivery of one event to one subscription in one cycle (initial, or a reviewed replay). state is pending, in-flight, acknowledged, failed, exhausted or cancelled. Delivery is at least once: a receiver deduplicates by eventId."

instance ToJSON DeliveryPageInfo where toJSON = genericToJSON recordOptions

instance FromJSON DeliveryPageInfo where parseJSON = genericParseJSON recordOptions

instance ToSchema DeliveryPageInfo where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "Whether deliveries remain, and the opaque cursor to continue after."

instance ToJSON SubscriptionList where toJSON = genericToJSON recordOptions

instance FromJSON SubscriptionList where parseJSON = genericParseJSON recordOptions

instance ToSchema SubscriptionList where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "The subscriptions a context's lifecycle sender applies."

instance ToJSON DeliveryList where toJSON = genericToJSON recordOptions

instance FromJSON DeliveryList where parseJSON = genericParseJSON recordOptions

instance ToSchema DeliveryList where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "One page of a subscription's deliveries, oldest first."

instance ToJSON DeliveryDocument where toJSON = genericToJSON recordOptions

instance FromJSON DeliveryDocument where parseJSON = genericParseJSON recordOptions

instance ToSchema DeliveryDocument where
  declareNamedSchema proxy = recordSchema proxy <&> schema . description ?~ "One delivery and its attempts."
