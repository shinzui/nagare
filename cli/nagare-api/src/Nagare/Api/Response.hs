{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | The responses every admin API route shares.
--
-- A body is encoded by the handler, not by Servant, so its strong ETag is a
-- hash of the exact bytes on the wire and a cached representation answers
-- without encoding again ('Encoded', served as 'PreEncodedJSON'). A state
-- route answers 200 with its validators and the snapshot it read, a bodyless
-- 304, or an RFC 9457 problem; a build route (version, OpenAPI) has no
-- inventory snapshot and cannot fail.
module Nagare.Api.Response
  ( PreEncodedJSON
  , Encoded (..)
  , decodeEncoded
  , Paged (..)
  , Validators (..)
  , SnapshotBody (..)
  , SnapshotUnchanged (..)
  , SnapshotHeaders
  , SnapshotResponses
  , SnapshotResult (..)
  , snapshotProblem
  , BuildBody (..)
  , BuildHeaders
  , BuildResponses
  , BuildResult (..)
  , Snapshot
  , Build
  , IfNoneMatch
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecode)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.HashMap.Strict.InsOrd.Compat qualified as InsOrd
import Data.OpenApi
  ( NamedSchema (..)
  , OpenApiItems (..)
  , OpenApiType (..)
  , OpenApiTypeValue (..)
  , Reference (..)
  , Referenced (..)
  , ToSchema (..)
  , declareSchemaRef
  , items
  , properties
  , required
  , type_
  )
import Data.OpenApi.Declare (declare)
import Data.SOP (I (..), NP (..), NS (..))
import Data.Sequence qualified as Seq
import Data.Text qualified as Text
import Data.Typeable (Typeable, tyConName, typeRep, typeRepTyCon)
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (ProblemDetails (..), ProblemJSON)
import Network.HTTP.Media ((//))
import Network.HTTP.Media qualified as Media
import Relay.Pagination (Connection, Cursor, PageInfo)
import Relay.Pagination.Servant.OpenApi ()
import Servant.API (Accept (..), Header, MimeRender (..), MimeUnrender (..), ReflectMethod (..), StdMethod (GET))
import Servant.API.MultiVerb (AsHeaders (..), AsUnion (..), MultiVerb, Respond, RespondAs, RespondEmpty, UnrenderResult (..), WithHeaders)
import Servant.Client.Core (ClientError (..), HasClient (..), RunClient (..), throwClientError)
import Servant.Client.Core.MultiVerb.ResponseUnrender (ResponseListUnrender (..), SomeClientResponse (..))
import Servant.Client.Core.Request (Request, RequestF (..))
import Servant.Client.Core.Response (ResponseF (..))

-- | @application/json@ whose bytes the handler already produced.
data PreEncodedJSON

instance Accept PreEncodedJSON where
  contentType _ = "application" // "json"

-- | The client of a route answering 'PreEncodedJSON'. Upstream's MultiVerb
-- client (servant-client-core 0.20.3) refuses any response whose media type
-- is not in the verb's list before it tries the alternatives, so it can never
-- decode a declared @application/problem+json@ error or a bodyless 304. This
-- client lets each alternative's own status and media checks decide, as the
-- server renders them. It is not an orphan: the verb's media type is ours.
instance
  {-# OVERLAPPING #-}
  ( ResponseListUnrender '[PreEncodedJSON] as
  , ReflectMethod method
  , AsUnion as r
  , RunClient m
  ) =>
  HasClient m (MultiVerb method '[PreEncodedJSON] as r)
  where
  type Client m (MultiVerb method '[PreEncodedJSON] as r) = m r

  clientWithRoute _ _ request = do
    response <-
      runRequestAcceptStatus
        (Just (responseListStatuses @'[PreEncodedJSON] @as))
        (request :: Request)
          { requestMethod = reflectMethod (Proxy @method)
          , requestAccept = Seq.fromList [contentType (Proxy @PreEncodedJSON), "application" // "problem+json"]
          }
    mediaType <- case lookup "Content-Type" (toList (responseHeaders response)) of
      Nothing -> pure ("application" // "octet-stream")
      Just value -> maybe (throwClientError (InvalidContentTypeHeader response)) pure (Media.parseAccept value)
    let candidate =
          if LBS.null (responseBody response)
            then SomeClientResponse response {responseBody = ()}
            else SomeClientResponse response
    case responseListUnrender @'[PreEncodedJSON] @as mediaType candidate of
      StatusMismatch -> throwClientError (DecodeFailure "Status mismatch" response)
      UnrenderError reason -> throwClientError (DecodeFailure (Text.pack reason) response)
      UnrenderSuccess union -> pure (fromUnion @as union)

  hoistClientMonad _ _ transform = transform

-- | The exact JSON bytes of an @a@. The client side checks the bytes decode
-- as an @a@ before handing them over.
newtype Encoded a = Encoded LBS.ByteString
  deriving stock (Eq, Show)

instance MimeRender PreEncodedJSON (Encoded a) where
  mimeRender _ (Encoded bytes) = bytes

instance (FromJSON a) => MimeUnrender PreEncodedJSON (Encoded a) where
  mimeUnrender _ bytes = Encoded bytes <$ (eitherDecode bytes :: Either String a)

instance (ToSchema a) => ToSchema (Encoded a) where
  declareNamedSchema _ = declareNamedSchema (Proxy @a)

decodeEncoded :: (FromJSON a) => Encoded a -> Either String a
decodeEncoded (Encoded bytes) = eitherDecode bytes

-- | A Relay connection of @a@. Its schema is named after @a@
-- (@ScopeStateConnection@, @ScopeStateEdge@): the relay package's generic
-- schemas name every connection @Connection@, which would collide.
newtype Paged a = Paged (Connection a)
  deriving stock (Eq, Show)

instance (ToJSON a) => ToJSON (Paged a) where
  toJSON (Paged page) = toJSON page
  toEncoding (Paged page) = toEncoding page

instance (FromJSON a) => FromJSON (Paged a) where
  parseJSON value = Paged <$> parseJSON value

instance (ToSchema a, Typeable a) => ToSchema (Paged a) where
  declareNamedSchema _ = do
    node <- declareSchemaRef (Proxy @a)
    pageInfo <- declareSchemaRef (Proxy @PageInfo)
    cursor <- declareSchemaRef (Proxy @Cursor)
    let itemName = Text.pack (tyConName (typeRepTyCon (typeRep (Proxy @a))))
        edge =
          mempty
            & type_
            ?~ OpenApiTypeSingle OpenApiObject
            & properties
            .~ InsOrd.fromList [("node", node), ("cursor", cursor)]
            & required
            .~ ["node", "cursor"]
    declare (InsOrd.singleton (itemName <> "Edge") edge)
    let edgeRef = Ref (Reference (itemName <> "Edge"))
    pure . NamedSchema (Just (itemName <> "Connection")) $
      mempty
        & type_
        ?~ OpenApiTypeSingle OpenApiObject
        & properties
        .~ InsOrd.fromList
          [ ("edges", Inline (mempty & type_ ?~ OpenApiTypeSingle OpenApiArray & items ?~ OpenApiItemsObject edgeRef))
          , ("pageInfo", pageInfo)
          ]
        & required
        .~ ["edges", "pageInfo"]

-- | The validators of one representation. The ETag is strong and quoted.
data Validators = Validators
  { etag :: !Text
  , cacheControl :: !Text
  , vary :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | A state representation, the validators of its bytes and the revision of
-- the checked head it was read from.
data SnapshotBody a = SnapshotBody
  { body :: !(Encoded a)
  , validators :: !Validators
  , headRevision :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | A 304 keeps the validators and the snapshot it was checked against.
data SnapshotUnchanged = SnapshotUnchanged
  { validators :: !Validators
  , headRevision :: !Text
  }
  deriving stock (Eq, Show, Generic)

type SnapshotHeaders =
  '[ Header "ETag" Text
   , Header "Cache-Control" Text
   , Header "Vary" Text
   , Header "Nagare-Head-Revision" Text
   ]

instance AsHeaders '[Text, Text, Text, Text] (Encoded a) (SnapshotBody a) where
  toHeaders (SnapshotBody bytes (Validators tag cache varying) revision) = (I tag :* I cache :* I varying :* I revision :* Nil, bytes)
  fromHeaders (I tag :* I cache :* I varying :* I revision :* Nil, bytes) = SnapshotBody bytes (Validators tag cache varying) revision

instance AsHeaders '[Text, Text, Text, Text] () SnapshotUnchanged where
  toHeaders (SnapshotUnchanged (Validators tag cache varying) revision) = (I tag :* I cache :* I varying :* I revision :* Nil, ())
  fromHeaders (I tag :* I cache :* I varying :* I revision :* Nil, ()) = SnapshotUnchanged (Validators tag cache varying) revision

type SnapshotResponses a =
  '[ WithHeaders SnapshotHeaders (SnapshotBody a) (Respond 200 "The recorded representation" (Encoded a))
   , WithHeaders SnapshotHeaders SnapshotUnchanged (RespondEmpty 304 "Not Modified")
   , RespondAs ProblemJSON 400 "Bad Request" ProblemDetails
   , RespondAs ProblemJSON 404 "Not Found" ProblemDetails
   , RespondAs ProblemJSON 500 "Internal Server Error" ProblemDetails
   , RespondAs ProblemJSON 503 "Service Unavailable" ProblemDetails
   ]

-- | What a state handler returns: one constructor per status.
data SnapshotResult a
  = SnapshotOk !(SnapshotBody a)
  | SnapshotNotModified !SnapshotUnchanged
  | SnapshotBadRequest !ProblemDetails
  | SnapshotNotFound !ProblemDetails
  | SnapshotInternal !ProblemDetails
  | SnapshotUnavailable !ProblemDetails
  deriving stock (Eq, Show)

instance AsUnion (SnapshotResponses a) (SnapshotResult a) where
  toUnion = \case
    SnapshotOk value -> Z (I value)
    SnapshotNotModified value -> S (Z (I value))
    SnapshotBadRequest problem -> S (S (Z (I problem)))
    SnapshotNotFound problem -> S (S (S (Z (I problem))))
    SnapshotInternal problem -> S (S (S (S (Z (I problem)))))
    SnapshotUnavailable problem -> S (S (S (S (S (Z (I problem))))))
  fromUnion = \case
    Z (I value) -> SnapshotOk value
    S (Z (I value)) -> SnapshotNotModified value
    S (S (Z (I problem))) -> SnapshotBadRequest problem
    S (S (S (Z (I problem)))) -> SnapshotNotFound problem
    S (S (S (S (Z (I problem))))) -> SnapshotInternal problem
    S (S (S (S (S (Z (I problem)))))) -> SnapshotUnavailable problem
    S (S (S (S (S (S impossible))))) -> case impossible of {}

-- | The alternative a problem's own status selects. A status outside the
-- list is an internal error.
snapshotProblem :: ProblemDetails -> SnapshotResult a
snapshotProblem problem@ProblemDetails {status = code} = case code of
  400 -> SnapshotBadRequest problem
  404 -> SnapshotNotFound problem
  503 -> SnapshotUnavailable problem
  _ -> SnapshotInternal problem

-- | A build representation (version, OpenAPI) and its validators.
data BuildBody a = BuildBody
  { body :: !(Encoded a)
  , validators :: !Validators
  }
  deriving stock (Eq, Show, Generic)

type BuildHeaders =
  '[ Header "ETag" Text
   , Header "Cache-Control" Text
   , Header "Vary" Text
   ]

instance AsHeaders '[Text, Text, Text] (Encoded a) (BuildBody a) where
  toHeaders (BuildBody bytes (Validators tag cache varying)) = (I tag :* I cache :* I varying :* Nil, bytes)
  fromHeaders (I tag :* I cache :* I varying :* Nil, bytes) = BuildBody bytes (Validators tag cache varying)

instance AsHeaders '[Text, Text, Text] () Validators where
  toHeaders (Validators tag cache varying) = (I tag :* I cache :* I varying :* Nil, ())
  fromHeaders (I tag :* I cache :* I varying :* Nil, ()) = Validators tag cache varying

type BuildResponses a =
  '[ WithHeaders BuildHeaders (BuildBody a) (Respond 200 "The serving build's representation" (Encoded a))
   , WithHeaders BuildHeaders Validators (RespondEmpty 304 "Not Modified")
   ]

data BuildResult a
  = BuildOk !(BuildBody a)
  | BuildNotModified !Validators
  deriving stock (Eq, Show)

instance AsUnion (BuildResponses a) (BuildResult a) where
  toUnion = \case
    BuildOk value -> Z (I value)
    BuildNotModified value -> S (Z (I value))
  fromUnion = \case
    Z (I value) -> BuildOk value
    S (Z (I value)) -> BuildNotModified value
    S (S impossible) -> case impossible of {}

-- | A conditional read: the client's @If-None-Match@, if any.
type IfNoneMatch = Header "If-None-Match" Text

type Snapshot a = MultiVerb 'GET '[PreEncodedJSON] (SnapshotResponses a) (SnapshotResult a)

type Build a = MultiVerb 'GET '[PreEncodedJSON] (BuildResponses a) (BuildResult a)
