-- | Explicit-context kubectl transport for reviewed Kubernetes objects.
-- Create is a server-side create-only request. Ordinary updates are server-side
-- apply; an unnamed Service port transition uses a guarded JSON Patch.
-- Both include UID and resourceVersion checks. A forced transfer from the
-- create operation is allowed only after a live managed-fields check proves
-- there is no foreign owner of the object's non-status fields. A
-- transport failure is ambiguous until a new observation proves its outcome.
module Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (..)
  , mkKubernetesRuntimeOps
  , mkKubernetesRuntimeOpsWithCacheKey
  , desiredFieldsMatch
  , deploymentSelectorReplacement
  , statefulSetImmutableReplacement
  , parseObserved
  , confirmInventoryFieldOwnership
  , confirmInventoryFieldOwnershipFor
  , jobCompleted
  , crdEstablished
  , certificateReady
  , knativeReady
  , materializeCredential
  , materializeLocalObjectStoreCredential
  , materializeLocalObjectStoreCredentialWith
  , minioSourceData
  , supportedUpdateAddress
  , credentialDataMatches
  , generatedCredentialTemplate
  , databaseCredentialKind
  , deploymentAvailable
  , statefulSetReady
  , readinessForAddress
  , observeKubernetesHealth
  , materializeCacheKey
  , cacheClientDataMatches
  , withoutCacheClientData
  , observeCacheClientOutput
  , collectionDeleteRequest
  ) where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Database.Secret (ConnectionParts (..), DbSecretInputs (..), b64decode, b64encode, dbHost, defaultDbUser, renderDbSecret, sanitizeDbName, secretKeysFor)
