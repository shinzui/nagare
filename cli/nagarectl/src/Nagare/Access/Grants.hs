-- | Operator commands for granting and revoking access to protected Nagare apps.
module Nagare.Access.Grants
  ( AccessGrantParams (..)
  , AccessListParams (..)
  , HostGrants (..)
  , ObjectRefWire (..)
  , SubjectWire (..)
  , TupleWire (..)
  , RelationshipFilter (..)
  , RelationshipPage (..)
  , accessTuple
  , teamAccessTuple
  , teamMemberTuple
  , hostGrantsFilter
  , teamMembersFilter
  , listRelationships
  , hostGrantsOf
  , teamMembersOf
  , maxListedPages
  , relationshipQueryPath
  , runAccessGrant
  , runAccessRevoke
  , runHostGrantsList
  , runTeamMembersList
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecode, encode, pairs, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encoding (pair)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
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
import Network.HTTP.Types.URI (urlEncode)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (stderr)

data AccessGrantParams = AccessGrantParams
  { enUrl :: !(Maybe Text)
  , enApiKey :: !(Maybe Text)
  , host :: !Text
  , user :: !Text
  }
  deriving stock (Generic, Eq, Show)

data AccessListParams = AccessListParams
  { enUrl :: !(Maybe Text)
  , enApiKey :: !(Maybe Text)
  , host :: !Text
  , json :: !Bool
  }
  deriving stock (Generic, Eq, Show)

data ObjectRefWire = ObjectRefWire
  { objectType :: !Text
  , objectId :: !Text
  }
  deriving stock (Generic, Eq, Show)

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
  deriving stock (Generic, Eq, Show)

instance ToJSON TupleWire where
  toJSON (TupleWire object relation subject caveat) =
    Aeson.object ["object" .= object, "relation" .= relation, "subject" .= subject, "caveat" .= caveat]
  toEncoding (TupleWire object relation subject caveat) =
    pairs ("object" .= object <> "relation" .= relation <> "subject" .= subject <> "caveat" .= caveat)

instance FromJSON TupleWire where
  parseJSON = withObject "TupleWire" $ \o ->
    TupleWire <$> o .: "object" <*> o .: "relation" <*> o .: "subject" <*> o .:? "caveat"

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

-- | A stored-relationship filter for @POST /v1/relationships/query@: one
-- object and relation, every subject. Listing never expands a permission, so
-- a team is reported as the userset it is, not as its members.
data RelationshipFilter = RelationshipFilter
  { objectType :: !Text
  , objectId :: !Text
  , relation :: !Text
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON RelationshipFilter where
  toJSON (RelationshipFilter objectType objectId relation) =
    Aeson.object
      [ "consistency" .= Aeson.object ["mode" .= ("fullyConsistent" :: Text)]
      , "filter" .= Aeson.object ["objectType" .= objectType, "objectId" .= objectId, "relation" .= relation]
      ]
  toEncoding (RelationshipFilter objectType objectId relation) =
    pairs
      ( "consistency" `pair` pairs ("mode" .= ("fullyConsistent" :: Text))
          <> "filter" `pair` pairs ("objectType" .= objectType <> "objectId" .= objectId <> "relation" .= relation)
      )

-- | One Relay page of stored relationships: the nodes and the continuation.
data RelationshipPage = RelationshipPage
  { nodes :: ![TupleWire]
  , hasNextPage :: !Bool
  , endCursor :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON RelationshipPage where
  parseJSON = withObject "relationship page" $ \o -> do
    edges <- o .: "edges"
    nodes <- traverse (withObject "edge" (.: "node")) edges
    info <- o .: "pageInfo"
    (hasNextPage, endCursor) <- withObject "page info" (\p -> (,) <$> p .: "hasNextPage" <*> p .:? "endCursor") info
    pure RelationshipPage {nodes, hasNextPage, endCursor}

hostGrantsFilter :: Text -> RelationshipFilter
hostGrantsFilter host = RelationshipFilter "app" (canonicalHost host) "viewer"

teamMembersFilter :: Text -> RelationshipFilter
teamMembersFilter team = RelationshipFilter "group" team "member"

-- | The most pages one listing follows. A hundred pages of a hundred tuples
-- is far beyond any host's grants; past it the listing is incomplete and says
-- so rather than printing a partial list as if it were the whole.
maxListedPages :: Int
maxListedPages = 100

-- | The query path for one page: a full page, continued from the server's
-- opaque cursor, which binds the continuation to the first page's snapshot.
relationshipQueryPath :: Maybe Text -> String
relationshipQueryPath cursor =
  "/v1/relationships/query?first=100"
    <> maybe "" (\c -> "&after=" <> BC.unpack (urlEncode True (TE.encodeUtf8 c))) cursor

-- | Drain a listing page by page. The fetcher takes the cursor to continue
-- from. A repeated cursor or more than 'maxListedPages' pages is an
-- incomplete listing, never an empty or complete one.
listRelationships :: (Monad m) => (Maybe Text -> m RelationshipPage) -> m (Either Text [TupleWire])
listRelationships fetch = go Nothing [] (0 :: Int)
  where
    go cursor seen pages
      | pages >= maxListedPages = pure (Left ("listing incomplete: more than " <> T.pack (show maxListedPages) <> " pages"))
      | otherwise = do
          page <- fetch cursor
          let collected = seen <> (page ^. #nodes)
          case (page ^. #hasNextPage, page ^. #endCursor) of
            (False, _) -> pure (Right collected)
            (True, Nothing) -> pure (Left "listing incomplete: the server reported more pages without a cursor")
            (True, Just next)
              | Just next == cursor -> pure (Left "listing incomplete: the server repeated a continuation cursor")
              | otherwise -> go (Just next) collected (pages + 1)

-- | A host's stored grants, direct users apart from team usersets. Anything
-- else on the viewer relation is reported verbatim rather than hidden.
data HostGrants = HostGrants
  { users :: ![Text]
  , teams :: ![Text]
  , other :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON HostGrants where
  toJSON grants = Aeson.object ["users" .= (grants ^. #users), "teams" .= (grants ^. #teams), "other" .= (grants ^. #other)]

hostGrantsOf :: Text -> [TupleWire] -> HostGrants
hostGrantsOf host tuples = foldr classify (HostGrants [] [] []) tuples
  where
    expectedObject = ObjectRefWire "app" (canonicalHost host)
    classify tuple grants
      | tuple ^. #object == expectedObject && tuple ^. #relation == "viewer" && isNothing (tuple ^. #caveat) =
          case tuple ^. #subject of
            SubjectIdWire (ObjectRefWire "user" user) -> grants & #users %~ (user :)
            SubjectSetWire (ObjectRefWire "group" team) "member" -> grants & #teams %~ (team :)
            subject -> grants & #other %~ (subjectText subject :)
      | otherwise = grants & #other %~ (tupleText tuple :)

teamMembersOf :: Text -> [TupleWire] -> ([Text], [Text])
teamMembersOf team = foldr classify ([], [])
  where
    classify tuple (members, others)
      | tuple ^. #object == ObjectRefWire "group" team && tuple ^. #relation == "member" && isNothing (tuple ^. #caveat)
      , SubjectIdWire (ObjectRefWire "user" user) <- tuple ^. #subject =
          (user : members, others)
      | otherwise = (members, tupleText tuple : others)

subjectText :: SubjectWire -> Text
subjectText = \case
  SubjectIdWire ref -> ref ^. #objectType <> ":" <> ref ^. #objectId
  SubjectSetWire ref relation -> ref ^. #objectType <> ":" <> ref ^. #objectId <> "#" <> relation
  SubjectWildcardWire typ -> typ <> ":*"

tupleText :: TupleWire -> Text
tupleText tuple =
  tuple ^. #object . #objectType
    <> ":"
    <> tuple ^. #object . #objectId
    <> "#"
    <> tuple ^. #relation
    <> "@"
    <> subjectText (tuple ^. #subject)
    <> maybe "" (const " (caveated)") (tuple ^. #caveat)

runAccessGrant :: AccessGrantParams -> IO ()
runAccessGrant params = do
  response <- (enRequest (params ^. #enUrl) (params ^. #enApiKey) methodPost "/v1/relationships" (WriteTuplesRequestWire [accessTuple (params ^. #host) (params ^. #user)]) :: IO WriteTuplesResponseWire)
  TIO.putStrLn ("Granted " <> params ^. #user <> " access to " <> canonicalHost (params ^. #host) <> " (token " <> response ^. #token <> ").")

runAccessRevoke :: AccessGrantParams -> IO ()
runAccessRevoke params = do
  response <- (enRequest (params ^. #enUrl) (params ^. #enApiKey) methodPost "/v1/relationships/delete" (DeleteTuplesRequestWire [accessTuple (params ^. #host) (params ^. #user)]) :: IO WriteTuplesResponseWire)
  TIO.putStrLn ("Revoked " <> params ^. #user <> " access to " <> canonicalHost (params ^. #host) <> " (token " <> response ^. #token <> ").")

-- | @access list --host@: the stored viewer relationships of one host, direct
-- users and team usersets apart. Effective access is @access check@'s job.
runHostGrantsList :: AccessListParams -> IO HostGrants
runHostGrantsList params = do
  tuples <- drain (params ^. #enUrl) (params ^. #enApiKey) (hostGrantsFilter (params ^. #host))
  let grants = hostGrantsOf (params ^. #host) tuples
  if params ^. #json
    then LBS.putStr (encode (Aeson.object ["host" .= canonicalHost (params ^. #host), "grants" .= grants])) >> TIO.putStrLn ""
    else do
      TIO.putStrLn ("direct users (" <> count (grants ^. #users) <> "):")
      mapM_ (TIO.putStrLn . ("  " <>)) (grants ^. #users)
      TIO.putStrLn ("teams (" <> count (grants ^. #teams) <> "):")
      mapM_ (TIO.putStrLn . ("  " <>)) (grants ^. #teams)
      unless (null (grants ^. #other)) $ do
        TIO.putStrLn ("other stored relationships (" <> count (grants ^. #other) <> "):")
        mapM_ (TIO.putStrLn . ("  " <>)) (grants ^. #other)
  pure grants
  where
    count = T.pack . show . length

-- | @access team list-members --team@: a team's stored memberships.
runTeamMembersList :: Maybe Text -> Maybe Text -> Text -> Bool -> IO [Text]
runTeamMembersList configuredUrl configuredKey team json = do
  tuples <- drain configuredUrl configuredKey (teamMembersFilter team)
  let (members, others) = teamMembersOf team tuples
  if json
    then LBS.putStr (encode (Aeson.object ["team" .= team, "members" .= members, "other" .= others])) >> TIO.putStrLn ""
    else do
      TIO.putStrLn ("members of " <> team <> " (" <> T.pack (show (length members)) <> "):")
      mapM_ (TIO.putStrLn . ("  " <>)) members
      unless (null others) $ do
        TIO.putStrLn ("other stored relationships (" <> T.pack (show (length others)) <> "):")
        mapM_ (TIO.putStrLn . ("  " <>)) others
  pure members

drain :: Maybe Text -> Maybe Text -> RelationshipFilter -> IO [TupleWire]
drain configuredUrl configuredKey query = do
  base <- resolveEnUrl configuredUrl
  apiKey <- resolveEnApiKey configuredKey
  manager <- newManager tlsManagerSettings
  listed <- listRelationships (\cursor -> enRequestWith manager base apiKey methodPost (relationshipQueryPath cursor) query)
  either dieT pure listed

accessTuple :: Text -> Text -> TupleWire
accessTuple host user =
  TupleWire
    { object = ObjectRefWire "app" (canonicalHost host)
    , relation = "viewer"
    , subject = SubjectIdWire (ObjectRefWire "user" user)
    , caveat = Nothing
    }

-- | A user's membership in a team: @group:<team>#member@user:<id>@ (EP-187).
teamMemberTuple :: Text -> Text -> TupleWire
teamMemberTuple team user =
  TupleWire
    { object = ObjectRefWire "group" team
    , relation = "member"
    , subject = SubjectIdWire (ObjectRefWire "user" user)
    , caveat = Nothing
    }

-- | A team's grant on a host: @app:<host>#viewer@group:<team>#member@. The
-- subject is a userset, so every current member of the team is a viewer and
-- nobody else.
teamAccessTuple :: Text -> Text -> TupleWire
teamAccessTuple host team =
  TupleWire
    { object = ObjectRefWire "app" (canonicalHost host)
    , relation = "viewer"
    , subject = SubjectSetWire (ObjectRefWire "group" team) "member"
    , caveat = Nothing
    }

enRequest :: (ToJSON body, FromJSON response) => Maybe Text -> Maybe Text -> BC.ByteString -> String -> body -> IO response
enRequest configuredUrl configuredApiKey method path body = do
  base <- resolveEnUrl configuredUrl
  apiKey <- resolveEnApiKey configuredApiKey
  manager <- newManager tlsManagerSettings
  enRequestWith manager base apiKey method path body

-- | One request on a shared connection manager, so a drained listing reuses
-- one connection rather than opening one per page.
enRequestWith :: (ToJSON body, FromJSON response) => Manager -> Text -> Text -> BC.ByteString -> String -> body -> IO response
enRequestWith manager base apiKey method path body = do
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
