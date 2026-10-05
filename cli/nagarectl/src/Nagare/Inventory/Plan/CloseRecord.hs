-- | ADR 26 close records: the per-operation proof classes and per-scope
-- dispositions of a closed transaction; internal implementation behind
-- Nagare.Inventory.Plan and Nagare.Inventory.Execute.
module Nagare.Inventory.Plan.CloseRecord
  ( CloseRecord (..)
  , OperationClass (..)
  , ScopeDisposition (..)
  , closedMarker
  , closedRecordDigest
  , closeRecordKey
  , loadCloseRecord
  , publishCloseRecord
  , renderCloseRecord
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal
  ( JournalEvent (eventOperation, eventState, eventTransaction)
  , OperationId
  , OperationState (OperatorResolved)
  , TransactionId
  , operationIdText
  , transactionIdText
  )
import Nagare.Inventory.Store (InventoryStore, ScopeRevision, publishIfAbsent, readObject)
import Nagare.Resource.Types (ContentDigest, PhysicalIdentity, ResourceId, ScopeId, digestText, mkContentDigest, physicalIdentityText, resourceIdText, scopeIdText)
import Nagare.Resource.Wire (canonicalValue)

-- | One operation's proof class (ADR 26 §1).
data OperationClass
  = ClassCompleted
  | ClassNeverStarted
  | ClassRefused
  | ClassReverted
  | ClassNoEffect !Text
  | ClassLanded !PhysicalIdentity
  | ClassTargetGone !(Maybe PhysicalIdentity)
  | ClassTerminalPartial !PhysicalIdentity
  | ClassUnknown !Text !Text
  deriving stock (Eq, Show)

data ScopeDisposition
  = -- | Nothing in the scope took effect: its accepted revision returns to the
    -- review's base ('Nothing' when the review introduced the scope).
    RevertTo !(Maybe ScopeRevision)
  | -- | Something took effect: the scope keeps its desired revision, so
    -- everything created or landed stays owned.
    KeepDesired
  deriving stock (Eq, Show)

data CloseRecord = CloseRecord
  { closedTransaction :: !TransactionId
  , closedReview :: !ContentDigest
  , closedClasses :: !(Map OperationId OperationClass)
  , closedScopes :: !(Map ScopeId ScopeDisposition)
  , closedDesired :: !(Map ScopeId ScopeRevision)
  , closedRetainedRemoved :: !(Set ResourceId)
  , closedNeverStarted :: !(Set ResourceId)
  -- ^ Creates that never started (or were refused) and were observed absent
  -- at close; valid while the scope's accepted revision is 'closedDesired'.
  }
  deriving stock (Eq, Show)

closedMarker :: Text
closedMarker = "closed:"

-- | The digest of the transaction's close record, once it is journalled.
closedRecordDigest :: TransactionId -> [JournalEvent] -> Maybe ContentDigest
closedRecordDigest transaction events =
  listToMaybe
    [ digest
    | event <- events
    , eventTransaction event == transaction
    , isNothing (eventOperation event)
    , OperatorResolved marker <- [eventState event]
    , Just token <- [T.stripPrefix closedMarker marker]
    , Right digest <- [mkContentDigest token]
    ]
  where
    listToMaybe = foldr (const . Just) Nothing

closeRecordKey :: ContentDigest -> FilePath
closeRecordKey digest = "closes/" <> T.unpack (digestText digest) <> ".json"

publishCloseRecord :: InventoryStore -> CloseRecord -> IO (Either Text ContentDigest)
publishCloseRecord store record = case canonicalValue (toJSON record) of
  Left err -> pure (Left err)
  Right bytes -> do
    let digest = contentDigestOf bytes
    first (T.pack . show) <$> publishIfAbsent store (closeRecordKey digest) bytes

loadCloseRecord :: InventoryStore -> ContentDigest -> IO (Either Text CloseRecord)
loadCloseRecord store digest = do
  loaded <- readObject store (closeRecordKey digest)
  pure $ do
    bytes <- first (T.pack . show) loaded >>= maybe (Left "the close record is missing") Right
    unless (contentDigestOf bytes == digest) (Left "the close record digest differs")
    first T.pack (eitherDecodeStrict' bytes)

contentDigestOf :: ByteString -> ContentDigest
contentDigestOf = contentDigest

instance ToJSON CloseRecord where
  toJSON record =
    object
      [ "version" .= (1 :: Int)
      , "transaction" .= closedTransaction record
      , "review" .= closedReview record
      , "operations" .= [object ["operation" .= operation, "class" .= cls] | (operation, cls) <- Map.toAscList (closedClasses record)]
      , "scopes" .= [object ["scope" .= scope, "disposition" .= disposition] | (scope, disposition) <- Map.toAscList (closedScopes record)]
      , "desired" .= [object ["scope" .= scope, "revision" .= revision] | (scope, revision) <- Map.toAscList (closedDesired record)]
      , "retainedRemoved" .= Set.toAscList (closedRetainedRemoved record)
      , "neverStarted" .= Set.toAscList (closedNeverStarted record)
      ]

instance FromJSON CloseRecord where
  parseJSON = withObject "CloseRecord" $ \o -> do
    version <- o .: "version"
    unless (version == (1 :: Int)) (fail "unsupported close record version")
    operations <- o .: "operations" >>= traverse (withObject "operation class" (\v -> (,) <$> v .: "operation" <*> v .: "class"))
    scopes <- o .: "scopes" >>= traverse (withObject "scope disposition" (\v -> (,) <$> v .: "scope" <*> v .: "disposition"))
    desired <- o .: "desired" >>= traverse (withObject "desired revision" (\v -> (,) <$> v .: "scope" <*> v .: "revision"))
    CloseRecord
      <$> o .: "transaction"
      <*> o .: "review"
      <*> pure (Map.fromList operations)
      <*> pure (Map.fromList scopes)
      <*> pure (Map.fromList desired)
      <*> (Set.fromList <$> o .: "retainedRemoved")
      <*> (Set.fromList <$> o .: "neverStarted")

instance ToJSON OperationClass where
  toJSON cls = case cls of
    ClassCompleted -> object ["class" .= ("completed" :: Text)]
    ClassNeverStarted -> object ["class" .= ("never-started" :: Text)]
    ClassRefused -> object ["class" .= ("refused" :: Text)]
    ClassReverted -> object ["class" .= ("reverted" :: Text)]
    ClassNoEffect evidence -> object ["class" .= ("no-effect" :: Text), "evidence" .= evidence]
    ClassLanded physical -> object ["class" .= ("landed" :: Text), "physical" .= physical]
    ClassTargetGone physical -> object ["class" .= ("target-gone" :: Text), "physical" .= physical]
    ClassTerminalPartial physical -> object ["class" .= ("terminal-partial" :: Text), "physical" .= physical]
    ClassUnknown reason resolvesBy -> object ["class" .= ("unknown" :: Text), "reason" .= reason, "resolvesBy" .= resolvesBy]

instance FromJSON OperationClass where
  parseJSON = withObject "OperationClass" $ \o -> do
    tag <- o .: "class" :: Parser Text
    case tag of
      "completed" -> pure ClassCompleted
      "never-started" -> pure ClassNeverStarted
      "refused" -> pure ClassRefused
      "reverted" -> pure ClassReverted
      "no-effect" -> ClassNoEffect <$> o .: "evidence"
      "landed" -> ClassLanded <$> o .: "physical"
      "target-gone" -> ClassTargetGone <$> o .:? "physical"
      "terminal-partial" -> ClassTerminalPartial <$> o .: "physical"
      "unknown" -> ClassUnknown <$> o .: "reason" <*> o .: "resolvesBy"
      _ -> fail "unknown operation class"

instance ToJSON ScopeDisposition where
  toJSON disposition = case disposition of
    RevertTo revision -> object ["disposition" .= ("revert" :: Text), "base" .= revision]
    KeepDesired -> object ["disposition" .= ("keep" :: Text)]

instance FromJSON ScopeDisposition where
  parseJSON = withObject "ScopeDisposition" $ \o -> do
    tag <- o .: "disposition" :: Parser Text
    case tag of
      "revert" -> RevertTo <$> o .:? "base"
      "keep" -> pure KeepDesired
      _ -> fail "unknown scope disposition"

-- | The operator-facing summary of a close.
renderCloseRecord :: CloseRecord -> Text
renderCloseRecord record =
  T.unlines $
    ["closed " <> transactionIdText (closedTransaction record) <> "; nothing was written to any provider"]
      <> ["  " <> operationIdText operation <> ": " <> renderClass cls | (operation, cls) <- Map.toAscList (closedClasses record)]
      <> ["  scope " <> scopeIdText scope <> ": " <> renderDisposition disposition | (scope, disposition) <- Map.toAscList (closedScopes record)]
      <> ["  never started, absent at close: " <> T.intercalate ", " (map resourceIdText (Set.toAscList (closedNeverStarted record))) | not (Set.null (closedNeverStarted record))]
      <> ["inspect inventory status before saving a corrected review or a retirement"]
  where
    renderClass = \case
      ClassCompleted -> "completed"
      ClassNeverStarted -> "never started"
      ClassRefused -> "refused with no effect"
      ClassReverted -> "reverted"
      ClassNoEffect evidence -> "no effect (" <> evidence <> ")"
      ClassLanded physical -> "landed on " <> physicalIdentityText physical <> ", not ready"
      ClassTargetGone physical -> "target gone" <> maybe "" ((" (now " <>) . (<> ")") . physicalIdentityText) physical
      ClassTerminalPartial physical -> "terminal partial effect on " <> physicalIdentityText physical
      ClassUnknown reason resolvesBy -> "unknown: " <> reason <> " (resolved by " <> resolvesBy <> ")"
    renderDisposition = \case
      RevertTo _ -> "reverted to the review's base"
      KeepDesired -> "kept at the review's desired revision; nothing converged"