import Nagare.Dsl.Database (Engine, dbSecretName, parseEngine)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (AdapterExecution (..), OperationAction (..))
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Resource.Inventory (ManagedResource (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data KubernetesRuntimeConfig = KubernetesRuntimeConfig
  { runtimeContext :: !ContextId
  , runtimeKubectlContext :: !Text
  , runtimeGuard :: !(IO (Either Text ()))
  }

mkKubernetesRuntimeOps
  :: KubernetesRuntimeConfig
  -> Map ResourceId (ManagedResource, ByteString)
  -> KubernetesAdapterOps
mkKubernetesRuntimeOps config = mkKubernetesRuntimeOpsWithCacheKey config (\_ -> pure (Left "cache public-key resolver is not installed"))

mkKubernetesRuntimeOpsWithCacheKey
  :: KubernetesRuntimeConfig
  -> (ResourceId -> IO (Either Text Text))
  -> Map ResourceId (ManagedResource, ByteString)
  -> KubernetesAdapterOps
mkKubernetesRuntimeOpsWithCacheKey config resolveCacheKey specs =
  KubernetesAdapterOps
    { kubernetesContext = runtimeContext config
    , kubernetesObserve = observe
    , kubernetesMutateConditional = mutate
    }
  where
    observe resource = case Map.lookup resource specs of
      Nothing -> pure (KubernetesUnknown "Kubernetes resource has no native binding")
      Just (declaration, native) -> do
        guarded <- runtimeGuard config
        case guarded of
          Left reason -> pure (KubernetesUnknown ("cluster guard refused: " <> reason))
          Right () -> case address declaration of
            Kubernetes _ group kind namespace name -> do
              result <- invoke config
                (["get", kindToken group kind, T.unpack (nameText name)]
                  <> namespaceArgs namespace <> ["-o", "json", "--ignore-not-found"])
                ""
              case result of
                Left reason -> pure (KubernetesUnknown reason)
                -- Before bootstrap installs a CRD, the API server can prove
                -- that no instance of its kind is currently addressable.
                -- Other get failures remain unknown, including authorization
                -- and transport failures.
                Right (ExitFailure _, _, errors)
                  | "the server doesn't have a resource type" `T.isInfixOf` T.pack errors ->
                      pure (KubernetesAbsent (contentDigest (TE.encodeUtf8 (resourceIdText resource <> ":absent"))))
                  | otherwise -> pure (KubernetesUnknown "kubectl get failed")
                Right (ExitSuccess, output, _)
                  | null output -> pure (KubernetesAbsent (contentDigest (TE.encodeUtf8 (resourceIdText resource <> ":absent"))))
                  | otherwise -> case parseObserved config resource native (T.pack output) of
                      Left reason -> pure (KubernetesUnknown reason)
                      Right state -> observeCacheClientOutput resolveCacheKey native (T.pack output) state
            _ -> pure (KubernetesUnknown "bound resource has no Kubernetes address")
    mutate mutation = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (AdapterEffectAmbiguous ("cluster guard refused before Kubernetes write: " <> reason))
        Right () -> do
          materialized <- case mutationAction mutation of
            CreateResource -> materializeLocalObjectStoreCredential config (mutationNativeJson mutation)
            _ -> pure (Right (mutationNativeJson mutation))
          resolved <- if mutationAction mutation == RetireResource
            then pure (Right "")
            else case materialized of
              Left reason -> pure (Left reason)
              Right native -> materializeCacheKey resolveCacheKey native
          request <- case (mutationAction mutation, mutationBefore mutation) of
            (CreateResource, KubernetesAbsent _) ->
              pure ((["create", "--field-manager=nagare-inventory", "-f", "-"],) <$> resolved)
            (AdoptResource, KubernetesPresent uid revision Nothing digest)
              | digest == mutationNativeDigest mutation ->
                  adoptionPatch config mutation uid revision
            (RetireResource, KubernetesPresent uid revision (Just owner) digest)
              | owner == mutationResource mutation
              , digest == mutationNativeDigest mutation ->
                  pure (collectionDeleteRequest (mutationAddress mutation) uid revision)
            (UpdateResource, KubernetesPresent _ _ _ _)
              | not (supportedUpdateAddress (mutationAddress mutation)) ->
                  pure (Left "Kubernetes update kind lacks a proved conditional mutation policy")
            (UpdateResource, KubernetesPresent uid revision _ _) -> do
              case generatedCredentialTemplate (mutationNativeJson mutation) of
                Left reason -> pure (Left reason)
                Right True -> pure (Left "generated credential updates require a dedicated data-preserving operation")
                Right False -> do
                  ownership <- verifyLiveOwnership config (mutationAddress mutation) uid revision
                  pure $ do
                    observed <- ownership
                    native <- resolved
                    case mutationAddress mutation of
                      Kubernetes _ "" kind namespace name | nameText kind == "service" ->
                        case servicePortPatch uid revision native observed of
                          Left reason -> Left reason
                          Right (Just patch) -> Right
                            (["patch", "service", T.unpack (nameText name)] <> namespaceArgs namespace
                              <> ["--type=json", "--field-manager=nagare-inventory", "-p", T.unpack patch], "")
                          Right Nothing -> applyRequest uid revision native
                      _ -> applyRequest uid revision native
            _ -> pure (Left "Kubernetes transport received an unsupported action or precondition")
          case request of
            Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
            Right (arguments, body) -> do
              result <- invoke config arguments (T.unpack body)
              case result of
                Right (ExitSuccess, _, _)
                  | mutationAction mutation == RetireResource ->
                      waitForCollection config (mutationAddress mutation)
                  | otherwise -> waitForReadiness config (mutationAddress mutation)
                _ -> pure (AdapterEffectAmbiguous "Kubernetes write did not return success; reobserve before retry")

collectionDeleteRequest :: ProviderAddress -> PhysicalIdentity -> Text -> Either Text ([String], Text)
collectionDeleteRequest address uid revision = case address of
  Kubernetes _ group kind (Just namespace) name
    | Just prefix <- collectionPathPrefix group (nameText kind) -> do
    bytes <- canonicalValue (object
      ["apiVersion" .= ("meta.k8s.io/v1" :: Text)
      ,"kind" .= ("DeleteOptions" :: Text)
      ,"preconditions" .= object
        ["uid" .= physicalIdentityText uid, "resourceVersion" .= revision]
      ,"propagationPolicy" .= ("Orphan" :: Text)])
    let path = prefix <> "/namespaces/" <> T.unpack (nameText namespace)
          <> "/" <> T.unpack (nameText kind) <> "s/" <> T.unpack (nameText name)
    pure (["delete", "--raw", path, "-f", "-"], TE.decodeUtf8 bytes)
  _ -> Left "conditional collection does not support this Kubernetes kind"

collectionPathPrefix :: Text -> Text -> Maybe String
collectionPathPrefix "" kind | kind `elem` ["configmap", "service"] = Just "/api/v1"
collectionPathPrefix "batch" "cronjob" = Just "/apis/batch/v1"
collectionPathPrefix "serving.knative.dev" "domainmapping" = Just "/apis/serving.knative.dev/v1beta1"
collectionPathPrefix _ _ = Nothing

-- | A successful DELETE can precede actual removal, especially for controllers.
-- Keep the effect ambiguous until the API confirms the address is absent; the
-- adapter's final verification also checks for a replacement incarnation.
waitForCollection :: KubernetesRuntimeConfig -> ProviderAddress -> IO AdapterExecution
waitForCollection config address = case address of
  Kubernetes _ group kind namespace name -> do
    let token = kindToken group kind <> "/" <> T.unpack (nameText name)
    waited <- invoke config (["wait", "--for=delete", token, "--timeout=30s"] <> namespaceArgs namespace) ""
    pure $ case waited of
      Right (ExitSuccess, _, _) -> AdapterEffectCompleted
      _ -> AdapterEffectAmbiguous "Kubernetes delete returned success but removal is not yet confirmed"
  _ -> pure (AdapterEffectAmbiguous "Kubernetes collection has no native address")

-- | Each admitted kind has disposable-cluster evidence for ownership checks,
-- UID/resourceVersion handling, and its normal update form. New kinds require
-- their own update proof before they can enter this list.
supportedUpdateAddress :: ProviderAddress -> Bool
supportedUpdateAddress (Kubernetes _ group kind _ _) =
  (group, nameText kind) `elem`
    [ ("", "namespace")
    , ("", "configmap")
    , ("", "service")
    , ("", "secret")
    , ("", "persistentvolumeclaim")
    , ("", "resourcequota")
    , ("apps", "deployment")
    , ("apps", "statefulset")
    , ("batch", "cronjob")
    , ("networking.k8s.io", "networkpolicy")
    ]
supportedUpdateAddress _ = False

waitForReadiness :: KubernetesRuntimeConfig -> ProviderAddress -> IO AdapterExecution
waitForReadiness config address = case address of
  Kubernetes _ "batch" kind namespace name | nameText kind == "job" ->
    waitCondition "complete" "job" namespace name "Job"
  Kubernetes _ "apiextensions.k8s.io" kind namespace name | nameText kind == "customresourcedefinition" ->
    waitCondition "established" "crd" namespace name "CustomResourceDefinition"
  Kubernetes _ "cert-manager.io" kind namespace name
    | nameText kind `elem` ["certificate", "clusterissuer"] ->
      waitCondition "ready" (T.unpack (nameText kind)) namespace name "cert-manager resource"
  Kubernetes _ "serving.knative.dev" kind namespace name | nameText kind == "service" ->
    waitCondition "ready" "ksvc" namespace name "Knative Service"
  Kubernetes _ "apps" kind namespace name | nameText kind == "deployment" -> do
    result <- invoke config
      (["rollout", "status", "deployment/" <> T.unpack (nameText name)]
        <> namespaceArgs namespace <> ["--timeout=300s"])
      ""
    pure $ case result of
      Right (ExitSuccess, _, _) -> AdapterEffectCompleted
      _ -> AdapterEffectAmbiguous "Kubernetes Deployment did not prove availability; reobserve before retry"
  Kubernetes _ "apps" kind namespace name | nameText kind == "statefulset" -> do
    result <- invoke config
      (["rollout", "status", "statefulset/" <> T.unpack (nameText name)]
        <> namespaceArgs namespace <> ["--timeout=300s"])
      ""
    pure $ case result of
      Right (ExitSuccess, _, _) -> AdapterEffectCompleted
      _ -> AdapterEffectAmbiguous "Kubernetes StatefulSet did not prove readiness; reobserve before retry"
  _ -> pure AdapterEffectCompleted
  where
    waitCondition condition kind namespace name label = do
      result <- invoke config
        (["wait", "--for=condition=" <> condition, kind <> "/" <> T.unpack (nameText name)]
          <> namespaceArgs namespace <> ["--timeout=300s"])
        ""
      pure $ case result of
        Right (ExitSuccess, _, _) -> AdapterEffectCompleted
        _ -> AdapterEffectAmbiguous ("Kubernetes " <> label <> " did not prove readiness; reobserve before retry")

-- | A separate read-only condition probe. The UID check prevents a second
-- get from attaching readiness of a replacement to the first observation.
observeKubernetesHealth :: KubernetesRuntimeConfig -> ProviderAddress -> PhysicalIdentity -> IO (Maybe Bool)
observeKubernetesHealth config address physical = case address of
  Kubernetes _ group kind namespace name
    | supportsReadiness address -> do
        guarded <- runtimeGuard config
        case guarded of
          Left _ -> pure Nothing
          Right () -> do
            result <- invoke config
              (["get", kindToken group kind, T.unpack (nameText name)]
                <> namespaceArgs namespace <> ["-o", "json", "--ignore-not-found"])
              ""
            pure $ case result of
              Right (ExitSuccess, output, _) | not (null output) -> do
                value <- either (const Nothing) Just (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
                metadata <- either (const Nothing) Just (metadataOf value)
                uid <- either (const Nothing) Just (fieldText "uid" metadata)
                if uid == physicalIdentityText physical
                  then readinessForAddress address value
                  else Nothing
              _ -> Nothing
  _ -> pure Nothing

readinessForAddress :: ProviderAddress -> Value -> Maybe Bool
readinessForAddress address value = case address of
  Kubernetes _ "batch" kind _ _ | nameText kind == "job" -> Just (jobCompleted value)
  Kubernetes _ "apiextensions.k8s.io" kind _ _ | nameText kind == "customresourcedefinition" -> Just (crdEstablished value)
  Kubernetes _ "cert-manager.io" kind _ _ | nameText kind `elem` ["certificate", "clusterissuer"] -> Just (certificateReady value)
  Kubernetes _ "serving.knative.dev" kind _ _ | nameText kind == "service" -> Just (knativeReady value)
  Kubernetes _ "apps" kind _ _ | nameText kind == "deployment" -> Just (deploymentAvailable value)
  Kubernetes _ "apps" kind _ _ | nameText kind == "statefulset" -> Just (statefulSetReady value)
  _ -> Nothing

supportsReadiness :: ProviderAddress -> Bool
supportsReadiness address = maybe False (const True) (readinessForAddress address Null)

-- The client ConfigMap's data is delegated at review time, but observation
-- still compares it with the current output of the named logical cache.
observeCacheClientOutput
  :: (ResourceId -> IO (Either Text Text))
  -> ByteString
  -> Text
  -> KubernetesState
  -> IO KubernetesState
observeCacheClientOutput resolve native response state = case eitherDecodeStrict native of
  Left (_ :: String) -> pure (KubernetesUnknown "cache client review bytes are malformed")
  Right desired -> case cacheClientTemplate desired of
    Left reason -> pure (KubernetesUnknown reason)
    Right Nothing -> pure state
    Right (Just (producer, template)) -> do
      resolved <- resolve producer
      pure $ case resolved of
        Left reason -> KubernetesUnknown reason
        Right key | not (validCachePublicKey key) -> KubernetesUnknown "cache public key is invalid"
        Right key -> case eitherDecodeStrict (TE.encodeUtf8 response) of
          Left (_ :: String) -> KubernetesUnknown "cache client observation is malformed"
          Right observed
            | observedClientText observed == Just (T.replace "${ATTIC_PUBLIC_KEY}" key template) -> state
            | otherwise -> case state of
                KubernetesPresent physical revision owner _ ->
                  KubernetesPresent physical revision owner (contentDigest (TE.encodeUtf8 response))
                _ -> state
  where
    observedClientText (Object root) = case KM.lookup "data" root of
      Just (Object entries) -> case KM.lookup "nix.conf" entries of
        Just (String value) -> Just value
        _ -> Nothing
      _ -> Nothing
    observedClientText _ = Nothing

-- | Compare only fields present in the retained desired object. Server-added
-- metadata, defaults and status do not count as drift. Arrays stay ordered;
-- this deliberately reports uncertain associative-list reorderings as drift.
desiredFieldsMatch :: Value -> Value -> Bool
desiredFieldsMatch desired observed
  | delegatedServingWebhook desired = servingWebhookRulesMatch desired observed
      && go [] (withoutWebhookRules desired) observed
  | otherwise = go [] desired observed
  where
    delegatedServingWebhook (Object root) =
      KM.lookup "apiVersion" root == Just (String "admissionregistration.k8s.io/v1")
        && KM.lookup "kind" root `elem`
          [Just (String "MutatingWebhookConfiguration"), Just (String "ValidatingWebhookConfiguration")]
        && case KM.lookup "metadata" root of
          Just (Object metadata) -> KM.lookup "name" metadata `elem`
            [Just (String "webhook.serving.knative.dev"), Just (String "validation.webhook.serving.knative.dev")]
          _ -> False
    delegatedServingWebhook _ = False
    withoutWebhookRules (Object root) = case KM.lookup "webhooks" root of
      Just hooks -> Object (KM.insert "webhooks" (stripWebhooks hooks) root)
      Nothing -> Object root
    withoutWebhookRules value = value
    stripWebhooks (Array webhooks) = Array (fmap stripOne webhooks)
    stripWebhooks value = value
    stripOne (Object webhook) = Object (KM.delete "rules" webhook)
    stripOne value = value
    servingWebhookRulesMatch (Object desiredRoot) (Object observedRoot) =
      case (KM.lookup "webhooks" desiredRoot, KM.lookup "webhooks" observedRoot) of
        (Just (Array desiredHooks), Just (Array observedHooks)) ->
          not (V.null desiredHooks) && V.length desiredHooks == V.length observedHooks
            && and (V.toList (V.zipWith sameRules desiredHooks observedHooks))
        _ -> False
    servingWebhookRulesMatch _ _ = False
    sameRules (Object desiredHook) (Object observedHook) =
      KM.lookup "name" desiredHook == KM.lookup "name" observedHook
        && case (KM.lookup "rules" desiredHook, KM.lookup "rules" observedHook) of
          (Just (Array desiredRules), Just (Array observedRules)) ->
            not (V.null desiredRules) && not (V.null observedRules)
              && all validRule (V.toList observedRules)
              && groups desiredRules == groups observedRules
              && resources desiredRules == resources observedRules
              && operations desiredRules == operations observedRules
              && scopes desiredRules == scopes observedRules
          _ -> False
    sameRules _ _ = False
    groups = Set.unions . map (textSet "apiGroups") . V.toList
    resources rules = Set.fromList
      [maybe item id (T.stripSuffix "/status" item)
      | rule <- V.toList rules, item <- Set.toList (textSet "resources" rule)]
    operations = Set.unions . map (textSet "operations") . V.toList
    scopes = Set.fromList . mapMaybe (ruleText "scope") . V.toList
    validRule rule = not (Set.null (textSet "apiGroups" rule))
      && not (Set.null (textSet "apiVersions" rule))
      && not (Set.null (textSet "operations" rule))
      && not (Set.null (textSet "resources" rule))
      && isJust (ruleText "scope" rule)
    ruleText key (Object value) = case KM.lookup key value of
      Just (String item) -> Just item
      _ -> Nothing
    ruleText _ _ = Nothing
    textSet key (Object value) = case KM.lookup key value of
      Just (Array items) -> Set.fromList [item | String item <- V.toList items]
      _ -> Set.empty
    textSet _ _ = Set.empty
    go path (Object desired) (Object observed) =
      all (\(key, value) -> case KM.lookup key observed of
        Just actual -> go (Key.toText key : path) value actual
        Nothing -> key == "value" && value == String "" && case path of
          "env" : _ -> KM.lookup "valueFrom" observed == Nothing
          _ -> False) (KM.toList desired)
    go path (Array desired) (Array observed) =
      length desired == length observed && and (zipWith (go path) (foldr (:) [] desired) (foldr (:) [] observed))
    go ("cpu" : className : "resources" : _) (String desired) (String observed)
      | className `elem` ["limits", "requests"] =
          desired == observed || case (cpuMilli desired, cpuMilli observed) of
            (Just left, Just right) -> left == right
            _ -> False
    go _ desired observed = desired == observed

    -- The API server canonicalises CPU quantities (for example 1000m to 1).
    -- Compare only CPU resource fields in millicores; arbitrary strings retain
    -- exact equality so ConfigMap data cannot be silently normalised.
    cpuMilli quantity = case T.stripSuffix "m" quantity of
      Just millis -> decimal millis
      Nothing -> case T.splitOn "." quantity of
        [whole] -> (* 1000) <$> decimal whole
        [whole, fraction] | not (T.null fraction) && T.length fraction <= 3 -> do
          integral <- decimal whole
          fractional <- decimal fraction
          pure (integral * 1000 + fractional * (10 ^ (3 - T.length fraction)))
        _ -> Nothing
    decimal digits
      | T.null digits = Nothing
      | otherwise = T.foldl' step (Just 0) digits
    step prior char
      | char >= '0' && char <= '9' = (\value -> value * 10 + toInteger (fromEnum char - fromEnum '0')) <$> prior
      | otherwise = Nothing

parseObserved :: KubernetesRuntimeConfig -> ResourceId -> ByteString -> Text -> Either Text KubernetesState
parseObserved config resource native response = do
  observed <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 response))
  desired <- first (T.pack . show) (eitherDecodeStrict native)
  metadata <- metadataOf observed
  uid <- fieldText "uid" metadata >>= mkPhysicalIdentity
  revision <- fieldText "resourceVersion" metadata
  annotations <- case KM.lookup "annotations" metadata of
    Nothing -> Right KM.empty
    Just (Object value) -> Right value
    _ -> Left "Kubernetes annotations are malformed"
  let stampedContext = textAt "nagare.dev/context-id" annotations
      stampedOwner = textAt "nagare.dev/resource-id" annotations >>= either (const Nothing) Just . mkResourceId
      owner = if stampedContext == Just (contextIdText (runtimeContext config)) then stampedOwner else Nothing
      desiredDigest = contentDigest native
      fieldsMatch = desiredFieldsMatch (withoutCacheClientData desired) observed
        && credentialDataMatches desired observed
        && cacheClientDataMatches desired observed
      stampMatches = textAt "nagare.dev/spec-digest" annotations == Just (digestText desiredDigest)
      hasAnyStamp = any (`KM.member` annotations)
        ["nagare.dev/context-id", "nagare.dev/resource-id", "nagare.dev/spec-digest"]
  when (hasAnyStamp && (stampedContext == Nothing || stampedOwner == Nothing))
    (Left "Kubernetes inventory ownership stamp is incomplete or malformed")
  driftDigest <- if fieldsMatch && (not hasAnyStamp || stampMatches)
    then Right desiredDigest else contentDigest <$> canonicalValue observed
  -- Keep a different logical owner visible to status. A foreign context is
  -- refused below rather than being misclassified as an unstamped object.
  when (stampedContext /= Nothing && stampedContext /= Just (contextIdText (runtimeContext config)))
    (Left "Kubernetes object belongs to a different inventory context")
  pure $ if deploymentSelectorReplacement desired observed
      || statefulSetImmutableReplacement desired observed
    then KubernetesReplacementRequired uid revision owner driftDigest
    else if not (observedReady observed)
      then KubernetesNotReady uid revision owner driftDigest
    else KubernetesPresent uid revision owner driftDigest

-- A failed controller condition is a health finding, not a failed read of
-- the object's configuration or ownership. Execution still refuses to verify
-- a KubernetesNotReady state as completed.
observedReady :: Value -> Bool
observedReady (Object root) = case (KM.lookup "apiVersion" root, KM.lookup "kind" root) of
  (_, Just (String "Job")) -> jobCompleted (Object root)
  (_, Just (String "CustomResourceDefinition")) -> crdEstablished (Object root)
  (_, Just (String "Certificate")) -> certificateReady (Object root)
  (_, Just (String "ClusterIssuer")) -> certificateReady (Object root)
  (Just (String "serving.knative.dev/v1"), Just (String "Service")) -> knativeReady (Object root)
  (_, Just (String "Deployment")) -> deploymentAvailable (Object root)
  (Just (String "apps/v1"), Just (String "StatefulSet")) -> statefulSetReady (Object root)
  _ -> True
observedReady _ = True

-- A Deployment's selector is immutable at the API server. Only classify a
-- change when both sides state it explicitly; an incomplete projection must
-- remain ordinary drift or unknown rather than claiming replacement proof.
deploymentSelectorReplacement :: Value -> Value -> Bool
deploymentSelectorReplacement desired observed =
  case (selector desired, selector observed) of
    (Just before, Just after) -> before /= after
    _ -> False
  where
    selector (Object root)
      | KM.lookup "apiVersion" root == Just (String "apps/v1")
      , KM.lookup "kind" root == Just (String "Deployment") = do
          Object specValue <- KM.lookup "spec" root
          KM.lookup "selector" specValue
    selector _ = Nothing

-- A StatefulSet's identity-bearing spec fields cannot be changed by an
-- ordinary update. Require both values to be explicit so omitted/defaulted
-- fields do not manufacture a replacement finding.
statefulSetImmutableReplacement :: Value -> Value -> Bool
statefulSetImmutableReplacement desired observed =
  any changed ["selector", "serviceName", "volumeClaimTemplates", "podManagementPolicy"]
  where
    changed field = case (specField desired field, specField observed field) of
      (Just before, Just after)
        | field == "volumeClaimTemplates" -> not (desiredFieldsMatch before after)
        | otherwise -> before /= after
      _ -> False
    specField (Object root) field
      | KM.lookup "apiVersion" root == Just (String "apps/v1")
      , KM.lookup "kind" root == Just (String "StatefulSet") = do
          Object specValue <- KM.lookup "spec" root
          KM.lookup field specValue
    specField _ _ = Nothing

jobCompleted :: Value -> Bool
jobCompleted = hasCondition "Complete"

crdEstablished :: Value -> Bool
crdEstablished = hasCondition "Established"

certificateReady :: Value -> Bool
certificateReady = hasCondition "Ready"

knativeReady :: Value -> Bool
knativeReady = hasCondition "Ready"

hasCondition :: Text -> Value -> Bool
hasCondition conditionType (Object root) = case KM.lookup "status" root of
  Just (Object status) -> case KM.lookup "conditions" status of
    Just (Array conditions) -> any completed (foldr (:) [] conditions)
    _ -> False
  _ -> False
  where
    completed (Object condition) = KM.lookup "type" condition == Just (String conditionType)
      && KM.lookup "status" condition == Just (String "True")
    completed _ = False
hasCondition _ _ = False

deploymentAvailable :: Value -> Bool
deploymentAvailable value@(Object root) = hasCondition "Available" value
  && case (KM.lookup "status" root, KM.lookup "metadata" root) of
    (Just (Object status), Just (Object metadata)) ->
      case (KM.lookup "observedGeneration" status, KM.lookup "generation" metadata) of
        (Just observed, Just desired) -> observed == desired
        _ -> False
    _ -> False
deploymentAvailable _ = False

-- StatefulSets do not expose the Deployment Available condition. A matching
-- observed generation and the requested number of ready, updated Pods is the
-- bounded health signal; it does not assert application-level or data health.
statefulSetReady :: Value -> Bool
statefulSetReady (Object root) = case
  (KM.lookup "metadata" root, KM.lookup "spec" root, KM.lookup "status" root) of
    (Just (Object metadata), Just (Object specValue), Just (Object status)) ->
      let requested = case KM.lookup "replicas" specValue of
            Just (Number replicas) -> Just replicas
            Nothing -> Just 1
            _ -> Nothing
          ready = case KM.lookup "readyReplicas" status of
            Just (Number replicas) -> Just replicas
            Nothing -> Just 0
            _ -> Nothing
          updated = case KM.lookup "updatedReplicas" status of
            Just (Number replicas) -> Just replicas
            Nothing -> Just 0
            _ -> Nothing
       in case (KM.lookup "generation" metadata,
                KM.lookup "observedGeneration" status, requested, ready, updated) of
            (Just (Number generation), Just (Number observed), Just desired,
              Just actualReady, Just actualUpdated) ->
              generation == observed && actualReady >= desired && actualUpdated >= desired
            _ -> False
    _ -> False
statefulSetReady _ = False

metadataOf :: Value -> Either Text Object
metadataOf (Object root) = case KM.lookup "metadata" root of
  Just (Object value) -> Right value
  _ -> Left "Kubernetes observation has no metadata"
metadataOf _ = Left "Kubernetes observation is not an object"

fieldText :: Key -> Object -> Either Text Text
fieldText key metadata = case KM.lookup key metadata of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("Kubernetes observation lacks " <> T.pack (show key))

textAt :: Key -> Object -> Maybe Text
textAt key value = case KM.lookup key value of Just (String textValue) -> Just textValue; _ -> Nothing

-- | Database credential templates carry no Secret.data at review time. At
-- mutation time only, materialize their data from a newly generated password.
-- The template's identity, labels and inventory stamps remain unchanged.
materializeCredential :: Text -> IO (Either Text Text)
materializeCredential native = case eitherDecodeStrict (TE.encodeUtf8 native) of
  Left (_ :: String) -> pure (Left "reviewed Kubernetes object is malformed")
  Right value -> case authCredentialKind value of
    Left reason -> pure (Left reason)
    Right (Just keys) -> case databaseCredentialKind value of
      Left reason -> pure (Left reason)
      Right (Just _) -> pure (Left "Secret cannot carry both auth and database credential templates")
      Right Nothing -> do
        generated <- traverse generateAuthKey keys
        pure $ do
          entries <- sequence generated
          case value of
            Object root -> TE.decodeUtf8 <$> canonicalValue (Object
              (KM.insert "data" (Object (KM.fromList entries)) root))
            _ -> Left "auth credential template is malformed"
    Right Nothing -> case databaseCredentialKind value of
      Left reason -> pure (Left reason)
      Right Nothing -> pure (Right native)
      Right (Just (dbName, namespace, engine)) -> do
        generated <- try (readProcessWithExitCode "openssl" ["rand", "-hex", "24"] "")
        pure $ case generated of
          Left (_ :: IOException) -> Left "could not generate database credential"
          Right (ExitFailure _, _, _) -> Left "could not generate database credential"
          Right (ExitSuccess, output, _) -> do
            let password = T.strip (T.pack output)
            unless (T.length password == 48) (Left "database credential generator returned an invalid password")
            fillCredential value dbName namespace engine password

-- | The local object's first Secret gets fresh values only at create time.
-- The second namespace receives those exact values after its reviewed
-- prerequisite, without storing them in the review or a fixed manifest.
materializeLocalObjectStoreCredential :: KubernetesRuntimeConfig -> Text -> IO (Either Text Text)
materializeLocalObjectStoreCredential config = materializeLocalObjectStoreCredentialWith
  (invoke config ["get", "secret", "nagare-minio-credentials", "-n", "nagare-system", "-o", "json"] "") config

materializeLocalObjectStoreCredentialWith
  :: IO (Either Text (ExitCode, String, String))
  -> KubernetesRuntimeConfig -> Text -> IO (Either Text Text)
materializeLocalObjectStoreCredentialWith readSource config native =
  case eitherDecodeStrict (TE.encodeUtf8 native) of
    Left (_ :: String) -> pure (Left "reviewed Kubernetes object is malformed")
    Right value -> case minioCredentialKind value of
      Left reason -> pure (Left reason)
      Right Nothing -> materializeCredential native
      Right (Just False) -> do
        access <- generateAuthKey "AWS_ACCESS_KEY_ID"
        secret <- generateAuthKey "AWS_SECRET_ACCESS_KEY"
        pure (insertMinioData value =<< (KM.fromList <$> sequence [access, secret]))
      Right (Just True) -> do
        fetched <- readSource
        pure $ do
          (code, body, _) <- fetched
          unless (code == ExitSuccess) (Left "local object-store source credential is unavailable")
          source <- first (const "local object-store source credential is malformed")
            (eitherDecodeStrict (TE.encodeUtf8 (T.pack body)))
          expected <- minioCopySourceId value
          fields <- minioSourceData config expected source
          insertMinioData value fields

insertMinioData :: Value -> KM.KeyMap Value -> Either Text Text
insertMinioData (Object root) fields =
  TE.decodeUtf8 <$> canonicalValue (Object (KM.insert "data" (Object fields) root))
insertMinioData _ _ = Left "local object-store credential template is malformed"

minioCredentialKind :: Value -> Either Text (Maybe Bool)
minioCredentialKind value@(Object root) | KM.lookup "kind" root == Just (String "Secret") = do
  metadata <- metadataOf value
  annotations <- case KM.lookup "annotations" metadata of
    Just (Object fields) -> Right fields
    Nothing -> Right KM.empty
    _ -> Left "local object-store credential annotations are malformed"
  let primary = textAt "nagare.dev/minio-credential-template" annotations
      copy = textAt "nagare.dev/minio-credential-copy" annotations
  case (primary, copy) of
    (Nothing, Nothing) -> Right Nothing
    (Just "v1", Nothing) -> validate "nagare-system" False
    (Nothing, Just "v1") -> validate "personal" True
    _ -> Left "local object-store credential template is malformed"
  where
    validate expected copied = do
      metadata <- metadataOf value
      namespace <- fieldText "namespace" metadata
      name <- fieldText "name" metadata
      unless (namespace == expected && name == "nagare-minio-credentials"
          && not (KM.member "data" root) && not (KM.member "stringData" root))
        (Left "local object-store credential template has unexpected content")
      pure (Just copied)
minioCredentialKind _ = Right Nothing

minioCopySourceId :: Value -> Either Text Text
minioCopySourceId value = do
  metadata <- metadataOf value
  annotations <- case KM.lookup "annotations" metadata of
    Just (Object fields) -> Right fields
    _ -> Left "local object-store copy lacks source identity"
  fieldText "nagare.dev/minio-source-resource-id" annotations

minioSourceData :: KubernetesRuntimeConfig -> Text -> Value -> Either Text (KM.KeyMap Value)
minioSourceData config expected source = do
  metadata <- metadataOf source
  name <- fieldText "name" metadata
  namespace <- fieldText "namespace" metadata
  annotations <- case KM.lookup "annotations" metadata of
    Just (Object fields) -> Right fields
    _ -> Left "local object-store source credential has no ownership stamps"
  unless (name == "nagare-minio-credentials" && namespace == "nagare-system"
      && textAt "nagare.dev/context-id" annotations == Just (contextIdText (runtimeContext config))
      && textAt "nagare.dev/minio-credential-template" annotations == Just "v1"
      && textAt "nagare.dev/resource-id" annotations == Just expected)
    (Left "local object-store source credential is not owned by this context")
  case source of
    Object root -> case KM.lookup "data" root of
      Just (Object fields) | validMinioData fields -> Right fields
      _ -> Left "local object-store source credential lacks required data"
    _ -> Left "local object-store source credential is malformed"

validMinioData :: KM.KeyMap Value -> Bool
validMinioData fields = Set.fromList (KM.keys fields) == Set.fromList
  ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
  && all (\case String encoded -> either (const False) (not . T.null) (b64decode encoded); _ -> False)
    (KM.elems fields)

generateAuthKey :: Text -> IO (Either Text (Key, Value))
generateAuthKey key = do
  let base64Key = key == "key-encryption-key"
      args = if base64Key then ["rand", "-base64", "32"] else ["rand", "-hex", "32"]
  generated <- try (readProcessWithExitCode "openssl" args "")
  pure $ case generated of
    Left (_ :: IOException) -> Left "could not generate auth credential"
    Right (ExitFailure _, _, _) -> Left "could not generate auth credential"
    Right (ExitSuccess, output, _) ->
      let secret = T.strip (T.pack output)
       in if (base64Key && T.length secret == 44 && T.isSuffixOf "=" secret)
            || (not base64Key && T.length secret == 64)
            then Right (Key.fromText key, String (b64encode secret))
            else Left "auth credential generator returned an invalid value"

authCredentialKind :: Value -> Either Text (Maybe [Text])
authCredentialKind (Object root) | KM.lookup "kind" root == Just (String "Secret") = do
  metadata <- metadataOf (Object root)
  annotations <- case KM.lookup "annotations" metadata of
    Just (Object fields) -> Right fields
    Nothing -> Right KM.empty
    _ -> Left "auth credential annotations are malformed"
  case textAt "nagare.dev/auth-credential-template" annotations of
    Nothing -> Right Nothing
    Just "v1" -> do
      namespace <- fieldText "namespace" metadata
      name <- fieldText "name" metadata
      unless (namespace == "nagare-system" && not (KM.member "data" root) && not (KM.member "stringData" root))
        (Left "auth credential template has an invalid namespace or includes data")
      case name of
        "nagare-en-api-keys" -> Right (Just ["read-write", "read-only"])
        "nagare-shomei-keys" -> Right (Just ["key-encryption-key"])
        "nagare-access" -> Right (Just ["cookie-key"])
        _ -> Left "auth credential template has an unexpected Secret name"
    Just _ -> Left "unknown auth credential template"
authCredentialKind _ = Right Nothing

generatedCredentialTemplate :: Text -> Either Text Bool
generatedCredentialTemplate native = do
  value <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 native))
  auth <- authCredentialKind value
  database <- databaseCredentialKind value
  minio <- minioCredentialKind value
  pure (isJust auth || isJust database || isJust minio)

