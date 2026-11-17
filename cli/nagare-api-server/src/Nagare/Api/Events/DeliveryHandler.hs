-- | The lifecycle delivery routes (EP-234), transport-neutral: the
-- subscriptions the sender applies, a page of one subscription's
-- deliveries, and one delivery. They read the lifecycle state beside the
-- feed and never write it.
module Nagare.Api.Events.DeliveryHandler
  ( subscriptionsHandler
  , deliveriesHandler
  , deliveryHandler
  )
where

import Data.Text qualified as Text
import Nagare.Api.Page (PageSize (..), maximumPageSize)
import Nagare.Api.Response (Paged (..), SnapshotResult)
import Nagare.Api.Server.Serve (Env, serveDelivery)
import Nagare.Contract.Delivery (Delivery (..), DeliverySubscription)
import Nagare.Contract.Delivery qualified as Contract
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (ProblemDetails, deliveryNotEnabled, invalidCursor, invalidPage, problemFor, storeInvalid, storeUnavailable, unknownDelivery, unknownSubscription)
import Nagare.Contract.Schema (fromNullable)
import Nagare.Events.Delivery.Inspect
import Nagare.Events.Store (FeedError (..))
import Relay.Pagination (Connection (..), Cursor, Edge (..), PageInfo (..), cursorFromText)
import Servant (Handler)

subscriptionsHandler :: Env -> Maybe Text -> Handler (SnapshotResult [DeliverySubscription])
subscriptionsHandler env match =
  serveDelivery env match $ \store -> do
    found <- subscriptionsOf store
    pure $ case found of
      Left err -> Left (refusal err)
      Right (generation, documents) -> Right ("sender-" <> Text.pack (show generation), documents)

deliveriesHandler :: Env -> Maybe PageSize -> Maybe Text -> Maybe PageSize -> Maybe Text -> Text -> Maybe Text -> Handler (SnapshotResult (Paged Delivery))
deliveriesHandler env firstArg afterArg lastArg beforeArg subscription match =
  serveDelivery env match $ \store -> case validated of
    Left problem -> pure (Left problem)
    Right (size, after) -> do
      found <- deliveryPage store subscription after size
      pure $ case found of
        Left err -> Left (refusal err)
        Right (documents, info) ->
          Right
            ( "deliveries-" <> subscription <> "-" <> maybe "0" (Text.pack . show) after
            , Paged
                ( Connection
                    [Edge document (relay (deliveryCursor n)) | (document, n) <- zip documents [maybe 0 (+ 1) after ..]]
                    (PageInfo (Contract.hasNextPage info) False Nothing (relay <$> fromNullable (Contract.endCursor info)))
                )
            )
  where
    validated = do
      when (isJust lastArg || isJust beforeArg) (Left (problemFor invalidPage "deliveries page forward only; use first and after"))
      size <- case firstArg of
        Nothing -> Right 50
        Just (PageSize n)
          | n >= 1 && n <= maximumPageSize -> Right n
          | otherwise -> Left (problemFor invalidPage "first is 1 to 100")
      after <- traverse (first (problemFor invalidCursor) . parseDeliveryCursor) afterArg
      pure (size, after)
    relay :: Text -> Cursor
    relay = either (error . Text.unpack) id . cursorFromText

deliveryHandler :: Env -> Text -> Maybe Text -> Handler (SnapshotResult Delivery)
deliveryHandler env deliveryText match =
  serveDelivery env match $ \store -> do
    found <- findDelivery store deliveryText
    pure $ case found of
      Left err -> Left (refusal err)
      Right Nothing -> Left (problemFor unknownDelivery (deliveryText <> " is not a delivery of this context"))
      Right (Just document) -> Right ("delivery-" <> deliveryId document <> "-" <> state document <> "-" <> Text.pack (show (length (attempts document))), document)

refusal :: InspectError -> ProblemDetails
refusal = \case
  DeliveryOff -> problemFor deliveryNotEnabled "the context's lifecycle delivery is not enabled; no subscription is applied yet"
  NoSubscription name -> problemFor unknownSubscription (name <> " is not a subscription the sender applies")
  InspectFeed (FeedTransport reason) -> problemFor storeUnavailable reason
  InspectFeed err -> problemFor storeInvalid (Text.pack (show err))
