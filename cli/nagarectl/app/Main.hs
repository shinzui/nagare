{-# LANGUAGE PackageImports #-}

-- | The @nagarectl@ deploy CLI entry point.
--
-- Two command namespaces:
--
--   * @nagarectl deploy@ — the original app deploy: load the typed
--     'Nagare.Dsl.Types.Deployment' config, render Knative manifests, build and
--     push the image, apply, wait, and print the URL.
--   * @nagarectl site deploy@ — the static-site deploy (EP-14): load the typed
--     'Nagare.Dsl.Static.Types.StaticSite' config, render the generated Nginx
--     config and Knative manifests, package the built output into a generated
--     Nginx image, push, apply, wait, and print the URL. This command is
--     kind-dispatching by design: a later plan (EP-18) routes a @ServerSite@
--     config down a Node-image path through the same command and options.
--
-- A config that fails to load prints a one-line error to stderr and exits 1
-- before anything touches Docker or the cluster. @--dry-run@ prints the rendered
-- artifacts and URL without side effects.
module Main (main) where

import Nagare.Dsl.Prelude

import "generic-lens" Data.Generics.Labels ()

import Control.Monad (forM_)
import Data.ByteString.Char8 qualified as BC
import Data.Maybe (maybeToList)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
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
import Nagare.Dsl.Types (domainText, namespaceText, serviceNameText)
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

-- ---------------------------------------------------------------------------
-- CLI options

-- | Options for the @deploy@ subcommand. Fields are strict and unprefixed;
-- access is via generic-lens @#label@.
data DeployOpts = DeployOpts
  { file :: !FilePath
  -- ^ Path to the typed config file (default 'defaultConfigFile').
  , tag :: !(Maybe String)
  -- ^ Override the auto-computed UTC timestamp tag.
  , baseDomain :: !(Maybe String)
  -- ^ Override the apps base domain; defaults to @NAGARE_BASE_DOMAIN@, then
  -- @"apps.example.com"@.
  , context :: !FilePath
  -- ^ Docker build-context directory. Default: @"."@.
  , ghcEnv :: !(Maybe FilePath)
  -- ^ GHC package-environment file the loader's @runghc@ should use so it can
  -- resolve the @nagare-dsl@ package from an arbitrary app directory. Defaults
  -- to @NAGARE_GHC_ENVIRONMENT@. When unset, @runghc@ falls back to discovering
  -- a @.ghc.environment.*@ from the working directory (which is why running
  -- @nagarectl@ from @cli/nagarectl/@ works with no flag).
  , dryRun :: !Bool
  -- ^ When True, print rendered manifests and URL without running any external
  -- process (build/push/apply/wait).
  }
  deriving stock (Generic, Show)

-- | Options for the @site deploy@ subcommand. Shares @file@/@tag@/@baseDomain@/
-- @ghcEnv@/@dryRun@ semantics with 'DeployOpts'; adds @projectDir@ (where the
-- build runs and the output directory is resolved) and @skipBuild@.
data SiteDeployOpts = SiteDeployOpts
  { file :: !FilePath
  , tag :: !(Maybe String)
  , baseDomain :: !(Maybe String)
  , projectDir :: !FilePath
  -- ^ Project root: where the build command runs and the configured output
  -- directory is resolved. Default: @"."@.
  , ghcEnv :: !(Maybe FilePath)
  , dryRun :: !Bool
  , skipBuild :: !Bool
  -- ^ Skip running the build command (for fixtures whose output already exists).
  }
  deriving stock (Generic, Show)

-- | The two things @nagarectl@ can be asked to do.
data Command
  = Deploy DeployOpts
  | SiteDeploy SiteDeployOpts

deployOptsParser :: FilePath -> Parser DeployOpts
deployOptsParser defaultFile =
  DeployOpts
    <$> strOption
      ( long "file"
          <> short 'f'
          <> metavar "FILE"
          <> value defaultFile
          <> showDefault
          <> help "Path to the typed deployment config file"
      )
    <*> optional
      ( strOption
          ( long "tag"
              <> short 't'
              <> metavar "TAG"
              <> help "Image tag override (default: UTC timestamp YYYYMMDD-HHMMSS)"
          )
      )
    <*> optional
      ( strOption
          ( long "base-domain"
              <> metavar "DOMAIN"
              <> help "Apps base domain (overrides NAGARE_BASE_DOMAIN, default apps.example.com)"
          )
      )
    <*> strOption
      ( long "context"
          <> short 'c'
          <> metavar "DIR"
          <> value "."
          <> showDefault
          <> help "Docker build-context directory"
      )
    <*> optional
      ( strOption
          ( long "ghc-env"
              <> metavar "FILE"
              <> help "GHC package-environment file for the config loader's runghc (overrides NAGARE_GHC_ENVIRONMENT)"
          )
      )
    <*> switch
      ( long "dry-run"
          <> help "Print rendered manifests and URL without building, pushing, or applying"
      )

siteDeployOptsParser :: FilePath -> Parser SiteDeployOpts
siteDeployOptsParser defaultFile =
  SiteDeployOpts
    <$> strOption
      ( long "file"
          <> short 'f'
          <> metavar "FILE"
          <> value defaultFile
          <> showDefault
          <> help "Path to the typed static-site config file"
      )
    <*> optional
      ( strOption
          ( long "tag"
              <> short 't'
              <> metavar "TAG"
              <> help "Image tag override (default: UTC timestamp YYYYMMDD-HHMMSS)"
          )
      )
    <*> optional
      ( strOption
          ( long "base-domain"
              <> metavar "DOMAIN"
              <> help "Apps base domain (overrides NAGARE_BASE_DOMAIN, default apps.example.com)"
          )
      )
    <*> strOption
      ( long "project-dir"
          <> short 'C'
          <> metavar "DIR"
          <> value "."
          <> showDefault
          <> help "Project root: where the build runs and the output directory is resolved"
      )
    <*> optional
      ( strOption
          ( long "ghc-env"
              <> metavar "FILE"
              <> help "GHC package-environment file for the config loader's runghc (overrides NAGARE_GHC_ENVIRONMENT)"
          )
      )
    <*> switch
      ( long "dry-run"
          <> help "Print the generated Nginx config, manifests, and URL without building, pushing, or applying"
      )
    <*> switch
      ( long "skip-build"
          <> help "Do not run the build command; package the existing output directory as-is"
      )

-- | The default config filename for the chosen substrate (EP-8: the native
-- Haskell eDSL / config-as-program). The CLI @--file@ flag always overrides.
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
      subparser (command "deploy" siteDeployCmd)
    siteDeployCmd =
      info
        (SiteDeploy <$> siteDeployOptsParser defaultConfigFile <**> helper)
        (fullDesc <> progDesc "Build, package, and deploy the static site in the current directory")

-- ---------------------------------------------------------------------------
-- Main

main :: IO ()
main =
  execParser opts >>= \case
    Deploy dopts -> runDeploy dopts
    SiteDeploy sopts -> runSiteDeploy sopts

runDeploy :: DeployOpts -> IO ()
runDeploy dopts = do
  -- 1. Resolve the base domain: --base-domain > NAGARE_BASE_DOMAIN > default.
  bd <- resolveBaseDomain (dopts ^. #baseDomain)

  -- 2. Provision the GHC package environment for the loader's runghc, if asked.
  provisionGhcEnv (dopts ^. #ghcEnv)

  -- 3. Load the typed config. A Left is a fatal error.
  edep <- Load.loadDeployment (dopts ^. #file)
  dep <- case edep of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> Load.renderLoadError err)
      exitFailure
    Right d -> pure d

  -- 4. Compute the image tag.
  imageTag <- case dopts ^. #tag of
    Just t -> pure (T.pack t)
    Nothing -> computeTag

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

-- | Deploy a static site (EP-14). Loads the typed 'StaticSite', renders the
-- generated Nginx config and Knative manifests, and — unless @--dry-run@ —
-- builds the files, packages them into the generated Nginx image, pushes,
-- applies, waits, and prints the URL.
runSiteDeploy :: SiteDeployOpts -> IO ()
runSiteDeploy sopts = do
  bd <- resolveBaseDomain (sopts ^. #baseDomain)
  provisionGhcEnv (sopts ^. #ghcEnv)

  -- Kind-dispatching seam: today @site deploy@ loads a StaticSite directly. When
  -- EP-18 lands, this call becomes a `loadSite` that returns SiteStatic/SiteServer
  -- and dispatches to the Nginx or Node image path; the rest of this function is
  -- the SiteStatic branch.
  esite <- Load.loadStaticSite (sopts ^. #file)
  site <- case esite of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> Load.renderLoadError err)
      exitFailure
    Right s -> pure s

  imageTag <- case sopts ^. #tag of
    Just t -> pure (T.pack t)
    Nothing -> computeTag

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
      BC.putStrLn "--- Generated nginx.conf ---"
      BC.putStr nginxBytes
      BC.putStrLn "--- Knative Service manifest ---"
      BC.putStr svcBytes
      forM_ dmBytes $ \dm -> do
        BC.putStrLn "--- DomainMapping manifest ---"
        BC.putStr dm
      TIO.putStrLn ("URL: " <> url)
    else do
      prepared <- prepareStaticOutput (sopts ^. #skipBuild) site (sopts ^. #projectDir)
      out <- case prepared of
        Left err -> do
          TIO.hPutStrLn stderr ("nagarectl: " <> renderStaticBuildError err)
          exitFailure
        Right p -> pure p
      configureDockerAuth
      withStaticImageContext site out $ \imageCtx ->
        buildImage ref imageCtx
      pushImage ref
      applyManifests (svcBytes : dmBytes)
      waitForReady name ns
      TIO.putStrLn ("Deployed static site: " <> url)

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

-- | Resolve the apps base domain from @--base-domain@, then
-- @NAGARE_BASE_DOMAIN@, defaulting to @"apps.example.com"@.
resolveBaseDomain :: Maybe String -> IO Text
resolveBaseDomain (Just bd) = pure (T.pack bd)
resolveBaseDomain Nothing = do
  menv <- lookupEnv "NAGARE_BASE_DOMAIN"
  pure $ maybe "apps.example.com" T.pack menv

-- | If a GHC package-environment file is given (via @--ghc-env@ or
-- @NAGARE_GHC_ENVIRONMENT@), export it as @GHC_ENVIRONMENT@ (absolute) so the
-- loader's child @runghc@ resolves the @nagare-dsl@ package. If neither is set,
-- do nothing — @runghc@ then discovers a @.ghc.environment.*@ from its working
-- directory.
provisionGhcEnv :: Maybe FilePath -> IO ()
provisionGhcEnv mflag = do
  menv <- lookupEnv "NAGARE_GHC_ENVIRONMENT"
  case mflag <|> menv of
    Nothing -> pure ()
    Just p -> do
      abs' <- makeAbsolute p
      setEnv "GHC_ENVIRONMENT" abs'
