{-# LANGUAGE OverloadedStrings #-}

-- | Reviewed lifecycle event subscriptions (EP-234), transport-neutral
-- (ADR 33). A subscription is one standalone inventory scope whose
-- override @events.subscription@ holds its canonical record: identity,
-- revision, status, exact event types and resource filter, the feed
-- position it starts after, a delivery policy reference and one typed
-- destination. The destination names its transport and carries that
-- transport's settings, which only the transport's adapter decodes; shared
-- code never reads a URL or a signing key.
--
-- Every converged change of the record, and every reviewed replay, is a
-- control fact on the @event-subscriptions@ channel, committed with the
-- convergence (ADR 39), so the sender applies them in committed order even
-- when several finish while it is offline.
module Nagare.Events.Subscription
  ( SubscriptionId
  , mkSubscriptionId
  , subscriptionIdText
  , subscriptionScopeId
  , SubscriptionStatus (..)
  , SubscriptionFilter (..)
  , PolicyRef (..)
  , DestinationSpec (..)
  , Subscription (..)
  , subscriptionRecordVersion
  , encodeSubscription
  , decodeSubscription
  , subscriptionOverride
  , replayOverride
  , Replay (..)
  , encodeReplay
  , decodeReplay
  , SubscriptionControl (..)
  , subscriptionChannel
  , subscriptionProducer
  , decodeSubscriptionControl
  , matchesEvent
  , subscriptionScope
  , acceptedSubscription
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Envelope (Envelope, EventId)
import Nagare.Events.Source
import Nagare.Resource.Inventory (ResourceBundle (..), ScopeDeclaration, ScopeSnapshot, mkScopeDeclaration, scopeOverrides, snapshotScopes, withScopeOverrides)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | Lowercase letters, digits and hyphens, starting with a letter, at most
-- 40 characters: it names the subscription's scope.
newtype SubscriptionId = SubscriptionId Text deriving stock (Eq, Ord, Show)

mkSubscriptionId :: Text -> Either Text SubscriptionId
mkSubscriptionId value
  | T.null value || T.length value > 40 = Left "a subscription name has 1 to 40 characters"
  | not (T.head value >= 'a' && T.head value <= 'z') = Left "a subscription name starts with a lowercase letter"
  | T.all (\c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') value && not ("-" `T.isSuffixOf` value) = Right (SubscriptionId value)
  | otherwise = Left "a subscription name holds only lowercase letters, digits and inner hyphens"

subscriptionIdText :: SubscriptionId -> Text
subscriptionIdText (SubscriptionId value) = value

-- | The standalone scope that holds a subscription.
subscriptionScopeId :: SubscriptionId -> ScopeId
subscriptionScopeId (SubscriptionId value) = either (error . T.unpack) id (mkScopeId Standalone ("events-" <> value))

data SubscriptionStatus = Active | Disabled | Deleted
  deriving stock (Eq, Ord, Show, Bounded, Enum, Generic)

-- | Exact matching: an event matches when its type is listed and, if a
-- scope is named, it is about that scope (and that member, if named).
data SubscriptionFilter = SubscriptionFilter
  { types :: !(Set EventKind)
  , scope :: !(Maybe ScopeId)
  , member :: !(Maybe ResourceId)
  }
  deriving stock (Eq, Show, Generic)

-- | The versioned delivery policy a destination's adapter supplies.
data PolicyRef = PolicyRef
  { name :: !Text
  , version :: !Int
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | One typed destination: a stable identity, its transport and that
-- transport's settings version and settings. Only the adapter registered
-- for the transport decodes @settings@.
data DestinationSpec = DestinationSpec
  { identity :: !Text
  , transport :: !Text
  , version :: !Int
  , settings :: !Value
  }
  deriving stock (Eq, Show, Generic)

data Subscription = Subscription
  { schemaVersion :: !Int
  , subscription :: !SubscriptionId
  , revision :: !Int
  , status :: !SubscriptionStatus
  , selects :: !SubscriptionFilter
  , startAfter :: !Integer
  -- ^ The feed's event count when the creation was reviewed: events at
  -- that position and later are eligible, earlier history is not.
  , policy :: !PolicyRef
  , destination :: !DestinationSpec
  }
  deriving stock (Eq, Show, Generic)

subscriptionRecordVersion :: Int
subscriptionRecordVersion = 1

subscriptionOverride, replayOverride :: Text
subscriptionOverride = "events.subscription"
replayOverride = "events.replay"

encodeSubscription :: Subscription -> Text
encodeSubscription = TE.decodeUtf8 . canonical . toJSON

decodeSubscription :: Text -> Either Text Subscription
decodeSubscription text = first T.pack (eitherDecodeStrict' (TE.encodeUtf8 text))

-- | A reviewed request for a new delivery cycle of one retained event under
-- the subscription revision it was reviewed against.
data Replay = Replay
  { subscription :: !SubscriptionId
  , revision :: !Int
  , event :: !EventId
  , cycleId :: !Text
  }
  deriving stock (Eq, Show, Generic)

encodeReplay :: Replay -> Text
encodeReplay = TE.decodeUtf8 . canonical . toJSON

decodeReplay :: Text -> Either Text Replay
decodeReplay text = first T.pack (eitherDecodeStrict' (TE.encodeUtf8 text))

data SubscriptionControl
  = -- | A converged revision of the record.
    RevisionControl !Subscription
  | ReplayControl !Replay
  deriving stock (Eq, Show)

subscriptionChannel :: ControlChannel
subscriptionChannel = either (error . T.unpack) id (mkControlChannel "event-subscriptions")

-- | The control facts of a converged transaction: one per changed record
-- and one per new replay, in scope order.
subscriptionProducer :: SourceProducer
subscriptionProducer = SourceProducer (const False) [subscriptionOverride, replayOverride] controls
  where
    controls input =
      concat
        [ revisionItem view' <> replayItem view'
        | (_, view') <- Map.toAscList (input ^. #scopes)
        ]
    changed key view' = Map.lookup key (view' ^. #desired) /= (view' ^. #previous >>= Map.lookup key)
    revisionItem view' = case Map.lookup subscriptionOverride (view' ^. #desired) >>= either (const Nothing) Just . decodeSubscription of
      Just record | changed subscriptionOverride view' -> [Control (control ("revision:" <> subscriptionIdText (record ^. #subscription) <> ":" <> T.pack (show (record ^. #revision))) (RevisionControl record))]
      _ -> []
    replayItem view' = case Map.lookup replayOverride (view' ^. #desired) >>= either (const Nothing) Just . decodeReplay of
      Just replay | changed replayOverride view' -> [Control (control ("replay:" <> subscriptionIdText (replay ^. #subscription) <> ":" <> replay ^. #cycleId) (ReplayControl replay))]
      _ -> []
    control key body =
      ControlFact
        { key = either (error . T.unpack) id (mkSourceKey ("event-subscription:" <> key))
        , channel = subscriptionChannel
        , version = 1
        , body = toJSON body
        }

-- | The sender's decoder: it refuses a version it does not read, which
-- stops it before that control rather than skipping it.
decodeSubscriptionControl :: ControlFact -> Either Text SubscriptionControl
decodeSubscriptionControl fact
  | fact ^. #version /= 1 = Left ("unsupported subscription control version " <> T.pack (show (fact ^. #version)))
  | otherwise = case fromJSON (fact ^. #body) of
      Success value -> Right value
      Error err -> Left (T.pack err)

matchesEvent :: SubscriptionFilter -> Envelope -> Bool
matchesEvent selected envelope =
  Set.member (payloadKind (envelope ^. #payload)) (selected ^. #types)
    && maybe True (== envelope ^. #resource . #scope) (selected ^. #scope)
    && maybe True (\wanted -> envelope ^. #resource . #member == Just wanted) (selected ^. #member)

-- | A subscription's scope: no provider member — the record is its
-- declaration, and the sender reads it from the committed control — and
-- the replay it last reviewed, if any.
subscriptionScope :: Subscription -> Maybe Replay -> Either Text ScopeDeclaration
subscriptionScope record replay = do
  base <- first (T.pack . show) (mkScopeDeclaration (subscriptionScopeId (record ^. #subscription)) [ResourceBundle [] [] [] [] [] []])
  pure (withScopeOverrides (Map.fromList ([(subscriptionOverride, encodeSubscription record)] <> [(replayOverride, encodeReplay r) | Just r <- [replay]])) base)

-- | The accepted record of a subscription, and its last reviewed replay.
acceptedSubscription :: ScopeSnapshot -> SubscriptionId -> Either Text (Maybe (Subscription, Maybe Replay))
acceptedSubscription snapshot subscription' = case Map.lookup (subscriptionScopeId subscription') (snapshotScopes snapshot) of
  Nothing -> Right Nothing
  Just (_, scope') -> do
    let fields = scopeOverrides scope'
    record <- maybe (Left "the subscription scope holds no record") decodeSubscription (Map.lookup subscriptionOverride fields)
    replay <- traverse decodeReplay (Map.lookup replayOverride fields)
    pure (Just (record, replay))

canonical :: Value -> ByteString
canonical = either (error . T.unpack) id . canonicalValue

exactKeys :: String -> [Key] -> Object -> Parser ()
exactKeys label allowed o = unless (all (`elem` allowed) (KM.keys o)) (fail (label <> " has an unknown field"))

instance ToJSON SubscriptionId where toJSON = String . subscriptionIdText

instance FromJSON SubscriptionId where parseJSON = withText "subscription" (either (fail . T.unpack) pure . mkSubscriptionId)

statusText :: SubscriptionStatus -> Text
statusText = \case
  Active -> "active"
  Disabled -> "disabled"
  Deleted -> "deleted"

instance ToJSON SubscriptionStatus where toJSON = String . statusText

instance FromJSON SubscriptionStatus where
  parseJSON = withText "subscription status" (\value -> maybe (fail "unknown subscription status") pure (lookup value [(statusText s, s) | s <- [minBound .. maxBound]]))

instance ToJSON SubscriptionFilter where
  toJSON selected = object ["types" .= Set.toAscList (selected ^. #types), "scope" .= (selected ^. #scope), "member" .= (selected ^. #member)]

instance FromJSON SubscriptionFilter where
  parseJSON = withObject "subscription filter" $ \o -> do
    exactKeys "subscription filter" ["types", "scope", "member"] o
    kinds <- o .: "types"
    when (null kinds) (fail "a subscription names at least one event type")
    selected <- SubscriptionFilter (Set.fromList kinds) <$> o .:? "scope" <*> o .:? "member"
    when (isNothing (selected ^. #scope) && isJust (selected ^. #member)) (fail "a member filter needs a scope")
    pure selected

instance ToJSON PolicyRef where toJSON ref = object ["name" .= (ref ^. #name), "version" .= (ref ^. #version)]

instance FromJSON PolicyRef where
  parseJSON = withObject "delivery policy" $ \o -> exactKeys "delivery policy" ["name", "version"] o >> (PolicyRef <$> o .: "name" <*> o .: "version")

instance ToJSON DestinationSpec where
  toJSON spec = object ["id" .= (spec ^. #identity), "transport" .= (spec ^. #transport), "version" .= (spec ^. #version), "settings" .= (spec ^. #settings)]

instance FromJSON DestinationSpec where
  parseJSON = withObject "destination" $ \o -> do
    exactKeys "destination" ["id", "transport", "version", "settings"] o
    DestinationSpec <$> o .: "id" <*> o .: "transport" <*> o .: "version" <*> o .: "settings"

instance ToJSON Subscription where
  toJSON record =
    object
      [ "version" .= (record ^. #schemaVersion)
      , "subscription" .= (record ^. #subscription)
      , "revision" .= (record ^. #revision)
      , "status" .= (record ^. #status)
      , "filter" .= (record ^. #selects)
      , "startAfter" .= (record ^. #startAfter)
      , "policy" .= (record ^. #policy)
      , "destination" .= (record ^. #destination)
      ]

instance FromJSON Subscription where
  parseJSON = withObject "subscription" $ \o -> do
    exactKeys "subscription" ["version", "subscription", "revision", "status", "filter", "startAfter", "policy", "destination"] o
    version <- o .: "version"
    unless (version == subscriptionRecordVersion) (fail "unsupported subscription record version")
    record <- Subscription version <$> o .: "subscription" <*> o .: "revision" <*> o .: "status" <*> o .: "filter" <*> o .: "startAfter" <*> o .: "policy" <*> o .: "destination"
    unless (record ^. #revision >= 1 && record ^. #startAfter >= 0) (fail "a subscription revision starts at 1 and its start position is not negative")
    pure record

instance ToJSON Replay where
  toJSON replay = object ["subscription" .= (replay ^. #subscription), "revision" .= (replay ^. #revision), "event" .= (replay ^. #event), "cycle" .= (replay ^. #cycleId)]

instance FromJSON Replay where
  parseJSON = withObject "replay" $ \o -> do
    exactKeys "replay" ["subscription", "revision", "event", "cycle"] o
    Replay <$> o .: "subscription" <*> o .: "revision" <*> o .: "event" <*> o .: "cycle"

instance ToJSON SubscriptionControl where
  toJSON = \case
    RevisionControl record -> object ["kind" .= ("revision" :: Text), "subscription" .= record]
    ReplayControl replay -> object ["kind" .= ("replay" :: Text), "replay" .= replay]

instance FromJSON SubscriptionControl where
  parseJSON = withObject "subscription control" $ \o -> do
    kind <- o .: "kind"
    case kind :: Text of
      "revision" -> exactKeys "subscription control" ["kind", "subscription"] o >> (RevisionControl <$> o .: "subscription")
      "replay" -> exactKeys "subscription control" ["kind", "replay"] o >> (ReplayControl <$> o .: "replay")
      _ -> fail "unknown subscription control"
