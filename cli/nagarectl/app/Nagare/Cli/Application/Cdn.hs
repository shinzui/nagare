-- | Application / Cdn. Executable-private CLI boundary.
module Nagare.Cli.Application.Cdn
  ( gatherGcpStackRefs
  , reviewedCdnBinding
  , serverSiteWithGeneratedEnvFor
  )
where

import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Nagare.Cdn.Provision (GcpStackRefs (GcpStackRefs))
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ProjectGuard (projectGuardInputsFor)
import Nagare.Dsl.Cdn.Types (Cdn, CdnProvider (CloudflareCdn))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Types (namespaceText)
import Nagare.Env.Generated (generatedEnv, mergeGenerated)
import Nagare.Env.Generated qualified as Gen
import Nagare.Inventory.Application
  ( CloudflareCdnBinding (CloudflareCdnBinding)
  , GoogleCdnBinding (GoogleCdnBinding)
  , ReviewedCdnBinding (..)
  )
import Nagare.Ops.ContextGuard (projectGuardVerdict)
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget, TargetProfile)
import System.Environment (lookupEnv)

serverSiteWithGeneratedEnvFor ::
  Text -> Text -> Maybe Text -> ServerSite -> Text -> Text -> ServerSite
serverSiteWithGeneratedEnvFor serviceName targetUrl source site bd tag =
  let context =
        Gen.GeneratedContext
          { Gen.serviceName = serviceName
          , Gen.namespace = namespaceText (site ^. #namespace)
          , Gen.serviceUrl = targetUrl
          , Gen.baseDomain = bd
          , Gen.releaseId = tag
          , Gen.source = source
          }
   in site & #env %~ mergeGenerated (generatedEnv context)

-- | Read the four EP-56 Google stack outputs, with a clear placeholder when an
-- output is absent (the CDN load balancer is disabled, or Pulumi is unavailable).
gatherGcpStackRefs :: FilePath -> TargetProfile -> IO GcpStackRefs
gatherGcpStackRefs pulumiDir tp = do
  let so name = fromMaybe ("<" <> name <> ">") <$> stackOutput pulumiDir name
  GcpStackRefs
    <$> so "cdnGlobalIp"
    <*> so "cdnBackendService"
    <*> so "cdnUrlMap"
    <*> so "dnsZoneName"
    <*> pure (tp ^. #project)

reviewedGoogleCdnBinding ::
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  Maybe Cdn ->
  Maybe String ->
  IO (Maybe GoogleCdnBinding)
reviewedGoogleCdnBinding active workspace snapshot intent rawBackend =
  case (intent, rawBackend) of
    (Nothing, Nothing) -> pure Nothing
    (Just _, Just rawBackendId) -> do
      guardInputs <- projectGuardInputsFor (active ^. #contextName) (active ^. #profile) workspace
      either dieT pure (projectGuardVerdict guardInputs)
      refs <- gatherGcpStackRefs (workspace ^. #pulumiDir) (active ^. #profile)
      unless
        ( all
            (not . T.isPrefixOf "<")
            [refs ^. #globalIp, refs ^. #backendService, refs ^. #dnsZone]
        )
        (dieT "reviewed CDN requires the accepted platform CDN and DNS zone stack outputs")
      backendId <- either dieT pure (Resource.mkResourceId (T.pack rawBackendId))
      let matches =
            [ ResourceInventory.Managed resource
            | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
            , bundle <- ResourceInventory.scopeBundles scope
            , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
            , resource ^. #identity == backendId
            ]
      backend <- case matches of
        [single] -> pure single
        _ -> dieT "CDN BackendService resource is absent or ambiguous in accepted inventory"
      pure (Just (GoogleCdnBinding refs backend))
    _ -> dieT "reviewed CDN intent and --cdn-backend-resource must be supplied together"

reviewedCdnBinding ::
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  Maybe Cdn ->
  Maybe String ->
  IO (Maybe ReviewedCdnBinding)
reviewedCdnBinding active workspace snapshot intent rawBackend = case intent of
  Just cdn | cdn ^. #provider == CloudflareCdn -> do
    when
      (isJust rawBackend)
      (dieT "Cloudflare CDN uses an accepted zone grant, not --cdn-backend-resource")
    guardInputs <- projectGuardInputsFor (active ^. #contextName) (active ^. #profile) workspace
    either dieT pure (projectGuardVerdict guardInputs)
    rawZone <-
      lookupEnv "CF_ZONE_ID"
        >>= maybe
          (dieT "reviewed Cloudflare CDN requires CF_ZONE_ID")
          (pure . T.pack)
    zone <- either dieT pure (Resource.mkName rawZone)
    let owners =
          [ ResourceInventory.scopeId scope
          | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
          , bundle <- ResourceInventory.scopeBundles scope
          , ResourceInventory.CloudflareZoneGrant grantedZone _ <- ResourceInventory.grants bundle
          , grantedZone == zone
          ]
    owner <- case owners of
      [single] | Resource.scopeKind single == Resource.Platform -> pure single
      _ -> dieT "Cloudflare zone must have exactly one accepted platform grant matching CF_ZONE_ID"
    originIp <-
      maybe (dieT "reviewed Cloudflare CDN requires the platform publicIp stack output") pure
        =<< stackOutput (workspace ^. #pulumiDir) "publicIp"
    unless
      (ResourceInventory.validDnsIpv4 originIp)
      (dieT "reviewed Cloudflare CDN requires an IPv4 platform publicIp stack output")
    pure (Just (CloudflareCdnBindingFor (CloudflareCdnBinding zone owner originIp)))
  _ ->
    fmap
      (fmap GoogleCdnBindingFor)
      (reviewedGoogleCdnBinding active workspace snapshot intent rawBackend)
