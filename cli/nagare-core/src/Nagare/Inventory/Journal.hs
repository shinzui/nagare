{-# LANGUAGE OverloadedStrings #-}

-- | Immutable, digest-linked execution events.
module Nagare.Inventory.Journal
  ( TransactionId
  , mkTransactionId
  , transactionIdText
  , reviewDigestOf
  , OperationId
  , mkOperationId
  , operationIdText
  , FailureClass (..)
  , OperationState (..)
  , JournalEvent (..)
  , Convergence (..)
  , convergenceSchemaVersion
  , encodeJournalEvent
  , decodeJournalEvent
  , journalEventDigest
  , validateJournal
  , operationStates
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

newtype TransactionId = TransactionId Text deriving stock (Eq, Ord, Show)

mkTransactionId :: Text -> Either Text TransactionId
mkTransactionId value
  | validToken "tx-" value = Right (TransactionId value)
  | otherwise = Left "transaction id must start with tx- and contain lowercase ASCII, digits, or hyphens"

transactionIdText :: TransactionId -> Text
transactionIdText (TransactionId value) = value

-- | The review a transaction applies: its ID is @tx-@ and the review's
-- digest.
reviewDigestOf :: TransactionId -> Maybe ContentDigest
reviewDigestOf transaction = either (const Nothing) Just (mkContentDigest (T.drop 3 (transactionIdText transaction)))

newtype OperationId = OperationId Text deriving stock (Eq, Ord, Show)

mkOperationId :: Text -> Either Text OperationId
mkOperationId value
  | validToken "op-" value = Right (OperationId value)
  | otherwise = Left "operation id must start with op- and contain lowercase ASCII, digits, or hyphens"

operationIdText :: OperationId -> Text
operationIdText (OperationId value) = value

validToken :: Text -> Text -> Bool
validToken prefix value =
  prefix `T.isPrefixOf` value
    && T.length value > T.length prefix
    && T.all (\c -> ('a' <= c && c <= 'z') || ('0' <= c && c <= '9') || c == '-') value

data FailureClass
  = KnownNoEffect !Text
  | PartialOrUnknown !Text
  deriving stock (Eq, Show, Generic)

data OperationState
  = Pending
  | IntentRecorded
  | Completed !ContentDigest
  | Failed !FailureClass
  | Ambiguous
  | OperatorResolved !Text
  deriving stock (Eq, Show, Generic)

data JournalEvent = JournalEvent
  { eventSchemaVersion :: !Int
  , eventSequence :: !Integer
  , eventPreviousDigest :: !(Maybe ContentDigest)
  , eventTransaction :: !TransactionId
  , eventOperation :: !(Maybe OperationId)
  , eventState :: !OperationState
  , eventTimestamp :: !Text
  , eventDetail :: !Text
  , eventPhysical :: !(Maybe PhysicalIdentity)
  -- ^ ADR 27: the identity the provider returned for the object this
  -- operation wrote, when it returned one. Omitted from the encoding when
  -- absent, so events written before this field keep their bytes and digests.
  , eventConvergence :: !(Maybe Convergence)
  -- ^ EP-231: present only on the event a converged release commits in the
  -- same head replacement that clears its claim. Such an event has schema
  -- version 2 and every other event version 1, so no earlier bytes change.
  }
  deriving stock (Eq, Show, Generic)

-- | What a converged release committed: its review and, when the
-- transaction produced lifecycle source facts, the digest of the immutable
-- facts object published before the release.
data Convergence = Convergence
  { convergedReview :: !ContentDigest
  , convergedFacts :: !(Maybe ContentDigest)
  }
  deriving stock (Eq, Show, Generic)

-- | The schema version of a convergence event.
convergenceSchemaVersion :: Int
convergenceSchemaVersion = 2

instance ToJSON TransactionId where toJSON = String . transactionIdText

instance FromJSON TransactionId where
  parseJSON = withText "transaction id" (either (fail . T.unpack) pure . mkTransactionId)

instance ToJSON OperationId where toJSON = String . operationIdText

instance FromJSON OperationId where
  parseJSON = withText "operation id" (either (fail . T.unpack) pure . mkOperationId)

instance ToJSON FailureClass where toJSON = genericToJSON defaultOptions

instance FromJSON FailureClass where parseJSON = genericParseJSON defaultOptions

instance ToJSON OperationState where toJSON = genericToJSON defaultOptions

instance FromJSON OperationState where parseJSON = genericParseJSON defaultOptions

instance ToJSON JournalEvent where
  toJSON event =
    object $
      [ "version" .= eventSchemaVersion event
      , "sequence" .= eventSequence event
      , "previousDigest" .= eventPreviousDigest event
      , "transaction" .= eventTransaction event
      , "operation" .= eventOperation event
      , "state" .= eventState event
      , "timestamp" .= eventTimestamp event
      , "detail" .= eventDetail event
      ]
        <> ["physical" .= physical | Just physical <- [eventPhysical event]]
        <> ["convergence" .= convergence | Just convergence <- [eventConvergence event]]

instance ToJSON Convergence where
  toJSON convergence = object ["review" .= convergedReview convergence, "facts" .= convergedFacts convergence]

instance FromJSON Convergence where
  parseJSON = withObject "Convergence" $ \objectValue -> do
    unless (all (`elem` ["review", "facts"]) (KM.keys objectValue)) (fail "convergence has an unknown field")
    Convergence <$> objectValue .: "review" <*> objectValue .: "facts"

instance FromJSON JournalEvent where
  parseJSON = withObject "JournalEvent" $ \objectValue -> do
    let allowed = ["version", "sequence", "previousDigest", "transaction", "operation", "state", "timestamp", "detail", "physical", "convergence"]
    unless (all (`elem` allowed) (KM.keys objectValue)) (fail "journal event has an unknown field")
    event <-
      JournalEvent
        <$> objectValue .: "version"
        <*> objectValue .: "sequence"
        <*> objectValue .: "previousDigest"
        <*> objectValue .: "transaction"
        <*> objectValue .: "operation"
        <*> objectValue .: "state"
        <*> objectValue .: "timestamp"
        <*> objectValue .: "detail"
        <*> objectValue .:? "physical"
        <*> objectValue .:? "convergence"
    case eventConvergence event of
      Nothing -> unless (eventSchemaVersion event == 1) (fail "unsupported journal schema version")
      Just convergence -> do
        unless (eventSchemaVersion event == convergenceSchemaVersion) (fail "a convergence event must have journal schema version 2")
        unless (isNothing (eventOperation event) && eventState event == Completed (convergedReview convergence)) (fail "a convergence event completes its transaction's review")
    unless (eventSequence event >= 0) (fail "journal sequence must not be negative")
    pure event

encodeJournalEvent :: JournalEvent -> ByteString
encodeJournalEvent = either (error . T.unpack) id . canonicalValue . toJSON

decodeJournalEvent :: ByteString -> Either Text JournalEvent
decodeJournalEvent bytes = do
  event <- first T.pack (eitherDecodeStrict' bytes)
  canonical <- canonicalValue (toJSON event)
  unless (canonical == bytes) (Left "journal event is not canonical")
  pure event

journalEventDigest :: JournalEvent -> ContentDigest
journalEventDigest = contentDigest . encodeJournalEvent

-- | Latest per-operation state from a validated journal in sequence order.
operationStates :: TransactionId -> [JournalEvent] -> Map OperationId OperationState
operationStates transaction =
  foldl
    ( \states event -> case eventOperation event of
        Just operation
          | eventTransaction event == transaction ->
              Map.insert operation (eventState event) states
        _ -> states
    )
    Map.empty

validateJournal :: [JournalEvent] -> Either Text [JournalEvent]
validateJournal events = go Nothing 0 (sortOn eventSequence events)
  where
    go _ _ [] = Right (sortOn eventSequence events)
    go previous expected (event : rest) = do
      unless (eventSequence event == expected) (Left "journal sequence is missing, duplicated, or reordered")
      unless (eventPreviousDigest event == previous) (Left "journal digest chain is broken")
      go (Just (journalEventDigest event)) (expected + 1) rest
