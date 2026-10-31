-- | The admin API's OpenAPI 3.1 document, derived from 'adminApi' and the
-- contract's component schemas. It is the one artifact,
-- @docs/api/openapi.json@, which the server also serves unchanged.
--
-- The derived document is enriched with what the route types cannot carry:
-- stable operation IDs, the two alternative credentials (session cookie or
-- bearer token) on every @/v1@ operation, and the problem responses the
-- access gateway produces before a request reaches the server.
module Nagare.Api.OpenApi
  ( adminOpenApi
  , renderAdminOpenApi
  , operationIds
  , gatewayStatuses
  )
where

import Data.ByteString.Lazy qualified as LBS
import Data.HashMap.Strict.InsOrd.Compat qualified as InsOrd
import Data.OpenApi
  ( ApiKeyLocation (..)
  , ApiKeyParams (..)
  , HttpSchemeType (..)
  , HttpStatusCode (..)
  , MediaTypeObject (..)
  , OpenApi
  , OpenApiType (..)
  , OpenApiTypeValue (..)
  , Reference (..)
  , Referenced (..)
  , Response
  , SecurityDefinitions (..)
  , SecurityRequirement (..)
  , SecurityScheme (..)
  , SecuritySchemeType (..)
  , components
  , content
  , description
  , get
  , headers
  , info
  , operationId
  , paths
  , responses
  , schema
  , schemas
  , security
  , securitySchemes
  , title
  , type_
  , version
  )
import Data.OpenApi.Declare (execDeclare)
import Data.Text qualified as Text
import Nagare.Api.Routes (adminApi)
import Nagare.Contract.OpenApi (contractSchemas, renderOpenApi)
import Nagare.Contract.Prelude
import Network.HTTP.Media (MediaType, (//))
import Relay.Pagination.Servant.OpenApi ()
import Servant.OpenApi (HasOpenApi (..))

adminOpenApi :: OpenApi
adminOpenApi =
  toOpenApi adminApi
    & components
    . schemas
    <>~ execDeclare contractSchemas mempty
    & components
    . securitySchemes
    .~ SecurityDefinitions credentials
    & paths
    %~ InsOrd.mapWithKey enrich
    & info
    . title
    .~ "Nagare admin API"
    & info
    . version
    .~ "1"
    & info
    . description
    ?~ "The read-only admin API of one Nagare context: recorded inventory state, never live workload health. Its components are also Nagare's versioned document contract (docs/api/README.md)."
  where
    credentials =
      InsOrd.fromList
        [ ("nagare_session", SecurityScheme (SecuritySchemeApiKey (ApiKeyParams "nagare_session" ApiKeyCookie)) (Just "A signed-in person's session cookie."))
        , ("bearer", SecurityScheme (SecuritySchemeHttp (HttpSchemeBearer Nothing)) (Just "A Shomei service-account access token."))
        ]
    enrich path item
      | "/v1/" `Text.isPrefixOf` Text.pack path = item & get . _Just %~ protected path
      | otherwise = item & get . _Just . operationId .~ lookup path operationIds
    protected path operation =
      operation
        & operationId
        .~ lookup path operationIds
        & security
        .~ [SecurityRequirement (InsOrd.singleton "nagare_session" []), SecurityRequirement (InsOrd.singleton "bearer" [])]
        & responses
        . responses
        %~ (InsOrd.mapWithKey problemTyped . addGateway)
    addGateway existing = foldr (\(code, response) -> InsOrd.insertWith (\_ kept -> kept) (StatusCode code) (Inline response)) existing gatewayResponses
    -- Servant's own rejections (a malformed parameter or header) render as
    -- problems too; the derived document lists them without content.
    problemTyped (StatusCode code) (Inline response)
      | code >= 400 && InsOrd.null (response ^. content) = Inline (response & content .~ problemContent)
    problemTyped _ response = response

-- | One stable operation ID per path; every path has a GET only.
operationIds :: [(FilePath, Text)]
operationIds =
  [ ("/v1/platform/version", "getPlatformVersion")
  , ("/v1/platform/versions", "getPlatformVersions")
  , ("/v1/inventory/head", "getInventoryHead")
  , ("/v1/inventory/scopes", "listInventoryScopes")
  , ("/v1/inventory/scopes/{scopeId}", "getInventoryScope")
  , ("/v1/inventory/publications", "listInventoryPublications")
  , ("/v1/sites", "listSites")
  , ("/v1/access/grants", "listAccessGrants")
  , ("/v1/openapi.json", "getOpenApi")
  , ("/health/live", "getLiveness")
  , ("/health/ready", "getReadiness")
  ]

-- | Statuses the gateway or the server's request handling answer for any
-- @/v1@ operation, outside its handler.
gatewayStatuses :: [Int]
gatewayStatuses = map fst gatewayResponses

gatewayResponses :: [(Int, Response)]
gatewayResponses =
  [ (401, problem "Unauthenticated: no valid session cookie or bearer token. Carries WWW-Authenticate: Bearer and a login link." & headers .~ InsOrd.singleton "WWW-Authenticate" (Inline (mempty & description ?~ "Bearer" & schema ?~ Inline (mempty & type_ ?~ OpenApiTypeSingle OpenApiString))))
  , (403, problem "Forbidden: the subject has no grant on this hostname.")
  , (405, problem "Method Not Allowed: only GET and HEAD are served. Carries Allow.")
  , (406, problem "Not Acceptable: the representation is application/json.")
  , (502, problem "Bad Gateway: the admin API is unreachable from the gateway.")
  , (503, problem "Service Unavailable: the gateway could not authorize the request, or the server is busy (Retry-After).")
  , (504, problem "Gateway Timeout: the admin API did not answer within the gateway's deadline.")
  ]
  where
    problem text =
      mempty
        & description
        .~ text
        & content
        .~ problemContent

problemContent :: InsOrd.InsOrdHashMap MediaType MediaTypeObject
problemContent =
  InsOrd.singleton
    ("application" // "problem+json")
    (MediaTypeObject (Just (Ref (Reference "ProblemDetails"))) Nothing mempty mempty)

-- | The checked-in artifact's bytes.
renderAdminOpenApi :: LBS.ByteString
renderAdminOpenApi = renderOpenApi adminOpenApi
