-- | Inventory / Foundation. Executable-private CLI boundary.
module Nagare.Cli.Inventory.Foundation
  ( foundationBucketNames
  , foundationDeployerKeys
  , foundationBucketKeys
  , foundationImageLink
  , foundationPulumiBucket
  , foundationStackAddress
  , foundationStackTarget
  , inventoryFoundationAdapter
  )
where

import Control.Monad (forM)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Posture (ActivePosture (..), activePosture)
import Nagare.Dsl.Prelude
import Nagare.Init (seedKeysFor)
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Adapters.Foundation
  ( FoundationTarget (FoundationBucket, FoundationStack)
  , mkFoundationAdapter
  )
import Nagare.Inventory.Adapters.FoundationRuntime
  ( mkFoundationRuntimeOps
  , realGcloudRunner
  )
import Nagare.Inventory.BucketCloudAccess (appBucketConfigKeys, cloudAppBuckets)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DeployerCloudAccess (cloudDelegatedDeployers, delegatedDeployerConfigKeys)
import Nagare.Inventory.Foundation qualified as InventoryFoundation
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), invokeKubectl)
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
import System.Exit (ExitCode (..))

inventoryFoundationAdapter ::
  InventoryFoundation.FoundationTargetUse ->
  ActiveTarget ->
  PlatformWorkspace ->
  Resource.ContextBinding ->
  [ResourceInventory.Declaration] ->
  [ResourceInventory.ScopeDeclaration] ->
  Set.Set Resource.ResourceId ->
  IO InventoryAdapter.Adapter
inventoryFoundationAdapter use active workspace binding declarations scopes selectedResources
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
              use
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
  bucketKeys <- foundationBucketKeys active scopes
  -- The posture reads the head the foundation uses: a fresh context's history is local until its first stage makes the bucket.
  selected <- Inventory.selectFoundationStore active >>= either (dieT . T.pack . show) pure
  ActivePosture {posture = ingressPosture, retainedDnsName = retained} <- activePosture selected
  let environment = pulumiEnvFor stateRoot context profile
      seeded = seedKeysFor profile ingressPosture retained
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
            <> filter ((`notElem` map fst seeded) . fst) bucketKeys
        )
    )

-- | EP-248 D6: @nagare:delegatedDeployers@ from the composition's accepted,
-- active delegations, never from the context file.
foundationDeployerKeys :: ActiveTarget -> [ResourceInventory.ScopeDeclaration] -> IO [(Text, Text)]
foundationDeployerKeys active scopes =
  either
    dieT
    pure
    (delegatedDeployerConfigKeys (contextNameText (active ^. #contextName)) (active ^. #profile) (cloudDelegatedDeployers (active ^. #profile) scopes))

-- | EP-284: @nagare:appBuckets@ and @nagare:workloadIdentity@ from the accepted
-- bucket scopes, and the cluster's service-account issuer and JWKS, read through
-- the context's guarded kubectl only when a bucket exists.
foundationBucketKeys :: ActiveTarget -> [ResourceInventory.ScopeDeclaration] -> IO [(Text, Text)]
foundationBucketKeys active scopes = case cloudAppBuckets scopes of
  [] -> pure []
  buckets -> do
    context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
    let clusterGuard = fmap (fmap (const ())) (guardKubernetesContext active)
        runtime = KubernetesRuntimeConfig context (contextNameText (active ^. #contextName)) clusterGuard
        raw path = do
          result <- invokeKubectl runtime ["get", "--raw", path] ""
          case result of
            Right (ExitSuccess, body, _) -> either (\reason -> dieT ("the cluster's " <> T.pack path <> " is not JSON: " <> T.pack reason)) pure (Aeson.eitherDecodeStrict (TE.encodeUtf8 (T.pack body)))
            _ -> dieT ("could not read the cluster's " <> T.pack path <> "; an app bucket's identities need it")
    clusterGuard >>= either dieT pure
    discovery <- raw "/.well-known/openid-configuration"
    issuer <- case discovery of
      Aeson.Object root | Just (Aeson.String found) <- AesonKeyMap.lookup "issuer" root -> pure found
      _ -> dieT "the cluster's OpenID configuration names no issuer"
    jwks <- raw "/openid/v1/jwks"
    either dieT pure (appBucketConfigKeys (active ^. #profile . #project) (contextNameText (active ^. #contextName)) (Just (issuer, jwks)) buckets)

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
