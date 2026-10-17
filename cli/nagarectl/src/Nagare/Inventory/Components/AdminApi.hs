-- | The read-only admin API as scope @platform:admin-api@ (EP-198).
--
-- One Deployment, its ClusterIP Service and NetworkPolicy from the packaged
-- template for the context's mode, a protected DomainMapping for
-- @admin.\<base domain>@ in @nagare-system@ whose ref is the nagare-access
-- enforcer, and an 'ApiBackend' contribution to the auth owner's backend map.
-- A cloud context also binds the operator's reader Secret as a private
-- member. The gateway reloads the backend map by itself, so no enforcer
-- rollout is part of this scope.
module Nagare.Inventory.Components.AdminApi
  ( AdminApiInput (..)
  , AdminApiStore (..)
  , adminApiHost
  , adminApiReaderSecretFile
  , compileAdminApi
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
import Data.Yaml qualified as Yaml
import Nagare.Access.Resolve (RouteTarget (..), backendConfigMapNamespace, renderAccessDomainMapping)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.Foundation (FoundationInput (..), foundationNamespaceId)
import Nagare.Inventory.Components.ObservabilitySecrets (normalizeSecretData)
import Nagare.Inventory.Components.Upstream
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (parseKubernetesManifest)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.FilePath ((</>))

-- | Where the server reads the context's inventory.
data AdminApiStore
  = -- | The node directory the local substrate mounts from the workstation,
    -- with the numeric owner and group of the store, whose files are private
    -- to that owner.
    LocalMountedStore !Int !Int
  | -- | The context's GCS prefix through the dedicated reader account, whose
    -- decrypted key Secret is bound as a private member.
    CloudReaderStore
      { storeUrl :: !Text
      , projectNumber :: !Text
      , readerSecret :: !(SourceLocation, Value)
      }
  deriving stock (Eq, Show, Generic)

data AdminApiInput = AdminApiInput
  { root :: !FilePath
  , foundation :: !FoundationInput
  , baseDomain :: !Text
  , context :: !Text
  , project :: !Text
  , image :: !Text
  -- ^ An immutable @…\@sha256:…@ reference.
  , store :: !AdminApiStore
  }
  deriving stock (Generic)

-- | The admin API's one public hostname; the future UI shares its origin.
adminApiHost :: Text -> Text
adminApiHost baseDomain = "admin." <> baseDomain

-- | The context's sops-encrypted reader Secret in its cluster-secrets
-- directory (docs/runbooks/admin-api-reader.md).
adminApiReaderSecretFile :: FilePath
adminApiReaderSecretFile = "admin-api-reader.yaml"

-- | Compile the scope against the composed declarations, which must hold the
-- auth owner's enforcer for the same cluster.
compileAdminApi ::
  AdminApiInput ->
  [Declaration] ->
  IO (Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)))
