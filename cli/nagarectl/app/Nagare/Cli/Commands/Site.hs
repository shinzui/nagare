-- | Commands / Site. Executable-private CLI boundary.
module Nagare.Cli.Commands.Site
  ( deployLoadedStaticSite
  , runSiteDeploy
  , runSiteReleases
  , runSiteRollback
  , staticSiteUrl
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
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
import Nagare.Cli.Application.Inputs (validateInlineReleaseAdoption)
import Nagare.Cli.Application.Site (reviewedSiteAccessBinding, reviewedSiteTag, siteDeployInputs)
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Move.Carry (withMovedRoutes)
import Nagare.Cli.Options (SiteCommonOpts, SiteDeployOpts, SiteRollbackOpts)
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Rendered (loadSiteInput)
import Nagare.Cli.Runtime.Target
  ( activeProfile
  , activeTarget
  , resolveBaseDomain
  , resolvePlatformWorkspace
  )
import Nagare.Contract.Project (deployPreview)
import Nagare.Contract.Sink (emitDocument)
import Nagare.Dsl.Access (AccessPolicy)
import Nagare.Dsl.Cdn.Types (Cdn)
import Nagare.Dsl.Config (encodeServerSite, encodeStaticSite)
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Types (StaticSite, siteNameText)
import Nagare.Dsl.Types (SecretName, imageRefText, namespaceText)
import Nagare.Image (qualifyImage)
import Nagare.Inventory.Application
  ( AccessBinding
  , ReviewedCdnBinding (..)
  , acceptedApplicationImage
  , acceptedImageBuildSecrets
  , acceptedSecretBindings
  )
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedAppNamespace)
import Nagare.Inventory.Lifecycle qualified as InventoryLifecycle
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Site (SiteReleaseAction (..), acceptedSiteReleaseLog, acceptedSiteSource, compileServerSiteScopeWith, compileStaticSiteScopeWith, legacyServerSiteReleaseImport, legacyStaticSiteReleaseImport, recordReviewedSiteInputs, siteVolumeRecoveryBindings)
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
import Nagare.Static.Release
  ( StaticRelease (..)
  , StaticReleaseLog
  , findRelease
  , formatReleasesTable
  , readReleaseLog
  )
import Nagare.Target (TargetProfile)
import Nagare.Target.Kinds (hostShapeFor)

