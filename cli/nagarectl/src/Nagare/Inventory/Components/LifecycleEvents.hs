{-# LANGUAGE OverloadedStrings #-}

-- | The lifecycle event worker as scope @platform:lifecycle-events@
-- (EP-235 M2).
--
-- A ServiceAccount, a ClusterRole that may get exactly the named signing
-- Secrets (the accepted backup schedules' and webhook subscriptions'; adding
-- either re-reviews this scope), its binding, a NetworkPolicy that admits only
-- the metrics scraper, and the worker Deployment, from the packaged template
-- for the context's mode. A cloud context also binds the operator's worker
-- key Secret as a private member. The worker image is the admin API's: the
-- worker is a second executable of the same package.
module Nagare.Inventory.Components.LifecycleEvents
  ( LifecycleEventsInput (..)
  , LifecycleStore (..)
  , lifecycleWorkerSecretFile
  , signingSecretNames
  , compileLifecycleEvents
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (ToJSON, Value (..), encode, toJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Database.AppDatabase.Backup (appDatabaseBackupScheduleName)
import Nagare.Dsl.Prelude
import Nagare.Events.Subscription (decodeSubscription, subscriptionOverride)
import Nagare.Events.Webhook.Subscription (decodeWebhookSettings)
import Nagare.Inventory.Components.Foundation (FoundationInput (..), foundationNamespaceId)
import Nagare.Inventory.Components.ObservabilitySecrets (normalizeSecretData)
import Nagare.Inventory.Components.Upstream
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ScheduledStatus (ScheduledStatusKind (..), scheduledStatusSources)
import Nagare.Platform.ReleaseImages (ImageSelection, annotateImageSelection)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (parseKubernetesManifest)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.FilePath ((</>))

-- | Where the worker reads the inventory and backups and writes its state.
data LifecycleStore
  = -- | The node directories the local substrate mounts from the
    -- workstation, and the in-cluster object store as the read-only user
    -- local bootstrap created.
    LocalLifecycle
      { minioEndpoint :: !Text
      , backupBucket :: !Text
      , clientImage :: !Text
      -- ^ The object store's client image, which runs the grant Job.
      }
  | -- | The context's GCS inventory prefix and backup bucket through the
    -- worker's own service account, whose key Secret is a private member.
    CloudLifecycle
      { storeUrl :: !Text
      , projectNumber :: !Text
      , backupBucket :: !Text
      , workerSecret :: !(SourceLocation, Value)
      }
  deriving stock (Eq, Show, Generic)

data LifecycleEventsInput = LifecycleEventsInput
  { root :: !FilePath
  , foundation :: !FoundationInput
  , context :: !Text
  , project :: !Text
  , image :: !ImageSelection
  , imagePublication :: !(Maybe ResourceId)
  , store :: !LifecycleStore
  , delivery :: !Bool
  -- ^ Whether the worker sends; off in a candidate or rehearsal context.
  , signingSecrets :: ![Text]
  }
  deriving stock (Generic)

-- | The context's sops-encrypted worker key Secret in its cluster-secrets
-- directory.
lifecycleWorkerSecretFile :: FilePath
lifecycleWorkerSecretFile = "lifecycle-worker.yaml"

-- | The names of the signing Secrets the worker reads: every accepted
-- database and app-database schedule's, and every accepted webhook
-- subscription's keys.
signingSecretNames :: ScopeSnapshot -> [Text]
signingSecretNames snapshot =
  sort . nub $
    [ name
    | status <- scheduledStatusSources snapshot
    , name <- case status ^. #kind of
        DatabaseStatus database -> ["nagare-dbbackup-" <> database <> "-signing"]
        AppDatabaseStatus appDatabase -> [appDatabaseBackupScheduleName appDatabase <> "-signing"]
        VolumeStatus _ -> []
    ]
      <> [ key ^. #secret
         | (_, scope) <- Map.elems (snapshotScopes snapshot)
         , Just text <- [Map.lookup subscriptionOverride (scopeOverrides scope)]
         , Right record <- [decodeSubscription text]
         , Right settings <- [decodeWebhookSettings (record ^. #destination)]
         , key <- settings ^. #signing
         ]

compileLifecycleEvents ::
  LifecycleEventsInput ->
  IO (Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)))
compileLifecycleEvents input = case validated of
  Left reason -> pure (Left (invalid reason :| []))
  Right (substitutions, secretObjects) -> do
    loaded <- try (BS.readFile (input ^. #root </> templatePath)) :: IO (Either IOException ByteString)
    case loaded of
      Left _ -> pure (Left (invalid ("the lifecycle events template is unavailable: " <> T.pack templatePath) :| []))
      Right bytes -> case render substitutions bytes of
        Left reason -> pure (Left (invalid reason :| []))
        Right rendered -> case parseKubernetesManifest (SourceLocation (T.pack templatePath) "lifecycle-events") rendered of
          Left reason -> pure (Left (reason :| []))
          Right parsed -> case traverse recordSelection parsed of
            Left reason -> pure (Left (invalid reason :| []))
            Right objects -> do
              result <- compileUpstream (upstreamInput (objects <> secretObjects))
              pure $ do
                (bundle, native) <- result
                scope <- mkScopeDeclaration owner [bundle]
                pure (scope, native)
  where
    owner = known (mkScopeId Platform "lifecycle-events")
    cluster = foundationCluster (input ^. #foundation)
    system = "nagare-system"
    known :: Either Text a -> a
    known = either (error . T.unpack) id
    invalid = inventoryError "invalid-lifecycle-events"
    address api kind namespace name = known (kubernetesAddress cluster api kind namespace name)
    deployment = address "apps/v1" "Deployment" (Just system) "nagare-events"
    account = address "v1" "ServiceAccount" (Just system) "nagare-events"
    role = address "rbac.authorization.k8s.io/v1" "ClusterRole" Nothing "nagare-events-signing-keys"
    binding = address "rbac.authorization.k8s.io/v1" "ClusterRoleBinding" Nothing "nagare-events-signing-keys"
    policy = address "networking.k8s.io/v1" "NetworkPolicy" (Just system) "nagare-events"
    secret = address "v1" "Secret" (Just system) "nagare-events-worker"
    userSecret = address "v1" "Secret" (Just system) "nagare-events-minio"
    userPolicy = address "v1" "ConfigMap" (Just system) "nagare-events-minio"
    grantJob = address "batch/v1" "Job" (Just system) "nagare-events-minio-grant"
    (templatePath, cloud) = case input ^. #store of
      LocalLifecycle {} -> ("cluster/bootstrap/lifecycle-events/lifecycle-events-local.yaml.tmpl", False)
      CloudLifecycle {} -> ("cluster/bootstrap/lifecycle-events/lifecycle-events-cloud.yaml.tmpl", True)

    validated = do
      unless (immutableImage (input ^. #image . #selected)) (Left "the lifecycle worker image must be an immutable registry/repository@sha256:<digest> reference")
      _ <- mkName (input ^. #context)
      _ <- mkName (input ^. #project)
      names <- traverse checkName (input ^. #signingSecrets)
      -- An empty resourceNames would grant every Secret: name one that
      -- does not exist instead.
      let named = if null names then ["nagare-events-no-signing-secret"] else names
          secretsJson = TE.decodeUtf8 (LBS.toStrict (encode named))
          common =
            [ ("@IMAGE@", input ^. #image . #selected)
            , ("@CONTEXT@", input ^. #context)
            , ("@PROJECT@", input ^. #project)
            , ("@DELIVERY@", if input ^. #delivery then "on" else "off")
            , ("@SIGNING_SECRETS@", secretsJson)
            ]
      case input ^. #store of
        LocalLifecycle endpoint bucket client -> do
          unless ("http://" `T.isPrefixOf` endpoint && T.all safeChar endpoint) (Left "the local object store endpoint must be an http:// in-cluster address")
          _ <- checkName bucket
          unless (immutableImage client) (Left "the object store client image must be an immutable reference")
          Right (common <> [("@MINIO_ENDPOINT@", endpoint), ("@BACKUP_BUCKET@", bucket)], localUserObjects endpoint bucket client)
        CloudLifecycle url number bucket workerObject -> do
          unless (("gs://" `T.isPrefixOf` url) && T.all safeChar url && T.length url > 5) (Left "the lifecycle worker's store must be the context's gs:// inventory prefix")
          unless (not (T.null number) && T.all (`elem` ['0' .. '9']) number) (Left "a cloud lifecycle worker requires NAGARE_PROJECT_NUMBER, the project's numeric number")
          _ <- checkName bucket
          checkWorkerSecret workerObject
          normalized <- normalizeSecretData workerObject
          workerBytes <- canonicalValue (snd normalized)
          Right
            ( common
                <> [ ("@STORE_URL@", url)
                   , ("@PROJECT_NUMBER@", number)
                   , ("@BACKUP_BUCKET@", bucket)
                   , ("@WORKER_DIGEST@", digestText (contentDigest workerBytes))
                   ]
            , [normalized]
            )

    checkName name
      | not (T.null name) && T.length name <= 253 && T.all (\c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c `elem` ("-." :: String)) name = Right name
      | otherwise = Left ("not a Kubernetes name: " <> name)

    render substitutions bytes = do
      text <- first (const "the lifecycle events template is not UTF-8") (TE.decodeUtf8' bytes)
      let rendered = foldl' (\acc (token, value) -> T.replace token value acc) text substitutions
          placeholders = ["@IMAGE@", "@CONTEXT@", "@PROJECT@", "@DELIVERY@", "@SIGNING_SECRETS@", "@MINIO_ENDPOINT@", "@BACKUP_BUCKET@", "@STORE_URL@", "@PROJECT_NUMBER@", "@WORKER_DIGEST@"]
      when (any (`T.isInfixOf` rendered) placeholders) (Left "the lifecycle events template has a placeholder its mode does not supply")
      Right (TE.encodeUtf8 rendered)

    upstreamInput generated =
      UpstreamInput
        { upstreamOwner = owner
        , upstreamCluster = cluster
        , upstreamKey = known (mkLogicalKey "lifecycle-events")
        , upstreamRoot = input ^. #root
        , upstreamFiles = []
        , upstreamNamespaces = Map.singleton (known (mkName system)) (foundationNamespaceId (input ^. #foundation) (known (mkName system)))
        , upstreamTransferred = Set.empty
        , upstreamConfigMapData = Map.empty
        , upstreamClusterIpServices = Set.empty
        , upstreamImageOverrides = Map.empty
        , upstreamGenerated = generated
        , upstreamAfter =
            Map.fromList
              ( [(binding, [role, account]), (deployment, [binding, policy] <> (if cloud then [secret] else [grantJob]))]
                  <> [(grantJob, [userSecret, userPolicy]) | not cloud]
              )
        , upstreamExternalAfter = Map.fromList [(deployment, [publication]) | publication <- maybe [] pure (input ^. #imagePublication)]
        , upstreamOrderDeployments = False
        , upstreamRegistryDelegations = Map.empty
        }

    recordSelection (location, value@(Object root'))
      | KM.lookup "kind" root' == Just (String "Deployment") = (location,) <$> annotateImageSelection (input ^. #image) value
    recordSelection object = Right object

-- | A local context's read-only object-store user for the worker: its
-- credential template (filled at creation, never reviewed), its policy —
-- get, version reads and listing of the backup bucket, nothing else — and
-- the Job that creates the user with that secret and attaches the policy.
localUserObjects :: Text -> Text -> Text -> [(SourceLocation, Value)]
localUserObjects endpoint bucket client =
  [ (at "user-secret", obj ["apiVersion" .= ("v1" :: Text), "kind" .= ("Secret" :: Text), "type" .= ("Opaque" :: Text), "metadata" .= obj ["name" .= user, "namespace" .= system, "labels" .= labels, "annotations" .= obj ["nagare.dev/minio-user-template" .= ("v1" :: Text), "nagare.dev/minio-user" .= user]]])
  , (at "user-policy", obj ["apiVersion" .= ("v1" :: Text), "kind" .= ("ConfigMap" :: Text), "metadata" .= obj ["name" .= user, "namespace" .= system, "labels" .= labels], "data" .= obj ["policy.json" .= policyText]])
  ,
    ( at "user-grant"
    , obj
        [ "apiVersion" .= ("batch/v1" :: Text)
        , "kind" .= ("Job" :: Text)
        , "metadata" .= obj ["name" .= (user <> "-grant"), "namespace" .= system, "labels" .= labels]
        , "spec"
            .= obj
              [ "backoffLimit" .= (6 :: Int)
              , "template"
                  .= obj
                    [ "metadata" .= obj ["labels" .= labels]
                    , "spec"
                        .= obj
                          [ "restartPolicy" .= ("OnFailure" :: Text)
                          , "automountServiceAccountToken" .= False
                          , "securityContext" .= obj ["runAsNonRoot" .= True, "runAsUser" .= (65532 :: Int), "runAsGroup" .= (65532 :: Int), "seccompProfile" .= obj ["type" .= ("RuntimeDefault" :: Text)]]
                          , "containers"
                              .= [ obj
                                     [ "name" .= ("mc" :: Text)
                                     , "image" .= client
                                     , "command" .= (["/bin/sh", "-c", script] :: [Text])
                                     , "env"
                                         .= [ obj ["name" .= ("HOME" :: Text), "value" .= ("/home/mc" :: Text)]
                                            , obj ["name" .= ("MC_CONFIG_DIR" :: Text), "value" .= ("/home/mc/.mc" :: Text)]
                                            , secretEnv "AWS_ACCESS_KEY_ID" "nagare-minio-credentials" "AWS_ACCESS_KEY_ID"
                                            , secretEnv "AWS_SECRET_ACCESS_KEY" "nagare-minio-credentials" "AWS_SECRET_ACCESS_KEY"
                                            , secretEnv "EVENTS_SECRET" user "AWS_SECRET_ACCESS_KEY"
                                            ]
                                     , "securityContext" .= obj ["allowPrivilegeEscalation" .= False, "readOnlyRootFilesystem" .= True, "capabilities" .= obj ["drop" .= (["ALL"] :: [Text])]]
                                     , "volumeMounts" .= [obj ["name" .= ("home" :: Text), "mountPath" .= ("/home/mc" :: Text)], obj ["name" .= ("policy" :: Text), "mountPath" .= ("/policy" :: Text), "readOnly" .= True]]
                                     ]
                                 ]
                          , "volumes" .= [obj ["name" .= ("home" :: Text), "emptyDir" .= obj []], obj ["name" .= ("policy" :: Text), "configMap" .= obj ["name" .= user]]]
                          ]
                    ]
              ]
        ]
    )
  ]
  where
    user = "nagare-events-minio" :: Text
    system = "nagare-system" :: Text
    obj :: [(Key.Key, Value)] -> Value
    obj = Object . KM.fromList
    (.=) :: (ToJSON v) => Text -> v -> (Key.Key, Value)
    k .= v = (Key.fromText k, toJSON v)
    at what = SourceLocation "lifecycle-events" what
    labels = obj ["app.kubernetes.io/name" .= ("nagare-events" :: Text), "app.kubernetes.io/part-of" .= ("nagare-platform" :: Text)]
    secretEnv :: Text -> Text -> Text -> Value
    secretEnv name secretName key = obj ["name" .= name, "valueFrom" .= obj ["secretKeyRef" .= obj ["name" .= secretName, "key" .= key]]]
    policyText =
      TE.decodeUtf8 . LBS.toStrict . encode $
        obj
          [ "Version" .= ("2012-10-17" :: Text)
          , "Statement"
              .= [ obj ["Effect" .= ("Allow" :: Text), "Action" .= (["s3:GetObject", "s3:GetObjectVersion"] :: [Text]), "Resource" .= ["arn:aws:s3:::" <> bucket <> "/*"]]
                 , obj ["Effect" .= ("Allow" :: Text), "Action" .= (["s3:ListBucket", "s3:ListBucketVersions"] :: [Text]), "Resource" .= ["arn:aws:s3:::" <> bucket]]
                 ]
          ]
    alias = "until mc alias set root " <> endpoint <> " \"$AWS_ACCESS_KEY_ID\" \"$AWS_SECRET_ACCESS_KEY\" >/dev/null; do echo waiting for the object store; sleep 2; done"
    script =
      T.intercalate
        "\n"
        [ "set -eu"
        , alias
        , "mc admin policy create root " <> user <> " /policy/policy.json"
        , "mc admin user add root " <> user <> " \"$EVENTS_SECRET\""
        , "mc admin policy attach root " <> user <> " --user " <> user <> " >/dev/null 2>&1 || mc admin user info root " <> user <> " | grep -q 'PolicyName: " <> user <> "'"
        , "echo granted " <> user
        ]

-- | The operator's worker key Secret: exactly @nagare-events-worker@ in
-- @nagare-system@ with a @key.json@ entry and nothing else.
checkWorkerSecret :: (SourceLocation, Value) -> Either Text ()
checkWorkerSecret (_, Object root') = do
  unless (KM.lookup "kind" root' == Just (String "Secret")) (Left "the lifecycle worker key input is not a Kubernetes Secret")
  metadata <- case KM.lookup "metadata" root' of
    Just (Object fields) -> Right fields
    _ -> Left "the lifecycle worker key Secret has no metadata"
  unless
    (KM.lookup "name" metadata == Just (String "nagare-events-worker") && KM.lookup "namespace" metadata == Just (String "nagare-system"))
    (Left "the lifecycle worker key Secret must be nagare-events-worker in nagare-system")
  let keys = concat [KM.keys fields | field <- ["data", "stringData"], Just (Object fields) <- [KM.lookup field root']]
  unless (keys == ["key.json"]) (Left "the lifecycle worker key Secret must hold exactly key.json")
checkWorkerSecret _ = Left "the lifecycle worker key input is not an object"

immutableImage :: Text -> Bool
immutableImage reference = case T.breakOn "@sha256:" reference of
  (name, digest) ->
    not (T.null name)
      && T.all (\c -> c /= ' ' && c /= '"') name
      && T.length digest == 72
      && T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) (T.drop 8 digest)

safeChar :: Char -> Bool
safeChar c = c > ' ' && c /= '"' && c /= '\\'
