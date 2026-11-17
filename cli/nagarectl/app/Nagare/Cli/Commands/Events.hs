-- | @nagarectl events list@ (EP-231): one page of the active context's
-- published lifecycle events. It reads the feed and never materializes it.
module Nagare.Cli.Commands.Events
  ( runEventsList
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Generics.Labels ()
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Options.Events (EventsListOpts (..))
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Contract.Problem (ProblemSpec, badRequest, eventsNotEnabled, invalidCursor, invalidPage, storeUnavailable)
import Nagare.Contract.Sink (emitDocument, refuseWith)
import Nagare.Dsl.Prelude
import Nagare.Events.Envelope (eventIdText)
import Nagare.Events.Query
import Nagare.Events.Read (FeedEntry, ResourceFilter (..))
import Nagare.Events.Source (eventKindText, parseEventKind, payloadKind)
import Nagare.Events.Store (FeedError (FeedNotEnabled))
import Nagare.Events.Target (openTargetFeedReadOnly, targetBinding)
import Nagare.Resource.Types

runEventsList :: Maybe String -> EventsListOpts -> IO ()
runEventsList mctx options = do
  target <- activeTarget mctx
  binding <- either dieT pure (targetBinding target)
  query <- either (refuse badRequest) pure (queryFrom options)
  store <- openTargetFeedReadOnly target >>= either (refuse storeUnavailable) pure
  queryEvents store binding query >>= \case
    Left (InvalidPage reason) -> refuse invalidPage reason
    Left (InvalidCursor reason) -> refuse invalidCursor reason
    Left (QueryFeed FeedNotEnabled) -> refuse eventsNotEnabled "the context's lifecycle feed is not enabled; it has no event history yet"
    Left (QueryFeed err) -> refuse storeUnavailable (T.pack (show err))
    Right page
      -- Under the contract the sink owns stdout; the document goes through it.
      | isJust (options ^. #contract) -> emitDocument (eventList binding page)
      | options ^. #json -> LBC.putStrLn (Aeson.encode (eventList binding page))
      | otherwise -> TIO.putStr (renderEvents page)

-- | A refused read: a problem document under @--contract@, else stderr.
refuse :: ProblemSpec -> Text -> IO a
refuse spec detail = refuseWith ("nagarectl: events list: " <> detail) spec detail

queryFrom :: EventsListOpts -> Either Text EventQuery
queryFrom options = do
  kinds <- traverse (\text -> maybe (Left ("unknown event type " <> T.pack text)) Right (parseEventKind (T.pack text))) (options ^. #types)
  resource <- case (options ^. #scope, options ^. #member) of
    (Nothing, Nothing) -> Right Nothing
    (Nothing, Just _) -> Left "--member needs --scope"
    (Just scopeText, memberText) -> do
      scopeId <- parseScope (T.pack scopeText)
      memberId <- traverse (mkResourceId . T.pack) memberText
      pure (Just (ResourceFilter scopeId memberId))
  pure (EventQuery (options ^. #first) (T.pack <$> options ^. #after) (options ^. #refresh) (Set.fromList kinds) resource)
  where
    parseScope text = case T.breakOn ":" text of
      (kindText, rest)
        | Just name <- T.stripPrefix ":" rest
        , Just kind <- lookup kindText [("platform", Platform), ("application", Application), ("standalone", Standalone), ("publication", Publication)] ->
            mkScopeId kind name
      _ -> Left "--scope is KIND:NAME, for example application:notes"

renderEvents :: EventPage -> Text
renderEvents page =
  T.unlines (map row (page ^. #entries))
    <> (if page ^. #hasNext then "more: --after " <> page ^. #endCursor <> "\n" else "")
  where
    row :: FeedEntry -> Text
    row entry =
      T.intercalate
        "  "
        [ T.pack (show (entry ^. #position))
        , entry ^. #envelope . #publishedAt
        , eventKindText (payloadKind (entry ^. #envelope . #payload))
        , scopeIdText (entry ^. #envelope . #resource . #scope)
        , eventIdText (entry ^. #envelope . #eventId)
        ]
