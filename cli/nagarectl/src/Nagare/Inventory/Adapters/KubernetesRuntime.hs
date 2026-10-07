-- | Explicit-context kubectl transport for reviewed Kubernetes objects.
-- Create is a server-side create-only request. Ordinary updates are server-side
-- apply; an unnamed Service port transition uses a guarded JSON Patch.
-- Both include UID and resourceVersion checks. A forced transfer from the
-- create operation is allowed only after a live managed-fields check proves
-- there is no foreign owner of the object's non-status fields. A
-- transport failure is ambiguous until a new observation proves its outcome.
module Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (..)
  , identified
  , mkKubernetesRuntimeOps
  , mkKubernetesRuntimeOpsWithCacheKey
  , mkKubernetesRuntimeOpsAndBatchWithCacheKey
  , observeKubernetesBatchWithGuard
  , desiredFieldsMatch
  , deploymentSelectorReplacement
  , statefulSetImmutableReplacement
  , observeKubernetesConfiguration
  , parseObservedConfiguration
  , parseObserved
  , confirmInventoryFieldOwnership
  , confirmInventoryFieldOwnershipFor
  , readLiveManagedObject
  , jobCompleted
  , readBackupReceiptFromCompletedPod
  , readCompletedJobContainerMessage
  , backupReceiptFromPodList
  , completedJobContainerMessageFromPodList
  , crdEstablished
  , certificateReady
  , knativeReady
  , materializeCredential
  , materializeLocalObjectStoreCredential
  , materializeLocalObjectStoreCredentialWith
  , minioSourceData
  , supportedUpdateAddress
  , supportedUpdateKinds
  , readinessKinds
  , supportsReadiness
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
  )