compileAdminApi input declarations = case validated of
  Left reason -> pure (Left (invalid reason :| []))
  Right (enforcerId, substitutions, secretObjects) -> do
    loaded <- try (BS.readFile (input ^. #root </> templatePath)) :: IO (Either IOException ByteString)
    case loaded of
      Left _ -> pure (Left (invalid ("the admin API template is unavailable: " <> T.pack templatePath) :| []))
      Right bytes -> case render substitutions bytes of
        Left reason -> pure (Left (invalid reason :| []))
        Right rendered -> case parseKubernetesManifest (SourceLocation (T.pack templatePath) "admin-api") rendered of
          Left reason -> pure (Left (reason :| []))
          Right objects -> case decodeMapping enforcerTarget of
            Left reason -> pure (Left (invalid reason :| []))
            Right mappingObject -> do
              result <-
                compileUpstream
                  (upstreamInput enforcerId (objects <> secretObjects <> [mappingObject]))
              pure $ do
                (bundle, native) <- result
                let aliased = Map.map (first withHostAlias) native
                    contributed =
                      bundle
                        { declarations = map aliasDeclaration (bundle ^. #declarations)
                        , contributions = [RegisterBackend authOwner cluster hostName upstream ApiBackend hostKey]
                        }
                scope <- mkScopeDeclaration owner [contributed]
                pure (scope, aliased)
  where
    owner = known (mkScopeId Platform "admin-api")
    authOwner = known (mkScopeId Platform "auth")
    cluster = foundationCluster (input ^. #foundation)
    host = adminApiHost (input ^. #baseDomain)
    hostName = known (mkName host)
    hostKey = known (mkLogicalKey host)
    upstream = "http://nagare-admin-api." <> backendConfigMapNamespace <> ".svc.cluster.local"
    known :: Either Text a -> a
    known = either (error . T.unpack) id
    invalid = inventoryError "invalid-admin-api"
    address api kind name = known (kubernetesAddress cluster api kind (Just backendConfigMapNamespace) name)
    deployment = address "apps/v1" "Deployment" "nagare-admin-api"
    service = address "v1" "Service" "nagare-admin-api"
    policy = address "networking.k8s.io/v1" "NetworkPolicy" "nagare-admin-api"
    secret = address "v1" "Secret" "nagare-admin-api-reader"
    domainMapping = address "serving.knative.dev/v1beta1" "DomainMapping" host
    enforcerAddress = known (kubernetesAddress cluster "serving.knative.dev/v1" "Service" (Just backendConfigMapNamespace) "nagare-access")
    enforcerTarget = RouteTarget "serving.knative.dev/v1" "Service" "nagare-access" backendConfigMapNamespace
    (templatePath, cloud) = case input ^. #store of
      LocalMountedStore {} -> ("cluster/bootstrap/admin-api/admin-api-local.yaml.tmpl", False)
      CloudReaderStore {} -> ("cluster/bootstrap/admin-api/admin-api-cloud.yaml.tmpl", True)

    validated = do
      unless (immutableImage (input ^. #image)) (Left "NAGARE_ADMIN_API_IMAGE must be an immutable registry/repository@sha256:<digest> reference")
      _ <- mkName (input ^. #context)
      _ <- mkName (input ^. #project)
      _ <- mkName host
      enforcerId <- case [ resource ^. #identity
                         | Managed resource <- declarations
                         , resource ^. #owner == authOwner
                         , resource ^. #address == enforcerAddress
                         ] of
        [one] -> Right one
        _ -> Left "the admin API requires the auth scope's nagare-access enforcer in the same cluster"
      let common = [("@IMAGE@", input ^. #image), ("@CONTEXT@", input ^. #context), ("@PROJECT@", input ^. #project)]
      case input ^. #store of
        LocalMountedStore uid gid -> do
          unless (uid > 0 && gid >= 0) (Left "the local admin API cannot run as root; the context's store must belong to an ordinary user")
          Right (enforcerId, common <> [("@STORE_UID@", T.pack (show uid)), ("@STORE_GID@", T.pack (show gid))], [])
        CloudReaderStore url number readerObject -> do
          unless
            (("gs://" `T.isPrefixOf` url) && T.all safeUrlChar url && T.length url > 5)
            (Left "the admin API store must be the context's gs:// inventory prefix")
          unless
            (not (T.null number) && T.all (`elem` ['0' .. '9']) number)
            (Left "a cloud admin API requires NAGARE_PROJECT_NUMBER, the project's numeric number (Pulumi output adminApiProjectNumber)")
          checkReaderSecret readerObject
          normalized <- normalizeSecretData readerObject
          -- The server reads its key once; a changed key must roll the pod.
          readerBytes <- canonicalValue (snd normalized)
          let readerDigest = digestText (contentDigest readerBytes)
          Right (enforcerId, common <> [("@STORE_URL@", url), ("@PROJECT_NUMBER@", number), ("@READER_DIGEST@", readerDigest)], [normalized])

    render substitutions bytes = do
      text <- first (const "the admin API template is not UTF-8") (TE.decodeUtf8' bytes)
      let rendered = foldl' (\acc (token, value) -> T.replace token value acc) text substitutions
          placeholders = ["@IMAGE@", "@CONTEXT@", "@PROJECT@", "@STORE_URL@", "@PROJECT_NUMBER@", "@READER_DIGEST@", "@STORE_UID@", "@STORE_GID@"]
      when
        (any (`T.isInfixOf` rendered) placeholders)
        (Left "the admin API template has a placeholder its mode does not supply")
      Right (TE.encodeUtf8 rendered)

    decodeMapping target = do
      value <-
        first
          (const "the admin API DomainMapping does not decode")
          (Yaml.decodeEither' (renderAccessDomainMapping backendConfigMapNamespace host target) :: Either Yaml.ParseException Value)
      Right (SourceLocation "admin-api" "domain-mapping", value)

    upstreamInput enforcerId generated =
      UpstreamInput
        { upstreamOwner = owner
        , upstreamCluster = cluster
        , upstreamKey = known (mkLogicalKey "admin-api")
        , upstreamRoot = input ^. #root
        , upstreamFiles = []
        , upstreamNamespaces =
            Map.singleton
              (known (mkName backendConfigMapNamespace))
              (foundationNamespaceId (input ^. #foundation) (known (mkName backendConfigMapNamespace)))
        , upstreamTransferred = Set.empty
        , upstreamConfigMapData = Map.empty
        , upstreamImageOverrides = Map.empty
        , upstreamGenerated = generated
        , upstreamAfter =
            Map.fromList [(deployment, [policy] <> [secret | cloud]), (service, [deployment])]
        , upstreamExternalAfter =
            Map.singleton domainMapping [backendMapResourceId authOwner, enforcerId]
        , upstreamOrderDeployments = False
        , upstreamRegistryDelegations = Map.empty
        }

    withHostAlias resource
      | resource ^. #address == domainMapping = resource {aliases = [Hostname hostName]}
      | otherwise = resource
    aliasDeclaration = \case
      Managed resource -> Managed (withHostAlias resource)
      other -> other

-- | The operator's reader Secret: exactly @nagare-admin-api-reader@ in
-- @nagare-system@ with a @key.json@ entry and nothing else.
checkReaderSecret :: (SourceLocation, Value) -> Either Text ()
checkReaderSecret (_, Object root) = do
  unless (KM.lookup "kind" root == Just (String "Secret")) (Left "the admin API reader input is not a Kubernetes Secret")
  metadata <- case KM.lookup "metadata" root of
    Just (Object fields) -> Right fields
    _ -> Left "the admin API reader Secret has no metadata"
  unless
    ( KM.lookup "name" metadata == Just (String "nagare-admin-api-reader")
        && KM.lookup "namespace" metadata == Just (String "nagare-system")
    )
    (Left "the admin API reader Secret must be nagare-admin-api-reader in nagare-system")
  let keys =
        concat
          [ KM.keys fields
          | field <- ["data", "stringData"]
          , Just (Object fields) <- [KM.lookup field root]
          ]
  unless (keys == ["key.json"]) (Left "the admin API reader Secret must hold exactly key.json")
checkReaderSecret _ = Left "the admin API reader input is not an object"

immutableImage :: Text -> Bool
immutableImage reference = case T.breakOn "@sha256:" reference of
  (name, digest) ->
    not (T.null name)
      && T.all (\c -> c /= ' ' && c /= '"') name
      && T.length digest == 72
      && T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) (T.drop 8 digest)

safeUrlChar :: Char -> Bool
safeUrlChar c = c > ' ' && c /= '"' && c /= '\\'
