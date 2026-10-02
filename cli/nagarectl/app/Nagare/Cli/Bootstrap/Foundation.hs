-- | Bootstrap / Foundation. Executable-private CLI boundary.
module Nagare.Cli.Bootstrap.Foundation
  ( buildCloudFoundationCandidate
  , cloudFoundationPending
  , cloudFoundationPendingAt
  , foundationStageTarget
  )
where

import Control.Monad (forM)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Cli.Inventory.Foundation
  ( foundationBucketNames
  , foundationImageLink
  , foundationPulumiBucket
  , foundationStackAddress
  , foundationStackTarget
  )
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Pulumi
  ( ensurePulumiInWorkspaceWithDependencies
  , pulumiQuiet
  )
import Nagare.Cli.Runtime.Target (resolvePlatformWorkspace)
import Nagare.Dsl.Prelude
import Nagare.Init (requiredApis)
import Nagare.Inventory.Adapters.Foundation
  ( FoundationAdapterOps (foundationInspect)
  , FoundationObservation (FoundationPresent)
  , FoundationTarget
    ( FoundationBucket
    , FoundationService
    , FoundationStack
    )
  , foundationTargetDigest
  )
import Nagare.Inventory.Adapters.FoundationRuntime
  ( mkFoundationRuntimeOps
  , realGcloudRunner
  )
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Foundation qualified as InventoryFoundation
import Nagare.Platform.Paths (PlatformPaths)
import Nagare.Platform.StackConfig (linkContextStackConfig)
import Nagare.Platform.Workspace
  ( PlatformWorkspace
  , readPayloadManifest
  , renderWorkspaceError
  )
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy qualified as ResourcePolicy
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Target
  ( ActiveTarget
  , InventoryStoreKind (InventoryStoreGcs, InventoryStoreLocal)
  , Mode (Cloud)
  , contextNameText
  , effectiveInventoryStore
  )
import System.Exit (ExitCode (ExitSuccess))

foundationStageTarget :: ActiveTarget -> IO ActiveTarget
foundationStageTarget active =
  Inventory.selectFoundationStore active
    >>= either (dieT . T.pack . show) pure

cloudFoundationPending :: ActiveTarget -> IO Bool
cloudFoundationPending active = foundationStageTarget active >>= cloudFoundationPendingAt active

