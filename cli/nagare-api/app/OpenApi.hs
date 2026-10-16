-- | Write the admin API's OpenAPI document. Run from the repository root:
--
-- > cabal run --project-dir=cli/nagarectl nagare-api-openapi
module Main (main) where

import Data.ByteString.Lazy qualified as LBS
import Nagare.Api.OpenApi (renderAdminOpenApi)
import Nagare.Contract.Prelude

main :: IO ()
main = LBS.writeFile "docs/api/openapi.json" renderAdminOpenApi