where

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
import Nagare.Inventory.Adapters.KubernetesCollection (collectionDeleteRequest)
import Nagare.Inventory.Adapters.KubernetesFields (desiredFieldsMatch)
import Nagare.Inventory.Adapters.KubernetesKinds (readinessKinds, supportedUpdateKinds)
import Nagare.Inventory.Adapters.KubernetesProof (kubectlRefusal, resourceVersionConflict)
import Nagare.Inventory.Adapters.KubernetesReadiness
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Inventory.KubernetesConfiguration (configurationDigest, confirmInventoryFieldOwnership, confirmInventoryFieldOwnershipFor, confirmReviewedFieldTakeover, confirmTakeoverSettled, confirmUpdateTarget, liveStamp)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), invokeKubectl)
import Nagare.Inventory.Migration.PostgresRename (migrationFenced, scaledToZero)
import Nagare.Resource.Inventory (ManagedResource (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

mkKubernetesRuntimeOps ::
  KubernetesRuntimeConfig ->
  Map ResourceId (ManagedResource, ByteString) ->
  KubernetesAdapterOps
mkKubernetesRuntimeOps config = mkKubernetesRuntimeOpsWithCacheKey config (\_ -> pure (Left "cache public-key resolver is not installed"))

mkKubernetesRuntimeOpsWithCacheKey ::
  KubernetesRuntimeConfig ->
  (ResourceId -> IO (Either Text Text)) ->
  Map ResourceId (ManagedResource, ByteString) ->
  KubernetesAdapterOps
mkKubernetesRuntimeOpsWithCacheKey config resolveCacheKey specs =
  fst (mkKubernetesRuntimeOpsAndBatchWithCacheKey config resolveCacheKey specs)

mkKubernetesRuntimeOpsAndBatchWithCacheKey ::
  KubernetesRuntimeConfig ->
  (ResourceId -> IO (Either Text Text)) ->
  Map ResourceId (ManagedResource, ByteString) ->
  (KubernetesAdapterOps, [ResourceId] -> IO [KubernetesState])
mkKubernetesRuntimeOpsAndBatchWithCacheKey = mkKubernetesRuntimeObservations False

observeKubernetesConfiguration ::
  KubernetesRuntimeConfig ->
  (ResourceId -> IO (Either Text Text)) ->
  Map ResourceId (ManagedResource, ByteString) ->
  ResourceId ->
  IO (KubernetesState, Maybe ContentDigest)
observeKubernetesConfiguration config cache specs = kubernetesObserveStamped (fst (mkKubernetesRuntimeObservations True config cache specs))

mkKubernetesRuntimeObservations ::
  Bool ->
  KubernetesRuntimeConfig ->
  (ResourceId -> IO (Either Text Text)) ->
  Map ResourceId (ManagedResource, ByteString) ->
  (KubernetesAdapterOps, [ResourceId] -> IO [KubernetesState])
mkKubernetesRuntimeObservations stable config resolveCacheKey specs =
  ( KubernetesAdapterOps
      { kubernetesContext = runtimeContext config
      , kubernetesObserveStamped = observe
      , kubernetesMutateConditional = mutate (1 :: Int)
      }
  , observeKubernetesBatchWithGuard (runtimeGuard config) (fmap fst . observeWithoutGuard)
  )
  where
    observe resource = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (KubernetesUnknown ("cluster guard refused: " <> reason), Nothing)
        Right () -> observeWithoutGuard resource
    observeWithoutGuard resource = case Map.lookup resource specs of
      Nothing -> pure (KubernetesUnknown "Kubernetes resource has no native binding", Nothing)
      Just (declaration, native) -> case address declaration of
        Kubernetes _ group kind namespace name -> do
          result <-
            invoke
              config
              ( ["get", kindToken group kind, T.unpack (nameText name)]
                  <> namespaceArgs namespace
                  <> ["-o", "json", "--ignore-not-found"]
                  <> ["--show-managed-fields" | stable]
              )
              ""
          case result of
            Left reason -> pure (KubernetesUnknown reason, Nothing)
            -- Before bootstrap installs a CRD, the API server can prove
            -- that no instance of its kind is currently addressable.
            -- Other get failures remain unknown, including authorization
            -- and transport failures.
            Right (ExitFailure _, _, errors)
              | "the server doesn't have a resource type" `T.isInfixOf` T.pack errors ->
                  pure (KubernetesAbsent (contentDigest (TE.encodeUtf8 (resourceIdText resource <> ":absent"))), Nothing)
              | otherwise -> pure (KubernetesUnknown "kubectl get failed", Nothing)
            Right (ExitSuccess, output, _)
              | null output -> pure (KubernetesAbsent (contentDigest (TE.encodeUtf8 (resourceIdText resource <> ":absent"))), Nothing)
              | otherwise -> case parseObservedWithConfiguration stable config resource native (T.pack output) of
                  Left reason -> pure (KubernetesUnknown reason, Nothing)
                  Right state -> (,liveStamp (T.pack output)) <$> observeCacheClientOutput resolveCacheKey native (T.pack output) state
        _ -> pure (KubernetesUnknown "bound resource has no Kubernetes address", Nothing)
    mutate attempt mutation = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (AdapterEffectAmbiguous ("cluster guard refused before Kubernetes write: " <> reason))
        Right () -> do
          materialized <- case mutationAction mutation of
            CreateResource -> materializeLocalObjectStoreCredential config (mutationNativeJson mutation)
            _ -> pure (Right (mutationNativeJson mutation))
          resolved <-
            if mutationAction mutation == RetireResource
              then pure (Right "")
              else case materialized of
                Left reason -> pure (Left reason)
                Right native -> materializeCacheKey resolveCacheKey native
          -- F72: an update of an unready object (a correction) is written like
          -- any other; the guard is its UID, stamp and field owners, read live,
          -- and the transport still waits for readiness after the write.
          let updateBefore = case (mutationAction mutation, mutationBefore mutation) of
                (UpdateResource, KubernetesNotReady uid revision owner digest) -> KubernetesPresent uid revision owner digest
                _ -> mutationBefore mutation
          request <- case (mutationAction mutation, updateBefore) of
            (CreateResource, KubernetesAbsent _) ->
              pure ((["create", "--field-manager=nagare-inventory", "-f", "-"],) <$> resolved)
            (AdoptResource, KubernetesPresent uid revision Nothing digest)
              | digest == mutationNativeDigest mutation ->
                  adoptionPatch config mutation uid revision
            (RetireResource, KubernetesPresent uid revision (Just owner) digest)
              | owner == mutationResource mutation
              , digest == mutationNativeDigest mutation ->
                  pure (collectionDeleteRequest (mutationAddress mutation) uid revision)
            -- A retained StatefulSet is usually scaled down or unready; the
            -- server preconditions still bind its exact UID and version.
            (RetireResource, KubernetesNotReady uid revision (Just owner) digest)
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
                  ownership <- verifyLiveOwnership config (mutationAddress mutation) uid (mutationBeforeStamp mutation) (mutationTakeover mutation)
                  pure $ do
                    (observed, fresh) <- ownership
                    native <- resolved
                    case mutationAddress mutation of
                      Kubernetes _ "" kind namespace name | nameText kind == "service" ->
                        case servicePortPatch uid fresh native observed of
                          Left reason -> Left reason
                          Right (Just patch) ->
                            Right
                              ( ["patch", "service", T.unpack (nameText name)]
                                  <> namespaceArgs namespace
                                  <> ["--type=json", "--field-manager=nagare-inventory", "-p", T.unpack patch]
                              , ""
                              )
                          Right Nothing -> applyRequest uid fresh native
                      _ -> applyRequest uid fresh native
            _ -> pure (Left "Kubernetes transport received an unsupported action or precondition")
          case request of
            Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
            Right (arguments, body) -> do
              -- ADR 27: a write returns the object it wrote; its UID is the
              -- identity the journal records, whatever happens afterwards.
              let writes = mutationAction mutation /= RetireResource
              result <- invoke config (arguments <> (if writes then ["-o", "json"] else [])) (T.unpack body)
              case result of
                Right (ExitSuccess, _, _)
                  | not writes ->
                      waitForCollection config (mutationAddress mutation)
                Right (ExitSuccess, output, _)
                  | Just takeover <- mutationTakeover mutation -> do
                      live <- readLiveManagedObject config (mutationAddress mutation)
                      identified output <$> case live >>= confirmTakeoverSettled (Just (mutationAddress mutation)) (takeoverPhysical takeover) of
                        Left reason -> pure (AdapterEffectAmbiguous reason)
                        Right () -> waitForReadiness config (mutationAddress mutation)
                  | otherwise -> identified output <$> waitForReadiness config (mutationAddress mutation)
                Right (ExitFailure _, _, errors) | mutationAction mutation == UpdateResource, attempt < 3, resourceVersionConflict (T.pack errors) -> mutate (attempt + 1) mutation
                Right (ExitFailure _, _, errors) | Just refusal <- kubectlRefusal (T.pack errors) -> pure (AdapterEffectFailed (KnownNoEffect refusal))
                _ -> pure (AdapterEffectAmbiguous "Kubernetes write did not return success; reobserve before retry")

-- | Attach the UID of the object a write returned. Output that names no UID
-- leaves the effect unidentified, so the member stays unrecorded.
identified :: String -> AdapterExecution -> AdapterExecution
identified output outcome = maybe outcome (`AdapterEffectIdentified` outcome) returned
  where
    returned = either (const Nothing) Just $ do
      value <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)) :: Either String Value)
      metadataOf value >>= fieldText "uid" >>= mkPhysicalIdentity

