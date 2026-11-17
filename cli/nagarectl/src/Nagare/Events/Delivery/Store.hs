{-# LANGUAGE OverloadedStrings #-}

-- | Delivery state (EP-234), in the lifecycle prefix's @delivery/@ beside
-- the feed and transport-neutral (ADR 33). The sender's head records the
-- journal checkpoint of the subscription controls it applied and the
-- destinations it knows. Each destination's head is constant-size: the
-- revision it applies, the feed position it scanned to, and digests of its
-- immutable pending-work node and delivery log. Each delivery is one
-- record, created before anything is sent, whose attempt intents and
-- outcomes are conditional replacements, so a stale worker's outcome never
-- overwrites a later one. Every mutable object is replaced only at the
-- generation it was read at, and a lost acknowledgement is settled by
-- reading it back.
module Nagare.Events.Delivery.Store
  ( DeliveryId
  , mkDeliveryId
  , deliveryIdText
  , deliveryIdFor
  , DeliveryState (..)
  , deliveryStateText
  , Attempt (..)
  , DeliveryRecord (..)
  , PendingEntry (..)
  , LogPointer (..)
  , emptyLog
  , DestinationHead (..)
  , SenderHead (..)
  , Observed (..)
  , observeJson
  , observeSender
  , observeDestination
  , observeRecordAt
  , replaceJson
  , createJson
  , senderKey
  , destinationKey
  , recordKey
  , publishNode
  , readNode
  , appendLog
  , readLog
  , logSegment
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Time (UTCTime)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Delivery.Transport (Receipt (..))
import Nagare.Events.Envelope (EventId, eventIdText)
import Nagare.Events.Source (SourceCheckpoint)
import Nagare.Events.Store
import Nagare.Events.Subscription (Subscription, SubscriptionId, subscriptionIdText)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | @dl-@ and 32 lowercase hexadecimal digits.
newtype DeliveryId = DeliveryId Text deriving stock (Eq, Ord, Show)

mkDeliveryId :: Text -> Either Text DeliveryId
mkDeliveryId value = case T.stripPrefix "dl-" value of
  Just digits | T.length digits == 32 && T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) digits -> Right (DeliveryId value)
  _ -> Left "a delivery id is dl- and 32 lowercase hexadecimal digits"

deliveryIdText :: DeliveryId -> Text
deliveryIdText (DeliveryId value) = value

-- | A delivery's identity: its subscription and destination, the event and
-- the delivery cycle (@initial@, or a reviewed replay's cycle).
deliveryIdFor :: SubscriptionId -> Text -> EventId -> Text -> DeliveryId
deliveryIdFor subscription destination event cycle' =
  DeliveryId ("dl-" <> T.take 32 (digestText (contentDigest (canonical (object ["version" .= (1 :: Int), "subscription" .= subscriptionIdText subscription, "destination" .= destination, "event" .= eventIdText event, "cycle" .= cycle'])))))

data DeliveryState
  = -- | Due at 'nextAttempt'.
    Pending
  | -- | An attempt was intended under this token and has no recorded outcome.
    InFlight !Text
  | -- | The destination acknowledged it.
    Delivered
  | -- | The destination refused it for good.
    Failed
  | -- | Its automatic attempts or lifetime ran out.
    Exhausted
  | -- | A reviewed change of destination or filter, or a deletion, retired it unsent.
    Cancelled
  deriving stock (Eq, Show)

deliveryStateText :: DeliveryState -> Text
deliveryStateText = \case
  Pending -> "pending"
  InFlight _ -> "in-flight"
  Delivered -> "acknowledged"
  Failed -> "failed"
  Exhausted -> "exhausted"
  Cancelled -> "cancelled"

-- | One attempt: intended before the external call, finished after it.
data Attempt = Attempt
  { number :: !Int
  , token :: !Text
  , startedAt :: !UTCTime
  , outcome :: !(Maybe Text)
  , detail :: !(Maybe Text)
  , receipt :: !(Maybe Receipt)
  , finishedAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)

data DeliveryRecord = DeliveryRecord
  { schemaVersion :: !Int
  , delivery :: !DeliveryId
  , subscription :: !SubscriptionId
  , destination :: !Text
  , transport :: !Text
  , revision :: !Int
  , policy :: !Text
  , event :: !EventId
  , position :: !Integer
  , deliveryCycle :: !Text
  , state :: !DeliveryState
  , attempts :: ![Attempt]
  , createdAt :: !UTCTime
  , nextAttempt :: !(Maybe UTCTime)
  , reason :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | One delivery in a destination's pending work, and when it is due.
data PendingEntry = PendingEntry
  { delivery :: !DeliveryId
  , due :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

-- | An append-only list of delivery IDs in creation order: segments of 64,
-- the tail segment and the list of full segment digests.
data LogPointer = LogPointer
  { count :: !Integer
  , lastSegment :: !(Maybe ContentDigest)
  , full :: !(Maybe ContentDigest)
  }
  deriving stock (Eq, Show, Generic)

emptyLog :: LogPointer
emptyLog = LogPointer 0 Nothing Nothing

logSegment :: Integer
logSegment = 64

data DestinationHead = DestinationHead
  { schemaVersion :: !Int
  , binding :: !ContextBinding
  , subscription :: !SubscriptionId
  , generation :: !Integer
  , record :: !Subscription
  -- ^ The revision this destination applies.
  , cursor :: !Integer
  -- ^ The next feed position to match.
  , cancelledThrough :: !(Maybe Integer)
  -- ^ The last boundary of a reviewed destination or filter change: the
  -- positions before it the old revision had not matched were cancelled.
  , pending :: !(Maybe ContentDigest)
  , history :: !LogPointer
  , diagnostic :: !(Maybe Text)
  -- ^ Why the destination is paused, when it cannot be bound.
  , refusedReplay :: !(Maybe Text)
  -- ^ The last reviewed replay the sender could not apply, and why; a
  -- later applied replay clears it.
  }
  deriving stock (Eq, Show, Generic)

data SenderHead = SenderHead
  { schemaVersion :: !Int
  , binding :: !ContextBinding
  , generation :: !Integer
  , controls :: !SourceCheckpoint
  , destinations :: ![SubscriptionId]
  }
  deriving stock (Eq, Show, Generic)

senderKey :: ObjectName
senderKey = ObjectName "delivery/sender.json"

destinationKey :: SubscriptionId -> ObjectName
destinationKey subscription = ObjectName ("delivery/destinations/" <> subscriptionIdText subscription <> "/head.json")

recordKey :: SubscriptionId -> DeliveryId -> ObjectName
recordKey subscription delivery = ObjectName ("delivery/destinations/" <> subscriptionIdText subscription <> "/deliveries/" <> deliveryIdText delivery <> ".json")

nodeKey :: ContentDigest -> ObjectName
nodeKey digest = ObjectName ("delivery/nodes/" <> digestText digest <> ".json")

-- | A mutable object read with the generation it came with.
data Observed a = Observed
  { value :: !(Maybe a)
  , tag :: !(Maybe Generation)
  }
  deriving stock (Eq, Show, Generic)

observeJson :: (FromJSON a, ToJSON a) => FeedStore -> ObjectName -> IO (Either FeedError (Observed a))
observeJson store name = do
  outcome <- getObject (feedStoreOps store) name
  pure $ case outcome of
    GetUnknown reason -> Left (FeedTransport reason)
    ObjectAbsent -> Right (Observed Nothing Nothing)
    ObjectFound tag' bytes -> (\decoded -> Observed (Just decoded) (Just tag')) <$> decodeObject name bytes

observeSender :: FeedStore -> IO (Either FeedError (Observed SenderHead))
observeSender store = observeJson store senderKey

observeDestination :: FeedStore -> SubscriptionId -> IO (Either FeedError (Observed DestinationHead))
observeDestination store = observeJson store . destinationKey

observeRecordAt :: FeedStore -> ObjectName -> IO (Either FeedError (Observed DeliveryRecord))
observeRecordAt = observeJson

-- | Replace the object read in @observed@ (or create it, if it was absent).
-- Another writer's object is 'Superseded'; equal bytes after a lost
-- acknowledgement are 'Replaced'.
replaceJson :: (ToJSON a) => FeedStore -> ObjectName -> Observed a -> a -> IO (Either FeedError ReplaceOutcome)
replaceJson store name observed replacement = do
  let bytes = canonical (toJSON replacement)
  outcome <- putObject (feedStoreOps store) (maybe IfAbsent IfGenerationMatches (observed ^. #tag)) name bytes
  case outcome of
    PutWritten _ -> pure (Right Replaced)
    PutPreconditionFailed -> pure (Right Superseded)
    PutNoEffect reason -> pure (Left (FeedTransport reason))
    PutUnknown reason -> do
      reread <- getObject (feedStoreOps store) name
      pure $ case reread of
        ObjectFound _ found | found == bytes -> Right Replaced
        ObjectFound _ _ -> Right Superseded
        ObjectAbsent -> Left (FeedTransport reason)
        GetUnknown again -> Left (FeedTransport again)

-- | Create an object that must not exist yet; an existing one is kept.
createJson :: (ToJSON a) => FeedStore -> ObjectName -> a -> IO (Either FeedError ReplaceOutcome)
createJson store name = replaceJson store name (Observed Nothing Nothing)

publishNode :: (ToJSON a) => FeedStore -> a -> IO (Either FeedError ContentDigest)
publishNode store = publishFeedObject store nodeKey . canonical . toJSON

readNode :: (FromJSON a, ToJSON a) => FeedStore -> ContentDigest -> IO (Either FeedError a)
readNode store digest = (>>= decodeObject (nodeKey digest)) <$> readFeedObject store nodeKey digest

newtype Segment = Segment [DeliveryId]

newtype FullSegments = FullSegments [ContentDigest]

-- | Append delivery IDs; only the tail segment and, when a segment fills,
-- the full-segment list are written.
appendLog :: FeedStore -> LogPointer -> [DeliveryId] -> IO (Either FeedError LogPointer)
appendLog _ pointer [] = pure (Right pointer)
appendLog store pointer additions = do
  tailIds <- maybe (pure (Right [])) (fmap (fmap (\(Segment ids) -> ids)) . readNode store) (pointer ^. #lastSegment)
  fullList <- maybe (pure (Right [])) (fmap (fmap (\(FullSegments ds) -> ds)) . readNode store) (pointer ^. #full)
  case (,) <$> tailIds <*> fullList of
    Left err -> pure (Left err)
    Right (kept, listed) -> do
      let (completed, rest) = chunks (kept <> additions)
      written <- traverse (publishNode store . Segment) completed
      case sequence written of
        Left err -> pure (Left err)
        Right digests -> do
          tailDigest <- if null rest then pure (Right Nothing) else fmap Just <$> publishNode store (Segment rest)
          fullDigest <- if null digests then pure (Right (pointer ^. #full)) else fmap Just <$> publishNode store (FullSegments (listed <> digests))
          pure (LogPointer (pointer ^. #count + fromIntegral (length additions)) <$> tailDigest <*> fullDigest)
  where
    chunks ids
      | length ids >= fromIntegral logSegment = let (now, later) = splitAt (fromIntegral logSegment) ids; (more, last') = chunks later in (now : more, last')
      | otherwise = ([], ids)

-- | At most @limit@ delivery IDs from position @from@: the full-segment
-- list and the segments the range touches, never the whole history.
readLog :: FeedStore -> LogPointer -> Integer -> Int -> IO (Either FeedError [(Integer, DeliveryId)])
readLog store pointer from limit
  | from >= pointer ^. #count || limit <= 0 = pure (Right [])
  | otherwise = do
      fullList <- maybe (pure (Right [])) (fmap (fmap (\(FullSegments ds) -> ds)) . readNode store) (pointer ^. #full)
      case fullList of
        Left err -> pure (Left err)
        Right listed -> do
          let wanted = [from `div` logSegment .. min ((pointer ^. #count - 1) `div` logSegment) ((from + fromIntegral limit - 1) `div` logSegment)]
              digestOf k
                | k < fromIntegral (length listed) = Just (listed !! fromIntegral k)
                | otherwise = pointer ^. #lastSegment
          loaded <- traverse (\k -> maybe (pure (Left (FeedInvalid "delivery log" "a segment is missing"))) (fmap (fmap (\(Segment ids) -> zip [k * logSegment ..] ids)) . readNode store) (digestOf k)) wanted
          pure (take limit . dropWhile ((< from) . fst) . concat <$> sequence loaded)

canonical :: Value -> ByteString
canonical = either (error . T.unpack) id . canonicalValue

decodeObject :: (FromJSON a, ToJSON a) => ObjectName -> ByteString -> Either FeedError a
decodeObject (ObjectName name) bytes = do
  decoded <- first (FeedInvalid name . T.pack) (eitherDecodeStrict' bytes)
  unless (canonical (toJSON decoded) == bytes) (Left (FeedInvalid name "not canonical"))
  pure decoded

exactKeys :: String -> [Key] -> Object -> Parser ()
exactKeys label allowed o = unless (all (`elem` allowed) (KM.keys o)) (fail (label <> " has an unknown field"))

versioned :: String -> [Key] -> (Object -> Parser a) -> Value -> Parser a
versioned label allowed parse = withObject label $ \o -> do
  exactKeys label ("version" : allowed) o
  version <- o .: "version"
  unless (version == (1 :: Int)) (fail ("unsupported " <> label <> " version"))
  parse o

instance ToJSON DeliveryId where toJSON = String . deliveryIdText

instance FromJSON DeliveryId where parseJSON = withText "delivery id" (either (fail . T.unpack) pure . mkDeliveryId)

instance ToJSON DeliveryState where
  toJSON = \case
    InFlight token' -> object ["state" .= ("in-flight" :: Text), "token" .= token']
    other -> object ["state" .= deliveryStateText other]

instance FromJSON DeliveryState where
  parseJSON = withObject "delivery state" $ \o -> do
    exactKeys "delivery state" ["state", "token"] o
    name <- o .: "state"
    case name :: Text of
      "in-flight" -> InFlight <$> o .: "token"
      _ -> maybe (fail "unknown delivery state") pure (lookup name [(deliveryStateText s, s) | s <- [Pending, Delivered, Failed, Exhausted, Cancelled]])

instance ToJSON Receipt where toJSON r = object ["kind" .= (r ^. #kind), "version" .= (r ^. #version), "details" .= (r ^. #details)]

instance FromJSON Receipt where parseJSON = withObject "receipt" $ \o -> exactKeys "receipt" ["kind", "version", "details"] o >> (Receipt <$> o .: "kind" <*> o .: "version" <*> o .: "details")

instance ToJSON Attempt where
  toJSON a = object ["number" .= (a ^. #number), "token" .= (a ^. #token), "startedAt" .= (a ^. #startedAt), "outcome" .= (a ^. #outcome), "detail" .= (a ^. #detail), "receipt" .= (a ^. #receipt), "finishedAt" .= (a ^. #finishedAt)]

instance FromJSON Attempt where
  parseJSON = withObject "attempt" $ \o -> do
    exactKeys "attempt" ["number", "token", "startedAt", "outcome", "detail", "receipt", "finishedAt"] o
    Attempt <$> o .: "number" <*> o .: "token" <*> o .: "startedAt" <*> o .:? "outcome" <*> o .:? "detail" <*> o .:? "receipt" <*> o .:? "finishedAt"

instance ToJSON DeliveryRecord where
  toJSON r =
    object
      [ "version" .= (1 :: Int)
      , "delivery" .= (r ^. #delivery)
      , "subscription" .= (r ^. #subscription)
      , "destination" .= (r ^. #destination)
      , "transport" .= (r ^. #transport)
      , "revision" .= (r ^. #revision)
      , "policy" .= (r ^. #policy)
      , "event" .= (r ^. #event)
      , "position" .= (r ^. #position)
      , "cycle" .= (r ^. #deliveryCycle)
      , "state" .= (r ^. #state)
      , "attempts" .= (r ^. #attempts)
      , "createdAt" .= (r ^. #createdAt)
      , "nextAttempt" .= (r ^. #nextAttempt)
      , "reason" .= (r ^. #reason)
      ]

instance FromJSON DeliveryRecord where
  parseJSON = versioned "delivery" ["delivery", "subscription", "destination", "transport", "revision", "policy", "event", "position", "cycle", "state", "attempts", "createdAt", "nextAttempt", "reason"] $ \o ->
    DeliveryRecord 1 <$> o .: "delivery" <*> o .: "subscription" <*> o .: "destination" <*> o .: "transport" <*> o .: "revision" <*> o .: "policy" <*> o .: "event" <*> o .: "position" <*> o .: "cycle" <*> o .: "state" <*> o .: "attempts" <*> o .: "createdAt" <*> o .:? "nextAttempt" <*> o .:? "reason"

instance ToJSON PendingEntry where toJSON e = object ["delivery" .= (e ^. #delivery), "due" .= (e ^. #due)]

instance FromJSON PendingEntry where parseJSON = withObject "pending entry" $ \o -> exactKeys "pending entry" ["delivery", "due"] o >> (PendingEntry <$> o .: "delivery" <*> o .: "due")

instance ToJSON LogPointer where toJSON p = object ["count" .= (p ^. #count), "tail" .= (p ^. #lastSegment), "full" .= (p ^. #full)]

instance FromJSON LogPointer where parseJSON = withObject "delivery log" $ \o -> exactKeys "delivery log" ["count", "tail", "full"] o >> (LogPointer <$> o .: "count" <*> o .:? "tail" <*> o .:? "full")

instance ToJSON Segment where toJSON (Segment ids) = object ["version" .= (1 :: Int), "deliveries" .= ids]

instance FromJSON Segment where parseJSON = versioned "delivery log segment" ["deliveries"] (\o -> Segment <$> o .: "deliveries")

instance ToJSON FullSegments where toJSON (FullSegments ds) = object ["version" .= (1 :: Int), "segments" .= ds]

instance FromJSON FullSegments where parseJSON = versioned "delivery log index" ["segments"] (\o -> FullSegments <$> o .: "segments")

instance ToJSON DestinationHead where
  toJSON h =
    object
      [ "version" .= (1 :: Int)
      , "binding" .= (h ^. #binding)
      , "subscription" .= (h ^. #subscription)
      , "generation" .= (h ^. #generation)
      , "record" .= (h ^. #record)
      , "cursor" .= (h ^. #cursor)
      , "cancelledThrough" .= (h ^. #cancelledThrough)
      , "pending" .= (h ^. #pending)
      , "history" .= (h ^. #history)
      , "diagnostic" .= (h ^. #diagnostic)
      , "refusedReplay" .= (h ^. #refusedReplay)
      ]

instance FromJSON DestinationHead where
  parseJSON = versioned "destination head" ["binding", "subscription", "generation", "record", "cursor", "cancelledThrough", "pending", "history", "diagnostic", "refusedReplay"] $ \o ->
    DestinationHead 1 <$> o .: "binding" <*> o .: "subscription" <*> o .: "generation" <*> o .: "record" <*> o .: "cursor" <*> o .:? "cancelledThrough" <*> o .:? "pending" <*> o .: "history" <*> o .:? "diagnostic" <*> o .:? "refusedReplay"

instance ToJSON SenderHead where
  toJSON h = object ["version" .= (1 :: Int), "binding" .= (h ^. #binding), "generation" .= (h ^. #generation), "controls" .= (h ^. #controls), "destinations" .= (h ^. #destinations)]

instance FromJSON SenderHead where
  parseJSON = versioned "delivery sender" ["binding", "generation", "controls", "destinations"] $ \o ->
    SenderHead 1 <$> o .: "binding" <*> o .: "generation" <*> o .: "controls" <*> o .: "destinations"
