{-# LANGUAGE PackageImports #-}

-- | The @nagarectl@ deploy CLI entry point.
--
-- Command namespaces:
--
--   * @nagarectl deploy@ — the original app deploy of a typed
--     'Nagare.Dsl.Types.Deployment'.
--   * @nagarectl site deploy@ — the static-site deploy (EP-14): load a
--     'Nagare.Dsl.Static.Types.StaticSite', render the generated Nginx config and
--     Knative manifests, package the built output into a generated Nginx image,
--     push, apply, wait, record a release, and print the URL. Kind-dispatching by
--     design: a later plan (EP-18) routes a @ServerSite@ down a Node-image path
--     through the same command.
--   * @nagarectl site releases@ / @site rollback@ — release history and rollback
--     (EP-15), backed by a per-site ConfigMap.
--   * @nagarectl site preview deploy|list|delete@ — branch/PR previews as
--     separate Knative Services (EP-15).
--
-- A config that fails to load prints a one-line error to stderr and exits 1
-- before anything touches Docker or the cluster. @--dry-run@ prints the rendered
-- artifacts and URL without side effects.
module Main (main) where

import Nagare.Dsl.Prelude

import "generic-lens" Data.Generics.Labels ()

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Maybe (maybeToList)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Options.Applicative
import System.Directory (makeAbsolute)
import System.Environment (lookupEnv, setEnv)
import System.Exit (exitFailure)
import System.IO (stderr)

import Nagare.Deploy (applyManifests, serviceUrl, waitForReady)
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Render (renderDomainMapping, renderService)
import Nagare.Dsl.Static.Render
  ( StaticDeployContext (..)
  , renderNginxConfig
  , renderStaticDomainMappings
  , renderStaticService
  )
import Nagare.Dsl.Static.Types (StaticSite, siteNameText)
import Nagare.Dsl.Types
  ( domainText
  , imageRefText
  , mkDomain
  , namespaceText
  , serviceNameText
  )
import Nagare.Image
  ( buildImage
  , computeTag
  , configureDockerAuth
  , imageRef
  , pushImage
  , taggedImageRef
  )
import Nagare.Static.Build
  ( PreparedStaticOutput (..)
  , prepareStaticOutput
  , renderStaticBuildError
  )
import Nagare.Static.Image (withStaticImageContext)
import Nagare.Static.Preview
  ( deletePreview
  , listPreviews
  , previewDomain
  , previewServiceName
  )
import Nagare.Static.Release
  ( StaticRelease (..)
  , StaticReleaseLog (..)
  , addRelease
  , findRelease
  , formatReleasesTable
  , readReleaseLog
  , writeReleaseLog
  )

-- ---------------------------------------------------------------------------
-- CLI options

-- | Options for the @deploy@ subcommand.
data DeployOpts = DeployOpts
  { file :: !FilePath
  , tag :: !(Maybe String)
  , baseDomain :: !(Maybe String)
  , context :: !FilePath
  , ghcEnv :: !(Maybe FilePath)
  , dryRun :: !Bool
  }
  deriving stock (Generic, Show)

-- | Options for @site deploy@ (and, with a @--name@, @site preview deploy@).
data SiteDeployOpts = SiteDeployOpts
  { file :: !FilePath
  , tag :: !(Maybe String)
  , baseDomain :: !(Maybe String)
  , projectDir :: !FilePath
  , ghcEnv :: !(Maybe FilePath)
  , dryRun :: !Bool
  , skipBuild :: !Bool
  , source :: !(Maybe String)
  -- ^ Free-form provenance recorded with the release (e.g. a git SHA or branch).
  }
  deriving stock (Generic, Show)

-- | Options for the read-only / config-only site subcommands (@releases@,
-- @rollback@, @preview list@, @preview delete@): enough to load the config and
-- resolve the base domain.
data SiteCommonOpts = SiteCommonOpts
  { file :: !FilePath
  , baseDomain :: !(Maybe String)
  , ghcEnv :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | Everything @nagarectl@ can be asked to do.
data Command
  = Deploy DeployOpts
  | SiteDeploy SiteDeployOpts
  | SiteReleases SiteCommonOpts
  | SiteRollback SiteCommonOpts String
  | SitePreviewDeploy SiteDeployOpts String
  | SitePreviewList SiteCommonOpts
  | SitePreviewDelete SiteCommonOpts String

-- Reusable option fragments shared across the subcommands.

fileOpt :: FilePath -> Parser FilePath
fileOpt defaultFile =
  strOption
    ( long "file"
        <> short 'f'
        <> metavar "FILE"
        <> value defaultFile
        <> showDefault
        <> help "Path to the typed config file"
    )

tagOpt :: Parser (Maybe String)
tagOpt =
  optional
    ( strOption
        ( long "tag"
            <> short 't'
            <> metavar "TAG"
            <> help "Image tag override (default: UTC timestamp YYYYMMDD-HHMMSS)"
        )
    )

baseDomainOpt :: Parser (Maybe String)
baseDomainOpt =
  optional
    ( strOption
        ( long "base-domain"
            <> metavar "DOMAIN"
            <> help "Apps base domain (overrides NAGARE_BASE_DOMAIN, default apps.example.com)"
        )
    )

ghcEnvOpt :: Parser (Maybe FilePath)
ghcEnvOpt =
  optional
    ( strOption
        ( long "ghc-env"
            <> metavar "FILE"
            <> help "GHC package-environment file for the config loader's runghc (overrides NAGARE_GHC_ENVIRONMENT)"
        )
    )

dryRunOpt :: Parser Bool
dryRunOpt =
  switch
    ( long "dry-run"
        <> help "Print rendered artifacts and URL without building, pushing, or applying"
    )

deployOptsParser :: FilePath -> Parser DeployOpts
deployOptsParser defaultFile =
  DeployOpts
    <$> fileOpt defaultFile
    <*> tagOpt
    <*> baseDomainOpt
    <*> strOption
      ( long "context"
          <> short 'c'
          <> metavar "DIR"
          <> value "."
          <> showDefault
          <> help "Docker build-context directory"
      )
    <*> ghcEnvOpt
    <*> dryRunOpt

siteDeployOptsParser :: FilePath -> Parser SiteDeployOpts
siteDeployOptsParser defaultFile =
  SiteDeployOpts
    <$> fileOpt defaultFile
    <*> tagOpt
    <*> baseDomainOpt
    <*> strOption
      ( long "project-dir"
          <> short 'C'
          <> metavar "DIR"
          <> value "."
          <> showDefault
          <> help "Project root: where the build runs and the output directory is resolved"
      )
    <*> ghcEnvOpt
    <*> dryRunOpt
    <*> switch
      ( long "skip-build"
          <> help "Do not run the build command; package the existing output directory as-is"
      )
    <*> optional
      ( strOption
          ( long "source"
              <> metavar "REF"
              <> help "Provenance to record with the release (e.g. a git SHA or branch)"
          )
      )

siteCommonOptsParser :: FilePath -> Parser SiteCommonOpts
siteCommonOptsParser defaultFile =
  SiteCommonOpts <$> fileOpt defaultFile <*> baseDomainOpt <*> ghcEnvOpt

previewNameOpt :: Parser String
previewNameOpt =
  strOption
    ( long "name"
        <> short 'n'
        <> metavar "NAME"
        <> help "Preview name (branch or PR identifier)"
    )

-- | The default config filename for the chosen substrate (EP-8).
defaultConfigFile :: FilePath
defaultConfigFile = "nagare/Config.hs"

opts :: ParserInfo Command
opts =
  info
    (commandParser <**> helper)
    ( fullDesc
        <> progDesc "nagarectl — deploy a typed Nagare app or static site to Knative"
    )
  where
    commandParser =
      subparser
        ( command "deploy" deployCmd
            <> command "site" siteCmd
        )
    deployCmd =
      info
        (Deploy <$> deployOptsParser defaultConfigFile <**> helper)
        (fullDesc <> progDesc "Build, push, and deploy the app in the current directory")
    siteCmd =
      info
        (siteSubparser <**> helper)
        (fullDesc <> progDesc "Static and full-stack site hosting")
    siteSubparser =
      subparser
        ( command "deploy" siteDeployCmd
            <> command "releases" siteReleasesCmd
            <> command "rollback" siteRollbackCmd
            <> command "preview" sitePreviewCmd
        )
    siteDeployCmd =
      info
        (SiteDeploy <$> siteDeployOptsParser defaultConfigFile <**> helper)
        (fullDesc <> progDesc "Build, package, and deploy the static site in the current directory")
    siteReleasesCmd =
      info
        (SiteReleases <$> siteCommonOptsParser defaultConfigFile <**> helper)
        (fullDesc <> progDesc "List recorded releases for the site")
    siteRollbackCmd =
      info
        ( SiteRollback
            <$> siteCommonOptsParser defaultConfigFile
            <*> strArgument (metavar "RELEASE_ID" <> help "Release id to roll back to")
            <**> helper
        )
        (fullDesc <> progDesc "Roll production back to a prior release")
    sitePreviewCmd =
      info
        (previewSubparser <**> helper)
        (fullDesc <> progDesc "Branch / pull-request preview deployments")
    previewSubparser =
      subparser
        ( command "deploy" previewDeployCmd
            <> command "list" previewListCmd
            <> command "delete" previewDeleteCmd
        )
    previewDeployCmd =
      info
        (SitePreviewDeploy <$> siteDeployOptsParser defaultConfigFile <*> previewNameOpt <**> helper)
        (fullDesc <> progDesc "Deploy a preview of the site under a derived name and domain")
    previewListCmd =
      info
        (SitePreviewList <$> siteCommonOptsParser defaultConfigFile <**> helper)
        (fullDesc <> progDesc "List the site's preview deployments")
    previewDeleteCmd =
      info
        ( SitePreviewDelete
            <$> siteCommonOptsParser defaultConfigFile
            <*> strArgument (metavar "NAME" <> help "Preview name to delete")
            <**> helper
        )
        (fullDesc <> progDesc "Delete a preview deployment")

-- ---------------------------------------------------------------------------
-- Main

main :: IO ()
main =
  execParser opts >>= \case
    Deploy dopts -> runDeploy dopts
    SiteDeploy sopts -> runSiteDeploy sopts
    SiteReleases copts -> runSiteReleases copts
    SiteRollback copts rid -> runSiteRollback copts (T.pack rid)
    SitePreviewDeploy sopts pname -> runPreviewDeploy sopts (T.pack pname)
    SitePreviewList copts -> runPreviewList copts
    SitePreviewDelete copts pname -> runPreviewDelete copts (T.pack pname)

runDeploy :: DeployOpts -> IO ()
runDeploy dopts = do
  bd <- resolveBaseDomain (dopts ^. #baseDomain)
  provisionGhcEnv (dopts ^. #ghcEnv)

  edep <- Load.loadDeployment (dopts ^. #file)
  dep <- case edep of
    Left err -> dieT (Load.renderLoadError err)
    Right d -> pure d

  imageTag <- resolveTag (dopts ^. #tag)

  let ref = imageRef dep imageTag
      svcBytes = renderService dep imageTag
      dmBytes = maybeToList (renderDomainMapping dep)
      url = serviceUrl dep bd
      name = serviceNameText (dep ^. #name)
      ns = namespaceText (dep ^. #namespace)

  if dopts ^. #dryRun
    then do
      BC.putStrLn "--- Knative Service manifest ---"
      BC.putStr svcBytes
      forM_ dmBytes $ \dm -> do
        BC.putStrLn "--- DomainMapping manifest ---"
        BC.putStr dm
      TIO.putStrLn ("URL: " <> url)
    else do
      configureDockerAuth
      buildImage ref (dopts ^. #context)
      pushImage ref
      applyManifests (svcBytes : dmBytes)
      waitForReady name ns
      TIO.putStrLn ("Deployed: " <> url)

-- | Deploy a static site (EP-14/EP-15). On success records a release.
runSiteDeploy :: SiteDeployOpts -> IO ()
runSiteDeploy sopts = do
  bd <- resolveBaseDomain (sopts ^. #baseDomain)
  provisionGhcEnv (sopts ^. #ghcEnv)

  -- Kind-dispatching seam: today @site deploy@ loads a StaticSite directly. When
  -- EP-18 lands, this becomes a `loadSite` returning SiteStatic/SiteServer and
  -- dispatching to the Nginx or Node image path; the rest is the SiteStatic branch.
  site <- loadSiteOrDie (sopts ^. #file)
  imageTag <- resolveTag (sopts ^. #tag)

  let ctx = StaticDeployContext {imageTag = imageTag, previewName = Nothing}
      ref = taggedImageRef (site ^. #image) imageTag
      nginxBytes = renderNginxConfig site
      svcBytes = renderStaticService site ctx
      dmBytes = renderStaticDomainMappings site ctx
      url = staticUrl site bd
      name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)

  if sopts ^. #dryRun
    then do
      printStaticArtifacts nginxBytes svcBytes dmBytes url
      TIO.putStrLn ("Release: " <> imageTag)
    else do
      out <- prepareOrDie (sopts ^. #skipBuild) site (sopts ^. #projectDir)
      configureDockerAuth
      withStaticImageContext site out (buildImage ref)
      pushImage ref
      applyManifests (svcBytes : dmBytes)
      waitForReady name ns
      recordRelease site imageTag url name ns (sopts ^. #source)
      TIO.putStrLn ("Deployed static site: " <> url)

-- | Build, store, and report a release record after a successful production
-- deploy. A malformed existing history is reported and the deploy exits
-- non-zero (the service is live, but history would be lost if overwritten).
recordRelease :: StaticSite -> Text -> Text -> Text -> Text -> Maybe String -> IO ()
recordRelease site imageTag url name ns src = do
  now <- getCurrentTime
  let rel =
        StaticRelease
          { releaseId = imageTag
          , siteName = name
          , namespace = ns
          , image = imageRefText (site ^. #image)
          , imageTag = imageTag
          , url = url
          , source = T.pack <$> src
          , createdAt = now
          }
  elog <- readReleaseLog name ns
  case elog of
    Left err ->
      dieT ("deploy succeeded but release history is unreadable (not overwritten): " <> err)
    Right logv -> writeReleaseLog name ns (addRelease rel logv)

-- | @site releases@: print the recorded release history.
runSiteReleases :: SiteCommonOpts -> IO ()
runSiteReleases copts = do
  provisionGhcEnv (copts ^. #ghcEnv)
  site <- loadSiteOrDie (copts ^. #file)
  let name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
  elog <- readReleaseLog name ns
  case elog of
    Left err -> dieT err
    Right logv -> TIO.putStr (formatReleasesTable logv)

-- | @site rollback RELEASE_ID@: re-point the production Service at a prior
-- release's image tag and mark it current.
runSiteRollback :: SiteCommonOpts -> Text -> IO ()
runSiteRollback copts rid = do
  provisionGhcEnv (copts ^. #ghcEnv)
  site <- loadSiteOrDie (copts ^. #file)
  let name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
  elog <- readReleaseLog name ns
  logv <- case elog of
    Left err -> dieT err
    Right l -> pure l
  case findRelease rid logv of
    Nothing -> dieT ("no such release: " <> rid)
    Just rel -> do
      let ctx = StaticDeployContext {imageTag = rel ^. #imageTag, previewName = Nothing}
          svcBytes = renderStaticService site ctx
          dmBytes = renderStaticDomainMappings site ctx
      applyManifests (svcBytes : dmBytes)
      waitForReady name ns
      writeReleaseLog name ns logv {current = Just (rel ^. #releaseId)}
      TIO.putStrLn ("Rolled back to " <> (rel ^. #releaseId) <> ": " <> (rel ^. #url))

-- | @site preview deploy --name NAME@: deploy the current build as an isolated
-- preview Service under a derived name and domain. Previews are not recorded in
-- the production release history.
runPreviewDeploy :: SiteDeployOpts -> Text -> IO ()
runPreviewDeploy sopts pname = do
  bd <- resolveBaseDomain (sopts ^. #baseDomain)
  provisionGhcEnv (sopts ^. #ghcEnv)
  site <- loadSiteOrDie (sopts ^. #file)
  let prodName = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
  svcName <- orDie (previewServiceName prodName pname)
  pdomText <- orDie (previewDomain prodName pname bd)
  pd <- orDie (mkDomain pdomText)
  imageTag <- resolveTag (sopts ^. #tag)

  let previewSite = site & #domains .~ [pd]
      ctx = StaticDeployContext {imageTag = imageTag, previewName = Just svcName}
      ref = taggedImageRef (site ^. #image) imageTag
      nginxBytes = renderNginxConfig site
      svcBytes = renderStaticService previewSite ctx
      dmBytes = renderStaticDomainMappings previewSite ctx
      url = "https://" <> pdomText

  if sopts ^. #dryRun
    then do
      printStaticArtifacts nginxBytes svcBytes dmBytes url
      TIO.putStrLn ("Preview service: " <> svcName)
    else do
      out <- prepareOrDie (sopts ^. #skipBuild) site (sopts ^. #projectDir)
      configureDockerAuth
      withStaticImageContext site out (buildImage ref)
      pushImage ref
      applyManifests (svcBytes : dmBytes)
      waitForReady svcName ns
      TIO.putStrLn ("Deployed preview: " <> url)

-- | @site preview list@: list the site's preview Service names.
runPreviewList :: SiteCommonOpts -> IO ()
runPreviewList copts = do
  provisionGhcEnv (copts ^. #ghcEnv)
  site <- loadSiteOrDie (copts ^. #file)
  let name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
  pnames <- listPreviews name ns
  if null pnames
    then TIO.putStrLn "(no previews)"
    else mapM_ TIO.putStrLn pnames

-- | @site preview delete NAME@: remove a preview's Service and DomainMapping.
runPreviewDelete :: SiteCommonOpts -> Text -> IO ()
runPreviewDelete copts pname = do
  bd <- resolveBaseDomain (copts ^. #baseDomain)
  provisionGhcEnv (copts ^. #ghcEnv)
  site <- loadSiteOrDie (copts ^. #file)
  let prodName = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
  svcName <- orDie (previewServiceName prodName pname)
  pdomText <- orDie (previewDomain prodName pname bd)
  deletePreview ns svcName pdomText
  TIO.putStrLn ("Deleted preview: " <> svcName)

-- ---------------------------------------------------------------------------
-- Shared helpers

-- | The static site's public URL: the first configured custom domain if any,
-- otherwise the Knative wildcard @https://\<site\>.\<namespace\>.\<baseDomain\>@.
staticUrl :: StaticSite -> Text -> Text
staticUrl site baseDomain =
  case site ^. #domains of
    (d : _) -> "https://" <> domainText d
    [] ->
      "https://"
        <> siteNameText (site ^. #name)
        <> "."
        <> namespaceText (site ^. #namespace)
        <> "."
        <> baseDomain

printStaticArtifacts :: ByteString -> ByteString -> [ByteString] -> Text -> IO ()
printStaticArtifacts nginxBytes svcBytes dmBytes url = do
  BC.putStrLn "--- Generated nginx.conf ---"
  BC.putStr nginxBytes
  BC.putStrLn "--- Knative Service manifest ---"
  BC.putStr svcBytes
  forM_ dmBytes $ \dm -> do
    BC.putStrLn "--- DomainMapping manifest ---"
    BC.putStr dm
  TIO.putStrLn ("URL: " <> url)

loadSiteOrDie :: FilePath -> IO StaticSite
loadSiteOrDie file = do
  esite <- Load.loadStaticSite file
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right s -> pure s

prepareOrDie :: Bool -> StaticSite -> FilePath -> IO PreparedStaticOutput
prepareOrDie skip site root = do
  result <- prepareStaticOutput skip site root
  case result of
    Left err -> dieT (renderStaticBuildError err)
    Right p -> pure p

resolveTag :: Maybe String -> IO Text
resolveTag (Just t) = pure (T.pack t)
resolveTag Nothing = computeTag

-- | Exit with a one-line error from a pure @Either Text@ validation.
orDie :: Either Text a -> IO a
orDie = either dieT pure

-- | Print a one-line @nagarectl:@ error to stderr and exit non-zero.
dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure

-- | Resolve the apps base domain from @--base-domain@, then
-- @NAGARE_BASE_DOMAIN@, defaulting to @"apps.example.com"@.
resolveBaseDomain :: Maybe String -> IO Text
resolveBaseDomain (Just bd) = pure (T.pack bd)
resolveBaseDomain Nothing = do
  menv <- lookupEnv "NAGARE_BASE_DOMAIN"
  pure $ maybe "apps.example.com" T.pack menv

-- | If a GHC package-environment file is given (via @--ghc-env@ or
-- @NAGARE_GHC_ENVIRONMENT@), export it as @GHC_ENVIRONMENT@ (absolute) so the
-- loader's child @runghc@ resolves the @nagare-dsl@ package.
provisionGhcEnv :: Maybe FilePath -> IO ()
provisionGhcEnv mflag = do
  menv <- lookupEnv "NAGARE_GHC_ENVIRONMENT"
  case mflag <|> menv of
    Nothing -> pure ()
    Just p -> do
      abs' <- makeAbsolute p
      setEnv "GHC_ENVIRONMENT" abs'
