-- | Bind the released Attic archive, its publication, and the complete cache
-- database/workload scope before the bootstrap inventory is composed.
module Nagare.Inventory.Components.PackagedCache
  ( compilePackagedCache
  , compilePackagedCacheWithVerifiedImage
  ) where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database (Database (..), Engine (Postgres), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Artifact
import Nagare.Inventory.Cache
import Nagare.Inventory.Components.ControllerImage (inspectArchive)
import Nagare.Inventory.Components.Foundation (FoundationInput (..), foundationNamespaceId)
import Nagare.Resource.Database (DatabaseDirectInput (..), databaseResourceId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import System.Directory (doesFileExist)
import System.FilePath ((</>))

compilePackagedCache
  :: FilePath -> FoundationInput -> Text -> Text -> Text -> Text
  -> IO (Either (NonEmpty InventoryError)
       (ScopeDeclaration, ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)))
compilePackagedCache root foundation project registryPrefix backupBucket cacheBucket = do
  let cacheRoot = root </> "cluster/bootstrap/nix-cache"
      pinPath = cacheRoot </> "attic-pin.json"
      archivePath = cacheRoot </> "attic-server-image.tar.gz"
  loaded <- try (BS.readFile pinPath) :: IO (Either IOException ByteString)
  archiveExists <- doesFileExist archivePath
  case loaded of
    Left failure -> pure (Left (single (invalid ("Attic payload pin is unavailable: " <> T.pack (show failure)))))
    Right _ | not archiveExists -> pure (Left (single (invalid "Attic payload image archive is unavailable")))
    Right pinBytes -> case parseAtticPin pinBytes of
      Left reason -> pure (Left (single (invalid reason)))
      Right (commit, digest) -> do
        inspected <- inspectArchive archivePath
        case inspected of
          Left reason -> pure (Left (single (invalid ("Attic payload image archive is invalid: " <> reason))))
          Right (archiveDigest, manifestDigest)
            | manifestDigest /= digest -> pure (Left (single (invalid "Attic payload image digest differs from its release pin")))
            | otherwise -> compilePackagedCacheWithVerifiedImage root foundation project registryPrefix backupBucket cacheBucket commit digest archiveDigest

-- | The production entry point above proves the archive bytes and OCI
-- manifest first. Fixtures can exercise composition with those verified
-- identities without carrying a release image archive in the source tree.
compilePackagedCacheWithVerifiedImage
  :: FilePath -> FoundationInput -> Text -> Text -> Text -> Text
  -> Text -> ContentDigest -> ContentDigest
  -> IO (Either (NonEmpty InventoryError)
       (ScopeDeclaration, ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)))
