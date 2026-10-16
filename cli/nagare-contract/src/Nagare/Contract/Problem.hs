{-# OPTIONS_GHC -Wno-orphans #-}

-- | RFC 9457 problem documents: the one error shape the CLI prints under
-- @--contract 1@, a refused transaction outcome carries, the admin API
-- answers, and the access gateway renders for API clients.
--
-- @type@ is always @about:blank@, so @title@ is the HTTP status phrase
-- (RFC 9457 section 4.2.1) and the domain distinction is in @code@ and
-- @detail@. Every code is a 'ProblemSpec' in 'problemCatalog'; a new code is
-- an additive catalog entry.
module Nagare.Contract.Problem
  ( ProblemDetails (..)
  , problemJsonOptions
  , ProblemJSON
  , ProblemSpec (..)
  , problemFor
  , problemCatalog
  , unknownScope
  , unsupportedContractVersion
  , wrongContext
  , reviewChanged
  , admissionRefused
  , storeUnavailable
  , reauthenticationRequired
  , workspaceNotPrepared
  , unclassified
  )
where

import Data.Aeson
  ( FromJSON (..)
  , Options (..)
  , ToJSON (..)
  , defaultOptions
  , eitherDecode
  , encode
  , genericParseJSON
  , genericToEncoding
  , genericToJSON
  )
import Data.OpenApi (ToSchema (..), fromAesonOptions, genericDeclareNamedSchema)
import Nagare.Contract.Prelude
import Network.HTTP.Media ((//))
import Servant.API (Accept (..), MimeRender (..), MimeUnrender (..))

-- | An RFC 9457 problem document. 'problemType' is the RFC's @type@ member
-- (a Haskell reserved word) and 'gatewayError' is its @error@ member (so
-- importers keep the Prelude's @error@). @error@ and @login@ are the access gateway's
-- compatibility extensions; every other producer leaves them out, so a base
-- problem has exactly the members @type@, @title@, @status@, @detail@,
-- @code@ and @retryable@.
data ProblemDetails = ProblemDetails
  { problemType :: !Text
  , title :: !Text
  , status :: !Int
  , detail :: !Text
  , code :: !Text
  , retryable :: !Bool
  , gatewayError :: !(Maybe Text)
  , login :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | The single field mapping shared by the codec and the schema.
problemJsonOptions :: Options
problemJsonOptions =
  defaultOptions
    { fieldLabelModifier = \case
        "problemType" -> "type"
        "gatewayError" -> "error"
        other -> other
    , omitNothingFields = True
    }

instance ToJSON ProblemDetails where
  toJSON = genericToJSON problemJsonOptions
  toEncoding = genericToEncoding problemJsonOptions

instance FromJSON ProblemDetails where
  parseJSON = genericParseJSON problemJsonOptions

instance ToSchema ProblemDetails where
  declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions problemJsonOptions)

-- | The @application/problem+json@ content type (RFC 9457 section 3).
data ProblemJSON

instance Accept ProblemJSON where
  contentType _ = "application" // "problem+json"

instance (ToJSON a) => MimeRender ProblemJSON a where
  mimeRender _ = encode

instance (FromJSON a) => MimeUnrender ProblemJSON a where
  mimeUnrender _ = eitherDecode

-- | One error kind: its stable code, the HTTP status the API answers with,
-- that status's phrase, and whether the unchanged request may succeed later.
data ProblemSpec = ProblemSpec
  { code :: !Text
  , status :: !Int
  , title :: !Text
  , retryable :: !Bool
  }
  deriving stock (Eq, Show, Generic)

problemFor :: ProblemSpec -> Text -> ProblemDetails
problemFor (ProblemSpec specCode specStatus specTitle specRetryable) detailText =
  ProblemDetails
    { problemType = "about:blank"
    , title = specTitle
    , status = specStatus
    , detail = detailText
    , code = specCode
    , retryable = specRetryable
    , gatewayError = Nothing
    , login = Nothing
    }

problemCatalog :: [ProblemSpec]
problemCatalog =
  [ unknownScope
  , unsupportedContractVersion
  , wrongContext
  , reviewChanged
  , admissionRefused
  , storeUnavailable
  , reauthenticationRequired
  , workspaceNotPrepared
  , unclassified
  ]

badRequest, notFound, conflict, internal, unavailable :: Text -> Bool -> ProblemSpec
badRequest c = ProblemSpec c 400 "Bad Request"
notFound c = ProblemSpec c 404 "Not Found"
conflict c = ProblemSpec c 409 "Conflict"
internal c = ProblemSpec c 500 "Internal Server Error"
unavailable c = ProblemSpec c 503 "Service Unavailable"

unknownScope, unsupportedContractVersion, wrongContext, reviewChanged, admissionRefused :: ProblemSpec
unknownScope = notFound "unknown_scope" False
unsupportedContractVersion = badRequest "unsupported_contract_version" False
wrongContext = conflict "wrong_context" False
reviewChanged = conflict "review_changed" False
admissionRefused = conflict "admission_refused" False

storeUnavailable, reauthenticationRequired, workspaceNotPrepared, unclassified :: ProblemSpec
storeUnavailable = unavailable "store_unavailable" True
reauthenticationRequired = unavailable "reauthentication_required" False
workspaceNotPrepared = conflict "workspace_not_prepared" False
unclassified = internal "unclassified" False
