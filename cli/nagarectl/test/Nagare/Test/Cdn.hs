-- | Cdn responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Cdn
  ( cdnProvisionTests
  , cdnStatusTests
  , cloudflareTests
  )
where

import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft, isRight)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Cdn.Cloudflare
  ( OriginTlsMode (Flexible, Full, FullStrict)
  , buildCacheRulesPayload
  , buildComposedCacheRulesPayload
  , buildPurgePayload
  , buildUpsertRecordPayload
  , parseDnsRecordId
  , parseEnvelopeUnit
  , parseExactARecordListing
  , parseZoneId
  , sslModeToken
  , zoneNameFromHostname
  )
import Nagare.Cdn.Provision
  ( CdnAction (DnsReference, DnsUpsert)
  , CdnTarget (CdnTarget)
  , GcpDnsState (DnsAbsent, DnsConflict, DnsCurrent)
  , GcpStackRefs (GcpStackRefs)
  , classifyGcpDnsRecord
  , gcloudDnsCreateArgs
  , gcloudDnsListArgs
  , googleCdnHostname
  , planCdn
  , renderCdnPlan
  )
import Nagare.Cdn.Status
  ( CdnDnsTarget (PointsAtEdge, PointsAtVm)
  , CdnRow (CdnRow)
  , formatCdnList
  , formatCdnStatus
  , formatCertificateManagerStatus
  , parseCertificateManagerState
  )
import Nagare.Dsl.Cdn.Types
  ( Cdn
      ( Cdn
      , cacheRules
      , cacheStaticAssets
      , defaultTtlSeconds
      , provider
      )
  , CdnCacheRule (CdnCacheRule)
  , CdnProvider (CloudflareCdn, GcpCloudCdn)
  )
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Resource.Inventory qualified as InventoryModel
import Nagare.Resource.Types qualified as Resource
import Nagare.Test.Support.Assertions (unsafe)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Nagare.Cdn (MasterPlan 11, EP-57): the pure Cloudflare request-builders and
-- envelope parsers, asserted byte-exactly (compared as decoded Values so key
-- order is irrelevant).

