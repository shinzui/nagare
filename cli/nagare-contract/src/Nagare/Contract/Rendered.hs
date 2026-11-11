-- | The rendered configuration documents (EP-249): an input a client hands to
-- @nagarectl … --rendered@. @config@ is the config program's exact stdout as a
-- JSON string; @configDigest@ is the lower-case hex SHA-256 of that string's
-- UTF-8 bytes. Its own schema is the DSL's, versioned by @nagareVersion@.
module Nagare.Contract.Rendered
  ( RenderedConfiguration (..)
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.OpenApi (ToSchema (..), description, schema)
import Nagare.Contract.Prelude
import Nagare.Contract.Schema

-- | @document@ is @rendered-application@, @rendered-worker@ or
-- @rendered-site@; @kind@ is @Application@, @Worker@, @StaticSite@ or
-- @ServerSite@.
data RenderedConfiguration = RenderedConfiguration
  { contractVersion :: !ContractVersion
  , document :: !Text
  , nagareVersion :: !Text
  , kind :: !Text
  , configDigest :: !Text
  , config :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RenderedConfiguration where toJSON = genericToJSON recordOptions

instance FromJSON RenderedConfiguration where parseJSON = genericParseJSON recordOptions

instance ToSchema RenderedConfiguration where
  declareNamedSchema proxy =
    recordSchema proxy
      <&> schema
      . description
      ?~ "A config program's exact stdout as data. nagarectl refuses an unknown member, a digest that is not the SHA-256 of config's UTF-8 bytes, and a document from a newer Nagare minor version."
