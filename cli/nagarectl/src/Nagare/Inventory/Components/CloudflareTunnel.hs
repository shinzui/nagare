-- | The Cloudflare Tunnel connector as scope @platform:cloudflare-tunnel@ (EP-241).
--
-- One namespace, its NetworkPolicy and Deployment from the packaged template,
-- and the operator's token Secret as a private member. The token is an
-- interception credential (ADR 34): it rests sops-encrypted in the context's
-- cluster-secrets directory and in this one Secret, and is never a context
-- variable. Only its digest reaches a plan, to roll the pods when it changes.
module Nagare.Inventory.Components.CloudflareTunnel
  ( CloudflareTunnelInput (..)
  , cloudflareTunnelTokenSecretFile
  , compileCloudflareTunnel
  , connectorImage
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
import Nagare.Inventory.Components.ObservabilitySecrets (normalizeSecretData)
import Nagare.Inventory.Components.Upstream
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (parseKubernetesManifest)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.FilePath ((</>))

data CloudflareTunnelInput = CloudflareTunnelInput
  { root :: !FilePath
  , foundation :: !FoundationInput
  , image :: !Text
  -- ^ An immutable @…\@sha256:…@ reference.
  , tokenSecret :: !(SourceLocation, Value)
  -- ^ The decrypted Secret from 'cloudflareTunnelTokenSecretFile'.
  }
  deriving stock (Generic)

-- | The connector image, pinned by digest (cloudflared 2026.10.7, observed in EP-240).
connectorImage :: Text
connectorImage = "docker.io/cloudflare/cloudflared@sha256:4955524aeaa379e154023d5a027c250f7b35041a2e7e950cf13f144bc9b9c5ba"

-- | The context's sops-encrypted token Secret in its cluster-secrets directory.
cloudflareTunnelTokenSecretFile :: FilePath
cloudflareTunnelTokenSecretFile = "cloudflare-tunnel-token.yaml"

compileCloudflareTunnel ::
  CloudflareTunnelInput ->
  IO (Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)))
compileCloudflareTunnel input = case validated of
  Left reason -> pure (Left (invalid reason :| []))
  Right (tokenDigest, secretObject) -> do
    loaded <- try (BS.readFile (input ^. #root </> templatePath)) :: IO (Either IOException ByteString)
    case loaded of
      Left _ -> pure (Left (invalid ("the connector template is unavailable: " <> T.pack templatePath) :| []))
      Right bytes -> case render tokenDigest bytes of
        Left reason -> pure (Left (invalid reason :| []))
        Right rendered -> case parseKubernetesManifest (SourceLocation (T.pack templatePath) "cloudflare-tunnel") rendered of
          Left reason -> pure (Left (reason :| []))
          Right objects -> do
            result <- compileUpstream (upstreamInput (objects <> [secretObject]))
            pure $ do
              (bundle, native) <- result
              scope <- mkScopeDeclaration owner [bundle]
              pure (scope, native)
  where
    templatePath = "cluster/bootstrap/cloudflare-tunnel/connector.yaml.tmpl"
    owner = known (mkScopeId Platform "cloudflare-tunnel")
    cluster = foundationCluster (input ^. #foundation)
    known :: Either Text a -> a
    known = either (error . T.unpack) id
    invalid = inventoryError "invalid-cloudflare-tunnel"
    address api kind name = known (kubernetesAddress cluster api kind (Just connectorNamespace) name)
    deployment = address "apps/v1" "Deployment" "cloudflared"
    policy = address "networking.k8s.io/v1" "NetworkPolicy" "cloudflared"
    secret = address "v1" "Secret" tokenSecretName

    validated = do
      unless (immutableImage (input ^. #image)) (Left "the connector image must be an immutable @sha256 reference")
      checkTokenSecret (input ^. #tokenSecret)
      normalized <- normalizeSecretData (input ^. #tokenSecret)
      tokenBytes <- canonicalValue (snd normalized)
      Right (digestText (contentDigest tokenBytes), input ^. #tokenSecret)

    render tokenDigest bytes = do
      text <- first (const "the connector template is not UTF-8") (TE.decodeUtf8' bytes)
      let rendered = T.replace "@TOKEN_DIGEST@" tokenDigest (T.replace "@IMAGE@" (input ^. #image) text)
      when (any (`T.isInfixOf` rendered) ["@TOKEN_DIGEST@", "@IMAGE@"]) (Left "the connector template kept a placeholder")
      Right (TE.encodeUtf8 rendered)

    upstreamInput generated =
      UpstreamInput
        { upstreamOwner = owner
        , upstreamCluster = cluster
        , upstreamKey = known (mkLogicalKey "cloudflare-tunnel")
        , upstreamRoot = input ^. #root
        , upstreamFiles = []
        , upstreamNamespaces = Map.empty
        , upstreamTransferred = Set.empty
        , upstreamConfigMapData = Map.empty
        , upstreamImageOverrides = Map.empty
        , upstreamGenerated = generated
        , -- The policy exists before a pod can start, so no connector runs unbounded.
          upstreamAfter = Map.singleton deployment [policy, secret]
        , upstreamExternalAfter = Map.empty
        , upstreamOrderDeployments = False
        , upstreamRegistryDelegations = Map.empty
        }

connectorNamespace :: Text
connectorNamespace = "cloudflare-tunnel"

tokenSecretName :: Text
tokenSecretName = "cloudflare-tunnel-token"

-- | Exactly @cloudflare-tunnel-token@ in the connector's namespace, holding @token@ and nothing else.
checkTokenSecret :: (SourceLocation, Value) -> Either Text ()
checkTokenSecret (_, Object root) = do
  unless (KM.lookup "kind" root == Just (String "Secret")) (Left "the tunnel token input is not a Kubernetes Secret")
  metadata <- case KM.lookup "metadata" root of
    Just (Object fields) -> Right fields
    _ -> Left "the tunnel token Secret has no metadata"
  unless
    ( KM.lookup "name" metadata == Just (String tokenSecretName)
        && KM.lookup "namespace" metadata == Just (String connectorNamespace)
    )
    (Left "the tunnel token Secret must be cloudflare-tunnel-token in cloudflare-tunnel")
  let keys =
        concat
          [ KM.keys fields
          | field <- ["data", "stringData"]
          , Just (Object fields) <- [KM.lookup field root]
          ]
  unless (keys == ["token"]) (Left "the tunnel token Secret must hold exactly token")
checkTokenSecret _ = Left "the tunnel token input is not an object"

immutableImage :: Text -> Bool
immutableImage reference = case T.breakOn "@sha256:" reference of
  (name, digest) ->
    not (T.null name)
      && T.all (\c -> c /= ' ' && c /= '"') name
      && T.length digest == 72
      && T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) (T.drop 8 digest)