databaseCredentialKind :: Value -> Either Text (Maybe (Text, Text, Engine))
databaseCredentialKind value = case value of
  Object root | KM.lookup "kind" root == Just (String "Secret") -> do
    metadata <- metadataOf value
    annotations <- case KM.lookup "annotations" metadata of
      Just (Object fields) -> Right fields
      Nothing -> Right KM.empty
      _ -> Left "reviewed Secret annotations are malformed"
    case textAt "nagare.dev/credential-template" annotations of
      Nothing -> Right Nothing
      Just "database-v1" -> do
        unless (not (KM.member "data" root) && not (KM.member "stringData" root))
          (Left "database credential template may not include Secret data")
        labels <- case KM.lookup "labels" metadata of
          Just (Object fields) -> Right fields
          _ -> Left "database credential template lacks labels"
        dbName <- fieldText "nagare.dev/database" labels
        namespace <- fieldText "namespace" metadata
        secretName <- fieldText "name" metadata
        unless (secretName == dbSecretName dbName) (Left "database credential template has the wrong Secret name")
        engineName <- fieldText "nagare.dev/engine" labels
        engine <- maybe (Left "database credential template has an unknown engine") Right (parseEngine engineName)
        pure (Just (dbName, namespace, engine))
      Just _ -> Left "unknown Kubernetes credential template"
  _ -> Right Nothing

