-- | Reading a reviewed Kubernetes Secret as a database credential template,
-- and the metadata field readers the credential templates share. Apart from
-- "Nagare.Inventory.Adapters.CredentialTemplate" so the admin API's backup
-- collector does not link the Kubernetes transport (MasterPlan 37).
module Nagare.Inventory.DatabaseCredential
  ( databaseCredentialKind
  , metadataOf
  , fieldText
  , textAt
  )
where

import Data.Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Database (Engine (..), dbSecretName, parseEngine)
import Nagare.Dsl.Prelude hiding ((.=))

metadataOf :: Value -> Either Text Object
metadataOf (Object root) = case KM.lookup "metadata" root of
  Just (Object value) -> Right value
  _ -> Left "Kubernetes observation has no metadata"
metadataOf _ = Left "Kubernetes observation is not an object"

fieldText :: Key -> Object -> Either Text Text
fieldText key metadata = case KM.lookup key metadata of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("Kubernetes observation lacks " <> T.pack (show key))

textAt :: Key -> Object -> Maybe Text
textAt key value = case KM.lookup key value of Just (String textValue) -> Just textValue; _ -> Nothing

databaseCredentialKind :: Value -> Either Text (Maybe (Text, Text, Engine))
databaseCredentialKind value = case value of
  Object root | KM.lookup "kind" root == Just (String "Secret") -> do
    metadata <- metadataOf value
    annotations <- case KM.lookup "annotations" metadata of
      Just (Object fields) -> Right fields
      Nothing -> Right KM.empty
      _ -> Left "reviewed Secret annotations are malformed"
    case textAt "nagare.dev/credential-template" annotations of
      Nothing -> Right Nothing
      Just "database-v1" -> do
        unless
          (not (KM.member "data" root) && not (KM.member "stringData" root))
          (Left "database credential template may not include Secret data")
        labels <- case KM.lookup "labels" metadata of
          Just (Object fields) -> Right fields
          _ -> Left "database credential template lacks labels"
        dbName <- fieldText "nagare.dev/database" labels
        namespace <- fieldText "namespace" metadata
        secretName <- fieldText "name" metadata
        unless (secretName == dbSecretName dbName) (Left "database credential template has the wrong Secret name")
        engineName <- fieldText "nagare.dev/engine" labels
        engine <- maybe (Left "database credential template has an unknown engine") Right (parseEngine engineName)
        pure (Just (dbName, namespace, engine))
      Just "app-database-v1" -> Right Nothing
      Just _ -> Left "unknown Kubernetes credential template"
  _ -> Right Nothing
