-- | Pure server-site renderers used by the reviewed inventory compiler.
module Nagare.Server.Deploy
  ( ServerDeployInputs (..)
  , ServerManifests (..)
  , serverManifests
  , serverPreviewManifests
  , serverUrl
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Render
  ( ServerDeployContext (..)
  , renderServerDockerfile
  , renderServerDomainMappings
  , renderServerService
  )
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Types (siteNameText)
import Nagare.Dsl.Types (canonicalDomain, domainText, mkDomains, namespaceText)
import Nagare.Env.PreviewOverlay (withPreviewEnvFrom)
import Nagare.Static.Preview (previewDomain, previewServiceName)
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
