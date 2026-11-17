-- | @nagarectl events webhook@, @events delivery replay@ and the
-- transport-neutral inspection commands (EP-234). Every change saves an
-- inventory review of the subscription's standalone scope; no command
-- mutates delivery state or calls a receiver.
module Nagare.Cli.Commands.EventsWebhook
  ( runEventsWebhook
  , runEventsDelivery
  , runEventsSubscription
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Options.Events
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Dsl.Prelude
import Nagare.Events.Delivery.Store
import Nagare.Events.Envelope (mkEventId)
import Nagare.Events.Read (readEvent)
import Nagare.Events.Source (EventKind, eventKindText, parseEventKind)
import Nagare.Events.Store (FeedError (FeedNotEnabled), FeedStore, readFeedHead)
import Nagare.Events.Subscription
import Nagare.Events.Target (openTargetFeedReadOnly, targetBinding)
import Nagare.Events.Webhook.Policy (webhookPolicy)
import Nagare.Events.Webhook.Subscription
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types
import Nagare.Target (ActiveTarget)

runEventsWebhook :: Maybe String -> EventsWebhookCommand -> IO ()
runEventsWebhook mctx = \case
  WebhookCreate options -> do
    active <- activeTarget mctx
    subscription' <- refuse (mkSubscriptionId (T.pack (options ^. #name)))
    snapshot <- Inventory.loadTargetSnapshotReadOnly active
    existing <- refuse (acceptedSubscription snapshot subscription')
    when (isJust existing) (dieT ("nagarectl: events webhook create: subscription " <> subscriptionIdText subscription' <> " exists; review a change with events webhook update"))
    selects <- refuse (filterFrom (options ^. #types) (options ^. #scope) (options ^. #member))
    (namespace', secret') <- refuse (secretRef (options ^. #signingSecret))
    let settings' = WebhookSettings (T.pack (options ^. #url)) (map (T.toLower . T.pack) (options ^. #allowHosts)) [SecretKeyRef (T.pack (options ^. #keyId)) namespace' secret' (T.pack (options ^. #signingKey))]
    destination' <- refuse (webhookDestination subscription' settings')
    -- New subscriptions start after the feed's current high-water mark.
    startAfter' <- feedCount active
    let record = Subscription subscriptionRecordVersion subscription' 1 Active selects startAfter' (webhookPolicy ^. #ref) destination'
    saveReview active snapshot record Nothing (options ^. #savePlan)
  WebhookUpdate options -> do
    active <- activeTarget mctx
    (snapshot, record, replay) <- accepted active (options ^. #name)
    settings' <- refuse (decodeWebhookSettings (record ^. #destination))
    selects <-
      if null (options ^. #types)
        then pure (record ^. #selects)
        else refuse (filterFrom (options ^. #types) (scopeArg (record ^. #selects)) (memberArg (record ^. #selects)))
    signing' <- refuse (rotate (options ^. #rotateKey) (options ^. #retireKey) (settings' ^. #signing))
    let changed =
          settings'
            & #url
            .~ maybe (settings' ^. #url) T.pack (options ^. #url)
            & #allowHosts
            .~ (if null (options ^. #allowHosts) then settings' ^. #allowHosts else map (T.toLower . T.pack) (options ^. #allowHosts))
            & #signing
            .~ signing'
    destination' <- refuse (webhookDestination (record ^. #subscription) changed)
    when (record ^. #status == Deleted) (dieT "nagarectl: events webhook update: the subscription is deleted")
    let status' = if options ^. #enable then Active else record ^. #status
        next = record & #revision %~ (+ 1) & #selects .~ selects & #destination .~ destination' & #status .~ status'
    when ((next & #revision .~ record ^. #revision) == record) (dieT "nagarectl: events webhook update: nothing changes")
    saveReview active snapshot next replay (options ^. #savePlan)
  WebhookDisable name' output -> statusChange name' Disabled output
  WebhookDelete name' output -> statusChange name' Deleted output
  where
    statusChange name' status' output = do
      active <- activeTarget mctx
      (snapshot, record, replay) <- accepted active name'
      when (record ^. #status == status') (dieT ("nagarectl: events webhook: the subscription is already " <> statusText status'))
      saveReview active snapshot (record & #revision %~ (+ 1) & #status .~ status') replay output
    rotate rotation retirement current = do
      added <- case rotation of
        Nothing -> Right current
        Just text -> case T.splitOn ":" (T.pack text) of
          [ref, field, kid] -> do
            (namespace', secret') <- secretRef (T.unpack ref)
            Right (SecretKeyRef kid namespace' secret' field : take 1 current)
          _ -> Left "--rotate-key is NAMESPACE/NAME:FIELD:ID"
      case retirement of
        Nothing -> Right added
        Just kid -> do
          let kept = [key | key <- added, key ^. #keyId /= T.pack kid]
          when (length kept == length added) (Left ("no signing key has ID " <> T.pack kid))
          Right kept

runEventsDelivery :: Maybe String -> EventsDeliveryCommand -> IO ()
runEventsDelivery mctx = \case
  DeliveryReplay name' eventText output -> do
    active <- activeTarget mctx
    (snapshot, record, _) <- accepted active name'
    unless (record ^. #status == Active) (dieT "nagarectl: events delivery replay: only an active subscription replays")
    event <- refuse (mkEventId (T.pack eventText))
    feed <- openTargetFeedReadOnly active >>= either dieT pure
    binding <- refuse (targetBinding active)
    found <- readEvent feed binding event >>= either (dieT . T.pack . show) pure
    when (isNothing (fst found)) (dieT ("nagarectl: events delivery replay: the feed holds no event " <> T.pack eventText))
    stamp <- T.pack . formatTime defaultTimeLocale "%Y%m%dt%H%M%S" <$> getCurrentTime
    saveReview active snapshot record (Just (Replay (record ^. #subscription) (record ^. #revision) event ("replay-" <> stamp))) output
  DeliveryList name' after first' _ -> do
    active <- activeTarget mctx
    subscription' <- refuse (mkSubscriptionId (T.pack name'))
    (feed, headValue) <- destinationOf active subscription'
    let size = maybe 50 (max 1 . min 100) first'
        from = maybe 0 (+ 1) after
    page <- readLog feed (headValue ^. #history) from size >>= either (dieT . T.pack . show) pure
    records <- traverse (\(n, delivery') -> (,) n <$> recordOf feed subscription' delivery') page
    TIO.putStr (T.unlines [T.intercalate "  " [T.pack (show n), deliveryIdText (r ^. #delivery), deliveryStateText (r ^. #state), r ^. #transport, "revision " <> T.pack (show (r ^. #revision)), r ^. #deliveryCycle, T.pack (show (length (r ^. #attempts))) <> " attempts"] | (n, Just r) <- records])
    when (from + fromIntegral size < headValue ^. #history . #count) (TIO.putStrLn ("more: --after " <> T.pack (show (from + fromIntegral size - 1))))
  DeliveryInspect deliveryText _ -> do
    active <- activeTarget mctx
    delivery' <- refuse (mkDeliveryId (T.pack deliveryText))
    feed <- openTargetFeedReadOnly active >>= either dieT pure
    sender <- observeSender feed >>= either (dieT . T.pack . show) pure
    found <- traverse (\s -> recordOf feed s delivery') (maybe [] (^. #destinations) (sender ^. #value))
    case [r | Just r <- found] of
      record : _ -> TIO.putStr (renderRecord record)
      [] -> dieT ("nagarectl: events delivery inspect: no delivery " <> T.pack deliveryText)

runEventsSubscription :: Maybe String -> EventsSubscriptionCommand -> IO ()
runEventsSubscription mctx = \case
  SubscriptionList _ -> do
    active <- activeTarget mctx
    snapshot <- Inventory.loadTargetSnapshotReadOnly active
    let records = [record | (_, scope') <- Map.elems (ResourceInventory.snapshotScopes snapshot), Just text <- [Map.lookup subscriptionOverride (ResourceInventory.scopeOverrides scope')], Right record <- [decodeSubscription text]]
    TIO.putStr (T.unlines [T.intercalate "  " [subscriptionIdText (r ^. #subscription), statusText (r ^. #status), r ^. #destination . #transport, "revision " <> T.pack (show (r ^. #revision))] | r <- records])
  SubscriptionInspect name' _ -> do
    active <- activeTarget mctx
    (_, record, _) <- accepted active name'
    feed <- openTargetFeedReadOnly active >>= either dieT pure
    observed <- observeDestination feed (record ^. #subscription) >>= either (dieT . T.pack . show) pure
    TIO.putStr . T.unlines $
      [ "subscription " <> subscriptionIdText (record ^. #subscription) <> ", revision " <> T.pack (show (record ^. #revision)) <> ", " <> statusText (record ^. #status)
      , "transport " <> record ^. #destination . #transport <> ", destination " <> record ^. #destination . #identity
      , "types " <> T.intercalate "," (map eventKindLabel (Set.toAscList (record ^. #selects . #types)))
      , "starts after event " <> T.pack (show (record ^. #startAfter))
      ]
        <> case observed ^. #value of
          Nothing -> ["sender: not yet applied"]
          Just headValue ->
            [ "sender: revision " <> T.pack (show (headValue ^. #record . #revision)) <> ", matched up to event " <> T.pack (show (headValue ^. #cursor)) <> ", " <> T.pack (show (headValue ^. #history . #count)) <> " deliveries"
            ]
              <> ["paused: " <> d | Just d <- [headValue ^. #diagnostic]]
              <> ["replay refused: " <> d | Just d <- [headValue ^. #refusedReplay]]

-- * Shared

refuse :: Either Text a -> IO a
refuse = either (dieT . ("nagarectl: events: " <>)) pure

accepted :: ActiveTarget -> String -> IO (ResourceInventory.ScopeSnapshot, Subscription, Maybe Replay)
accepted active name' = do
  subscription' <- refuse (mkSubscriptionId (T.pack name'))
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  found <- refuse (acceptedSubscription snapshot subscription')
  case found of
    Nothing -> dieT ("nagarectl: events: no subscription " <> subscriptionIdText subscription' <> " is accepted")
    Just (record, replay) -> pure (snapshot, record, replay)

-- | Save the review of a subscription's scope and show what it activates.
saveReview :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> Subscription -> Maybe Replay -> FilePath -> IO ()
saveReview active snapshot record replay output = do
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  scope' <- refuse (subscriptionScope record replay)
  candidate <- either (dieT . T.pack . show) pure (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope' NE.:| []))
  Inventory.planInventoryCandidateWith (inventoryPlanRegistryWithNative active workspace Map.empty) active candidate output
  TIO.putStr . T.unlines $
    [ "subscription " <> subscriptionIdText (record ^. #subscription) <> ", revision " <> T.pack (show (record ^. #revision)) <> ", " <> statusText (record ^. #status)
    , "types " <> T.intercalate "," (map eventKindLabel (Set.toAscList (record ^. #selects . #types))) <> maybe "" (\s -> ", scope " <> scopeIdText s) (record ^. #selects . #scope)
    , "starts after event " <> T.pack (show (record ^. #startAfter))
    ]
      <> case decodeWebhookSettings (record ^. #destination) of
        Right settings' ->
          ["webhook " <> settings' ^. #url]
            <> ["signing key " <> key ^. #keyId <> " from Secret " <> key ^. #namespace <> "/" <> key ^. #secret <> " field " <> key ^. #key | key <- settings' ^. #signing]
        Left _ -> []
      <> ["replay " <> r ^. #cycleId <> " of event " <> T.pack (show (r ^. #event)) | Just r <- [replay]]

filterFrom :: [String] -> Maybe String -> Maybe String -> Either Text SubscriptionFilter
filterFrom types' scopeText memberText = do
  kinds <- traverse (\t -> maybe (Left ("unknown event type " <> T.pack t)) Right (parseEventKind (T.pack t))) types'
  when (null kinds) (Left "name at least one --type")
  scope' <- traverse (parseScopeArg . T.pack) scopeText
  member' <- traverse (mkResourceId . T.pack) memberText
  when (isNothing scope' && isJust member') (Left "--member needs --scope")
  pure (SubscriptionFilter (Set.fromList kinds) scope' member')

scopeArg :: SubscriptionFilter -> Maybe String
scopeArg selects = T.unpack . scopeIdText <$> selects ^. #scope

memberArg :: SubscriptionFilter -> Maybe String
memberArg selects = T.unpack . resourceIdText <$> selects ^. #member

secretRef :: String -> Either Text (Text, Text)
secretRef text = case T.splitOn "/" (T.pack text) of
  [namespace', name'] | not (T.null namespace') && not (T.null name') -> Right (namespace', name')
  _ -> Left "--signing-secret is NAMESPACE/NAME"

feedCount :: ActiveTarget -> IO Integer
feedCount active = do
  feed <- openTargetFeedReadOnly active >>= either dieT pure
  binding <- refuse (targetBinding active)
  readFeedHead feed binding >>= \case
    Right headValue -> pure (headValue ^. #count)
    Left FeedNotEnabled -> pure 0
    Left err -> dieT ("nagarectl: events: the feed cannot be read: " <> T.pack (show err))

destinationOf :: ActiveTarget -> SubscriptionId -> IO (FeedStore, DestinationHead)
destinationOf active subscription' = do
  feed <- openTargetFeedReadOnly active >>= either dieT pure
  observed <- observeDestination feed subscription' >>= either (dieT . T.pack . show) pure
  maybe (dieT ("nagarectl: events: the sender has not applied subscription " <> subscriptionIdText subscription' <> " yet")) (pure . (,) feed) (observed ^. #value)

recordOf :: FeedStore -> SubscriptionId -> DeliveryId -> IO (Maybe DeliveryRecord)
recordOf feed subscription' delivery' = do
  observed <- observeRecordAt feed (recordKey subscription' delivery')
  pure (either (const Nothing) (^. #value) observed)

renderRecord :: DeliveryRecord -> Text
renderRecord r =
  T.unlines $
    [ "delivery " <> deliveryIdText (r ^. #delivery) <> ", " <> deliveryStateText (r ^. #state)
    , "subscription " <> subscriptionIdText (r ^. #subscription) <> ", revision " <> T.pack (show (r ^. #revision)) <> ", transport " <> r ^. #transport <> ", policy " <> r ^. #policy
    , "event " <> T.pack (show (r ^. #event)) <> " at position " <> T.pack (show (r ^. #position)) <> ", cycle " <> r ^. #deliveryCycle
    ]
      <> ["reason: " <> why | Just why <- [r ^. #reason]]
      <> ["next attempt " <> T.pack (show at) | Just at <- [r ^. #nextAttempt]]
      <> ["attempt " <> T.pack (show (a ^. #number)) <> " " <> T.pack (show (a ^. #startedAt)) <> " " <> fromMaybe "no outcome" (a ^. #outcome) <> maybe "" (": " <>) (a ^. #detail) | a <- r ^. #attempts]

statusText :: SubscriptionStatus -> Text
statusText = \case
  Active -> "active"
  Disabled -> "disabled"
  Deleted -> "deleted"

eventKindLabel :: EventKind -> Text
eventKindLabel = eventKindText
