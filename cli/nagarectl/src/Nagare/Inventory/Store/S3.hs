-- | An S3-compatible 'ObjectOps' for a local context's in-cluster object
-- store (EP-251). Conditional create is @If-None-Match: *@ and conditional
-- replace is @If-Match: ETAG@ (proved on the pinned server by
-- @docs/audits/ep251-s3-conditional-writes.md@). Like the GCS transport, a
-- failed read or list is never absence, and an ambiguous write is classified
-- by reading the object back.
module Nagare.Inventory.Store.S3
  ( S3Endpoint (..)
  , S3Credentials (..)
  , parseS3Endpoint
  , S3Response (..)
  , S3Transport
  , s3HttpTransport
  , s3ObjectOps
  , s3ObjectOpsWith
  , ensureBucket
  , signedHeaders
  , listedKeys
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.ByteArray (convert)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, ord)
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store.ObjectOps
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (Method, methodGet, methodPut, statusCode)
import Text.Printf (printf)

-- | @http://HOST:PORT/BUCKET/PREFIX@: a loopback or in-cluster endpoint, one
-- bucket and the context's private prefix inside it.
data S3Endpoint = S3Endpoint
  { base :: !Text
  , host :: !Text
  , bucket :: !Text
  , prefix :: !Text
  }
  deriving stock (Eq, Show, Generic)

data S3Credentials = S3Credentials
  { accessKeyId :: !Text
  , secretAccessKey :: !Text
  }
  deriving stock (Eq, Generic)