fillCredential :: Value -> Text -> Text -> Engine -> Text -> Either Text Text
fillCredential template dbName namespace engine password = do
  let connection = ConnectionParts defaultDbUser password (dbHost dbName namespace) (sanitizeDbName dbName)
      generated = renderDbSecret (DbSecretInputs dbName namespace engine (secretKeysFor engine connection))
  generatedValue <- first (T.pack . show) (eitherDecodeStrict generated)
  secretData <- case generatedValue of
    Object root -> maybe (Left "generated credential has no data") Right (KM.lookup "data" root)
    _ -> Left "generated credential is malformed"
  case template of
    Object root -> TE.decodeUtf8 <$> canonicalValue (Object (KM.insert "data" secretData root))
    _ -> Left "credential template is malformed"

credentialDataMatches :: Value -> Value -> Bool
credentialDataMatches desired observed = case authCredentialKind desired of
  Right (Just keys) -> databaseCredentialKind desired == Right Nothing
    && dataMatches (Set.fromList (map Key.fromText keys)) observed
  Left _ -> False
  Right Nothing -> case minioCredentialKind desired of
    Right (Just _) -> case observed of
      Object root -> case KM.lookup "data" root of
        Just (Object fields) -> validMinioData fields
        _ -> False
      _ -> False
    Left _ -> False
    Right Nothing -> databaseDataMatches desired observed

