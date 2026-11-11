-- | The flat @export VAR=value@ context file format: its reader and the
-- shell quoting its writers use.
module Nagare.Target.ContextFile
  ( parseContextEnv
  , shellQuote
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude

-- | Single-quote a value for POSIX shell. A literal single quote is closed,
-- escaped, and reopened — @'@ becomes @'\\''@ — which is the only quoting that is
-- correct for every byte a context file can hold.
shellQuote :: Text -> Text
shellQuote v = "'" <> T.replace "'" "'\\''" v <> "'"

-- | Parse a flat @export VAR=value@ context file into a variable map. Blank
-- lines and lines whose first non-space character is '#' are ignored. A leading
-- @export @ is stripped; this is a pragmatic reader for machine-generated or
-- example-derived files, not a complete shell parser.
parseContextEnv :: Text -> Map String Text
parseContextEnv = Map.fromList . concatMap lineKV . T.lines
  where
    lineKV raw =
      let s = T.stripStart raw
       in if T.null s || "#" `T.isPrefixOf` s
            then []
            else
              let s' = fromMaybe s (T.stripPrefix "export " s)
               in case T.breakOn "=" s' of
                    (k, v)
                      | T.null v -> []
                      | otherwise -> [(T.unpack (T.strip k), unquote (T.drop 1 v))]
    unquote v =
      let t = T.strip v
       in if T.length t >= 2 && (T.head t == '"' || T.head t == '\'') && T.last t == T.head t
            then T.drop 1 (T.dropEnd 1 t)
            else t
