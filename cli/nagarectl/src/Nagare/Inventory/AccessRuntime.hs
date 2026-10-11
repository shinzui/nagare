-- | Private credential transport for exact reviewed en tuples.
module Nagare.Inventory.AccessRuntime
  ( accessRuntimeOps
  , accessQuery
  , accessMutation
  , parseAccessPage
  , accessReviewAdapter
  , parseAccessCapabilities
  , parseEnForwardPort
  )
where

import Control.Exception (IOException, bracket, catch, try)
import Control.Monad (join)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Access.Grants (accessTuple)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Access
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Inventory.Plan (ReviewBundle, loadInventoryHistory, reviewBaseRevisions, reviewBundleDocument, reviewBundleScopes, reviewDesiredRevisions)
import Nagare.Inventory.Plan.Types (historyDeclarations)
import Nagare.Inventory.Store (InventoryStore, readObject, revisionDigest, scopeKey)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope)
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hGetLine)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, proc, readProcessWithExitCode, terminateProcess, waitForProcess)
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
    tuple = case accessResource binding ^. #address of
      AccessTuple _ host subject -> toJSON (accessTuple (nameText host) subject)
      _ -> Null

wanted :: AccessBinding -> Bool
wanted binding = case accessResource binding ^. #spec of AccessGrantSpec _ granted -> granted; _ -> False

tupleFilter :: AccessBinding -> Value
tupleFilter binding = case accessResource binding ^. #address of
  AccessTuple _ host subject ->
    object
      [ "objectType" .= ("app" :: Text)
      , "objectId" .= nameText host
      , "relation" .= ("viewer" :: Text)
      , "subjectType" .= ("user" :: Text)
      , "subjectId" .= subject
      , "subjectRelation" .= object ["match" .= ("none" :: Text)]
      ]
  _ -> Null

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
      expected <- case accessResource binding ^. #address of
        AccessTuple _ host subject -> Right (toJSON (accessTuple (nameText host) subject))
        _ -> Left "invalid access tuple address"
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

accessRuntimeOps :: ContextBinding -> Text -> IO (Either Text ()) -> AccessOps
accessRuntimeOps context kubectlContext contextGuard =
  AccessOps
    { accessInspect = \binding -> do
        owner <- inspectOwners binding
        case owner of
          Left reason -> pure (Left reason)
          Right physical -> fmap join $ withEn $ \call -> do
            capability <- call "GET" "/v1/openapi.json" Null
            case capability >>= \(code, bytes) -> do
              unless (code == 200) (Left "access API capability observation refused")
              parseAccessCapabilities bytes of
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
            sent <- withEn (\call -> call "POST" "/v1/relationships" (accessMutation binding before))
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
      guarded <- contextGuard
      case guarded of
        Left _ -> pure (Left "access context guard refused")
        Right () -> do
          identities <- traverse inspectOwner [accessAuth binding, accessRoute binding]
          pure $ do
            uids <- sequence identities
            mkPhysicalIdentity ("access-owner://" <> T.intercalate "/" uids)
    inspectOwner resource = case resource ^. #address of
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
          Right (ExitSuccess, output, _) -> do
            value <- first (const "malformed access owner observation") (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)))
            first (const "access owner UID or inventory binding differs") (parseEither (ownerUid resource) value)
      _ -> pure (Left "access dependency is not a namespaced Kubernetes object")
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
    -- Every grant reaches the context's en the same way, through a private
    -- port-forward to its Service, so no accepted grant depends on the local
    -- address an operator once used (F97). The forward lives for one call.
    withEn :: ((ByteString -> Text -> Value -> IO (Either Text (Int, ByteString))) -> IO a) -> IO (Either Text a)
    withEn action = do
      credential <- lookupEnv "NAGARE_EN_API_KEY"
      case credential of
        Just key | not (null key) -> do
          result <-
            try @IOException $
              bracket openEnForward closeEnForward $ \(output, _) -> do
                ready <- timeout 15000000 (hGetLine output)
                case ready >>= parseEnForwardPort . T.pack of
                  Nothing -> pure (Left "en port-forward did not become ready")
                  Just port -> Right <$> action (request key ("http://127.0.0.1:" <> port))
          pure (either (const (Left "en port-forward failed")) id result)
        _ -> pure (Left "reviewed access requires private NAGARE_EN_API_KEY")
    openEnForward :: IO (Handle, ProcessHandle)
    openEnForward = do
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
    closeEnForward (output, process) = do
      terminateProcess process `catch` \(_ :: IOException) -> pure ()
      _ <- waitForProcess process
      hClose output `catch` \(_ :: IOException) -> pure ()
    request key base verb suffix body = do
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
accessReviewAdapter :: InventoryStore -> ContextBinding -> Text -> IO (Either Text ()) -> ReviewBundle -> IO (Either Text Adapter)
accessReviewAdapter store binding context guard bundle = do
  desiredResult <- declarationsFor (reviewDesiredRevisions document)
  history <- loadInventoryHistory store
  previousResult <- declarationsFor (reviewBaseRevisions document)
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
    pure (mkAccessAdapter accepted specs (accessRuntimeOps binding context guard))
  where
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