-- | A review observes one explicit Kubernetes context. Validate the ambient
-- context and server node before and after the read-only scan; discard every
-- observation if either check fails. Individual effect paths retain their own
-- fresh guard calls through 'kubernetesObserve' and 'kubernetesMutateConditional'.
observeKubernetesBatchWithGuard ::
  IO (Either Text ()) ->
  (ResourceId -> IO KubernetesState) ->
  [ResourceId] ->
  IO [KubernetesState]
observeKubernetesBatchWithGuard checkGuard observe resources
  | null resources = pure []
  | otherwise = do
      before <- checkGuard
      case before of
        Left reason -> pure (refused reason)
        Right () -> do
          states <- traverse observe resources
          after <- checkGuard
          pure (either refused (const states) after)
  where
    refused reason =
      replicate
        (length resources)
        (KubernetesUnknown ("cluster guard refused: " <> reason))

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
supportedUpdateAddress (Kubernetes _ group kind _ _) = (group, nameText kind) `elem` supportedUpdateKinds
supportedUpdateAddress _ = False

waitForReadiness :: KubernetesRuntimeConfig -> ProviderAddress -> IO AdapterExecution
waitForReadiness config address = case address of
  Kubernetes _ "batch" kind namespace name
    | nameText kind == "job" ->
        waitCondition "complete" "job" namespace name "Job"
  Kubernetes _ "apiextensions.k8s.io" kind namespace name
    | nameText kind == "customresourcedefinition" ->
        waitCondition "established" "crd" namespace name "CustomResourceDefinition"
  Kubernetes _ "cert-manager.io" kind namespace name
    | nameText kind `elem` ["certificate", "clusterissuer"] ->
        waitCondition "ready" (T.unpack (nameText kind)) namespace name "cert-manager resource"
  Kubernetes _ "serving.knative.dev" kind namespace name
    | nameText kind == "service" ->
        waitCondition "ready" "ksvc" namespace name "Knative Service"
  Kubernetes _ "serving.knative.dev" kind namespace name
    | nameText kind == "domainmapping" ->
        waitCondition "ready" "domainmapping.serving.knative.dev" namespace name "Knative DomainMapping"
  Kubernetes _ "apps" kind namespace name | nameText kind == "deployment" -> do
    result <-
      invoke
        config
        ( ["rollout", "status", "deployment/" <> T.unpack (nameText name)]
            <> namespaceArgs namespace
            <> ["--timeout=300s"]
        )
        ""
    pure $ case result of
      Right (ExitSuccess, _, _) -> AdapterEffectCompleted
      _ -> AdapterEffectAmbiguous "Kubernetes Deployment did not prove availability; reobserve before retry"
  Kubernetes _ "apps" kind namespace name | nameText kind == "statefulset" -> do
    result <-
      invoke
        config
        ( ["rollout", "status", "statefulset/" <> T.unpack (nameText name)]
            <> namespaceArgs namespace
            <> ["--timeout=300s"]
        )
        ""
    pure $ case result of
      Right (ExitSuccess, _, _) -> AdapterEffectCompleted
      _ -> AdapterEffectAmbiguous "Kubernetes StatefulSet did not prove readiness; reobserve before retry"
  _ -> pure AdapterEffectCompleted
  where
    waitCondition condition kind namespace name label = do
      result <-
        invoke
          config
          ( ["wait", "--for=condition=" <> condition, kind <> "/" <> T.unpack (nameText name)]
              <> namespaceArgs namespace
              <> ["--timeout=300s"]
          )
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
            result <-
              invoke
                config
                ( ["get", kindToken group kind, T.unpack (nameText name)]
                    <> namespaceArgs namespace
                    <> ["-o", "json", "--ignore-not-found"]
                )
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