databaseDataMatches :: Value -> Value -> Bool
databaseDataMatches desired observed = case databaseCredentialKind desired of
  Right Nothing -> True
  Left _ -> False
  Right (Just (_, _, engine)) ->
    let connection = ConnectionParts defaultDbUser "example" "example" "example"
        expected = Set.fromList (map (Key.fromText . fst) (secretKeysFor engine connection))
     in dataMatches expected observed

dataMatches :: Set.Set Key -> Value -> Bool
dataMatches expected (Object root) = case KM.lookup "data" root of
  Just (Object entries) -> Set.fromList (KM.keys entries) == expected
    && all (\case String encoded -> either (const False) (not . T.null) (b64decode encoded); _ -> False) (KM.elems entries)
  _ -> False
dataMatches _ _ = False

cacheClientTemplate :: Value -> Either Text (Maybe (ResourceId, Text))
cacheClientTemplate value = case value of
  Object root | KM.lookup "kind" root == Just (String "ConfigMap") -> do
    metadata <- metadataOf value
    annotations <- case KM.lookup "annotations" metadata of
      Just (Object fields) -> Right fields
      Nothing -> Right KM.empty
      _ -> Left "cache client annotations are malformed"
    case textAt "nagare.dev/cache-client-template" annotations of
      Nothing -> Right Nothing
      Just "v1" -> do
        name <- fieldText "name" metadata
        namespace <- fieldText "namespace" metadata
        unless (name == "nagare-nix-cache-client" && namespace == "personal")
          (Left "cache client template has an unexpected address")
        producerText <- fieldText "nagare.dev/cache-key-producer" annotations
        producer <- mkResourceId producerText
        entries <- case KM.lookup "data" root of
          Just (Object fields) -> Right fields
          _ -> Left "cache client template has no data"
        template <- case KM.toList entries of
          [("nix.conf", String textValue)] -> Right textValue
          _ -> Left "cache client template must contain only nix.conf"
        unless (T.count "${ATTIC_PUBLIC_KEY}" template == 1)
          (Left "cache client template has no unique public-key slot")
        pure (Just (producer, template))
      Just _ -> Left "unknown cache client template"
  _ -> Right Nothing

