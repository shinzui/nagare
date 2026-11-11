-- | Inventory / Foundation. Executable-private CLI boundary.
module Nagare.Cli.Inventory.Foundation
  ( foundationBucketNames
  , foundationDeployerKeys
  , foundationImageLink
  , foundationPulumiBucket
  , foundationStackAddress
  , foundationStackTarget
  , inventoryFoundationAdapter
  )
where

import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Prelude
import Nagare.Init (seedKeys)
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Adapters.Foundation
  ( FoundationTarget (FoundationBucket, FoundationStack)
  , mkFoundationAdapter
  )
import Nagare.Inventory.Adapters.FoundationRuntime
  ( mkFoundationRuntimeOps
  , realGcloudRunner
  )
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DeployerCloudAccess (cloudDelegatedDeployers, delegatedDeployerConfigKeys)
import Nagare.Inventory.Foundation qualified as InventoryFoundation
import Nagare.Ops.PulumiBackend
  ( gcsBucketOfUrl
  , pulumiStateBackendUrl
  )
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target
  ( ActiveTarget
  , InventoryStoreKind (InventoryStoreGcs)
  , PulumiBackendKind (PulumiBackendGcs)
  , contextNameText
  , defaultGcsInventoryStoreUrl
  , effectiveInventoryStore
  , effectivePulumiBackend
  , nagareStateDir
  , pulumiEnvFor
  )

inventoryFoundationAdapter ::
  ActiveTarget ->
  PlatformWorkspace ->
  Resource.ContextBinding ->
  [ResourceInventory.Declaration] ->
  [ResourceInventory.ScopeDeclaration] ->
  Set.Set Resource.ResourceId ->
  IO InventoryAdapter.Adapter
