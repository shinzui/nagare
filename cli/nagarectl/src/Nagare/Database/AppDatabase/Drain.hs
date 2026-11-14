-- | What a drain observes on an app database's server (EP-205), parsed from
-- the drain query in "Nagare.Database.AppDatabase.Sql".
module Nagare.Database.AppDatabase.Drain
  ( DrainObservation (..)
  , parseDrainObservation
  , comparedIdentity
  )
where

import Data.Aeson (Value, eitherDecodeStrict, withObject, (.:), (.:?))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude

-- | What a drain observes on the server.
data DrainObservation = DrainObservation
  { sessions :: !Int
  -- ^ ClickHouse: the blocked users' running queries; PostgreSQL: their sessions
  , unfinished :: ![Text]
  -- ^ the app's unfinished mutations, as @database.table mutation_id@
  , failed :: ![Text]
  -- ^ those with a failure reason, as @database.table mutation_id: reason@
  , identity :: !(Map Text Text)
  -- ^ the engine's server identity
  }
  deriving stock (Generic, Eq, Show)

parseDrainObservation :: Engine -> ByteString -> Either Text DrainObservation
parseDrainObservation ClickHouse bytes = do
  rows <- traverse (decodeValue "ClickHouse drain observation") (filter (not . BC.null) (BC.lines bytes))
  parsed <- first T.pack (traverse (parseEither row) rows)
  let mutations = [(database' <> "." <> table <> " " <> mutation, reason) | Right (database', table, mutation, reason) <- parsed]
  identity' <- case [fields | Left (Just fields) <- parsed] of
    [fields] -> Right fields
    _ -> Left "ClickHouse drain observation has no server identity"
  pure
    DrainObservation
      { sessions = length [() | Left Nothing <- parsed]
      , unfinished = map fst mutations
      , failed = [mutation <> ": " <> reason | (mutation, reason) <- mutations, not (T.null reason)]
      , identity = identity'
      }
  where
    -- Left Nothing: a running query; Left (Just identity): the server; Right: a mutation.
    row :: Value -> Parser (Either (Maybe (Map Text Text)) (Text, Text, Text, Text))
    row = withObject "row" $ \o ->
      (o .: "kind" :: Parser Text) >>= \case
        "session" -> pure (Left Nothing)
        "server" -> (\uuid started -> Left (Just (Map.fromList [("serverUUID", uuid), ("processStarted", started)]))) <$> o .: "uuid" <*> o .: "started"
        "mutation" -> (\d t m r -> Right (d, t, m, fromMaybe "" r)) <$> o .: "database" <*> o .: "table" <*> o .: "mutation_id" <*> o .:? "latest_fail_reason"
        other -> fail ("unknown drain observation row " <> T.unpack other)
parseDrainObservation _ bytes = do
  value <- decodeValue "PostgreSQL drain observation" bytes
  first T.pack $ flip parseEither value $ withObject "drain" $ \o -> do
    sessions' <- o .: "sessions"
    systemIdentifier <- o .: "systemIdentifier"
    started <- o .: "started"
    pure (DrainObservation sessions' [] [] (Map.fromList [("systemIdentifier", systemIdentifier), ("postmasterStarted", started)]))

-- | The identity fields drain and resume compare. ClickHouse's process start
-- time is whole seconds and may move by one between reads, so it is
-- recorded, not compared (EP-205 M1).
comparedIdentity :: Map Text Text -> Map Text Text
comparedIdentity = Map.delete "processStarted"

decodeValue :: Text -> ByteString -> Either Text Value
decodeValue what bytes = first (const (what <> " is malformed")) (eitherDecodeStrict (BC.strip bytes))
