-- | The published OpenAPI artifact (EP-197 M1): it is the generated
-- document, its path set is exactly the served routes, and every @/v1@
-- operation carries both credentials and problem-typed error responses.
module Nagare.Api.Server.Test.Document
  ( documentTests
  )
where

import Data.ByteString.Lazy qualified as LBS
import Data.HashMap.Strict.InsOrd.Compat qualified as InsOrd
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.OpenApi
  ( HttpStatusCode (..)
  , Referenced (..)
  , SecurityRequirement (..)
  , content
  , get
  , operationId
  , paths
  , responses
  , security
  )
import Data.Text qualified as Text
import Nagare.Api.OpenApi (adminOpenApi, gatewayStatuses, operationIds, renderAdminOpenApi)
import Nagare.Contract.Prelude
import Network.HTTP.Media ((//))
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

-- | The repository root, relative to @cli/nagare-api-server@.
repositoryRoot :: FilePath
repositoryRoot = "../.."

documentTests :: TestTree
documentTests =
  testGroup
    "document"
    [ testCase "docs/api/openapi.json equals the generated document" $ do
        checkedIn <- LBS.readFile (repositoryRoot </> "docs/api/openapi.json")
        assertBool
          "docs/api/openapi.json is stale; run: cabal run --project-dir=cli/nagarectl nagare-api-openapi"
          (checkedIn == renderAdminOpenApi)
    , testCase "paths list exactly the served operations, each with its stable operation ID" $ do
        sort (InsOrd.keys (adminOpenApi ^. paths)) @?= sort (map fst operationIds)
        for_ (InsOrd.toList (adminOpenApi ^. paths)) $ \(path, item) ->
          (item ^? get . _Just . operationId . _Just) @?= lookup path operationIds
    , testCase "every /v1 operation accepts a session cookie or a bearer token" $
        for_ v1Operations $ \(path, operation) ->
          assertEqual
            path
            [SecurityRequirement (InsOrd.singleton "nagare_session" []), SecurityRequirement (InsOrd.singleton "bearer" [])]
            (operation ^. security)
    , testCase "every /v1 error response is application/problem+json, including the gateway's" $
        for_ v1Operations $ \(path, operation) -> do
          let codes = [code | StatusCode code <- InsOrd.keys (operation ^. responses . responses)]
          let handlerStatuses = if path `elem` buildPaths then [] else [400, 404, 500, 503]
          for_ (gatewayStatuses <> handlerStatuses) $ \code ->
            assertBool (path <> " lacks " <> show code) (code `elem` codes)
          for_ (InsOrd.toList (operation ^. responses . responses)) $ \case
            (StatusCode code, Inline response)
              | code >= 400 ->
                  InsOrd.keys (response ^. content) @?= ["application" // "problem+json"]
            _ -> pure ()
    , testCase "health probes carry no gateway security requirement" $
        for_ (InsOrd.toList (adminOpenApi ^. paths)) $ \(path, item) ->
          when ("/health/" `Text.isPrefixOf` Text.pack path) $
            (item ^? get . _Just . security) @?= Just []
    ]
  where
    for_ xs action = mapM_ action xs
    -- The build routes describe the binary and cannot fail; the versions
    -- document answers 200 with reasons when its snapshot is unusable.
    buildPaths = ["/v1/platform/version", "/v1/platform/versions", "/v1/openapi.json"]
    v1Operations =
      mapMaybe
        (\(path, item) -> if "/v1/" `Text.isPrefixOf` Text.pack path then (path,) <$> item ^. get else Nothing)
        (InsOrd.toList (adminOpenApi ^. paths))
