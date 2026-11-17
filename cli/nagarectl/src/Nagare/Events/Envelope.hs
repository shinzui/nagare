{-# LANGUAGE OverloadedStrings #-}

-- | The public lifecycle event envelope (EP-231 M2): one immutable,
-- transport-neutral document per event. Its canonical bytes are usable
-- unchanged as an HTTP body or a future Kafka record value. Feed position is
-- publication metadata kept beside it, never inside it, and no URL, signing
-- header, broker name or delivery state enters it (ADR 33).
module Nagare.Events.Envelope
  ( EventId
  , mkEventId
  , eventIdText
  , eventIdFor
  , Envelope (..)
  , envelopeSchemaVersion
  , encodeEnvelope
  , decodeEnvelope
  , envelopeFor
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Source
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | @ev-@ and 32 lowercase hexadecimal digits.
newtype EventId = EventId Text deriving stock (Eq, Ord, Show)

mkEventId :: Text -> Either Text EventId
mkEventId value = case T.stripPrefix "ev-" value of
  Just digits | T.length digits == 32 && T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) digits -> Right (EventId value)
  _ -> Left "an event id is ev- and 32 lowercase hexadecimal digits"

eventIdText :: EventId -> Text
eventIdText (EventId value) = value

-- | The stable ID of a source in a context: derived from the context
-- identity and the versioned source key, never from a time or a position.
eventIdFor :: ContextId -> SourceKey -> EventId
eventIdFor context key =
  EventId
    ( "ev-"
        <> T.take 32 (digestText (contentDigest (either (error . T.unpack) id (canonicalValue (object ["context" .= contextIdText context, "key" .= sourceKeyText key, "version" .= (1 :: Int)])))))
    )

data Envelope = Envelope
  { schemaVersion :: !Int
  , eventId :: !EventId
  , context :: !ContextId
  , resource :: !ResourceRef
  , occurredAt :: !Text
  , observedAt :: !Text
  , publishedAt :: !Text
  , evidence :: ![Evidence]
  , payload :: !EventPayload
  }
  deriving stock (Eq, Show, Generic)

envelopeSchemaVersion :: Int
envelopeSchemaVersion = 1

-- | The envelope a candidate becomes when the feed publishes it.
envelopeFor :: ContextId -> Text -> Text -> EventCandidate -> Envelope
envelopeFor context observed published candidate =
  Envelope
    { schemaVersion = envelopeSchemaVersion
    , eventId = eventIdFor context (candidate ^. #key)
    , context
    , resource = candidate ^. #resource
    , occurredAt = candidate ^. #occurredAt
    , observedAt = observed
    , publishedAt = published
    , evidence = candidate ^. #evidence
    , payload = candidate ^. #payload
    }

encodeEnvelope :: Envelope -> ByteString
encodeEnvelope = either (error . T.unpack) id . canonicalValue . toJSON

decodeEnvelope :: ByteString -> Either Text Envelope
decodeEnvelope bytes = do
  envelope <- first T.pack (eitherDecodeStrict' bytes)
  canonical <- canonicalValue (toJSON envelope)
  unless (canonical == bytes) (Left "the event envelope is not canonical")
  pure envelope

instance ToJSON EventId where toJSON = String . eventIdText

instance FromJSON EventId where parseJSON = withText "event id" (either (fail . T.unpack) pure . mkEventId)

instance ToJSON Envelope where
  toJSON envelope =
    object
      [ "schemaVersion" .= (envelope ^. #schemaVersion)
      , "id" .= (envelope ^. #eventId)
      , "type" .= payloadKind (envelope ^. #payload)
      , "context" .= (envelope ^. #context)
      , "resource" .= (envelope ^. #resource)
      , "occurredAt" .= (envelope ^. #occurredAt)
      , "observedAt" .= (envelope ^. #observedAt)
      , "publishedAt" .= (envelope ^. #publishedAt)
      , "evidence" .= (envelope ^. #evidence)
      , "data" .= payloadData (envelope ^. #payload)
      ]
    where
      payloadData = \case
        AppDeployedPayload value -> toJSON value
        BackupCompletedPayload value -> toJSON value
        BackupAcceptedPayload value -> toJSON value

instance FromJSON Envelope where
  parseJSON = withObject "event envelope" $ \o -> do
    unless (all (`elem` ["schemaVersion", "id", "type", "context", "resource", "occurredAt", "observedAt", "publishedAt", "evidence", "data"]) (KM.keys o)) (fail "the event envelope has an unknown field")
    version <- o .: "schemaVersion"
    unless (version == envelopeSchemaVersion) (fail "unsupported event envelope version")
    kind <- o .: "type"
    dataValue <- o .: "data"
    payloadValue <- case kind of
      AppDeployed -> AppDeployedPayload <$> parseJSON dataValue
      DatabaseBackupCompleted -> BackupCompletedPayload <$> parseJSON dataValue
      DatabaseBackupAccepted -> BackupAcceptedPayload <$> parseJSON dataValue
    Envelope version
      <$> o .: "id"
      <*> o .: "context"
      <*> o .: "resource"
      <*> o .: "occurredAt"
      <*> o .: "observedAt"
      <*> o .: "publishedAt"
      <*> o .: "evidence"
      <*> pure payloadValue