-- | The secret never reaches a log or an error.
instance Show S3Credentials where
  show credentials = "S3Credentials " <> show (credentials ^. #accessKeyId) <> " <secret>"

parseS3Endpoint :: Text -> Either Text S3Endpoint
parseS3Endpoint url = do
  (scheme, rest) <- case T.breakOn "://" url of
    (scheme, rest) | scheme `elem` ["http", "https"], not (T.null rest) -> Right (scheme, T.drop 3 rest)
    _ -> Left "an object inventory store URL must be http://HOST:PORT/BUCKET/PREFIX"
  let (authority, path) = T.breakOn "/" rest
  case filter (not . T.null) (T.splitOn "/" path) of
    bucket : parts@(_ : _)
      | not (T.null authority)
      , all validPart (bucket : parts) ->
          Right S3Endpoint {base = scheme <> "://" <> authority, host = authority, bucket = bucket, prefix = T.intercalate "/" parts}
    _ -> Left "an object inventory store URL must name a bucket and a private prefix"
  where
    validPart part = part /= "." && part /= ".." && T.all (\c -> isAsciiLower c || isDigit c || c `elem` ("-._" :: String)) part

-- | AWS Signature Version 4 for one path-style S3 request: the headers to
-- send, including @Authorization@. Extra headers are signed too.
signedHeaders :: S3Credentials -> Text -> UTCTime -> Method -> Text -> Text -> [(Text, Text)] -> [(ByteString, ByteString)] -> ByteString -> [(ByteString, ByteString)]
signedHeaders credentials region now method host path query extra payload =
  ("Authorization", authorization) : headers
  where
    amzDate = BC.pack (formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" now)
    day = BC.pack (formatTime defaultTimeLocale "%Y%m%d" now)
    payloadHash = hexSha256 payload
    headers =
      sortOn fst ([("host", TE.encodeUtf8 host), ("x-amz-content-sha256", payloadHash), ("x-amz-date", amzDate)] <> [(BC.map lower name, value) | (name, value) <- extra])
    lower c = if isAsciiUpper c then toEnum (ord c + 32) else c
    signedNames = BS.intercalate ";" (map fst headers)
    canonicalQuery = BS.intercalate "&" [encode True k <> "=" <> encode True v | (k, v) <- sortOn fst query]
    canonicalRequest =
      BS.intercalate
        "\n"
        [ method
        , encode False path
        , canonicalQuery
        , BS.concat [name <> ":" <> BC.strip value <> "\n" | (name, value) <- headers]
        , signedNames
        , payloadHash
        ]
    scope = BS.intercalate "/" [day, TE.encodeUtf8 region, "s3", "aws4_request"]
    stringToSign = BS.intercalate "\n" ["AWS4-HMAC-SHA256", amzDate, scope, hexSha256 canonicalRequest]
    signingKey = foldl hmacSha256 ("AWS4" <> TE.encodeUtf8 (credentials ^. #secretAccessKey)) [day, TE.encodeUtf8 region, "s3", "aws4_request"]
    signature = convertToBase Base16 (hmacSha256 signingKey stringToSign)
    authorization =
      "AWS4-HMAC-SHA256 Credential="
        <> TE.encodeUtf8 (credentials ^. #accessKeyId)
        <> "/"
        <> scope
        <> ", SignedHeaders="
        <> signedNames
        <> ", Signature="
        <> signature

hexSha256 :: ByteString -> ByteString
hexSha256 bytes = convertToBase Base16 (hash bytes :: Digest SHA256)

hmacSha256 :: ByteString -> ByteString -> ByteString
hmacSha256 key message = convert (hmacGetDigest (hmac key message :: HMAC SHA256))

-- | RFC 3986 unreserved characters pass; @/@ passes in a path.
encode :: Bool -> Text -> ByteString
encode slashEncoded = BS.concatMap one . TE.encodeUtf8
  where
    one byte
      | unreserved byte || (not slashEncoded && byte == 47) = BS.singleton byte
      | otherwise = BC.pack (printf "%%%02X" byte)
    unreserved byte =
      (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte `elem` [45, 46, 95, 126]

-- | One answer: the status, the lower-cased response headers and the body.
data S3Response = S3Response !Int ![(ByteString, ByteString)] !ByteString
  deriving stock (Eq, Show)

-- | One request: method, raw path, query, extra headers and payload. A
-- 'Left' is a request whose outcome is unknown.
type S3Transport = Method -> Text -> [(Text, Text)] -> [(ByteString, ByteString)] -> ByteString -> IO (Either Text S3Response)

s3ObjectOps :: S3Endpoint -> S3Credentials -> IO ObjectOps
s3ObjectOps endpoint credentials = (`s3ObjectOpsWith` endpoint) <$> s3HttpTransport (pure (Right (endpoint ^. #base, endpoint ^. #host))) credentials

-- | Signed path-style requests over HTTP. The base URL and host are asked for
-- at every request, so a workstation forward that exited is reopened.
s3HttpTransport :: IO (Either Text (Text, Text)) -> S3Credentials -> IO S3Transport
s3HttpTransport reach credentials = do
  manager <- HTTP.newManager HTTP.defaultManagerSettings {HTTP.managerResponseTimeout = HTTP.responseTimeoutMicro 30000000}
  pure $ \method path query extra payload ->
    reach >>= \case
      Left reason -> pure (Left reason)
      Right (baseUrl, hostName) -> do
        now <- getCurrentTime
        let headers = signedHeaders credentials "us-east-1" now method hostName path query extra payload
        result <- try $ do
          initial <- HTTP.parseRequest (T.unpack (baseUrl <> TE.decodeUtf8 (encode False path)))
          let prepared =
                initial
                  { HTTP.method = method
                  , HTTP.requestHeaders = [(CI.mk name, value) | (name, value) <- headers, name /= "host"]
                  , HTTP.requestBody = HTTP.RequestBodyBS payload
                  , HTTP.queryString = if null query then "" else "?" <> BS.intercalate "&" [encode True k <> "=" <> encode True v | (k, v) <- sortOn fst query]
                  }
          response <- HTTP.httpLbs prepared manager
          pure
            ( S3Response
                (statusCode (HTTP.responseStatus response))
                [(CI.foldedCase name, value) | (name, value) <- HTTP.responseHeaders response]
                (LBS.toStrict (HTTP.responseBody response))
            )
        pure (first (\(err :: SomeException) -> "object store request failed: " <> T.pack (takeWhile (/= '\n') (show err))) result)

s3ObjectOpsWith :: S3Transport -> S3Endpoint -> ObjectOps
s3ObjectOpsWith request endpoint =
  ObjectOps
    { getObject = get
    , getImmutableObject = fmap immutableGet . get
    , getObjects = getPrefix
    , putObject = put
    , listObjects = list
    , pauseBeforeRetry = threadDelay
    }
  where
    objectPath (ObjectName name) = "/" <> endpoint ^. #bucket <> "/" <> endpoint ^. #prefix <> "/" <> name
    etagOf headers = ObjectEtag . TE.decodeUtf8 <$> lookup "etag" headers
    get name = do
      response <- request methodGet (objectPath name) [] [] ""
      pure $ case response of
        Left reason -> GetUnknown reason
        Right (S3Response 200 headers body) -> maybe (GetUnknown "object store answered without an ETag") (`ObjectFound` body) (etagOf headers)
        Right (S3Response 404 _ body) | "<Code>NoSuchKey</Code>" `BS.isInfixOf` body -> ObjectAbsent
        Right (S3Response status _ _) -> GetUnknown ("object store read answered " <> T.pack (show status))
    put condition name bytes = case condition of
      IfGenerationMatches (Generation _) -> pure (PutNoEffect "an S3 object has no integer generation")
      _ -> do
        let header = case condition of
              IfGenerationMatches (ObjectEtag etag) -> [("If-Match", TE.encodeUtf8 etag)]
              _ -> [("If-None-Match", "*")]
        response <- request methodPut (objectPath name) [] header bytes
        case response of
          Right (S3Response 200 headers _) | Just generation <- etagOf headers -> pure (PutWritten generation)
          Right (S3Response 412 _ _) -> pure PutPreconditionFailed
          -- A conditional replace of a missing key is answered 404 NoSuchKey.
          Right (S3Response 404 _ body)
            | IfGenerationMatches _ <- condition
            , "<Code>NoSuchKey</Code>" `BS.isInfixOf` body ->
                pure PutPreconditionFailed
          _ -> classifyPutReadback condition bytes <$> get name
    list (ObjectName requested) = go Nothing []
      where
        go token acc = do
          response <-
            request
              methodGet
              ("/" <> endpoint ^. #bucket)
              ([("list-type", "2"), ("prefix", endpoint ^. #prefix <> "/" <> requested)] <> [("continuation-token", t) | Just t <- [token]])
              []
              ""
          case response of
            Left reason -> pure (Left reason)
            Right (S3Response 200 _ body) -> case listedKeys body of
              Left reason -> pure (Left reason)
              Right (keys, next) -> do
                let names = [ObjectName relative | key <- keys, Just relative <- [T.stripPrefix (endpoint ^. #prefix <> "/") key]]
                maybe (pure (Right (acc <> names))) (\t -> go (Just t) (acc <> names)) next
            Right (S3Response status _ _) -> pure (Left ("object store listing answered " <> T.pack (show status)))
    getPrefix requested@(ObjectName directory) = do
      listed <- list requested
      case listed of
        Left reason -> pure (Left reason)
        Right names -> do
          let batch = [name | name@(ObjectName full) <- names, Just leaf <- [T.stripPrefix (directory <> "/") full], not ("/" `T.isInfixOf` leaf)]
          loaded <- forM' batch $ \name -> do
            outcome <- get name
            pure $ case outcome of
              ObjectFound _ bytes -> Right (name, bytes)
              ObjectAbsent -> Left "a listed object vanished during a prefix read"
              GetUnknown reason -> Left reason
          pure (Map.fromList <$> sequence loaded)
    forM' xs f = traverse f xs

-- | Create the endpoint's bucket when it is absent; one the caller already
-- owns is kept.
ensureBucket :: S3Transport -> S3Endpoint -> IO (Either Text ())
ensureBucket request endpoint = do
  response <- request methodPut ("/" <> endpoint ^. #bucket) [] [] ""
  pure $ case response of
    Left reason -> Left reason
    Right (S3Response 200 _ _) -> Right ()
    Right (S3Response 409 _ body) | "<Code>BucketAlreadyOwnedByYou</Code>" `BS.isInfixOf` body -> Right ()
    Right (S3Response status _ _) -> Left ("object store bucket creation answered " <> T.pack (show status))

-- | The keys of one ListObjectsV2 page and its continuation token. Keys are
-- the store's own fixed names, so a minimal reader of the closed response
-- shape suffices; anything unexpected is an error, never an empty page.
listedKeys :: ByteString -> Either Text ([Text], Maybe Text)
listedKeys body
  | not ("<ListBucketResult" `BS.isInfixOf` body) = Left "object store listing is not a ListBucketResult"
  | otherwise = do
      keys <- traverse decodeXml (elements "Key")
      let truncated = elements "IsTruncated" == ["true"]
      next <- case (truncated, elements "NextContinuationToken") of
        (False, _) -> Right Nothing
        (True, [token]) -> Just <$> decodeXml token
        (True, _) -> Left "a truncated object store listing has no continuation token"
      pure (keys, next)
  where
    elements tag =
      [ value
      | chunk <- drop 1 (splitOn ("<" <> tag <> ">") body)
      , let value = fst (BS.breakSubstring ("</" <> tag <> ">") chunk)
      ]
    splitOn needle haystack = case BS.breakSubstring needle haystack of
      (before, rest)
        | BS.null rest -> [before]
        | otherwise -> before : splitOn needle (BS.drop (BS.length needle) rest)
    decodeXml raw = do
      text <- first (const "object store listing is not UTF-8") (TE.decodeUtf8' raw)
      pure (T.replace "&amp;" "&" (T.replace "&lt;" "<" (T.replace "&gt;" ">" (T.replace "&quot;" "\"" (T.replace "&apos;" "'" text)))))
