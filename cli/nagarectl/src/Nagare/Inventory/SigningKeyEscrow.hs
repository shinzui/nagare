-- | Off-cluster escrow of one database's scheduled-backup signing key
-- (MasterPlan 23, decision D1). Freshness may count a verified upload that
-- awaits ingestion, and that verification needs the in-cluster HMAC key. The
-- escrow document keeps the key, bound to the observed Secret and source
-- incarnations, in sops-encrypted operator material, so such receipts remain
-- verifiable after the cluster is gone. Verification is evidence only: it never
-- grants restore authority, which still requires reviewed ingestion.
module Nagare.Inventory.SigningKeyEscrow
  ( SigningKeyEscrow (..)
  , EscrowSourceKind (..)
  , escrowObjectPrefix
  , renderSigningKeyEscrow
  , parseSigningKeyEscrow
  , escrowReceiptExpectation
  , escrowReceiptDatabases
  , EscrowDecision (..)
  , escrowDecision
  , archivedEscrowPath
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Database.AppDatabase.Backup (appDatabaseBackupKeyPrefix, appDatabaseBackupScheduleName)
import Nagare.Database.Backup (dbBackupKeyPrefix)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.BackupReceipt
  ( ScheduledReceiptExpectation (..)
  , scheduleMetadataObjective
  , scheduleMetadataObjectiveWith
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types (PhysicalIdentity, mkContentDigest, mkPhysicalIdentity, physicalIdentityText)
import Nagare.Resource.Wire (canonicalValue)
import System.FilePath (dropExtensions, takeExtensions)

-- | Which schedule signed the receipts: a database server's own, or one app
-- database's on a shared server (F145).
data EscrowSourceKind = DatabaseEscrow | AppDatabaseEscrow
  deriving stock (Eq, Show)

data SigningKeyEscrow = SigningKeyEscrow
  { context :: !Text
  , namespace :: !Text
  , database :: !Text
  , format :: !Text
  , signingSecretUid :: !PhysicalIdentity
  , statefulSetUid :: !PhysicalIdentity
  , pvcUid :: !PhysicalIdentity
  , hmacKey :: !Text
  , sourceKind :: !EscrowSourceKind
  }
  deriving stock (Eq, Generic)

-- | The key never appears in rendered diagnostics.
instance Show SigningKeyEscrow where
  show escrow =
    "SigningKeyEscrow "
      <> show (context escrow, namespace escrow, database escrow, format escrow)
      <> " <hmac key redacted>"

-- | What a new escrow does to the file already at its path.
data EscrowDecision
  = AlreadyEscrowed
  | -- | A replaced database: its old backups still need the old key, so the old
    -- file moves aside under its own volume's name.
    KeepPrevious
  | DifferentEscrow
  deriving stock (Eq, Show)

escrowDecision :: SigningKeyEscrow -> SigningKeyEscrow -> EscrowDecision
escrowDecision stored new
  | stored == new = AlreadyEscrowed
  | context stored == context new
      && namespace stored == namespace new
      && database stored == database new
      && sourceKind stored == sourceKind new
      && pvcUid stored /= pvcUid new =
      KeepPrevious
  | otherwise = DifferentEscrow

-- | Where a previous incarnation's escrow goes.
archivedEscrowPath :: FilePath -> SigningKeyEscrow -> FilePath
archivedEscrowPath path stored =
  dropExtensions path <> "." <> T.unpack (physicalIdentityText (pvcUid stored)) <> takeExtensions path

renderSigningKeyEscrow :: SigningKeyEscrow -> ByteString
renderSigningKeyEscrow escrow =
  Yaml.encode $
    object $
      [ "source" .= ("appDatabase" :: Text) | sourceKind escrow == AppDatabaseEscrow
      ]
        <> [ "kind" .= ("NagareBackupSigningKeyEscrow" :: Text)
           , "version" .= (1 :: Int)
           , "context" .= context escrow
           , "namespace" .= namespace escrow
           , "database" .= database escrow
           , "format" .= format escrow
           , "signingSecretUid" .= physicalIdentityText (signingSecretUid escrow)
           , "statefulSetUid" .= physicalIdentityText (statefulSetUid escrow)
           , "pvcUid" .= physicalIdentityText (pvcUid escrow)
           , "hmacKey" .= hmacKey escrow
           ]

parseSigningKeyEscrow :: ByteString -> Either Text SigningKeyEscrow
parseSigningKeyEscrow bytes = do
  value <- first (const "signing-key escrow is not valid YAML") (Yaml.decodeEither' bytes)
  (fields, kind) <- case value of
    Object root
      | KM.lookup "kind" root == Just (String "NagareBackupSigningKeyEscrow")
      , KM.lookup "version" root == Just (Number 1)
      , Just selected <- sourceOf root ->
          Right (root, selected)
    _ -> Left "signing-key escrow has an unknown kind, version or field set"
  let text key = case KM.lookup key fields of
        Just (String found) | not (T.null found) -> Right found
        _ -> Left "signing-key escrow has a missing or empty field"
  key <- text "hmacKey"
  unless
    (T.length key == 64 && T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) key)
    (Left "signing-key escrow key is not a 64-digit lowercase hex HMAC key")
  SigningKeyEscrow
    <$> text "context"
    <*> text "namespace"
    <*> text "database"
    <*> text "format"
    <*> (text "signingSecretUid" >>= mkPhysicalIdentity)
    <*> (text "statefulSetUid" >>= mkPhysicalIdentity)
    <*> (text "pvcUid" >>= mkPhysicalIdentity)
    <*> pure key
    <*> pure kind
  where
    sourceOf root = case (KM.size root, KM.lookup "source" root) of
      (10, Nothing) -> Just DatabaseEscrow
      (11, Just (String "appDatabase")) -> Just AppDatabaseEscrow
      _ -> Nothing

-- | Where the escrowed schedule writes its objects, under the store's root.
escrowObjectPrefix :: SigningKeyEscrow -> Text
escrowObjectPrefix escrow = case sourceKind escrow of
  DatabaseEscrow -> dbBackupKeyPrefix (database escrow)
  AppDatabaseEscrow -> appDatabaseBackupKeyPrefix (namespace escrow) (database escrow)

-- | The databases an app database's signed receipt says the run holds. Read
-- only from bytes whose digest the verified evidence covers.
escrowReceiptDatabases :: ByteString -> Either Text [Text]
escrowReceiptDatabases receiptBytes = do
  value <- first (const "scheduled receipt is not JSON") (eitherDecodeStrict receiptBytes)
  case value of
    Object root
      | Just (Object payload) <- KM.lookup "payload" root
      , Just (Object backup) <- KM.lookup "backup" payload
      , Just (Array names) <- KM.lookup "databases" backup
      , Just held <- traverse (\case String name -> Just name; _ -> Nothing) (toList names)
      , not (null held) ->
          Right held
    _ -> Left "scheduled receipt names no databases"

-- | Derive a receipt expectation without the cluster. The source incarnation
-- comes from the escrow; the schedule metadata comes from the receipt itself,
-- whose HMAC covers it, and must name this escrow's database and format.
-- 'Nagare.Inventory.ScheduledReceipt.inspectScheduledReceipt' then rereads the
-- exact provider versions, checks the HMAC, and hashes the archive.
escrowReceiptExpectation ::
  SigningKeyEscrow -> Text -> ByteString -> Either Text ScheduledReceiptExpectation
escrowReceiptExpectation escrow objectPrefix receiptBytes = do
  value <- first (const "scheduled receipt is not JSON") (eitherDecodeStrict receiptBytes)
  metadata <- case value of
    Object root
      | Just (Object payload) <- KM.lookup "payload" root
      , Just backup@(Object _) <- KM.lookup "backup" payload ->
          Right backup
    _ -> Left "scheduled receipt has no schedule metadata"
  fields <- case metadata of
    Object found -> Right found
    _ -> Left "scheduled receipt has no schedule metadata"
  let (nameField, scheduleName, objectiveOf) = case sourceKind escrow of
        DatabaseEscrow -> ("database", "nagare-dbbackup-" <> database escrow, scheduleMetadataObjective fields)
        AppDatabaseEscrow -> ("appDatabase", appDatabaseBackupScheduleName (database escrow), scheduleMetadataObjectiveWith 10 fields)
  objective <-
    maybe
      (Left "scheduled receipt metadata has an unknown field set")
      Right
      objectiveOf
  let field key = KM.lookup key fields
  unless
    ( field nameField == Just (String (database escrow))
        && field "namespace" == Just (String (namespace escrow))
        && field "schedule" == Just (String scheduleName)
        && field "format" == Just (String (format escrow))
    )
    (Left "scheduled receipt belongs to another database, namespace or format than the escrow")
  revision <- case field "scheduleRevision" of
    Just (String digest) -> mkContentDigest digest
    _ -> Left "scheduled receipt metadata lacks a schedule revision"
  keep <- case field "keep" of
    Just (Number count) | Just selected <- integral count, selected > 0 -> Right selected
    _ -> Left "scheduled receipt metadata has an invalid keep count"
  metadataBytes <- canonicalValue metadata
  pure
    ScheduledReceiptExpectation
      { scheduledObjectPrefix = objectPrefix
      , scheduledFormat = format escrow
      , scheduledKeep = keep
      , scheduledPolicyRevision = revision
      , scheduledMetadataDigest = contentDigest metadataBytes
      , scheduledStatefulUid = Just (statefulSetUid escrow)
      , scheduledPvcUid = pvcUid escrow
      , scheduledObjective = objective
      }
  where
    integral number =
      let whole = truncate number :: Integer
       in if fromInteger whole == number && whole <= toInteger (maxBound :: Int)
            then Just (fromInteger whole)
            else Nothing
