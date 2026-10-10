-- | Off-cluster escrow of one database's scheduled-backup signing key
-- (MasterPlan 23, decision D1). Freshness may count a verified upload that
-- awaits ingestion, and that verification needs the in-cluster HMAC key. The
-- escrow document keeps the key, bound to the observed Secret and source
-- incarnations, in sops-encrypted operator material, so such receipts remain
-- verifiable after the cluster is gone. Verification is evidence only: it never
-- grants restore authority, which still requires reviewed ingestion.
module Nagare.Inventory.SigningKeyEscrow
  ( SigningKeyEscrow (..)
  , renderSigningKeyEscrow
  , parseSigningKeyEscrow
  , escrowReceiptExpectation
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.BackupReceipt
  ( ScheduledReceiptExpectation (..)
  , scheduleMetadataObjective
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types (PhysicalIdentity, mkContentDigest, mkPhysicalIdentity, physicalIdentityText)
import Nagare.Resource.Wire (canonicalValue)

data SigningKeyEscrow = SigningKeyEscrow
  { context :: !Text
  , namespace :: !Text
  , database :: !Text
  , format :: !Text
  , signingSecretUid :: !PhysicalIdentity
  , statefulSetUid :: !PhysicalIdentity
  , pvcUid :: !PhysicalIdentity
  , hmacKey :: !Text
  }
  deriving stock (Eq, Generic)

-- | The key never appears in rendered diagnostics.
instance Show SigningKeyEscrow where
  show escrow =
    "SigningKeyEscrow "
      <> show (context escrow, namespace escrow, database escrow, format escrow)
      <> " <hmac key redacted>"

renderSigningKeyEscrow :: SigningKeyEscrow -> ByteString
renderSigningKeyEscrow escrow =
  Yaml.encode $
    object
      [ "kind" .= ("NagareBackupSigningKeyEscrow" :: Text)
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
  fields <- case value of
    Object root
      | KM.size root == 10
      , KM.lookup "kind" root == Just (String "NagareBackupSigningKeyEscrow")
      , KM.lookup "version" root == Just (Number 1) ->
          Right root
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
  objective <-
    maybe
      (Left "scheduled receipt metadata has an unknown field set")
      Right
      (scheduleMetadataObjective fields)
  let field key = KM.lookup key fields
  unless
    ( field "database" == Just (String (database escrow))
        && field "namespace" == Just (String (namespace escrow))
        && field "schedule" == Just (String ("nagare-dbbackup-" <> database escrow))
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
