-- | Operator commands for granting and revoking access to protected Nagare apps.
module Nagare.Access.Grants
  ( AccessGrantParams (..)
  , AccessListParams (..)
  , AccessListResult (..)
  , ObjectRefWire (..)
  , SubjectWire (..)
  , TupleWire (..)
  , ExpandNodeWire (..)
  , ExpandStateWire (..)
  , ExpandTreeWire (..)
  , accessTuple
  , collectExpandedSubjects
  , expandRequest
  , runAccessGrant
  , runAccessList
  , runAccessRevoke
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecode, encode, pairs, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import GHC.Generics (Generic)
import Nagare.Dsl.Prelude hiding (children, (.=))
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (hAuthorization, hContentType)
import Network.HTTP.Types.Method (methodPost)
import Network.HTTP.Types.Status (statusCode)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (stderr)

data AccessGrantParams = AccessGrantParams
  { agpEnUrl :: !(Maybe Text)
  , agpEnApiKey :: !(Maybe Text)
  , agpHost :: !Text
  , agpUser :: !Text
  }
  deriving stock (Generic, Eq, Show)

data AccessListParams = AccessListParams
  { alpEnUrl :: !(Maybe Text)
  , alpEnApiKey :: !(Maybe Text)
  , alpHost :: !Text
  }
  deriving stock (Generic, Eq, Show)

newtype AccessListResult = AccessListResult
  { users :: [Text]
  }
  deriving stock (Generic, Eq, Show)

data ObjectRefWire = ObjectRefWire
  { objectType :: !Text
  , objectId :: !Text
  }
  deriving stock (Eq, Show)

instance ToJSON ObjectRefWire where
  toJSON (ObjectRefWire objectType objectId) =
    Aeson.object ["objectType" .= objectType, "objectId" .= objectId]
  toEncoding (ObjectRefWire objectType objectId) =
    pairs ("objectType" .= objectType <> "objectId" .= objectId)

instance FromJSON ObjectRefWire where
  parseJSON = withObject "ObjectRefWire" $ \o ->
    ObjectRefWire <$> o .: "objectType" <*> o .: "objectId"

data SubjectWire
  = SubjectIdWire !ObjectRefWire
  | SubjectSetWire !ObjectRefWire !Text
  | SubjectWildcardWire !Text
  deriving stock (Eq, Show)

instance ToJSON SubjectWire where
  toJSON = \case
    SubjectIdWire (ObjectRefWire objectType objectId) ->
      Aeson.object ["kind" .= ("id" :: Text), "objectType" .= objectType, "objectId" .= objectId]
    SubjectSetWire (ObjectRefWire objectType objectId) relation ->
      Aeson.object ["kind" .= ("set" :: Text), "objectType" .= objectType, "objectId" .= objectId, "relation" .= relation]
    SubjectWildcardWire objectType ->
      Aeson.object ["kind" .= ("wildcard" :: Text), "objectType" .= objectType]
  toEncoding = \case
    SubjectIdWire (ObjectRefWire objectType objectId) ->
      pairs ("kind" .= ("id" :: Text) <> "objectType" .= objectType <> "objectId" .= objectId)
    SubjectSetWire (ObjectRefWire objectType objectId) relation ->
      pairs ("kind" .= ("set" :: Text) <> "objectType" .= objectType <> "objectId" .= objectId <> "relation" .= relation)
    SubjectWildcardWire objectType ->
      pairs ("kind" .= ("wildcard" :: Text) <> "objectType" .= objectType)

instance FromJSON SubjectWire where
  parseJSON = withObject "SubjectWire" $ \o ->
    o .: "kind" >>= \case
      "id" -> SubjectIdWire <$> (ObjectRefWire <$> o .: "objectType" <*> o .: "objectId")
      "set" -> SubjectSetWire <$> (ObjectRefWire <$> o .: "objectType" <*> o .: "objectId") <*> o .: "relation"
      "wildcard" -> SubjectWildcardWire <$> o .: "objectType"
      other -> fail ("unknown subject kind: " <> T.unpack other)

data TupleWire = TupleWire
  { object :: !ObjectRefWire
  , relation :: !Text
  , subject :: !SubjectWire
  , caveat :: !(Maybe ())
  }
  deriving stock (Eq, Show)

instance ToJSON TupleWire where
  toJSON (TupleWire object relation subject caveat) =
    Aeson.object ["object" .= object, "relation" .= relation, "subject" .= subject, "caveat" .= caveat]
  toEncoding (TupleWire object relation subject caveat) =
    pairs ("object" .= object <> "relation" .= relation <> "subject" .= subject <> "caveat" .= caveat)

instance FromJSON TupleWire where
  parseJSON = withObject "TupleWire" $ \o ->
    TupleWire <$> o .: "object" <*> o .: "relation" <*> o .: "subject" <*> o .: "caveat"

newtype WriteTuplesRequestWire = WriteTuplesRequestWire
  { tuples :: [TupleWire]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

newtype DeleteTuplesRequestWire = DeleteTuplesRequestWire
  { tuples :: [TupleWire]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

newtype WriteTuplesResponseWire = WriteTuplesResponseWire
  { token :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

data ConsistencyWire
  = MinimizeLatencyWire
  | FullyConsistentWire
  | AtLeastAsFreshWire !Text
  | AtExactSnapshotWire !Text
  deriving stock (Eq, Show)

instance ToJSON ConsistencyWire where
  toJSON = \case
    MinimizeLatencyWire -> Aeson.object ["mode" .= ("minimizeLatency" :: Text)]
    FullyConsistentWire -> Aeson.object ["mode" .= ("fullyConsistent" :: Text)]
    AtLeastAsFreshWire token -> Aeson.object ["mode" .= ("atLeastAsFresh" :: Text), "token" .= token]
    AtExactSnapshotWire token -> Aeson.object ["mode" .= ("atExactSnapshot" :: Text), "token" .= token]
  toEncoding = \case
    MinimizeLatencyWire -> pairs ("mode" .= ("minimizeLatency" :: Text))
    FullyConsistentWire -> pairs ("mode" .= ("fullyConsistent" :: Text))
    AtLeastAsFreshWire token -> pairs ("mode" .= ("atLeastAsFresh" :: Text) <> "token" .= token)
    AtExactSnapshotWire token -> pairs ("mode" .= ("atExactSnapshot" :: Text) <> "token" .= token)

instance FromJSON ConsistencyWire where
  parseJSON = withObject "ConsistencyWire" $ \o ->
    o .: "mode" >>= \case
      "minimizeLatency" -> pure MinimizeLatencyWire
      "fullyConsistent" -> pure FullyConsistentWire
      "atLeastAsFresh" -> AtLeastAsFreshWire <$> o .: "token"
      "atExactSnapshot" -> AtExactSnapshotWire <$> o .: "token"
      other -> fail ("unknown consistency mode: " <> T.unpack other)

newtype CaveatContextWire = CaveatContextWire
  { values :: Map.Map Text ()
  }
  deriving stock (Eq, Show)

instance ToJSON CaveatContextWire where
  toJSON (CaveatContextWire values) = Aeson.object ["values" .= values]
  toEncoding (CaveatContextWire values) = pairs ("values" .= values)

data ExpandRequestWire = ExpandRequestWire
  { consistency :: !ConsistencyWire
  , object :: !ObjectRefWire
  , permission :: !Text
  , context :: !CaveatContextWire
  , limit :: !Int
  , cursor :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance ToJSON ExpandRequestWire where
  toJSON (ExpandRequestWire consistency object permission context limit cursor) =
    Aeson.object
      [ "consistency" .= consistency
      , "object" .= object
      , "permission" .= permission
      , "context" .= context
      , "limit" .= limit
      , "cursor" .= cursor
      ]
  toEncoding (ExpandRequestWire consistency object permission context limit cursor) =
    pairs
      ( "consistency" .= consistency
          <> "object" .= object
          <> "permission" .= permission
          <> "context" .= context
          <> "limit" .= limit
          <> "cursor" .= cursor
      )

data ExpandNodeWire
  = ExpandSubjectWire !SubjectWire
  | ExpandUsersetWire !ObjectRefWire !Text ![ExpandNodeWire]
  | ExpandCaveatedWire !Text ![ExpandNodeWire]
  | ExpandUnionWire ![ExpandNodeWire]
  | ExpandIntersectionWire ![ExpandNodeWire]
  | ExpandExclusionWire ![ExpandNodeWire] ![ExpandNodeWire]
  deriving stock (Eq, Show)

instance ToJSON ExpandNodeWire where
  toJSON = \case
    ExpandSubjectWire subject -> Aeson.object ["kind" .= ("subject" :: Text), "subject" .= subject]
    ExpandUsersetWire object relation children ->
      Aeson.object ["kind" .= ("userset" :: Text), "object" .= object, "relation" .= relation, "children" .= children]
    ExpandCaveatedWire caveat children ->
      Aeson.object ["kind" .= ("caveated" :: Text), "caveat" .= caveat, "children" .= children]
    ExpandUnionWire children -> Aeson.object ["kind" .= ("union" :: Text), "children" .= children]
    ExpandIntersectionWire children -> Aeson.object ["kind" .= ("intersection" :: Text), "children" .= children]
    ExpandExclusionWire granted subtracted ->
      Aeson.object ["kind" .= ("exclusion" :: Text), "granted" .= granted, "subtracted" .= subtracted]
  toEncoding = \case
    ExpandSubjectWire subject -> pairs ("kind" .= ("subject" :: Text) <> "subject" .= subject)
    ExpandUsersetWire object relation children ->
      pairs ("kind" .= ("userset" :: Text) <> "object" .= object <> "relation" .= relation <> "children" .= children)
    ExpandCaveatedWire caveat children ->
      pairs ("kind" .= ("caveated" :: Text) <> "caveat" .= caveat <> "children" .= children)
    ExpandUnionWire children -> pairs ("kind" .= ("union" :: Text) <> "children" .= children)
    ExpandIntersectionWire children -> pairs ("kind" .= ("intersection" :: Text) <> "children" .= children)
    ExpandExclusionWire granted subtracted ->
      pairs ("kind" .= ("exclusion" :: Text) <> "granted" .= granted <> "subtracted" .= subtracted)

instance FromJSON ExpandNodeWire where
  parseJSON = withObject "ExpandNodeWire" $ \o ->
    o .: "kind" >>= \case
      "subject" -> ExpandSubjectWire <$> o .: "subject"
      "userset" -> ExpandUsersetWire <$> o .: "object" <*> o .: "relation" <*> o .: "children"
      "caveated" -> ExpandCaveatedWire <$> o .: "caveat" <*> o .: "children"
      "union" -> ExpandUnionWire <$> o .: "children"
      "intersection" -> ExpandIntersectionWire <$> o .: "children"
      "exclusion" -> ExpandExclusionWire <$> o .: "granted" <*> o .: "subtracted"
      other -> fail ("unknown expand node kind: " <> T.unpack other)

data ExpandTreeWire = ExpandTreeWire
  { root :: !ObjectRefWire
  , permission :: !Text
  , children :: ![ExpandNodeWire]
  , state :: !ExpandStateWire
  , checkedAt :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

data ExpandStateWire
  = ExpandExhaustedWire
  | ExpandHasMoreWire !Text
  | ExpandTruncatedWire !Text
  deriving stock (Eq, Show)

instance ToJSON ExpandStateWire where
  toJSON = \case
    ExpandExhaustedWire -> Aeson.object ["status" .= ("exhausted" :: Text)]
    ExpandHasMoreWire cursor -> Aeson.object ["status" .= ("hasMore" :: Text), "cursor" .= cursor]
    ExpandTruncatedWire cursor -> Aeson.object ["status" .= ("truncated" :: Text), "cursor" .= cursor]
  toEncoding = \case
    ExpandExhaustedWire -> pairs ("status" .= ("exhausted" :: Text))
    ExpandHasMoreWire cursor -> pairs ("status" .= ("hasMore" :: Text) <> "cursor" .= cursor)
    ExpandTruncatedWire cursor -> pairs ("status" .= ("truncated" :: Text) <> "cursor" .= cursor)

instance FromJSON ExpandStateWire where
  parseJSON = withObject "ExpandStateWire" $ \o ->
    o .: "status" >>= \case
      "exhausted" -> pure ExpandExhaustedWire
      "hasMore" -> ExpandHasMoreWire <$> o .: "cursor"
      "truncated" -> ExpandTruncatedWire <$> o .: "cursor"
      other -> fail ("unknown expand status: " <> T.unpack other)

runAccessGrant :: AccessGrantParams -> IO ()
runAccessGrant params = do
  response <- enRequest (agpEnUrl params) (agpEnApiKey params) methodPost "/v1/relationships" (WriteTuplesRequestWire [accessTuple (agpHost params) (agpUser params)])
  TIO.putStrLn ("Granted " <> agpUser params <> " access to " <> canonicalHost (agpHost params) <> " (token " <> token response <> ").")

runAccessRevoke :: AccessGrantParams -> IO ()
runAccessRevoke params = do
  response <- enRequest (agpEnUrl params) (agpEnApiKey params) methodPost "/v1/relationships/delete" (DeleteTuplesRequestWire [accessTuple (agpHost params) (agpUser params)])
  TIO.putStrLn ("Revoked " <> agpUser params <> " access to " <> canonicalHost (agpHost params) <> " (token " <> token response <> ").")

runAccessList :: AccessListParams -> IO AccessListResult
runAccessList params = do
  tree <- enRequest (alpEnUrl params) (alpEnApiKey params) methodPost "/v1/expand" (expandRequest (alpHost params))
  let result = AccessListResult (collectExpandedSubjects tree)
  if null (users result)
    then TIO.putStrLn "(none)"
    else mapM_ TIO.putStrLn (users result)
  pure result

accessTuple :: Text -> Text -> TupleWire
accessTuple host user =
  TupleWire
    { object = ObjectRefWire "app" (canonicalHost host)
    , relation = "viewer"
    , subject = SubjectIdWire (ObjectRefWire "user" user)
    , caveat = Nothing
    }

expandRequest :: Text -> ExpandRequestWire
expandRequest host =
  ExpandRequestWire
    { consistency = MinimizeLatencyWire
    , object = ObjectRefWire "app" (canonicalHost host)
    , permission = "access"
    , context = CaveatContextWire Map.empty
    , limit = 1000
    , cursor = Nothing
    }

collectExpandedSubjects :: ExpandTreeWire -> [Text]
collectExpandedSubjects tree =
  T.strip <$> concatMap collectNode (children tree)
  where
    collectNode = \case
      ExpandSubjectWire (SubjectIdWire (ObjectRefWire "user" user)) -> [user]
      ExpandSubjectWire (SubjectIdWire ref) -> [objectType ref <> ":" <> objectId ref]
      ExpandSubjectWire (SubjectSetWire ref relation) -> [objectType ref <> ":" <> objectId ref <> "#" <> relation]
      ExpandSubjectWire (SubjectWildcardWire typ) -> [typ <> ":*"]
      ExpandUsersetWire _ _ nodes -> concatMap collectNode nodes
      ExpandCaveatedWire _ nodes -> concatMap collectNode nodes
      ExpandUnionWire nodes -> concatMap collectNode nodes
      ExpandIntersectionWire nodes -> concatMap collectNode nodes
      ExpandExclusionWire granted _subtracted -> concatMap collectNode granted

enRequest :: (ToJSON body, FromJSON response) => Maybe Text -> Maybe Text -> BC.ByteString -> String -> body -> IO response
enRequest configuredUrl configuredApiKey method path body = do
  base <- resolveEnUrl configuredUrl
  apiKey <- resolveEnApiKey configuredApiKey
  manager <- newManager tlsManagerSettings
  initial <- parseRequest (T.unpack (trimTrailingSlash base) <> path)
  let request =
        initial
          { method
          , requestHeaders = [(hAuthorization, "Bearer " <> TE.encodeUtf8 apiKey), (hContentType, "application/json")]
          , requestBody = RequestBodyLBS (encode body)
          , responseTimeout = responseTimeoutMicro 30000000
          }
  response <- httpLbs request manager
  let status = responseStatus response
      bytes = responseBody response
  if statusCode status >= 200 && statusCode status < 300
    then case eitherDecode bytes of
      Left err -> dieT ("en returned malformed JSON: " <> T.pack err)
      Right value -> pure value
    else
      let detail =
            case eitherDecode bytes of
              Right (EnErrorEnvelope _ message _) -> message
              Left _ -> T.take 500 (decodeUtf8Lenient bytes)
       in dieT ("en request failed with HTTP " <> T.pack (show (statusCode status)) <> ": " <> detail)

data EnErrorEnvelope = EnErrorEnvelope !Text !Text !Bool

instance FromJSON EnErrorEnvelope where
  parseJSON = withObject "EnErrorEnvelope" $ \o ->
    EnErrorEnvelope <$> o .: "code" <*> o .: "message" <*> o .: "retryable"

resolveEnUrl :: Maybe Text -> IO Text
resolveEnUrl (Just url) = pure url
resolveEnUrl Nothing =
  lookupEnv "NAGARE_EN_URL" >>= \case
    Just url | not (null url) -> pure (T.pack url)
    _ ->
      dieT
        "missing en URL; pass --en-url URL or set NAGARE_EN_URL (for example, http://localhost:8090)"

resolveEnApiKey :: Maybe Text -> IO Text
resolveEnApiKey (Just key) | not (T.null (T.strip key)) = pure (T.strip key)
resolveEnApiKey _ =
  lookupEnv "NAGARE_EN_API_KEY" >>= \case
    Just key | not (T.null (T.strip (T.pack key))) -> pure (T.strip (T.pack key))
    _ -> dieT "missing en API key; pass --en-api-key KEY or set NAGARE_EN_API_KEY"

canonicalHost :: Text -> Text
canonicalHost =
  T.toLower . T.dropWhileEnd (== '.') . T.strip

trimTrailingSlash :: Text -> Text
trimTrailingSlash =
  T.dropWhileEnd (== '/')

decodeUtf8Lenient :: LBS.ByteString -> Text
decodeUtf8Lenient =
  T.pack . BC.unpack . LBS.toStrict

dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
