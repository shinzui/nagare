-- | Bootstrap / Cloud. Executable-private CLI boundary.
module Nagare.Cli.Bootstrap.Cloud
  ( buildCloudStageCandidate
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cli.Inventory.CloudCatalog (loadCloudCatalog)
import Nagare.Cli.Inventory.Foundation (foundationImageLink)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Prelude
import Nagare.Init (seedKeys)
import Nagare.Inventory.Adapters.PulumiRuntime
  ( decodePhysicalResources
  )
import Nagare.Inventory.Cloud qualified as InventoryCloud
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Inventory.VmPower (retainVmPowerIntents)
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy qualified as ResourcePolicy
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget, Mode (Cloud), contextNameText)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.Process (readProcessWithExitCode)

-- Admit one dependency layer per review. Every member of an admitted layer
-- has its own journal operation; later registrations remain explicit native
-- bookkeeping until their prerequisites have receipts.
buildCloudStageCandidate ::
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO (Maybe ResourceInventory.CompositionCandidate)
buildCloudStageCandidate active workspace snapshot
  | active ^. #profile . #mode /= Cloud = pure Nothing
  | otherwise = do
      (catalogBytes, rawCatalog) <- loadCloudCatalog workspace
      let profile = active ^. #profile
          catalog =
            InventoryCloud.withCloudInstanceName
              (either (error . T.unpack) (\name -> name) (Resource.mkName (profile ^. #instanceName)))
              rawCatalog
      imageLink <-
        foundationImageLink
          active
          ( concatMap
              (concatMap ResourceInventory.declarations . ResourceInventory.scopeBundles . snd)
              (Map.elems (ResourceInventory.snapshotScopes snapshot))
          )
      let owner =
            either
              (error . T.unpack)
              (\scope -> scope)
              (Resource.mkScopeId Resource.Platform "cloud")
          entries =
            InventoryCloud.selectedCloudCatalog
              (profile ^. #nixCacheEnabled)
              (isJust imageLink)
              (profile ^. #cdnEnabled)
              catalog
          acceptedMembers = case Map.lookup owner (ResourceInventory.snapshotScopes snapshot) of
            Nothing -> []
            Just (_, scope) ->
              [ member
              | bundle <- ResourceInventory.scopeBundles scope
              , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
              ]
          acceptedUrns =
            Set.fromList
              [ urn
              | member <- acceptedMembers
              , Resource.PulumiUrn urn <- [member ^. #address]
              ]
      stack <-
        either
          dieT
          pure
          ( Resource.mkName
              (contextNameText (active ^. #contextName))
          )
      project <- either dieT pure (Resource.mkName (profile ^. #project))
      context <-
        either
          dieT
          pure
          ( Resource.mkContextId
              (contextNameText (active ^. #contextName))
          )
      catalogUrns <-
        either
          dieT
          pure
          (traverse (InventoryCloud.cloudCatalogUrn stack catalog) entries)
      let expectedUrns = Set.fromList catalogUrns
      unless
        ( Set.isSubsetOf acceptedUrns expectedUrns
            && length acceptedMembers == Set.size acceptedUrns
        )
        (dieT "accepted cloud scope differs from the selected Pulumi resource catalog")
      exported <-
        try
          ( readProcessWithExitCode
              "pulumi"
              [ "-C"
              , workspace ^. #pulumiDir
              , "stack"
              , "export"
              , "--stack"
              , T.unpack (Resource.nameText stack)
              , "--show-secrets=false"
              ]
              ""
          )
          >>= \case
            Left (err :: IOException) ->
              dieT
                ("could not inspect reviewed cloud stack: " <> T.pack (show err))
            Right (ExitFailure code, _, err) ->
              dieT
                ("reviewed cloud stack export failed (exit " <> T.pack (show code) <> "): " <> T.pack err)
            Right (ExitSuccess, out, _) -> pure out
      physical <-
        either
          dieT
          pure
          (decodePhysicalResources (TE.encodeUtf8 (T.pack exported)))
      let missing =
            [ urn
            | urn <- catalogUrns
            , not (Set.member urn acceptedUrns && Map.member urn physical)
            ]
      case missing of
        [] -> pure Nothing
        _ -> do
          let admitted = entries
              resourceId entry =
                Resource.mintResourceId
                  owner
                  ( either
                      (error . T.unpack)
                      (\key -> key)
                      (Resource.mkLogicalKey (Resource.nameText (InventoryCloud.catalogKey entry)))
                  )
                  (InventoryCloud.catalogNativeName entry)
              stackOwner =
                either
                  (error . T.unpack)
                  (\scope -> scope)
                  (Resource.mkScopeId Resource.Platform "cloud-foundation")
              stackId =
                Resource.mintResourceId
                  stackOwner
                  (either (error . T.unpack) (\key -> key) (Resource.mkLogicalKey "pulumi-stack"))
                  stack
              intentDigest entry =
                InventoryDigest.contentDigest
                  ( catalogBytes
                      <> TE.encodeUtf8
                        ( T.pack
                            ( show
                                ( seedKeys profile
                                    <> [ ("nagare:nagareImageSelfLink", link)
                                       | entry `elem` InventoryCloud.catalogImageEnabled catalog
                                       , link <- maybe [] pure imageLink
                                       ]
                                )
                            )
                        )
                  )
          resources <- forM admitted $ \entry -> do
            urn <- either dieT pure (InventoryCloud.cloudCatalogUrn stack catalog entry)
            key <-
              either
                dieT
                pure
                ( Resource.mkLogicalKey
                    (Resource.nameText (InventoryCloud.catalogKey entry))
                )
            let predecessors =
                  [ resourceId prior
                  | prior <- admitted
                  , InventoryCloud.catalogLayer prior < InventoryCloud.catalogLayer entry
                  ]
                dependencies =
                  map
                    ResourceReference.OrderedAfter
                    (if null predecessors then [stackId] else predecessors)
            pure
              ( InventoryCloud.CloudResource
                  key
                  (InventoryCloud.catalogNativeName entry)
                  (InventoryCloud.PulumiAddress urn)
                  []
                  (intentDigest entry)
                  ResourcePolicy.Protect
                  ResourcePolicy.Stateless
                  ResourcePolicy.Public
                  dependencies
                  ( Resource.SourceLocation
                      "infra/pulumi/resource-catalog.json"
                      (Resource.nameText (InventoryCloud.catalogNativeName entry))
                  )
                  (InventoryCloud.catalogNativeType entry)
                  (InventoryCloud.catalogNativeName entry)
                  urn
                  InventoryCloud.ManagedRegistration
              )
          compiled <-
            either
              (dieT . T.pack . show)
              pure
              ( InventoryCloud.compileCloudScope
                  (InventoryCloud.CloudDeclarationBundle 1 context project stack owner resources)
              )
          scope <- case Map.lookup owner (ResourceInventory.snapshotScopes snapshot) of
            Nothing -> pure compiled
            Just (_, prior) -> either dieT pure (retainVmPowerIntents prior compiled)
          Just
            <$> either
              (dieT . T.pack . show)
              pure
              ( ResourceInventory.composeInventory
                  snapshot
                  (ResourceInventory.ReplaceScope scope NE.:| [])
              )
