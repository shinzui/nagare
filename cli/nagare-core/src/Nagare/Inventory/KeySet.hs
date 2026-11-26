-- | A signing key set as its own standalone scope, @keyset-\<key\>@
-- (EP-286 M3). Its members, all in the key set's namespace:
--
-- * the Secret @nagare-keyset-NAME@, created with no data; the rotator
--   writes its one key, @private.json@, and the adapter accepts the
--   rotator's field manager owning exactly that key;
-- * the ConfigMap @nagare-keyset-NAME-public@, whose reviewed part is
--   @policy.json@; the rotator writes @public.json@ beside it;
-- * a ServiceAccount, a Role that may get and update only those two objects,
--   and its RoleBinding;
-- * a CronJob that runs @nagare-keyset@ every five minutes;
-- * a first-run Job with the CronJob's pod, which the review waits for, so
--   the keys exist before any workload bound to the key set starts.
--
-- A Job never changes once created, so the first-run Job is named after a
-- digest of its pod: a new image is a new Job, and the one it replaces
-- leaves the scope in the same review. No review carries a key.
module Nagare.Inventory.KeySet
  ( KeySetInput (..)
  , keySetScopeId
  , keySetDeclarationKey
  , keySetSchedule
  , keySetRotatorCommand
  , compileStandaloneKeySet
  , scopeKeySet
  , keySetFirstRunJob
  , keySetStatusLines
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Config (encodeKeySets)
import Nagare.Dsl.KeySet
import Nagare.Dsl.Load (decodeKeySets)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (namespaceText)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.KeySet.Rotator (encodePolicy, keySetPublicName, keySetSecretName, policyFileKey, privateFileKey, publicFileKey)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), DelegatedOperation (RefreshCredential), Delegation (..), LifecyclePolicy (Retain), Sensitivity (Private, Public, Secret))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data KeySetInput = KeySetInput
  { keySet :: !KeySet
  , image :: !Text
  -- ^ An immutable image that holds @/usr/local/bin/nagare-keyset@: the
  -- admin API's.
  , imagePublication :: !(Maybe ResourceId)
  -- ^ The member that publishes the image to the context's registry.
  , cluster :: !ResourceId
  , namespace :: !ResourceId
  -- ^ The accepted namespace member of the key set's namespace.
  , source :: !SourceLocation
  }
  deriving stock (Eq, Show, Generic)

