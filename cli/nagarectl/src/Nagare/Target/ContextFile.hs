-- | The flat @export VAR=value@ context file format: its reader, the field lookups over the map it
-- yields, and the shell quoting its writers use.
module Nagare.Target.ContextFile
  ( parseContextEnv
  , shellQuote
  , ctxOr
  , ctxRaw
  , mapOr
  , mapRaw
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import System.Environment (lookupEnv)

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

-- | Resolve one field with precedence: process env > context map > default. An
-- env var or context value set to empty is treated as unset.
ctxOr :: Map String Text -> String -> Text -> IO Text
ctxOr ctx name def = do
  m <- lookupEnv name
  pure $ case m of
    Just v | not (null v) -> T.pack v
    _ -> case Map.lookup name ctx of
      Just v | not (T.null v) -> v
      _ -> def

-- | Raw field lookup with env > context precedence for parsers like 'parseMode'.
ctxRaw :: Map String Text -> String -> IO (Maybe String)
ctxRaw ctx name = do
  m <- lookupEnv name
  pure $ case m of
    Just v | not (null v) -> Just v
    _ -> case Map.lookup name ctx of
      Just v | not (T.null v) -> Just (T.unpack v)
      _ -> Nothing

mapOr :: Map String Text -> String -> Text -> Text
mapOr ctx name def = case Map.lookup name ctx of
  Just v | not (T.null v) -> v
  _ -> def

mapRaw :: Map String Text -> String -> Maybe String
mapRaw ctx name = case Map.lookup name ctx of
  Just v | not (T.null v) -> Just (T.unpack v)
  _ -> Nothing
