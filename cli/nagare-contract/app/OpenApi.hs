-- | Write the contract's OpenAPI document. Run from the repository root:
--
-- > cabal run --project-dir=cli/nagarectl nagare-contract-openapi
module Main (main) where

import Data.ByteString.Lazy qualified as LBS
import Nagare.Contract.OpenApi (contractOpenApi, renderOpenApi)
import Nagare.Contract.Prelude

main :: IO ()
main = LBS.writeFile "docs/api/openapi.json" (renderOpenApi contractOpenApi)
