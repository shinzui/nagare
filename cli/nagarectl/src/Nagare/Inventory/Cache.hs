-- | Render packaged cache templates once during planning and bind their exact
-- structured values to the typed cache-core declarations.
module Nagare.Inventory.Cache
  ( CacheRenderInput (..)
  , compileCacheNative
  ) where

import Data.Aeson
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
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.CacheKubernetes
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

compileCacheNative
  :: CacheRenderInput
  -> IO (Either (NonEmpty InventoryError) (ResourceBundle, Map ResourceId (ManagedResource, ByteString)))
compileCacheNative input = case validateInputs input of
  Left err -> pure (Left (single err))
  Right () -> do
    let root = renderTemplateRoot input
        source = SourceLocation (T.pack root) "cache-core"
    serverTemplate <- BS.readFile (root </> "server.toml.tmpl")
    workloadTemplate <- BS.readFile (root </> "workloads.yaml.tmpl")
    policyTemplate <- BS.readFile (root </> "networkpolicies.yaml")
    pure $ do
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
      workload <- first single (parseKubernetesManifest source workloadTemplate)
      policies <- first single (parseKubernetesManifest source policyTemplate)
      let resolve = replaceTemplate (renderImage input) (digestText serverDigest)
          workloadValues = map (resolve . snd) workload
          policyValues = map snd policies
      unless (all (not . hasPlaceholder) workloadValues)
        (Left (single (invalid "cache workload has an unresolved template placeholder")))
      (deployment, publicService, internalService, gc) <- case workloadValues of
        [a, b, c, d] -> Right (a, b, c, d)
        _ -> Left (single (invalid "cache workload template must contain exactly four objects"))
      (serverPolicy, clientPolicy) <- case policyValues of
        [a, b] -> Right (a, b)
        _ -> Left (single (invalid "cache network policy template must contain exactly two objects"))
      let core = CacheCoreInput
            (renderOwner input) (renderCluster input) (renderLogicalKey input)
            (renderDatabase input) (renderCredential input)
            configMap deployment publicService internalService gc serverPolicy clientPolicy source
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
