{-# LANGUAGE OverloadedStrings #-}

-- | The shared lifecycle delivery engine (EP-234, ADR 33). It applies the
-- committed subscription controls in journal order, matches each
-- destination's eligible feed events into durable deliveries before its
-- cursor passes them, and publishes due deliveries through the adapter
-- registered for the destination's transport. It knows outcomes, never
-- HTTP: a transport's adapter classifies its own results and supplies its
-- retry policy.
--
-- Delivery is at least once. A delivery is recorded before anything is
-- sent; an attempt's intent, under a fresh token, is recorded before the
-- external call and its outcome after it, conditionally on that token, so a
-- stale worker's outcome never overwrites a later attempt. A worker that
-- dies between the two leaves an attempt with no outcome, which a later
-- cycle closes as unknown and retries under the same event and delivery
-- IDs: the receiver deduplicates. Each destination has its own head,
-- cursor, pending work and attempts; one that is failing, paused or slow
-- never holds back another, and no inventory claim is held while sending.
module Nagare.Events.Delivery
  ( DeliveryEnv (..)
  , DeliveryBudget (..)
  , defaultDeliveryBudget
  , DeliveryError (..)
  , ControlOutcome (..)
  , DestinationOutcome (..)
  , enableDelivery
  , applyControls
  , deliverDestination
  , deliverOnce
  )
where

import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (SomeAsyncException, SomeException, bracket_, displayException, fromException, throwIO, try)
import Control.Monad (mfilter)
import Data.Generics.Labels ()
import Data.List (nub, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime)
import Nagare.Dsl.Prelude
import Nagare.Events.Delivery.Store
import Nagare.Events.Delivery.Transport
import Nagare.Events.Envelope (EventId, encodeEnvelope, eventIdText)
import Nagare.Events.Read
import Nagare.Events.Source
import Nagare.Events.Store
import Nagare.Events.Subscription
import Nagare.Inventory.Store (InventoryStore)
import Nagare.Resource.Types
import System.Timeout (timeout)

data DeliveryEnv = DeliveryEnv
  { inventory :: !InventoryStore
  , feed :: !FeedStore
  , binding :: !ContextBinding
  , registry :: !AdapterRegistry
  , clock :: !(IO UTCTime)
  , random :: !(IO Double)
  -- ^ A fraction in [0, 1) for retry jitter.
  , token :: !(IO Text)
  -- ^ A fresh attempt token.
  , budget :: !DeliveryBudget
  }
  deriving stock (Generic)

-- | Per cycle: journal events read for controls, feed positions scanned and
-- attempts made per destination, destinations served at once, pending
-- deliveries one destination holds before it stops matching more, and how
-- long an attempt with no outcome stays in flight before it is unknown.
data DeliveryBudget = DeliveryBudget
  { controls :: !Int
  , scan :: !Int
  , sends :: !Int
  , concurrency :: !Int
  , pendingBound :: !Int
  , staleAfter :: !NominalDiffTime
  }
  deriving stock (Eq, Show, Generic)

defaultDeliveryBudget :: DeliveryBudget
defaultDeliveryBudget = DeliveryBudget 500 200 10 4 1000 120

data DeliveryError
  = DeliveryNotEnabled
  | DeliveryFeed !FeedError
  | DeliverySource !SourceChainError
  | DeliveryContended
  | UnknownDestination !SubscriptionId
  deriving stock (Eq, Show)

data ControlOutcome = ControlOutcome
  { applied :: !Int
  , refused :: !(Maybe Text)
  , checkpoint :: !SourceCheckpoint
  }
  deriving stock (Eq, Show, Generic)

data DestinationOutcome = DestinationOutcome
  { subscription :: !SubscriptionId
  , matched :: !Int
  , attempted :: !Int
  , acknowledged :: !Int
  , pendingCount :: !Int
  , diagnostic :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | Start delivery for a context. Its controls are read from the journal's
-- start, so no subscription that ever converged is missed.
enableDelivery :: DeliveryEnv -> IO (Either DeliveryError SenderHead)
enableDelivery env = do
  observed <- observeSender (env ^. #feed)
  case observed of
    Left err -> pure (Left (DeliveryFeed err))
    Right current | Just headValue <- current ^. #value -> pure (Right headValue)
    Right current -> do
      let headValue = SenderHead 1 (env ^. #binding) 0 initialCheckpoint []
      replaced <- replaceJson (env ^. #feed) senderKey current headValue
      pure $ case replaced of
        Left err -> Left (DeliveryFeed err)
        Right _ -> Right headValue

-- | Apply the committed controls after the sender's checkpoint, in order,
-- then advance it. Each control is applied to its destination's head
-- idempotently (an applied revision, an existing replay delivery), so a
-- crash before the checkpoint moves only repeats harmless work.
applyControls :: DeliveryEnv -> IO (Either DeliveryError ControlOutcome)
applyControls env = attempt' (3 :: Int)
  where
    attempt' remaining = do
      observed <- observeSender (env ^. #feed)
      case observed of
        Left err -> pure (Left (DeliveryFeed err))
        Right current -> case current ^. #value of
          Nothing -> pure (Left DeliveryNotEnabled)
          Just sender -> do
            chain <- readSourceChain (env ^. #inventory) (sender ^. #controls) (env ^. #budget . #controls)
            case chain of
              Left err -> pure (Left (DeliverySource err))
              Right batch -> do
                let step = consumeControls subscriptionChannel decodeSubscriptionControl batch
                results <- traverse (applyControl env) (step ^. #accepted)
                case sequence results of
                  Left err -> pure (Left err)
                  Right touched -> do
                    let known = nub (sender ^. #destinations <> touched)
                        replacement = sender & #generation .~ sender ^. #generation + 1 & #controls .~ step ^. #checkpoint & #destinations .~ known
                        outcome = ControlOutcome (length touched) (fmap (\(key, reason) -> sourceKeyText key <> ": " <> reason) (step ^. #refused)) (step ^. #checkpoint)
                    if (replacement & #generation .~ sender ^. #generation) == sender
                      then pure (Right outcome)
                      else do
                        replaced <- replaceJson (env ^. #feed) senderKey current replacement
                        case replaced of
                          Left err -> pure (Left (DeliveryFeed err))
                          Right Replaced -> pure (Right outcome)
                          Right Superseded
                            | remaining > 1 -> attempt' (remaining - 1)
                            | otherwise -> pure (Left DeliveryContended)

-- | One control, applied to its destination's head. Returns the destination.
applyControl :: DeliveryEnv -> SubscriptionControl -> IO (Either DeliveryError SubscriptionId)
applyControl env = \case
  RevisionControl record -> (record ^. #subscription <$) <$> applyRevision env record
  ReplayControl replay -> (replay ^. #subscription <$) <$> applyReplay env replay

applyRevision :: DeliveryEnv -> Subscription -> IO (Either DeliveryError ())
applyRevision env record = withHead env (record ^. #subscription) True $ \current now -> case current of
  Nothing -> pure (Right (Just (DestinationHead 1 (env ^. #binding) (record ^. #subscription) 0 record (record ^. #startAfter) Nothing Nothing emptyLog Nothing Nothing)))
  Just headValue
    | headValue ^. #record . #revision >= record ^. #revision -> pure (Right Nothing)
    | otherwise -> do
        let old = headValue ^. #record
            redirect = redirectsUnder (env ^. #registry) (old ^. #destination) (record ^. #destination) || old ^. #selects /= record ^. #selects
            moved = headValue & #record .~ record & #diagnostic .~ Nothing
        if not redirect
          then pure (Right (Just moved))
          else do
            -- The boundary: what the old revision had not matched by now is
            -- cancelled, its unsent deliveries too; later events use the new.
            count <- either (const 0) (^. #count) <$> readFeedHead (env ^. #feed) (env ^. #binding)
            pendingEntries <- loadPending env headValue
            case pendingEntries of
              Left err -> pure (Left err)
              Right entries -> do
                kept <- traverse (cancelIfUnsent env (record ^. #subscription) now ("revision " <> T.pack (show (record ^. #revision)) <> " changed the destination or filter")) entries
                case sequence kept of
                  Left err -> pure (Left err)
                  Right survivors -> do
                    node <- pendingNode env [entry | Just entry <- survivors]
                    pure ((\digest -> Just (moved & #cursor .~ max (headValue ^. #cursor) count & #cancelledThrough ?~ count & #pending .~ digest)) <$> node)

applyReplay :: DeliveryEnv -> Replay -> IO (Either DeliveryError ())
applyReplay env replay = withHead env (replay ^. #subscription) False $ \current now -> case current of
  Nothing -> pure (Right Nothing)
  Just headValue
    | headValue ^. #record . #revision /= replay ^. #revision || headValue ^. #record . #status /= Active ->
        pure (Right (Just (headValue & #refusedReplay ?~ ("replay " <> replay ^. #cycleId <> " was reviewed against revision " <> T.pack (show (replay ^. #revision)) <> "; the subscription is now at revision " <> T.pack (show (headValue ^. #record . #revision)) <> " (" <> statusLabel (headValue ^. #record . #status) <> "); review the replay again"))))
    | otherwise -> do
        found <- readEvent (env ^. #feed) (env ^. #binding) (replay ^. #event)
        case found of
          Left err -> pure (Left (DeliveryFeed err))
          Right (Nothing, _) -> pure (Right (Just (headValue & #refusedReplay ?~ ("replay " <> replay ^. #cycleId <> " names event " <> eventIdText (replay ^. #event) <> ", which the feed does not hold"))))
          Right (Just entry, _) -> do
            created <- ensureDelivery env headValue now (replay ^. #cycleId) (replay ^. #event) (entry ^. #position)
            case created of
              Left err -> pure (Left err)
              -- Already applied: only a stale refusal report is cleared.
              Right Nothing -> pure (Right (if isNothing (headValue ^. #refusedReplay) then Nothing else Just (headValue & #refusedReplay .~ Nothing)))
              Right (Just added) -> fmap (fmap (#refusedReplay .~ Nothing)) <$> addPending env headValue [added] [added ^. #delivery]

-- | Read, change and replace one destination's head, rereading and
-- reapplying when another writer replaced it first.
withHead :: DeliveryEnv -> SubscriptionId -> Bool -> (Maybe DestinationHead -> UTCTime -> IO (Either DeliveryError (Maybe DestinationHead))) -> IO (Either DeliveryError ())
withHead env subscription' mayCreate change = go (3 :: Int)
  where
    go remaining = do
      observed <- observeDestination (env ^. #feed) subscription'
      now <- env ^. #clock
      case observed of
        Left err -> pure (Left (DeliveryFeed err))
        Right current
          | isNothing (current ^. #value) && not mayCreate -> pure (Right ())
          | otherwise -> do
              changed <- change (current ^. #value) now
              case changed of
                Left err -> pure (Left err)
                Right Nothing -> pure (Right ())
                Right (Just replacement) -> do
                  let next = replacement & #generation .~ maybe 0 ((+ 1) . (^. #generation)) (current ^. #value)
                  replaced <- replaceJson (env ^. #feed) (destinationKey subscription') current next
                  case replaced of
                    Left err -> pure (Left (DeliveryFeed err))
                    Right Replaced -> pure (Right ())
                    Right Superseded
                      | remaining > 1 -> go (remaining - 1)
                      | otherwise -> pure (Left DeliveryContended)

loadPending :: DeliveryEnv -> DestinationHead -> IO (Either DeliveryError [PendingEntry])
loadPending env headValue = maybe (pure (Right [])) (fmap (first DeliveryFeed) . readNode (env ^. #feed)) (headValue ^. #pending)

pendingNode :: DeliveryEnv -> [PendingEntry] -> IO (Either DeliveryError (Maybe ContentDigest))
pendingNode _ [] = pure (Right Nothing)
pendingNode env entries = first DeliveryFeed . fmap Just <$> publishNode (env ^. #feed) (sortOn (\entry -> (entry ^. #due, entry ^. #delivery)) entries)

-- | Add deliveries not already pending to the head's pending work, and the
-- given IDs to its log.
addPending :: DeliveryEnv -> DestinationHead -> [PendingEntry] -> [DeliveryId] -> IO (Either DeliveryError (Maybe DestinationHead))
addPending env headValue added logged = do
  existing <- loadPending env headValue
  case existing of
    Left err -> pure (Left err)
    Right entries -> do
      let present = Set.fromList (map (^. #delivery) entries)
          fresh = [entry | entry <- added, Set.notMember (entry ^. #delivery) present]
      if null fresh
        then pure (Right Nothing)
        else do
          node <- pendingNode env (entries <> fresh)
          logged' <- first DeliveryFeed <$> appendLog (env ^. #feed) (headValue ^. #history) [d | d <- logged, Set.notMember d present]
          pure ((\digest pointer -> Just (headValue & #pending .~ digest & #history .~ pointer)) <$> node <*> logged')

-- | The delivery of an event in a cycle, created when absent. Its pending
-- entry is returned while the delivery is still pending, so a control or
-- scan reapplied after a crash adds it once and never re-adds finished work.
ensureDelivery :: DeliveryEnv -> DestinationHead -> UTCTime -> Text -> EventId -> Integer -> IO (Either DeliveryError (Maybe PendingEntry))
ensureDelivery env headValue now cycle' event position' = do
  let record = headValue ^. #record
      delivery' = deliveryIdFor (record ^. #subscription) (record ^. #destination . #identity) event cycle'
      key = recordKey (record ^. #subscription) delivery'
      fresh =
        DeliveryRecord
          { schemaVersion = 1
          , delivery = delivery'
          , subscription = record ^. #subscription
          , destination = record ^. #destination . #identity
          , transport = record ^. #destination . #transport
          , revision = record ^. #revision
          , policy = record ^. #policy . #name <> "/" <> T.pack (show (record ^. #policy . #version))
          , event
          , position = position'
          , deliveryCycle = cycle'
          , state = Pending
          , attempts = []
          , createdAt = now
          , nextAttempt = Just now
          , reason = Nothing
          }
  created <- createJson (env ^. #feed) key fresh
  case created of
    Left err -> pure (Left (DeliveryFeed err))
    Right Replaced -> pure (Right (Just (PendingEntry delivery' now)))
    Right Superseded -> do
      existing <- observeRecordAt (env ^. #feed) key
      pure $ case existing of
        Left err -> Left (DeliveryFeed err)
        Right observed -> case observed ^. #value of
          Just found | found ^. #state == Pending -> Right (Just (PendingEntry delivery' (fromMaybe now (found ^. #nextAttempt))))
          _ -> Right Nothing

-- | Cancel a pending delivery that has not been sent; one in flight is kept
-- and reported as it completes.
cancelIfUnsent :: DeliveryEnv -> SubscriptionId -> UTCTime -> Text -> PendingEntry -> IO (Either DeliveryError (Maybe PendingEntry))
cancelIfUnsent env subscription' _ why entry = do
  let key = recordKey subscription' (entry ^. #delivery)
  observed <- observeRecordAt (env ^. #feed) key
  case observed of
    Left err -> pure (Left (DeliveryFeed err))
    Right current -> case current ^. #value of
      Just record | record ^. #state == Pending -> do
        replaced <- replaceJson (env ^. #feed) key current (record & #state .~ Cancelled & #nextAttempt .~ Nothing & #reason ?~ why)
        pure $ case replaced of
          Left err -> Left (DeliveryFeed err)
          Right Replaced -> Right Nothing
          Right Superseded -> Right (Just entry)
      Just record | isInFlight (record ^. #state) -> pure (Right (Just entry))
      _ -> pure (Right Nothing)

isInFlight :: DeliveryState -> Bool
isInFlight = \case
  InFlight _ -> True
  _ -> False

statusLabel :: SubscriptionStatus -> Text
statusLabel = \case
  Active -> "active"
  Disabled -> "disabled"
  Deleted -> "deleted"

-- | One destination's cycle: match the feed after its cursor, attempt its
-- due deliveries one at a time, and record both in one head replacement.
deliverDestination :: DeliveryEnv -> SubscriptionId -> IO (Either DeliveryError DestinationOutcome)
deliverDestination env subscription' = do
  observed <- observeDestination (env ^. #feed) subscription'
  case observed of
    Left err -> pure (Left (DeliveryFeed err))
    Right current -> case current ^. #value of
      Nothing -> pure (Left (UnknownDestination subscription'))
      Just headValue
        | headValue ^. #record . #status /= Active -> idle headValue (headValue ^. #diagnostic)
        | otherwise -> do
            bound <- bindAdapter (env ^. #registry) (headValue ^. #record . #destination)
            case bound of
              Left reason -> do
                -- A destination that cannot be bound is paused with its reason.
                _ <- withHead env subscription' False (\fresh _ -> pure (Right ((#diagnostic ?~ reason) <$> mfilter ((/= Just reason) . (^. #diagnostic)) fresh)))
                idle headValue (Just reason)
              Right adapter -> serve headValue adapter
  where
    idle headValue reason = do
      entries <- loadPending env headValue
      pure (either Left (\pending' -> Right (DestinationOutcome subscription' 0 0 0 (length pending') reason)) entries)
    serve headValue adapter = do
      now <- env ^. #clock
      entries <- loadPending env headValue
      feedHead <- readFeedHead (env ^. #feed) (env ^. #binding)
      case (,) <$> entries <*> first DeliveryFeed feedHead of
        Left err -> pure (Left err)
        Right (pending', feedValue) -> do
          scanned <- scanFeed headValue feedValue pending' now
          case scanned of
            Left err -> pure (Left err)
            Right (cursor', added) -> do
              let candidates = sortOn (^. #due) (pending' <> [entry | entry <- added, entry ^. #delivery `notElem` map (^. #delivery) pending'])
                  due = take (env ^. #budget . #sends) [entry | entry <- candidates, entry ^. #due <= now]
              results <- traverse (attemptOne adapter headValue feedValue) due
              case sequence results of
                Left err -> pure (Left err)
                Right outcomes -> do
                  let finished = Set.fromList [entry ^. #delivery | (entry, Done _) <- zip due outcomes]
                      moved = Map.fromList [(entry ^. #delivery, at) | (entry, Later at) <- zip due outcomes]
                      remaining' = [maybe entry (\at -> entry & #due .~ at) (Map.lookup (entry ^. #delivery) moved) | entry <- candidates, Set.notMember (entry ^. #delivery) finished]
                  recorded <- recordProgress cursor' added remaining' finished moved
                  pure $ do
                    () <- recorded
                    pure
                      DestinationOutcome
                        { subscription = subscription'
                        , matched = length added
                        , attempted = length [() | o <- outcomes, attemptedOutcome o]
                        , acknowledged = length [() | Done True <- outcomes]
                        , pendingCount = length remaining'
                        , diagnostic = Nothing
                        }
    -- Match at most a budget of positions, while pending work is below its bound.
    scanFeed headValue feedValue pending' now
      | headValue ^. #cursor >= feedValue ^. #count || length pending' >= env ^. #budget . #pendingBound = pure (Right (headValue ^. #cursor, []))
      | otherwise = do
          let selects = headValue ^. #record . #selects
              request =
                readRequest
                  { after = if headValue ^. #cursor == 0 then Nothing else Just (headValue ^. #cursor - 1)
                  , limit = env ^. #budget . #scan
                  , upper = Just (min (feedValue ^. #count) (headValue ^. #cursor + fromIntegral (env ^. #budget . #scan)))
                  , kinds = selects ^. #types
                  , resource = (\scope' -> ResourceFilter scope' (selects ^. #member)) <$> selects ^. #scope
                  }
          page <- readPageAt (env ^. #feed) feedValue request
          case page of
            Left err -> pure (Left (DeliveryFeed err))
            Right found -> do
              let eligible = [entry | entry <- found ^. #entries, matchesEvent selects (entry ^. #envelope)]
              made <- traverse (\entry -> ensureDelivery env headValue now "initial" (entry ^. #envelope . #eventId) (entry ^. #position)) eligible
              pure $ do
                added <- sequence made
                let cursor' = if found ^. #more then maybe (headValue ^. #cursor) (+ 1) (found ^. #scannedTo) else found ^. #upper
                pure (max (headValue ^. #cursor) cursor', [entry | Just entry <- added])
    attemptOne adapter headValue feedValue entry = attemptDelivery env adapter headValue feedValue entry
    recordProgress cursor' added remaining' finished moved =
      withHead env subscription' False $ \fresh _ -> case fresh of
        Nothing -> pure (Right Nothing)
        Just headValue -> do
          current' <- loadPending env headValue
          case current' of
            Left err -> pure (Left err)
            Right freshPending -> do
              -- Another worker's head: keep its pending work, drop what this
              -- cycle finished, take this cycle's reschedules and matches.
              let already = Set.fromList (map (^. #delivery) freshPending)
                  ours = [entry | entry <- remaining', Set.notMember (entry ^. #delivery) already]
                  merged = [maybe entry (\at -> entry & #due .~ at) (Map.lookup (entry ^. #delivery) moved) | entry <- freshPending, Set.notMember (entry ^. #delivery) finished] <> ours
                  logged = if headValue ^. #cursor >= cursor' then [] else [entry ^. #delivery | entry <- added, Set.notMember (entry ^. #delivery) already]
              node <- pendingNode env merged
              pointer <- first DeliveryFeed <$> appendLog (env ^. #feed) (headValue ^. #history) logged
              pure $ do
                digest <- node
                logPointer <- pointer
                let replacement = headValue & #cursor .~ max cursor' (headValue ^. #cursor) & #pending .~ digest & #history .~ logPointer & #diagnostic .~ Nothing
                pure (if replacement == headValue then Nothing else Just replacement)

-- | The result of attempting one due delivery.
data AttemptResult
  = -- | It left pending work; acknowledged or not.
    Done !Bool
  | -- | It is due again at this time.
    Later !UTCTime
  | -- | Another worker holds it, or it is not due: left as it is.
    Untouched

attemptedOutcome :: AttemptResult -> Bool
attemptedOutcome = \case
  Untouched -> False
  _ -> True

-- | Intend, publish, record. The outcome is recorded only while the record
-- still holds this attempt's token.
attemptDelivery :: DeliveryEnv -> Adapter -> DestinationHead -> FeedHead -> PendingEntry -> IO (Either DeliveryError AttemptResult)
attemptDelivery env adapter headValue feedValue entry = do
  let subscription' = headValue ^. #subscription
      key = recordKey subscription' (entry ^. #delivery)
      policy' = adapter ^. #policy
  now <- env ^. #clock
  observed <- observeRecordAt (env ^. #feed) key
  case observed of
    Left err -> pure (Left (DeliveryFeed err))
    Right current -> case current ^. #value of
      Nothing -> pure (Right (Done False))
      Just record -> case record ^. #state of
        Pending
          | maybe False (> now) (record ^. #nextAttempt) -> pure (Right (Later (fromMaybe now (record ^. #nextAttempt))))
          | otherwise -> start current record now policy'
        InFlight _
          | maybe True (\started -> diffUTCTime now started < env ^. #budget . #staleAfter) (lastStarted record) -> pure (Right Untouched)
          | otherwise -> start current (closeStale record now) now policy'
        _ -> pure (Right (Done (record ^. #state == Delivered)))
  where
    lastStarted record = case reverse (record ^. #attempts) of
      latest : _ -> Just (latest ^. #startedAt)
      [] -> Nothing
    -- The previous worker stopped between its intent and its outcome.
    closeStale :: DeliveryRecord -> UTCTime -> DeliveryRecord
    closeStale record now =
      record
        & #state
        .~ Pending
        & #attempts
        .~ [if isNothing (a ^. #outcome) then a & #outcome ?~ ("unknown" :: Text) & #detail ?~ ("the attempt's worker stopped before recording an outcome" :: Text) & #finishedAt ?~ now else a | a <- record ^. #attempts]
    start current record now policy'
      | length (record ^. #attempts) >= policy' ^. #attempts || diffUTCTime now (record ^. #createdAt) > policy' ^. #lifetime =
          finish current (record & #state .~ Exhausted & #nextAttempt .~ Nothing & #reason ?~ "automatic attempts or lifetime ran out") (Done False)
      | otherwise = do
          token' <- env ^. #token
          let number' = length (record ^. #attempts) + 1
              intended = record & #state .~ InFlight token' & #attempts .~ (record ^. #attempts <> [Attempt number' token' now Nothing Nothing Nothing Nothing]) & #nextAttempt .~ Nothing
              key = recordKey (headValue ^. #subscription) (entry ^. #delivery)
          written <- replaceJson (env ^. #feed) key current intended
          case written of
            Left err -> pure (Left (DeliveryFeed err))
            Right Superseded -> pure (Right Untouched)
            Right Replaced -> do
              found <- readEventAt (env ^. #feed) feedValue (record ^. #event)
              outcome' <- case found of
                Left err -> pure (Unknown ("the event could not be read: " <> T.pack (show err)))
                Right (Nothing, _) -> pure (Permanent "the event is not in the feed")
                Right (Just event', _) ->
                  boundedPublish (env ^. #budget) (adapter ^. #publish) $
                    PublicationRequest
                      { destination = record ^. #destination
                      , revision = record ^. #revision
                      , eventId = eventIdText (record ^. #event)
                      , deliveryId = deliveryIdText (record ^. #delivery)
                      , attempt = number'
                      , body = encodeEnvelope (event' ^. #envelope)
                      , position = event' ^. #position
                      }
              done <- env ^. #clock
              fraction <- env ^. #random
              let closed = [if a ^. #token == token' then a & #outcome ?~ outcomeLabel outcome' & #detail .~ detailOf outcome' & #receipt .~ receiptOf outcome' & #finishedAt ?~ done else a | a <- intended ^. #attempts]
                  next delay = addUTCTime (retryDelay policy' number' fraction delay) done
                  (state', next', reason', result) = case outcome' of
                    Acknowledged _ -> (Delivered, Nothing, Nothing, Done True)
                    Permanent why -> (Failed, Nothing, Just why, Done False)
                    Retryable delay why
                      | number' < policy' ^. #attempts -> (Pending, Just (next delay), Just why, Later (next delay))
                      | otherwise -> (Exhausted, Nothing, Just why, Done False)
                    Unknown why
                      | number' < policy' ^. #attempts -> (Pending, Just (next Nothing), Just why, Later (next Nothing))
                      | otherwise -> (Exhausted, Nothing, Just why, Done False)
              reread <- observeRecordAt (env ^. #feed) key
              case reread of
                Left err -> pure (Left (DeliveryFeed err))
                Right latest -> case latest ^. #value of
                  Just held
                    | held ^. #state == InFlight token' ->
                        finish latest (held & #state .~ state' & #attempts .~ closed & #nextAttempt .~ next' & #reason .~ reason') result
                  _ -> pure (Right Untouched)
    finish current replacement result = do
      written <- replaceJson (env ^. #feed) (recordKey (headValue ^. #subscription) (entry ^. #delivery)) current replacement
      pure $ case written of
        Left err -> Left (DeliveryFeed err)
        Right Replaced -> Right result
        Right Superseded -> Right Untouched
    detailOf = \case
      Acknowledged _ -> Nothing
      Retryable _ why -> Just (T.take 512 why)
      Permanent why -> Just (T.take 512 why)
      Unknown why -> Just (T.take 512 why)
    receiptOf = \case
      Acknowledged receipt' -> Just receipt'
      _ -> Nothing

-- | An adapter call bounded by half the in-flight window, so a stuck
-- adapter neither holds the cycle nor races the closer of its intent, and
-- one that throws is an unknown outcome rather than a dead destination.
-- Either way the attempt may have been received, so it is 'Unknown'.
boundedPublish :: DeliveryBudget -> (PublicationRequest -> IO Outcome) -> PublicationRequest -> IO Outcome
boundedPublish budget' publish' request = do
  let seconds = max 1 (floor (budget' ^. #staleAfter / 2) :: Int)
  result <- try @SomeException (timeout (seconds * 1000000) (publish' request))
  case result of
    Left err | Just (_ :: SomeAsyncException) <- fromException err -> throwIO err
    Left err -> pure (Unknown ("the adapter failed: " <> T.pack (displayException err)))
    Right Nothing -> pure (Unknown ("the adapter did not answer within " <> T.pack (show seconds) <> " s"))
    Right (Just outcome') -> pure outcome'

-- | One delivery cycle: the committed controls, then every destination, at
-- most @concurrency@ at a time. A destination's failure is its own.
deliverOnce :: DeliveryEnv -> IO (Either DeliveryError (ControlOutcome, [Either DeliveryError DestinationOutcome]))
deliverOnce env = do
  controlled <- applyControls env
  case controlled of
    Left err -> pure (Left err)
    Right outcome -> do
      sender <- observeSender (env ^. #feed)
      case sender of
        Left err -> pure (Left (DeliveryFeed err))
        Right observed -> do
          slots <- newQSem (max 1 (env ^. #budget . #concurrency))
          results <- forConcurrently (maybe [] (^. #destinations) (observed ^. #value)) $ \destination' ->
            bracket_ (waitQSem slots) (signalQSem slots) (deliverDestination env destination')
          pure (Right (outcome, results))
