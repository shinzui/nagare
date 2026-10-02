-- | Bootstrap / Host. Executable-private CLI boundary.
module Nagare.Cli.Bootstrap.Host
  ( buildHostStageCandidate
  , buildHostTransitionCandidate
  , buildKubeconfigStageCandidate
  , buildKubeconfigStageCandidateWithRecovery
  )
where

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.List (delete)
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cli.Bootstrap.Local (LocalSubstrateSpec (..))
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cluster.Kubeconfig
  ( KubeconfigIdentity (..)
  , defaultFetchOps
  , fetchKubeconfig
  , kubeconfigPath
  , normalizeLocalKubeconfig
  )
import Nagare.Dsl.Prelude
import Nagare.Host.AgeKey qualified as HostAgeKey
import Nagare.Host.Config (hostConfigDir, readContextHostName)
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
import Nagare.Inventory.Host qualified as InventoryHost
import Nagare.Inventory.RegistryCredentials qualified as RegistryCredentials
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy qualified as ResourcePolicy
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire qualified as ResourceWire
import Nagare.Target
  ( ActiveTarget
  , Mode (Cloud, Local)
  , contextNameText
  , nagareStateDir
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , pathIsSymbolicLink
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withTempDirectory)
import System.Posix.Files (createLink, setFileMode)
import System.Process (readProcessWithExitCode)

buildHostStageCandidate ::
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO (Maybe ResourceInventory.CompositionCandidate)
buildHostStageCandidate = buildHostCandidate False

-- | An explicit host review can replace the accepted same-payload inputs.
-- Bootstrap retains its strict unchanged-host prerequisite behavior.
buildHostTransitionCandidate ::
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO (Maybe ResourceInventory.CompositionCandidate)
buildHostTransitionCandidate = buildHostCandidate True

