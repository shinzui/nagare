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
  , CloudAppBucket (..)
  , retiredGrantsKey
  , retiredGrantsRecord
  , scopeRetiredGrants
  , cloudAppBuckets
  , catalogAppBucketGrants
  , appBucketConfigKeys
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Config (encodeObjectBuckets)
import Nagare.Dsl.Load (decodeObjectBuckets)
import Nagare.Dsl.ObjectBucket
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (Namespace, ServiceName, namespaceText, serviceNameText)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ObjectBucket (scopeBucket)
import Nagare.Resource.Inventory (ScopeDeclaration, scopeOverrides)
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
-- bucket, namespace and workload, 30 characters. Each grant is its own
-- account, so retiring one bucket disables only that bucket's accounts.
grantAccountId :: BucketName -> Namespace -> ServiceName -> Text
grantAccountId bucket ns workload = "nagare-wl-" <> short 20 (bucketNameText bucket <> "/" <> namespaceText ns <> "/" <> serviceNameText workload)

grantAccountEmail :: Text -> BucketName -> Namespace -> ServiceName -> Text
grantAccountEmail project bucket ns workload = grantAccountId bucket ns workload <> "@" <> project <> ".iam.gserviceaccount.com"

-- | The subject the pool provider maps from the projected token's @sub@.
grantSubject :: Namespace -> ServiceName -> Text
grantSubject ns workload = "system:serviceaccount:" <> namespaceText ns <> ":" <> workloadAccountName workload

-- | An accepted bucket as the cloud review sees it. A retired bucket (one with no grant left)
-- keeps the grants it last had, so the review disables their accounts rather than deleting
-- them: a disabled account refuses every credential at once, and nothing is lost.
data CloudAppBucket = CloudAppBucket
  { bucket :: !ObjectBucket
  , retired :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | The scope override holding a retired bucket's last grants.
retiredGrantsKey :: Text
retiredGrantsKey = "bucket.retired-grants"

-- | The override a bucket with no grant records: its last grants, kept from the accepted
-- scope across every later plan. None when the bucket has grants or never had one.
retiredGrantsRecord :: ObjectBucket -> [BucketGrant] -> Maybe Text
retiredGrantsRecord declared kept
  | null (declared ^. #grants) && not (null kept) = Just (TE.decodeUtf8 (LBS.toStrict (encodeObjectBuckets [declared & #grants .~ kept])))
  | otherwise = Nothing

-- | The grants an accepted bucket scope holds, or, once it is retired, the ones it kept.
scopeRetiredGrants :: ScopeDeclaration -> [BucketGrant]
scopeRetiredGrants scope = case Map.lookup retiredGrantsKey (scopeOverrides scope) of
  Just record | Right [kept] <- decodeObjectBuckets (TE.encodeUtf8 record) -> kept ^. #grants
  _ -> maybe [] (^. #grants) (scopeBucket scope)

-- | The accepted buckets, by name.
cloudAppBuckets :: [ScopeDeclaration] -> [CloudAppBucket]
cloudAppBuckets scopes =
  sortOn
    (bucketNameText . (^. #bucket . #name))
    [ if null (declared ^. #grants) then CloudAppBucket (declared & #grants .~ scopeRetiredGrants scope) True else CloudAppBucket declared False
    | scope <- scopes
    , Just declared <- [scopeBucket scope]
    ]

-- | Each accepted bucket's declared name with its grants' account IDs and
-- signing flags, which 'Nagare.Inventory.Cloud.withAppBuckets' instantiates.
-- A retired bucket's kept grants stay, so their accounts are disabled, not deleted.
catalogAppBucketGrants :: [CloudAppBucket] -> [(Text, [(Text, Bool)])]
catalogAppBucketGrants buckets =
  [ (bucketNameText (entry ^. #bucket . #name), [(grantAccountId (entry ^. #bucket . #name) (grant ^. #namespace) (grant ^. #workload), grant ^. #signUrls) | grant <- entry ^. #bucket . #grants])
  | entry <- buckets
  ]

-- | The derived config for the accepted buckets: none without a bucket;
-- otherwise @nagare:appBuckets@ and, given the cluster's issuer and JWKS,
-- @nagare:workloadIdentity@. A bucket refuses without them, since its grants
-- could not be federated.
appBucketConfigKeys :: Text -> Text -> Maybe (Text, Value) -> [CloudAppBucket] -> Either Text [(Text, Text)]
appBucketConfigKeys _ _ _ [] = Right []
appBucketConfigKeys project context identity entries' = do
  let buckets = map (^. #bucket) entries'
  (issuer, jwks) <- maybe (Left "an app bucket on a cloud context needs the cluster's service-account issuer and JWKS; is the cluster up?") Right identity
  let names = map (googleBucketName project context . (^. #name)) buckets
  unless (length names == length (nubText names)) (Left "two app buckets derive the same Google bucket name")
  entries <-
    canonicalValue
      ( toJSON
          [ object
              [ "name" .= bucketNameText (bucket ^. #name)
              , "bucket" .= googleBucketName project context (bucket ^. #name)
              , "retired" .= retired
              , "expire" .= [object ["prefix" .= objectPrefixText (rule ^. #prefix), "afterDays" .= positiveDaysInt (rule ^. #afterDays)] | rule <- sortOn (objectPrefixText . (^. #prefix)) (bucket ^. #expire)]
              , "grants"
                  .= [ object
                         [ "subject" .= grantSubject (grant ^. #namespace) (grant ^. #workload)
                         , "accountId" .= grantAccountId (bucket ^. #name) (grant ^. #namespace) (grant ^. #workload)
                         , "access" .= bucketAccessToken (grant ^. #access)
                         , "signUrls" .= (grant ^. #signUrls)
                         ]
                     | grant <- sortOn (\grant -> (namespaceText (grant ^. #namespace), serviceNameText (grant ^. #workload))) (bucket ^. #grants)
                     ]
              ]
          | CloudAppBucket bucket retired <- entries'
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
