-- | An app object bucket (EP-283): a private bucket declared from the
-- consuming app's repository, with expiry rules and one grant per workload.
-- Each granted workload gets its own credential, read-write or read-only.
--
-- A bucket is a standalone document, like an app database: its objects
-- outlive the applications that use it. A workload binds it by name with a
-- 'BucketBinding' and receives the @NAGARE_BUCKET_\<NAME\>_*@ variables.
module Nagare.Dsl.ObjectBucket
  ( -- * Names
    BucketName
  , mkBucketName
  , bucketNameText
  , BucketBinding (..)
  , bucketEnvPrefix

    -- * Expiry
  , ObjectPrefix
  , mkObjectPrefix
  , objectPrefixText
  , PositiveDays
  , mkPositiveDays
  , positiveDaysInt
  , ExpireRule (..)

    -- * Grants
  , BucketAccess (..)
  , bucketAccessToken
  , parseBucketAccess
  , BucketGrant (..)

    -- * Declaration
  , ObjectBucket (..)
  , validateObjectBucket
  , bucketGrantFor
  )
where

import Data.Generics.Labels ()
import Data.List (find)
import Data.Text qualified as Text
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (BucketBinding (..), BucketName, Namespace, ServiceName, bucketNameText, mkBucketName, namespaceText, serviceNameText)
import Nagare.Resource.Types (LogicalKey)

-- | The prefix of a bound workload's variables: @NAGARE_BUCKET_@, then the
-- bucket name upper-cased with @-@ as @_@.
bucketEnvPrefix :: BucketName -> Text
bucketEnvPrefix name = "NAGARE_BUCKET_" <> Text.toUpper (Text.replace "-" "_" (bucketNameText name))

-- | An object key prefix that ends in @/@, so a rule covers a directory and
-- never a sibling whose name merely starts the same. Constructor hidden; use
-- 'mkObjectPrefix'.
newtype ObjectPrefix = ObjectPrefix Text
  deriving stock (Eq, Ord, Show)

mkObjectPrefix :: Text -> Either Text ObjectPrefix
mkObjectPrefix t
  | Text.null t = Left "expiry prefix must not be empty"
  | not (Text.isSuffixOf "/" t) = Left ("expiry prefix must end in /: " <> t)
  | Text.isPrefixOf "/" t = Left ("expiry prefix must not start with /: " <> t)
  | Text.any (\c -> c < ' ' || c == '\DEL') t = Left "expiry prefix must not contain control characters"
  | otherwise = Right (ObjectPrefix t)

objectPrefixText :: ObjectPrefix -> Text
objectPrefixText (ObjectPrefix t) = t

-- | A whole number of days, at least one. Constructor hidden; use
-- 'mkPositiveDays'.
newtype PositiveDays = PositiveDays Int
  deriving stock (Eq, Ord, Show)

mkPositiveDays :: Int -> Either Text PositiveDays
mkPositiveDays n
  | n < 1 = Left ("expiry must be at least one day, got " <> Text.show n)
  | otherwise = Right (PositiveDays n)

positiveDaysInt :: PositiveDays -> Int
positiveDaysInt (PositiveDays n) = n

-- | Delete objects under a prefix after a number of days.
data ExpireRule = ExpireRule
  { prefix :: !ObjectPrefix
  , afterDays :: !PositiveDays
  }
  deriving stock (Generic, Eq, Show)

data BucketAccess = ReadOnly | ReadWrite
  deriving stock (Generic, Eq, Ord, Show)

bucketAccessToken :: BucketAccess -> Text
bucketAccessToken = \case
  ReadOnly -> "read-only"
  ReadWrite -> "read-write"

parseBucketAccess :: Text -> Maybe BucketAccess
parseBucketAccess = \case
  "read-only" -> Just ReadOnly
  "read-write" -> Just ReadWrite
  _ -> Nothing

-- | One workload's right to the bucket. The workload is named by its
-- namespace and its service, worker or task name. 'signUrls' lets it sign
-- URLs as itself; on the S3 backend any credential can presign, so it has no
-- effect there.
data BucketGrant = BucketGrant
  { namespace :: !Namespace
  , workload :: !ServiceName
  , access :: !BucketAccess
  , signUrls :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | A bucket. The record is open: its fields are validated values, and
-- 'validateObjectBucket' checks the rules that span fields.
data ObjectBucket = ObjectBucket
  { name :: !BucketName
  , logicalKey :: !(Maybe LogicalKey)
  , expire :: ![ExpireRule]
  , grants :: ![BucketGrant]
  }
  deriving stock (Generic, Eq, Show)

-- | Refuse two grants for one workload and two rules for one prefix.
validateObjectBucket :: ObjectBucket -> Either Text ObjectBucket
validateObjectBucket bucket = do
  case duplicate [(namespaceText (grant ^. #namespace), serviceNameText (grant ^. #workload)) | grant <- bucket ^. #grants] of
    Just (ns, workload') -> Left ("bucket " <> label <> " grants workload " <> workload' <> " in " <> ns <> " twice")
    Nothing -> Right ()
  case duplicate [objectPrefixText (rule ^. #prefix) | rule <- bucket ^. #expire] of
    Just prefix' -> Left ("bucket " <> label <> " has two expiry rules for prefix " <> prefix')
    Nothing -> Right ()
  pure bucket
  where
    label = bucketNameText (bucket ^. #name)
    duplicate values = fst <$> find (\(value, index) -> value `elem` take index values) (zip values [0 :: Int ..])

-- | The grant a workload holds on the bucket, if any.
bucketGrantFor :: Namespace -> ServiceName -> ObjectBucket -> Maybe BucketGrant
bucketGrantFor ns workload' bucket =
  find (\grant -> grant ^. #namespace == ns && grant ^. #workload == workload') (bucket ^. #grants)
