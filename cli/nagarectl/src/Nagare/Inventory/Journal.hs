{-# LANGUAGE OverloadedStrings #-}

-- | Immutable, digest-linked execution events.
module Nagare.Inventory.Journal
  ( TransactionId
  , mkTransactionId
  , transactionIdText
  , OperationId
  , mkOperationId
  , operationIdText
  , FailureClass (..)
  , OperationState (..)
  , JournalEvent (..)
  , encodeJournalEvent
  , decodeJournalEvent
  , journalEventDigest
  , validateJournal
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.List (sortOn)
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
  }
  deriving stock (Eq, Show, Generic)

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
    object
      [ "version" .= eventSchemaVersion event
      , "sequence" .= eventSequence event
      , "previousDigest" .= eventPreviousDigest event
      , "transaction" .= eventTransaction event
      , "operation" .= eventOperation event
      , "state" .= eventState event
      , "timestamp" .= eventTimestamp event
      , "detail" .= eventDetail event
      ]

instance FromJSON JournalEvent where
  parseJSON = withObject "JournalEvent" $ \objectValue -> do
    let allowed = ["version", "sequence", "previousDigest", "transaction", "operation", "state", "timestamp", "detail"]
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
    unless (eventSchemaVersion event == 1) (fail "unsupported journal schema version")
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

validateJournal :: [JournalEvent] -> Either Text [JournalEvent]
validateJournal events = go Nothing 0 (sortOn eventSequence events)
  where
    go _ _ [] = Right (sortOn eventSequence events)
    go previous expected (event : rest) = do
      unless (eventSequence event == expected) (Left "journal sequence is missing, duplicated, or reordered")
      unless (eventPreviousDigest event == previous) (Left "journal digest chain is broken")
      go (Just (journalEventDigest event)) (expected + 1) rest
