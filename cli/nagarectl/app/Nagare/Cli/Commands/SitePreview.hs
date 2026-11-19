-- | Commands / SitePreview. Executable-private CLI boundary: a site's preview
-- environments, each an isolated reviewed scope beside the production site.
module Nagare.Cli.Commands.SitePreview
  ( runPreviewDelete
  , runPreviewDeploy
  , runPreviewList
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Application.Cdn (serverSiteWithGeneratedEnvFor)
import Nagare.Cli.Application.Config
  ( siteConfigIdentity
  , siteIdentityOrDie
  )
import Nagare.Cli.Application.Inputs (validateInlinePreviewAdoption)
import Nagare.Cli.Application.Site (reviewedSiteAccessBinding, reviewedSiteTag, siteDeployInputs)
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistry
  , inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Move.Carry (withMovedRoutes)
import Nagare.Cli.Options (SiteCommonOpts, SiteDeployOpts, SitePreviewDeleteOpts)
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT, orDie)
import Nagare.Cli.Runtime.Rendered (loadSiteInput)
import Nagare.Cli.Runtime.Target
  ( activeProfile
  , activeTarget
  , resolveBaseDomain
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Types (StaticSite, siteNameText)
import Nagare.Dsl.Types (imageRefText, namespaceText, volumeNameText)
import Nagare.Image (qualifyImage)
import Nagare.Inventory.Application (ReviewedCdnBinding (..), acceptedApplicationImage, acceptedImageBuildSecrets, acceptedSecretBindings)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedAppNamespace)
import Nagare.Inventory.Lifecycle qualified as InventoryLifecycle
import Nagare.Inventory.Site (acceptedSitePreviewDependencies, compileServerSitePreviewScopeWithBuild, compileStaticSitePreviewScope, sitePreviewRetirementScope, siteVolumeRecoveryBindings)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire qualified as ResourceWire
import Nagare.Server.Deploy (ServerDeployInputs (ServerDeployInputs))
import Nagare.Static.Preview
  ( listPreviews
  , previewDomain
  , previewDomainFor
  , previewServiceName
  )
import Nagare.Target (TargetProfile)
import Nagare.Target.Kinds (hostShapeFor)

