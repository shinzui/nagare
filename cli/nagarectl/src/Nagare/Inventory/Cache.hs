-- | Render packaged cache templates once during planning and bind their exact
-- structured values to the typed cache-core declarations.
module Nagare.Inventory.Cache
  ( CacheRenderInput (..)
  , compileCacheNative
  , compileCacheComponent
  , compileCacheCandidate
  , logicalConfigurationDigest
  ) where

import Data.Aeson
import Control.Exception (IOException, try)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.Dsl.Database (Database (..), Engine (Postgres))
import Nagare.Dsl.Types (databaseNameText, namespaceText)
import Nagare.Inventory.Database (compileDatabaseForBackend)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.CacheKubernetes
import Nagare.Resource.Cache (LogicalCacheInput (..), compileLogicalCache)
import Nagare.Resource.CacheClient (CacheClientInput (..), compileCacheClient)
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.FilePath ((</>))

data CacheRenderInput = CacheRenderInput
  { renderOwner :: !ScopeId
  , renderCluster :: !ResourceId
  , renderLogicalKey :: !LogicalKey
  , renderDatabase :: !ResourceId
  , renderCredential :: !ResourceId
  , renderImage :: !Text
  , renderBucket :: !Text
  , renderTemplateRoot :: !FilePath
  }

-- | Compose one owner scope from the complete database bundle, the nine
-- direct cache objects, and the Attic logical cache/output contract.
compileCacheComponent
  :: DatabaseDirectInput
  -> StoreBackend
  -> CacheRenderInput
  -> IO (Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)))