supportsReadiness :: ProviderAddress -> Bool
supportsReadiness address = maybe False (const True) (readinessForAddress address Null)

-- The client ConfigMap's data is delegated at review time, but observation
-- still compares it with the current output of the named logical cache.
observeCacheClientOutput ::
  (ResourceId -> IO (Either Text Text)) ->
  ByteString ->
  Text ->
  KubernetesState ->
  IO KubernetesState
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

parseObserved :: KubernetesRuntimeConfig -> ResourceId -> ByteString -> Text -> Either Text KubernetesState
parseObserved = parseObservedWithConfiguration False

parseObservedConfiguration :: KubernetesRuntimeConfig -> ResourceId -> ByteString -> Text -> Either Text KubernetesState
parseObservedConfiguration = parseObservedWithConfiguration True

parseObservedWithConfiguration :: Bool -> KubernetesRuntimeConfig -> ResourceId -> ByteString -> Text -> Either Text KubernetesState
parseObservedWithConfiguration stable config resource native response = do
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
      fenced = migrationFenced desired observed
      fieldsMatch =
        desiredFieldsMatch (withoutCacheClientData (if fenced then scaledToZero desired else desired)) observed
          && credentialDataMatches desired observed
          && cacheClientDataMatches desired observed
      stampMatches = textAt "nagare.dev/spec-digest" annotations == Just (digestText desiredDigest)
      hasAnyStamp =
        any
          (`KM.member` annotations)
          ["nagare.dev/context-id", "nagare.dev/resource-id", "nagare.dev/spec-digest"]
  when
    (hasAnyStamp && (stampedContext == Nothing || stampedOwner == Nothing))
    (Left "Kubernetes inventory ownership stamp is incomplete or malformed")
  driftDigest <-
    if stable
      then configurationDigest observed
      else
        if fieldsMatch && (not hasAnyStamp || stampMatches)
          then Right desiredDigest
          else contentDigest <$> canonicalValue observed
  -- Keep a different logical owner visible to status. A foreign context is
  -- refused below rather than being misclassified as an unstamped object.
  when
    (stampedContext /= Nothing && stampedContext /= Just (contextIdText (runtimeContext config)))
    (Left "Kubernetes object belongs to a different inventory context")
  pure $
    if deploymentSelectorReplacement desired observed
      || statefulSetImmutableReplacement desired observed
      then KubernetesReplacementRequired uid revision owner driftDigest
      else
        if jobFailed observed
          then KubernetesFailed uid revision owner driftDigest
          else
            if fenced || not (observedReady observed)
              then KubernetesNotReady uid revision owner driftDigest
              else KubernetesPresent uid revision owner driftDigest

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

