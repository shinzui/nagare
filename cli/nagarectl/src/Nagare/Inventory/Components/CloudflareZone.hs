-- | A tunnel context's Cloudflare resources as scope @platform:cloudflare-zone@ (ADR 34).
--
-- One remotely managed tunnel, its ingress rules, proxied apex and wildcard records to it, the zone's
-- edge policy, and a zone-wide cache bypass. None of these is per-hostname, so a redeploy makes no
-- Cloudflare call. The API token stays on the operator's machine.
module Nagare.Inventory.Components.CloudflareZone
  ( CloudflareZoneInput (..)
  , cloudflareTunnelName
  , cloudflareZoneOwner
  , compileCloudflareZone
  , connectorOrigin
  , tunnelEdgePolicy
  )
where

import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types

data CloudflareZoneInput = CloudflareZoneInput
  { zone :: !Name
  -- ^ @CF_ZONE_ID@.
  , baseDomain :: !Text
  , context :: !Text
  }
  deriving stock (Generic)

cloudflareZoneOwner :: ScopeId
cloudflareZoneOwner = either (error . T.unpack) id (mkScopeId Platform "cloudflare-zone")

cloudflareTunnelName :: Text -> Text
cloudflareTunnelName context = "nagare-" <> context

-- | The external gateway. @kourier-internal@ serves cluster-local routes and is never the origin.
connectorOrigin :: Text
connectorOrigin = "http://kourier.kourier-system.svc.cluster.local:80"

-- | The zone's edge policy. Cloudflare's defaults are a TLS 1.0 minimum and no redirect while
-- Knative serves plain HTTP, and these rewriting features would alter hosted pages.
tunnelEdgePolicy :: [(Text, Text)]
tunnelEdgePolicy =
  [ ("always_use_https", "on")
  , ("min_tls_version", "1.2")
  , ("ssl", "strict")
  , ("email_obfuscation", "off")
  , ("rocket_loader", "off")
  , ("server_side_exclude", "off")
  , ("automatic_https_rewrites", "off")
  ]

compileCloudflareZone :: CloudflareZoneInput -> Either (NonEmpty InventoryError) ScopeDeclaration
compileCloudflareZone input = do
  tunnelName <- named (mkName (cloudflareTunnelName (input ^. #context)))
  apex <- named (mkName "apex")
  wildcard <- named (mkName "wildcard")
  when
    (T.null (input ^. #baseDomain) || "*" `T.isInfixOf` (input ^. #baseDomain))
    (Left (invalid "the base domain must be the Cloudflare zone's own name" :| []))
  let tunnel = member "tunnel" (CloudflareTunnel (input ^. #zone) tunnelName) CloudflareTunnelSpec []
      afterTunnel = [OrderedAfter (tunnel ^. #identity)]
      config =
        member
          "tunnel-config"
          (CloudflareTunnelConfig (input ^. #zone) tunnelName)
          (CloudflareTunnelConfigSpec (input ^. #baseDomain) connectorOrigin)
          afterTunnel
      record key role name =
        member key (CloudflareTunnelRecord (input ^. #zone) role) (CloudflareTunnelRecordSpec name tunnelName) afterTunnel
      settings =
        [ member ("setting-" <> T.replace "_" "-" setting) (CloudflareZoneSetting (input ^. #zone) (known setting)) (CloudflareZoneSettingSpec value) []
        | (setting, value) <- tunnelEdgePolicy
        ]
      bypass = member "cache-bypass" (CloudflareRuleset (input ^. #zone)) CloudflareBypassCacheSpec []
      members =
        [tunnel, config, record "record-apex" apex (input ^. #baseDomain), record "record-wildcard" wildcard ("*." <> input ^. #baseDomain), bypass]
          <> settings
  mkScopeDeclaration cloudflareZoneOwner [ResourceBundle (map Managed (sortOn (resourceIdText . (^. #identity)) members)) [] [] [] [] []]
  where
    named = first (\reason -> invalid reason :| [])
    known = either (error . T.unpack) id . mkName
    invalid message = inventoryError "invalid-cloudflare-zone" message & #scopes .~ [cloudflareZoneOwner]
    member key address desired dependencies =
      ManagedResource
        { identity = mintResourceId cloudflareZoneOwner (either (error . T.unpack) id (mkLogicalKey key)) (known key)
        , owner = cloudflareZoneOwner
        , executor = CdnExecutor
        , address = address
        , aliases = []
        , spec = desired
        , lifecycle = Retain
        , dataPolicy = Stateless
        , sensitivity = Private
        , dependencies = dependencies
        , delegations = []
        , source = SourceLocation "context-profile" ("cloudflare-zone/" <> key)
        }