compilePackagedCacheWithVerifiedImage root foundation project registryPrefix backupBucket cacheBucket commit digest archiveDigest = do
  let cacheRoot = root </> "cluster/bootstrap/nix-cache"
      pinPath = cacheRoot </> "attic-pin.json"
  let owner = knownScope "cache"
      artifactOwner = knownScope "cache-image"
      artifactKey = knownKey "attic-image"
      artifactId = mintResourceId artifactOwner artifactKey (knownName "image")
      publishId = mintResourceId artifactOwner artifactKey (knownName "publish")
      destination = registryPrefix <> "/attic:" <> commit
      image = registryPrefix <> "/attic@sha256:" <> digestText digest
      artifactSpec = ArtifactResourceSpec
        { artifactLogicalKey = artifactKey
        , artifactRole = knownName "image"
        , artifactName = knownName "attic"
        , artifactDestination = destination
        , artifactContentDigest = digest
        , artifactSpecDigest = archiveDigest
        , artifactKind = OciImageArtifact
        , artifactOwnership = OwnedArtifact
        , artifactLifecycle = Retain
        , artifactDataPolicy = Stateless
        , artifactSensitivity = Private
        , artifactDependencies = []
        , artifactConsumers = ConsumerCompletenessUnknown
        , artifactPublishOperation = True
        , artifactSource = SourceLocation (T.pack pinPath) "attic-image"
        }
      namespaceId = foundationNamespaceId foundation (knownName "nagare-system")
      database = Database (knownDatabase "nix-cache-db") Nothing Postgres
        (defaultEngineVersion Postgres) (knownNamespace "nagare-system")
        (knownQuantity "5Gi")
        (Just (Dsl.Resources (Just (knownQuantity "500m")) (Just (knownQuantity "1Gi")) Nothing Nothing))
        Dsl.Retain
      recovery = RecoveryIntent (knownName "postgres-backup")
        (mkSecretRef (knownName "nagare-db-nix-cache-db") (knownName "v1") :| [])
      direct = DatabaseDirectInput database owner (foundationCluster foundation)
        (Just namespaceId) recovery (SourceLocation (T.pack cacheRoot) "nix-cache-db")
      dbId = either (error . T.unpack) (\value -> value) (databaseResourceId owner (knownName "statefulset") database)
      credentialId = either (error . T.unpack) (\value -> value) (databaseResourceId owner (knownName "credential") database)
      render = CacheRenderInput owner (foundationCluster foundation) (knownKey "cache")
        dbId credentialId image cacheBucket cacheRoot (Just namespaceId)
  cache <- compileCacheComponent direct (GcsBackend project backupBucket) render
  pure $ do
    imageScope <- compileArtifactScope (ArtifactDeclarationBundle 1 artifactOwner (artifactSpec :| []))
    (cacheScope, cacheNative) <- cache
    let attach resource = resource {dependencies = OrderedAfter publishId : resource ^. #dependencies}
        attachDeclaration (Managed resource) = Managed (attach resource)
        attachDeclaration declaration = declaration
        orderedBundles = [bundle {declarations = map attachDeclaration (declarations bundle)}
          | bundle <- scopeBundles cacheScope]
        orderedNative = Map.map (\(resource, bytes) -> (attach resource, bytes)) cacheNative
    orderedCache <- mkScopeDeclaration owner orderedBundles
    unless (artifactId `elem` [declarationId declaration | bundle <- scopeBundles imageScope,
        declaration <- declarations bundle])
      (Left (single (invalid "Attic image publication identity changed")))
    pure (imageScope, orderedCache, orderedNative)

invalid :: Text -> InventoryError
invalid message = inventoryError "invalid-packaged-cache" message

single :: InventoryError -> NonEmpty InventoryError
single err = err :| []

knownName :: Text -> Name
knownName = either (error . T.unpack) id . mkName

knownKey :: Text -> LogicalKey
knownKey = either (error . T.unpack) id . mkLogicalKey

knownScope :: Text -> ScopeId
knownScope = either (error . T.unpack) id . mkScopeId Platform

knownDatabase :: Text -> Dsl.DatabaseName
knownDatabase = either (error . T.unpack) id . mkDatabaseName

knownNamespace :: Text -> Dsl.Namespace
knownNamespace = either (error . T.unpack) id . Dsl.mkNamespace

knownQuantity :: Text -> Dsl.Quantity
knownQuantity = either (error . T.unpack) id . Dsl.mkQuantity

parseAtticPin :: ByteString -> Either Text (Text, ContentDigest)
parseAtticPin bytes = do
  value <- first (T.pack . show) (eitherDecodeStrict' bytes)
  root <- case value of Object entries -> Right entries; _ -> Left "Attic pin is not an object"
  commit <- textField "sourceCommit" root
  digestTextValue <- textField "linuxAmd64Digest" root
  unless (not (T.null commit) && T.all (\char -> char `elem` (['0'..'9'] <> ['a'..'f'])) commit)
    (Left "Attic source commit is malformed")
  digest <- case T.stripPrefix "sha256:" digestTextValue of
    Nothing -> Left "Attic image digest is not SHA-256"
    Just hexDigest -> mkContentDigest hexDigest
  pure (commit, digest)
  where
    textField key root = case KM.lookup key root of
      Just (String value) -> Right value
      _ -> Left "Attic pin is missing a required field"