-- | Deploy a site (EP-14/EP-15/EP-18). Dispatches on the config's @kind@: a
-- @StaticSite@ runs the Nginx path, a @ServerSite@ runs the Node path. Both share
-- the same CLI options and record a release on success.
runSiteDeploy :: Maybe String -> SiteDeployOpts -> IO ()
runSiteDeploy mctx sopts = do
  when
    (isNothing (sopts ^. #imageResource))
    (dieT "reviewed site deployment requires --image-resource")
  when
    (isJust (sopts ^. #contract) && not (sopts ^. #dryRun) && isNothing (sopts ^. #savePlan))
    (dieT "--contract requires --dry-run or --save-plan; a live deploy has no contract document")
  bd <- resolveBaseDomain mctx (sopts ^. #baseDomain)
  tp <- activeProfile mctx
  esite <- loadSiteInput (sopts ^. #rendered) (sopts ^. #ghcEnv) (sopts ^. #file)
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
            (encodeStaticSite s)
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
            (encodeServerSite s)
            (s & #image %~ const qimg)
            bd
            (sopts ^. #savePlan)

-- | Deploy an already-loaded, image-qualified static site and return its
-- production URL: the second half of @site publish@, with no second config load.
deployLoadedStaticSite :: Maybe String -> TargetProfile -> SiteDeployOpts -> LBS.ByteString -> StaticSite -> Text -> IO Text
deployLoadedStaticSite mctx tp options config site bd = do
  runStaticSiteDeployPlan mctx tp options config site bd Nothing
  tag <- reviewedSiteTag options
  pure (staticSiteUrl tp options site tag bd)

staticSiteUrl :: TargetProfile -> SiteDeployOpts -> StaticSite -> Text -> Text -> Text
staticSiteUrl tp options site tag bd = productionManifests (siteDeployInputs tp options site tag bd) ^. #url

runStaticSiteDeployPlan ::
  Maybe String -> TargetProfile -> SiteDeployOpts -> LBS.ByteString -> StaticSite -> Text -> Maybe FilePath -> IO ()
runStaticSiteDeployPlan mctx tp options config site bd output = do
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
    config
    (siteNameText (site ^. #name))
    (namespaceText (site ^. #namespace))
    (imageRefText (site ^. #image))
    (rendered ^. #url)
    tag
    (site ^. #cdn)
    (site ^. #access)
    False
    ( \cdn access _ _ tls cluster namespaceId imageId ->
        compileStaticSiteScopeWith RecordRelease cdn access inputs cluster namespaceId imageId tls
    )
    (legacyStaticSiteReleaseImport site)
    output

runServerSiteDeployPlan ::
  Maybe String -> TargetProfile -> SiteDeployOpts -> LBS.ByteString -> ServerSite -> Text -> Maybe FilePath -> IO ()
runServerSiteDeployPlan mctx tp options config original bd output = do
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
    config
    (siteNameText (site ^. #name))
    (namespaceText (site ^. #namespace))
    (imageRefText (site ^. #image))
    (rendered ^. #url)
    tag
    (site ^. #cdn)
    (site ^. #access)
    True
    ( \cdn access buildSecrets bindings tls cluster namespaceId imageId ->
        compileServerSiteScopeWith
          RecordRelease
          cdn
          access
          buildSecrets
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

runReviewedSiteDeployPlan ::
  Maybe String ->
  SiteDeployOpts ->
  LBS.ByteString ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe Cdn ->
  Maybe AccessPolicy ->
  Bool ->
  ( Maybe ReviewedCdnBinding ->
    Maybe AccessBinding ->
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
runReviewedSiteDeployPlan mctx options config siteName ns imageName url tag cdnIntent accessIntent bindBuildInputs compile importLegacy output = do
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
  (cluster, namespaceId) <- either dieT pure (acceptedAppNamespace snapshot ns)
  accessBinding <- reviewedSiteAccessBinding active snapshot cluster accessIntent
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
  (compiled, native) <-
    either
      (dieT . T.pack . show)
      pure
      (compile cdnBinding accessBinding buildSecrets envSecrets tlsSecrets cluster namespaceId imageId prior release source)
  -- EP-263: the scope records its configuration digest and reviewed inputs.
  let inputs = Map.fromList ([("tag", tag), ("imageResource", Resource.resourceIdText imageId)] <> [("baseDomain", T.pack domain) | Just domain <- [options ^. #baseDomain]])
  scope <- either (dieT . T.pack . show) pure (recordReviewedSiteInputs config inputs compiled)
  (carriedScope, carriedNative) <- withMovedRoutes active snapshot (scope, native)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope carriedScope NE.:| []))
  if options ^. #dryRun
    then
      if isJust (options ^. #contract)
        then emitDocument (deployPreview carriedScope [])
        else BC.putStrLn (ResourceWire.encodeCanonicalScope scope)
    else case (adoption, output) of
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
      (Just proposal, Just directory) -> do
        validateInlineReleaseAdoption scope ("nagare-static-releases-" <> siteName) proposal
        Inventory.planInventoryCandidateAdoptionWith
          (inventoryPlanRegistryWithNative active workspace carriedNative)
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
      -- The current config's policy governs a rollback: it changes the image,
      -- never resurrects older public routing from release history (EP-186).
      accessIntent = case config of
        Load.SiteStatic site -> site ^. #access
        Load.SiteServer site -> site ^. #access
  cdnBinding <-
    reviewedCdnBinding
      active
      workspace
      snapshot
      cdnIntent
      (options ^. #cdnBackendResource)
  (cluster, namespaceId) <- either dieT pure (acceptedAppNamespace snapshot ns)
  accessBinding <- reviewedSiteAccessBinding active snapshot cluster accessIntent
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
      either
        (dieT . T.pack . show)
        pure
        ( compileStaticSiteScopeWith
            SelectRelease
            cdnBinding
            accessBinding
            inputs
            cluster
            namespaceId
            imageId
            tlsSecrets
            prior
            release
            source
        )
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
        ( compileServerSiteScopeWith
            SelectRelease
            cdnBinding
            accessBinding
            buildSecrets
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
  (carriedScope, carriedNative) <- withMovedRoutes active snapshot (scope, native)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope carriedScope NE.:| []))
  Inventory.planInventoryCandidateWith
    (inventoryPlanRegistryWithNative active workspace carriedNative)
    active
    candidate
    output
