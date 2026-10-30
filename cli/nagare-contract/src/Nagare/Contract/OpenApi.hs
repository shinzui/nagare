-- | The contract as an OpenAPI 3.1 document of component schemas. The admin
-- API's generator adds its paths to the same declarations, so a schema is
-- declared once for both the CLI documents and the API.
module Nagare.Contract.OpenApi
  ( contractOpenApi
  , contractSchemas
  , renderOpenApi
  )
where

import Data.Aeson.Encode.Pretty (Config (..), Indent (..), defConfig, encodePretty')
import Data.ByteString.Lazy qualified as LBS
import Data.OpenApi
  ( Definitions
  , OpenApi
  , Schema
  , components
  , declareSchemaRef
  , info
  , schemas
  , title
  , version
  )
import Data.OpenApi.Declare (Declare, execDeclare)
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (ProblemDetails)
import Nagare.Contract.V1
  ( DeployPreview
  , Finding
  , Grant
  , HeadSummary
  , ImagePublicationResult
  , InventoryStatusReport
  , NixCacheEndpoint
  , NixCachePushResult
  , Publication
  , PublicationList
  , SavedReview
  , ScopeState
  , SiteList
  , SitePublishResult
  , SiteSummary
  , TransactionOutcome
  , VersionInfo
  )

-- | Every contract type, declared into @components.schemas@.
contractSchemas :: Declare (Definitions Schema) ()
contractSchemas = do
  void (declareSchemaRef (Proxy @ProblemDetails))
  void (declareSchemaRef (Proxy @TransactionOutcome))
  void (declareSchemaRef (Proxy @SavedReview))
  void (declareSchemaRef (Proxy @ImagePublicationResult))
  void (declareSchemaRef (Proxy @SitePublishResult))
  void (declareSchemaRef (Proxy @NixCacheEndpoint))
  void (declareSchemaRef (Proxy @NixCachePushResult))
  void (declareSchemaRef (Proxy @DeployPreview))
  void (declareSchemaRef (Proxy @InventoryStatusReport))
  void (declareSchemaRef (Proxy @PublicationList))
  void (declareSchemaRef (Proxy @VersionInfo))
  void (declareSchemaRef (Proxy @ScopeState))
  void (declareSchemaRef (Proxy @Finding))
  void (declareSchemaRef (Proxy @Publication))
  void (declareSchemaRef (Proxy @SiteList))
  void (declareSchemaRef (Proxy @SiteSummary))
  void (declareSchemaRef (Proxy @HeadSummary))
  void (declareSchemaRef (Proxy @Grant))

contractOpenApi :: OpenApi
contractOpenApi =
  mempty
    & components
    . schemas
    .~ execDeclare contractSchemas mempty
    & info
    . title
    .~ "Nagare contract"
    & info
    . version
    .~ "1"

-- | The checked-in artifact's bytes: two-space indent, sorted keys and a
-- trailing newline, so a diff shows a contract change rather than a reshuffle.
renderOpenApi :: OpenApi -> LBS.ByteString
renderOpenApi document = encodePretty' config document <> "\n"
  where
    config = defConfig {confIndent = Spaces 2, confCompare = compare}