withoutCacheClientData :: Value -> Value
withoutCacheClientData value@(Object root) = case cacheClientTemplate value of
  Right (Just _) -> Object (KM.delete "data" root)
  _ -> value
withoutCacheClientData value = value

cacheClientDataMatches :: Value -> Value -> Bool
cacheClientDataMatches desired observed = case cacheClientTemplate desired of
  Right Nothing -> True
  Left _ -> False
  Right (Just (_, template)) -> case observed of
    Object root -> case KM.lookup "data" root of
      Just (Object entries) -> case KM.toList entries of
        [("nix.conf", String actual)] ->
          let (prefix, markerAndSuffix) = T.breakOn "${ATTIC_PUBLIC_KEY}" template
              suffix = T.drop (T.length "${ATTIC_PUBLIC_KEY}") markerAndSuffix
           in case T.stripPrefix prefix actual >>= T.stripSuffix suffix of
                Just key -> validCachePublicKey key
                Nothing -> False
        _ -> False
      _ -> False
    _ -> False

materializeCacheKey :: (ResourceId -> IO (Either Text Text)) -> Text -> IO (Either Text Text)
materializeCacheKey resolve native = case eitherDecodeStrict (TE.encodeUtf8 native) of
  Left (_ :: String) -> pure (Left "reviewed cache client object is malformed")
  Right value -> case cacheClientTemplate value of
    Left reason -> pure (Left reason)
    Right Nothing -> pure (Right native)
    Right (Just (producer, template)) -> do
      resolved <- resolve producer
      pure $ do
        key <- resolved
        unless (validCachePublicKey key) (Left "cache resolver returned an invalid public key")
        case value of
          Object root -> do
            let dataValue = object ["nix.conf" .= T.replace "${ATTIC_PUBLIC_KEY}" key template]
            TE.decodeUtf8 <$> canonicalValue (Object (KM.insert "data" dataValue root))
          _ -> Left "cache client object is malformed"