cloudflareTests :: [TestTree]
cloudflareTests =
  [ testCase "buildCacheRulesPayload: default + /assets/ + never-cache /api/ + static" $
      buildCacheRulesPayload "blog.example.com" cdnFixture @?= expectedCacheRules
  , testCase "composed Cloudflare rules keep both hosts and stable precedence" $ do
      let named = either (error . T.unpack) id . Resource.mkName
          firstIntent =
            InventoryModel.CloudflareCacheIntent
              (named "a.example.com")
              (Just 300)
              False
              [("/api/", Nothing)]
          secondIntent =
            InventoryModel.CloudflareCacheIntent
              (named "b.example.com")
              (Just 600)
              True
              []
          expected =
            Aeson.object
              [ "rules"
                  Aeson..= [ ruleObj "(http.host eq \"a.example.com\")" (ttlParams 300)
                           , ruleObj "(http.host eq \"a.example.com\") and starts_with(http.request.uri.path, \"/api/\")" bypassParams
                           , ruleObj "(http.host eq \"b.example.com\")" (ttlParams 600)
                           , ruleObj "(http.host eq \"b.example.com\") and (http.request.uri.path.extension in {\"js\" \"css\" \"woff2\" \"woff\" \"png\" \"jpg\" \"jpeg\" \"gif\" \"svg\" \"webp\" \"ico\"})" (ttlParams 31536000)
                           ]
              ]
      buildComposedCacheRulesPayload [secondIntent, firstIntent] @?= expected
      buildComposedCacheRulesPayload [firstIntent, secondIntent] @?= expected
  , testCase "Cloudflare paths keep declared priority and escape filter literals" $ do
      let named = either (error . T.unpack) id . Resource.mkName
          intent =
            InventoryModel.CloudflareCacheIntent
              (named "a.example.com")
              (Just 300)
              False
              [("/api/\" or true", Nothing), ("/api/", Just 60)]
          expression = "(http.host eq \"a.example.com\") and starts_with(http.request.uri.path, \"/api/\\\" or true\")"
      buildComposedCacheRulesPayload [intent]
        @?= Aeson.object
          [ "rules"
              Aeson..= [ ruleObj "(http.host eq \"a.example.com\")" (ttlParams 300)
                       , ruleObj "(http.host eq \"a.example.com\") and starts_with(http.request.uri.path, \"/api/\")" (ttlParams 60)
                       , ruleObj expression bypassParams
                       ]
          ]
  , testCase "buildUpsertRecordPayload: proxied A record" $
      buildUpsertRecordPayload "blog.example.com" "34.105.10.20"
        @?= Aeson.object
          [ "type" Aeson..= ("A" :: Text)
          , "name" Aeson..= ("blog.example.com" :: Text)
          , "content" Aeson..= ("34.105.10.20" :: Text)
          , "proxied" Aeson..= True
          , "ttl" Aeson..= (1 :: Int)
          ]
  , testCase "sslModeToken: flexible/full/strict" $ do
      sslModeToken Flexible @?= "flexible"
      sslModeToken Full @?= "full"
      sslModeToken FullStrict @?= "strict"
  , testCase "buildPurgePayload: only selected host when no paths" $
      buildPurgePayload "blog.example.com" []
        @?= Aeson.object ["hosts" Aeson..= (["blog.example.com"] :: [Text])]
  , testCase "buildPurgePayload: purge specific URLs" $
      buildPurgePayload "blog.example.com" ["/assets/app.css", "/"]
        @?= Aeson.object
          [ "files"
              Aeson..= ( [ "https://blog.example.com/assets/app.css"
                         , "https://blog.example.com/"
                         ] ::
                           [Text]
                       )
          ]
  , testCase "zoneNameFromHostname: registrable domain" $ do
      zoneNameFromHostname "blog.example.com" @?= "example.com"
      zoneNameFromHostname "example.com" @?= "example.com"
      zoneNameFromHostname "a.b.example.com." @?= "example.com"
  , testCase "parseEnvelopeUnit: success:true -> Right ()" $
      parseEnvelopeUnit "{\"success\":true,\"errors\":[],\"result\":{}}" @?= Right ()
  , testCase "parseEnvelopeUnit: success:false -> Left message" $
      parseEnvelopeUnit
        "{\"success\":false,\"errors\":[{\"code\":9109,\"message\":\"Invalid access token\"}]}"
        @?= Left "Invalid access token"
  , testCase "parseZoneId: result[0].id from a zone list" $
      parseZoneId "{\"success\":true,\"result\":[{\"id\":\"zone1\",\"name\":\"example.com\"}]}"
        @?= Just "zone1"
  , testCase "parseDnsRecordId: result[0].id from a record list (find)" $
      parseDnsRecordId "{\"success\":true,\"result\":[{\"id\":\"rec1\"}]}"
        @?= Just "rec1"
  , testCase "parseDnsRecordId: result.id from a single-object response (create)" $
      parseDnsRecordId "{\"success\":true,\"result\":{\"id\":\"rec2\"}}"
        @?= Just "rec2"
  , testCase "Cloudflare exact A listing distinguishes absence from provider failure" $ do
      parseExactARecordListing
        "blog.example.com"
        "{\"success\":true,\"result\":[],\"result_info\":{\"count\":0,\"page\":1}}"
        @?= Right Nothing
      assertBool
        "provider failure cannot prove DNS absence"
        ( isLeft
            ( parseExactARecordListing
                "blog.example.com"
                "{\"success\":false,\"errors\":[{\"message\":\"denied\"}],\"result\":[]}"
            )
        )
      assertBool
        "missing result array cannot prove DNS absence"
        ( isLeft
            (parseExactARecordListing "blog.example.com" "{\"success\":true}")
        )
      assertBool
        "missing pagination cannot prove DNS absence"
        ( isLeft
            ( parseExactARecordListing
                "blog.example.com"
                "{\"success\":true,\"result\":[]}"
            )
        )
  , testCase "Cloudflare exact A listing requires one matching record and physical ID" $ do
      let record = "{\"id\":\"rec1\",\"name\":\"blog.example.com\",\"type\":\"A\",\"content\":\"203.0.113.4\",\"proxied\":true,\"ttl\":1}"
      parseExactARecordListing
        "blog.example.com"
        ("{\"success\":true,\"result\":[" <> record <> "],\"result_info\":{\"count\":1,\"page\":1}}")
        @?= Right (Just ("rec1", "203.0.113.4", True, 1))
      assertBool
        "multiple A records must refuse"
        ( isLeft
            ( parseExactARecordListing
                "blog.example.com"
                ("{\"success\":true,\"result\":[" <> record <> "," <> record <> "]}")
            )
        )
      assertBool
        "a different exact name must refuse"
        ( isLeft
            ( parseExactARecordListing
                "other.example.com"
                ("{\"success\":true,\"result\":[" <> record <> "]}")
            )
        )
      assertBool
        "inconsistent pagination count must refuse"
        ( isLeft
            ( parseExactARecordListing
                "blog.example.com"
                ("{\"success\":true,\"result\":[" <> record <> "],\"result_info\":{\"count\":0,\"page\":1}}")
            )
        )
  ]
  where
    cdnFixture =
      Cdn
        { provider = CloudflareCdn
        , defaultTtlSeconds = Just 3600
        , cacheStaticAssets = True
        , cacheRules =
            [ CdnCacheRule "/assets/" (Just 31536000)
            , CdnCacheRule "/api/" Nothing
            ]
        }

    ttlParams ttl =
      Aeson.object
        [ "cache" Aeson..= True
        , "edge_ttl"
            Aeson..= Aeson.object
              [ "mode" Aeson..= ("override_origin" :: Text)
              , "default" Aeson..= (ttl :: Int)
              ]
        ]
    bypassParams = Aeson.object ["cache" Aeson..= False]
    ruleObj expr params =
      Aeson.object
        [ "expression" Aeson..= (expr :: Text)
        , "action" Aeson..= ("set_cache_settings" :: Text)
        , "action_parameters" Aeson..= params
        ]

    expectedCacheRules =
      Aeson.object
        [ "rules"
            Aeson..= [ ruleObj
                         "(http.host eq \"blog.example.com\")"
                         (ttlParams 3600)
                     , ruleObj
                         "(http.host eq \"blog.example.com\") and (http.request.uri.path.extension in {\"js\" \"css\" \"woff2\" \"woff\" \"png\" \"jpg\" \"jpeg\" \"gif\" \"svg\" \"webp\" \"ico\"})"
                         (ttlParams 31536000)
                     , ruleObj
                         "(http.host eq \"blog.example.com\") and starts_with(http.request.uri.path, \"/api/\")"
                         bypassParams
                     , ruleObj
                         "(http.host eq \"blog.example.com\") and starts_with(http.request.uri.path, \"/assets/\")"
                         (ttlParams 31536000)
                     ]
        ]

