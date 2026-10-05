-- | Reading @nix build --dry-run@ output. A dry run of every check of a
-- system that lists nothing to build or fetch proves those exact outputs are
-- already in the store, which a flake check's exit status alone does not.
module Nagare.Harness.Realise
  ( remainingPaths
  )
where

import Data.Text qualified as T
import Nagare.Harness.Prelude

-- | Store paths a dry run says it would still build or fetch.
remainingPaths :: Text -> [Text]
remainingPaths = go False . T.lines
  where
    go _ [] = []
    go inList (line : rest)
      | isHeader line = go True rest
      | inList, Just path <- storePath line = path : go True rest
      | otherwise = go False rest
    isHeader line =
      any
        (`T.isPrefixOf` line)
        ["this derivation will be built", "these ", "this path will be fetched"]
        && any (`T.isInfixOf` line) ["will be built", "will be fetched"]
    storePath line =
      let stripped = T.strip line
       in if "/nix/store/" `T.isPrefixOf` stripped && T.isPrefixOf "  " line then Just stripped else Nothing
