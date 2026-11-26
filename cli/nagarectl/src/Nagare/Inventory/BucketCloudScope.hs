-- | EP-284 M3: an app object bucket on a cloud context, as its standalone
-- scope's Kubernetes members. The bucket, its accounts and their bindings are
-- the cloud review's ('Nagare.Inventory.BucketCloudAccess'); this scope holds
-- what a granted workload needs in its own namespace:
--
-- * the Kubernetes ServiceAccount @nagare-wl-WORKLOAD@, with no RBAC and no
--   token of its own, whose projected token the pool provider trusts; a
--   workload runs as one account, so one workload can hold a grant of one
--   cloud bucket (a second bucket's account claims the same name and the
--   composition refuses it);
-- * the ConfigMap @nagare-bucket-BUCKET-WORKLOAD@ holding the
--   @external_account@ credential configuration that exchanges that token for
--   the grant's own Google account.
--
-- No member holds a key, and nothing here creates or deletes a bucket.
module Nagare.Inventory.BucketCloudScope
  ( CloudBucketTarget (..)
  , CloudBucketInput (..)
  , workloadIdentityPoolId
  , workloadIdentityAudience
  , identityTokenAudience
  , identityMountPath
  , identityTokenFile
  , credentialsFileKey
  , cloudBucketGoogleNameKey
  , cloudBucketProjectKey
  , credentialConfiguration
  , compileStandaloneCloudBucket
  , cloudBucketReviewEffects
  )
where

