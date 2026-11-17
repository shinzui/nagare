{-# LANGUAGE OverloadedStrings #-}

-- | The contract between the shared delivery engine and a transport adapter
-- (EP-234, ADR 33). The engine hands an adapter one publication request —
-- destination and revision identity, event and delivery IDs, the event's
-- canonical bytes and its feed position — and receives a typed outcome. It
-- never sees an HTTP status, header or URL. An adapter owns its settings'
-- validation, credentials, external call, acknowledgement evidence, failure
-- classification and default retry policy.
--
-- Adapters are registered by the process that runs delivery; source
-- materialization and domain producers never select a transport.
module Nagare.Events.Delivery.Transport
  ( PublicationRequest (..)
  , Receipt (..)
  , Outcome (..)
  , outcomeLabel
  , RetryPolicy (..)
  , retryDelay
  , Adapter (..)
  , AdapterFactory (..)
  , AdapterRegistry
  , adapterRegistry
  , bindAdapter
  , redirectsUnder
  )
where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Time (NominalDiffTime)
import Nagare.Dsl.Prelude
import Nagare.Events.Subscription (DestinationSpec, PolicyRef)

-- | One external publication attempt of one delivery.
data PublicationRequest = PublicationRequest
  { destination :: !Text
  , revision :: !Int
  , eventId :: !Text
  , deliveryId :: !Text
  , attempt :: !Int
  , body :: !ByteString
  -- ^ The event's canonical envelope bytes, the same for every attempt and
  -- destination.
  , position :: !Integer
  }
  deriving stock (Eq, Show, Generic)

-- | A transport's evidence of an acknowledged publication: its kind, the
-- version of its shape and its details. A webhook's is its status code; a
-- broker's would name a partition and offset.
data Receipt = Receipt
  { kind :: !Text
  , version :: !Int
  , details :: !Value
  }
  deriving stock (Eq, Show, Generic)

data Outcome
  = -- | The destination accepted the publication.
    Acknowledged !Receipt
  | -- | It did not; retry, no sooner than the delay if one is given.
    Retryable !(Maybe NominalDiffTime) !Text
  | -- | It refused for good; never retried automatically.
    Permanent !Text
  | -- | Nobody knows whether it was received: a retry may duplicate it.
    Unknown !Text
  deriving stock (Eq, Show)

outcomeLabel :: Outcome -> Text
outcomeLabel = \case
  Acknowledged _ -> "acknowledged"
  Retryable _ _ -> "retryable"
  Permanent _ -> "permanent"
  Unknown _ -> "unknown"

-- | The persisted retry policy a destination's adapter supplies: at most
-- @attempts@ automatic attempts within @lifetime@ of the first, the delay
-- doubling from @base@ up to @cap@, with up to @jitter@ of it added.
data RetryPolicy = RetryPolicy
  { ref :: !PolicyRef
  , attempts :: !Int
  , lifetime :: !NominalDiffTime
  , base :: !NominalDiffTime
  , cap :: !NominalDiffTime
  , jitter :: !Double
  , inFlight :: !Int
  -- ^ Attempts in flight at once for one destination.
  }
  deriving stock (Eq, Show, Generic)

-- | The delay before attempt @n + 1@ after @n@ failed, given a random
-- fraction in [0, 1) and the adapter's requested delay, if any; the
-- request wins when longer.
retryDelay :: RetryPolicy -> Int -> Double -> Maybe NominalDiffTime -> NominalDiffTime
retryDelay policy n fraction requested =
  max (fromMaybe 0 requested) (min (policy ^. #cap) backoff * (1 + realToFrac (policy ^. #jitter * fraction)))
  where
    backoff = policy ^. #base * (2 ^ max 0 (min 30 (n - 1)))

-- | A bound adapter: one destination's validated settings and credentials.
data Adapter = Adapter
  { transport :: !Text
  , policy :: !RetryPolicy
  , publish :: !(PublicationRequest -> IO Outcome)
  }
  deriving stock (Generic)

-- | How one transport binds a destination: decode and validate its settings
-- of a version it supports, resolving its credentials; and whether a
-- reviewed change of its settings sends to another place (a webhook's URL),
-- which cancels unsent work, rather than only changing how (its signing
-- keys), which does not.
data AdapterFactory = AdapterFactory
  { bind :: !(DestinationSpec -> IO (Either Text Adapter))
  , redirects :: !(DestinationSpec -> DestinationSpec -> Bool)
  }
  deriving stock (Generic)

newtype AdapterRegistry = AdapterRegistry (Map Text AdapterFactory)

adapterRegistry :: [(Text, AdapterFactory)] -> AdapterRegistry
adapterRegistry = AdapterRegistry . Map.fromList

-- | A destination whose transport is not registered is a diagnostic for that
-- destination alone.
bindAdapter :: AdapterRegistry -> DestinationSpec -> IO (Either Text Adapter)
bindAdapter (AdapterRegistry factories) spec = case Map.lookup (spec ^. #transport) factories of
  Nothing -> pure (Left ("no adapter is registered for transport " <> spec ^. #transport))
  Just factory -> (factory ^. #bind) spec

-- | A change of transport, or of a transport no adapter is registered for,
-- always redirects.
redirectsUnder :: AdapterRegistry -> DestinationSpec -> DestinationSpec -> Bool
redirectsUnder (AdapterRegistry factories) old new
  | old ^. #transport /= new ^. #transport || old ^. #identity /= new ^. #identity = True
  | otherwise = maybe True (\factory -> (factory ^. #redirects) old new) (Map.lookup (new ^. #transport) factories)
