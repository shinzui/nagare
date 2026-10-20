-- | The evidence of an app database's maintenance window (EP-205, IR-31
-- AC-6), assembled read-only from what the inventory store already keeps:
-- the reviewed drain and resume plans, which record the server identity
-- each was reviewed against; their journalled completions, whose proofs
-- commit to the idle state the drain verified; and the newest ingested
-- backup receipt of the app database taken after the drain.
module Nagare.Inventory.AppDatabaseEvidence
  ( StepEvidence (..)
  , BackupEvidence (..)
  , AppDatabaseEvidence (..)
  , appDatabaseEvidence
  , loadAppDatabaseEvidence
  , renderAppDatabaseEvidence
  )
where

import Data.Aeson (ToJSON (toJSON), Value (Null), eitherDecodeStrict', object, (.=))
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (PlannedOperation (..))
import Nagare.Inventory.Adapters.AppDatabaseSessions (SessionPlan (..), SessionStep (..))
import Nagare.Inventory.Execute.Journal (readJournalAtHead)
import Nagare.Inventory.Journal (JournalEvent (..), OperationId, OperationState (..), TransactionId, mkTransactionId, transactionIdText)
import Nagare.Inventory.Plan (ReviewBundle, ReviewDocument (..), ReviewOperation (..), loadPublishedReview, reviewBundleDocument, reviewBundleNative, reviewDigest)
import Nagare.Inventory.Store (InventoryStore, StoreSnapshot (..), readStoreSnapshot)
import Nagare.Resource.Inventory (ScopeDeclaration, scopeId, scopeOverrides)
import Nagare.Resource.Types

-- | One completed drain or resume: its transaction, the journal event that
-- recorded its verified completion, and its reviewed plan.
data StepEvidence = StepEvidence
  { transaction :: !Text
  , sequenceNumber :: !Integer
  , completedAt :: !Text
  , proof :: !ContentDigest
  , plan :: !SessionPlan
  }
  deriving stock (Generic, Eq, Show)

data BackupEvidence = BackupEvidence
  { backupId :: !Text
  , receipt :: !Text
  , object' :: !Text
  , transaction :: !Text
  }
  deriving stock (Generic, Eq, Show)

data AppDatabaseEvidence = AppDatabaseEvidence
  { appDatabase :: !Text
  , drain :: !(Maybe StepEvidence)
  , resume :: !(Maybe StepEvidence)
  , backup :: !(Maybe BackupEvidence)
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON AppDatabaseEvidence where
  toJSON evidence =
    object
      [ "appDatabase" .= (evidence ^. #appDatabase)
      , "server" .= maybe Null (toJSON . (^. #plan . #identity)) (evidence ^. #drain)
      , "serverAtResume" .= maybe Null (toJSON . (^. #plan . #identity)) (evidence ^. #resume)
      , "blockedUsers" .= maybe Null (toJSON . (^. #plan . #users)) (evidence ^. #drain)
      , -- The completed drain's verified postcondition (ADR 26).
        "sessionsObserved" .= maybe Null (const (toJSON (0 :: Int))) (evidence ^. #drain)
      , "activeRuns" .= maybe Null (const (toJSON (0 :: Int))) (evidence ^. #drain)
      , "unfinishedMutations" .= maybe Null (const (toJSON ([] :: [Text]))) (evidence ^. #drain)
      , "drain" .= fmap step (evidence ^. #drain)
      , "backup" .= fmap backup' (evidence ^. #backup)
      , "resume" .= fmap step (evidence ^. #resume)
      ]
    where
      step s =
        object
          [ "transaction" .= (s ^. #transaction)
          , "sequence" .= (s ^. #sequenceNumber)
          , "completedAt" .= (s ^. #completedAt)
          , "proof" .= (s ^. #proof)
          , "operation" .= (s ^. #plan . #operation)
          ]
      backup' b =
        object
          [ "backupId" .= (b ^. #backupId)
          , "receipt" .= (b ^. #receipt)
          , "object" .= (b ^. #object')
          , "transaction" .= (b ^. #transaction)
          ]

-- | The newest completed drain and resume of the app database's scope, and
-- the newest receipt of its runs ingested after that drain.
appDatabaseEvidence :: Text -> ScopeId -> [ReviewBundle] -> [JournalEvent] -> [ScopeDeclaration] -> AppDatabaseEvidence
appDatabaseEvidence name owner bundles events accepted =
  AppDatabaseEvidence
    { appDatabase = name
    , drain = newest DrainStep
    , resume = newest ResumeStep
    , backup = listToMaybe (sortOn (Down . fst) receipts) <&> snd
    }
  where
    ownerPrefix = scopeIdText owner <> "/"
    transactionOf bundle = either (const Nothing) Just (mkTransactionId ("tx-" <> digestText (reviewDigest bundle)))
    completions :: Map (TransactionId, OperationId) (Integer, Text, ContentDigest)
    completions =
      Map.fromList
        [ ((eventTransaction event, operation), (eventSequence event, eventTimestamp event, digest))
        | event <- events
        , Just operation <- [eventOperation event]
        , Completed digest <- [eventState event]
        ]
    steps =
      [ StepEvidence (transactionIdText transaction') sequence' timestamp digest plan'
      | bundle <- bundles
      , Just transaction' <- [transactionOf bundle]
      , entry <- reviewOperations (reviewBundleDocument bundle)
      , reviewAdapterIdentity entry == "reviewed-app-database"
      , Just native <- [reviewNativeDigest entry >>= (`Map.lookup` reviewBundleNative bundle)]
      , Right plan' <- [eitherDecodeStrict' native :: Either String SessionPlan]
      , plan' ^. #operation == plannedOperationId (reviewPlannedOperation entry)
      , ownerPrefix `T.isPrefixOf` resourceIdText (plan' ^. #resource)
      , Just (sequence', timestamp, digest) <- [Map.lookup (transaction', plannedOperationId (reviewPlannedOperation entry)) completions]
      ]
    newest step' = listToMaybe (sortOn (Down . (^. #sequenceNumber)) [s | s <- steps, s ^. #plan . #step == step'])
    drainedAt = maybe 0 (^. #sequenceNumber) (newest DrainStep)
    -- When each scope was accepted: the admission of the review that desired it.
    admissions :: Map Text (Integer, Text)
    admissions =
      Map.fromList
        [ (scopeIdText scope', (eventSequence event, transactionIdText transaction'))
        | bundle <- bundles
        , Just transaction' <- [transactionOf bundle]
        , event <- events
        , eventTransaction event == transaction'
        , isNothing (eventOperation event)
        , Pending <- [eventState event]
        , scope' <- Map.keys (reviewDesiredRevisions (reviewBundleDocument bundle))
        ]
    receipts =
      [ (admitted, BackupEvidence runId receiptAddress objectAddress transaction')
      | scope' <- accepted
      , let overrides = scopeOverrides scope'
      , Map.lookup "scheduled.backup.source.scope" overrides == Just (scopeIdText owner)
      , Just runId <- [Map.lookup "scheduled.backup.id" overrides]
      , Just receiptAddress <- [Map.lookup "scheduled.backup.receipt" overrides]
      , Just objectAddress <- [Map.lookup "scheduled.backup.object" overrides]
      , Just (admitted, transaction') <- [Map.lookup (scopeIdText (scopeId scope')) admissions]
      , admitted > drainedAt
      ]

loadAppDatabaseEvidence :: InventoryStore -> Text -> ScopeId -> [ScopeDeclaration] -> IO (Either Text AppDatabaseEvidence)
loadAppDatabaseEvidence store name owner accepted = do
  snapshot <- readStoreSnapshot store
  case snapshot of
    Left err -> pure (Left (T.pack (show err)))
    Right state -> do
      published <- traverse (loadPublishedReview store) (Set.toAscList (storeSnapshotReviewDigests state))
      journal <- readJournalAtHead store (storeSnapshotHead state)
      pure $ do
        bundles <- first (T.pack . show) (sequence published)
        events <- first (T.pack . show) journal
        pure (appDatabaseEvidence name owner bundles events accepted)

-- | One line per field; a missing step prints as @absent@.
renderAppDatabaseEvidence :: AppDatabaseEvidence -> [Text]
renderAppDatabaseEvidence evidence =
  [ "app database: " <> evidence ^. #appDatabase
  , "server at drain: " <> maybe "absent" (identityText . (^. #plan . #identity)) (evidence ^. #drain)
  , "server at resume: " <> maybe "absent" (identityText . (^. #plan . #identity)) (evidence ^. #resume)
  , "blocked users: " <> maybe "absent" (T.intercalate ", " . (^. #plan . #users)) (evidence ^. #drain)
  , "drained: " <> maybe "absent" (const "0 sessions, 0 scheduled runs in flight, no unfinished mutations") (evidence ^. #drain)
  , "drain: " <> maybe "absent" step (evidence ^. #drain)
  , "backup: " <> maybe "absent" (\b -> b ^. #backupId <> " receipt " <> b ^. #receipt <> " ingested in " <> b ^. #transaction) (evidence ^. #backup)
  , "resume: " <> maybe "absent" step (evidence ^. #resume)
  ]
  where
    identityText = T.intercalate " " . map (\(key, value) -> key <> "=" <> value) . Map.toAscList
    step s = s ^. #transaction <> " #" <> T.show (s ^. #sequenceNumber) <> " at " <> s ^. #completedAt <> " proof " <> digestText (s ^. #proof)
