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
  , deployServerProduction
  , serverUrl
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Nagare.Deploy (applyManifests, requireWait, waitForReady)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Render
  ( ServerDeployContext (..)
  , renderServerDockerfile
  , renderServerDomainMappings
  , renderServerService
  )
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Types (siteNameText)
import Nagare.Dsl.Types (domainText, imageRefText, namespaceText)
import Nagare.Image (buildImage, configureDockerAuthFor, pushImage, taggedImageRef)
import Nagare.Server.Build (prepareServerOutput)
import Nagare.Server.Image (withServerImageContext)
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
  prep <- prepareServerOutput (inputs ^. #skipBuild) s (inputs ^. #projectDir)
  case prep of
    Left err -> pure (Left err)
    Right out -> do
      configureDockerAuthFor (targetProfile inputs)
      withServerImageContext s out (buildImage ref)
      pushImage ref
      applyManifests (m ^. #service : m ^. #domainMappings)
      waitForReady (m ^. #serviceName) ns
        >>= requireWait ("server '" <> (m ^. #serviceName) <> "'")
      recorded <-
        recordReleaseFor
          (imageRefText (s ^. #image))
          (inputs ^. #imageTag)
          (m ^. #url)
          (m ^. #serviceName)
          ns
          src
      pure (m ^. #url <$ recorded)

-- | The server site's public URL: the first configured custom domain if any,
-- otherwise the Knative wildcard @https://\<site\>.\<namespace\>.\<baseDomain\>@.
serverUrl :: ServerSite -> Text -> Text
serverUrl s baseDomain =
  case s ^. #domains of
    (d : _) -> "https://" <> domainText d
    [] ->
      "https://"
        <> siteNameText (s ^. #name)
        <> "."
        <> namespaceText (s ^. #namespace)
        <> "."
        <> baseDomain