-- | Read the upload container's terminal copy of the object-store receipt.
-- The pod must belong to the exact completed Job UID; the caller validates
-- the receipt against the bound native Job before recording completion.
readBackupReceiptFromCompletedPod ::
  KubernetesRuntimeConfig ->
  Map ResourceId (ManagedResource, ByteString) ->
  ResourceId ->
  PhysicalIdentity ->
  IO (Either Text ByteString)
readBackupReceiptFromCompletedPod config specs resource physical =
  readCompletedJobContainerMessage config specs resource physical "upload"

readCompletedJobContainerMessage ::
  KubernetesRuntimeConfig ->
  Map ResourceId (ManagedResource, ByteString) ->
  ResourceId ->
  PhysicalIdentity ->
  Text ->
  IO (Either Text ByteString)
readCompletedJobContainerMessage config specs resource physical containerName =
  case Map.lookup resource specs of
    Just (declaration, _) -> case address declaration of
      Kubernetes _ "batch" kind (Just namespace) name | nameText kind == "job" -> do
        guarded <- runtimeGuard config
        case guarded of
          Left reason -> pure (Left ("cluster guard refused backup receipt read: " <> reason))
          Right () -> do
            result <-
              invoke
                config
                [ "get"
                , "pods"
                , "--namespace"
                , T.unpack (nameText namespace)
                , "-l"
                , "batch.kubernetes.io/job-name=" <> T.unpack (nameText name)
                , "-o"
                , "json"
                ]
                ""
            pure $ do
              (code, output, _) <- result
              unless (code == ExitSuccess) (Left "Kubernetes backup Pod receipt read failed")
              pods <- first T.pack (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
              completedJobContainerMessageFromPodList physical containerName pods
      _ -> pure (Left "backup receipt resource is not a namespaced Job")
    Nothing -> pure (Left "backup receipt Job lacks its bound native object")

backupReceiptFromPodList :: PhysicalIdentity -> Value -> Either Text ByteString
backupReceiptFromPodList physical =
  completedJobContainerMessageFromPodList physical "upload"

completedJobContainerMessageFromPodList ::
  PhysicalIdentity -> Text -> Value -> Either Text ByteString
completedJobContainerMessageFromPodList physical containerName (Object root) = case KM.lookup "items" root of
  Just (Array items) -> case mapMaybe matchingReceipt (V.toList items) of
    [receipt] -> Right (TE.encodeUtf8 receipt)
    [] -> Left "completed backup Job has no matching upload Pod receipt"
    _ -> Left "completed backup Job has multiple matching upload Pod receipts"
  _ -> Left "Kubernetes Pod list lacks items"
  where
    matchingReceipt (Object pod) = do
      Object metadata <- KM.lookup "metadata" pod
      Array owners <- KM.lookup "ownerReferences" metadata
      guard (any ownedByJob (V.toList owners))
      Object status <- KM.lookup "status" pod
      guard (KM.lookup "phase" status == Just (String "Succeeded"))
      Array containers <- KM.lookup "containerStatuses" status
      container <- findSelected (V.toList containers)
      Object state <- KM.lookup "state" container
      Object terminated <- KM.lookup "terminated" state
      guard (KM.lookup "exitCode" terminated == Just (Number 0))
      String message <- KM.lookup "message" terminated
      guard (not (T.null message))
      pure message
    matchingReceipt _ = Nothing
    ownedByJob (Object owner) =
      KM.lookup "kind" owner == Just (String "Job")
        && KM.lookup "uid" owner == Just (String (physicalIdentityText physical))
        && KM.lookup "controller" owner == Just (Bool True)
    ownedByJob _ = False
    findSelected =
      foldr
        ( \candidate rest -> case candidate of
            Object container | KM.lookup "name" container == Just (String containerName) -> Just container
            _ -> rest
        )
        Nothing
completedJobContainerMessageFromPodList _ _ _ = Left "Kubernetes Pod list is not an object"

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
            Object root ->
              TE.decodeUtf8
                <$> canonicalValue
                  ( Object
                      (KM.insert "data" (Object (KM.fromList entries)) root)
                  )
            _ -> Left "auth credential template is malformed"
    Right Nothing -> case backupSigningCredentialKind value of
      Left reason -> pure (Left reason)
      Right (Just ()) -> do
        generated <- generateAuthKey "HMAC_KEY"
        pure $ do
          entry <- generated
          case value of
            Object root ->
              TE.decodeUtf8
                <$> canonicalValue
                  ( Object
                      (KM.insert "data" (Object (KM.fromList [entry])) root)
                  )
            _ -> Left "backup signing credential template is malformed"
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
materializeLocalObjectStoreCredential config =
  materializeLocalObjectStoreCredentialWith
    (invoke config ["get", "secret", "nagare-minio-credentials", "-n", "nagare-system", "-o", "json"] "")
    config

materializeLocalObjectStoreCredentialWith ::
  IO (Either Text (ExitCode, String, String)) ->
  KubernetesRuntimeConfig ->
  Text ->
  IO (Either Text Text)
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
          source <-
            first
              (const "local object-store source credential is malformed")
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
      unless
        ( namespace == expected
            && name == "nagare-minio-credentials"
            && not (KM.member "data" root)
            && not (KM.member "stringData" root)
        )
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
  unless
    ( name == "nagare-minio-credentials"
        && namespace == "nagare-system"
        && textAt "nagare.dev/context-id" annotations == Just (contextIdText (runtimeContext config))
        && textAt "nagare.dev/minio-credential-template" annotations == Just "v1"
        && textAt "nagare.dev/resource-id" annotations == Just expected
    )
    (Left "local object-store source credential is not owned by this context")
  case source of
    Object root -> case KM.lookup "data" root of
      Just (Object fields) | validMinioData fields -> Right fields
      _ -> Left "local object-store source credential lacks required data"
    _ -> Left "local object-store source credential is malformed"

validMinioData :: KM.KeyMap Value -> Bool
validMinioData fields =
  Set.fromList (KM.keys fields)
    == Set.fromList
      ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
    && all
      (\case String encoded -> either (const False) (not . T.null) (b64decode encoded); _ -> False)
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
      unless
        (namespace == "nagare-system" && not (KM.member "data" root) && not (KM.member "stringData" root))
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
  signing <- backupSigningCredentialKind value
  pure (isJust auth || isJust database || isJust minio || isJust signing)

backupSigningCredentialKind :: Value -> Either Text (Maybe ())
backupSigningCredentialKind value@(Object root) | KM.lookup "kind" root == Just (String "Secret") = do
  metadata <- metadataOf value
  annotations <- case KM.lookup "annotations" metadata of
    Just (Object fields) -> Right fields
    Nothing -> Right KM.empty
    _ -> Left "backup signing credential annotations are malformed"
  case textAt "nagare.dev/backup-signing-template" annotations of
    Nothing -> Right Nothing
    Just "v1" -> do
      database <- case KM.lookup "labels" metadata of
        Just (Object labels) -> fieldText "nagare.dev/database" labels
        _ -> Left "backup signing credential lacks database label"
      name <- fieldText "name" metadata
      _ <- fieldText "namespace" metadata
      unless
        ( name == "nagare-dbbackup-" <> database <> "-signing"
            && not (KM.member "data" root)
            && not (KM.member "stringData" root)
        )
        (Left "backup signing credential template has unexpected content")
      pure (Just ())
    Just _ -> Left "unknown backup signing credential template"
backupSigningCredentialKind _ = Right Nothing

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
        unless
          (not (KM.member "data" root) && not (KM.member "stringData" root))
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
  Right (Just keys) ->
    databaseCredentialKind desired == Right Nothing
      && dataMatches (Set.fromList (map Key.fromText keys)) observed
  Left _ -> False
  Right Nothing -> case backupSigningCredentialKind desired of
    Right (Just ()) -> backupSigningDataMatches observed
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

backupSigningDataMatches :: Value -> Bool
backupSigningDataMatches (Object root) = case KM.lookup "data" root of
  Just (Object fields) | Set.fromList (KM.keys fields) == Set.singleton "HMAC_KEY" ->
    case KM.lookup "HMAC_KEY" fields of
      Just (String encoded) -> case b64decode encoded of
        Right key -> T.length key == 64 && T.all lowerHex key
        Left _ -> False
      _ -> False
  _ -> False
  where
    lowerHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
backupSigningDataMatches _ = False

dataMatches :: Set.Set Key -> Value -> Bool
dataMatches expected (Object root) = case KM.lookup "data" root of
  Just (Object entries) ->
    Set.fromList (KM.keys entries) == expected
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
        unless
          (name == "nagare-nix-cache-client" && namespace == "personal")
          (Left "cache client template has an unexpected address")
        producerText <- fieldText "nagare.dev/cache-key-producer" annotations
        producer <- mkResourceId producerText
        entries <- case KM.lookup "data" root of
          Just (Object fields) -> Right fields
          _ -> Left "cache client template has no data"
        template <- case KM.toList entries of
          [("nix.conf", String textValue)] -> Right textValue
          _ -> Left "cache client template must contain only nix.conf"
        unless
          (T.count "${ATTIC_PUBLIC_KEY}" template == 1)
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
  not (T.null key)
    && T.count ":" key == 1
    && T.all (\character -> character > ' ' && character /= '\DEL') key

addPreconditions :: PhysicalIdentity -> Text -> Text -> Either Text Text
addPreconditions uid revision native = do
  value <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 native))
  metadata <- metadataOf value
  let guarded =
        KM.insert
          "uid"
          (String (physicalIdentityText uid))
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
    fetched <-
      invoke
        config
        ( ["get", kindToken group kind, T.unpack (nameText name)]
            <> namespaceArgs namespace
            <> ["-o", "json"]
        )
        ""
    pure $ do
      observed <- case fetched of
        Right (ExitSuccess, output, _) ->
          first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)))
        _ -> Left "could not verify the unowned Kubernetes object before adoption"
      metadata <- metadataOf observed
      liveUid <- fieldText "uid" metadata
      liveRevision <- fieldText "resourceVersion" metadata
      unless
        (liveUid == physicalIdentityText uid && liveRevision == revision)
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
      when
        (maybe False (\values -> any (\(key, _) -> KM.member (Key.fromText key) values) reserved) annotations)
        (Left "Kubernetes object already has an inventory ownership stamp")
      let tests =
            [ object ["op" .= ("test" :: Text), "path" .= ("/metadata/uid" :: Text), "value" .= liveUid]
            , object ["op" .= ("test" :: Text), "path" .= ("/metadata/resourceVersion" :: Text), "value" .= liveRevision]
            ]
          writes = case annotations of
            Nothing ->
              [ object
                  [ "op" .= ("add" :: Text)
                  , "path" .= ("/metadata/annotations" :: Text)
                  , "value" .= object [Key.fromText key .= value | (key, value) <- reserved]
                  ]
              ]
            Just _ ->
              [ object
                  [ "op" .= ("add" :: Text)
                  , "path" .= ("/metadata/annotations/" <> T.replace "/" "~1" key)
                  , "value" .= value
                  ]
              | (key, value) <- reserved
              ]
      patch <- canonicalValue (toJSON (tests <> writes))
      pure
        ( ["patch", kindToken group kind, T.unpack (nameText name)]
            <> namespaceArgs namespace
            <> [ "--type=json"
               , "--field-manager=nagare-inventory"
               , "-p"
               , T.unpack (TE.decodeUtf8 patch)
               ]
        , ""
        )
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
  if desiredFieldsMatch ports oldPorts
    then Right Nothing
    else do
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
      unless
        (desiredFieldsMatch desired projected)
        (Left "Service port transition also changes other fields; a guarded per-kind patch is required")
      patch <-
        canonicalValue
          ( toJSON
              [ object ["op" .= ("test" :: Text), "path" .= ("/metadata/uid" :: Text), "value" .= physicalIdentityText uid]
              , object ["op" .= ("test" :: Text), "path" .= ("/metadata/resourceVersion" :: Text), "value" .= revision]
              , object ["op" .= ("replace" :: Text), "path" .= ("/spec/ports" :: Text), "value" .= ports]
              , object ["op" .= ("replace" :: Text), "path" .= ("/metadata/annotations/nagare.dev~1spec-digest" :: Text), "value" .= newDigest]
              ]
          )
      pure (Just (TE.decodeUtf8 patch))
  where
    specOf (Object root) = case KM.lookup "spec" root of
      Just (Object value) -> Right value
      _ -> Left "Service lacks spec object"
    specOf _ = Left "Service is not an object"
    annotationsOf metadata = case KM.lookup "annotations" metadata of
      Just (Object value) -> Right value
      _ -> Left "Service inventory annotations are missing"

