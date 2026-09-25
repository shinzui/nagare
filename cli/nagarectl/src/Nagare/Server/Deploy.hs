-- | The server-site deploy effects (EP-18), parallel to 'Nagare.Static.Deploy'.
--
-- Build → package into a Node image → push → apply the Knative Service +
-- DomainMappings → wait → record a release. The release record is the
-- runtime-agnostic one EP-15 defines ('Nagare.Static.Release.recordReleaseFor'),
-- so server releases list and roll back through the same history as static ones.
-- Rendering ('serverManifests') is split from the effect so the CLI dry-run and
-- the real deploy derive identical artifacts.
module Nagare.Server.Deploy
  ( ServerDeployInputs (..)
  , ServerManifests (..)
  , serverManifests
  , serverPreviewManifests
  , deployServerProduction
  , serverUrl
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Nagare.Cluster.Namespace (NamespacePurpose (..), ensureNamespace)
import Nagare.Deploy (applyManifests, requireWait, waitForReady)
import Nagare.Domain.Binding (BindingTarget (..), preflightDomainBindings, waitForDomainBindings)
import Nagare.Domain.Tls (preflightDomainTls, verifyDomainTlsReady)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Render
  ( ServerDeployContext (..)
  , renderServerDockerfile
  , renderServerDomainMappings
  , renderServerService
  )
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Types (siteNameText)
import Nagare.Dsl.Types (canonicalDomain, domainText, imageRefText, mkDomains, namespaceText)
import Nagare.Env.PreviewOverlay (withPreviewEnvFrom)
import Nagare.Image (buildImage, configureDockerAuthFor, pushImage, taggedImageRef)
import Nagare.Server.Build (prepareServerOutput)
import Nagare.Server.Image (withServerImageContext)
import Nagare.Static.Preview (previewDomain, previewServiceName)
import Nagare.Static.Release (recordReleaseFor)
import Nagare.Target (TargetProfile)

-- | The CLI-independent inputs to a server deploy.
data ServerDeployInputs = ServerDeployInputs
  { site :: !ServerSite
  , imageTag :: !Text
  , baseDomain :: !Text
  , projectDir :: !FilePath
  , skipBuild :: !Bool
  , targetProfile :: !TargetProfile
  }
  deriving stock (Generic)

-- | The rendered artifacts for a server deploy.
data ServerManifests = ServerManifests
  { dockerfile :: !Text
  , service :: !ByteString
  , domainMappings :: ![ByteString]
  , url :: !Text
  , serviceName :: !Text
  }
  deriving stock (Generic)

-- | Render the production artifacts for these inputs.
serverManifests :: ServerDeployInputs -> ServerManifests
serverManifests inputs =
  ServerManifests
    { dockerfile = renderServerDockerfile s
    , service = renderServerService s ctx
    , domainMappings = renderServerDomainMappings s ctx
    , url = serverUrl s (inputs ^. #baseDomain)
    , serviceName = siteNameText (s ^. #name)
    }
  where
    s = inputs ^. #site
    ctx = ServerDeployContext {imageTag = inputs ^. #imageTag, previewName = Nothing}

-- | Render a server preview under a derived Service and automatic-TLS domain.
-- The same Runtime/Preview overlay references as static previews are included
-- in the Service bytes for reviewed dependency binding.
serverPreviewManifests :: ServerDeployInputs -> Text -> Either Text ServerManifests
serverPreviewManifests inputs raw = do
  let s = inputs ^. #site
      prodName = siteNameText (s ^. #name)
  svcName <- previewServiceName prodName raw
  host <- previewDomain prodName raw (inputs ^. #baseDomain)
  previewDomains <- mkDomains [(host, True)]
  let previewSite = s & #domains .~ previewDomains
      ctx = ServerDeployContext {imageTag = inputs ^. #imageTag, previewName = Just svcName}
  pure ServerManifests
    { dockerfile = renderServerDockerfile s
    , service = withPreviewEnvFrom prodName (renderServerService previewSite ctx)
    , domainMappings = renderServerDomainMappings previewSite ctx
    , url = "https://" <> host
    , serviceName = svcName
    }

-- | Production deploy: prepare the output, package and push the Node image,
-- apply the Service + DomainMappings, wait for readiness, and record a release.
-- Returns the live URL, or a 'Left' for a build-prep failure or an unrecordable
-- release history.
deployServerProduction :: ServerDeployInputs -> Maybe Text -> IO (Either Text Text)
deployServerProduction inputs src = do
  let s = inputs ^. #site
      m = serverManifests inputs
      ref = taggedImageRef (s ^. #image) (inputs ^. #imageTag)
      ns = namespaceText (s ^. #namespace)
  namespaceReady <- ensureNamespace ApplicationNamespace ns
  case namespaceReady of
    Left err -> pure (Left err)
    Right () -> do
      prep <- prepareServerOutput (inputs ^. #skipBuild) s (inputs ^. #projectDir)
      case prep of
        Left err -> pure (Left err)
        Right out -> do
          configureDockerAuthFor (inputs ^. #targetProfile)
          withServerImageContext s out (buildImage ref)
          pushImage ref
          let targets = bindingTargets s (m ^. #serviceName) ns
          checked <- preflightDomainBindings targets
          case checked of
            Left err -> pure (Left err)
            Right () -> do
              tlsChecked <- preflightDomainTls (inputs ^. #targetProfile) (inputs ^. #baseDomain) ns (s ^. #domains)
              case tlsChecked of
                Left err -> pure (Left err)
                Right () -> do
                  applyManifests (m ^. #service : m ^. #domainMappings)
                  waitForReady (m ^. #serviceName) ns
                    >>= requireWait ("server '" <> (m ^. #serviceName) <> "'")
                  domainsReady <- waitForDomainBindings 300 targets
                  case domainsReady of
                    Left err -> pure (Left err)
                    Right () -> do
                      tlsReady <- verifyDomainTlsReady (inputs ^. #targetProfile) (inputs ^. #baseDomain) ns (s ^. #domains)
                      case tlsReady of
                        Left err -> pure (Left err)
                        Right () -> do
                          recorded <-
                            recordReleaseFor
                              (imageRefText (s ^. #image))
                              (inputs ^. #imageTag)
                              (m ^. #url)
                              (m ^. #serviceName)
                              ns
                              src
                          pure (m ^. #url <$ recorded)

-- | The server site's public URL: the explicitly canonical custom domain if any,
-- otherwise the Knative wildcard @https://\<site\>.\<namespace\>.\<baseDomain\>@.
serverUrl :: ServerSite -> Text -> Text
serverUrl s baseDomain =
  case canonicalDomain (s ^. #domains) of
    Just d -> "https://" <> domainText d
    Nothing ->
      "https://"
        <> siteNameText (s ^. #name)
        <> "."
        <> namespaceText (s ^. #namespace)
        <> "."
        <> baseDomain

bindingTargets :: ServerSite -> Text -> Text -> [BindingTarget]
bindingTargets site serviceName namespace =
  [ BindingTarget
      { host = domainText (domainSpec ^. #domain)
      , namespace = namespace
      , service = serviceName
      }
  | domainSpec <- site ^. #domains
  ]
