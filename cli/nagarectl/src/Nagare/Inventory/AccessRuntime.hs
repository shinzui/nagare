-- | Private credential transport for exact reviewed en tuples.
module Nagare.Inventory.AccessRuntime
  ( EnCall
  , EnTransport (..)
  , EnForwarder (..)
  , accessRuntimeOpsWith
  , kubectlTransport
  , withEnSession
  , withEnSessionUsing
  , accessKeyRefusal
  , accessQuery
  , accessMutation
  , parseAccessPage
  , accessReviewAdapter
  , parseAccessCapabilities
  , parseEnForwardPort
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Control.Exception (IOException, bracket, catch, onException, try)
import Control.Monad (join)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isRight)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Access.Grants (TupleWire, accessTuple, teamAccessTuple, teamMemberTuple)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Access
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Inventory.Plan (ReviewBundle, ReviewDocument (reviewOperations), ReviewInventory, ReviewOperation (reviewPlannedOperation), reviewBaseRevisions, reviewBundleDocument, reviewBundleScopes, reviewDesiredRevisions, reviewInventoryHistory)
import Nagare.Inventory.Plan.Types (historyDeclarations)
import Nagare.Inventory.Store (InventoryStore, readObject, revisionDigest, scopeKey)
import Nagare.Resource.Access (teamKeyText)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope)
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hGetLine)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, getProcessExitCode, proc, readProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)

accessQuery :: AccessBinding -> Value
accessQuery binding =
  object
    [ "consistency" .= object ["mode" .= ("fullyConsistent" :: Text)]
    , "filter" .= tupleFilter binding
    ]

accessMutation :: AccessBinding -> AccessFact -> Value
accessMutation binding before =
  object
    [ "tuples" .= [tuple | wanted binding]
    , "deletes" .= [tuple | not (wanted binding)]
    , "preconditions"
        .= [ object
               [ "kind" .= (if accessPresent before then "mustExist" else "mustNotExist" :: Text)
               , "filter" .= tupleFilter binding
               ]
           ]
    ]
  where
    tuple = maybe Null toJSON (relationshipTuple binding)

wanted :: AccessBinding -> Bool
wanted binding = case accessResource binding ^. #spec of AccessGrantSpec _ granted -> granted; _ -> False

