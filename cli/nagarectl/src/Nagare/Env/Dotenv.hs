{-# LANGUAGE PackageImports #-}

-- | A minimal dotenv (@.env@) parser for @nagarectl env sync@ (EP-25).
--
-- Accepts @KEY=VALUE@ per line. Ignores blank lines and @#@ comments. Strips an
-- optional leading @export @. Trims surrounding whitespace around the key and
-- around the (unquoted) value. If the value is wrapped in matching single or
-- double quotes, the quotes are stripped and the inner text is taken literally
-- (a @#@ inside quotes is part of the value). A quoted value may span multiple
-- physical lines: lines are joined (with their newlines) until the closing quote.
-- A non-blank, non-comment line with no @=@, or an empty key, is a 'Left' error
-- (never silently dropped). Shell interpolation (@${X}@) and escape sequences
-- are NOT supported.
module Nagare.Env.Dotenv
  ( parseDotenv
  ) where

import Nagare.Dsl.Prelude

import Data.Char (isSpace)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as T

-- | Parse a dotenv file's text into a key/value map. See the module header for
-- the accepted grammar. A malformed line yields a 'Left' naming the offender.
parseDotenv :: Text -> Either Text (Map Text Text)
parseDotenv = fmap Map.fromList . go . T.lines
  where
    go :: [Text] -> Either Text [(Text, Text)]
    go [] = Right []
    go (line : rest)
      | isBlankOrComment line = go rest
      | otherwise = do
          (k, v, rest') <- parseEntry line rest
          ((k, v) :) <$> go rest'

-- | A line that is whitespace-only or whose first non-space character is @#@.
isBlankOrComment :: Text -> Bool
isBlankOrComment line =
  let s = T.strip line
   in T.null s || "#" `T.isPrefixOf` s

-- | Split a @KEY=VALUE@ line on the first @=@, validate the key, and parse the
-- value (which may consume further lines for a multiline quoted value).
parseEntry :: Text -> [Text] -> Either Text (Text, Text, [Text])
parseEntry line rest =
  let (before, after0) = T.breakOn "=" line
   in if T.null after0
        then Left ("malformed line (no '='): " <> line)
        else do
          k <- validateKey (stripExport (T.strip before))
          let rawVal = T.drop 1 after0 -- drop the '='
          (v, rest') <- parseValue rawVal rest
          Right (k, v, rest')

-- | A key must be non-empty and contain no whitespace or @=@.
validateKey :: Text -> Either Text Text
validateKey k
  | T.null k = Left "empty env key"
  | T.any (\c -> c == '=' || isSpace c) k =
      Left ("invalid env key (whitespace or '='): " <> k)
  | otherwise = Right k

-- | Strip a leading @export @ shell idiom.
stripExport :: Text -> Text
stripExport t = fromMaybe t (T.stripPrefix "export " t)

-- | Parse the value text after the @=@. Quoted values strip the quotes and take
-- the inner text literally; an unterminated quote consumes subsequent lines.
parseValue :: Text -> [Text] -> Either Text (Text, [Text])
parseValue rawVal rest =
  let stripped = T.strip rawVal
   in case T.uncons stripped of
        Just (q, afterQuote)
          | q == '"' || q == '\'' ->
              case T.breakOn (T.singleton q) afterQuote of
                (inner, closing)
                  | not (T.null closing) -> Right (inner, rest) -- closes on the same line
                  | otherwise -> consumeMultiline q afterQuote rest
        _ -> Right (stripped, rest)

-- | Accumulate physical lines (joined with newlines) until one contains the
-- closing quote @q@. The text after the closing quote is ignored.
consumeMultiline :: Char -> Text -> [Text] -> Either Text (Text, [Text])
consumeMultiline q _acc [] =
  Left ("unterminated quoted value (missing closing " <> T.singleton q <> ")")
consumeMultiline q acc (l : ls) =
  case T.breakOn (T.singleton q) l of
    (inner, closing)
      | not (T.null closing) -> Right (acc <> "\n" <> inner, ls)
      | otherwise -> consumeMultiline q (acc <> "\n" <> l) ls
