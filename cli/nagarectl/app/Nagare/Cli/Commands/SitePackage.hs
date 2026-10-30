-- | @nagarectl site package@: write a static site's local build context or
-- Docker archive. A thin boundary over "Nagare.Static.Package"; packaging reads
-- local files only and never touches inventory, Kubernetes, gcloud or the
-- target registry.
module Nagare.Cli.Commands.SitePackage
  ( runSitePackage
  )
where

import Control.Monad (forM_, void)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Nagare.Cli.Options (SitePackageOpts)
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeProfile)
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Prelude
import Nagare.Dsl.Static.Types (StaticSite)
import Nagare.Image (qualifyImage, taggedImageRef)
import Nagare.Inventory.Store.Counters (tracePhase)
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
  , renderPackageError
  , validatePlatform
  , validateTag
  )
import Nagare.Target (TargetProfile)
import System.Directory (doesDirectoryExist, makeAbsolute)
import System.FilePath ((</>))

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
  prepared <- tracePhase "package.output" (prepareOutput options site)
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

-- | The configured output as-is, or after one run of the build command with
-- @--build@. @--output-dir@ replaces the configured directory (resolved from
-- the project directory); the build, when requested, still runs once.
prepareOutput :: SitePackageOpts -> StaticSite -> IO PreparedStaticOutput
prepareOutput options site = do
  let projectDir = options ^. #projectDir
      configured skipBuild = prepareStaticOutput skipBuild site projectDir >>= either (dieT . renderStaticBuildError) pure
  case options ^. #outputDir of
    Nothing -> configured (not (options ^. #build))
    Just override -> do
      when (options ^. #build) (void (configured False))
      absolute <- makeAbsolute (projectDir </> override)
      exists <- doesDirectoryExist absolute
      unless exists (dieT ("static output directory not found: " <> T.pack absolute))
      pure (PreparedStaticOutput absolute)

archiveTarget :: Maybe String -> SitePackageOpts -> StaticSite -> FilePath -> IO PackageTarget
archiveTarget mctx options site out = do
  profile <- activeProfile mctx
  platform <- either (dieT . renderPackageError) pure (validatePlatform (maybe (profile ^. #targetPlatform) T.pack (options ^. #platform)))
  tag <- case options ^. #tag of
    Just given -> either (dieT . renderPackageError) pure (validateTag (T.pack given))
    Nothing -> derivedTag <$> getCurrentTime
  qualified <- either (dieT . ("site package: " <>)) pure (qualifyImage profile (site ^. #image))
  pure ArchiveOut {archive = out, destination = taggedImageRef qualified tag, tag = tag, platform = platform}
