-- | Object-bucket responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.ObjectBucket
  ( JsonObjectBucket (..)
  , decodeObjectBuckets
  , toObjectBucket
  )
where

import Data.Aeson
  ( FromJSON (parseJSON)
  , eitherDecodeStrict
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  )
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields (JsonKindEnvelope (..), firstDuplicate)
import Nagare.Dsl.ObjectBucket
  ( BucketGrant (..)
  , ExpireRule (..)
  , ObjectBucket (..)
  , bucketNameText
  , mkBucketName
  , mkObjectPrefix
  , mkPositiveDays
  , parseBucketAccess
  , validateObjectBucket
  )
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (mkNamespace, mkServiceName)
import Nagare.Resource.Types (mkLogicalKey)

data JsonExpireRule = JsonExpireRule
  { prefix :: !Text
  , afterDays :: !Int
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonExpireRule where
  parseJSON = withObject "ExpireRule" $ \o -> JsonExpireRule <$> o .: "prefix" <*> o .: "afterDays"

data JsonBucketGrant = JsonBucketGrant
  { namespace :: !Text
  , workload :: !Text
  , access :: !Text
  , signUrls :: !Bool
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonBucketGrant where
  parseJSON = withObject "BucketGrant" $ \o ->
    JsonBucketGrant <$> o .: "namespace" <*> o .: "workload" <*> o .: "access" <*> o .:? "signUrls" .!= False

-- | The JSON 'Nagare.Dsl.Config.emitObjectBuckets' writes for one entry.
data JsonObjectBucket = JsonObjectBucket
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , expire :: ![JsonExpireRule]
  , grants :: ![JsonBucketGrant]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonObjectBucket where
  parseJSON = withObject "ObjectBucket" $ \o ->
    JsonObjectBucket <$> o .: "name" <*> o .:? "logicalKey" <*> o .:? "expire" .!= [] <*> o .:? "grants" .!= []

newtype JsonObjectBuckets = JsonObjectBuckets [JsonObjectBucket]

instance FromJSON JsonObjectBuckets where
  parseJSON = withObject "ObjectBuckets" $ \o -> JsonObjectBuckets <$> o .: "buckets"

toObjectBucket :: JsonObjectBucket -> Either LoadError ObjectBucket
toObjectBucket j = do
  name' <- first (MarshalError "name") (mkBucketName (j ^. #name))
  key' <- traverse (first (MarshalError "logicalKey") . mkLogicalKey) (j ^. #logicalKey)
  expire' <- traverse toRule (j ^. #expire)
  grants' <- traverse toGrant (j ^. #grants)
  first (MarshalError (j ^. #name)) $
    validateObjectBucket ObjectBucket {name = name', logicalKey = key', expire = expire', grants = grants'}
  where
    toRule rule =
      ExpireRule
        <$> first (MarshalError "expire.prefix") (mkObjectPrefix (rule ^. #prefix))
        <*> first (MarshalError "expire.afterDays") (mkPositiveDays (rule ^. #afterDays))
    toGrant grant =
      BucketGrant
        <$> first (MarshalError "grants.namespace") (mkNamespace (grant ^. #namespace))
        <*> first (MarshalError "grants.workload") (mkServiceName (grant ^. #workload))
        <*> maybe (Left (MarshalError "grants.access" ("unknown access: " <> grant ^. #access <> " (expected read-only or read-write)"))) Right (parseBucketAccess (grant ^. #access))
        <*> pure (grant ^. #signUrls)

-- | Decode the JSON a bucket config emits (via
-- 'Nagare.Dsl.Config.emitObjectBuckets'): every entry is validated, and two
-- entries may not share a name.
decodeObjectBuckets :: ByteString -> Either LoadError [ObjectBucket]
decodeObjectBuckets bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "ObjectBuckets" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode object buckets: " <> Text.pack perr))
        Right (JsonObjectBuckets entries) -> do
          when (null entries) (Left (MarshalError "buckets" "config declares no bucket"))
          buckets <- traverse toObjectBucket entries
          case firstDuplicate (map (bucketNameText . (^. #name)) buckets) of
            Just duplicate -> Left (MarshalError "buckets" ("bucket declared twice: " <> duplicate))
            Nothing -> Right buckets
      Just other -> Left (UnexpectedKind "ObjectBuckets" other)
      Nothing -> Left (UnexpectedKind "ObjectBuckets" "<none>")
