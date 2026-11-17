{-# LANGUAGE OverloadedStrings #-}

-- | One page of the lifecycle feed as the CLI and the admin API serve it
-- (EP-231 M3). A cursor is opaque: it binds the context, the feed epoch, the
-- filter set and the publication bound the traversal pinned. So a traversal
-- finishes while new events arrive. Refreshing a cursor keeps its position and
-- checks and takes the feed's current bound, which is how a tailing client
-- polls.
module Nagare.Events.Query
  ( EventQuery (..)
  , eventQuery
  , QueryRefusal (..)
  , EventPage (..)
  , queryEvents
  , queryEventsAt
  , lookupEvent
  , lookupEventAt
  , feedRevision
  , lifecycleEvent
  , feedEntry
  , eventList
  , EventCursor (..)
  , encodeCursor
  , decodeCursor
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Contract.Events
import Nagare.Contract.Schema (ContractVersion (ContractVersion1), DocumentName (DocumentName), Nullable (Nullable))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Envelope
import Nagare.Events.Read
import Nagare.Events.Source (EventKind, eventKindText)
import Nagare.Events.Store
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data EventQuery = EventQuery
  { size :: !(Maybe Int)
  , after :: !(Maybe Text)
  , refresh :: !Bool
  , kinds :: !(Set EventKind)
  , resource :: !(Maybe ResourceFilter)
  }
  deriving stock (Eq, Show, Generic)

-- | The first page of every event.
eventQuery :: EventQuery
eventQuery = EventQuery Nothing Nothing False Set.empty Nothing

data QueryRefusal
  = InvalidPage !Text
  | InvalidCursor !Text
  | QueryFeed !FeedError
  deriving stock (Eq, Show)

data EventPage = EventPage
  { entries :: ![FeedEntry]
  , cursors :: ![Text]
  -- ^ Each entry's own cursor, to resume right after it.
  , hasNext :: !Bool
  , endCursor :: !Text
  , feed :: !FeedHead
  }
  deriving stock (Eq, Show, Generic)

-- | Where a traversal stands.
data EventCursor = EventCursor
  { context :: !Text
  , epoch :: !Text
  , filters :: !Text
  , upper :: !Integer
  , position :: !(Maybe Integer)
  }
  deriving stock (Eq, Show, Generic)

queryEvents :: FeedStore -> ContextBinding -> EventQuery -> IO (Either QueryRefusal EventPage)
queryEvents store binding query =
  readFeedHead store binding >>= either (pure . Left . QueryFeed) (\headValue -> queryEventsAt store binding headValue query)

-- | The page as @headValue@ names the feed.
queryEventsAt :: FeedStore -> ContextBinding -> FeedHead -> EventQuery -> IO (Either QueryRefusal EventPage)
queryEventsAt store binding headValue query = case pageSize of
  Left refusal -> pure (Left refusal)
  Right size -> case resume of
    Left refusal -> pure (Left refusal)
    Right (from, bound) -> do
      page <- readPageAt store headValue (ReadRequest from size (Just bound) (query ^. #kinds) (query ^. #resource) 4)
      pure $ case page of
        Left err -> Left (QueryFeed err)
        Right found ->
          let reached = (found ^. #scannedTo) <|> from
           in Right
                ( EventPage
                    (found ^. #entries)
                    [encodeCursor (cursorAt headValue bound (Just (entry ^. #position))) | entry <- found ^. #entries]
                    (found ^. #more)
                    (encodeCursor (cursorAt headValue bound reached))
                    (found ^. #feed)
                )
  where
    pageSize = case query ^. #size of
      Nothing -> Right 50
      Just size
        | size >= 1 && size <= 100 -> Right size
        | otherwise -> Left (InvalidPage "first must be between 1 and 100")
    fingerprint = filterFingerprint (query ^. #kinds) (query ^. #resource)
    cursorAt _ bound = EventCursor (contextIdText (binding ^. #identity)) (headValue ^. #epoch) fingerprint bound
    resume = case query ^. #after of
      Nothing -> Right (Nothing, headValue ^. #count)
      Just text -> do
        cursor <- first InvalidCursor (decodeCursor text)
        unless (cursor ^. #context == contextIdText (binding ^. #identity)) (Left (InvalidCursor "the cursor belongs to another context"))
        unless (cursor ^. #epoch == headValue ^. #epoch) (Left (InvalidCursor "the cursor belongs to another feed epoch"))
        unless (cursor ^. #filters == fingerprint) (Left (InvalidCursor "the cursor was issued for other filters"))
        unless (cursor ^. #upper <= headValue ^. #count) (Left (InvalidCursor "the cursor is ahead of the feed"))
        pure (cursor ^. #position, if query ^. #refresh then headValue ^. #count else cursor ^. #upper)

-- | One event by its ID text. Text that is no event ID names no event.
lookupEvent :: FeedStore -> ContextBinding -> Text -> IO (Either QueryRefusal (Maybe FeedEntry, FeedHead))
lookupEvent store binding text =
  readFeedHead store binding >>= either (pure . Left . QueryFeed) (\headValue -> lookupEventAt store headValue text)

lookupEventAt :: FeedStore -> FeedHead -> Text -> IO (Either QueryRefusal (Maybe FeedEntry, FeedHead))
lookupEventAt store headValue text = case mkEventId text of
  Left _ -> pure (Right (Nothing, headValue))
  Right eventId -> first QueryFeed <$> readEventAt store headValue eventId

-- | The feed head's revision: the digest of its canonical bytes.
feedRevision :: FeedHead -> Text
feedRevision = digestText . contentDigest . either (error . T.unpack) id . canonicalValue . toJSON

filterFingerprint :: Set EventKind -> Maybe ResourceFilter -> Text
filterFingerprint kinds resource =
  T.take 16 . digestText . contentDigest . either (error . T.unpack) id . canonicalValue $
    object
      [ "types" .= map eventKindText (Set.toAscList kinds)
      , "scope" .= fmap (^. #scope) resource
      , "member" .= (resource >>= (^. #member))
      ]

encodeCursor :: EventCursor -> Text
encodeCursor cursor =
  TE.decodeUtf8
    ( convertToBase
        Base64URLUnpadded
        ( either (error . T.unpack) id . canonicalValue $
            object
              [ "v" .= (1 :: Int)
              , "context" .= (cursor ^. #context)
              , "epoch" .= (cursor ^. #epoch)
              , "filters" .= (cursor ^. #filters)
              , "upper" .= (cursor ^. #upper)
              , "position" .= (cursor ^. #position)
              ]
        ) ::
        ByteString
    )

decodeCursor :: Text -> Either Text EventCursor
decodeCursor text = do
  bytes <- first (const "the cursor is not one this server issued") (convertFromBase Base64URLUnpadded (TE.encodeUtf8 text) :: Either String ByteString)
  value <- first (const "the cursor is not one this server issued") (eitherDecodeStrict' bytes)
  case value of
    Object o
      | all (`elem` ["v", "context", "epoch", "filters", "upper", "position"]) (KM.keys o) ->
          maybe (Left "the cursor is not one this server issued") Right $ do
            Number 1 <- KM.lookup "v" o
            String context' <- KM.lookup "context" o
            String epoch' <- KM.lookup "epoch" o
            String filters' <- KM.lookup "filters" o
            Number upper' <- KM.lookup "upper" o
            position' <- KM.lookup "position" o
            positionValue <- case position' of
              Null -> Just Nothing
              Number n | n >= 0 -> Just (Just (truncate n))
              _ -> Nothing
            guard (upper' >= 0)
            pure (EventCursor context' epoch' filters' (truncate upper') positionValue)
    _ -> Left "the cursor is not one this server issued"

-- | The contract form of an envelope: the same members, decoded from its
-- canonical JSON, so the two cannot drift apart.
lifecycleEvent :: Envelope -> LifecycleEvent
lifecycleEvent envelope = case fromJSON (toJSON envelope) of
  Success event -> event
  Error reason -> error ("an envelope does not decode as its contract document: " <> reason)

feedEntry :: FeedEntry -> LifecycleFeedEntry
feedEntry entry = LifecycleFeedEntry (entry ^. #position) (lifecycleEvent (entry ^. #envelope))

eventList :: ContextBinding -> EventPage -> EventList
eventList binding page =
  EventList
    ContractVersion1
    DocumentName
    (contextIdText (binding ^. #identity))
    (feedRevision (page ^. #feed))
    (map feedEntry (page ^. #entries))
    (EventPageInfo (page ^. #hasNext) (Nullable (Just (page ^. #endCursor))))
