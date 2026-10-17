-- | Bootstrap / Local. Executable-private CLI boundary.
module Nagare.Cli.Bootstrap.Local
  ( LocalSubstrateSpec (..)
  , buildLocalSubstrateCandidate
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Text qualified as T
import Nagare.Cli.Bootstrap.Stage (StageMode (..))
import Nagare.Cli.Inventory.Adapters (inventoryArtifactAdapter)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Artifact
  ( ArtifactDeclarationBundle (ArtifactDeclarationBundle)
  , ArtifactResourceSpec
    ( ArtifactResourceSpec
    , artifactConsumers
    , artifactContentDigest
    , artifactDataPolicy
    , artifactDependencies
    , artifactDestination
    , artifactKind
    , artifactLifecycle
    , artifactLogicalKey
    , artifactName
    , artifactOwnership
    , artifactPublishOperation
    , artifactRole
    , artifactSensitivity
    , artifactSource
    , artifactSpecDigest
    )
  )
import Nagare.Inventory.Artifact qualified as InventoryArtifact
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Platform.Transition (sameDeclarationsModuloSource)
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy qualified as ResourcePolicy
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire qualified as ResourceWire
import Nagare.Target (ActiveTarget, Mode (Local), contextNameText, nagareStateDir)
import System.FilePath ((</>))

data LocalSubstrateSpec = LocalSubstrateSpec
  { localSpecVersion :: !Int
  , localSpecCluster :: !Text
  , localSpecRegistry :: !Text
  , localSpecRegistryHost :: !Text
  , localSpecRegistryPort :: !Text
  , localSpecK3sImage :: !Text
  , localSpecHttpPort :: !Text
  , localSpecHttpsPort :: !Text
  , localSpecK3sArg :: !Text
  }
  deriving stock (Eq, Show)

instance Aeson.FromJSON LocalSubstrateSpec where
  parseJSON = Aeson.withObject "local substrate spec" $ \value ->
    LocalSubstrateSpec
      <$> value Aeson..: "version"
      <*> value Aeson..: "cluster"
      <*> value Aeson..: "registry"
      <*> value Aeson..: "registryHost"
      <*> value Aeson..: "registryPort"
      <*> value Aeson..: "k3sImage"
      <*> value Aeson..: "httpPort"
      <*> value Aeson..: "httpsPort"
      <*> value Aeson..: "k3sArg"

buildLocalSubstrateCandidate ::
  StageMode ->
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO (Maybe ResourceInventory.CompositionCandidate)
buildLocalSubstrateCandidate mode active workspace snapshot
  | active ^. #profile . #mode /= Local = pure Nothing
  | otherwise = do
      (source, bytes) <- localSubstrateSpecSource active (workspace ^. #root </> "cluster/bootstrap/local-substrate.json")
      spec <- either (dieT . T.pack) pure (Aeson.eitherDecodeStrict' bytes)
      unless
        ( localSpecVersion spec == 1
            && localSpecRegistryHost spec == active ^. #profile . #registryHost
        )
        (dieT "local substrate specification differs from the selected registry profile")
      let digest = InventoryDigest.contentDigest bytes
          knownName value = either (error . T.unpack) (\name -> name) (Resource.mkName value)
          knownKey value = either (error . T.unpack) (\key -> key) (Resource.mkLogicalKey value)
      owner <- either dieT pure (Resource.mkScopeId Resource.Platform "local-substrate")
      let registryName = knownName ("k3d-" <> localSpecRegistry spec)
          clusterName = knownName (localSpecCluster spec)
          registryId = Resource.mintResourceId owner (knownKey "registry") registryName
          clusterId = Resource.mintResourceId owner (knownKey "cluster") clusterName
          resource key role name destination kind dependencies =
            ArtifactResourceSpec
              { artifactLogicalKey = knownKey key
              , artifactRole = role
              , artifactName = name
              , artifactDestination = destination
              , artifactContentDigest = digest
              , artifactSpecDigest = digest
              , artifactKind = kind
              , artifactOwnership = InventoryArtifact.OwnedArtifact
              , artifactLifecycle = ResourcePolicy.Protect
              , artifactDataPolicy = ResourcePolicy.Stateless
              , artifactSensitivity = ResourcePolicy.Public
              , artifactDependencies = dependencies
              , artifactConsumers = InventoryArtifact.ConsumerCompletenessUnknown
              , artifactPublishOperation = False
              , artifactSource = Resource.SourceLocation (T.pack source) "local-substrate-v1"
              }
          registry =
            resource
              "registry"
              registryName
              registryName
              (localSpecRegistryHost spec)
              InventoryArtifact.LocalRegistryArtifact
              []
          cluster =
            resource
              "cluster"
              clusterName
              clusterName
              (localSpecCluster spec)
              InventoryArtifact.LocalClusterArtifact
              [ResourceReference.OrderedAfter registryId]
          bundle = ArtifactDeclarationBundle 1 owner (registry NE.:| [cluster])
      scope <- either (dieT . T.pack . show) pure (InventoryArtifact.compileArtifactScope bundle)
      case Map.lookup owner (ResourceInventory.snapshotScopes snapshot) of
        Just (_, prior)
          | ResourceWire.encodeCanonicalScope prior /= ResourceWire.encodeCanonicalScope scope ->
              -- EP-172: a release transition re-accepts the substrate declared from
              -- the target payload; the cluster and registry themselves never change
              -- in place.
              if mode == ReleaseTransition && sameDeclarationsModuloSource prior scope
                then
                  Just
                    <$> either
                      (dieT . T.pack . show)
                      pure
                      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
                else dieT "accepted local substrate differs from the selected specification"
        Just _ -> do
          adapter <- inventoryArtifactAdapter active workspace (InventoryArtifact.artifactExecutionSpecs bundle)
          observed <- InventoryAdapter.adapterObserve adapter [registryId, clusterId]
          let ready = case observed of
                Left _ -> False
                Right facts ->
                  all
                    ( \resourceId -> case Map.lookup resourceId (InventoryAdapter.observationMap facts) of
                        Just (InventoryAdapter.ObservedPresent _) -> True
                        _ -> False
                    )
                    [registryId, clusterId]
          if ready
            then pure Nothing
            else
              Just
                <$> either
                  (dieT . T.pack . show)
                  pure
                  (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
        Nothing ->
          Just
            <$> either
              (dieT . T.pack . show)
              pure
              (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))

-- | The reviewed substrate specification. A context with the admin API
-- enabled (EP-198) adds @inventoryMount@, its own store directory, which the
-- cluster's server node mounts read-only at @/var/lib/nagare/inventory@; that
-- derived specification is written beside the context's store, so its digest
-- differs from the packaged one and an existing cluster without the mount is
-- refused rather than silently reused.
localSubstrateSpecSource :: ActiveTarget -> FilePath -> IO (FilePath, ByteString)
localSubstrateSpecSource active packaged = do
  original <- BS.readFile packaged
  if not (active ^. #profile . #adminApiEnabled)
    then pure (packaged, original)
    else do
      stateRoot <- nagareStateDir
      let contextDir = stateRoot </> T.unpack (contextNameText (active ^. #contextName))
          derived = contextDir </> "local-substrate.json"
      value <- either (dieT . T.pack) pure (Aeson.eitherDecodeStrict' original)
      withMount <- case value of
        Aeson.Object fields ->
          pure (Aeson.Object (KeyMap.insert "inventoryMount" (Aeson.String (T.pack (contextDir </> "inventory"))) fields))
        _ -> dieT "local substrate specification is not an object"
      encoded <- either dieT pure (ResourceWire.canonicalValue withMount)
      BS.writeFile derived encoded
      pure (derived, encoded)
