{-# LANGUAGE OverloadedStrings #-}

-- | Read-only inspection of lifecycle delivery state (EP-234), shared by the
-- CLI and the admin API: the subscriptions the sender applies, a page of
-- one subscription's deliveries, and one delivery. Every read is exact GETs
-- of the sender and destination heads, the delivery log's index and the
-- segments a page touches, and the page's records — never a listing and
-- never the whole history.
module Nagare.Events.Delivery.Inspect
  ( InspectError (..)
  , subscriptionsOf
  , deliveryPage
  , findDelivery
  , subscriptionDocument
  , deliveryDocument
  , deliveryCursor
  , parseDeliveryCursor
  )
where

import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Nagare.Contract.Delivery qualified as Contract
import Nagare.Contract.Schema (Nullable (..))
import Nagare.Dsl.Prelude
import Nagare.Events.Delivery.Store
import Nagare.Events.Delivery.Transport (Receipt (..))
import Nagare.Events.Envelope (eventIdText)
import Nagare.Events.Source (eventKindText)
import Nagare.Events.Store (FeedError, FeedStore)
import Nagare.Events.Subscription
import Nagare.Resource.Types

data InspectError
  = DeliveryOff
  | NoSubscription !Text
  | InspectFeed !FeedError
  deriving stock (Eq, Show)

-- | Every subscription the sender knows, with the sender head's generation.
subscriptionsOf :: FeedStore -> IO (Either InspectError (Integer, [Contract.DeliverySubscription]))
subscriptionsOf store = do
  sender <- observeSender store
  case sender of
    Left err -> pure (Left (InspectFeed err))
    Right observed -> case observed ^. #value of
      Nothing -> pure (Left DeliveryOff)
      Just headValue -> do
        heads <- traverse (observeDestination store) (headValue ^. #destinations)
        pure $ do
          found <- first InspectFeed (sequence heads)
          pure (headValue ^. #generation, [subscriptionDocument h | Just h <- map (^. #value) found])

-- | An opaque cursor after delivery number @n@ of a subscription.
deliveryCursor :: Integer -> Text
deliveryCursor n = TE.decodeUtf8 (convertToBase Base64URLUnpadded (TE.encodeUtf8 ("delivery:" <> T.pack (show n))))

parseDeliveryCursor :: Text -> Either Text Integer
parseDeliveryCursor text = do
  bytes <- first (const "the cursor is not one this server issued") (convertFromBase Base64URLUnpadded (TE.encodeUtf8 text) :: Either String ByteString)
  case T.stripPrefix "delivery:" (TE.decodeUtf8 bytes) of
    Just digits | [(n, "")] <- reads (T.unpack digits), n >= 0 -> Right n
    _ -> Left "the cursor is not one this server issued"

-- | At most @size@ deliveries after delivery number @after@, oldest first.
deliveryPage :: FeedStore -> Text -> Maybe Integer -> Int -> IO (Either InspectError ([Contract.Delivery], Contract.DeliveryPageInfo))
deliveryPage store name after size = case mkSubscriptionId name of
  Left _ -> pure (Left (NoSubscription name))
  Right subscription' -> do
    observed <- observeDestination store subscription'
    case observed of
      Left err -> pure (Left (InspectFeed err))
      Right current -> case current ^. #value of
        Nothing -> do
          -- A sender never enabled is not a subscription it does not apply.
          sender <- observeSender store
          pure $ case sender of
            Left err -> Left (InspectFeed err)
            Right observed' -> Left (maybe DeliveryOff (const (NoSubscription name)) (observed' ^. #value))
        Just headValue -> do
          let from = maybe 0 (+ 1) after
              total = headValue ^. #history . #count
          page <- readLog store (headValue ^. #history) from size
          case page of
            Left err -> pure (Left (InspectFeed err))
            Right ids -> do
              records <- traverse (\(_, delivery') -> observeRecordAt store (recordKey subscription' delivery')) ids
              pure $ do
                found <- first InspectFeed (sequence records)
                let last' = if null ids then Nothing else Just (fst (last ids))
                pure ([deliveryDocument r | Just r <- map (^. #value) found], Contract.DeliveryPageInfo (maybe False (< total - 1) last') (Nullable (deliveryCursor <$> last')))

-- | One delivery, by ID, among the destinations the sender knows.
findDelivery :: FeedStore -> Text -> IO (Either InspectError (Maybe Contract.Delivery))
findDelivery store text = case mkDeliveryId text of
  Left _ -> pure (Right Nothing)
  Right delivery' -> do
    sender <- observeSender store
    case sender of
      Left err -> pure (Left (InspectFeed err))
      Right observed -> case observed ^. #value of
        Nothing -> pure (Left DeliveryOff)
        Just headValue -> go (headValue ^. #destinations)
    where
      go [] = pure (Right Nothing)
      go (subscription' : rest) = do
        found <- observeRecordAt store (recordKey subscription' delivery')
        case found of
          Left err -> pure (Left (InspectFeed err))
          Right observed -> maybe (go rest) (pure . Right . Just . deliveryDocument) (observed ^. #value)

subscriptionDocument :: DestinationHead -> Contract.DeliverySubscription
subscriptionDocument headValue =
  Contract.DeliverySubscription
    { subscription = subscriptionIdText (record ^. #subscription)
    , revision = record ^. #revision
    , status = case record ^. #status of
        Active -> "active"
        Disabled -> "disabled"
        Deleted -> "deleted"
    , transport = record ^. #destination . #transport
    , destination = record ^. #destination . #identity
    , policy = record ^. #policy . #name <> "/" <> T.pack (show (record ^. #policy . #version))
    , types = map eventKindText (Set.toAscList (record ^. #selects . #types))
    , scope = Nullable (scopeIdText <$> (record ^. #selects . #scope))
    , member = Nullable (resourceIdText <$> (record ^. #selects . #member))
    , startAfter = record ^. #startAfter
    , matchedTo = headValue ^. #cursor
    , deliveries = headValue ^. #history . #count
    , paused = Nullable (headValue ^. #diagnostic)
    , refusedReplay = Nullable (headValue ^. #refusedReplay)
    }
  where
    record = headValue ^. #record

deliveryDocument :: DeliveryRecord -> Contract.Delivery
deliveryDocument r =
  Contract.Delivery
    { deliveryId = deliveryIdText (r ^. #delivery)
    , subscription = subscriptionIdText (r ^. #subscription)
    , destination = r ^. #destination
    , transport = r ^. #transport
    , policy = r ^. #policy
    , revision = r ^. #revision
    , eventId = eventIdText (r ^. #event)
    , position = r ^. #position
    , cycle = r ^. #deliveryCycle
    , state = deliveryStateText (r ^. #state)
    , nextAttempt = Nullable (stamp <$> (r ^. #nextAttempt))
    , reason = Nullable (r ^. #reason)
    , attempts =
        [ Contract.DeliveryAttempt
            { number = a ^. #number
            , startedAt = stamp (a ^. #startedAt)
            , outcome = Nullable (a ^. #outcome)
            , detail = Nullable (a ^. #detail)
            , finishedAt = Nullable (stamp <$> (a ^. #finishedAt))
            , receipt = Nullable ((\receipt' -> Contract.DeliveryReceipt (receipt' ^. #kind) (receipt' ^. #version) (receipt' ^. #details)) <$> (a ^. #receipt))
            }
        | a <- r ^. #attempts
        ]
    }

stamp :: UTCTime -> Text
stamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