-- | A version-3 mutation allows the exact foreign entries its review recorded.
verifyLiveOwnership :: KubernetesRuntimeConfig -> ProviderAddress -> PhysicalIdentity -> Maybe ContentDigest -> Maybe FieldTakeover -> IO (Either Text (Value, Text))
verifyLiveOwnership config target uid stamp takeover = do
  live <- readLiveManagedObject config target
  pure (live >>= \observed -> (observed,) <$> confirmUpdateTarget (Just target) (maybe [] takeoverManagers takeover) uid stamp (takeoverResourceVersion <$> takeover) observed)

readLiveManagedObject :: KubernetesRuntimeConfig -> ProviderAddress -> IO (Either Text Value)
readLiveManagedObject config target = case target of
  Kubernetes _ group kind namespace name -> do
    result <- invoke config (["get", kindToken group kind, T.unpack (nameText name)] <> namespaceArgs namespace <> ["-o", "json", "--show-managed-fields"]) ""
    pure $ case result of
      Right (ExitSuccess, output, _) -> first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)))
      _ -> Left "could not read Kubernetes field ownership"
  _ -> pure (Left "Kubernetes mutation has no Kubernetes address")

kindToken :: Text -> Name -> String
kindToken group kind = T.unpack (nameText kind <> if T.null group then "" else "." <> group)

namespaceArgs :: Maybe Name -> [String]
namespaceArgs = maybe [] (\namespace -> ["--namespace", T.unpack (nameText namespace)])

invoke :: KubernetesRuntimeConfig -> [String] -> String -> IO (Either Text (ExitCode, String, String))
invoke = invokeKubectl
