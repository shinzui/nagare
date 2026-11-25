-- | App object buckets on the local object store (EP-283). A bucket is its own
-- standalone scope, @bucket-\<key\>@, whose members are Kubernetes objects:
--
-- * a Job that makes the store bucket @nagare-app-\<name\>@ and sets its
--   expiry rules;
-- * per grant, the store user's credential template in @nagare-system@, the
--   workload's copy of it in the workload's namespace, and a Job that creates
--   the user with that credential and attaches its policy;
-- * per grant the declaration no longer holds, a Job that removes the user.
--
-- A Job never changes once created, so each is named after a digest of what
-- it runs: a changed rule or policy is a new Job, and the one it replaces
-- leaves the scope in the same review. Nothing here deletes a bucket or an
-- object. No review carries a key: both Secrets are data-free templates.
module Nagare.Inventory.ObjectBucket
  ( BucketStore (..)
  , bucketStoreFor
  , BucketInput (..)
  , bucketScopeId
  , bucketDeclarationKey
  , bucketBackendKey
  , bucketEndpointKey
  , storeBucketName
  , bucketUser
  , bucketCredentialSecretName
  , bucketPolicy
  , compileStandaloneBucket
  , scopeBucket
  , scopeGrantJob
  , scopeNativeObjects
  , retiredBucket
  , bucketReviewEffects
  , boundBy
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Traversable (for)
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend (..))
import Nagare.Dsl.Config (encodeObjectBuckets)
import Nagare.Dsl.Load (decodeObjectBuckets)
import Nagare.Dsl.ObjectBucket
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (Namespace, ServiceName, namespaceText, serviceNameText)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Plan.Types (ReviewEffect (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Protect, Retain), Sensitivity (Private, Secret))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | The local object store and the client image that administers it.
data BucketStore = BucketStore
  { endpoint :: !Text
  -- ^ The in-cluster base URL, such as
  -- @http://minio.nagare-system.svc.cluster.local:9000@.
  , clientImage :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | Only the local object store serves app buckets until the GCS backend
-- lands (ExecPlan 284).
bucketStoreFor :: StoreBackend -> Text -> Either InventoryError BucketStore
bucketStoreFor backend client = case backend of
  MinioBackend minio -> Right (BucketStore (minio ^. #endpoint) client)
  GcsBackend _ _ -> Left (inventoryError "bucket-backend-unsupported" "app object buckets are served only by a local context's object store")

data BucketInput = BucketInput
  { bucket :: !ObjectBucket
  , store :: !BucketStore
  , cluster :: !ResourceId
  , systemNamespace :: !ResourceId
  , namespaces :: !(Map Text ResourceId)
  -- ^ The accepted namespace member of each grant's namespace.
  , storeReady :: !ResourceId
  -- ^ The member after which the object store answers.
  , previous :: ![Value]
  -- ^ The accepted native objects of this scope, from which a dropped
  -- grant's revoke Job is derived and earlier revoke Jobs are kept.
  , source :: !SourceLocation
  }
  deriving stock (Eq, Show, Generic)

bucketScopeKey :: ObjectBucket -> Either Text LogicalKey
bucketScopeKey declared = maybe (mkLogicalKey (bucketNameText (declared ^. #name))) Right (declared ^. #logicalKey)

bucketScopeId :: ObjectBucket -> Either Text ScopeId
bucketScopeId declared = do
  key <- bucketScopeKey declared
  mkScopeId Standalone ("bucket-" <> logicalKeyText key)

-- | The scope override holding the declaration's JSON, from which bindings
-- and status read the accepted grants.
bucketDeclarationKey :: Text
bucketDeclarationKey = "bucket.declaration"

-- | The scope overrides naming the backend a bound workload must speak
-- (@s3@ here) and the endpoint it reaches the bucket at.
bucketBackendKey, bucketEndpointKey :: Text
bucketBackendKey = "bucket.backend"
bucketEndpointKey = "bucket.endpoint"

-- | The bucket on the store.
storeBucketName :: BucketName -> Text
storeBucketName name = "nagare-app-" <> bucketNameText name

-- | The store user of one grant. It is named by a digest because a bucket, a
-- namespace and a workload name together exceed a Job name.
bucketUser :: BucketName -> Namespace -> ServiceName -> Text
bucketUser name ns workload' = "nagare-bucket-" <> short 12 (T.intercalate "/" [bucketNameText name, namespaceText ns, serviceNameText workload'])

-- | The Secret a granted workload reads its key from, in its own namespace.
bucketCredentialSecretName :: BucketName -> ServiceName -> Text
bucketCredentialSecretName name workload' = "nagare-bucket-" <> bucketNameText name <> "-" <> serviceNameText workload'

-- | The canonical policy document of an access level on a store bucket.
bucketPolicy :: Text -> BucketAccess -> Either Text Text
bucketPolicy storeBucket access =
  TE.decodeUtf8 <$> canonicalValue (object ["Version" .= ("2012-10-17" :: Text), "Statement" .= statements])
  where
    allow :: [Text] -> Text -> Value
    allow actions resource = object ["Effect" .= ("Allow" :: Text), "Action" .= actions, "Resource" .= [resource]]
    statements = case access of
      ReadOnly -> [allow ["s3:GetObject"] ("arn:aws:s3:::" <> storeBucket <> "/*")]
      ReadWrite ->
        [ allow ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"] ("arn:aws:s3:::" <> storeBucket <> "/*")
        , allow ["s3:ListBucket"] ("arn:aws:s3:::" <> storeBucket)
        ]

compileStandaloneBucket ::
  BucketInput ->
  Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneBucket input = do
  declared <- first invalid (validateObjectBucket (input ^. #bucket))
  owner <- first invalid (bucketScopeId declared)
  key <- first invalid (bucketScopeKey declared)
  let name = declared ^. #name
      label = bucketNameText name
      storeBucket = storeBucketName name
      roleId role = mintResourceId owner key <$> first invalid (mkName role)
      bind role value lifecycle sensitivity dependencies = do
        memberId <- roleId role
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
                  , lifecyclePolicy = lifecycle
                  , inputDataPolicy = Stateless
                  , inputSensitivity = sensitivity
                  , sourceLocation = input ^. #source
                  }
            )
        pure (resource {dependencies = dependencies}, bound)
      users = [(bucketUser name (grant ^. #namespace) (grant ^. #workload), grant) | grant <- declared ^. #grants]
      granted = Set.fromList (map fst users)
      earlier = [(user, step, jobName, value) | value <- input ^. #previous, Just (user, step, jobName) <- [bucketJob value]]
      earlierRevoke user = listToMaybe [jobName | (earlierUser, "revoke", jobName, _) <- earlier, earlierUser == user]
  -- The bucket itself. Protect: no review collects the record of its creation.
  let makeText = makeScript (input ^. #store) storeBucket (declared ^. #expire)
      makeName = "nagare-bucket-" <> label <> "-make-" <> short 8 makeText
  makeId <- roleId ("make-" <> short 8 makeText)
  make <-
    bind
      ("make-" <> short 8 makeText)
      (jobObject (input ^. #store) makeName (jobLabels label Nothing "make") makeText Nothing)
      Protect
      Private
      [OrderedAfter (input ^. #systemNamespace), OrderedAfter (input ^. #storeReady)]
  perGrant <- fmap concat . for users $ \(user, grant) -> do
    let digest = T.drop (T.length "nagare-bucket-") user
        ns = namespaceText (grant ^. #namespace)
    namespaceId <-
      maybe
        (Left (invalid ("namespace " <> ns <> " of workload " <> serviceNameText (grant ^. #workload) <> " is not an accepted namespace")))
        Right
        (Map.lookup ns (input ^. #namespaces))
    policy <- first invalid (bucketPolicy storeBucket (grant ^. #access))
    userId <- roleId ("user-" <> digest)
    userSecret <-
      bind
        ("user-" <> digest)
        (secretObject user "nagare-system" (userLabels label user) [("nagare.dev/minio-user-template", "v1"), ("nagare.dev/minio-user", user)])
        Retain
        Secret
        [OrderedAfter (input ^. #systemNamespace)]
    credential <-
      bind
        ("credential-" <> digest)
        ( secretObject
            (bucketCredentialSecretName name (grant ^. #workload))
            ns
            (userLabels label user)
            [("nagare.dev/minio-user-copy", "v1"), ("nagare.dev/minio-user", user), ("nagare.dev/minio-source-resource-id", resourceIdText userId)]
        )
        Retain
        Secret
        [OrderedAfter namespaceId, OrderedAfter userId]
    -- A grant after a revoke is a new Job, not the one that ran before it.
    let grantText = grantScript (input ^. #store) user policy <> maybe "" ("\n# after " <>) (earlierRevoke user)
        grantRole = "grant-" <> digest <> "-" <> short 8 grantText
    grant' <-
      bind
        grantRole
        (jobObject (input ^. #store) (user <> "-grant-" <> short 8 grantText) (jobLabels label (Just user) "grant") grantText (Just user))
        Retain
        Private
        [OrderedAfter makeId, OrderedAfter userId]
    pure [userSecret, credential, grant']
  -- A user the declaration no longer grants is removed by a Job that stays
  -- in the scope until the workload is granted again.
  kept <- for [(user, jobName, value) | (user, "revoke", jobName, value) <- earlier, Set.notMember user granted] $ \(user, jobName, value) ->
    bind (revokeRole user jobName) value Retain Private [OrderedAfter (input ^. #systemNamespace)]
  let revoked = Set.fromList [user | (user, "revoke", _, _) <- earlier]
      dropped = sortOn fst (Map.toList (Map.fromList [(user, jobName) | (user, "grant", jobName, _) <- earlier, Set.notMember user granted, Set.notMember user revoked]))
  added <- for dropped $ \(user, grantJob) -> do
    let revokeText = revokeScript (input ^. #store) user <> "\n# revokes " <> grantJob
        jobName = user <> "-revoke-" <> short 8 revokeText
    bind (revokeRole user jobName) (jobObject (input ^. #store) jobName (jobLabels label (Just user) "revoke") revokeText Nothing) Retain Private [OrderedAfter (input ^. #systemNamespace)]
  let members = make : perGrant <> kept <> added
      record = LBS.toStrict (encodeObjectBuckets [declared])
  scope <- mkScopeDeclaration owner [ResourceBundle [Managed resource | (resource, _) <- members] [] [] [] [] []]
  pure
    ( withScopeConfigDigest
        (contentDigest record)
        (withScopeOverrides (Map.fromList [(bucketDeclarationKey, TE.decodeUtf8 record), (bucketBackendKey, "s3"), (bucketEndpointKey, input ^. #store . #endpoint)]) scope)
    , Map.fromList [(resource ^. #identity, (resource, native)) | (resource, native) <- members]
    )
  where
    invalid message = (inventoryError "invalid-object-bucket" message) {sources = [input ^. #source]} :| []
    revokeRole user jobName = "revoke-" <> T.drop (T.length "nagare-bucket-") user <> "-" <> T.takeEnd 8 jobName

-- | The bucket an accepted scope declares, read from its override.
scopeBucket :: ScopeDeclaration -> Maybe ObjectBucket
scopeBucket scope = do
  record <- Map.lookup bucketDeclarationKey (scopeOverrides scope)
  case decodeObjectBuckets (TE.encodeUtf8 record) of
    Right [declared] -> Just declared
    _ -> Nothing

-- | The accepted Job that grants one store user, found by its labels in the
-- scope's native objects.
scopeGrantJob :: Text -> Map ResourceId (ManagedResource, ByteString) -> Maybe ResourceId
scopeGrantJob user native =
  listToMaybe
    [ resource ^. #identity
    | (resource, bytes) <- Map.elems native
    , Right value <- [Yaml.decodeEither' bytes :: Either Yaml.ParseException Value]
    , Just (jobUser, "grant", _) <- [bucketJob value]
    , jobUser == user
    ]

-- | The user, step and name of one of a bucket scope's per-user Jobs.
bucketJob :: Value -> Maybe (Text, Text, Text)
bucketJob = \case
  Object root
    | KM.lookup "kind" root == Just (String "Job")
    , Just (Object metadata) <- KM.lookup "metadata" root
    , Just (String jobName) <- KM.lookup "name" metadata
    , Just (Object labels) <- KM.lookup "labels" metadata
    , Just (String user) <- KM.lookup "nagare.dev/bucket-user" labels
    , Just (String step) <- KM.lookup "nagare.dev/bucket-step" labels ->
        Just (user, step, jobName)
  _ -> Nothing

short :: Int -> Text -> Text
short n = T.take n . digestText . contentDigest . TE.encodeUtf8

userLabels :: Text -> Text -> Value
userLabels label user = object ["app.kubernetes.io/part-of" .= ("nagare" :: Text), "nagare.dev/bucket" .= label, "nagare.dev/bucket-user" .= user]

jobLabels :: Text -> Maybe Text -> Text -> Value
jobLabels label user step =
  object
    ( ["app.kubernetes.io/part-of" .= ("nagare" :: Text), "nagare.dev/bucket" .= label, "nagare.dev/bucket-step" .= step]
        <> ["nagare.dev/bucket-user" .= found | Just found <- [user]]
    )

secretObject :: Text -> Text -> Value -> [(Text, Text)] -> Value
secretObject name ns labels annotations =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Secret" :: Text)
    , "type" .= ("Opaque" :: Text)
    , "metadata" .= object ["name" .= name, "namespace" .= ns, "labels" .= labels, "annotations" .= Map.fromList annotations]
    ]

alias :: BucketStore -> Text
alias store' = "until mc alias set root " <> store' ^. #endpoint <> " \"$AWS_ACCESS_KEY_ID\" \"$AWS_SECRET_ACCESS_KEY\" >/dev/null; do echo waiting for the object store; sleep 2; done"

-- | Make the bucket and set its expiry rules to exactly the declared ones.
-- Every command is safe to repeat.
makeScript :: BucketStore -> Text -> [ExpireRule] -> Text
makeScript store' storeBucket rules =
  T.intercalate
    "\n"
    ( ["set -eu", alias store', "mc mb --ignore-existing root/" <> storeBucket]
        <> case rules of
          [] -> ["if mc ilm rule ls root/" <> storeBucket <> " >/dev/null 2>&1; then mc ilm rule rm --all --force root/" <> storeBucket <> "; fi"]
          _ ->
            [ "cat > /home/mc/lifecycle.json <<'NAGARE_RULES'"
            , lifecycle
            , "NAGARE_RULES"
            , "mc ilm rule import root/" <> storeBucket <> " < /home/mc/lifecycle.json"
            ]
        <> ["echo made " <> storeBucket]
    )
  where
    lifecycle =
      either (const "{}") TE.decodeUtf8 . canonicalValue $
        object
          [ "Rules"
              .= [ object
                     [ "ID" .= ("expire-" <> T.show index)
                     , "Status" .= ("Enabled" :: Text)
                     , "Filter" .= object ["Prefix" .= objectPrefixText (rule ^. #prefix)]
                     , "Expiration" .= object ["Days" .= positiveDaysInt (rule ^. #afterDays)]
                     ]
                 | (index, rule) <- zip [0 :: Int ..] (sortOn (objectPrefixText . (^. #prefix)) rules)
                 ]
          ]

-- | Create the user with the key in @USER_SECRET@ and attach its policy.
grantScript :: BucketStore -> Text -> Text -> Text
grantScript store' user policy =
  T.intercalate
    "\n"
    [ "set -eu"
    , alias store'
    , "cat > /home/mc/policy.json <<'NAGARE_POLICY'"
    , policy
    , "NAGARE_POLICY"
    , "mc admin policy create root " <> user <> " /home/mc/policy.json"
    , "mc admin user add root " <> user <> " \"$USER_SECRET\""
    , "mc admin policy attach root " <> user <> " --user " <> user <> " >/dev/null 2>&1 || mc admin user info root " <> user <> " | grep -q 'PolicyName: " <> user <> "'"
    , "echo granted " <> user
    ]

-- | Remove the user and its policy. The bucket and its objects stay.
revokeScript :: BucketStore -> Text -> Text
revokeScript store' user =
  T.intercalate
    "\n"
    [ "set -eu"
    , alias store'
    , "if mc admin user info root " <> user <> " >/dev/null 2>&1; then mc admin user remove root " <> user <> "; fi"
    , "if mc admin policy info root " <> user <> " >/dev/null 2>&1; then mc admin policy remove root " <> user <> "; fi"
    , "echo revoked " <> user
    ]

-- | A one-shot Job that runs a script with the store's client image and the
-- administrator's credentials, plus one user's key when it creates the user.
jobObject :: BucketStore -> Text -> Value -> Text -> Maybe Text -> Value
jobObject store' name labels script userSecret =
  object
    [ "apiVersion" .= ("batch/v1" :: Text)
    , "kind" .= ("Job" :: Text)
    , "metadata" .= object ["name" .= name, "namespace" .= ("nagare-system" :: Text), "labels" .= labels]
    , "spec"
        .= object
          [ "backoffLimit" .= (6 :: Int)
          , "template"
              .= object
                [ "metadata" .= object ["labels" .= labels]
                , "spec"
                    .= object
                      [ "restartPolicy" .= ("OnFailure" :: Text)
                      , "automountServiceAccountToken" .= False
                      , "securityContext" .= object ["runAsNonRoot" .= True, "runAsUser" .= (65532 :: Int), "runAsGroup" .= (65532 :: Int), "seccompProfile" .= object ["type" .= ("RuntimeDefault" :: Text)]]
                      , "containers"
                          .= [ object
                                 [ "name" .= ("mc" :: Text)
                                 , "image" .= (store' ^. #clientImage)
                                 , "command" .= (["/bin/sh", "-c", script] :: [Text])
                                 , "env"
                                     .= ( [ object ["name" .= ("HOME" :: Text), "value" .= ("/home/mc" :: Text)]
                                          , object ["name" .= ("MC_CONFIG_DIR" :: Text), "value" .= ("/home/mc/.mc" :: Text)]
                                          , secretEnv "AWS_ACCESS_KEY_ID" "nagare-minio-credentials" "AWS_ACCESS_KEY_ID"
                                          , secretEnv "AWS_SECRET_ACCESS_KEY" "nagare-minio-credentials" "AWS_SECRET_ACCESS_KEY"
                                          ]
                                            <> [secretEnv "USER_SECRET" secretName "AWS_SECRET_ACCESS_KEY" | Just secretName <- [userSecret]]
                                        )
                                 , "securityContext" .= object ["allowPrivilegeEscalation" .= False, "readOnlyRootFilesystem" .= True, "capabilities" .= object ["drop" .= (["ALL"] :: [Text])]]
                                 , "volumeMounts" .= [object ["name" .= ("home" :: Text), "mountPath" .= ("/home/mc" :: Text)]]
                                 ]
                             ]
                      , "volumes" .= [object ["name" .= ("home" :: Text), "emptyDir" .= object []]]
                      ]
                ]
          ]
    ]
  where
    secretEnv :: Text -> Text -> Text -> Value
    secretEnv variable secretName secretKey = object ["name" .= variable, "valueFrom" .= object ["secretKeyRef" .= object ["name" .= secretName, "key" .= secretKey]]]

-- | The declaration that retires a bucket: no workload has access. The
-- bucket Job and the revoke Jobs stay, so the bucket and its objects do.
retiredBucket :: ObjectBucket -> ObjectBucket
retiredBucket declared = declared & #grants .~ []

-- | What replacing a bucket's accepted scope with @desired@ takes away: one
-- line per workload that loses access or the right to write, and, when no
-- grant is left, one line saying that the bucket and its objects are kept.
bucketReviewEffects :: ScopeSnapshot -> ScopeDeclaration -> [ReviewEffect]
bucketReviewEffects snapshot desired = case (Map.lookup (scopeId desired) (snapshotScopes snapshot), scopeBucket desired) of
  (Just (_, accepted), Just after)
    | Just before <- scopeBucket accepted ->
        let label = bucketNameText (before ^. #name)
            members = [resource | bundle <- scopeBundles accepted, Managed resource <- declarations bundle]
            memberNamed kind ns named =
              listToMaybe
                [ resource ^. #identity
                | resource <- members
                , Kubernetes _ _ nativeKind nativeNamespace nativeName <- [resource ^. #address]
                , nameText nativeKind == kind
                , fmap nameText nativeNamespace == Just ns
                , named (nameText nativeName)
                ]
            lost grant = do
              credential <- memberNamed "secret" (namespaceText (grant ^. #namespace)) (== bucketCredentialSecretName (before ^. #name) (grant ^. #workload))
              let who = "workload " <> serviceNameText (grant ^. #workload) <> " in " <> namespaceText (grant ^. #namespace)
              case bucketGrantFor (grant ^. #namespace) (grant ^. #workload) after of
                Nothing -> Just (ReviewEffect credential (who <> " loses " <> bucketAccessToken (grant ^. #access) <> " access to bucket " <> label))
                Just kept
                  | grant ^. #access == ReadWrite && kept ^. #access == ReadOnly ->
                      Just (ReviewEffect credential (who <> " loses write access to bucket " <> label <> " and keeps read-only access"))
                _ -> Nothing
            effects = mapMaybe lost (before ^. #grants)
            kept =
              [ ReviewEffect make ("no object: bucket " <> storeBucketName (before ^. #name) <> " and its objects are kept")
              | not (null effects)
              , null (after ^. #grants)
              , Just make <- [memberNamed "job" "nagare-system" (("nagare-bucket-" <> label <> "-make-") `T.isPrefixOf`)]
              ]
         in effects <> kept
  _ -> []

-- | The accepted members of other scopes that are ordered after a member of
-- this bucket scope: the workloads that bind the bucket.
boundBy :: ScopeSnapshot -> ScopeDeclaration -> [ResourceId]
boundBy snapshot scope =
  [ resource ^. #identity
  | (owner, (_, other)) <- Map.toList (snapshotScopes snapshot)
  , owner /= scopeId scope
  , bundle <- scopeBundles other
  , Managed resource <- declarations bundle
  , any (\dependency -> Set.member (dependencyProducer dependency) own) (resource ^. #dependencies)
  ]
  where
    own = Set.fromList [resource ^. #identity | bundle <- scopeBundles scope, Managed resource <- declarations bundle]

-- | The accepted native objects of one scope, which a recompile reads its
-- earlier Jobs from.
scopeNativeObjects :: ScopeId -> Map ResourceId (ManagedResource, ByteString) -> [Value]
scopeNativeObjects owner native =
  [ value
  | (resource, bytes) <- Map.elems native
  , resource ^. #owner == owner
  , Right value <- [Yaml.decodeEither' bytes :: Either Yaml.ParseException Value]
  ]
