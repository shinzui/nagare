{-# LANGUAGE OverloadedStrings #-}

-- | Reading the lifecycle event feed (EP-231 M2). Every read is exact GETs:
-- the head, the index nodes it names and the segments a page needs, never a
-- listing and never the inventory. A page is bounded by the positions it may
-- scan, so an exact filter that matches rarely returns a short page and a
-- continuation instead of reading the whole history.
module Nagare.Events.Read
  ( ResourceFilter (..)
  , ReadRequest (..)
  , readRequest
  , FeedEntry (..)
  , FeedPage (..)
  , readPage
  , readPageAt
  , readEvent
  , readEventAt
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Nagare.Dsl.Prelude
import Nagare.Events.Envelope
import Nagare.Events.Layout
import Nagare.Events.Source
import Nagare.Events.Store
import Nagare.Resource.Types

-- | An exact resource filter: the scope, and the member when named.
data ResourceFilter = ResourceFilter
  { scope :: !ScopeId
  , member :: !(Maybe ResourceId)
  }
  deriving stock (Eq, Show, Generic)

data ReadRequest = ReadRequest
  { after :: !(Maybe Integer)
  -- ^ Resume after this position.
  , limit :: !Int
  , upper :: !(Maybe Integer)
  -- ^ The publication bound a traversal pinned; positions at or past it are
  -- not read. 'Nothing' takes the feed's current count.
  , kinds :: !(Set EventKind)
  -- ^ Empty for every kind.
  , resource :: !(Maybe ResourceFilter)
  , scanSegments :: !Int
  -- ^ At most this many segments are read for one page.
  }
  deriving stock (Eq, Show, Generic)

-- | The first page of every event: 50, from the start, unpinned.
readRequest :: ReadRequest
readRequest = ReadRequest Nothing 50 Nothing Set.empty Nothing 4

data FeedEntry = FeedEntry
  { position :: !Integer
  , envelope :: !Envelope
  }
  deriving stock (Eq, Show, Generic)

data FeedPage = FeedPage
  { entries :: ![FeedEntry]
  , scannedTo :: !(Maybe Integer)
  -- ^ The last position this page examined; a continuation resumes after it.
  , upper :: !Integer
  , more :: !Bool
  -- ^ Positions remain between 'scannedTo' and 'upper'.
  , feed :: !FeedHead
  }
  deriving stock (Eq, Show, Generic)

readPage :: FeedStore -> ContextBinding -> ReadRequest -> IO (Either FeedError FeedPage)
readPage store binding request = readFeedHead store binding >>= either (pure . Left) (\headValue -> readPageAt store headValue request)

-- | A page of the feed as @headValue@ names it.
readPageAt :: FeedStore -> FeedHead -> ReadRequest -> IO (Either FeedError FeedPage)
readPageAt store headValue request = do
  let bound = maybe (headValue ^. #count) (min (headValue ^. #count)) (request ^. #upper)
      start = maybe 0 (+ 1) (request ^. #after)
      wanted = max 1 (min 100 (request ^. #limit))
  locator <- newLocator store headValue
  let scan k remaining found lastSeen
        | remaining <= 0 || k * segmentCapacity >= bound || length found >= wanted = pure (Right (found, lastSeen))
        | otherwise = do
            digest <- locateSegment locator k
            segment <- either (pure . Left) (loadSegment store k) digest
            case segment of
              Left err -> pure (Left err)
              Right loadedSegment -> do
                let inRange = [FeedEntry position envelope | (position, envelope) <- zip [k * segmentCapacity ..] (loadedSegment ^. #entries), position >= start, position < bound]
                    (taken, lastExamined) = takeMatches (wanted - length found) inRange
                scan (k + 1) (remaining - 1) (found <> taken) (lastExamined <|> lastSeen)
      takeMatches n = go n [] Nothing
        where
          go _ kept seen [] = (reverse kept, seen)
          go 0 kept seen _ = (reverse kept, seen)
          go remaining kept _ (entry : rest)
            | matches (entry ^. #envelope) = go (remaining - 1) (entry : kept) (Just (entry ^. #position)) rest
            | otherwise = go remaining kept (Just (entry ^. #position)) rest
  if start >= bound
    then pure (Right (FeedPage [] Nothing bound False headValue))
    else do
      scanned <- scan (start `div` segmentCapacity) (max 1 (request ^. #scanSegments)) [] Nothing
      pure $ do
        (found, lastSeen) <- scanned
        pure (FeedPage found lastSeen bound (maybe False (\seen -> seen + 1 < bound) lastSeen) headValue)
  where
    matches envelope =
      (Set.null (request ^. #kinds) || Set.member (payloadKind (envelope ^. #payload)) (request ^. #kinds))
        && maybe True (resourceMatches (envelope ^. #resource)) (request ^. #resource)
    resourceMatches reference wanted =
      reference ^. #scope == wanted ^. #scope
        && maybe True (\resourceId -> reference ^. #member == Just resourceId) (wanted ^. #member)

-- | One event by ID: the head, the ID index path and its segment.
readEvent :: FeedStore -> ContextBinding -> EventId -> IO (Either FeedError (Maybe FeedEntry, FeedHead))
readEvent store binding eventId = readFeedHead store binding >>= either (pure . Left) (\headValue -> readEventAt store headValue eventId)

-- | One event by ID in the feed as @headValue@ names it.
readEventAt :: FeedStore -> FeedHead -> EventId -> IO (Either FeedError (Maybe FeedEntry, FeedHead))
readEventAt store headValue eventId = do
  found <- lookupIds store (headValue ^. #ids) [eventId]
  case Map.lookup eventId <$> found of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right (Nothing, headValue))
    Right (Just position) -> do
      locator <- newLocator store headValue
      let k = position `div` segmentCapacity
      digest <- locateSegment locator k
      segment <- either (pure . Left) (loadSegment store k) digest
      pure $ do
        loadedSegment <- segment
        case drop (fromIntegral (position `mod` segmentCapacity)) (loadedSegment ^. #entries) of
          envelope : _
            | envelope ^. #eventId == eventId -> Right (Just (FeedEntry position envelope), headValue)
          _ -> Left (FeedInvalid "ids" "the ID index names a position holding another event")
