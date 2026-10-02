-- | Commands / Site. Executable-private CLI boundary.
module Nagare.Cli.Commands.Site
  ( runPreviewDelete
  , runPreviewDeploy
  , runPreviewList
  , runSiteDeploy
  , runSiteReleases
  , runSiteRollback
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Nagare.Cli.Application.Cdn
  ( reviewedCdnBinding
  , serverSiteWithGeneratedEnvFor
  )
import Nagare.Cli.Application.Config
  ( siteConfigIdentity
  , siteIdentityOrDie
  )
import Nagare.Cli.Application.Inputs
  ( validateInlinePreviewAdoption
  , validateInlineReleaseAdoption
  )
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistry
  , inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Options
  ( SiteCommonOpts
  , SiteDeployOpts
  , SitePreviewDeleteOpts
  , SiteRollbackOpts
  )
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT, orDie)
import Nagare.Cli.Runtime.Target
  ( activeProfile
  , activeTarget
  , resolveBaseDomain
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Cdn.Types (Cdn)
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Types (StaticSite, siteNameText)
import Nagare.Dsl.Types
  ( SecretName
  , imageRefText
  , namespaceText
  , volumeNameText
  )
import Nagare.Image (qualifyImage)
import Nagare.Inventory.Application
  ( ReviewedCdnBinding (..)
  , acceptedApplicationImage
  , acceptedImageBuildSecrets
  , acceptedSecretBindings
  )
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Lifecycle qualified as InventoryLifecycle
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Site
  ( acceptedSitePreviewDependencies
  , acceptedSiteReleaseLog
  , acceptedSiteSource
  , compileServerSitePreviewScopeWithBuild
  , compileServerSiteRollbackScopeWithBuild
  , compileServerSiteScopeWithBuild
  , compileStaticSitePreviewScope
  , compileStaticSiteRollbackScope
  , compileStaticSiteRollbackScopeWithCdn
  , compileStaticSiteRollbackScopeWithCloudflare
  , compileStaticSiteScope
  , compileStaticSiteScopeWithCdn
  , compileStaticSiteScopeWithCloudflare
  , legacyServerSiteReleaseImport
  , legacyStaticSiteReleaseImport
  , sitePreviewRetirementScope
  , siteVolumeRecoveryBindings
  )
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire qualified as ResourceWire
import Nagare.Server.Deploy
  ( ServerDeployInputs
      ( ServerDeployInputs
      , baseDomain
      , imageTag
      , projectDir
      , site
      , skipBuild
      , targetProfile
      )
  , serverManifests
  , serverUrl
  )
import Nagare.Static.Deploy
  ( DeployInputs (..)
  , productionManifests
  )
import Nagare.Static.Preview
  ( listPreviews
  , previewDomain
  , previewServiceName
  )
import Nagare.Static.Release
  ( StaticRelease (..)
  , StaticReleaseLog
  , findRelease
  , formatReleasesTable
  , readReleaseLog
  )
import Nagare.Target (TargetProfile)

-- | Deploy a site (EP-14/EP-15/EP-18). Dispatches on the config's @kind@: a
-- @StaticSite@ runs the Nginx path, a @ServerSite@ runs the Node path. Both share
-- the same CLI options and record a release on success.
runSiteDeploy :: Maybe String -> SiteDeployOpts -> IO ()
runSiteDeploy mctx sopts = do
  when
    (isNothing (sopts ^. #imageResource))
    (dieT "reviewed site deployment requires --image-resource")
  bd <- resolveBaseDomain mctx (sopts ^. #baseDomain)
  provisionGhcEnv (sopts ^. #ghcEnv)
  tp <- activeProfile mctx
  esite <- Load.loadSite (sopts ^. #file)
  -- EP-62 M3: qualify a name-only image with the resolved registry prefix; a
  -- fully-qualified ref is left untouched. Inlined per kind because the static
  -- and server site records are distinct types.
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right (Load.SiteStatic s) -> do
      case qualifyImage tp (s ^. #image) of
        Left e -> dieT ("nagarectl deploy: " <> e)
        Right qimg ->
          runStaticSiteDeployPlan
            mctx
            tp
            sopts
            (s & #image %~ const qimg)
            bd
            (sopts ^. #savePlan)
    Right (Load.SiteServer s) -> do
      case qualifyImage tp (s ^. #image) of
        Left e -> dieT ("nagarectl deploy: " <> e)
        Right qimg ->
          runServerSiteDeployPlan
            mctx
            tp
            sopts
            (s & #image %~ const qimg)
            bd
            (sopts ^. #savePlan)

runStaticSiteDeployPlan ::
  Maybe String -> TargetProfile -> SiteDeployOpts -> StaticSite -> Text -> Maybe FilePath -> IO ()
runStaticSiteDeployPlan mctx tp options site bd output = do
  unless
    (null (options ^. #siteVolumeRecovery))
    (dieT "static sites have no volume recovery inputs")
  unless
    (null (options ^. #siteEnvSecretResources))
    (dieT "static sites have no runtime Secret references")
  tag <- reviewedSiteTag options
  let inputs = siteDeployInputs tp options site tag bd
      rendered = productionManifests inputs
  runReviewedSiteDeployPlan
    mctx
    options
    (siteNameText (site ^. #name))
    (namespaceText (site ^. #namespace))
    (imageRefText (site ^. #image))
    (rendered ^. #url)
    tag
    (site ^. #cdn)
    False
    ( \cdn _ _ tls cluster namespaceId imageId ->
        case cdn of
          Nothing -> compileStaticSiteScope inputs cluster namespaceId imageId tls
          Just (GoogleCdnBindingFor binding) -> compileStaticSiteScopeWithCdn binding inputs cluster namespaceId imageId tls
          Just (CloudflareCdnBindingFor binding) -> compileStaticSiteScopeWithCloudflare binding inputs cluster namespaceId imageId tls
    )
    (legacyStaticSiteReleaseImport site)
    output

runServerSiteDeployPlan ::
  Maybe String -> TargetProfile -> SiteDeployOpts -> ServerSite -> Text -> Maybe FilePath -> IO ()
runServerSiteDeployPlan mctx tp options original bd output = do
  tag <- reviewedSiteTag options
  recovery <-
    either
      dieT
      pure
      ( siteVolumeRecoveryBindings
          original
          (map T.pack (options ^. #siteVolumeRecovery))
      )
  let site =
        serverSiteWithGeneratedEnvSource
          (T.pack <$> options ^. #source)
          original
          bd
          tag
      inputs =
        ServerDeployInputs
          { site = site
          , imageTag = tag
          , baseDomain = bd
          , projectDir = options ^. #projectDir
          , skipBuild = True
          , targetProfile = tp
          }
      rendered = serverManifests inputs
  runReviewedSiteDeployPlan
    mctx
    options
    (siteNameText (site ^. #name))
    (namespaceText (site ^. #namespace))
    (imageRefText (site ^. #image))
    (rendered ^. #url)
    tag
    (site ^. #cdn)
    True
    ( \cdn buildSecrets bindings tls cluster namespaceId imageId ->
        compileServerSiteScopeWithBuild
          buildSecrets
          cdn
          inputs
          cluster
          namespaceId
          imageId
          recovery
          bindings
          tls
    )
    (legacyServerSiteReleaseImport site)
    output

reviewedSiteTag :: SiteDeployOpts -> IO Text
reviewedSiteTag options = do
  unless
    (options ^. #skipBuild)
    (dieT "reviewed site deployment requires --skip-build")
  when
    (options ^. #dryRun && isJust (options ^. #savePlan))
    (dieT "reviewed site deployment cannot combine --dry-run with --save-plan")
  maybe
    (dieT "reviewed site deployment requires --tag")
    (pure . T.pack)
    (options ^. #tag)

runReviewedSiteDeployPlan ::
  Maybe String ->
  SiteDeployOpts ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe Cdn ->
  Bool ->
  ( Maybe ReviewedCdnBinding ->
    Set SecretName ->
    Map.Map SecretName ResourceInventory.Declaration ->
    Map.Map SecretName ResourceInventory.Declaration ->
    Resource.ResourceId ->
    Resource.ResourceId ->
    Resource.ResourceId ->
    StaticReleaseLog ->
    StaticRelease ->
    Resource.SourceLocation ->
    Either
      (NE.NonEmpty Resource.InventoryError)
      ( ResourceInventory.ScopeDeclaration
      , Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString)
      )
  ) ->
  (Text -> ByteString -> Either Text (StaticReleaseLog, StaticRelease)) ->
  Maybe FilePath ->
  IO ()
runReviewedSiteDeployPlan mctx options siteName ns imageName url tag cdnIntent bindBuildInputs compile importLegacy output = do
  unless
    (null (options ^. #sitePreviewEnvResources))
    (dieT "production site review has no preview environment resources")
  when
    (isJust (options ^. #sitePreviewAdoptionInput))
    (dieT "production site review has no preview adoption input")
  case (options ^. #legacyReleaseImport, options ^. #releaseAdoptionInput) of
    (Nothing, Nothing) -> pure ()
    (Just _, Just _) -> pure ()
    _ -> dieT "site import requires both --legacy-release-import and --release-adoption-input"
  when
    (isNothing output && isJust (options ^. #legacyReleaseImport))
    (dieT "site adoption requires --save-plan and a separate reviewed apply")
  imageId <-
    maybe
      (dieT "reviewed site deployment requires --image-resource")
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #imageResource)
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  cdnBinding <-
    reviewedCdnBinding
      active
      workspace
      snapshot
      cdnIntent
      (options ^. #cdnBackendResource)
  secretIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #siteEnvSecretResources)
  envSecrets <- either dieT pure (acceptedSecretBindings snapshot secretIds)
  tlsIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #siteTlsSecretResources)
  tlsSecrets <- either dieT pure (acceptedSecretBindings snapshot tlsIds)
  let source =
        Resource.SourceLocation
          (maybe (T.pack (options ^. #file)) T.pack (options ^. #source))
          siteName
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
  either
    dieT
    pure
    ( acceptedApplicationImage
        snapshot
        imageId
        (imageName <> ":" <> tag)
    )
  buildSecrets <-
    if bindBuildInputs
      then either dieT pure (acceptedImageBuildSecrets snapshot imageId cluster siteName ns)
      else pure Set.empty
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
  (prior, release, adoption) <- case (options ^. #legacyReleaseImport, options ^. #releaseAdoptionInput) of
    (Nothing, Nothing) -> do
      accepted <-
        either
          dieT
          pure
          (acceptedSiteReleaseLog snapshot acceptedNative siteName ns cluster)
      releasedAt <- getCurrentTime
      pure
        ( accepted
        , StaticRelease
            { releaseId = tag
            , siteName = siteName
            , namespace = ns
            , image = imageName
            , imageTag = tag
            , url = url
            , source = T.pack <$> options ^. #source
            , createdAt = releasedAt
            }
        , Nothing
        )
    (Just legacyFile, Just proposalFile) -> do
      legacyBytes <-
        (try (BS.readFile legacyFile) :: IO (Either IOException ByteString))
          >>= either (dieT . T.pack . show) pure
      (oldLog, oldRelease) <-
        either
          dieT
          pure
          (importLegacy tag legacyBytes)
      proposalBytes <-
        (try (BS.readFile proposalFile) :: IO (Either IOException ByteString))
          >>= either (dieT . T.pack . show) pure
      proposal <- either dieT pure (InventoryLifecycle.decodeAdoptionInput proposalBytes)
      unless
        (InventoryLifecycle.adoptionCandidateDirectory proposal == ".")
        (dieT "inline site import requires candidate '.' in its adoption proposal")
      pure (oldLog, oldRelease, Just proposal)
    _ -> dieT "site import options are incomplete"
  (scope, native) <-
    either
      (dieT . T.pack . show)
      pure
      (compile cdnBinding buildSecrets envSecrets tlsSecrets cluster namespaceId imageId prior release source)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  if options ^. #dryRun
    then BC.putStrLn (ResourceWire.encodeCanonicalScope scope)
    else case (adoption, output) of
      (Nothing, Nothing) ->
        Inventory.convergeInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace native)
          (inventoryExecutionRegistry mctx)
          active
          candidate
      (Nothing, Just directory) ->
        Inventory.planInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace native)
          active
          candidate
          directory
      (Just proposal, Just directory) -> do
        validateInlineReleaseAdoption scope ("nagare-static-releases-" <> siteName) proposal
        Inventory.planInventoryCandidateAdoptionWith
          (inventoryPlanRegistryWithNative active workspace native)
          active
          candidate
          proposal
          directory
      (Just _, Nothing) -> dieT "site adoption requires --save-plan"

serverSiteWithGeneratedEnvSource :: Maybe Text -> ServerSite -> Text -> Text -> ServerSite
serverSiteWithGeneratedEnvSource source site bd tag =
  serverSiteWithGeneratedEnvFor
    (siteNameText (site ^. #name))
    (serverUrl site bd)
    source
    site
    bd
    tag

-- | @site releases@: print the recorded release history. Kind-agnostic — works
-- for both static and server sites (the release record is runtime-agnostic).
runSiteReleases :: SiteCommonOpts -> IO ()
runSiteReleases copts = do
  provisionGhcEnv (copts ^. #ghcEnv)
  (name, ns) <- siteIdentityOrDie (copts ^. #file)
  elog <- readReleaseLog name ns
  case elog of
    Left err -> dieT err
    Right logv -> TIO.putStr (formatReleasesTable logv)

-- | @site rollback RELEASE_ID@: select a prior release. Reviewed rollback
-- rebinds the site scope and its release-history pointer to an accepted image.
runSiteRollback :: Maybe String -> SiteRollbackOpts -> Text -> IO ()
runSiteRollback mctx options rid = do
  output <-
    maybe
      (dieT "site rollback requires --save-plan for a reviewed rollback")
      pure
      (options ^. #savePlan)
  let copts = options ^. #common
  bd <- resolveBaseDomain mctx (copts ^. #baseDomain)
  tp <- activeProfile mctx
  provisionGhcEnv (copts ^. #ghcEnv)
  esite <- Load.loadSite (copts ^. #file)
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right sc -> runReviewedSiteRollbackPlan mctx tp options sc bd rid output

runReviewedSiteRollbackPlan ::
  Maybe String ->
  TargetProfile ->
  SiteRollbackOpts ->
  Load.SiteConfig ->
  Text ->
  Text ->
  FilePath ->
  IO ()
runReviewedSiteRollbackPlan mctx tp options config bd rid output = do
  let (name, ns) = siteConfigIdentity config
  imageId <-
    maybe
      (dieT "reviewed site rollback requires --image-resource")
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #imageResource)
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  let cdnIntent = case config of
        Load.SiteStatic site -> site ^. #cdn
        Load.SiteServer site -> site ^. #cdn
  cdnBinding <-
    reviewedCdnBinding
      active
      workspace
      snapshot
      cdnIntent
      (options ^. #cdnBackendResource)
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
  prior <-
    either
      dieT
      pure
      (acceptedSiteReleaseLog snapshot acceptedNative name ns cluster)
  source <- either dieT pure (acceptedSiteSource snapshot name ns cluster)
  release <- maybe (dieT ("no accepted site release: " <> rid)) pure (findRelease rid prior)
  either
    dieT
    pure
    ( acceptedApplicationImage
        snapshot
        imageId
        (release ^. #image <> ":" <> release ^. #imageTag)
    )
  envIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #siteEnvSecretResources)
  envSecrets <- either dieT pure (acceptedSecretBindings snapshot envIds)
  tlsIds <-
    traverse
      (either dieT pure . Resource.mkResourceId . T.pack)
      (options ^. #siteTlsSecretResources)
  tlsSecrets <- either dieT pure (acceptedSecretBindings snapshot tlsIds)
  (scope, native) <- case config of
    Load.SiteStatic original -> do
      unless
        ( null (options ^. #siteVolumeRecovery)
            && null (options ^. #siteEnvSecretResources)
        )
        (dieT "static-site rollback has no volume or runtime Secret inputs")
      qualifiedImage <- either dieT pure (qualifyImage tp (original ^. #image))
      let qualified = original & #image .~ qualifiedImage
          inputs = DeployInputs qualified (release ^. #imageTag) bd "." True tp
      either (dieT . T.pack . show) pure $ case cdnBinding of
        Nothing ->
          compileStaticSiteRollbackScope
            inputs
            cluster
            namespaceId
            imageId
            tlsSecrets
            prior
            release
            source
        Just (GoogleCdnBindingFor binding) ->
          compileStaticSiteRollbackScopeWithCdn
            binding
            inputs
            cluster
            namespaceId
            imageId
            tlsSecrets
            prior
            release
            source
        Just (CloudflareCdnBindingFor binding) ->
          compileStaticSiteRollbackScopeWithCloudflare
            binding
            inputs
            cluster
            namespaceId
            imageId
            tlsSecrets
            prior
            release
            source
    Load.SiteServer original -> do
      buildSecrets <-
        either
          dieT
          pure
          (acceptedImageBuildSecrets snapshot imageId cluster name ns)
      qualifiedImage <- either dieT pure (qualifyImage tp (original ^. #image))
      let qualified = original & #image .~ qualifiedImage
      recovery <-
        either
          dieT
          pure
          ( siteVolumeRecoveryBindings
              qualified
              (map T.pack (options ^. #siteVolumeRecovery))
          )
      let site =
            serverSiteWithGeneratedEnvSource
              (release ^. #source)
              qualified
              bd
              (release ^. #imageTag)
          inputs = ServerDeployInputs site (release ^. #imageTag) bd "." True tp
      either
        (dieT . T.pack . show)
        pure
        ( compileServerSiteRollbackScopeWithBuild
            buildSecrets
            cdnBinding
            inputs
            cluster
            namespaceId
            imageId
            recovery
            envSecrets
            tlsSecrets
            prior
            release
            source
        )
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  Inventory.planInventoryCandidateWith
    (inventoryPlanRegistryWithNative active workspace native)
    active
    candidate
    output

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
  provisionGhcEnv (sopts ^. #ghcEnv)
  esite <- Load.loadSite (sopts ^. #file)
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
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
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
          inputs
          pname
          cluster
          namespaceId
          imageId
          dependencies
          source
      )
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  if options ^. #dryRun
    then BC.putStrLn (ResourceWire.encodeCanonicalScope scope)
    else case (options ^. #sitePreviewAdoptionInput, output) of
      (Nothing, Nothing) ->
        Inventory.convergeInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace native)
          (inventoryExecutionRegistry mctx)
          active
          candidate
      (Nothing, Just directory) ->
        Inventory.planInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace native)
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
          (inventoryPlanRegistryWithNative active workspace native)
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
  host <- orDie (previewDomain name pname bd)
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
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
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
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  if options ^. #dryRun
    then BC.putStrLn (ResourceWire.encodeCanonicalScope scope)
    else case (options ^. #sitePreviewAdoptionInput, output) of
      (Nothing, Nothing) ->
        Inventory.convergeInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace native)
          (inventoryExecutionRegistry mctx)
          active
          candidate
      (Nothing, Just directory) ->
        Inventory.planInventoryCandidateWith
          (inventoryPlanRegistryWithNative active workspace native)
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
          (inventoryPlanRegistryWithNative active workspace native)
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
  (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
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

-- ---------------------------------------------------------------------------
-- Shared helpers

-- | Assemble the runtime-agnostic 'DeployInputs' from the @site deploy@ options.
siteDeployInputs :: TargetProfile -> SiteDeployOpts -> StaticSite -> Text -> Text -> DeployInputs
siteDeployInputs tp sopts site imageTag bd =
  DeployInputs
    { site = site
    , imageTag = imageTag
    , baseDomain = bd
    , projectDir = sopts ^. #projectDir
    , skipBuild = sopts ^. #skipBuild
    , targetProfile = tp
    }
