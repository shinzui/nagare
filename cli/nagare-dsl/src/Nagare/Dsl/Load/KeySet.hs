-- | Key-set responsibilities (EP-286); internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.KeySet
  ( decodeKeySets
  )
where

import Data.Aeson (FromJSON (parseJSON), eitherDecodeStrict, withObject, (.:), (.:?))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Nagare.Dsl.KeySet
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields (JsonKindEnvelope (..), firstDuplicate)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (mkNamespace)
import Nagare.Resource.Types (mkLogicalKey)

-- | The JSON 'Nagare.Dsl.Config.emitKeySets' writes for one entry.
data JsonKeySet = JsonKeySet
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , namespace :: !Text
  , periodMinutes :: !Int
  , overlapMinutes :: !Int
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonKeySet where
  parseJSON = withObject "KeySet" $ \o -> do
    rotation' <- o .: "rotation"
    JsonKeySet
      <$> o .: "name"
      <*> o .:? "logicalKey"
      <*> o .: "namespace"
      <*> rotation' .: "periodMinutes"
      <*> rotation' .: "overlapMinutes"

newtype JsonKeySets = JsonKeySets [JsonKeySet]

instance FromJSON JsonKeySets where
  parseJSON = withObject "KeySets" $ \o -> JsonKeySets <$> o .: "keySets"

toKeySet :: JsonKeySet -> Either LoadError KeySet
toKeySet j = do
  name' <- first (MarshalError "name") (mkKeySetName (j ^. #name))
  key' <- traverse (first (MarshalError "logicalKey") . mkLogicalKey) (j ^. #logicalKey)
  namespace' <- first (MarshalError "namespace") (mkNamespace (j ^. #namespace))
  rotation' <- first (MarshalError "rotation") $ do
    period' <- mkMinutes (j ^. #periodMinutes)
    overlap' <- mkMinutes (j ^. #overlapMinutes)
    mkRotationPolicy period' overlap'
  pure KeySet {name = name', logicalKey = key', namespace = namespace', rotation = rotation'}

-- | Decode the JSON a key-set config emits (via
-- 'Nagare.Dsl.Config.emitKeySets'): every entry is validated, and two entries
-- in one namespace may not share a name.
decodeKeySets :: ByteString -> Either LoadError [KeySet]
decodeKeySets bs =
  case eitherDecodeStrict bs of
    Left perr -> Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "KeySets" -> case eitherDecodeStrict bs of
        Left perr -> Left (MarshalError "json" ("could not decode key sets: " <> Text.pack perr))
        Right (JsonKeySets entries) -> do
          when (null entries) (Left (MarshalError "keySets" "config declares no key set"))
          keySets <- traverse toKeySet entries
          case firstDuplicate [namespaceKey keySet | keySet <- keySets] of
            Just duplicate -> Left (MarshalError "keySets" ("key set declared twice: " <> duplicate))
            Nothing -> Right keySets
      Just other -> Left (UnexpectedKind "KeySets" other)
      Nothing -> Left (UnexpectedKind "KeySets" "<none>")
  where
    namespaceKey keySet = keySetNameText (keySet ^. #name)
