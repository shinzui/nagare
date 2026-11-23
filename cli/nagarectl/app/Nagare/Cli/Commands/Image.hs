-- | Commands / Image. Executable-private CLI boundary.
module Nagare.Cli.Commands.Image
  ( runAppImagePlan
  )
where

import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Options (AppImageInput (..), AppImagePlanOpts)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Contract.Project (imagePublicationResult)
import Nagare.Contract.Sink (contractSinkSet, emitDocument, transactionExitCode)
import Nagare.Dsl.Prelude
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
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Components.ControllerImage
  ( inspectArchive
  )
import Nagare.Inventory.Environment
  ( acceptedBuildChannelMember
  , acceptedEnvChannelValues
  , acceptedSecretChannelValues
  )
import Nagare.Inventory.ImageBuild (buildDockerArchive)
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy qualified as ResourcePolicy
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget, imageDestinationAllowed, parseImageDigestReference)
import System.Directory (makeAbsolute)
import System.Exit (ExitCode (ExitSuccess), exitWith)

-- ---------------------------------------------------------------------------
-- app lifecycle handlers (EP-30)

data ReviewedImageInput = ReviewedImageInput
  { destination :: !Text
  , digest :: !Resource.ContentDigest
  , specDigest :: !Resource.ContentDigest
  , kind :: !InventoryArtifact.ArtifactKind
  , source :: !Resource.SourceLocation
  , inputs :: ![Resource.ResourceId]
  , overrides :: !(Map.Map Text Text)
  }

