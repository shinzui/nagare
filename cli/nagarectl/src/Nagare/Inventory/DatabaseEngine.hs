-- | F86: a managed database's data files belong to its engine, and
-- PostgreSQL's to its major version. PostgreSQL refuses to open files another
-- major initialized ("database files are incompatible with server"), so an
-- in-place major change leaves the database down; an engine change would
-- point a different server at the volume. Both are side-by-side migrations: a
-- new database at the new version, its data moved by dump and restore.
module Nagare.Inventory.DatabaseEngine (databaseEngineUnchanged) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Char (isDigit)
import Data.Foldable (toList)
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude

-- | Compare an accepted StatefulSet with its desired replacement. Another
-- kind (a database's backup CronJob shares its labels) or a StatefulSet that
-- is not a managed database (no @nagare.dev/engine@ label) is not checked.
databaseEngineUnchanged :: ByteString -> ByteString -> Either Text ()
databaseEngineUnchanged accepted desired = do
  before <- database "accepted" accepted
  after <- database "desired" desired
  case (before, after) of
    (Nothing, Nothing) -> Right ()
    (Just (engine, image), Just (engine', image'))
      | engine /= engine' ->
          Left ("database " <> label <> " would change engine from " <> engine <> " to " <> engine' <> " in place; create a new database beside it and move the data")
      | engine == "postgres" && image /= image' && (isNothing (major image) || major image /= major image') ->
          Left
            ( "PostgreSQL "
                <> label
                <> " would change from "
                <> image
                <> " to "
                <> image'
                <> " in place; PostgreSQL cannot open data files of another major version. Create a new database at the new version beside it and move the data (docs/user/managed-databases.md#upgrade-postgresql-to-a-new-major-version)"
            )
      | otherwise -> Right ()
    _ -> Left ("database " <> label <> " would gain or lose its engine label in place")
  where
    label = either (const "StatefulSet") id (name accepted)
    major image = case T.breakOnEnd ":" image of
      (prefix, tag)
        | not (T.null prefix), digits <- T.takeWhile isDigit tag, not (T.null digits) -> Just digits
      _ -> Nothing

database :: Text -> ByteString -> Either Text (Maybe (Text, Text))
database side bytes = do
  value <- first (const (side <> " StatefulSet is not YAML")) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
  case path ["metadata", "labels", "nagare.dev/engine"] value of
    _ | path ["kind"] value /= Just (String "StatefulSet") -> Right Nothing
    Nothing -> Right Nothing
    Just (String engine) -> case path ["spec", "template", "spec", "containers"] value of
      Just (Array containers) -> case [image | Object container <- toList containers, KM.lookup "name" container == Just (String engine), Just (String image) <- [KM.lookup "image" container]] of
        [image] -> Right (Just (engine, image))
        _ -> Left (side <> " database StatefulSet has no single " <> engine <> " container image")
      _ -> Left (side <> " database StatefulSet has no containers")
    Just _ -> Left (side <> " database engine label is not a string")

name :: ByteString -> Either Text Text
name bytes = do
  value <- first (const "not YAML") (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
  case path ["metadata", "name"] value of
    Just (String text) -> Right text
    _ -> Left "no name"

path :: [Text] -> Value -> Maybe Value
path [] value = Just value
path (key : rest) (Object fields) = KM.lookup (Key.fromText key) fields >>= path rest
path _ _ = Nothing
