{-# LANGUAGE PackageImports #-}

-- | The @nagarectl@ deploy CLI entry point.
--
-- The deploy flow: load the typed config (EP-10's 'Load.loadDeployment'), and
-- on success render the Knative manifests (EP-9's 'renderService' /
-- 'renderDomainMapping'), build and push the image, apply the manifests, wait
-- for readiness, and print the URL. A config that fails to load prints a
-- one-line error to stderr and exits 1 before anything touches the cluster.
-- @--dry-run@ prints the rendered manifests and URL without side effects.
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
import Nagare.Dsl.Types (namespaceText, serviceNameText)
import Nagare.Image
  ( buildImage
  , computeTag
  , configureDockerAuth
  , imageRef
  , pushImage
  )

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

-- | The default config filename for the chosen substrate (EP-8: the native
-- Haskell eDSL / config-as-program). The CLI @--file@ flag always overrides.
defaultConfigFile :: FilePath
defaultConfigFile = "nagare/Config.hs"

opts :: ParserInfo DeployOpts
opts =
  info
    (subparser (command "deploy" deployCmd) <**> helper)
    ( fullDesc
        <> progDesc "nagarectl — deploy a typed Nagare app to Knative"
    )
  where
    deployCmd =
      info
        (deployOptsParser defaultConfigFile <**> helper)
        (fullDesc <> progDesc "Build, push, and deploy the app in the current directory")

-- ---------------------------------------------------------------------------
-- Main

main :: IO ()
main = execParser opts >>= runDeploy

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
