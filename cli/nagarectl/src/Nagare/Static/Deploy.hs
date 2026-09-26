-- | Pure static-site renderers used by the reviewed inventory compiler.
module Nagare.Static.Deploy
  ( DeployInputs (..)
  , StaticManifests (..)
  , productionManifests
  , previewManifests
  , staticUrl
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Static.Render
  ( StaticDeployContext (..)
  , renderNginxConfig
  , renderStaticDomainMappings
  , renderStaticService
  )
import Nagare.Dsl.Static.Types (StaticSite, siteNameText)
import Nagare.Dsl.Types (canonicalDomain, domainText, mkDomains, namespaceText)
import Nagare.Env.PreviewOverlay (withPreviewEnvFrom)
import Nagare.Static.Preview (previewDomain, previewServiceName)
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