validCachePublicKey :: Text -> Bool
validCachePublicKey key =
  not (T.null key) && T.count ":" key == 1
    && T.all (\character -> character > ' ' && character /= '\DEL') key

addPreconditions :: PhysicalIdentity -> Text -> Text -> Either Text Text
addPreconditions uid revision native = do
  value <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 native))
  metadata <- metadataOf value
  let guarded = KM.insert "uid" (String (physicalIdentityText uid))
        (KM.insert "resourceVersion" (String revision) metadata)
  case value of
    Object root -> TE.decodeUtf8 <$> canonicalValue (Object (KM.insert "metadata" (Object guarded) root))
    _ -> Left "Kubernetes native object is not an object"

applyRequest :: PhysicalIdentity -> Text -> Text -> Either Text ([String], Text)
applyRequest uid revision native = do
  body <- addPreconditions uid revision native
  pure (["apply", "--server-side", "--force-conflicts", "--field-manager=nagare-inventory", "-f", "-"], body)

-- | Adoption changes only Nagare's reserved annotations. The API server
-- tests UID and resourceVersion in the same JSON Patch that writes them, so a
-- replacement or concurrent mutation cannot be stamped from a stale review.
adoptionPatch :: KubernetesRuntimeConfig -> KubernetesMutation -> PhysicalIdentity -> Text -> IO (Either Text ([String], Text))
adoptionPatch config mutation uid revision = case mutationAddress mutation of
  Kubernetes _ group kind namespace name -> do
    fetched <- invoke config
      (["get", kindToken group kind, T.unpack (nameText name)]
        <> namespaceArgs namespace <> ["-o", "json"]) ""
    pure $ do
      observed <- case fetched of
        Right (ExitSuccess, output, _) ->
          first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)))
        _ -> Left "could not verify the unowned Kubernetes object before adoption"
      metadata <- metadataOf observed
      liveUid <- fieldText "uid" metadata
      liveRevision <- fieldText "resourceVersion" metadata
      unless (liveUid == physicalIdentityText uid && liveRevision == revision)
        (Left "Kubernetes adoption identity or resourceVersion changed")
      annotations <- case KM.lookup "annotations" metadata of
        Nothing -> Right Nothing
        Just (Object values) -> Right (Just values)
        _ -> Left "Kubernetes annotations are malformed"
      let reserved =
            [ ("nagare.dev/context-id", contextIdText (runtimeContext config))
            , ("nagare.dev/resource-id", resourceIdText (mutationResource mutation))
            , ("nagare.dev/spec-digest", digestText (mutationNativeDigest mutation))
            ]
      when (maybe False (\values -> any (\(key, _) -> KM.member (Key.fromText key) values) reserved) annotations)
        (Left "Kubernetes object already has an inventory ownership stamp")
      let tests =
            [ object ["op" .= ("test" :: Text), "path" .= ("/metadata/uid" :: Text), "value" .= liveUid]
            , object ["op" .= ("test" :: Text), "path" .= ("/metadata/resourceVersion" :: Text), "value" .= liveRevision]
            ]
          writes = case annotations of
            Nothing -> [object ["op" .= ("add" :: Text), "path" .= ("/metadata/annotations" :: Text),
              "value" .= object [Key.fromText key .= value | (key, value) <- reserved]]]
            Just _ -> [object ["op" .= ("add" :: Text),
              "path" .= ("/metadata/annotations/" <> T.replace "/" "~1" key), "value" .= value]
              | (key, value) <- reserved]
      patch <- canonicalValue (toJSON (tests <> writes))
      pure (["patch", kindToken group kind, T.unpack (nameText name)]
        <> namespaceArgs namespace <> ["--type=json", "--field-manager=nagare-inventory",
          "-p", T.unpack (TE.decodeUtf8 patch)], "")
  _ -> pure (Left "Kubernetes adoption has no Kubernetes address")

