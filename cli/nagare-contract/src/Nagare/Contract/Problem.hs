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
  , badRequest
  , invalidPage
  , invalidCursor
  , notFound
  , methodNotAllowed
  , notAcceptable
  , internalError
  , storeTimeout
  , storeInvalid
  , storeCredentialsUnavailable
  , serverBusy
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
  , badRequest
  , invalidPage
  , invalidCursor
  , notFound
  , methodNotAllowed
  , notAcceptable
  , internalError
  , storeTimeout
  , storeInvalid
  , storeCredentialsUnavailable
  , serverBusy
  ]

status400, status404, status405, status406, conflict, internal, unavailable :: Text -> Bool -> ProblemSpec
status400 c = ProblemSpec c 400 "Bad Request"
status404 c = ProblemSpec c 404 "Not Found"
status405 c = ProblemSpec c 405 "Method Not Allowed"
status406 c = ProblemSpec c 406 "Not Acceptable"
conflict c = ProblemSpec c 409 "Conflict"
internal c = ProblemSpec c 500 "Internal Server Error"
unavailable c = ProblemSpec c 503 "Service Unavailable"

unknownScope, unsupportedContractVersion, wrongContext, reviewChanged, admissionRefused :: ProblemSpec
unknownScope = status404 "unknown_scope" False
unsupportedContractVersion = status400 "unsupported_contract_version" False
wrongContext = conflict "wrong_context" False
reviewChanged = conflict "review_changed" False
admissionRefused = conflict "admission_refused" False

storeUnavailable, reauthenticationRequired, workspaceNotPrepared, unclassified :: ProblemSpec
storeUnavailable = unavailable "store_unavailable" True
reauthenticationRequired = unavailable "reauthentication_required" False
workspaceNotPrepared = conflict "workspace_not_prepared" False
unclassified = internal "unclassified" False

-- The admin API's own codes (EP-197). A malformed parameter, page or cursor
-- is the client's to fix; a store that cannot be read in time, or a server
-- at its admission limit, may answer the unchanged request later; a store
-- whose objects fail their checks will not.

badRequest, invalidPage, invalidCursor, notFound, methodNotAllowed, notAcceptable, internalError :: ProblemSpec
badRequest = status400 "bad_request" False
invalidPage = status400 "invalid_page" False
invalidCursor = status400 "invalid_cursor" False
notFound = status404 "not_found" False
methodNotAllowed = status405 "method_not_allowed" False
notAcceptable = status406 "not_acceptable" False
internalError = internal "internal_error" False

storeTimeout, storeInvalid, storeCredentialsUnavailable, serverBusy :: ProblemSpec
storeTimeout = unavailable "store_timeout" True
storeInvalid = unavailable "store_invalid" False
storeCredentialsUnavailable = unavailable "store_credentials_unavailable" True
serverBusy = unavailable "server_busy" True
