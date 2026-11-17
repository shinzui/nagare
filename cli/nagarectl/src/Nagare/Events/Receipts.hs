{-# LANGUAGE OverloadedStrings #-}

-- | The backup collector's observation chain (EP-233), in the lifecycle
-- prefix beside the feed. A verified backup becomes an immutable
-- observation at @receipts/observations/<sequence>.json@, linked to the one
-- before it by digest, and is committed when the collector head's chain
-- position advances over it in one conditional write, together with the
-- collector's state. The feed materializer consumes committed observations
-- after its receipt checkpoint, exactly as it consumes the journal: an
-- observation the head does not commit is invisible.
--
-- An observation published at the head's next sequence whose head write
-- never landed is an orphan of this chain; the next append adopts it as
-- history rather than wedge the chain, as the journal does (F38). Its
-- candidates were verified, so adopting it publishes nothing unverified.
module Nagare.Events.Receipts
  ( CollectorHead (..)
  , collectorHeadVersion
  , Observation (..)
  , observationVersion
  , ObservedCollector
  , observedCollectorHead
  , observeCollector
  , replaceCollectorHead
  , observationKey
  , stateKey
  , publishObservation
  , observationDigest
  , PublishOutcome (..)
  , ReceiptBatch (..)
  , readReceiptChain
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Source (EventCandidate, SourceCheckpoint (..))
import Nagare.Events.Store
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | Constant size: the chain position the collector committed up to and
-- the digest of its state object.
data CollectorHead = CollectorHead
  { schemaVersion :: !Int
  , binding :: !ContextBinding
  , generation :: !Integer
  , chain :: !SourceCheckpoint
  , state :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

collectorHeadVersion :: Int
collectorHeadVersion = 1

-- | Verified completion candidates, observed together.
data Observation = Observation
  { schemaVersion :: !Int
  , number :: !Integer
  , previous :: !(Maybe ContentDigest)
  , observedAt :: !Text
  , events :: ![EventCandidate]
  }
  deriving stock (Eq, Show, Generic)

observationVersion :: Int
observationVersion = 1

collectorHeadKey :: ObjectName
collectorHeadKey = ObjectName "receipts/head.json"

observationKey :: Integer -> ObjectName
observationKey n = ObjectName ("receipts/observations/" <> T.pack (show n) <> ".json")

stateKey :: ContentDigest -> ObjectName
stateKey digest = ObjectName ("receipts/state/" <> digestText digest <> ".json")

data ObservedCollector = ObservedCollector !(Maybe CollectorHead) !(Maybe Generation)
  deriving stock (Eq, Show)

observedCollectorHead :: ObservedCollector -> Maybe CollectorHead
observedCollectorHead (ObservedCollector current _) = current

observeCollector :: FeedStore -> ContextBinding -> IO (Either FeedError ObservedCollector)
observeCollector store expected = do
  outcome <- getObject (feedStoreOps store) collectorHeadKey
  pure $ case outcome of
    GetUnknown reason -> Left (FeedTransport reason)
    ObjectAbsent -> Right (ObservedCollector Nothing Nothing)
    ObjectFound tag bytes -> do
      headValue <- decodeCanonical "receipts/head.json" bytes
      unless (headValue ^. #binding == expected) (Left FeedBindingMismatch)
      pure (ObservedCollector (Just headValue) (Just tag))

-- | Replace the observed collector head. A lost acknowledgement is settled
-- by reading the head back: equal bytes mean the write landed.
replaceCollectorHead :: FeedStore -> ObservedCollector -> CollectorHead -> IO (Either FeedError ReplaceOutcome)
replaceCollectorHead store (ObservedCollector current tag) replacement
  | replacement ^. #generation /= maybe 0 ((+ 1) . (^. #generation)) current = pure (Left (FeedConflict "replacement collector head generation is not the next generation"))
  | otherwise = do
      let bytes = encodeCanonical replacement
      outcome <- putObject (feedStoreOps store) (maybe IfAbsent IfGenerationMatches tag) collectorHeadKey bytes
      case outcome of
        PutWritten _ -> pure (Right Replaced)
        PutPreconditionFailed -> pure (Right Superseded)
        PutNoEffect reason -> pure (Left (FeedTransport reason))
        PutUnknown reason -> do
          reread <- getObject (feedStoreOps store) collectorHeadKey
          pure $ case reread of
            ObjectFound _ found | found == bytes -> Right Replaced
            ObjectFound _ _ -> Right Superseded
            ObjectAbsent -> Left (FeedTransport reason)
            GetUnknown again -> Left (FeedTransport again)

data PublishOutcome
  = -- | This observation is at its sequence.
    Published
  | -- | An orphan of this chain holds the sequence: commit it first.
    Orphan !Observation
  deriving stock (Eq, Show)

-- | Publish an observation at its sequence, create-only. Equal bytes there
-- are an idempotent success; an observation of the same chain position
-- with other bytes is an orphan to adopt; anything else conflicts.
publishObservation :: FeedStore -> Observation -> IO (Either FeedError PublishOutcome)
publishObservation store observation = do
  let name = observationKey (observation ^. #number)
      bytes = encodeCanonical observation
  outcome <- putObject (feedStoreOps store) IfAbsent name bytes
  case outcome of
    PutWritten _ -> pure (Right Published)
    _ -> do
      existing <- getObject (feedStoreOps store) name
      pure $ case (outcome, existing) of
        (_, ObjectFound _ found)
          | found == bytes -> Right Published
          | otherwise -> do
              other <- decodeCanonical "observation" found
              if other ^. #number == observation ^. #number && other ^. #previous == observation ^. #previous
                then Right (Orphan other)
                else Left (FeedConflict "an observation of another chain holds the sequence")
        (PutNoEffect reason, _) -> Left (FeedTransport reason)
        (PutUnknown reason, _) -> Left (FeedTransport reason)
        (_, GetUnknown reason) -> Left (FeedTransport reason)
        _ -> Left (FeedTransport "could not publish the observation")

-- | The digest the next observation links to.
observationDigest :: Observation -> ContentDigest
observationDigest = contentDigest . encodeCanonical

data ReceiptBatch = ReceiptBatch
  { observations :: ![(SourceCheckpoint, Observation)]
  -- ^ Each committed observation, with the checkpoint after it.
  , checkpoint :: !SourceCheckpoint
  }
  deriving stock (Eq, Show, Generic)

-- | At most @budget@ committed observations after @from@: one collector
-- head read, then exact reads of the observations after the checkpoint,
-- linked by digest. A context whose collection was never activated has
-- none.
readReceiptChain :: FeedStore -> ContextBinding -> SourceCheckpoint -> Int -> IO (Either FeedError ReceiptBatch)
readReceiptChain store binding from budget = do
  observed <- observeCollector store binding
  case observedCollectorHead <$> observed of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right (ReceiptBatch [] from))
    Right (Just headValue)
      | from ^. #next > headValue ^. #chain . #next -> pure (Left (FeedInvalid "receipts/head.json" "the feed's receipt checkpoint is ahead of the collector"))
      | otherwise -> do
          let wanted = take (max 1 budget) [from ^. #next .. headValue ^. #chain . #next - 1]
          loaded <- traverse (\n -> fmap ((,) n) <$> readOne n) wanted
          pure (sequence loaded >>= link from . Map.toAscList . Map.fromList)
  where
    readOne n = do
      outcome <- getImmutableObject (feedStoreOps store) (observationKey n)
      pure $ case outcome of
        ImmutableFound bytes -> (,) (contentDigest bytes) <$> decodeCanonical "observation" bytes
        ImmutableMissing -> Left (FeedInvalid "observation" "a committed observation is missing")
        ImmutableUnknown reason -> Left (FeedTransport reason)
    link position [] = Right (ReceiptBatch [] position)
    link position ((n, (digest, observation)) : rest)
      | observation ^. #number /= n || observation ^. #previous /= position ^. #previous = Left (FeedInvalid "observation" "the observation chain is broken")
      | otherwise = do
          let after = SourceCheckpoint (n + 1) (Just digest)
          ReceiptBatch later final <- link after rest
          pure (ReceiptBatch ((after, observation) : later) final)

encodeCanonical :: (ToJSON a) => a -> ByteString
encodeCanonical = either (error . T.unpack) id . canonicalValue . toJSON

decodeCanonical :: (FromJSON a, ToJSON a) => Text -> ByteString -> Either FeedError a
decodeCanonical label bytes = do
  value <- first (FeedInvalid label . T.pack) (eitherDecodeStrict' bytes)
  unless (encodeCanonical value == bytes) (Left (FeedInvalid label "not canonical"))
  pure value

instance ToJSON CollectorHead where
  toJSON headValue =
    object
      [ "version" .= (headValue ^. #schemaVersion)
      , "binding" .= (headValue ^. #binding)
      , "generation" .= (headValue ^. #generation)
      , "chain" .= (headValue ^. #chain)
      , "state" .= (headValue ^. #state)
      ]

instance FromJSON CollectorHead where
  parseJSON = withObject "collector head" $ \o -> do
    unless (all (`elem` ["version", "binding", "generation", "chain", "state"]) (KM.keys o)) (fail "the collector head has an unknown field")
    version <- o .: "version"
    unless (version == collectorHeadVersion) (fail "unsupported collector head version")
    CollectorHead version <$> o .: "binding" <*> o .: "generation" <*> o .: "chain" <*> o .: "state"

instance ToJSON Observation where
  toJSON observation =
    object
      [ "version" .= (observation ^. #schemaVersion)
      , "number" .= (observation ^. #number)
      , "previous" .= (observation ^. #previous)
      , "observedAt" .= (observation ^. #observedAt)
      , "events" .= (observation ^. #events)
      ]

instance FromJSON Observation where
  parseJSON = withObject "observation" $ \o -> do
    unless (all (`elem` ["version", "number", "previous", "observedAt", "events"]) (KM.keys o)) (fail "the observation has an unknown field")
    version <- o .: "version"
    unless (version == observationVersion) (fail "unsupported observation version")
    Observation version <$> o .: "number" <*> o .: "previous" <*> o .: "observedAt" <*> o .: "events"
