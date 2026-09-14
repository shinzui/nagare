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
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Nagare.Cluster.Namespace (NamespacePurpose (..), ensureNamespace)
import Nagare.Deploy (applyManifests, requireWait, waitForReady)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Static.Render
  ( StaticDeployContext (..)
  , renderNginxConfig
  , renderStaticDomainMappings
  , renderStaticService
  )
import Nagare.Dsl.Static.Types (StaticSite, siteNameText)
import Nagare.Dsl.Types (canonicalDomain, domainText, imageRefText, mkDomains, namespaceText)
import Nagare.Env.PreviewOverlay (withPreviewEnvFrom)
import Nagare.Image (buildImage, configureDockerAuthFor, pushImage, taggedImageRef)
import Nagare.Static.Build (PreparedStaticOutput, prepareStaticOutput, renderStaticBuildError)
import Nagare.Static.Image (withStaticImageContext)
import Nagare.Static.Preview (previewDomain, previewServiceName)
import Nagare.Static.Release
  ( StaticRelease (..)
  , addRelease
  , readReleaseLog
  , writeReleaseLog
  )
import Nagare.Target (TargetProfile)

-- | The CLI-independent inputs to a static deploy.
data DeployInputs = DeployInputs
  { site :: !StaticSite
  , imageTag :: !Text
  , baseDomain :: !Text
  , projectDir :: !FilePath
  , skipBuild :: !Bool
  , targetProfile :: !TargetProfile
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
    , url = staticUrl s (inputs ^. #baseDomain)
    , serviceName = siteNameText (s ^. #name)
    }
  where
    s = inputs ^. #site
    ctx = StaticDeployContext {imageTag = inputs ^. #imageTag, previewName = Nothing}

-- | Render the preview artifacts for these inputs and a (raw) preview name, or a
-- 'Left' for a naming or domain failure.
previewManifests :: DeployInputs -> Text -> Either Text StaticManifests
previewManifests inputs raw = do
  let s = inputs ^. #site
      prodName = siteNameText (s ^. #name)
  svcName <- previewServiceName prodName raw
  pdomText <- previewDomain prodName raw (inputs ^. #baseDomain)
  previewDomains <- mkDomains [(pdomText, True)]
  let previewSite = s & #domains .~ previewDomains
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
  let s = inputs ^. #site
      m = productionManifests inputs
      ref = taggedImageRef (s ^. #image) (inputs ^. #imageTag)
      ns = namespaceText (s ^. #namespace)
  namespaceReady <- ensureNamespace ApplicationNamespace ns
  case namespaceReady of
    Left err -> pure (Left err)
    Right () ->
      withPreparedOutput inputs $ \out -> do
        configureDockerAuthFor (inputs ^. #targetProfile)
        withStaticImageContext s out (buildImage ref)
        pushImage ref
        applyManifests (m ^. #service : m ^. #domainMappings)
        waitForReady (m ^. #serviceName) ns
          >>= requireWait ("site '" <> m ^. #serviceName <> "'")
        recordRelease s (inputs ^. #imageTag) (m ^. #url) (m ^. #serviceName) ns src

-- | Preview deploy: same build/push path under a derived preview Service name
-- and domain; does not record a production release. Returns the preview URL or a
-- 'Left' for a naming, build-prep, or domain failure.
deployStaticPreview :: DeployInputs -> Text -> IO (Either Text Text)
deployStaticPreview inputs raw =
  case previewManifests inputs raw of
    Left e -> pure (Left e)
    Right m -> do
      let s = inputs ^. #site
          ref = taggedImageRef (s ^. #image) (inputs ^. #imageTag)
          ns = namespaceText (s ^. #namespace)
      namespaceReady <- ensureNamespace ApplicationNamespace ns
      case namespaceReady of
        Left err -> pure (Left err)
        Right () ->
          withPreparedOutput inputs $ \out -> do
            configureDockerAuthFor (inputs ^. #targetProfile)
            withStaticImageContext s out (buildImage ref)
            pushImage ref
            applyManifests (m ^. #service : m ^. #domainMappings)
            waitForReady (m ^. #serviceName) ns
              >>= requireWait ("preview site '" <> m ^. #serviceName <> "'")
            pure (Right (m ^. #url))

-- | Run the build-preparation, then @k@ if it succeeded; thread a build-prep
-- error out as @Left@.
withPreparedOutput ::
  DeployInputs -> (PreparedStaticOutput -> IO (Either Text Text)) -> IO (Either Text Text)
withPreparedOutput inputs k = do
  prep <- prepareStaticOutput (inputs ^. #skipBuild) (inputs ^. #site) (inputs ^. #projectDir)
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

-- | The static site's public URL: the explicitly canonical custom domain if any,
-- otherwise the Knative wildcard @https://\<site\>.\<namespace\>.\<baseDomain\>@.
staticUrl :: StaticSite -> Text -> Text
staticUrl s baseDomain =
  case canonicalDomain (s ^. #domains) of
    Just d -> "https://" <> domainText d
    Nothing ->
      "https://"
        <> siteNameText (s ^. #name)
        <> "."
        <> namespaceText (s ^. #namespace)
        <> "."
        <> baseDomain
