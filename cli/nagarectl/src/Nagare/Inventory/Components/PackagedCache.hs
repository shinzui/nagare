-- | Bind the released Attic archive, its publication, and the complete cache
-- database/workload scope before the bootstrap inventory is composed.
module Nagare.Inventory.Components.PackagedCache
  ( compilePackagedCache
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
import Nagare.Inventory.Components.Foundation (FoundationInput (..), foundationNamespaceId)
import Nagare.Inventory.Digest (contentDigest)
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
    Right pinBytes | not archiveExists -> pure (Left (single (invalid "Attic payload image archive is unavailable")))
    Right pinBytes -> case parsePin pinBytes of
      Left reason -> pure (Left (single (invalid reason)))
      Right (commit, digest) -> do
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
              , artifactSpecDigest = contentDigest pinBytes
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
  where
    invalid message = inventoryError "invalid-packaged-cache" message
    single err = err :| []
    knownName = either (error . T.unpack) (\value -> value) . mkName
    knownKey = either (error . T.unpack) (\value -> value) . mkLogicalKey
    knownScope = either (error . T.unpack) (\value -> value) . mkScopeId Platform
    knownDatabase = either (error . T.unpack) (\value -> value) . mkDatabaseName
    knownNamespace = either (error . T.unpack) (\value -> value) . Dsl.mkNamespace
    knownQuantity = either (error . T.unpack) (\value -> value) . Dsl.mkQuantity
    parsePin bytes = do
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
    textField key root = case KM.lookup key root of
      Just (String value) -> Right value
      _ -> Left "Attic pin is missing a required field"
