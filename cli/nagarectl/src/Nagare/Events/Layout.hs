{-# LANGUAGE OverloadedStrings #-}

-- | The lifecycle feed's immutable layout (EP-231 M2). Envelopes live in
-- segments of at most 64; position @p@ is entry @p mod 64@ of segment
-- @p div 64@. A tail index node lists the digests of up to 1024 segments; the
-- head names it and a node listing every completed one, so a page near the
-- end of up to 65,536 events reads the head, one index node and at most two
-- segments. An event ID resolves to its position through a persistent trie
-- keyed by the ID's hexadecimal digits, whose cost grows with the logarithm
-- of the history, not with its length.
module Nagare.Events.Layout
  ( segmentCapacity
  , leafCapacity
  , Segment (..)
  , IndexNode (..)
  , Completed (..)
  , IdNode (..)
  , encodeLayout
  , decodeLayout
  , SegmentLocator
  , newLocator
  , locateSegment
  , loadSegment
  , lookupIds
  , insertIds
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Envelope
import Nagare.Events.Store
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

segmentCapacity :: Integer
segmentCapacity = 64

leafCapacity :: Integer
leafCapacity = 1024

data Segment = Segment
  { start :: !Integer
  , entries :: ![Envelope]
  }
  deriving stock (Eq, Show, Generic)

-- | The digests of segments @number * 1024@ onwards.
data IndexNode = IndexNode
  { number :: !Integer
  , segments :: ![ContentDigest]
  }
  deriving stock (Eq, Show, Generic)

-- | Every completed index node, in order.
newtype Completed = Completed [ContentDigest]
  deriving stock (Eq, Show)

-- | A trie node at a depth: a leaf of at most 64 entries, or a branch by the
-- ID's next hexadecimal digit.
data IdNode
  = IdLeaf ![(EventId, Integer)]
  | IdBranch !(Map Char ContentDigest)
  deriving stock (Eq, Show)

encodeLayout :: (ToJSON a) => a -> ByteString
encodeLayout = either (error . T.unpack) id . canonicalValue . toJSON

decodeLayout :: (FromJSON a, ToJSON a) => Text -> ByteString -> Either FeedError a
decodeLayout label bytes = do
  value <- first (FeedInvalid label . T.pack) (eitherDecodeStrict' bytes)
  unless (encodeLayout value == bytes) (Left (FeedInvalid label "a feed object is not canonical"))
  pure value

-- | Finds segment digests for one request, reading each index node once.
data SegmentLocator = SegmentLocator !FeedStore !FeedHead !(IORef (Map Integer IndexNode)) !(IORef (Maybe [ContentDigest]))

newLocator :: FeedStore -> FeedHead -> IO SegmentLocator
newLocator store headValue = SegmentLocator store headValue <$> newIORef Map.empty <*> newIORef Nothing

-- | The digest of segment @k@ of the visible feed.
locateSegment :: SegmentLocator -> Integer -> IO (Either FeedError ContentDigest)
locateSegment locator@(SegmentLocator _ headValue _ _) k
  | k < 0 || k * segmentCapacity >= headValue ^. #count = pure (Left (FeedInvalid "index" "segment beyond the visible feed"))
  | otherwise = do
      node <- indexNode locator (k `div` leafCapacity)
      pure $ do
        found <- node
        case drop (fromIntegral (k `mod` leafCapacity)) (found ^. #segments) of
          digest : _ -> Right digest
          [] -> Left (FeedInvalid "index" "an index node is shorter than the visible feed")

indexNode :: SegmentLocator -> Integer -> IO (Either FeedError IndexNode)
indexNode (SegmentLocator store headValue nodes completedRef) leaf = do
  cached <- Map.lookup leaf <$> readIORef nodes
  case cached of
    Just node -> pure (Right node)
    Nothing -> do
      let tailLeaf = (headValue ^. #count - 1) `div` segmentCapacity `div` leafCapacity
      digestResult <-
        if leaf == tailLeaf
          then pure (maybe (Left (FeedInvalid "head.json" "a non-empty feed names no tail node")) Right (headValue ^. #tail))
          else do
            listed <- completedNodes
            pure $ case drop (fromIntegral leaf) <$> listed of
              Right (digest : _) -> Right digest
              Right [] -> Left (FeedInvalid "index" "a completed index node is missing from its list")
              Left err -> Left err
      case digestResult of
        Left err -> pure (Left err)
        Right digest -> do
          loaded <- readFeedObject store indexKey digest
          case loaded >>= decodeLayout "index" of
            Right node | node ^. #number == leaf -> Right node <$ modifyIORef' nodes (Map.insert leaf node)
            Right _ -> pure (Left (FeedInvalid "index" "an index node has the wrong number"))
            Left err -> pure (Left err)
  where
    completedNodes = do
      cached <- readIORef completedRef
      case (cached, headValue ^. #completed) of
        (Just listed, _) -> pure (Right listed)
        (Nothing, Nothing) -> pure (Right [])
        (Nothing, Just digest) -> do
          loaded <- readFeedObject store indexKey digest
          case loaded >>= decodeLayout "completed" of
            Right (Completed listed) -> Right listed <$ writeIORef completedRef (Just listed)
            Left err -> pure (Left err)

loadSegment :: FeedStore -> Integer -> ContentDigest -> IO (Either FeedError Segment)
loadSegment store k digest = do
  loaded <- readFeedObject store segmentKey digest
  pure $ do
    segment <- loaded >>= decodeLayout "segment"
    unless (segment ^. #start == k * segmentCapacity) (Left (FeedInvalid "segment" "a segment starts at the wrong position"))
    pure segment

idDigits :: EventId -> String
idDigits = T.unpack . T.drop 3 . eventIdText

-- | The positions of the IDs already in the trie rooted at @root@.
lookupIds :: FeedStore -> Maybe ContentDigest -> [EventId] -> IO (Either FeedError (Map EventId Integer))
lookupIds _ Nothing _ = pure (Right Map.empty)
lookupIds store (Just root) wanted = go 0 root (Map.fromList [(eventId, ()) | eventId <- wanted])
  where
    go depth digest pending
      | Map.null pending = pure (Right Map.empty)
      | otherwise = do
          loaded <- readFeedObject store idsKey digest
          case loaded >>= decodeLayout "ids" of
            Left err -> pure (Left err)
            Right (IdLeaf entries) -> pure (Right (Map.restrictKeys (Map.fromList entries) (Map.keysSet pending)))
            Right (IdBranch children) -> do
              let byDigit = Map.fromListWith Map.union [(digitAt depth eventId, Map.singleton eventId ()) | eventId <- Map.keys pending]
              results <- traverse (\(digit, group) -> maybe (pure (Right Map.empty)) (\child -> go (depth + 1) child group) (Map.lookup digit children)) (Map.toList byDigit)
              pure (Map.unions <$> sequence results)

digitAt :: Int -> EventId -> Char
digitAt depth eventId = case drop depth (idDigits eventId) of
  digit : _ -> digit
  [] -> '0'

-- | Insert new IDs (none already present) and return the new root. Only the
-- nodes on the touched paths are read and written.
insertIds :: FeedStore -> Maybe ContentDigest -> [(EventId, Integer)] -> IO (Either FeedError (Maybe ContentDigest))
insertIds _ root [] = pure (Right root)
insertIds store root additions = fmap Just <$> go 0 root additions
  where
    go :: Int -> Maybe ContentDigest -> [(EventId, Integer)] -> IO (Either FeedError ContentDigest)
    go depth digest added = do
      current <- case digest of
        Nothing -> pure (Right (IdLeaf []))
        Just existing -> (>>= decodeLayout "ids") <$> readFeedObject store idsKey existing
      case current of
        Left err -> pure (Left err)
        Right (IdLeaf entries)
          | length entries + length added <= 64 || depth >= 31 -> publishFeedObject store idsKey (encodeLayout (IdLeaf (sortOn fst (entries <> added))))
          | otherwise -> branch depth (Map.empty :: Map Char ContentDigest) (entries <> added) True
        Right (IdBranch children) -> branch depth children added False
    branch depth children added splitting = do
      let groups = Map.fromListWith (flip (<>)) [(digitAt depth eventId, [(eventId, position)]) | (eventId, position) <- added]
      written <- traverse (\(digit, group) -> fmap ((,) digit) <$> go (depth + 1) (if splitting then Nothing else Map.lookup digit children) group) (Map.toList groups)
      case sequence written of
        Left err -> pure (Left err)
        Right updated -> publishFeedObject store idsKey (encodeLayout (IdBranch (Map.union (Map.fromList updated) children)))

instance ToJSON Segment where
  toJSON segment = object ["version" .= (1 :: Int), "start" .= (segment ^. #start), "entries" .= (segment ^. #entries)]

instance FromJSON Segment where
  parseJSON = layoutObject "segment" ["version", "start", "entries"] $ \o -> Segment <$> o .: "start" <*> o .: "entries"

instance ToJSON IndexNode where
  toJSON node = object ["version" .= (1 :: Int), "number" .= (node ^. #number), "segments" .= (node ^. #segments)]

instance FromJSON IndexNode where
  parseJSON = layoutObject "index node" ["version", "number", "segments"] $ \o -> IndexNode <$> o .: "number" <*> o .: "segments"

instance ToJSON Completed where
  toJSON (Completed leaves) = object ["version" .= (1 :: Int), "completed" .= leaves]

instance FromJSON Completed where
  parseJSON = layoutObject "completed index" ["version", "completed"] $ \o -> Completed <$> o .: "completed"

instance ToJSON IdNode where
  toJSON = \case
    IdLeaf entries -> object ["version" .= (1 :: Int), "entries" .= [object ["id" .= eventId, "position" .= position] | (eventId, position) <- entries]]
    IdBranch children -> object ["version" .= (1 :: Int), "children" .= Map.mapKeys T.singleton children]

instance FromJSON IdNode where
  parseJSON value = flip (withObject "id node") value $ \o ->
    if KM.member "children" o
      then layoutObject "id branch" ["version", "children"] (\fields -> IdBranch . Map.mapKeys T.head <$> (fields .: "children" :: Parser (Map Text ContentDigest))) value
      else layoutObject "id leaf" ["version", "entries"] (\fields -> IdLeaf <$> (fields .: "entries" >>= traverse (withObject "id entry" (\entry -> (,) <$> entry .: "id" <*> entry .: "position")))) value

layoutObject :: String -> [Key] -> (Object -> Parser a) -> Value -> Parser a
layoutObject label allowed parse = withObject label $ \o -> do
  unless (all (`elem` allowed) (KM.keys o)) (fail (label <> " has an unknown field"))
  version <- o .: "version"
  unless (version == (1 :: Int)) (fail ("unsupported " <> label <> " version"))
  parse o
