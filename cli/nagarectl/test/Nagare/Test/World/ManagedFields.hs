-- | The fake API server's @metadata.managedFields@ entries, as rendered to a
-- client and as a client may write them back.
module Nagare.Test.World.ManagedFields
  ( Operation (..)
  , FieldsEntry (..)
  , renderEntry
  , parseManagedFields
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Containers.ListUtils (nubOrd)
import Data.Generics.Labels ()
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Dsl.Prelude hiding ((.=))

data Operation = Apply | Update
  deriving stock (Eq, Ord, Show)

-- | One @managedFields@ entry: who owns which leaf paths.
data FieldsEntry = FieldsEntry
  { manager :: !Text
  , operation :: !Operation
  , subresource :: !(Maybe Text)
  , fields :: !(Set.Set [Text])
  }
  deriving stock (Eq, Show, Generic)

renderEntry :: FieldsEntry -> Value
renderEntry entry =
  object
    ( [ "manager" .= (entry ^. #manager)
      , "operation" .= T.pack (show (entry ^. #operation))
      , "apiVersion" .= ("v1" :: Text)
      , "time" .= ("2026-10-06T00:00:00Z" :: Text)
      , "fieldsType" .= ("FieldsV1" :: Text)
      , "fieldsV1" .= fieldsTree (Set.toList (entry ^. #fields))
      ]
        <> ["subresource" .= s | Just s <- [entry ^. #subresource]]
    )
  where
    fieldsTree paths =
      Object
        ( KM.fromList
            [ (Key.fromText (if head' == "." then "." else "f:" <> head'), fieldsTree [rest | (h : rest) <- paths, h == head', not (null rest)])
            | head' <- nubOrd [h | h : _ <- paths]
            ]
        )

-- | Read a client-written @metadata.managedFields@ list.
parseManagedFields :: Value -> Either Text [FieldsEntry]
parseManagedFields = \case
  Array items -> traverse parseEntry (V.toList items)
  _ -> Left "metadata.managedFields must be a list"
  where
    parseEntry (Object entry) = do
      managerName <- maybe (Left "a managed-field entry has no manager") Right (text "manager" entry)
      operation' <- case text "operation" entry of
        Just "Apply" -> Right Apply
        Just "Update" -> Right Update
        _ -> Left "a managed-field entry has no operation"
      Right (FieldsEntry managerName operation' (text "subresource" entry) (Set.fromList (treePaths (fromMaybe Null (KM.lookup "fieldsV1" entry)))))
    parseEntry _ = Left "a managed-field entry is not an object"
    text key entry = case KM.lookup key entry of
      Just (String value) -> Just value
      _ -> Nothing
    treePaths (Object tree)
      | KM.null tree = [[]]
      | otherwise = [segment key <> rest | (key, sub) <- KM.toList tree, rest <- treePaths sub]
    treePaths _ = [[]]
    segment key = case Key.toText key of
      "." -> ["."]
      other -> [fromMaybe other (T.stripPrefix "f:" other)]