-- | The exact tuple a binding writes or deletes, in en's wire form.
relationshipTuple :: AccessBinding -> Maybe TupleWire
relationshipTuple binding = case relationshipOf (accessResource binding ^. #address) of
  Just (_, DirectViewer host subject) -> Just (accessTuple (nameText host) subject)
  Just (_, TeamMember team subject) -> Just (teamMemberTuple (teamKeyText team) subject)
  Just (_, TeamViewer host team) -> Just (teamAccessTuple (nameText host) (teamKeyText team))
  Nothing -> Nothing

-- | The exact filter for one relationship: every field named, and the subject
-- relation pinned, so a concrete user never matches a userset over that user
-- and a team grant never matches a direct one.
tupleFilter :: AccessBinding -> Value
tupleFilter binding = case relationshipOf (accessResource binding ^. #address) of
  Just (_, DirectViewer host subject) ->
    object
      [ "objectType" .= ("app" :: Text)
      , "objectId" .= nameText host
      , "relation" .= ("viewer" :: Text)
      , "subjectType" .= ("user" :: Text)
      , "subjectId" .= subject
      , "subjectRelation" .= object ["match" .= ("none" :: Text)]
      ]
  Just (_, TeamMember team subject) ->
    object
      [ "objectType" .= ("group" :: Text)
      , "objectId" .= teamKeyText team
      , "relation" .= ("member" :: Text)
      , "subjectType" .= ("user" :: Text)
      , "subjectId" .= subject
      , "subjectRelation" .= object ["match" .= ("none" :: Text)]
      ]
  Just (_, TeamViewer host team) ->
    object
      [ "objectType" .= ("app" :: Text)
      , "objectId" .= nameText host
      , "relation" .= ("viewer" :: Text)
      , "subjectType" .= ("group" :: Text)
      , "subjectId" .= teamKeyText team
      , "subjectRelation" .= object ["match" .= ("exact" :: Text), "relation" .= ("member" :: Text)]
      ]
  Nothing -> Null

-- No expand/permission inference: only a complete page of the exact direct tuple.
-- Caveated or userset grants are distinct authority and cannot be rewritten.
parseAccessPage :: AccessBinding -> ByteString -> Either Text Bool
parseAccessPage binding bytes = do
  value <- first (const "malformed access relationship response") (eitherDecodeStrict bytes)
  (nodes, more) <- first (const "incomplete access relationship response") (parseEither page value)
  unless (not more && length nodes <= 1) (Left "access tuple query is incomplete or ambiguous")
  case nodes of
    [] -> Right False
    [node] -> do
      expected <- maybe (Left "invalid access tuple address") (Right . toJSON) (relationshipTuple binding)
      unless (node == expected) (Left "access query returned a foreign or caveated tuple")
      pure True
    _ -> Left "access query returned multiple tuples"
  where
    page :: Value -> Parser ([Value], Bool)
    page = withObject "relationship page" $ \o -> do
      edges <- o .: "edges"
      nodes <- traverse (withObject "relationship edge" (.: "node")) edges
      info <- o .: "pageInfo"
      more <- withObject "page info" (.: "hasNextPage") info
      pure (nodes, more)

-- Older API decoders may ignore extra write fields. Refuse those services
-- before admitting a mutation instead of assuming preconditions are enforced.
parseAccessCapabilities :: ByteString -> Either Text ()
parseAccessCapabilities bytes = do
  value <- first (const "malformed access API capability response") (eitherDecodeStrict bytes)
  first (const "access API lacks reviewed atomic tuple preconditions") (parseEither parser value)
  where
    parser = withObject "OpenAPI" $ \o -> do
      components <- o .: "components"
      schemas <- withObject "components" (.: "schemas") components
      requestSchema <- withObject "schemas" (.: "WriteTuplesRequestWire") schemas
      properties <- withObject "write request" (.: "properties") requestSchema
      withObject
        "properties"
        ( \props -> do
            _ <- props .: "preconditions" :: Parser Value
            _ <- props .: "deletes" :: Parser Value
            pure ()
        )
        properties

-- | How the access runtime reaches one context (EP-214): its en, the owner
-- objects of a relationship, and the cluster guard. 'withEnSession' keeps one
-- forward and one guard for a whole command; held EP-216 implements the same
-- seam over the API server's service proxy.
data EnTransport = EnTransport
  { withEn :: !(forall a. (EnCall -> IO a) -> IO (Either Text a))
  , readOwner :: !(ManagedResource -> IO (Either Text Value))
  , clusterGuard :: !(IO (Either Text ()))
  }

-- | The access operations over a transport. The capability and, for a team
-- relationship, the active schema are checked once per adapter: a success is
-- remembered, a refusal is asked again by the next phase. The owner objects
-- are read at every phase and before every write; their UIDs are what refuse
-- a write against a replaced auth service or route (F97, ADR 29).
accessRuntimeOpsWith :: EnTransport -> ContextBinding -> IO AccessOps
accessRuntimeOpsWith transport context = do
  capable <- newMVar False
  teamSchema <- newMVar False
  pure
    AccessOps
      { accessInspect = \binding -> do
          owner <- inspectOwners binding
          case owner of
            Left reason -> pure (Left reason)
            Right physical -> fmap join $ withEn transport $ \call -> do
              capability <- rememberSuccess capable $ do
                observed <- call "GET" "/v1/openapi.json" Null
                pure $ do
                  (code, bytes) <- observed
                  unless (code == 200) (Left "access API capability observation refused")
                  parseAccessCapabilities bytes
              case capability of
                Left reason -> pure (Left reason)
                Right () -> do
                  -- A team relationship needs the reviewed group schema to be
                  -- the active one; the direct form predates it (EP-187).
                  schema <-
                    if teamRelationship binding
                      then rememberSuccess teamSchema $ do
                        active <- call "GET" "/v1/schema" Null
                        pure $ do
                          (code, bytes) <- active
                          unless (code == 200) (Left "active en schema observation refused")
                          source <- first (const "malformed en schema response") (eitherDecodeStrict bytes >>= parseEither (withObject "schema" (.: "source")))
                          unless (activeSchemaSupportsTeams source) (Left "active en schema does not declare team membership; apply the reviewed auth schema update first")
                      else pure (Right ())
                  case schema of
                    Left reason -> pure (Left reason)
                    Right () -> do
                      response <- call "POST" "/v1/relationships/query?first=2" (accessQuery binding)
                      pure $ do
                        (code, bytes) <- response
                        unless (code == 200) (Left "access relationship query refused")
                        present <- parseAccessPage binding bytes
                        pure (AccessFact physical present)
      , accessWrite = \binding before -> do
          current <- inspectOwners binding
          case current of
            Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
            Right owner
              | owner /= accessPhysical before ->
                  pure (AdapterEffectFailed (KnownNoEffect "reviewed auth or route UID changed"))
            Right _ -> do
              sent <- withEn transport (\call -> call "POST" "/v1/relationships" (accessMutation binding before))
              pure $ case sent of
                -- No request left this process without a ready forward and key.
                Left reason -> AdapterEffectFailed (KnownNoEffect reason)
                Right (Left reason) -> AdapterEffectAmbiguous reason
                Right (Right (412, _)) -> AdapterEffectFailed (KnownNoEffect "atomic access tuple precondition refused")
                Right (Right (code, bytes)) | code >= 200 && code < 300 ->
                  case eitherDecodeStrict bytes >>= parseEither (withObject "write token" (.: "token")) of
                    Right (token :: Text) | not (T.null token) -> AdapterEffectCompleted
                    _ -> AdapterEffectAmbiguous "access write response has no valid consistency token"
                _ -> AdapterEffectAmbiguous "access write failed; observe the exact tuple before recovery"
      }
  where
    inspectOwners binding = do
      guarded <- clusterGuard transport
      case guarded of
        Left _ -> pure (Left "access context guard refused")
        Right () -> do
          identities <- traverse inspectOwner (accessAuth binding : maybeToList (accessRoute binding))
          pure $ do
            uids <- sequence identities
            mkPhysicalIdentity ("access-owner://" <> T.intercalate "/" uids)
    inspectOwner resource = do
      observed <- readOwner transport resource
      pure (observed >>= first (const "access owner UID or inventory binding differs") . parseEither (ownerUid resource))
    ownerUid resource = withObject "owner" $ \root -> do
      meta <- root .: "metadata"
      withObject
        "metadata"
        ( \m -> do
            uid <- m .: "uid"
            unless (not (T.null uid)) (fail "missing UID")
            annotations <- m .: "annotations"
            withObject
              "annotations"
              ( \a -> do
                  boundContext <- a .: "nagare.dev/context-id"
                  boundResource <- a .: "nagare.dev/resource-id"
                  digest <- a .: "nagare.dev/spec-digest"
                  expected <- case resource ^. #spec of
                    NativeObject d -> pure d
                    KnativeService d -> pure d
                    _ -> fail "unsupported owner specification"
                  unless
                    ( boundContext == contextIdText (context ^. #identity)
                        && boundResource == resourceIdText (resource ^. #identity)
                        && digest == digestText expected
                    )
                    (fail "foreign binding")
                  pure uid
              )
              annotations
        )
        meta

-- | Run a check until it succeeds once; a refusal is not remembered.
rememberSuccess :: MVar Bool -> IO (Either Text ()) -> IO (Either Text ())
rememberSuccess cell check =
  modifyMVar cell $ \case
    True -> pure (True, Right ())
    False -> (\result -> (isRight result, result)) <$> check

-- | One owner object of a relationship, read through the context's kubectl.
kubectlReadOwner :: Text -> ManagedResource -> IO (Either Text Value)
kubectlReadOwner kubectlContext resource = case resource ^. #address of
  Kubernetes _ group kind (Just namespace) name -> do
    let kindArg = nameText kind <> if T.null group then "" else "." <> group
    result <-
      try
        ( readProcessWithExitCode
            "kubectl"
            [ "--context"
            , T.unpack kubectlContext
            , "get"
            , T.unpack kindArg
            , T.unpack (nameText name)
            , "-n"
            , T.unpack (nameText namespace)
            , "-o"
            , "json"
            , "--request-timeout=10s"
            ]
            ""
        )
    pure $ case result of
      Left (_ :: IOException) -> Left "access owner observation failed"
      Right (ExitFailure _, _, _) -> Left "access owner observation refused"
      Right (ExitSuccess, output, _) ->
        first (const "malformed access owner observation") (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)))
  _ -> pure (Left "access dependency is not a namespaced Kubernetes object")

-- | A transport with no command-scoped session: every 'withEn' opens and
-- closes its own forward and the guard runs on every phase. For callers that
-- reach access outside the commands 'withEnSession' covers.
kubectlTransport :: Text -> IO (Either Text ()) -> EnTransport
kubectlTransport kubectlContext contextGuard =
  EnTransport
    { withEn = \action -> withEnSession kubectlContext contextGuard (\session -> withEn session action)
    , readOwner = kubectlReadOwner kubectlContext
    , clusterGuard = contextGuard
    }

-- | One request to the context's en: method, path, JSON body; en's status
-- and body, or a transport failure that withholds credentials and bodies.
type EnCall = ByteString -> Text -> Value -> IO (Either Text (Int, ByteString))

-- | Every reviewed relationship and every diagnostic reaches the context's en
-- the same way, through a private port-forward to its Service, so nothing
-- depends on the local address an operator once used (F97). One session is
-- one command (EP-214): the forward opens on first use, is reopened if its
-- kubectl exited, and is terminated when the session ends, however it ends;
-- the cluster guard runs until it succeeds once. The private
-- @NAGARE_EN_API_KEY@ is read at every call; nothing is sent without it.
withEnSession :: Text -> IO (Either Text ()) -> (EnTransport -> IO a) -> IO a
withEnSession kubectlContext =
  withEnSessionUsing (kubectlForwarder kubectlContext) (kubectlReadOwner kubectlContext)

-- | What a session needs to keep a forward: the private key, a started
-- forward with its base URL, whether it still runs, its stop, and the request
-- sent through it.
data EnForwarder forward = EnForwarder
  { forwardKey :: !(IO (Maybe String))
  , startForward :: !(IO (Either Text (forward, Text)))
  , forwardRunning :: !(forward -> IO Bool)
  , stopForward :: !(forward -> IO ())
  , forwardRequest :: !(String -> Text -> EnCall)
  }

-- | 'withEnSession' over any forwarder and owner reader, so the session's
-- forward reuse, guard and release are proved with fakes (ADR 25).
withEnSessionUsing :: forall forward a. EnForwarder forward -> (ManagedResource -> IO (Either Text Value)) -> IO (Either Text ()) -> (EnTransport -> IO a) -> IO a
withEnSessionUsing forwarder owners contextGuard action =
  bracket (newMVar Nothing) release $ \current -> do
    passed <- newMVar False
    action
      EnTransport
        { withEn = sessionCall current
        , readOwner = owners
        , clusterGuard = rememberSuccess passed contextGuard
        }
  where
    release current = readMVar current >>= traverse_ (stopForward forwarder . fst)
    sessionCall :: MVar (Maybe (forward, Text)) -> (EnCall -> IO b) -> IO (Either Text b)
    sessionCall current call = do
      credential <- forwardKey forwarder
      case credential of
        Just key | accessKeyPresent credential -> do
          ready <- modifyMVar current reuseOrOpen
          case ready of
            Left reason -> pure (Left reason)
            Right base -> first (\(_ :: IOException) -> "en port-forward failed") <$> try (call (forwardRequest forwarder key base))
        _ -> pure (Left "reviewed access requires private NAGARE_EN_API_KEY")
    reuseOrOpen open = do
      running <- case open of
        Just (forward, base) -> do
          alive <- forwardRunning forwarder forward
          if alive then pure (Just base) else Nothing <$ stopForward forwarder forward
        Nothing -> pure Nothing
      case running of
        Just base -> pure (open, Right base)
        Nothing -> do
          started <- try (startForward forwarder)
          pure $ case started of
            Right (Right (forward, base)) -> (Just (forward, base), Right base)
            Right (Left reason) -> (Nothing, Left reason)
            Left (_ :: IOException) -> (Nothing, Left "en port-forward failed")

-- | kubectl's port-forward to the context's en Service. After its first line
-- names the local port, the rest of its output is drained, so a long
-- command's per-connection lines never fill the pipe.
kubectlForwarder :: Text -> EnForwarder (Handle, ProcessHandle)
kubectlForwarder kubectlContext =
  EnForwarder
    { forwardKey = lookupEnv "NAGARE_EN_API_KEY"
    , startForward = do
        forward@(output, _) <- openEnForward kubectlContext
        ready <- timeout 15000000 (hGetLine output) `onException` closeEnForward forward
        case ready >>= parseEnForwardPort . T.pack of
          Nothing -> closeEnForward forward >> pure (Left "en port-forward did not become ready")
          Just port -> do
            _ <- forkIO (drain output)
            pure (Right (forward, "http://127.0.0.1:" <> port))
    , forwardRunning = \(_, process) -> isNothing <$> getProcessExitCode process
    , stopForward = closeEnForward
    , forwardRequest = enRequest
    }
  where
    drain output = (hGetLine output >> drain output) `catch` \(_ :: IOException) -> pure ()

accessKeyPresent :: Maybe String -> Bool
accessKeyPresent = maybe False (not . null)

-- | The refusal for a review that has access operations while the private
-- key is unset or empty. Takes the variable's value so tests need no setEnv.
accessKeyRefusal :: Maybe String -> ReviewBundle -> Maybe Text
accessKeyRefusal credential bundle
  | not (accessKeyPresent credential)
  , any ((== AccessExecutor) . plannedExecutor . reviewPlannedOperation) (reviewOperations (reviewBundleDocument bundle)) =
      Just "reviewed access requires private NAGARE_EN_API_KEY; export it in this shell and rerun this command (the saved review stays valid)"
  | otherwise = Nothing

openEnForward :: Text -> IO (Handle, ProcessHandle)
openEnForward kubectlContext = do
  (_, output, _, process) <-
    createProcess
      ( proc
          "kubectl"
          ["--context", T.unpack kubectlContext, "-n", "nagare-system", "port-forward", "svc/en", ":80", "--address", "127.0.0.1"]
      )
        { std_out = CreatePipe
        , std_err = NoStream
        }
  maybe (fail "kubectl port-forward has no output pipe") (\handle -> pure (handle, process)) output

closeEnForward :: (Handle, ProcessHandle) -> IO ()
closeEnForward (output, process) = do
  terminateProcess process `catch` \(_ :: IOException) -> pure ()
  _ <- waitForProcess process
  hClose output `catch` \(_ :: IOException) -> pure ()

enRequest :: String -> Text -> EnCall
enRequest key base verb suffix body = do
  response <- try @HttpException $ do
    manager <- newTlsManager
    initial <- parseRequest (T.unpack (base <> suffix))
    httpLbs
      initial
        { method = verb
        , requestHeaders = [("Authorization", "Bearer " <> TE.encodeUtf8 (T.pack key)), ("Content-Type", "application/json")]
        , requestBody = RequestBodyLBS (if verb == "GET" then "" else encode body)
        , responseTimeout = responseTimeoutMicro 10000000
        , redirectCount = 0
        , checkResponse = \_ _ -> pure ()
        }
      manager
  pure $ case response of
    Left _ -> Left "access transport failed; credentials and response body withheld"
    Right result -> Right (statusCode (responseStatus result), LBS.toStrict (responseBody result))

-- | The local port from kubectl's first @Forwarding from 127.0.0.1:PORT -> N@ line.
parseEnForwardPort :: Text -> Maybe Text
parseEnForwardPort line = do
  rest <- T.stripPrefix "Forwarding from 127.0.0.1:" (T.strip line)
  let (port, target) = T.breakOn " -> " rest
  unless (not (T.null port) && T.all (`elem` ['0' .. '9']) port && not (T.null (T.drop 4 target))) Nothing
  pure port

-- Select immutable desired/base members by digest; admitted state must not turn
-- a new grant into prior ownership during recovery.
accessReviewAdapter :: ReviewInventory -> ContextBinding -> EnTransport -> ReviewBundle -> IO (Either Text Adapter)
accessReviewAdapter inventory binding transport bundle = do
  desiredResult <- declarationsFor (reviewDesiredRevisions document)
  history <- reviewInventoryHistory inventory
  previousResult <- declarationsFor (reviewBaseRevisions document)
  ops <- accessRuntimeOpsWith transport binding
  pure $ do
    desired <- desiredResult
    previous <- previousResult
    composed <- first (T.pack . show) (composedDeclarations desired)
    desiredSpecs <- accessBindings composed
    acceptedDeclarations <- first (T.pack . show) history
    -- A retirement's tuple is reread at admission through its accepted binding.
    let specs = Map.union desiredSpecs (acceptedAccessBindings (historyDeclarations acceptedDeclarations))
    let accepted =
          Map.fromList
            [ (r ^. #identity, r)
            | scope <- Map.elems previous
            , b <- scopeBundles scope
            , Managed r <- b ^. #declarations
            , r ^. #executor == AccessExecutor
            ]
    pure (mkAccessAdapter accepted specs ops)
  where
    store = inventory ^. #executionStore
    document = reviewBundleDocument bundle
    declarationsFor revisions =
      fmap sequence $
        Map.traverseWithKey
          ( \owner revision -> do
              member <- case Map.lookup (revisionDigest revision) (reviewBundleScopes bundle) of
                Just bytes -> pure (Right (Just bytes))
                Nothing -> fmap (first (T.pack . show)) (readObject store (scopeKey (revisionDigest revision)))
              pure $ do
                bytes <- member >>= maybe (Left "access review scope member is missing") Right
                unless (contentDigest bytes == revisionDigest revision) (Left "access review scope digest differs")
                scope <- first (T.pack . show) (decodeScope bytes)
                unless (scopeId scope == owner) (Left "access review owner binding differs")
                pure scope
          )
          revisions
