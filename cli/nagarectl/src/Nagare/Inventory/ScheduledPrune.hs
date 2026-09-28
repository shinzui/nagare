-- | Select exact scheduled backup versions for a reviewed keep-last-N prune.
-- The complete provider listing is compared with accepted receipt history;
-- random Job UIDs and ingestion order never stand in for completion order.
module Nagare.Inventory.ScheduledPrune
  ( ScheduledPruneCandidate (..)
  , selectScheduledPruneCandidates
  ) where

import Control.Monad (unless)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Text.Read (readMaybe)
import Nagare.Dsl.Prelude
import Nagare.Inventory.ScheduledStore (ListedObject (..))
import Nagare.Resource.Inventory (ScopeDeclaration, scopeId, scopeOverrides)
import Nagare.Resource.Types (ScopeId, scopeIdText)

data ScheduledPruneCandidate = ScheduledPruneCandidate
  { scheduledPruneScope :: !ScopeId
  , scheduledPruneId :: !Text
  , scheduledPruneObject :: !Text
  , scheduledPruneObjectVersion :: !Text
  , scheduledPruneObjectLength :: !Integer
  , scheduledPruneObjectSha256 :: !Text
  , scheduledPruneReceipt :: !Text
  , scheduledPruneReceiptVersion :: !Text
  , scheduledPruneReceiptLength :: !Integer
  , scheduledPruneReceiptDigest :: !Text
  , scheduledPruneCompleted :: !UTCTime
  }
  deriving stock (Eq, Show)

-- | Refuse incomplete, unaccepted, already-pruned-but-visible, or unknown
-- provider objects. A tie across the retention boundary has no provable
-- newest-N ordering, so it cannot authorize either deletion.
selectScheduledPruneCandidates
  :: ScopeId -> Text -> Text -> Text -> Int -> Set Text
  -> [ScopeDeclaration] -> [ListedObject]
  -> Either Text [ScheduledPruneCandidate]
selectScheduledPruneCandidates source bucketAddress prefix format keep protected scopes listed = do
  unless (keep > 0)
    (Left "scheduled backup retention must keep at least one run")
  unless (bucketAddress `T.isPrefixOf` prefix
      && not (T.null bucketAddress) && T.isSuffixOf "/" bucketAddress)
    (Left "scheduled backup prefix is outside the listed provider bucket")
  unless (Set.size (Set.fromList (map listedKey listed)) == length listed)
    (Left "scheduled backup provider listing repeats a key")
  let fields scope = scopeOverrides scope
      sourceName = scopeIdText source
      sameSource scope = Map.lookup "scheduled.backup.source.scope" (fields scope)
        == Just sourceName
      pruned = Set.fromList
        [selected | scope <- scopes,
          Just selected <- [Map.lookup "scheduled.prune.backup.scope" (fields scope)]]
      backups = filter (\scope -> sameSource scope
        && Set.notMember (scopeIdText (scopeId scope)) pruned) scopes
      visible = Map.fromList [(bucketAddress <> listedKey item, listedModified item)
        | item <- listed]
  entries <- traverse (accepted prefix format visible) backups
  let identifiers = map (scopeIdText . scheduledPruneScope) entries
  unless (Set.size (Set.fromList identifiers) == length entries
      && Set.size (Set.fromList (map scheduledPruneId entries)) == length entries)
    (Left "scheduled backup accepted history repeats a run")
  let expected = Set.fromList (concat
        [[scheduledPruneObject entry, scheduledPruneReceipt entry]
          | entry <- entries])
  unless (Map.keysSet visible == expected)
    (Left "scheduled backup listing differs from accepted unpruned receipts")
  let newest = sortOn (Down . scheduledPruneCompleted) entries
      (retained, eligible) = splitAt keep newest
  case (reverse retained, eligible) of
    (boundary : _, next : _)
      | scheduledPruneCompleted boundary == scheduledPruneCompleted next ->
          Left "scheduled backup completion times tie across the retention boundary"
    _ -> pure ()
  unless (all (\entry -> Set.notMember
      (scopeIdText (scheduledPruneScope entry)) protected) eligible)
    (Left "scheduled backup selected for pruning has an accepted dependency")
  pure (sortOn scheduledPruneCompleted eligible)

accepted :: Text -> Text -> Map.Map Text UTCTime -> ScopeDeclaration
  -> Either Text ScheduledPruneCandidate
accepted prefix format visible scope = do
  let fields = scopeOverrides scope
      required key = maybe (Left ("scheduled prune lacks " <> key)) Right
        (Map.lookup key fields)
      positive key = do
        raw <- required key
        value <- maybe (Left ("scheduled prune has invalid " <> key)) Right
          (readMaybe (T.unpack raw) :: Maybe Integer)
        unless (value > 0) (Left ("scheduled prune has empty " <> key))
        pure value
      digest key = do
        raw <- required key
        unless (T.length raw == 64 && T.all lowerHex raw)
          (Left ("scheduled prune has invalid " <> key))
        pure raw
  backupId <- required "scheduled.backup.id"
  unless (validUid backupId)
    (Left "scheduled prune backup ID is not a Job UID")
  object <- required "scheduled.backup.object"
  receipt <- required "scheduled.backup.receipt"
  unless (object == prefix <> backupId <> "." <> format
      && receipt == object <> ".receipt.json")
    (Left "scheduled prune backup addresses another key space")
  objectTime <- maybe (Left "scheduled backup object is missing") Right
    (Map.lookup object visible)
  receiptTime <- maybe (Left "scheduled backup receipt is missing") Right
    (Map.lookup receipt visible)
  unless (receiptTime >= objectTime)
    (Left "scheduled backup receipt predates its object")
  objectVersion <- required "scheduled.backup.object.version"
  receiptVersion <- required "scheduled.backup.receipt.version"
  unless (not (T.null objectVersion) && not (T.null receiptVersion))
    (Left "scheduled prune lacks exact provider versions")
  objectLength <- positive "scheduled.backup.object.length"
  receiptLength <- positive "scheduled.backup.receipt.length"
  objectSha <- digest "scheduled.backup.object.sha256"
  receiptDigest <- digest "scheduled.backup.receipt.digest"
  pure ScheduledPruneCandidate
    { scheduledPruneScope = scopeId scope
    , scheduledPruneId = backupId
    , scheduledPruneObject = object
    , scheduledPruneObjectVersion = objectVersion
    , scheduledPruneObjectLength = objectLength
    , scheduledPruneObjectSha256 = objectSha
    , scheduledPruneReceipt = receipt
    , scheduledPruneReceiptVersion = receiptVersion
    , scheduledPruneReceiptLength = receiptLength
    , scheduledPruneReceiptDigest = receiptDigest
    , scheduledPruneCompleted = receiptTime
    }

lowerHex :: Char -> Bool
lowerHex character = character >= '0' && character <= '9'
  || character >= 'a' && character <= 'f'

validUid :: Text -> Bool
validUid uid = T.length uid == 36 && and
  [if position `elem` [8, 13, 18, 23] then character == '-'
    else lowerHex character
    | (position, character) <- zip [0 :: Int ..] (T.unpack uid)]
