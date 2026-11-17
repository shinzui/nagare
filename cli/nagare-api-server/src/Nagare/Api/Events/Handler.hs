-- | The lifecycle event routes (EP-231). A request reads the feed head once;
-- its representation is cached by route, arguments and the feed revision, so
-- an unchanged feed answers from cached bytes or 304.
module Nagare.Api.Events.Handler
  ( eventsServer
  )
where

import Data.Generics.Labels ()
import Data.Set qualified as Set
import Data.Text qualified as Text
import Nagare.Api.Events.DeliveryHandler (deliveriesHandler, deliveryHandler, subscriptionsHandler)
import Nagare.Api.Events.Routes (EventsRoutes (..))
import Nagare.Api.Page (PageSize (..))
import Nagare.Api.Response (Paged (..))
import Nagare.Api.Server.Serve (Env, Plan (..), serveFeed)
import Nagare.Contract.Events (LifecycleFeedEntry)
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (ProblemDetails, badRequest, eventsNotEnabled, invalidCursor, invalidPage, problemFor, storeInvalid, storeUnavailable, unknownEvent)
import Nagare.Events.Query
import Nagare.Events.Read (ResourceFilter (..))
import Nagare.Events.Source (parseEventKind)
import Nagare.Events.Store (FeedError (..))
import Nagare.Resource.Types (ScopeKind (..), mkResourceId, mkScopeId)
import Relay.Pagination (Connection (..), Cursor, Edge (..), PageInfo (..), cursorFromText)
import Servant (Handler)
import Servant.Server.Generic (AsServerT)

eventsServer :: Env -> EventsRoutes (AsServerT Handler)
eventsServer env =
  EventsRoutes
    { list = \firstArg afterArg lastArg beforeArg refreshFlag types scopeArg memberArg match ->
        serveFeed env match $ \store binding headValue -> do
          when (isJust lastArg || isJust beforeArg) (Left (problemFor invalidPage "the event feed pages forward only; use first and after"))
          query <- validated (fmap (\(PageSize size) -> size) firstArg) afterArg refreshFlag types scopeArg memberArg
          pure
            Plan
              { key = Text.intercalate "|" ["events", Text.pack (show query), feedRevision headValue]
              , construct = fmap (fmap paged) (first refusal <$> queryEventsAt store binding headValue query)
              }
    , subscriptions = subscriptionsHandler env
    , deliveries = deliveriesHandler env
    , delivery = deliveryHandler env
    , event = \eventIdText match ->
        serveFeed env match $ \store _ headValue ->
          Right
            Plan
              { key = "event|" <> eventIdText <> "|" <> feedRevision headValue
              , construct = do
                  found <- lookupEventAt store headValue eventIdText
                  pure $ case found of
                    Left err -> Left (refusal err)
                    Right (Nothing, _) -> Left (problemFor unknownEvent (eventIdText <> " is not a published event"))
                    Right (Just entry, _) -> Right (feedEntry entry)
              }
    }

validated :: Maybe Int -> Maybe Text -> Bool -> [Text] -> Maybe Text -> Maybe Text -> Either ProblemDetails EventQuery
validated size after refreshFlag types scopeArg memberArg = do
  kinds <- traverse (\text -> maybe (Left (problemFor badRequest ("unknown event type " <> text))) Right (parseEventKind text)) types
  resource <- case (scopeArg, memberArg) of
    (Nothing, Nothing) -> Right Nothing
    (Nothing, Just _) -> Left (problemFor badRequest "member needs scope")
    (Just scopeText, memberText) -> do
      scopeId <- first (problemFor badRequest) (parseScope scopeText)
      memberId <- traverse (first (problemFor badRequest) . mkResourceId) memberText
      pure (Just (ResourceFilter scopeId memberId))
  pure (EventQuery size after refreshFlag (Set.fromList kinds) resource)
  where
    parseScope text = case Text.breakOn ":" text of
      (kindText, rest)
        | Just name <- Text.stripPrefix ":" rest
        , Just kind <- lookup kindText [("platform", Platform), ("application", Application), ("standalone", Standalone), ("publication", Publication)] ->
            mkScopeId kind name
      _ -> Left "scope is kind:name, for example application:notes"

refusal :: QueryRefusal -> ProblemDetails
refusal = \case
  InvalidPage reason -> problemFor invalidPage reason
  InvalidCursor reason -> problemFor invalidCursor reason
  QueryFeed FeedNotEnabled -> problemFor eventsNotEnabled "the context's lifecycle feed is not enabled; it has no event history yet"
  QueryFeed (FeedTransport reason) -> problemFor storeUnavailable reason
  QueryFeed err -> problemFor storeInvalid (Text.pack (show err))

paged :: EventPage -> Paged LifecycleFeedEntry
paged page =
  Paged
    ( Connection
        [Edge (feedEntry entry) (relay cursor) | (entry, cursor) <- zip (page ^. #entries) (page ^. #cursors)]
        (PageInfo (page ^. #hasNext) False (relay <$> listToMaybe (page ^. #cursors)) (Just (relay (page ^. #endCursor))))
    )
  where
    -- An event cursor is unpadded base64url, which is all a Relay cursor is.
    relay :: Text -> Cursor
    relay = either (error . Text.unpack . ("an event cursor is not a Relay cursor: " <>) . Text.pack . show) id . cursorFromText
    listToMaybe = \case
      cursor : _ -> Just cursor
      [] -> Nothing