-- | Service ports use a merge key that includes the port number. SSA can
-- temporarily retain both unnamed entries while changing that number, which
-- fails Service validation. For a port-only transition, replace the entire
-- reviewed port list atomically after testing UID and resourceVersion. Refuse
-- if any other desired field differs, so the patch cannot silently omit it.
servicePortPatch :: PhysicalIdentity -> Text -> Text -> Value -> Either Text (Maybe Text)
servicePortPatch uid revision native observed = do
  desired <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 native))
  desiredSpec <- specOf desired
  observedSpec <- specOf observed
  ports <- maybe (Left "reviewed Service lacks spec.ports") Right (KM.lookup "ports" desiredSpec)
  oldPorts <- maybe (Left "observed Service lacks spec.ports") Right (KM.lookup "ports" observedSpec)
  if desiredFieldsMatch ports oldPorts then Right Nothing else do
    desiredMetadata <- metadataOf desired
    observedMetadata <- metadataOf observed
    desiredAnnotations <- annotationsOf desiredMetadata
    observedAnnotations <- annotationsOf observedMetadata
    newDigest <- maybe (Left "reviewed Service lacks spec digest") Right (KM.lookup "nagare.dev/spec-digest" desiredAnnotations)
    let projectedSpec = KM.insert "ports" ports observedSpec
        projectedAnnotations = KM.insert "nagare.dev/spec-digest" newDigest observedAnnotations
        projectedMetadata = KM.insert "annotations" (Object projectedAnnotations) observedMetadata
        projected = case observed of
          Object root -> Object (KM.insert "metadata" (Object projectedMetadata) (KM.insert "spec" (Object projectedSpec) root))
          _ -> observed
    unless (desiredFieldsMatch desired projected)
      (Left "Service port transition also changes other fields; a guarded per-kind patch is required")
    patch <- canonicalValue (toJSON
      [ object ["op" .= ("test" :: Text), "path" .= ("/metadata/uid" :: Text), "value" .= physicalIdentityText uid]
      , object ["op" .= ("test" :: Text), "path" .= ("/metadata/resourceVersion" :: Text), "value" .= revision]
      , object ["op" .= ("replace" :: Text), "path" .= ("/spec/ports" :: Text), "value" .= ports]
      , object ["op" .= ("replace" :: Text), "path" .= ("/metadata/annotations/nagare.dev~1spec-digest" :: Text), "value" .= newDigest]
      ])
    pure (Just (TE.decodeUtf8 patch))
  where
    specOf (Object root) = case KM.lookup "spec" root of
      Just (Object value) -> Right value
      _ -> Left "Service lacks spec object"
    specOf _ = Left "Service is not an object"
    annotationsOf metadata = case KM.lookup "annotations" metadata of
      Just (Object value) -> Right value
      _ -> Left "Service inventory annotations are missing"

-- | A create is recorded as an Update field manager even when it uses the
-- same manager name as later server-side apply. Force is safe only while all
-- non-status fields still belong exclusively to that manager. The subsequent
-- apply includes the observed UID/resourceVersion, so a change after this
-- read makes the API server reject the write.
confirmInventoryFieldOwnership :: PhysicalIdentity -> Text -> Value -> Either Text ()
confirmInventoryFieldOwnership = confirmInventoryFieldOwnershipFor Nothing

confirmInventoryFieldOwnershipFor :: Maybe ProviderAddress -> PhysicalIdentity -> Text -> Value -> Either Text ()
confirmInventoryFieldOwnershipFor target uid revision observed = do
  metadata <- metadataOf observed
  actualUid <- fieldText "uid" metadata
  actualRevision <- fieldText "resourceVersion" metadata
  unless (actualUid == physicalIdentityText uid && actualRevision == revision)
    (Left "Kubernetes object changed after the reviewed observation")
  fields <- case KM.lookup "managedFields" metadata of
    Just (Array entries) | not (null entries) -> Right (foldr (:) [] entries)
    _ -> Left "Kubernetes managed fields are missing; update ownership is unknown"
  mapM_ checkEntry fields
  unless (any isInventoryOwner fields)
    (Left "Kubernetes object has no inventory-managed fields to update")
  where
    checkEntry (Object entry) = do
      manager <- fieldText "manager" entry
      fieldSet <- case KM.lookup "fieldsV1" entry of
        Just (Object value) -> Right value
        _ -> Left "Kubernetes managed-field entry is malformed"
      unless (manager == "nagare-inventory" || statusOnly fieldSet || expectedControllerFields target manager fieldSet)
        (Left ("Kubernetes object has fields managed by another writer: " <> manager))
    checkEntry _ = Left "Kubernetes managed-field entry is malformed"
    isInventoryOwner (Object entry) = textAt "manager" entry == Just "nagare-inventory"
    isInventoryOwner _ = False
    statusOnly fields = all (== "f:status") (KM.keys fields)

-- PVC provisioners add these annotations after the create-only write. They
-- do not intersect inventory's desired fields. Any other controller field is
-- still a refusal until its specific owner and path have been established.
expectedControllerFields :: Maybe ProviderAddress -> Text -> Object -> Bool
expectedControllerFields (Just (Kubernetes _ "" kind _ _)) "k3s" fields
  | nameText kind == "persistentvolumeclaim" =
      not (null paths) && all (`elem` allowed) paths
  where
    paths = managedPaths [] fields
    allowed =
      [ ["f:metadata", "f:annotations", "f:volume.beta.kubernetes.io/storage-provisioner"]
      , ["f:metadata", "f:annotations", "f:volume.kubernetes.io/selected-node"]
      , ["f:metadata", "f:annotations", "f:volume.kubernetes.io/storage-provisioner"]
      , ["f:spec", "f:volumeName"]
      ]
expectedControllerFields (Just (Kubernetes _ "apps" kind _ _)) "k3s" fields
  | nameText kind == "deployment" =
      ["f:metadata", "f:annotations", "f:deployment.kubernetes.io/revision"] `elem` paths
        && all permitted paths
  where
    paths = managedPaths [] fields
    permitted ["f:metadata", "f:annotations", "."] = True
    permitted ["f:metadata", "f:annotations", "f:deployment.kubernetes.io/revision"] = True
    permitted ("f:status" : _) = True
    permitted _ = False
expectedControllerFields _ _ _ = False

managedPaths :: [Text] -> Object -> [[Text]]
managedPaths prefix fields = concatMap one (KM.toList fields)
  where
    one (key, Object nested)
      | KM.null nested = [prefix <> [Key.toText key]]
      | otherwise = managedPaths (prefix <> [Key.toText key]) nested
    one (key, _) = [prefix <> [Key.toText key]]

verifyLiveOwnership :: KubernetesRuntimeConfig -> ProviderAddress -> PhysicalIdentity -> Text -> IO (Either Text Value)
verifyLiveOwnership config target uid revision = case target of
  Kubernetes _ group kind namespace name -> do
    result <- invoke config
      (["get", kindToken group kind, T.unpack (nameText name)]
        <> namespaceArgs namespace <> ["-o", "json", "--show-managed-fields"])
      ""
    pure $ case result of
      Right (ExitSuccess, output, _) -> do
        observed <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)))
        confirmInventoryFieldOwnershipFor (Just target) uid revision observed
        pure observed
      _ -> Left "could not verify Kubernetes field ownership before update"
  _ -> pure (Left "Kubernetes mutation has no Kubernetes address")

kindToken :: Text -> Name -> String
kindToken group kind = T.unpack (nameText kind <> if T.null group then "" else "." <> group)

namespaceArgs :: Maybe Name -> [String]
namespaceArgs = maybe [] (\namespace -> ["--namespace", T.unpack (nameText namespace)])

invoke :: KubernetesRuntimeConfig -> [String] -> String -> IO (Either Text (ExitCode, String, String))
invoke config arguments input = do
  result <- try (readProcessWithExitCode "kubectl"
    (["--context", T.unpack (runtimeKubectlContext config), "--request-timeout=10s"] <> arguments) input)
  pure $ case result of
    Left (_ :: IOException) -> Left "could not invoke kubectl"
    Right output -> Right output