-- ---------------------------------------------------------------------------
-- Nagare.Cdn.Provision (MasterPlan 11, EP-58): the pure deploy-time planner,
-- the gcloud-arg builders, and the dry-run renderer.

cdnProvisionTests :: [TestTree]
cdnProvisionTests =
  [ testCase "planCdn Cloudflare: DNS/OriginTls/Cache actions" $ do
      let p = unsafe (planCdn cfCdn cfTarget noRefs)
      p ^. #provider @?= CloudflareCdn
      assertBool "one DnsUpsert per host" (length [() | DnsUpsert {} <- p ^. #actions] == 1)
  , testCase "planCdn Gcp: DNS only; the Pulumi owner keeps backend policy" $ do
      let p = unsafe (planCdn gcpCdn gcpTarget gcpRefs)
      p ^. #provider @?= GcpCloudCdn
      p ^. #actions @?= [DnsUpsert "app.apps.example.com" "203.0.113.20" "Cloud DNS A-record"]
      assertBool
        "per-site TTL refuses"
        ( isLeft
            ( planCdn
                (gcpCdn & #defaultTtlSeconds .~ Just 3600)
                gcpTarget
                gcpRefs
            )
        )
      assertBool
        "per-site cache mode refuses"
        ( isLeft
            ( planCdn
                (gcpCdn & #cacheStaticAssets .~ False)
                gcpTarget
                gcpRefs
            )
        )
      assertBool
        "per-site path rule refuses"
        ( isLeft
            ( planCdn
                (gcpCdn & #cacheRules .~ [CdnCacheRule "/assets/" (Just 300)])
                gcpTarget
                gcpRefs
            )
        )
  , testCase "Google CDN accepts only apex and one-label base-domain hosts" $ do
      googleCdnHostname "apps.example.com" "apps.example.com" @?= Right ()
      googleCdnHostname "apps.example.com" "www.apps.example.com" @?= Right ()
      assertBool "nested host rejected" (isLeft (googleCdnHostname "apps.example.com" "deep.www.apps.example.com"))
      assertBool "unrelated host rejected" (isLeft (googleCdnHostname "apps.example.com" "www.example.net"))
      assertBool
        "Cloudflare remains unrestricted"
        (isRight (planCdn cfCdn (cfTarget & #hostnames .~ ["deep.unrelated.example.net"]) noRefs))
  , testCase "Google apex CDN uses the Pulumi-owned DNS record without writing it" $ do
      let target = gcpTarget & #hostnames .~ ["apps.example.com", "app.apps.example.com"]
          plan = unsafe (planCdn gcpCdn target gcpRefs)
      plan ^. #actions
        @?= [ DnsReference "apps.example.com" "203.0.113.20"
            , DnsUpsert "app.apps.example.com" "203.0.113.20" "Cloud DNS A-record"
            ]
      assertBool
        "apex is a reference in the public review"
        ("Pulumi-owned reference; no write" `T.isInfixOf` renderCdnPlan plan)
  , testCase "gcloudDnsListArgs: exact project and hostname read before mutation" $
      gcloudDnsListArgs "tan-nb-exp" "nagare-zone" "app.example.com"
        @?= [ "dns"
            , "record-sets"
            , "list"
            , "--name=app.example.com."
            , "--type=A"
            , "--zone=nagare-zone"
            , "--format=json"
            , "--project=tan-nb-exp"
            ]
  , testCase "direct Google DNS treats only a successful empty listing as absence" $ do
      classifyGcpDnsRecord "app.example.com" "203.0.113.20" "[]" @?= Right DnsAbsent
      let record ip ttl =
            BC.pack
              ( "[{\"name\":\"app.example.com.\",\"type\":\"A\",\"ttl\":"
                  <> show ttl
                  <> ",\"rrdatas\":[\""
                  <> ip
                  <> "\"]}]"
              )
      classifyGcpDnsRecord "app.example.com" "203.0.113.20" (record "203.0.113.20" (300 :: Int))
        @?= Right DnsCurrent
      classifyGcpDnsRecord "app.example.com" "203.0.113.20" (record "203.0.113.10" (300 :: Int))
        @?= Right DnsConflict
      classifyGcpDnsRecord "app.example.com" "203.0.113.20" (record "203.0.113.20" (600 :: Int))
        @?= Right DnsConflict
      assertBool
        "a failed or malformed listing never proves absence"
        (isLeft (classifyGcpDnsRecord "app.example.com" "203.0.113.20" "not found"))
      assertBool
        "a wrong hostname never proves absence"
        (isLeft (classifyGcpDnsRecord "other.example.com" "203.0.113.20" (record "203.0.113.20" (300 :: Int))))
  , testCase "Cloud DNS read and create operations are project-pinned" $
      forM_
        [ gcloudDnsListArgs "acme-prod" "z" "h"
        , gcloudDnsCreateArgs "acme-prod" "z" "h" "ip"
        ]
        (assertBool "--project follows the supplied project" . elem "--project=acme-prod")
  , testCase "renderCdnPlan: Cloudflare dry-run block" $
      renderCdnPlan (unsafe (planCdn cfCdn cfTarget noRefs))
        @?= T.unlines
          [ "--- CDN plan (Cloudflare) ---"
          , "DNS: blog.example.com -> 203.0.113.10 (proxied)"
          , "Origin TLS: Flexible"
          , "Cache: /assets/ -> 31536000s"
          , "Cache: /api/ -> never"
          , "Cache: (default) -> 3600s"
          ]
  , testCase "renderCdnPlan: Google dry-run contains only the DNS effect" $
      renderCdnPlan (unsafe (planCdn gcpCdn gcpTarget gcpRefs))
        @?= T.unlines
          [ "--- CDN plan (GcpCloudCdn) ---"
          , "DNS: app.apps.example.com -> 203.0.113.20 (Cloud DNS A-record)"
          ]
  ]
  where
    cfCdn =
      Cdn
        { provider = CloudflareCdn
        , defaultTtlSeconds = Just 3600
        , cacheStaticAssets = False
        , cacheRules = [CdnCacheRule "/assets/" (Just 31536000), CdnCacheRule "/api/" Nothing]
        }
    cfTarget = CdnTarget ["blog.example.com"] "203.0.113.10" "personal" "blog" "apps.example.com"
    gcpCdn =
      Cdn
        { provider = GcpCloudCdn
        , defaultTtlSeconds = Nothing
        , cacheStaticAssets = True
        , cacheRules = []
        }
    gcpTarget = CdnTarget ["app.apps.example.com"] "203.0.113.20" "personal" "app" "apps.example.com"
    gcpRefs = GcpStackRefs "203.0.113.20" "nagare-cdn-backend" "nagare-cdn-urlmap" "nagare-zone" "tan-nb-exp"
    noRefs = GcpStackRefs "" "" "" "" "tan-nb-exp"

-- ---------------------------------------------------------------------------
-- Nagare.Cdn.Status (EP-58): the cdn list/status formatters.

cdnStatusTests :: [TestTree]
cdnStatusTests =
  [ testCase "formatCdnList []: empty sentinel" $
      formatCdnList [] @?= "(no CDN-fronted hostnames)\n"
  , testCase "formatCdnList: header + edge/VM rows are present and aligned" $ do
      let out = formatCdnList [edgeRow, vmRow]
      assertBool "HOST header" ("HOST" `T.isInfixOf` out)
      assertBool "edge host" ("blog.example.com" `T.isInfixOf` out)
      assertBool "points at edge" ("points at edge (203.0.113.30)" `T.isInfixOf` out)
      assertBool "points at VM" ("points at VM (203.0.113.10)" `T.isInfixOf` out)
  , testCase "formatCdnStatus: one host's field block" $
      formatCdnStatus edgeRow
        @?= T.unlines
          [ "Host:     blog.example.com"
          , "Provider: Cloudflare"
          , "DNS:      points at edge (203.0.113.30)"
          , "Cache:    default 3600s, 2 rules"
          , "Ready:    ready"
          ]
  , testCase "Certificate Manager status parser reads the managed lifecycle" $
      parseCertificateManagerState "{\"managed\":{\"state\":\"ACTIVE\"}}" @?= Right "ACTIVE"
  , testCase "certificate-map activation is printed only for an ACTIVE prepared certificate" $ do
      let command = "pulumi -C /payload/infra/pulumi config set --stack prod nagare:cdnCertificateMode certificate-map"
          active = formatCertificateManagerStatus "nagare-cdn" "prepare" "ACTIVE" command
          pending = formatCertificateManagerStatus "nagare-cdn" "prepare" "PROVISIONING" command
      assertBool "active has exact command" (command `T.isInfixOf` active)
      assertBool "pending has no command" (not (command `T.isInfixOf` pending))
  ]
  where
    edgeRow = CdnRow "blog.example.com" "Cloudflare" (PointsAtEdge "203.0.113.30") "default 3600s, 2 rules" True
    vmRow = CdnRow "old.example.com" "GcpCloudCdn" (PointsAtVm "203.0.113.10") "default 3600s" False
