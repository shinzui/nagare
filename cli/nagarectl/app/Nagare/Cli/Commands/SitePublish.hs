-- | @nagarectl site package@: write a static site's local build context or
-- Docker archive. A thin boundary over "Nagare.Static.Package"; packaging reads
-- local files only and never touches inventory, Kubernetes, gcloud or the
-- target registry.
module Nagare.Cli.Commands.SitePublish
  ( runSitePackage
  , runSitePublish
  )
where

import Control.Exception (try)
import Control.Monad (forM_, void)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Nagare.Cli.Options (AppImagePlanOpts (..), SiteDeployOpts (..), SitePackageOpts, SitePublishOpts)
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeProfile, activeTarget, resolveBaseDomain)
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Prelude hiding (Context)
import Nagare.Dsl.Static.Types (StaticSite, siteNameText)
import Nagare.Dsl.Types (namespaceText)
import Nagare.Image (qualifyImage, taggedImageRef)
import Nagare.Inventory.Application (acceptedAccessBinding, acceptedSecretBindings)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Site (acceptedSiteReleaseLog)
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store.Counters (tracePhase, traceProcess)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Static.Build
  ( PreparedStaticOutput (..)
  , prepareStaticOutput
  , renderStaticBuildError
  )
import Nagare.Static.ContentDigest (contentDigestText)
import Nagare.Static.Package
  ( PackageResult (..)
  , PackageTarget (..)
  , derivedTag
  , packageStaticSite
  , packageStaticSiteGated
  , renderPackageError
  , runLogged
  , validatePlatform
  , validateTag
  )
import Nagare.Static.Publish
import Nagare.Static.Release (findRelease)
import Nagare.Target (ActiveTarget, TargetProfile, contextNameText)
import System.Directory (XdgDirectory (..), createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getXdgDirectory, listDirectory, makeAbsolute, removeDirectory)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>))
import System.IO (stderr)

