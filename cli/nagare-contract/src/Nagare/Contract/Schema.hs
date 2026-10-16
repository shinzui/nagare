{-# OPTIONS_GHC -Wno-orphans #-}

-- | The schema building blocks every contract type shares: a required field
-- whose value may be @null@, constant @contractVersion@ and @document@
-- members, the enumeration encoding, and the schema of an opaque JSON value.
--
-- The orphan @ToSchema Value@ lives here, not in the generator, because the
-- library's own instances (an opaque @scopeDocuments@ list) need it where
-- they are compiled.
module Nagare.Contract.Schema
  ( Nullable (..)
  , nullable
  , fromNullable
  , DocumentName (..)
  , ContractVersion (..)
  , recordOptions
  , enumOptions
  , recordSchema
  , enumSchema
  )
where

import Data.Aeson
  ( FromJSON (..)
  , Options (..)
  , ToJSON (..)
  , Value (..)
  , camelTo2
  , defaultOptions
  , withScientific
  , withText
  )
import Data.Kind (Type)
import Data.List (stripPrefix)
import Data.OpenApi
  ( AdditionalProperties (..)
  , Definitions
  , NamedSchema (..)
  , OpenApiType (..)
  , OpenApiTypeValue (..)
  , Referenced (..)
  , Schema
  , ToSchema (..)
  , additionalProperties
  , declareSchemaRef
  , enum_
  , fromAesonOptions
  , genericDeclareNamedSchema
  , oneOf
  , type_
  )
import Data.OpenApi.Declare (Declare)
import Data.OpenApi.Internal.Schema (GToSchema)
import Data.Text qualified as Text
import Data.Typeable (Typeable)
import GHC.Generics (Rep)
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Nagare.Contract.Prelude

-- | A member that is always present and may be @null@. A plain 'Maybe' field
-- is an optional member in the derived schema, so its @null@ would fail
-- validation; this wrapper makes the member required and its schema admit
-- @null@ (a 3.1 type array, or @oneOf@ with a referenced schema).
newtype Nullable a = Nullable (Maybe a)
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

nullable :: Maybe a -> Nullable a
nullable = Nullable

fromNullable :: Nullable a -> Maybe a
fromNullable (Nullable value) = value

instance (ToSchema a) => ToSchema (Nullable a) where
  declareNamedSchema _ = do
    reference <- declareSchemaRef (Proxy @a)
    pure . NamedSchema Nothing $ case reference of
      Inline schema
        | Just (OpenApiTypeSingle single) <- schema ^. type_
        , isNothing (schema ^. enum_) ->
            schema & type_ ?~ OpenApiTypeArray [single, OpenApiNull]
      _ -> mempty & oneOf ?~ [reference, Inline nullSchema]
    where
      nullSchema = mempty & type_ ?~ OpenApiTypeSingle OpenApiNull

-- | The constant @document@ member naming a document's kind.
data DocumentName (name :: Symbol) = DocumentName
  deriving stock (Eq, Ord, Show, Generic)

instance (KnownSymbol name) => ToJSON (DocumentName name) where
  toJSON _ = String (Text.pack (symbolVal (Proxy @name)))

instance (KnownSymbol name) => FromJSON (DocumentName name) where
  parseJSON = withText "document" $ \value ->
    if value == Text.pack (symbolVal (Proxy @name))
      then pure DocumentName
      else fail ("expected document " <> symbolVal (Proxy @name))

instance (KnownSymbol name) => ToSchema (DocumentName name) where
  declareNamedSchema _ =
    pure . NamedSchema Nothing $
      mempty
        & type_
        ?~ OpenApiTypeSingle OpenApiString
        & enum_
        ?~ [String (Text.pack (symbolVal (Proxy @name)))]

-- | The constant @contractVersion@ member. Version 1 is the only one.
data ContractVersion = ContractVersion1
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON ContractVersion where
  toJSON ContractVersion1 = Number 1

instance FromJSON ContractVersion where
  parseJSON = withScientific "contractVersion" $ \value ->
    if value == 1 then pure ContractVersion1 else fail "unsupported contract version"

instance ToSchema ContractVersion where
  declareNamedSchema _ =
    pure . NamedSchema Nothing $
      mempty
        & type_
        ?~ OpenApiTypeSingle OpenApiInteger
        & enum_
        ?~ [Number 1]

-- | Records encode their field names verbatim.
recordOptions :: Options
recordOptions = defaultOptions

-- | Enumerations encode a constructor without its @prefix@, in kebab case:
-- @CategoryConfigurationDrift@ with prefix @Category@ is
-- @configuration-drift@.
enumOptions :: String -> Options
enumOptions prefix =
  defaultOptions
    { constructorTagModifier = camelTo2 '-' . dropPrefix
    , allNullaryToStringTag = True
    }
  where
    dropPrefix name = fromMaybe name (stripPrefix prefix name)

-- | The schema of a record, from the same options as its codec.
recordSchema ::
  forall (a :: Type).
  (Generic a, GToSchema (Rep a), Typeable a) =>
  Proxy a ->
  Declare (Definitions Schema) NamedSchema
recordSchema = genericDeclareNamedSchema (fromAesonOptions recordOptions)

-- | The schema of an enumeration, from the same options as its codec.
enumSchema ::
  forall (a :: Type).
  (Generic a, GToSchema (Rep a), Typeable a) =>
  String ->
  Proxy a ->
  Declare (Definitions Schema) NamedSchema
enumSchema prefix = genericDeclareNamedSchema (fromAesonOptions (enumOptions prefix))

-- | An opaque JSON value. An empty schema is not enough: the validator
-- rejects unmentioned object members unless they are explicitly allowed.
instance ToSchema Value where
  declareNamedSchema _ =
    pure . NamedSchema (Just "AnyValue") $
      mempty & additionalProperties ?~ AdditionalPropertiesAllowed True