compileCacheComponent databaseInput backend cacheInput = do
  coreResult <- compileCacheNative cacheInput
  clientTemplate <- try (BS.readFile (renderTemplateRoot cacheInput </> "client-configmap.yaml.tmpl")) :: IO (Either IOException ByteString)
  pure $ do
    unless (directOwnerScope databaseInput == renderOwner cacheInput
        && directClusterId databaseInput == renderCluster cacheInput)
      (Left (single (invalid "cache and database must share one owner and cluster")))
    unless (databaseNameText (directDatabase databaseInput ^. #name) == "nix-cache-db"
        && namespaceText (directDatabase databaseInput ^. #namespace) == "nagare-system"
        && directDatabase databaseInput ^. #engine == Postgres)
      (Left (single (invalid "cache transport requires the nix-cache-db PostgreSQL database in nagare-system")))
    expectedDatabase <- first (single . invalid) (databaseResourceId (renderOwner cacheInput) (known "statefulset") (directDatabase databaseInput))
    expectedCredential <- first (single . invalid) (databaseResourceId (renderOwner cacheInput) (known "credential") (directDatabase databaseInput))
    unless (renderDatabase cacheInput == expectedDatabase && renderCredential cacheInput == expectedCredential)
      (Left (single (invalid "cache prerequisites differ from the compiled database identities")))
    (databaseBundle, databaseNative) <- compileDatabaseForBackend databaseInput backend
    (coreBundle, coreNative) <- coreResult
    templateBytes <- first (single . invalid . ("cannot read cache client template: " <>) . T.pack . show) clientTemplate
    clientObjects <- first single (parseKubernetesManifest (SourceLocation (T.pack (renderTemplateRoot cacheInput)) "client-config") templateBytes)
    clientTemplateValue <- case clientObjects of
      [(_, value)] -> Right value
      _ -> Left (single (invalid "cache client template must contain exactly one ConfigMap"))
    let logicalResource = mintResourceId (renderOwner cacheInput) (renderLogicalKey cacheInput) (known "logical-cache")
    clientObject <- first (single . invalid) (setClientProducer logicalResource clientTemplateValue)
    (clientBundle, clientId, clientValue) <- compileCacheClient (fmap contentDigest . canonicalValue)
      (CacheClientInput (renderOwner cacheInput) (renderCluster cacheInput) (renderLogicalKey cacheInput)
        logicalResource clientObject (SourceLocation (T.pack (renderTemplateRoot cacheInput)) "client-config"))
    clientNative <- bindMember cacheInput clientBundle (clientId, clientValue)
    let logicalCache = compileLogicalCache (LogicalCacheInput
          (renderOwner cacheInput) (renderCluster cacheInput) (renderLogicalKey cacheInput)
          (known "nagare-cache") logicalConfigurationDigest expectedDatabase
          (mintResourceId (renderOwner cacheInput) (renderLogicalKey cacheInput) (known "deployment"))
          (SourceLocation (T.pack (renderTemplateRoot cacheInput)) "logical-cache"))
    scope <- mkScopeDeclaration (renderOwner cacheInput) [databaseBundle, coreBundle, logicalCache, clientBundle]
    unless (Map.null (Map.intersection databaseNative coreNative))
      (Left (single (invalid "database and cache native members share a logical identity")))
    pure (scope, Map.insert clientId (snd clientNative) (Map.union databaseNative coreNative))
  where
    invalid message = inventoryError "invalid-cache-component" message
      & #scopes .~ [renderOwner cacheInput]
    known = either (error . show) id . mkName

-- | Compose the generated component against a caller-supplied snapshot. The
-- native map is held in memory until plan preparation retains it privately.
compileCacheCandidate
  :: ScopeSnapshot
  -> DatabaseDirectInput
  -> StoreBackend
  -> CacheRenderInput
  -> IO (Either (NonEmpty InventoryError) (CompositionCandidate, Map ResourceId (ManagedResource, ByteString)))
compileCacheCandidate snapshot databaseInput backend cacheInput = do
  compiled <- compileCacheComponent databaseInput backend cacheInput
  pure $ do
    (scope, native) <- compiled
    candidate <- composeInventory snapshot (ReplaceScope scope :| [])
    pure (candidate, native)

logicalConfigurationDigest :: ContentDigest
logicalConfigurationDigest = contentDigest (either (error . T.unpack) id (canonicalValue (object
  [ "public" .= True
  , "retentionSeconds" .= (2592000 :: Int)
  , "substituterEndpoint" .= ("http://nix-cache-internal.nagare-system.svc.cluster.local:8080/nagare-cache" :: Text)
  ])))

compileCacheNative
  :: CacheRenderInput
  -> IO (Either (NonEmpty InventoryError) (ResourceBundle, Map ResourceId (ManagedResource, ByteString)))
compileCacheNative input = case validateInputs input of
  Left err -> pure (Left (single err))
  Right () -> do
    let root = renderTemplateRoot input
        source = SourceLocation (T.pack root) "cache-core"
    templates <- traverse (\file -> try (BS.readFile (root </> file)) :: IO (Either IOException ByteString))
      ["server.toml.tmpl", "config-check-job.yaml.tmpl", "migration-job.yaml.tmpl", "workloads.yaml.tmpl", "networkpolicies.yaml"]
    pure $ do
      (serverTemplate, checkTemplate, migrationTemplate, workloadTemplate, policyTemplate) <- case sequence templates of
        Right [server, checkBytes, migrationBytes, workloadBytes, policyBytes] -> Right (server, checkBytes, migrationBytes, workloadBytes, policyBytes)
        Right _ -> Left (single (invalid "cache template set is incomplete"))
        Left err -> Left (single (invalid ("cannot read packaged cache template: " <> T.pack (show err))))
      serverText <- first (single . invalid . T.pack . show) (TE.decodeUtf8' serverTemplate)
      unless (T.count "${NAGARE_NIX_CACHE_BUCKET}" serverText == 1)
        (Left (single (invalid "cache server template must contain one bucket placeholder")))
      let serverConfigText = T.replace "${NAGARE_NIX_CACHE_BUCKET}" (renderBucket input) serverText
          serverDigest = contentDigest (TE.encodeUtf8 serverConfigText)
          configMap = object
            [ "apiVersion" .= ("v1" :: Text)
            , "kind" .= ("ConfigMap" :: Text)
            , "metadata" .= object
                [ "name" .= ("nagare-nix-cache-server" :: Text)
                , "namespace" .= ("nagare-system" :: Text)
                , "labels" .= object ["app.kubernetes.io/part-of" .= ("nagare" :: Text)]
                ]
            , "data" .= object ["server.toml" .= serverConfigText]
            ]
      revisionBytes <- first (single . invalid) (canonicalValue (object
        ["image" .= renderImage input, "serverConfigDigest" .= serverDigest]))
      let revision = contentDigest revisionBytes
          suffix = T.take 12 (digestText revision)
      checks <- first single (parseKubernetesManifest source checkTemplate)
      migrations <- first single (parseKubernetesManifest source migrationTemplate)
      workload <- first single (parseKubernetesManifest source workloadTemplate)
      policies <- first single (parseKubernetesManifest source policyTemplate)
      let resolve = replaceTemplate (renderImage input) (digestText serverDigest)
          workloadValues = map (resolve . snd) workload
          policyValues = map snd policies
      checkJob <- case checks of
        [(_, value)] -> first (single . invalid) (setObjectName ("nix-cache-config-check-" <> suffix) (resolve value))
        _ -> Left (single (invalid "cache config-check template must contain exactly one Job"))
      migrationJob <- case migrations of
        [(_, value)] -> first (single . invalid) (setObjectName ("nix-cache-migrate-" <> suffix) (resolve value))
        _ -> Left (single (invalid "cache migration template must contain exactly one Job"))
      unless (all (not . hasPlaceholder) (checkJob : migrationJob : workloadValues))
        (Left (single (invalid "cache workload has an unresolved template placeholder")))
      (deployment, publicService, internalService, gc) <- case workloadValues of
        [a, b, c, d] -> Right (a, b, c, d)
        _ -> Left (single (invalid "cache workload template must contain exactly four objects"))
      (serverPolicy, clientPolicy) <- case policyValues of
        [a, b] -> Right (a, b)
        _ -> Left (single (invalid "cache network policy template must contain exactly two objects"))
      let core = CacheCoreInput
            (renderOwner input) (renderCluster input) (renderLogicalKey input)
            (renderDatabase input) (renderCredential input) revision
            configMap checkJob migrationJob deployment publicService internalService gc serverPolicy clientPolicy source
      (bundle, native) <- compileCacheCore (fmap contentDigest . canonicalValue) core
      bound <- traverse (bindMember input bundle) native
      pure (bundle, Map.fromList bound)
  where
    invalid message = inventoryError "invalid-cache-native" message
      & #scopes .~ [renderOwner input]
      & #sources .~ [SourceLocation (T.pack (renderTemplateRoot input)) "cache-core"]

validateInputs :: CacheRenderInput -> Either InventoryError ()
validateInputs input
  | not (validImageDigest (renderImage input)) = Left (invalid "cache image must be pinned to a sha256 digest")
  | T.any (not . imageCharacter) (renderImage input) = Left (invalid "cache image contains an invalid character")
  | T.null (renderBucket input) || T.any (not . bucketCharacter) (renderBucket input) = Left (invalid "cache bucket contains an invalid character")
  | otherwise = Right ()
  where
    imageCharacter c = c `elem` ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:/@._-" :: String)
    bucketCharacter c = c `elem` ("abcdefghijklmnopqrstuvwxyz0123456789.-_" :: String)
    validImageDigest value =
      let (prefix, suffix) = T.breakOnEnd "@sha256:" value
       in not (T.null prefix) && T.length suffix == 64 && T.all (`elem` ("0123456789abcdef" :: String)) suffix
    invalid message = inventoryError "invalid-cache-render-input" message
      & #scopes .~ [renderOwner input]

replaceTemplate :: Text -> Text -> Value -> Value
replaceTemplate image digest = go
  where
    go (String "${ATTIC_IMAGE}") = String image
    go (String "${ATTIC_CONFIG_SHA256}") = String digest
    go (Object fields) = Object (fmap go fields)
    go (Array values) = Array (fmap go values)
    go value = value

hasPlaceholder :: Value -> Bool
hasPlaceholder (String value) = "${" `T.isInfixOf` value
hasPlaceholder (Object fields) = any hasPlaceholder (KM.elems fields)
hasPlaceholder (Array values) = any hasPlaceholder values
hasPlaceholder _ = False

setObjectName :: Text -> Value -> Either Text Value
setObjectName name (Object root) = case KM.lookup "metadata" root of
  Just (Object metadata) -> Right (Object (KM.insert "metadata" (Object (KM.insert "name" (String name) metadata)) root))
  _ -> Left "cache Job has no metadata object"
setObjectName _ _ = Left "cache Job is not an object"

setClientProducer :: ResourceId -> Value -> Either Text Value
setClientProducer producer (Object root) = case KM.lookup "metadata" root of
  Just (Object metadata) -> do
    annotations <- case KM.lookup "annotations" metadata of
      Nothing -> Right KM.empty
      Just (Object values) -> Right values
      _ -> Left "cache client annotations are malformed"
    unless (not (KM.member "nagare.dev/cache-key-producer" annotations)
        && not (KM.member "nagare.dev/cache-client-template" annotations))
      (Left "cache client template preclaims generated-key annotations")
    let stamped = KM.insert "nagare.dev/cache-key-producer" (String (resourceIdText producer))
          (KM.insert "nagare.dev/cache-client-template" (String "v1") annotations)
    pure (Object (KM.insert "metadata" (Object (KM.insert "annotations" (Object stamped) metadata)) root))
  _ -> Left "cache client ConfigMap has no metadata object"
setClientProducer _ _ = Left "cache client template is not an object"

bindMember
  :: CacheRenderInput
  -> ResourceBundle
  -> (ResourceId, Value)
  -> Either (NonEmpty InventoryError) (ResourceId, (ManagedResource, ByteString))
bindMember input bundle (resource, value) = do
  declaration <- maybe (Left (single (invalid "cache native object has no declaration"))) Right
    (lookup resource [(r ^. #identity, r) | Managed r <- declarations bundle])
  digest <- first (single . invalid) (contentDigest <$> canonicalValue value)
  (recompiled, bytes) <- first single $ bindKubernetesObject
    KubernetesInput
      { resourceId = resource
      , ownerScope = declaration ^. #owner
      , clusterId = renderCluster input
      , inputObject = value
      , objectDigest = digest
      , lifecyclePolicy = declaration ^. #lifecycle
      , inputDataPolicy = declaration ^. #dataPolicy
      , inputSensitivity = declaration ^. #sensitivity
      , sourceLocation = declaration ^. #source
      }
  unless (recompiled {dependencies = declaration ^. #dependencies} == declaration)
    (Left (single (invalid "cache native object changed during binding")))
  pure (resource, (declaration, bytes))
  where
    invalid message = inventoryError "invalid-cache-native" message
      & #scopes .~ [renderOwner input]
      & #sources .~ [SourceLocation (T.pack (renderTemplateRoot input)) "cache-core"]

single :: InventoryError -> NonEmpty InventoryError
single errorValue = errorValue :| []