runSitePackage :: Maybe String -> SitePackageOpts -> IO ()
runSitePackage mctx options = do
  -- Refuse an ambiguous request before loading the config or touching Docker.
  case (options ^. #contextOut, options ^. #archive) of
    (Nothing, Nothing) -> dieT "site package needs exactly one of --context-out DIR and --archive FILE"
    (Just _, Just _) -> dieT "site package takes --context-out or --archive, not both"
    _ -> pure ()
  when
    (isJust (options ^. #contextOut) && (isJust (options ^. #tag) || isJust (options ^. #platform)))
    (dieT "--tag and --platform apply to --archive only")
  provisionGhcEnv (options ^. #ghcEnv)
  loaded <- tracePhase "package.config" (Load.loadSite (options ^. #file))
  site <- case loaded of
    Left err -> dieT (Load.renderLoadError err)
    Right (Load.SiteServer _) -> dieT "site package supports static sites only; this config declares a server site"
    Right (Load.SiteStatic s) -> pure s
  prepared <- tracePhase "package.output" (prepareOutputFor (options ^. #projectDir) (options ^. #outputDir) (options ^. #build) site)
  target <- case (options ^. #contextOut, options ^. #archive) of
    (Just out, _) -> pure (ContextOut out)
    (_, Just out) -> archiveTarget mctx options site out
    _ -> dieT "site package needs exactly one of --context-out DIR and --archive FILE"
  result <- packageStaticSite site prepared target
  packaged <- either (dieT . renderPackageError) pure result
  TIO.putStrLn ("path: " <> T.pack (packaged ^. #path))
  TIO.putStrLn ("content-digest: " <> contentDigestText (packaged ^. #digest))
  forM_ (packaged ^. #image) $ \image -> TIO.putStrLn ("image: " <> image)
  forM_ (packaged ^. #tag) $ \tag -> TIO.putStrLn ("tag: " <> tag)
  forM_ (packaged ^. #platform) $ \platform -> TIO.putStrLn ("platform: " <> platform)

archiveTarget :: Maybe String -> SitePackageOpts -> StaticSite -> FilePath -> IO PackageTarget
archiveTarget mctx options site out = do
  profile <- activeProfile mctx
  platform <- either (dieT . renderPackageError) pure (validatePlatform (maybe (profile ^. #targetPlatform) T.pack (options ^. #platform)))
  tag <- case options ^. #tag of
    Just given -> either (dieT . renderPackageError) pure (validateTag (T.pack given))
    Nothing -> derivedTag <$> getCurrentTime
  qualified <- either (dieT . ("site package: " <>)) pure (qualifyImage profile (site ^. #image))
  pure ArchiveOut {archive = out, destination = taggedImageRef qualified tag, tag = tag, platform = platform}

-- ---------------------------------------------------------------------------
-- site publish

-- | The reviewed image publication and site deployment are the existing
-- command handlers, passed in by the dispatcher (command handlers do not import
-- each other).
runSitePublish ::
  Maybe String ->
  SitePublishOpts ->
  (AppImagePlanOpts -> IO ()) ->
  (TargetProfile -> SiteDeployOpts -> StaticSite -> Text -> IO Text) ->
  (TargetProfile -> SiteDeployOpts -> StaticSite -> Text -> Text -> Text) ->
  IO ()
runSitePublish mctx options imagePlan deployLoadedStaticSite staticSiteUrl = do
  provisionGhcEnv (options ^. #ghcEnv)
  active <- activeTarget mctx
  let profile = active ^. #profile
      contextText = contextNameText (active ^. #contextName)
  loaded <- tracePhase "publish.config" (Load.loadSite (options ^. #file))
  site0 <- case loaded of
    Left err -> dieT (Load.renderLoadError err)
    Right (Load.SiteServer _) -> dieT "site publish supports static sites only; this config declares a server site"
    Right (Load.SiteStatic s) -> pure s
  qualified <- either (dieT . ("site publish: " <>)) pure (qualifyImage profile (site0 ^. #image))
  let site = site0 & #image .~ qualified
      siteText = siteNameText (site ^. #name)
      nsText = namespaceText (site ^. #namespace)
      configHash = configDigestOf site
  stateRoot <- getXdgDirectory XdgState ("nagare" </> T.unpack contextText </> "static-releases" </> T.unpack siteText)
  snapshot <- Inventory.loadTargetSnapshot active
  baseDomain <- resolveBaseDomain mctx (options ^. #baseDomain)
  platform <- either (dieT . renderPackageError) pure (validatePlatform (maybe (profile ^. #targetPlatform) T.pack (options ^. #platform)))
  let deployOptions tagText sourceText image =
        SiteDeployOpts
          { file = options ^. #file
          , tag = Just (T.unpack tagText)
          , baseDomain = options ^. #baseDomain
          , projectDir = options ^. #projectDir
          , ghcEnv = options ^. #ghcEnv
          , dryRun = False
          , skipBuild = True
          , source = Just (T.unpack sourceText)
          , savePlan = Nothing
          , imageResource = Just (T.unpack image)
          , cdnBackendResource = options ^. #cdnBackendResource
          , siteVolumeRecovery = []
          , siteEnvSecretResources = []
          , siteTlsSecretResources = options ^. #tlsSecretResources
          , sitePreviewEnvResources = []
          , sitePreviewAdoptionInput = Nothing
          , legacyReleaseImport = Nothing
          , releaseAdoptionInput = Nothing
          }
      urlFor tagText = staticSiteUrl profile (deployOptions tagText "" "") site tagText baseDomain
  prepared <- tracePhase "publish.output" (prepareOutputFor (options ^. #projectDir) (options ^. #outputDir) (options ^. #build) site)
  let prerequisites = checkPrerequisites snapshot site options nsText
      operations logHandle =
        PublishOps
          { preflight = pure prerequisites
          , servingSource = servingRelease active snapshot siteText nsText
          , package = \archive tagText gate ->
              packageStaticSiteGated
                (loggedDocker logHandle)
                site
                prepared
                ArchiveOut {archive = archive, destination = taggedImageRef qualified tagText, tag = tagText, platform = platform}
                gate
          , publishImage = publishImageFor imagePlan
          , deploy = \receipt -> do
              image <- maybe (pure (Left "receipt has no image resource")) (pure . Right) (receipt ^. #imageResource)
              case image of
                Left e -> pure (Left e)
                Right resource ->
                  tryExit
                    (deployLoadedStaticSite profile (deployOptions (receipt ^. #tag) (receipt ^. #source) resource) site baseDomain)
          }
  if options ^. #resume
    then do
      (releaseDir, receipt) <- selectResume options stateRoot
      when (receipt ^. #site /= siteText || receipt ^. #context /= contextText) $
        dieT ("release " <> T.pack releaseDir <> " belongs to site " <> receipt ^. #site <> " in context " <> receipt ^. #context)
      -- The retained archive is immutable input; the current files and config
      -- must still be the ones it was built from.
      seen <- newIORef Nothing
      void $
        packageStaticSiteGated (\_ -> pure True) site prepared ArchiveOut {archive = releaseDir </> "resume-check.tar", destination = receipt ^. #destination, tag = receipt ^. #tag, platform = receipt ^. #platform} (\d -> writeIORef seen (Just d) >> pure False)
      current <- readIORef seen
      when (fmap (contentSource configHash) current /= Just (receipt ^. #source)) $
        dieT ("the files or configuration changed since release " <> receipt ^. #releaseId <> " was packaged; start a new release with `nagarectl site publish` (the retained release stays in " <> T.pack releaseDir <> ")")
      archivePresent <- doesFileExist (receipt ^. #archive)
      unless archivePresent (dieT ("the retained archive is missing: " <> T.pack (receipt ^. #archive)))
      result <- withBuildLog options releaseDir (\h -> resumePublish (operations h) releaseDir receipt)
      report urlFor releaseDir result
    else do
      now <- getCurrentTime
      let releaseId = derivedTag now
          tagText = maybe releaseId T.pack (options ^. #tag)
      tagOk <- either (dieT . renderPackageError) pure (validateTag tagText)
      releaseDir <- maybe (pure (stateRoot </> T.unpack releaseId)) makeAbsolute (options ^. #releaseDir)
      unless (isRight (publicationImageId (publishKey siteText releaseId))) $
        dieT ("site name too long to derive a publication key: " <> siteText)
      createDirectoryIfMissing True releaseDir
      let request =
            PublishRequest
              { releaseDir = releaseDir
              , releaseId = releaseId
              , tag = tagOk
              , site = siteText
              , namespace = nsText
              , context = contextText
              , platform = platform
              , destination = taggedImageRef qualified tagOk
              , configDigest = configHash
              , newRelease = options ^. #newRelease
              }
      result <- withBuildLog options releaseDir (\h -> runPublish (operations h) request)
      report urlFor releaseDir result
  where
    report urlFor releaseDir = \case
      Left failure -> do
        TIO.hPutStrLn stderr (renderPublishFailure failure)
        TIO.hPutStrLn stderr ("release kept in " <> T.pack releaseDir)
        when (failureStage failure /= "preflight" && failureStage failure /= "package") $
          TIO.hPutStrLn stderr ("resume with: nagarectl site publish --resume --release-dir " <> T.pack releaseDir)
        exitFailure
      Right (Unchanged servingTag) -> do
        -- Nothing was released, so the directory made up front holds nothing.
        leftovers <- listDirectory releaseDir
        when (null leftovers) (removeDirectory releaseDir)
        TIO.putStrLn ("unchanged: release " <> servingTag <> " already serves these files at " <> urlFor servingTag)
      Right (Released receipt) -> do
        TIO.putStrLn ("url: " <> fromMaybe "" (receipt ^. #url))
        TIO.putStrLn ("tag: " <> receipt ^. #tag)
        TIO.putStrLn ("image: " <> fromMaybe "" (receipt ^. #imageResource))
        TIO.putStrLn ("release-dir: " <> T.pack releaseDir)
    failureStage (PublishFailure stageName _) = stageName

-- | The configured output, or an override resolved from the project directory.
prepareOutputFor :: FilePath -> Maybe FilePath -> Bool -> StaticSite -> IO PreparedStaticOutput
prepareOutputFor projectDir override buildFirst site = do
  let configured skipBuild = prepareStaticOutput skipBuild site projectDir >>= either (dieT . renderStaticBuildError) pure
  case override of
    Nothing -> configured (not buildFirst)
    Just dir -> do
      when buildFirst (void (configured False))
      absolute <- makeAbsolute (projectDir </> dir)
      exists <- doesDirectoryExist absolute
      unless exists (dieT ("static output directory not found: " <> T.pack absolute))
      pure (PreparedStaticOutput absolute)

-- | Docker's output goes to @build.log@ in the release directory, and to
-- stderr as well with @--verbose@ (a tee through the log keeps stdout clean).
withBuildLog :: SitePublishOpts -> FilePath -> (Maybe FilePath -> IO a) -> IO a
withBuildLog options releaseDir action = do
  createDirectoryIfMissing True releaseDir
  action (if options ^. #verbose then Nothing else Just (releaseDir </> "build.log"))

loggedDocker :: Maybe FilePath -> [String] -> IO Bool
loggedDocker logPath args = traceProcess "docker" (runLogged "docker" logPath args)

-- | The first accepted prerequisite the release lacks, with the command that
-- provides it, before anything is built.
checkPrerequisites :: ResourceInventory.ScopeSnapshot -> StaticSite -> SitePublishOpts -> Text -> Either Text ()
checkPrerequisites snapshot site options nsText = do
  (cluster, _) <-
    first
      (\e -> "namespace " <> nsText <> " is not accepted: " <> e <> "; provide it with `nagarectl inventory plan` and `nagarectl inventory apply` for the platform foundation")
      (acceptedFoundationNamespace snapshot nsText)
  when (isJust (site ^. #access)) $
    void (first (\e -> "site access needs the accepted auth owner: " <> e <> "; provide it with `nagarectl access` setup (see docs/user/site-access.md)") (acceptedAccessBinding snapshot cluster))
  when (isJust (site ^. #cdn) && isNothing (options ^. #cdnBackendResource)) $
    Left "the site declares a CDN; pass --cdn-backend-resource RESOURCE-ID (the accepted platform BackendService, see `nagarectl inventory status`)"
  tlsIds <- traverse (first id . Resource.mkResourceId . T.pack) (options ^. #tlsSecretResources)
  void (first (\e -> "supplied-TLS Secret is not accepted: " <> e) (acceptedSecretBindings snapshot tlsIds))

-- | The serving release's (tag, recorded source) from accepted inventory, or
-- 'Nothing' when the site has no history (or none this plan can read: the
-- safe answer is to release).
servingRelease :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> Text -> Text -> IO (Maybe (Text, Text))
servingRelease active snapshot siteText nsText =
  case acceptedFoundationNamespace snapshot nsText of
    Left _ -> pure Nothing
    Right (cluster, _) -> do
      store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
      history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
      accepted <- either (dieT . T.pack . show) pure (ResourceInventory.composeSnapshot snapshot)
      (native, _) <- InventoryStatus.loadAcceptedNative store history accepted >>= either dieT pure
      pure $ do
        releaseLog <- either (const Nothing) Just (acceptedSiteReleaseLog snapshot native siteText nsText cluster)
        current <- releaseLog ^. #current
        release <- findRelease current releaseLog
        recorded <- release ^. #source
        pure (current, recorded)

-- | Converge the reviewed image publication for a receipt's retained archive.
-- The image resource is computed from the publication key, not parsed from output.
publishImageFor :: (AppImagePlanOpts -> IO ()) -> Receipt -> IO (Either Text Text)
publishImageFor imagePlan receipt =
  case publicationImageId (receipt ^. #key) of
    Left e -> pure (Left e)
    Right resource -> do
      outcome <-
        tryExit $
          imagePlan
            AppImagePlanOpts
              { archive = receipt ^. #archive
              , destination = T.unpack (receipt ^. #destination)
              , key = T.unpack (receipt ^. #key)
              , buildInputResources = []
              , buildDockerfile = Nothing
              , buildContext = Nothing
              , savePlan = Nothing
              , contract = Nothing
              }
      pure (Resource.resourceIdText resource <$ outcome)

-- | Run a command that reports failure by exiting, as a value, so the
-- coordinator can keep the release and print its resume command.
tryExit :: IO a -> IO (Either Text a)
tryExit action =
  try action >>= \case
    Right value -> pure (Right value)
    Left (ExitFailure code) -> pure (Left ("the command failed (exit " <> T.pack (show code) <> "; its message is above)"))
    Left ExitSuccess -> pure (Left "the command exited early")

-- | The release named by @--release-dir@, or the newest unfinished one of this
-- site in this context; more than one candidate is refused rather than guessed.
selectResume :: SitePublishOpts -> FilePath -> IO (FilePath, Receipt)
selectResume options stateRoot = case options ^. #releaseDir of
  Just dir -> do
    absolute <- makeAbsolute dir
    readReceipt absolute >>= either dieT (pure . (absolute,))
  Nothing ->
    unfinishedReleases stateRoot >>= \case
      [] -> dieT "no unfinished release of this site in this context; nothing to resume"
      [one] -> pure one
      several ->
        dieT
          ( "more than one unfinished release; choose one with --release-dir: "
              <> T.intercalate ", " (map (T.pack . fst) several)
          )
