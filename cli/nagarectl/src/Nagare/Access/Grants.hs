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
  , runAccessGrant
  , runAccessList
  , runAccessRevoke
  )
where

import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import GHC.Generics (Generic)
import Nagare.Dsl.Prelude hiding (children)
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (hContentType)
import Network.HTTP.Types.Method (methodDelete, methodPost)
import Network.HTTP.Types.Status (statusCode)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (stderr)

data AccessGrantParams = AccessGrantParams
  { agpEnUrl :: !(Maybe Text)
  , agpHost :: !Text
  , agpUser :: !Text
  }
  deriving stock (Generic, Eq, Show)

data AccessListParams = AccessListParams
  { alpEnUrl :: !(Maybe Text)
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
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SubjectWire
  = SubjectIdWire !ObjectRefWire
  | SubjectSetWire !ObjectRefWire !Text
  | SubjectWildcardWire !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data TupleWire = TupleWire
  { object :: !ObjectRefWire
  , relation :: !Text
  , subject :: !SubjectWire
  , caveat :: !(Maybe ())
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

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
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

newtype CaveatContextWire = CaveatContextWire
  { values :: Map.Map Text ()
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data ExpandRequestWire = ExpandRequestWire
  { consistency :: !ConsistencyWire
  , object :: !ObjectRefWire
  , permission :: !Text
  , context :: !CaveatContextWire
  , limit :: !Int
  , cursor :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data ExpandNodeWire
  = ExpandSubjectWire !SubjectWire
  | ExpandUsersetWire !ObjectRefWire !Text ![ExpandNodeWire]
  | ExpandCaveatedWire !Text ![ExpandNodeWire]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

data ExpandTreeWire = ExpandTreeWire
  { root :: !ObjectRefWire
  , permission :: !Text
  , children :: ![ExpandNodeWire]
  , state :: !ExpandStateWire
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

data ExpandStateWire
  = ExpandExhaustedWire
  | ExpandHasMoreWire !Text
  | ExpandTruncatedWire !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

runAccessGrant :: AccessGrantParams -> IO ()
runAccessGrant params = do
  response <- enRequest (agpEnUrl params) methodPost "/tuples" (WriteTuplesRequestWire [accessTuple (agpHost params) (agpUser params)])
  TIO.putStrLn ("Granted " <> agpUser params <> " access to " <> canonicalHost (agpHost params) <> " (token " <> token response <> ").")

runAccessRevoke :: AccessGrantParams -> IO ()
runAccessRevoke params = do
  response <- enRequest (agpEnUrl params) methodDelete "/tuples" (DeleteTuplesRequestWire [accessTuple (agpHost params) (agpUser params)])
  TIO.putStrLn ("Revoked " <> agpUser params <> " access to " <> canonicalHost (agpHost params) <> " (token " <> token response <> ").")

runAccessList :: AccessListParams -> IO AccessListResult
runAccessList params = do
  tree <- enRequest (alpEnUrl params) methodPost "/expand" (expandRequest (alpHost params))
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

enRequest :: (ToJSON body, FromJSON response) => Maybe Text -> BC.ByteString -> String -> body -> IO response
enRequest configuredUrl method path body = do
  base <- resolveEnUrl configuredUrl
  manager <- newManager tlsManagerSettings
  initial <- parseRequest (T.unpack (trimTrailingSlash base) <> path)
  let request =
        initial
          { method
          , requestHeaders = [(hContentType, "application/json")]
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
    else dieT ("en request failed with HTTP " <> T.pack (show (statusCode status)) <> ": " <> T.take 500 (decodeUtf8Lenient bytes))

resolveEnUrl :: Maybe Text -> IO Text
resolveEnUrl (Just url) = pure url
resolveEnUrl Nothing =
  lookupEnv "NAGARE_EN_URL" >>= \case
    Just url | not (null url) -> pure (T.pack url)
    _ ->
      dieT
        "missing en URL; pass --en-url URL or set NAGARE_EN_URL (for example, http://localhost:8090)"

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