inventoryFoundationAdapter active workspace binding declarations scopes selectedResources
  | Set.null selectedResources =
      pure
        (Inventory.executionBlockedAdapterFor ResourceInventory.CloudFoundationExecutor)
  | otherwise = do
      either
        dieT
        pure
        ( InventoryFoundation.validateFoundationMember
            (active ^. #profile . #pulumiBackendMember)
        )
      project <- either dieT pure (Resource.mkName (active ^. #profile . #project))
      location <- either dieT pure (Resource.mkName (active ^. #profile . #region))
      unless
        (project == binding ^. #project)
        (dieT "reviewed cloud foundation belongs to another target project")
      backendBucket <- foundationPulumiBucket active
      imageLink <- foundationImageLink active declarations
      stackTarget <- foundationStackTarget active workspace imageLink scopes
      let stackName = case stackTarget of
            FoundationStack _ name _ _ _ _ _ -> name
            _ -> error "foundationStackTarget did not return a stack"
      targets <-
        either
          dieT
          pure
          ( InventoryFoundation.foundationTargetsFromDeclarations
              project
              location
              backendBucket
              (active ^. #profile . #pulumiBackendMember)
              (Just (foundationStackAddress project stackName, stackTarget))
              declarations
          )
      expectedBuckets <- foundationBucketNames active
      let reviewedBuckets =
            Set.fromList
              [Resource.nameText bucket | FoundationBucket _ bucket _ _ <- Map.elems targets]
      unless
        (reviewedBuckets == expectedBuckets)
        (dieT "reviewed cloud foundation buckets differ from the selected backend and inventory URLs")
      unless
        (selectedResources `Set.isSubsetOf` Map.keysSet targets)
        (dieT "reviewed cloud foundation lacks an exact execution target")
      pure
        ( mkFoundationAdapter
            (Map.restrictKeys targets selectedResources)
            (mkFoundationRuntimeOps realGcloudRunner)
        )

foundationPulumiBucket :: ActiveTarget -> IO (Maybe Resource.Name)
foundationPulumiBucket active
  | effectivePulumiBackend profile /= PulumiBackendGcs = pure Nothing
  | otherwise = do
      let url = pulumiStateBackendUrl (contextNameText (active ^. #contextName)) profile
      bucket <-
        maybe
          (dieT ("selected Pulumi backend has invalid GCS URL: " <> url))
          pure
          (gcsBucketOfUrl url)
      Just <$> either dieT pure (Resource.mkName bucket)
  where
    profile = active ^. #profile

foundationStackAddress :: Resource.Name -> Resource.Name -> Resource.ProviderAddress
foundationStackAddress = Resource.CloudStack

-- | The stack's config: the profile's keys, the accepted host image and the
-- delegated deployers' cloud principals, both derived from the composition.
foundationStackTarget :: ActiveTarget -> PlatformWorkspace -> Maybe Text -> [ResourceInventory.ScopeDeclaration] -> IO FoundationTarget
foundationStackTarget active workspace imageLink scopes = do
  let profile = active ^. #profile
      context = contextNameText (active ^. #contextName)
  stateRoot <- nagareStateDir
  project <- either dieT pure (Resource.mkName (profile ^. #project))
  stack <- either dieT pure (Resource.mkName context)
  bucket <- foundationPulumiBucket active
  deployerKeys <- foundationDeployerKeys active scopes
  let environment = pulumiEnvFor stateRoot context profile
      seeded = seedKeys profile
  pure
    ( FoundationStack
        project
        stack
        (environment ^. #backendUrl)
        (workspace ^. #pulumiDir)
        (environment ^. #home)
        bucket
        ( seeded
            <> maybe [] (\link -> [("nagare:nagareImageSelfLink", link)]) imageLink
            <> filter ((`notElem` map fst seeded) . fst) deployerKeys
        )
    )

-- | EP-248 D6: @nagare:delegatedDeployers@ from the composition's accepted,
-- active delegations, never from the context file.
foundationDeployerKeys :: ActiveTarget -> [ResourceInventory.ScopeDeclaration] -> IO [(Text, Text)]
foundationDeployerKeys active scopes =
  either
    dieT
    pure
    (delegatedDeployerConfigKeys (contextNameText (active ^. #contextName)) (active ^. #profile) (cloudDelegatedDeployers scopes))

foundationImageLink :: ActiveTarget -> [ResourceInventory.Declaration] -> IO (Maybe Text)
foundationImageLink active declarations = do
  owner <- either dieT pure (Resource.mkScopeId Resource.Platform "host-image")
  let project = active ^. #profile . #project
      prefix = "projects/" <> project <> "/global/images/"
      images =
        [ (resource ^. #address, resource ^. #spec)
        | ResourceInventory.Managed resource <- declarations
        , resource ^. #owner == owner
        ]
  case images of
    [] -> pure Nothing
    [(Resource.Artifact name _, ResourceInventory.ArtifactPublication kind destination _ _)]
      | Resource.nameText kind == "gce-image"
      , destination == prefix <> Resource.nameText name ->
          pure (Just ("https://www.googleapis.com/compute/v1/" <> destination))
    _ -> dieT "accepted host image has no unique GCE destination for Pulumi config"

foundationBucketNames :: ActiveTarget -> IO (Set.Set Text)
foundationBucketNames active = do
  let profile = active ^. #profile
      urls =
        [ pulumiStateBackendUrl (contextNameText (active ^. #contextName)) profile
        | effectivePulumiBackend profile == PulumiBackendGcs
        ]
          <> [ if T.null (profile ^. #inventoryStoreUrl)
                 then defaultGcsInventoryStoreUrl (contextNameText (active ^. #contextName)) profile
                 else profile ^. #inventoryStoreUrl
             | effectiveInventoryStore profile == InventoryStoreGcs
             ]
  Set.fromList
    <$> forM
      urls
      ( \url ->
          maybe
            (dieT ("selected cloud foundation has invalid GCS URL: " <> url))
            pure
            (gcsBucketOfUrl url)
      )