-- | @site preview deploy --name NAME@: deploy the accepted image as an isolated
-- preview Service under a derived name and domain. Previews are not recorded in
-- the production release history.
runPreviewDeploy :: Maybe String -> SiteDeployOpts -> Text -> IO ()
runPreviewDeploy mctx sopts pname = do
  when
    (isNothing (sopts ^. #imageResource))
    (dieT "reviewed site preview requires --image-resource")
  when
    ( not (null (sopts ^. #siteTlsSecretResources))
        || isJust (sopts ^. #cdnBackendResource)
        || isJust (sopts ^. #legacyReleaseImport)
        || isJust (sopts ^. #releaseAdoptionInput)
    )
    (dieT "site preview deploy does not support production inventory options")
  bd <- resolveBaseDomain mctx (sopts ^. #baseDomain)
  tp <- activeProfile mctx
  esite <- loadSiteInput (sopts ^. #rendered) (sopts ^. #ghcEnv) (sopts ^. #file)
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right (Load.SiteStatic site) -> do
      unless
        (null (sopts ^. #siteVolumeRecovery))
        (dieT "static preview has no volume recovery inputs")
      unless
        (null (sopts ^. #siteEnvSecretResources))
        (dieT "static preview has no runtime Secret references")
      runReviewedStaticPreviewPlan mctx tp sopts site bd pname (sopts ^. #savePlan)
    Right (Load.SiteServer site) ->
      runReviewedServerPreviewPlan mctx tp sopts site bd pname (sopts ^. #savePlan)

runReviewedStaticPreviewPlan ::
  Maybe String ->
  TargetProfile ->
  SiteDeployOpts ->
  StaticSite ->
  Text ->
  Text ->
  Maybe FilePath ->
  IO ()
runReviewedStaticPreviewPlan mctx tp options original bd pname output = do
  when
    (isNothing output && isJust (options ^. #sitePreviewAdoptionInput))
    (dieT "preview adoption requires --save-plan and a separate reviewed apply")
  tag <- reviewedSiteTag options
  imageId <-
    maybe
      (dieT "reviewed site preview requires --image-resource")
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #imageResource)
  qualifiedImage <- either dieT pure (qualifyImage tp (original ^. #image))
  let site = original & #image .~ qualifiedImage
      name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
      inputs = siteDeployInputs tp options site tag bd
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <- either dieT pure (acceptedAppNamespace snapshot ns)
  accessBinding <- reviewedSiteAccessBinding snapshot cluster (site ^. #access)
  either
    dieT
    pure
    ( acceptedApplicationImage
        snapshot
        imageId
        (imageRefText qualifiedImage <> ":" <> tag)
    )
  envIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #sitePreviewEnvResources)
  dependencies <-
    either
      dieT
      pure
      (acceptedSitePreviewDependencies snapshot cluster name ns envIds)
  previewName <- orDie (previewServiceName name pname)
  let source =
        Resource.SourceLocation
          (maybe (T.pack (options ^. #file)) T.pack (options ^. #source))
          ("preview/" <> previewName)
  (scope, native) <-
    either
      (dieT . T.pack . show)
      pure
      ( compileStaticSitePreviewScope
          accessBinding
          inputs
          pname
          cluster
          namespaceId
          imageId
          dependencies
          source
      )
  (carriedScope, carriedNative) <- withMovedRoutes active snapshot (scope, native)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope carriedScope NE.:| []))
  if options ^. #dryRun
    then BC.putStrLn (ResourceWire.encodeCanonicalScope scope)
    else case (options ^. #sitePreviewAdoptionInput, output) of
      (Nothing, Nothing) ->
        Inventory.convergeInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace carriedNative)
          (inventoryExecutionRegistry mctx)
          active
          candidate
      (Nothing, Just directory) ->
        Inventory.planInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace carriedNative)
          active
          candidate
          directory
      (Just proposalFile, Just directory) -> do
        proposalBytes <-
          (try (BS.readFile proposalFile) :: IO (Either IOException ByteString))
            >>= either (dieT . T.pack . show) pure
        proposal <- either dieT pure (InventoryLifecycle.decodeAdoptionInput proposalBytes)
        unless
          (InventoryLifecycle.adoptionCandidateDirectory proposal == ".")
          (dieT "inline preview adoption requires candidate '.' in its proposal")
        validateInlinePreviewAdoption scope proposal
        Inventory.planInventoryCandidateAdoptionWith
          (inventoryPlanRegistryWithNative active workspace carriedNative)
          active
          candidate
          proposal
          directory
      (Just _, Nothing) -> dieT "preview adoption requires --save-plan"

runReviewedServerPreviewPlan ::
  Maybe String ->
  TargetProfile ->
  SiteDeployOpts ->
  ServerSite ->
  Text ->
  Text ->
  Maybe FilePath ->
  IO ()
runReviewedServerPreviewPlan mctx tp options original bd pname output = do
  when
    (isNothing output && isJust (options ^. #sitePreviewAdoptionInput))
    (dieT "preview adoption requires --save-plan and a separate reviewed apply")
  tag <- reviewedSiteTag options
  imageId <-
    maybe
      (dieT "reviewed server preview requires --image-resource")
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #imageResource)
  qualifiedImage <- either dieT pure (qualifyImage tp (original ^. #image))
  let qualified = original & #image .~ qualifiedImage
      name = siteNameText (qualified ^. #name)
      ns = namespaceText (qualified ^. #namespace)
  previewName <- orDie (previewServiceName name pname)
  host <- orDie (previewDomainFor (hostShapeFor (tp ^. #ingress)) name pname bd)
  let sourceText = T.pack <$> options ^. #source
      site =
        serverSiteWithGeneratedEnvFor
          previewName
          ("https://" <> host)
          sourceText
          qualified
          bd
          tag
      inputs = ServerDeployInputs site tag bd (options ^. #projectDir) True tp
      source =
        Resource.SourceLocation
          (maybe (T.pack (options ^. #file)) T.pack (options ^. #source))
          ("preview/" <> previewName)
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <- either dieT pure (acceptedAppNamespace snapshot ns)
  accessBinding <- reviewedSiteAccessBinding snapshot cluster (site ^. #access)
  either
    dieT
    pure
    ( acceptedApplicationImage
        snapshot
        imageId
        (imageRefText qualifiedImage <> ":" <> tag)
    )
  buildSecrets <-
    either
      dieT
      pure
      (acceptedImageBuildSecrets snapshot imageId cluster name ns)
  envIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #sitePreviewEnvResources)
  stores <-
    either
      dieT
      pure
      (acceptedSitePreviewDependencies snapshot cluster name ns envIds)
  secretIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #siteEnvSecretResources)
  runtimeSecrets <- either dieT pure (acceptedSecretBindings snapshot secretIds)
  recovery <-
    either
      dieT
      pure
      ( siteVolumeRecoveryBindings
          site
          (map T.pack (options ^. #siteVolumeRecovery))
      )
  (scope, native) <-
    either
      (dieT . T.pack . show)
      pure
      ( compileServerSitePreviewScopeWithBuild
          accessBinding
          buildSecrets
          inputs
          pname
          cluster
          namespaceId
          imageId
          stores
          recovery
          runtimeSecrets
          source
      )
  (carriedScope, carriedNative) <- withMovedRoutes active snapshot (scope, native)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope carriedScope NE.:| []))
  if options ^. #dryRun
    then BC.putStrLn (ResourceWire.encodeCanonicalScope scope)
    else case (options ^. #sitePreviewAdoptionInput, output) of
      (Nothing, Nothing) ->
        Inventory.convergeInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace carriedNative)
          (inventoryExecutionRegistry mctx)
          active
          candidate
      (Nothing, Just directory) ->
        Inventory.planInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace carriedNative)
          active
          candidate
          directory
      (Just proposalFile, Just directory) -> do
        proposalBytes <-
          (try (BS.readFile proposalFile) :: IO (Either IOException ByteString))
            >>= either (dieT . T.pack . show) pure
        proposal <- either dieT pure (InventoryLifecycle.decodeAdoptionInput proposalBytes)
        unless
          (InventoryLifecycle.adoptionCandidateDirectory proposal == ".")
          (dieT "inline preview adoption requires candidate '.' in its proposal")
        validateInlinePreviewAdoption scope proposal
        Inventory.planInventoryCandidateAdoptionWith
          (inventoryPlanRegistryWithNative active workspace carriedNative)
          active
          candidate
          proposal
          directory
      (Just _, Nothing) -> dieT "preview adoption requires --save-plan"

-- | @site preview list@: list the site's preview Service names.
runPreviewList :: SiteCommonOpts -> IO ()
runPreviewList copts = do
  provisionGhcEnv (copts ^. #ghcEnv)
  (name, ns) <- siteIdentityOrDie (copts ^. #file)
  pnames <- listPreviews name ns
  if null pnames
    then TIO.putStrLn "(no previews)"
    else mapM_ TIO.putStrLn pnames

-- | @site preview delete NAME@: save retirement of the preview scope.
runPreviewDelete :: Maybe String -> SitePreviewDeleteOpts -> Text -> IO ()
runPreviewDelete mctx options pname = do
  output <-
    maybe
      (dieT "site preview delete requires --save-plan for reviewed retirement")
      pure
      (options ^. #savePlan)
  let copts = options ^. #common
  bd <- resolveBaseDomain mctx (copts ^. #baseDomain)
  provisionGhcEnv (copts ^. #ghcEnv)
  esite <- Load.loadSite (copts ^. #file)
  site <- either (dieT . Load.renderLoadError) pure esite
  let (prodName, ns) = siteConfigIdentity site
      volumeNames = case site of
        Load.SiteStatic _ -> []
        Load.SiteServer server ->
          map
            (volumeNameText . (^. #name))
            (server ^. #volumes)
  svcName <- orDie (previewServiceName prodName pname)
  pdomText <- orDie (previewDomain prodName pname bd)
  active <- activeTarget mctx
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, _) <- either dieT pure (acceptedAppNamespace snapshot ns)
  owner <-
    either
      dieT
      pure
      (sitePreviewRetirementScope snapshot cluster svcName ns pdomText volumeNames)
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  Inventory.planInventoryRetirementWith
    (inventoryPlanRegistry active workspace)
    active
    owner
    output