import Crypto.Hash (SHA256 (..), hashWith)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Traversable (for)
import Nagare.Dsl.Config (encodeObjectBuckets)
import Nagare.Dsl.ObjectBucket
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (namespaceText, serviceNameText)
import Nagare.Inventory.BucketCloudAccess (googleBucketName, grantAccountEmail, retiredGrantsKey, retiredGrantsRecord, workloadAccountName)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.ObjectBucket (bucketBackendKey, bucketCredentialSecretName, bucketDeclarationKey, bucketEndpointKey, bucketScopeId, scopeBucket)
import Nagare.Inventory.Plan.Types (ReviewEffect (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | The cloud context a bucket's identities live in.
data CloudBucketTarget = CloudBucketTarget
  { project :: !Text
  , context :: !Text
  , projectNumber :: !Text
  }
  deriving stock (Eq, Show, Generic)

data CloudBucketInput = CloudBucketInput
  { bucket :: !ObjectBucket
  , target :: !CloudBucketTarget
  , cluster :: !ResourceId
  , namespaces :: !(Map Text ResourceId)
  -- ^ The accepted namespace member of each grant's namespace.
  , source :: !SourceLocation
  , kept :: ![BucketGrant]
  -- ^ The grants the accepted scope holds or, once retired, kept ('scopeRetiredGrants').
  -- A bucket with no grant records them, so the cloud review disables their accounts.
  }
  deriving stock (Eq, Show, Generic)

-- | The pool's ID, as @infra/pulumi/src/components/NagareWorkloadIdentity.ts@
-- derives it: @nagare-CONTEXT@ when that is a valid pool ID, else @nagare-@
-- and the first 16 hex digits of the context's SHA-256.
workloadIdentityPoolId :: Text -> Text
workloadIdentityPoolId context'
  | valid candidate = candidate
  | otherwise = "nagare-" <> T.take 16 (T.pack (show (hashWith SHA256 (TE.encodeUtf8 context'))))
  where
    candidate = "nagare-" <> context'
    valid t =
      T.length t >= 4
        && T.length t <= 32
        && maybe False (isAsciiLower . fst) (T.uncons t)
        && T.all (\c -> isAsciiLower c || isDigit c || c == '-') t
        && maybe False ((\c -> isAsciiLower c || isDigit c) . snd) (T.unsnoc t)

-- | The provider's canonical name without its scheme: the credential
-- configuration's audience, which the token exchange names.
workloadIdentityAudience :: CloudBucketTarget -> Text
workloadIdentityAudience target' =
  "//iam.googleapis.com/projects/" <> target' ^. #projectNumber <> "/locations/global/workloadIdentityPools/" <> workloadIdentityPoolId (target' ^. #context) <> "/providers/kubernetes"

-- | The projected token's audience, which the provider allows.
identityTokenAudience :: CloudBucketTarget -> Text
identityTokenAudience target' = "https:" <> workloadIdentityAudience target'

identityMountPath :: Text
identityMountPath = "/var/run/nagare/identity"

identityTokenFile :: Text
identityTokenFile = identityMountPath <> "/token"

-- | The ConfigMap's one key, the credential configuration, mounted at
-- @/var/run/nagare/identity/credentials.json@.
credentialsFileKey :: Text
credentialsFileKey = "credentials.json"

-- | The scope overrides naming the bucket's Google name and project.
cloudBucketGoogleNameKey, cloudBucketProjectKey :: Text
cloudBucketGoogleNameKey = "bucket.google-name"
cloudBucketProjectKey = "bucket.project"

-- | The @external_account@ configuration a grant's workload reads: exchange
-- the projected token at STS for the pool, then impersonate the grant's
-- account, which alone holds the bucket's role.
credentialConfiguration :: CloudBucketTarget -> Text -> Value
credentialConfiguration target' accountEmail =
  object
    [ "type" .= ("external_account" :: Text)
    , "audience" .= workloadIdentityAudience target'
    , "subject_token_type" .= ("urn:ietf:params:oauth:token-type:jwt" :: Text)
    , "token_url" .= ("https://sts.googleapis.com/v1/token" :: Text)
    , "service_account_impersonation_url" .= ("https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/" <> accountEmail <> ":generateAccessToken")
    , "credential_source" .= object ["file" .= identityTokenFile, "format" .= object ["type" .= ("text" :: Text)]]
    ]

compileStandaloneCloudBucket ::
  CloudBucketInput ->
  Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneCloudBucket input = do
  declared <- first invalid (validateObjectBucket (input ^. #bucket))
  owner <- first invalid (bucketScopeId declared)
  key <- first invalid (maybe (mkLogicalKey (bucketNameText (declared ^. #name))) Right (declared ^. #logicalKey))
  let target' = input ^. #target
      name = declared ^. #name
      label = bucketNameText name
      googleName = googleBucketName (target' ^. #project) (target' ^. #context) name
      bind role value dependencies = do
        memberId <- mintResourceId owner key <$> first invalid (mkName role)
        native <- first invalid (canonicalValue value)
        (resource, bound) <-
          first
            (:| [])
            ( bindKubernetesObject
                KubernetesInput
                  { resourceId = memberId
                  , ownerScope = owner
                  , clusterId = input ^. #cluster
                  , inputObject = value
                  , objectDigest = contentDigest native
                  , lifecyclePolicy = DeleteWhenUnreferenced
                  , inputDataPolicy = Stateless
                  , inputSensitivity = Private
                  , sourceLocation = input ^. #source
                  }
            )
        pure (resource {dependencies = dependencies}, bound)
      labels workload' = object ["app.kubernetes.io/part-of" .= ("nagare" :: Text), "nagare.dev/bucket" .= label, "nagare.dev/workload" .= serviceNameText workload']
  members <- fmap concat . for (declared ^. #grants) $ \grant -> do
    let ns = namespaceText (grant ^. #namespace)
        workload' = grant ^. #workload
        email = grantAccountEmail (target' ^. #project) name (grant ^. #namespace) workload'
    namespaceId <-
      maybe
        (Left (invalid ("namespace " <> ns <> " of workload " <> serviceNameText workload' <> " is not an accepted namespace")))
        Right
        (Map.lookup ns (input ^. #namespaces))
    configuration <- first invalid (TE.decodeUtf8 <$> canonicalValue (credentialConfiguration target' email))
    account <-
      bind
        ("account-" <> serviceNameText workload')
        ( object
            [ "apiVersion" .= ("v1" :: Text)
            , "kind" .= ("ServiceAccount" :: Text)
            , "metadata" .= object ["name" .= workloadAccountName workload', "namespace" .= ns, "labels" .= labels workload', "annotations" .= object ["nagare.dev/google-service-account" .= email]]
            , "automountServiceAccountToken" .= False
            ]
        )
        [OrderedAfter namespaceId]
    credentials <-
      bind
        ("credentials-" <> serviceNameText workload')
        ( object
            [ "apiVersion" .= ("v1" :: Text)
            , "kind" .= ("ConfigMap" :: Text)
            , "metadata" .= object ["name" .= bucketCredentialSecretName name workload', "namespace" .= ns, "labels" .= labels workload', "annotations" .= object ["nagare.dev/google-service-account" .= email]]
            , "data" .= object [Key.fromText credentialsFileKey .= configuration]
            ]
        )
        [OrderedAfter namespaceId]
    pure [account, credentials]
  let record = LBS.toStrict (encodeObjectBuckets [declared])
  scope <- mkScopeDeclaration owner [ResourceBundle [Managed resource | (resource, _) <- members] [] [] [] [] []]
  pure
    ( withScopeConfigDigest
        (contentDigest record)
        ( withScopeOverrides
            ( Map.fromList $
                [(retiredGrantsKey, keptRecord) | Just keptRecord <- [retiredGrantsRecord declared (input ^. #kept)]]
                  <> [ (bucketDeclarationKey, TE.decodeUtf8 record)
                     , (bucketBackendKey, "gcs")
                     , (bucketEndpointKey, "https://storage.googleapis.com")
                     , (cloudBucketGoogleNameKey, googleName)
                     , (cloudBucketProjectKey, target' ^. #project)
                     ]
            )
            scope
        )
    , Map.fromList [(resource ^. #identity, (resource, native)) | (resource, native) <- members]
    )
  where
    invalid message = (inventoryError "invalid-object-bucket" message) {sources = [input ^. #source]} :| []

-- | What replacing a cloud bucket's accepted scope with @desired@ takes away: one line per
-- workload that loses access or the right to write, naming the Google account, and, when no
-- grant is left, one line saying that the bucket and its objects are kept. A retired bucket's
-- accounts are disabled by the next cloud review; a dropped grant's account is deleted by it.
cloudBucketReviewEffects :: ScopeSnapshot -> ScopeDeclaration -> [ReviewEffect]
cloudBucketReviewEffects snapshot desired = case (Map.lookup (scopeId desired) (snapshotScopes snapshot), scopeBucket desired) of
  (Just (_, accepted), Just after)
    | Just before <- scopeBucket accepted
    , Just project <- Map.lookup cloudBucketProjectKey (scopeOverrides accepted) ->
        let label = bucketNameText (before ^. #name)
            googleName = Map.findWithDefault label cloudBucketGoogleNameKey (scopeOverrides accepted)
            retiring = null (after ^. #grants)
            members = [resource | bundle <- scopeBundles accepted, Managed resource <- declarations bundle]
            credentialOf grant =
              listToMaybe
                [ resource ^. #identity
                | resource <- members
                , Kubernetes _ _ kind ns name' <- [resource ^. #address]
                , T.toLower (nameText kind) == "configmap"
                , fmap nameText ns == Just (namespaceText (grant ^. #namespace))
                , nameText name' == bucketCredentialSecretName (before ^. #name) (grant ^. #workload)
                ]
            lost grant = do
              credential <- credentialOf grant
              let who = "workload " <> serviceNameText (grant ^. #workload) <> " in " <> namespaceText (grant ^. #namespace)
                  account = grantAccountEmail project (before ^. #name) (grant ^. #namespace) (grant ^. #workload)
                  fate = if retiring then "the next cloud review disables its Google account " else "the next cloud review deletes its Google account "
              case bucketGrantFor (grant ^. #namespace) (grant ^. #workload) after of
                Nothing -> Just (ReviewEffect credential (who <> " loses " <> bucketAccessToken (grant ^. #access) <> " access to bucket " <> label <> "; " <> fate <> account))
                Just still
                  | grant ^. #access == ReadWrite && still ^. #access == ReadOnly ->
                      Just (ReviewEffect credential (who <> " loses write access to bucket " <> label <> " and keeps read-only access"))
                _ -> Nothing
            effects = mapMaybe lost (before ^. #grants)
            keptLine =
              [ ReviewEffect anchor ("no object: Google bucket " <> googleName <> " and its objects are kept; Nagare never deletes a bucket")
              | retiring
              , anchor : _ <- [map (^. #resource) effects]
              ]
         in effects <> keptLine
  _ -> []