keySetScopeKey :: KeySet -> Either Text LogicalKey
keySetScopeKey declared = maybe (mkLogicalKey (keySetNameText (declared ^. #name))) Right (declared ^. #logicalKey)

keySetScopeId :: KeySet -> Either Text ScopeId
keySetScopeId declared = do
  key <- keySetScopeKey declared
  mkScopeId Standalone ("keyset-" <> logicalKeyText key)

-- | The scope override holding the declaration's JSON, from which bindings
-- and status read the accepted key set.
keySetDeclarationKey :: Text
keySetDeclarationKey = "keyset.declaration"

-- | The rotator's schedule. 'minimumPeriod' and 'minimumOverlap' are sized to it.
keySetSchedule :: Text
keySetSchedule = "*/5 * * * *"

keySetRotatorCommand :: KeySet -> [Text]
keySetRotatorCommand declared = ["/usr/local/bin/nagare-keyset", "--namespace", namespaceText (declared ^. #namespace), "--key-set", keySetNameText (declared ^. #name)]

compileStandaloneKeySet ::
  KeySetInput ->
  Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneKeySet input = do
  let declared = input ^. #keySet
  unless (immutableImage (input ^. #image)) (Left (invalid "the rotator image must be an immutable registry/repository@sha256:<digest> reference"))
  owner <- first invalid (keySetScopeId declared)
  key <- first invalid (keySetScopeKey declared)
  let name = declared ^. #name
      label = keySetNameText name
      ns = namespaceText (declared ^. #namespace)
      secretName = keySetSecretName name
      publicName = keySetPublicName name
      labels = object ["app.kubernetes.io/part-of" .= ("nagare" :: Text), "nagare.dev/keyset" .= label]
      metadata objectName = object ["name" .= objectName, "namespace" .= ns, "labels" .= labels]
      roleId role = mintResourceId owner key <$> first invalid (mkName role)
      bind role value sensitivity dependencies delegations = do
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
                  , lifecyclePolicy = Retain
                  , inputDataPolicy = Stateless
                  , inputSensitivity = sensitivity
                  , sourceLocation = input ^. #source
                  }
            )
        pure (resource {dependencies = dependencies, delegations = delegations}, bound)
      afterNamespace = [OrderedAfter (input ^. #namespace)]
      published = [OrderedAfter publication | Just publication <- [input ^. #imagePublication]]
      pod = podTemplate (input ^. #image) secretName labels (keySetRotatorCommand declared)
      firstName = secretName <> "-first-" <> short 8 (either (const "") TE.decodeUtf8 (canonicalValue pod))
  rotateId <- roleId "rotate"
  privateField <- first invalid (mkName ("data." <> privateFileKey))
  publicField <- first invalid (mkName ("data." <> publicFileKey))
  let delegatedTo field' = [Delegation rotateId (field' :| []) (RefreshCredential :| [])]
  private <-
    bind
      "private"
      (object ["apiVersion" .= ("v1" :: Text), "kind" .= ("Secret" :: Text), "type" .= ("Opaque" :: Text), "metadata" .= metadata secretName])
      Secret
      afterNamespace
      (delegatedTo privateField)
  public <-
    bind
      "public"
      (object ["apiVersion" .= ("v1" :: Text), "kind" .= ("ConfigMap" :: Text), "metadata" .= metadata publicName, "data" .= object [Key.fromText policyFileKey .= encodePolicy (declared ^. #rotation)]])
      Public
      afterNamespace
      (delegatedTo publicField)
  account <-
    bind
      "account"
      (object ["apiVersion" .= ("v1" :: Text), "kind" .= ("ServiceAccount" :: Text), "metadata" .= metadata secretName, "automountServiceAccountToken" .= False])
      Private
      afterNamespace
      []
  role <-
    bind
      "role"
      ( object
          [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
          , "kind" .= ("Role" :: Text)
          , "metadata" .= metadata secretName
          , "rules"
              .= [ object ["apiGroups" .= [("" :: Text)], "resources" .= [("secrets" :: Text)], "resourceNames" .= [secretName], "verbs" .= (["get", "update"] :: [Text])]
                 , object ["apiGroups" .= [("" :: Text)], "resources" .= [("configmaps" :: Text)], "resourceNames" .= [publicName], "verbs" .= (["get", "update"] :: [Text])]
                 ]
          ]
      )
      Private
      afterNamespace
      []
  binding <-
    bind
      "binding"
      ( object
          [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
          , "kind" .= ("RoleBinding" :: Text)
          , "metadata" .= metadata secretName
          , "roleRef" .= object ["apiGroup" .= ("rbac.authorization.k8s.io" :: Text), "kind" .= ("Role" :: Text), "name" .= secretName]
          , "subjects" .= [object ["kind" .= ("ServiceAccount" :: Text), "name" .= secretName, "namespace" .= ns]]
          ]
      )
      Private
      [OrderedAfter (fst role ^. #identity), OrderedAfter (fst account ^. #identity)]
      []
  let ready = map (OrderedAfter . (^. #identity) . fst) [private, public, account, role, binding] <> published
  rotate <-
    bind
      "rotate"
      ( object
          [ "apiVersion" .= ("batch/v1" :: Text)
          , "kind" .= ("CronJob" :: Text)
          , "metadata" .= metadata secretName
          , "spec"
              .= object
                [ "schedule" .= keySetSchedule
                , "concurrencyPolicy" .= ("Forbid" :: Text)
                , "startingDeadlineSeconds" .= (240 :: Int)
                , "successfulJobsHistoryLimit" .= (1 :: Int)
                , "failedJobsHistoryLimit" .= (3 :: Int)
                , "jobTemplate" .= object ["metadata" .= object ["labels" .= labels], "spec" .= object ["backoffLimit" .= (0 :: Int), "template" .= pod]]
                ]
          ]
      )
      Private
      ready
      []
  firstRun <-
    bind
      ("first-" <> T.takeEnd 8 firstName)
      ( object
          [ "apiVersion" .= ("batch/v1" :: Text)
          , "kind" .= ("Job" :: Text)
          , "metadata" .= object ["name" .= firstName, "namespace" .= ns, "labels" .= object ["app.kubernetes.io/part-of" .= ("nagare" :: Text), "nagare.dev/keyset" .= label, "nagare.dev/keyset-step" .= ("first" :: Text)]]
          , "spec" .= object ["backoffLimit" .= (6 :: Int), "template" .= pod]
          ]
      )
      Private
      ready
      []
  let members = [private, public, account, role, binding, rotate, firstRun]
      record = LBS.toStrict (encodeKeySets [declared])
  scope <- mkScopeDeclaration owner [ResourceBundle [Managed resource | (resource, _) <- members] [] [] [] [] []]
  pure
    ( withScopeConfigDigest (contentDigest record) (withScopeOverrides (Map.singleton keySetDeclarationKey (TE.decodeUtf8 record)) scope)
    , Map.fromList [(resource ^. #identity, (resource, native)) | (resource, native) <- members]
    )
  where
    invalid message = (inventoryError "invalid-key-set" message) {sources = [input ^. #source]} :| []

-- | The rotator's pod: its own account and token, nothing else mounted.
podTemplate :: Text -> Text -> Value -> [Text] -> Value
podTemplate image' account labels command =
  object
    [ "metadata" .= object ["labels" .= labels]
    , "spec"
        .= object
          [ "restartPolicy" .= ("OnFailure" :: Text)
          , "serviceAccountName" .= account
          , "automountServiceAccountToken" .= True
          , "securityContext" .= object ["runAsNonRoot" .= True, "runAsUser" .= (65532 :: Int), "runAsGroup" .= (65532 :: Int), "seccompProfile" .= object ["type" .= ("RuntimeDefault" :: Text)]]
          , "containers"
              .= [ object
                     [ "name" .= ("rotate" :: Text)
                     , "image" .= image'
                     , "command" .= command
                     , "securityContext" .= object ["allowPrivilegeEscalation" .= False, "readOnlyRootFilesystem" .= True, "capabilities" .= object ["drop" .= (["ALL"] :: [Text])]]
                     , "resources" .= object ["requests" .= object ["cpu" .= ("10m" :: Text), "memory" .= ("32Mi" :: Text)], "limits" .= object ["memory" .= ("64Mi" :: Text)]]
                     ]
                 ]
          ]
    ]

-- | The key set an accepted scope declares, read from its override.
scopeKeySet :: ScopeDeclaration -> Maybe KeySet
scopeKeySet scope = do
  record <- Map.lookup keySetDeclarationKey (scopeOverrides scope)
  case decodeKeySets (TE.encodeUtf8 record) of
    Right [declared] -> Just declared
    _ -> Nothing

-- | The first-run Job of a key set scope, found by its label: a bound
-- workload is ordered after it, so it starts once the keys exist.
keySetFirstRunJob :: Map ResourceId (ManagedResource, ByteString) -> ScopeId -> Maybe ResourceId
keySetFirstRunJob native owner =
  listToMaybe
    [ resource ^. #identity
    | (resource, bytes) <- Map.elems native
    , resource ^. #owner == owner
    , Right (Object root) <- [Yaml.decodeEither' bytes :: Either Yaml.ParseException Value]
    , KM.lookup "kind" root == Just (String "Job")
    , Just (Object metadata) <- [KM.lookup "metadata" root]
    , Just (Object labels) <- [KM.lookup "labels" metadata]
    , KM.lookup "nagare.dev/keyset-step" labels == Just (String "first")
    ]

short :: Int -> Text -> Text
short n = T.take n . digestText . contentDigest . TE.encodeUtf8

immutableImage :: Text -> Bool
immutableImage reference = case T.breakOn "@sha256:" reference of
  (repository, digest) ->
    not (T.null repository)
      && T.length digest == T.length "@sha256:" + 64
      && T.all (`elem` ("0123456789abcdef" :: String)) (T.drop (T.length "@sha256:") digest)

-- | What @keyset status@ prints for one key set, from the public file the
-- rotator wrote: the policy, each published key, and the recorded rotations.
keySetStatusLines :: KeySet -> ByteString -> Either Text [Text]
keySetStatusLines declared bytes = do
  value <- first T.pack (eitherDecodeStrict bytes :: Either String Value)
  (keys, history) <- first T.pack (parseEither parser value)
  let policy = declared ^. #rotation
      overlap' = fromIntegral (60 * minutesInt (policy ^. #overlap))
      line (status, kid, published, activated, superseded) = case status of
        "next" -> Just ("  next      " <> kid <> "  published " <> time published)
        "active" -> Just ("  active    " <> kid <> "  since     " <> maybe "-" time activated)
        "previous" -> Just ("  previous  " <> kid <> "  until     " <> maybe "-" (time . addUTCTime overlap') superseded)
        _ -> Nothing
      order (status, _, _, _, _) = lookup status [("next", 0 :: Int), ("active", 1), ("previous", 2)]
  pure
    ( [keySetNameText (declared ^. #name) <> "  period " <> duration (policy ^. #period) <> "  overlap " <> duration (policy ^. #overlap)]
        <> [rendered | entry <- sortOn order keys, Just rendered <- [line entry]]
        <> ["rotations: " <> (if null history then "none" else T.intercalate ", " [kid <> " " <> time at' | (kid, at') <- history])]
    )
  where
    parser = withObject "public key set" $ \o -> do
      keys <- o .: "keys" >>= traverse (withObject "key" (\k -> (,,,,) <$> k .: "status" <*> k .: "kid" <*> k .: "publishedAt" <*> k .:? "activatedAt" <*> k .:? "supersededAt"))
      history <- o .: "history" >>= traverse (withObject "activation" (\e -> (,) <$> e .: "kid" <*> e .: "at"))
      pure (keys :: [(Text, Text, UTCTime, Maybe UTCTime, Maybe UTCTime)], history :: [(Text, UTCTime)])
    time = T.pack . iso8601Show
    duration minutes
      | minutesInt minutes `mod` 60 == 0 = T.show (minutesInt minutes `div` 60) <> "h"
      | otherwise = T.show (minutesInt minutes) <> "m"