-- | An archive review binds the file and manifest digests. A registry
-- reference review records the observed manifest and authorizes inventory
-- acceptance without a registry publication operation.
runAppImagePlan :: Maybe String -> AppImagePlanOpts -> IO ()
runAppImagePlan mctx options = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  logical <- either dieT pure (Resource.mkLogicalKey (T.pack (options ^. #key)))
  owner <- either dieT pure (Resource.mkScopeId Resource.Publication ("app-image-" <> Resource.logicalKeyText logical))
  role <- either dieT pure (Resource.mkName "oci-image")
  artifactName <- either dieT pure (Resource.mkName (Resource.logicalKeyText logical))
  (snapshot, image) <-
    case options ^. #input of
      ArchiveImage archive tagged -> do
        snapshot <- Inventory.loadTargetSnapshot active
        image <- inspectAppArchive active snapshot options archive (T.pack tagged)
        pure (snapshot, image)
      RegistryImage reference -> do
        when (isNothing (options ^. #savePlan)) (dieT "a registry reference requires --save-plan")
        unless
          (null (options ^. #buildInputResources) && isNothing (options ^. #buildDockerfile) && isNothing (options ^. #buildContext))
          (dieT "a registry reference cannot declare local build options or Build inputs")
        let destination = T.pack reference
        (repository, digest) <- either dieT pure (parseImageDigestReference destination)
        unless
          (imageDestinationAllowed (active ^. #profile) (repository <> ":verify"))
          (dieT "image repository is outside the active context registry")
        snapshot <- Inventory.loadTargetSnapshotReadOnly active
        let image = ReviewedImageInput destination digest digest InventoryArtifact.OciImageReferenceArtifact (Resource.SourceLocation destination "oci-reference-v1") [] Map.empty
        pure (snapshot, image)
  let imageId = Resource.mintResourceId owner logical role
      resource =
        ArtifactResourceSpec
          { artifactLogicalKey = logical
          , artifactRole = role
          , artifactName = artifactName
          , artifactDestination = destination image
          , artifactContentDigest = digest image
          , artifactSpecDigest = specDigest image
          , artifactKind = kind image
          , artifactOwnership = InventoryArtifact.OwnedArtifact
          , artifactLifecycle = ResourcePolicy.Retain
          , artifactDataPolicy = ResourcePolicy.Stateless
          , artifactSensitivity = ResourcePolicy.Private
          , artifactDependencies = map ResourceReference.OrderedAfter (inputs image)
          , artifactConsumers = InventoryArtifact.ConsumerCompletenessUnknown
          , artifactPublishOperation = kind image == InventoryArtifact.OciImageArtifact
          , artifactSource = source image
          }
  compiled <-
    either
      (dieT . T.pack . show)
      pure
      (InventoryArtifact.compileArtifactScope (ArtifactDeclarationBundle 1 owner (resource NE.:| [])))
  let scope = ResourceInventory.withScopeOverrides (overrides image) compiled
  case Map.lookup owner (ResourceInventory.snapshotScopes snapshot) of
    Just (_, prior)
      | prior /= scope ->
          dieT "image publication key already has different accepted content or Build inputs; choose a new key"
    _ -> pure ()
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  let planning = inventoryPlanRegistryWithNative active workspace Map.empty
  contract <- contractSinkSet
  case options ^. #savePlan of
    Nothing
      | contract -> do
          (digest, result) <- Inventory.convergeInventoryCandidateResult planning (inventoryExecutionRegistry mctx) active candidate
          emitDocument (imagePublicationResult imageId digest Nothing (Just result))
          when (transactionExitCode result /= ExitSuccess) (exitWith (transactionExitCode result))
      | otherwise -> Inventory.convergeInventoryCandidateWith planning (inventoryExecutionRegistry mctx) active candidate
    Just directory
      | contract -> do
          (_, digest) <- Inventory.planInventoryCandidateQuiet planning active candidate directory
          saved <- makeAbsolute directory
          emitDocument (imagePublicationResult imageId digest (Just saved) Nothing)
      | otherwise -> Inventory.planInventoryCandidateWith planning active candidate directory
  unless contract (TIO.putStrLn ("Image resource: " <> Resource.resourceIdText imageId))

inspectAppArchive ::
  ActiveTarget ->
  ResourceInventory.ScopeSnapshot ->
  AppImagePlanOpts ->
  FilePath ->
  Text ->
  IO ReviewedImageInput
inspectAppArchive active snapshot options archive destination = do
  let profile = active ^. #profile
  unless
    (imageDestinationAllowed profile destination)
    (dieT "image destination must be a tagged image in the active context registry, or a cloud deployer's project")
  archivePath <- makeAbsolute archive
  when
    ( isJust (options ^. #buildDockerfile)
        /= isJust (options ^. #buildContext)
    )
    (dieT "local image build requires both --build-dockerfile and --build-context")
  inputIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #buildInputResources)
  unless
    (length inputIds == Set.size (Set.fromList inputIds))
    (dieT "image Build input resource IDs must be distinct")
  inputMembers <- traverse (either dieT pure . acceptedBuildChannelMember snapshot) inputIds
  unless
    (Set.size (Set.fromList [app | (app, _, _) <- inputMembers]) <= 1)
    (dieT "image Build inputs must belong to one application")
  (inputRevisions, inputNative) <-
    if null inputMembers
      then pure ([], Map.empty)
      else do
        store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
        history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
        acceptedInventory <-
          either
            (dieT . T.pack . show)
            pure
            (ResourceInventory.composeSnapshot snapshot)
        (native, _) <-
          InventoryStatus.loadAcceptedNative store history acceptedInventory
            >>= either dieT pure
        revisions <- forM inputMembers $ \(_, inputScope, member) -> case Map.lookup
          (ResourceInventory.scopeId inputScope)
          (InventoryPlan.historyAccepted history) of
          Just (revision, accepted)
            | accepted == inputScope ->
                pure (member ^. #identity, InventoryStore.revisionDigest revision)
          _ -> dieT "image Build input differs from accepted scope history"
        pure (revisions, native)
  let inputAddresses =
        [ (boundCluster, namespaceName)
        | (_, _, member) <- inputMembers
        , Resource.Kubernetes boundCluster "" _ (Just namespaceName) _ <- [member ^. #address]
        ]
  unless
    ( length inputAddresses == length inputMembers
        && Set.size (Set.fromList inputAddresses) <= 1
    )
    (dieT "image Build inputs must be in one cluster and namespace")
  case (options ^. #buildDockerfile, options ^. #buildContext) of
    (Just dockerfile, Just context) -> do
      channelValues <- forM inputMembers $ \(_, inputScope, member) ->
        case member ^. #address of
          Resource.Kubernetes _ "" kind _ _
            | Resource.nameText kind == "configmap" -> do
                values <-
                  either
                    dieT
                    pure
                    (acceptedEnvChannelValues snapshot inputNative inputScope)
                pure (values, Map.empty)
            | Resource.nameText kind == "secret" -> do
                values <-
                  either
                    dieT
                    pure
                    (acceptedSecretChannelValues snapshot inputNative inputScope)
                when
                  (Map.null values)
                  (dieT "accepted Build Secret channel has no keys to mount")
                pure (Map.empty, values)
          _ -> dieT "image Build input has an unexpected native kind"
      let buildArgs = Map.unions (map fst channelValues)
          buildSecrets = Map.unions (map snd channelValues)
      unless
        ( Map.size buildArgs == sum (map (Map.size . fst) channelValues)
            && Map.size buildSecrets == sum (map (Map.size . snd) channelValues)
        )
        (dieT "accepted Build channels contain duplicate keys")
      dockerfilePath <- makeAbsolute dockerfile
      contextPath <- makeAbsolute context
      either dieT pure
        =<< buildDockerArchive
          (profile ^. #targetPlatform)
          destination
          dockerfilePath
          contextPath
          archivePath
          buildArgs
          buildSecrets
    (Nothing, Nothing) -> pure ()
    _ -> dieT "local image build options are incomplete"
  (archiveDigest, manifestDigest) <- inspectArchive archivePath >>= either dieT pure
  let overrides =
        Map.fromList
          ( [ ("build-input." <> Resource.resourceIdText inputId, Resource.digestText revision)
            | (inputId, revision) <- inputRevisions
            ]
              <> [("build-method", "dockerfile-buildkit-v1") | isJust (options ^. #buildDockerfile)]
          )
  pure (ReviewedImageInput destination manifestDigest archiveDigest InventoryArtifact.OciImageArtifact (Resource.SourceLocation (T.pack archivePath) "oci-archive-v1") inputIds overrides)