buildHostCandidate ::
  Bool ->
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO (Maybe ResourceInventory.CompositionCandidate)
buildHostCandidate transition active _ snapshot
  | active ^. #profile . #mode /= Cloud = pure Nothing
  | otherwise = do
      hostRoot <- hostConfigDir (active ^. #contextName)
      hostName <- readContextHostName (active ^. #contextName) >>= either dieT pure
      flake <- BS.readFile (hostRoot </> "flake.nix")
      hostModule <- BS.readFile (hostRoot </> "host.nix")
      registryCredentials <-
        either
          dieT
          pure
          ( RegistryCredentials.registryCredentialModuleEnabled
              RegistryCredentials.registryClusterIdentity
              hostModule
          )
      lock <- BS.readFile (hostRoot </> "flake.lock")
      owner <- either dieT pure (Resource.mkScopeId Resource.Platform "host")
      key <- either dieT pure (Resource.mkLogicalKey "nixos-system")
      role <- either dieT pure (Resource.mkName "system")
      let configurationDigest = InventoryDigest.contentDigest (flake <> hostModule)
          lockDigest = InventoryDigest.contentDigest lock
          acceptedScope = snd <$> Map.lookup owner (ResourceInventory.snapshotScopes snapshot)
          systemId = Resource.mintResourceId owner key role
      when transition $ for_ acceptedScope $ \prior -> do
        inputs <- either dieT pure (InventoryHost.hostExecutionInputsFromScopes [prior])
        unless (maybe False (lockDigest `elem`) inputs) $
          dieT "host plan cannot change the accepted flake.lock; in-place payload upgrades are unsupported"
      ageKeyPath <- lookupEnv "NAGARE_HOST_AGE_KEY_FILE"
      ageKeyDigest <- case ageKeyPath of
        Just keyPath -> do
          inspected <- HostAgeKey.inspectLocalAgeKey keyPath >>= either dieT pure
          Just <$> either dieT pure (Resource.mkContentDigest (HostAgeKey.sha256 inspected))
        Nothing -> case acceptedScope of
          Nothing -> pure Nothing
          Just prior -> do
            inputs <- either dieT pure (InventoryHost.hostExecutionInputsFromScopes [prior])
            case inputs of
              Just reviewed
                | length reviewed `elem` [2, 3]
                    && (configurationDigest `elem` reviewed && lockDigest `elem` reviewed) ->
                    case delete lockDigest (delete configurationDigest reviewed) of
                      [] -> pure Nothing
                      [digest] -> pure (Just digest)
                      _ -> dieT "accepted host has invalid credential input binding"
              Just reviewed | transition && length reviewed == 2 -> pure Nothing
              _ -> dieT "accepted host configuration differs from the selected context; use a reviewed host transition with the accepted age-key file when credentials are bound"
      let specDigest =
            InventoryDigest.contentDigest
              ( TE.encodeUtf8
                  ( Resource.digestText configurationDigest
                      <> ":"
                      <> Resource.digestText lockDigest
                      <> maybe "" ((":" <>) . Resource.digestText) ageKeyDigest
                  )
              )
      provider <- either dieT pure (Resource.mkName hostName)
      cloudOwner <- either dieT pure (Resource.mkScopeId Resource.Platform "cloud")
      vmKey <- either dieT pure (Resource.mkLogicalKey "nagare-instance-vm")
      vmName <- either dieT pure (Resource.mkName (active ^. #profile . #instanceName))
      let vmId = Resource.mintResourceId cloudOwner vmKey vmName
          source =
            fromMaybe
              (Resource.SourceLocation "nixos/host.nix" "nixos-system")
              ( acceptedScope >>= \prior ->
                  listToMaybe
                    [ member ^. #source
                    | bundle <- ResourceInventory.scopeBundles prior
                    , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                    , member ^. #identity == systemId
                    ]
              )
          resource =
            InventoryHost.HostResourceSpec
              { InventoryHost.hostLogicalKey = key
              , InventoryHost.hostRole = role
              , InventoryHost.hostProviderName = provider
              , InventoryHost.hostSpecDigest = specDigest
              , InventoryHost.hostLifecycle = ResourcePolicy.Protect
              , InventoryHost.hostDataPolicy = ResourcePolicy.Stateless
              , InventoryHost.hostSensitivity = ResourcePolicy.Private
              , InventoryHost.hostDependencies = [ResourceReference.OrderedAfter vmId]
              , InventoryHost.hostSource = source
              }
      let declaration =
            InventoryHost.HostDeclarationBundle
              1
              owner
              vmId
              (resource NE.:| [])
              configurationDigest
              lockDigest
              ageKeyDigest
      scope <-
        either
          (dieT . T.pack . show)
          pure
          ( if registryCredentials
              then
                InventoryHost.compileHostScopeWithRegistryCredentials
                  declaration
                  RegistryCredentials.registryClusterIdentity
              else InventoryHost.compileHostScope declaration
          )
      case Map.lookup owner (ResourceInventory.snapshotScopes snapshot) of
        Just (_, prior)
          | not transition && ResourceWire.encodeCanonicalScope prior /= ResourceWire.encodeCanonicalScope scope ->
              dieT "accepted host configuration differs from the selected context; use a reviewed host transition"
        Just _ | not transition -> pure Nothing
        _ ->
          Just
            <$> either
              (dieT . T.pack . show)
              pure
              (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))

buildKubeconfigStageCandidate ::
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO (Maybe ResourceInventory.CompositionCandidate)
buildKubeconfigStageCandidate = buildKubeconfigStageCandidateWithRecovery False

buildKubeconfigStageCandidateWithRecovery ::
  Bool ->
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO (Maybe ResourceInventory.CompositionCandidate)
buildKubeconfigStageCandidateWithRecovery recover active workspace snapshot = do
  let context = active ^. #contextName
      contextText = contextNameText context
  destination <- kubeconfigPath context
  stateRoot <- nagareStateDir
  let preparedDir = stateRoot </> T.unpack contextText </> "prepared-kubeconfig"
  createDirectoryIfMissing True preparedDir
  setFileMode preparedDir 0o700
  (bytes, producer) <- case active ^. #profile . #mode of
    Cloud -> do
      hostName <- readContextHostName context >>= either dieT pure
      fetched <- withTempDirectory preparedDir "candidate-" $ \temporary -> do
        let path = temporary </> "kubeconfig.yaml"
            identity = KubeconfigIdentity contextText hostName
            ops = defaultFetchOps (workspace ^. #scriptsDir </> "iap-ssh.sh")
        fetchKubeconfig ops identity (active ^. #profile) path >>= either dieT pure
        BS.readFile path
      hostOwner <- either dieT pure (Resource.mkScopeId Resource.Platform "host")
      hostKey <- either dieT pure (Resource.mkLogicalKey "nixos-system")
      hostRole <- either dieT pure (Resource.mkName "system")
      pure (fetched, Resource.mintResourceId hostOwner hostKey hostRole)
    Local -> do
      specBytes <- BS.readFile (workspace ^. #root </> "cluster/bootstrap/local-substrate.json")
      spec <- either (dieT . T.pack) pure (Aeson.eitherDecodeStrict' specBytes)
      (code, output, err) <-
        readProcessWithExitCode
          "k3d"
          ["kubeconfig", "get", T.unpack (localSpecCluster spec)]
          ""
      unless
        (code == ExitSuccess)
        (dieT ("could not read reviewed local cluster kubeconfig: " <> T.pack err))
      normalized <- either dieT pure (normalizeLocalKubeconfig contextText (BC.pack output))
      clusterOwner <- either dieT pure (Resource.mkScopeId Resource.Platform "local-substrate")
      clusterKey <- either dieT pure (Resource.mkLogicalKey "cluster")
      clusterRole <- either dieT pure (Resource.mkName (localSpecCluster spec))
      pure (normalized, Resource.mintResourceId clusterOwner clusterKey clusterRole)
  let digest = InventoryDigest.contentDigest bytes
      prepared = preparedDir </> T.unpack (Resource.digestText digest) <> ".yaml"
  linked <-
    try (pathIsSymbolicLink prepared) >>= \case
      Left (err :: IOException) | isDoesNotExistError err -> pure False
      Left (err :: IOException) -> dieT ("could not inspect prepared kubeconfig: " <> T.pack (show err))
      Right value -> pure value
  when linked (dieT "prepared kubeconfig path is a symlink")
  exists <- doesFileExist prepared
  if exists
    then do
      retained <- BS.readFile prepared
      unless (retained == bytes) (dieT "prepared kubeconfig digest path contains different bytes")
    else BS.writeFile prepared bytes
  setFileMode prepared 0o600
  owner <- either dieT pure (Resource.mkScopeId Resource.Platform "kubeconfig")
  key <- either dieT pure (Resource.mkLogicalKey "context-kubeconfig")
  role <- either dieT pure (Resource.mkName contextText)
  let artifact =
        ArtifactResourceSpec
          { artifactLogicalKey = key
          , artifactRole = role
          , artifactName = role
          , artifactDestination = T.pack destination
          , artifactContentDigest = digest
          , artifactSpecDigest = digest
          , artifactKind = InventoryArtifact.KubeconfigArtifact
          , artifactOwnership = InventoryArtifact.OwnedArtifact
          , artifactLifecycle = ResourcePolicy.Protect
          , artifactDataPolicy = ResourcePolicy.Stateless
          , artifactSensitivity = ResourcePolicy.Secret
          , artifactDependencies = [ResourceReference.OrderedAfter producer]
          , artifactConsumers = InventoryArtifact.ConsumerCompletenessUnknown
          , artifactPublishOperation = False
          , artifactSource = Resource.SourceLocation (T.pack prepared) "kubeconfig-prepared-v1"
          }
  scope <-
    either
      (dieT . T.pack . show)
      pure
      ( InventoryArtifact.compileArtifactScope
          (ArtifactDeclarationBundle 1 owner (artifact NE.:| []))
      )
  case Map.lookup owner (ResourceInventory.snapshotScopes snapshot) of
    Just (_, prior)
      | not (InventoryArtifact.sameKubeconfigProjection prior scope) ->
          dieT "accepted kubeconfig differs from the selected host; use a reviewed credential transition"
    _ -> pure ()
  destinationLinked <-
    try (pathIsSymbolicLink destination) >>= \case
      Left (err :: IOException) | isDoesNotExistError err -> pure False
      Left (err :: IOException) -> dieT ("could not inspect context kubeconfig: " <> T.pack (show err))
      Right value -> pure value
  when destinationLinked (dieT "context kubeconfig destination is a symlink")
  destinationExists <- doesFileExist destination
  current <- if destinationExists then Just <$> BS.readFile destination else pure Nothing
  let accepted = Map.member owner (ResourceInventory.snapshotScopes snapshot)
  case (accepted, current) of
    (True, Just currentBytes) | InventoryDigest.contentDigest currentBytes == digest -> pure Nothing
    (True, Just _) -> dieT "accepted context kubeconfig has a different content digest"
    (True, Nothing) | recover -> do
      createDirectoryIfMissing True (takeDirectory destination)
      setFileMode (takeDirectory destination) 0o700
      withTempDirectory (takeDirectory destination) "recover-" $ \temporary -> do
        let staged = temporary </> "kubeconfig.yaml"
        BS.writeFile staged bytes
        setFileMode staged 0o600
        createLink staged destination
      pure Nothing
    (True, Nothing) -> dieT "accepted kubeconfig is absent in this context root; run nagarectl kubeconfig recover"
    _ | recover -> dieT "kubeconfig recovery requires an accepted credential scope"
    _ ->
      Just
        <$> either
          (dieT . T.pack . show)
          pure
          (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
