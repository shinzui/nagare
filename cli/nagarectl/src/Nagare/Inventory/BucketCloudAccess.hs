-- | EP-284 M1: the derived Pulumi config that gives each granted workload of
-- an app object bucket a keyless Google identity. Names are derived only here.
--
-- @nagare:appBuckets@ lists every accepted bucket with its Google name, its
-- expiry rules, whether it is retired (no grant left) and, per grant, the
-- Kubernetes subject the pool provider maps, the account ID, the access and the
-- signing flag. @nagare:workloadIdentity@ carries the cluster's issuer and JWKS,
-- both public. A context with no bucket derives neither key, so an existing
-- stack previews unchanged.
module Nagare.Inventory.BucketCloudAccess
  ( googleBucketName
  , grantAccountId
  , grantAccountEmail
  , grantSubject
  , workloadAccountName
  , cloudAppBuckets
  , appBucketConfigKeys
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.ObjectBucket
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (Namespace, ServiceName, namespaceText, serviceNameText)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ObjectBucket (scopeBucket)
import Nagare.Resource.Inventory (ScopeDeclaration)
import Nagare.Resource.Types (digestText)
import Nagare.Resource.Wire (canonicalValue)

-- | @PROJECT-CONTEXT-NAME@, the bucket's Google name. A name past Google's 63
-- characters keeps a prefix and ends in a digest of the whole, so two buckets
-- never share one.
googleBucketName :: Text -> Text -> BucketName -> Text
googleBucketName project context name
  | T.length full <= 63 = full
  | otherwise = T.dropWhileEnd (== '-') (T.take 50 full) <> "-" <> short 12 full
  where
    full = project <> "-" <> context <> "-" <> bucketNameText name

-- | The Kubernetes ServiceAccount a granted workload runs as.
workloadAccountName :: ServiceName -> Text
workloadAccountName workload = "nagare-wl-" <> serviceNameText workload

-- | The grant's Google service account ID: @nagare-wl-@ and a digest of the
-- namespace and workload, 30 characters, so one workload has one account
-- whatever buckets it is granted.
grantAccountId :: Namespace -> ServiceName -> Text
grantAccountId ns workload = "nagare-wl-" <> short 20 (namespaceText ns <> "/" <> serviceNameText workload)

grantAccountEmail :: Text -> Namespace -> ServiceName -> Text
grantAccountEmail project ns workload = grantAccountId ns workload <> "@" <> project <> ".iam.gserviceaccount.com"

-- | The subject the pool provider maps from the projected token's @sub@.
grantSubject :: Namespace -> ServiceName -> Text
grantSubject ns workload = "system:serviceaccount:" <> namespaceText ns <> ":" <> workloadAccountName workload

-- | The accepted buckets, by name.
cloudAppBuckets :: [ScopeDeclaration] -> [ObjectBucket]
cloudAppBuckets scopes = sortOn (bucketNameText . (^. #name)) [declared | scope <- scopes, Just declared <- [scopeBucket scope]]

-- | The derived config for the accepted buckets: none without a bucket;
-- otherwise @nagare:appBuckets@ and, given the cluster's issuer and JWKS,
-- @nagare:workloadIdentity@. A bucket refuses without them, since its grants
-- could not be federated.
appBucketConfigKeys :: Text -> Text -> Maybe (Text, Value) -> [ObjectBucket] -> Either Text [(Text, Text)]
appBucketConfigKeys _ _ _ [] = Right []
appBucketConfigKeys project context identity buckets = do
  (issuer, jwks) <- maybe (Left "an app bucket on a cloud context needs the cluster's service-account issuer and JWKS; is the cluster up?") Right identity
  let names = map (googleBucketName project context . (^. #name)) buckets
  unless (length names == length (nubText names)) (Left "two app buckets derive the same Google bucket name")
  entries <-
    canonicalValue
      ( toJSON
          [ object
              [ "name" .= bucketNameText (bucket ^. #name)
              , "bucket" .= googleBucketName project context (bucket ^. #name)
              , "retired" .= null (bucket ^. #grants)
              , "expire" .= [object ["prefix" .= objectPrefixText (rule ^. #prefix), "afterDays" .= positiveDaysInt (rule ^. #afterDays)] | rule <- sortOn (objectPrefixText . (^. #prefix)) (bucket ^. #expire)]
              , "grants"
                  .= [ object
                         [ "subject" .= grantSubject (grant ^. #namespace) (grant ^. #workload)
                         , "accountId" .= grantAccountId (grant ^. #namespace) (grant ^. #workload)
                         , "access" .= bucketAccessToken (grant ^. #access)
                         , "signUrls" .= (grant ^. #signUrls)
                         ]
                     | grant <- sortOn (\grant -> (namespaceText (grant ^. #namespace), serviceNameText (grant ^. #workload))) (bucket ^. #grants)
                     ]
              ]
          | bucket <- buckets
          ]
      )
  federation <- canonicalValue (object ["issuer" .= issuer, "jwks" .= jwks])
  pure
    [ ("nagare:appBuckets", TE.decodeUtf8 entries)
    , ("nagare:workloadIdentity", TE.decodeUtf8 federation)
    ]
  where
    nubText = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

short :: Int -> Text -> Text
short n = T.take n . digestText . contentDigest . TE.encodeUtf8
