-- | The reusable static-deploy effects, factored out of the CLI (EP-16
-- Milestone 1) so both @nagarectl site deploy@ and the @nagared@ webhook runner
-- drive the exact same path — load is the caller's job; these functions take a
-- fully-resolved 'StaticSite' plus explicit inputs and perform the
-- prepare → build → push → apply → wait (→ record) effect.
--
-- The rendering ('productionManifests' / 'previewManifests') is split from the
-- effect so the CLI @--dry-run@ and the actual deploy derive identical artifacts.
-- A build-preparation failure is returned as @Left@; Docker/@kubectl@ failures
-- propagate as exceptions for the caller to catch.
module Nagare.Static.Deploy
  ( DeployInputs (..)
  , StaticManifests (..)
  , productionManifests
  , previewManifests
  , deployStaticProduction
  , deployStaticPreview
  , staticUrl
  ) where

import Nagare.Dsl.Prelude

import Data.Generics.Labels ()

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Nagare.Deploy (applyManifests, waitForReady)
import Nagare.Dsl.Static.Render
  ( StaticDeployContext (..)
  , renderNginxConfig
  , renderStaticDomainMappings
  , renderStaticService
  )
import Nagare.Dsl.Static.Types (StaticSite, siteNameText)
import Nagare.Dsl.Types (domainText, imageRefText, mkDomain, namespaceText)
import Nagare.Env.PreviewOverlay (withPreviewEnvFrom)
import Nagare.Image (buildImage, configureDockerAuth, pushImage, taggedImageRef)
import Nagare.Static.Build (PreparedStaticOutput, prepareStaticOutput, renderStaticBuildError)
import Nagare.Static.Image (withStaticImageContext)
import Nagare.Static.Preview (previewDomain, previewServiceName)
import Nagare.Static.Release
  ( StaticRelease (..)
  , addRelease
  , readReleaseLog
  , writeReleaseLog
  )

-- | The CLI-independent inputs to a static deploy.
data DeployInputs = DeployInputs
  { site :: !StaticSite
  , imageTag :: !Text
  , baseDomain :: !Text
  , projectDir :: !FilePath
  , skipBuild :: !Bool
  }
  deriving stock (Generic)

-- | The rendered artifacts for one (production or preview) deploy.
data StaticManifests = StaticManifests
  { nginxConf :: !ByteString
  , service :: !ByteString
  , domainMappings :: ![ByteString]
  , url :: !Text
  , serviceName :: !Text
  }
  deriving stock (Generic)

-- | Render the production artifacts for these inputs.
productionManifests :: DeployInputs -> StaticManifests
productionManifests inputs =
  StaticManifests
    { nginxConf = renderNginxConfig s
    , service = renderStaticService s ctx
    , domainMappings = renderStaticDomainMappings s ctx
    , url = staticUrl s (baseDomain inputs)
    , serviceName = siteNameText (s ^. #name)
    }
  where
    s = site inputs
    ctx = StaticDeployContext {imageTag = inputs ^. #imageTag, previewName = Nothing}

-- | Render the preview artifacts for these inputs and a (raw) preview name, or a
-- 'Left' for a naming or domain failure.
previewManifests :: DeployInputs -> Text -> Either Text StaticManifests
previewManifests inputs raw = do
  let s = site inputs
      prodName = siteNameText (s ^. #name)
  svcName <- previewServiceName prodName raw
  pdomText <- previewDomain prodName raw (baseDomain inputs)
  pd <- mkDomain pdomText
  let previewSite = s & #domains .~ [pd]
      ctx = StaticDeployContext {imageTag = inputs ^. #imageTag, previewName = Just svcName}
  Right
    StaticManifests
      { nginxConf = renderNginxConfig s
      , -- EP-27 M2: overlay the preview env onto the rendered Service, keyed by the
        -- production name (preview env is shared across all previews of one app).
        service = withPreviewEnvFrom prodName (renderStaticService previewSite ctx)
      , domainMappings = renderStaticDomainMappings previewSite ctx
      , url = "https://" <> pdomText
      , serviceName = svcName
      }

-- | Production deploy: prepare the output, package and push the Nginx image,
-- apply the production Service + DomainMappings, wait for readiness, and record
-- a release. Returns the live URL, or a 'Left' for a build-prep failure or an
-- unrecordable (malformed) release history.
deployStaticProduction :: DeployInputs -> Maybe Text -> IO (Either Text Text)
deployStaticProduction inputs src = do
  let s = site inputs
      m = productionManifests inputs
      ref = taggedImageRef (s ^. #image) (inputs ^. #imageTag)
      ns = namespaceText (s ^. #namespace)
  withPreparedOutput inputs $ \out -> do
    configureDockerAuth
    withStaticImageContext s out (buildImage ref)
    pushImage ref
    applyManifests (service m : domainMappings m)
    waitForReady (serviceName m) ns
    recordRelease s (inputs ^. #imageTag) (m ^. #url) (serviceName m) ns src

-- | Preview deploy: same build/push path under a derived preview Service name
-- and domain; does not record a production release. Returns the preview URL or a
-- 'Left' for a naming, build-prep, or domain failure.
deployStaticPreview :: DeployInputs -> Text -> IO (Either Text Text)
deployStaticPreview inputs raw =
  case previewManifests inputs raw of
    Left e -> pure (Left e)
    Right m -> do
      let s = site inputs
          ref = taggedImageRef (s ^. #image) (inputs ^. #imageTag)
          ns = namespaceText (s ^. #namespace)
      withPreparedOutput inputs $ \out -> do
        configureDockerAuth
        withStaticImageContext s out (buildImage ref)
        pushImage ref
        applyManifests (service m : domainMappings m)
        waitForReady (serviceName m) ns
        pure (Right (m ^. #url))

-- | Run the build-preparation, then @k@ if it succeeded; thread a build-prep
-- error out as @Left@.
withPreparedOutput ::
  DeployInputs -> (PreparedStaticOutput -> IO (Either Text Text)) -> IO (Either Text Text)
withPreparedOutput inputs k = do
  prep <- prepareStaticOutput (skipBuild inputs) (site inputs) (projectDir inputs)
  case prep of
    Left err -> pure (Left (renderStaticBuildError err))
    Right out -> k out

-- | Record a release after a successful production deploy. A malformed existing
-- history is reported (and not overwritten) as @Left@; success returns the URL.
recordRelease :: StaticSite -> Text -> Text -> Text -> Text -> Maybe Text -> IO (Either Text Text)
recordRelease s tag siteUrl name ns src = do
  now <- getCurrentTime
  let rel =
        StaticRelease
          { releaseId = tag
          , siteName = name
          , namespace = ns
          , image = imageRefText (s ^. #image)
          , imageTag = tag
          , url = siteUrl
          , source = src
          , createdAt = now
          }
  elog <- readReleaseLog name ns
  case elog of
    Left err ->
      pure (Left ("deploy succeeded but release history is unreadable (not overwritten): " <> err))
    Right logv -> do
      writeReleaseLog name ns (addRelease rel logv)
      pure (Right siteUrl)

-- | The static site's public URL: the first configured custom domain if any,
-- otherwise the Knative wildcard @https://\<site\>.\<namespace\>.\<baseDomain\>@.
staticUrl :: StaticSite -> Text -> Text
staticUrl s baseDomain =
  case s ^. #domains of
    (d : _) -> "https://" <> domainText d
    [] ->
      "https://"
        <> siteNameText (s ^. #name)
        <> "."
        <> namespaceText (s ^. #namespace)
        <> "."
        <> baseDomain