cloudFoundationPendingAt :: ActiveTarget -> ActiveTarget -> IO Bool
cloudFoundationPendingAt active selected
  | active ^. #profile . #mode /= Cloud = pure False
  | otherwise = do
      snapshot <- Inventory.loadTargetSnapshot selected
      ready <- foundationScopeReady active snapshot
      if ready
        && effectiveInventoryStore (active ^. #profile) == InventoryStoreGcs
        && effectiveInventoryStore (selected ^. #profile) == InventoryStoreLocal
        then do
          Inventory.migrateTargetStore selected InventoryStoreGcs False
            >>= either (dieT . T.pack . show) (const (pure ()))
          pure False
        else pure (not ready)

foundationScopeReady :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> IO Bool
foundationScopeReady active snapshot = case Map.lookup owner (ResourceInventory.snapshotScopes snapshot) of
  Nothing -> pure False
  Just (_, scope) -> do
    (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
    let profile = active ^. #profile
        declarations = concatMap (^. #declarations) (ResourceInventory.scopeBundles scope)
    project <- either dieT pure (Resource.mkName (profile ^. #project))
    location <- either dieT pure (Resource.mkName (profile ^. #region))
    backendBucket <- foundationPulumiBucket active
    imageLink <-
      foundationImageLink
        active
        ( concatMap
            (concatMap ResourceInventory.declarations . ResourceInventory.scopeBundles . snd)
            (Map.elems (ResourceInventory.snapshotScopes snapshot))
        )
    stackTarget <- foundationStackTarget active workspace imageLink
    let stackName = case stackTarget of
          FoundationStack _ name _ _ _ _ _ -> name
          _ -> error "foundationStackTarget did not return a stack"
        stackId =
          Resource.mintResourceId
            owner
            (either (error . T.unpack) (\key -> key) (Resource.mkLogicalKey "pulumi-stack"))
            stackName
    expectedBuckets <- foundationBucketNames active
    case InventoryFoundation.foundationTargetsFromDeclarations
      project
      location
      backendBucket
      (profile ^. #pulumiBackendMember)
      (Just (foundationStackAddress project stackName, stackTarget))
      declarations of
      Left _ -> pure False
      Right targets -> do
        let declaredServices =
              Set.fromList
                [ Resource.nameText service
                | FoundationService _ service <- Map.elems targets
                ]
            declared =
              maybe
                False
                ((== foundationTargetDigest stackTarget) . foundationTargetDigest)
                (Map.lookup stackId targets)
                && Set.fromList
                  [ Resource.nameText bucket
                  | FoundationBucket _ bucket _ _ <- Map.elems targets
                  ]
                  == expectedBuckets
                && declaredServices `Set.isSubsetOf` Set.fromList requiredApis
        if not declared
          then pure False
          else do
            -- A newly materialized payload workspace has no stack config link yet.
            -- Observe the accepted stack through its context-owned config.
            configPath <-
              linkContextStackConfig (active ^. #contextName) (workspace ^. #pulumiDir)
                >>= either dieT pure
            configBytes <- BS.readFile configPath
            -- Pulumi's config command reads workstation YAML. Recover only an
            -- empty context-owned file from the already accepted backend stack;
            -- preserve every nonempty operator configuration for drift checks.
            when (BS.null configBytes) $ do
              ensurePulumiInWorkspaceWithDependencies
                False
                False
                False
                (active ^. #contextName)
                profile
                workspace
              refreshed <-
                pulumiQuiet
                  [ "-C"
                  , workspace ^. #pulumiDir
                  , "config"
                  , "refresh"
                  , "--stack"
                  , T.unpack (Resource.nameText stackName)
                  , "--force"
                  ]
              unless
                (refreshed == ExitSuccess)
                (dieT "accepted Pulumi stack configuration is unavailable; cannot recover the empty local config")
            let runtime = mkFoundationRuntimeOps realGcloudRunner
            observations <-
              traverse
                ( \target ->
                    (,) target <$> foundationInspect runtime target
                )
                (Map.elems targets)
            requiredServices <- forM requiredApis $ \api -> do
              service <- either dieT pure (Resource.mkName api)
              let target = FoundationService project service
              (,) target <$> foundationInspect runtime target
            pure
              ( all
                  ( \(target, state) -> case state of
                      FoundationPresent _ digest -> digest == foundationTargetDigest target
                      _ -> False
                  )
                  observations
                  && all
                    ( \(target, state) -> case state of
                        FoundationPresent _ digest -> digest == foundationTargetDigest target
                        _ -> False
                    )
                    requiredServices
              )
  where
    owner =
      either
        (error . T.unpack)
        (\scope -> scope)
        (Resource.mkScopeId Resource.Platform "cloud-foundation")

buildCloudFoundationCandidate ::
  ActiveTarget ->
  PlatformPaths ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO ResourceInventory.CompositionCandidate
buildCloudFoundationCandidate active paths workspace snapshot = do
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  unless
    ( manifest ^. #payloadId == workspace ^. #payloadId
        && manifest ^. #platformVersion == workspace ^. #platformVersion
        && active ^. #profile . #platformVersion == Just (manifest ^. #platformVersion)
    )
    (dieT "cloud foundation requires the selected immutable payload and matching context pin")
  let profile = active ^. #profile
  either dieT pure (InventoryFoundation.validateFoundationMember (profile ^. #pulumiBackendMember))
  project <- either dieT pure (Resource.mkName (profile ^. #project))
  location <- either dieT pure (Resource.mkName (profile ^. #region))
  owner <- either dieT pure (Resource.mkScopeId Resource.Platform "cloud-foundation")
  let accepted =
        Set.fromList
          [ resource ^. #identity
          | Just (_, scope) <- [Map.lookup owner (ResourceInventory.snapshotScopes snapshot)]
          , ResourceInventory.Managed resource <-
              concatMap (^. #declarations) (ResourceInventory.scopeBundles scope)
          ]
      runtime = mkFoundationRuntimeOps realGcloudRunner
  serviceResources <- fmap catMaybes $ forM requiredApis $ \api -> do
    service <- either dieT pure (Resource.mkName api)
    key <- either dieT pure (Resource.mkLogicalKey api)
    let target = FoundationService project service
        resourceId = Resource.mintResourceId owner key service
    observed <- foundationInspect runtime target
    let alreadyEnabled = case observed of
          FoundationPresent _ digest -> digest == foundationTargetDigest target
          _ -> False
    pure $
      if alreadyEnabled && not (Set.member resourceId accepted)
        then Nothing
        else
          Just
            ( InventoryFoundation.FoundationResource
                key
                service
                (Resource.CloudService project service)
                (foundationTargetDigest target)
                ResourcePolicy.Retain
                ResourcePolicy.Stateless
                ResourcePolicy.Public
                []
                (Resource.SourceLocation "context-profile" ("required-api:" <> api))
            )
  let storageApi =
        Resource.mintResourceId
          owner
          (either (error . T.unpack) (\key -> key) (Resource.mkLogicalKey "storage.googleapis.com"))
          (either (error . T.unpack) (\name -> name) (Resource.mkName "storage.googleapis.com"))
      managesStorageApi =
        any
          ( (== storageApi)
              . ( \resource ->
                    Resource.mintResourceId
                      owner
                      (InventoryFoundation.foundationLogicalKey resource)
                      (InventoryFoundation.foundationRole resource)
                )
          )
          serviceResources
  backendBucket <- foundationPulumiBucket active
  imageLink <-
    foundationImageLink
      active
      ( concatMap
          (concatMap ResourceInventory.declarations . ResourceInventory.scopeBundles . snd)
          (Map.elems (ResourceInventory.snapshotScopes snapshot))
      )
  stackTarget <- foundationStackTarget active workspace imageLink
  bucketNames <- foundationBucketNames active
  buckets <- forM (Set.toAscList bucketNames) $ \bucketText -> do
    bucket <- either dieT pure (Resource.mkName bucketText)
    key <- either dieT pure (Resource.mkLogicalKey ("state-" <> bucketText))
    let member = if Just bucket == backendBucket then profile ^. #pulumiBackendMember else Nothing
        target = FoundationBucket project bucket location member
    pure
      ( InventoryFoundation.FoundationResource
          key
          bucket
          (Resource.GlobalBucket bucket)
          (foundationTargetDigest target)
          ResourcePolicy.Protect
          ResourcePolicy.Stateless
          ResourcePolicy.Public
          [ResourceReference.OrderedAfter storageApi | managesStorageApi]
          (Resource.SourceLocation "context-profile" ("state-bucket:" <> bucketText))
      )
  stackName <- either dieT pure (Resource.mkName (contextNameText (active ^. #contextName)))
  let stackDependencies = case backendBucket of
        Nothing -> [ResourceReference.OrderedAfter storageApi | managesStorageApi]
        Just bucket ->
          [ ResourceReference.OrderedAfter
              ( Resource.mintResourceId
                  owner
                  ( either
                      (error . T.unpack)
                      (\key -> key)
                      ( Resource.mkLogicalKey
                          ("state-" <> Resource.nameText bucket)
                      )
                  )
                  bucket
              )
          ]
      stackResource =
        InventoryFoundation.FoundationResource
          (either (error . T.unpack) (\key -> key) (Resource.mkLogicalKey "pulumi-stack"))
          stackName
          (foundationStackAddress project stackName)
          (foundationTargetDigest stackTarget)
          ResourcePolicy.Protect
          ResourcePolicy.Stateless
          ResourcePolicy.Public
          stackDependencies
          (Resource.SourceLocation "context-profile" "pulumi-stack")
  resources <- case serviceResources <> buckets <> [stackResource] of
    firstResource : rest -> pure (firstResource NE.:| rest)
    [] -> dieT "cloud foundation has no required resources"
  scope <-
    either
      (dieT . T.pack . show)
      pure
      ( InventoryFoundation.compileFoundationScope
          (InventoryFoundation.FoundationDeclarationBundle 1 owner project resources)
      )
  either
    (dieT . T.pack . show)
    pure
    (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
