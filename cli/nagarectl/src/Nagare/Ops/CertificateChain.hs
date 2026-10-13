-- | The certificate issuance chain of one hostname (EP-191): its Knative
-- DomainMapping, the Knative Certificate it owns, the cert-manager Certificate
-- net-certmanager made from that, the latest CertificateRequest, its ACME Order
-- and the Order's Challenges. 'classifyChain' turns the parsed objects into a
-- verdict with bounded upstream detail; 'renewDecision' and 'renewPatch' are
-- the one re-issuance trigger @nagarectl domains tls HOST --renew --yes@ may
-- write. Secrets are never read.
module Nagare.Ops.CertificateChain
  ( ChainVerdict (..)
  , ChainLink (..)
  , ChainReport (..)
  , RenewTarget (..)
  , ChainObjects (..)
  , verdictText
  , parseChainObjects
  , classifyChain
  , nextRetryAfter
  , renewDecision
  , renewPatch
  , readChainWith
  , renewChainWith
  , chainSummaryLine
  , renderChainReport
  , chainReportValue
  , domainMappingQuery
  , runtimeToolRunner
  , withCertificateDiagnosis
  )
where

import Data.Aeson (eitherDecodeStrict, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (forM_)
import Data.Generics.Labels ()
import Data.List (find, findIndex, sortOn)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Data.Vector qualified as V
import Nagare.Cluster.CertificateMigration
  ( CertificateResource (..)
  , certManagerCertificateFor
  , parseCertManagerCertificates
  , parseKnativeCertificates
  )
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (AdapterExecution (..))
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig, invokeKubectl)
import Nagare.Ops.Domains (Observation (..), ToolRunner)
import System.Exit (ExitCode (..))
import System.IO (stderr)

data ChainVerdict
  = VerdictReady
  | VerdictIssuing
  | VerdictFailed
  | VerdictRateLimited
  | VerdictIncomplete
  deriving stock (Generic, Eq, Show, Enum, Bounded)

verdictText :: ChainVerdict -> Text
verdictText = \case
  VerdictReady -> "ready"
  VerdictIssuing -> "issuing"
  VerdictFailed -> "failed"
  VerdictRateLimited -> "rate-limited"
  VerdictIncomplete -> "incomplete"

data Condition = Condition
  { conditionType :: !Text
  , status :: !Text
  , reason :: !(Maybe Text)
  , message :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- | The fields of any object in the chain this module reads.
data Object = Object
  { name :: !Text
  , namespace :: !Text
  , uid :: !Text
  , ownerUids :: ![Text]
  , annotations :: !(KeyMap.KeyMap Aeson.Value)
  , created :: !Text
  , value :: !Aeson.Value
  }
  deriving stock (Generic, Eq, Show)

-- | The six lists of one namespace, already decoded. The Knative and
-- cert-manager Certificates also carry the identity 'CertificateResource' that
-- the certificate migration parses, so both share one ownership predicate.
data ChainObjects = ChainObjects
  { domainMappings :: ![Object]
  , knativeCertificates :: ![(CertificateResource, Object)]
  , certificates :: ![(CertificateResource, Object)]
  , certificateRequests :: ![Object]
  , orders :: ![Object]
  , challenges :: ![Object]
  }
  deriving stock (Generic, Eq, Show)

data ChainLink = ChainLink
  { kind :: !Text
  , name :: !Text
  , uid :: !Text
  , phase :: !Text
  , detail :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- | What a renew writes against: the cert-manager Certificate as just read.
data RenewTarget = RenewTarget
  { namespace :: !Text
  , name :: !Text
  , resourceVersion :: !Text
  , generation :: !Integer
  , issuingIndex :: !(Maybe Int)
  , hasConditions :: !Bool
  }
  deriving stock (Generic, Eq, Show)

data ChainReport = ChainReport
  { host :: !Text
  , namespace :: !(Maybe Text)
  , verdict :: !ChainVerdict
  , links :: ![ChainLink]
  , missing :: !(Maybe Text)
  , upstream :: !(Maybe Text)
  , problemType :: !(Maybe Text)
  , caRetryAfter :: !(Maybe Text)
  , failedIssuanceAttempts :: !(Maybe Int)
  , lastFailureTime :: !(Maybe UTCTime)
  , nextRetry :: !(Maybe UTCTime)
  , contextId :: !(Maybe Text)
  , wildcard :: !Bool
  , latestRequestReason :: !(Maybe Text)
  , target :: !(Maybe RenewTarget)
  }
  deriving stock (Generic, Eq, Show)

-- ---------------------------------------------------------------------------
-- Parsing

lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] v = Just v
lookupPath (key : rest) (Aeson.Object o) = KeyMap.lookup (Key.fromText key) o >>= lookupPath rest
lookupPath _ _ = Nothing

textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (Aeson.String t) | not (T.null (T.strip t)) -> Just t
  _ -> Nothing

intAt :: [Text] -> Aeson.Value -> Maybe Integer
intAt path v = case lookupPath path v of
  Just (Aeson.Number n) -> Just (truncate n)
  _ -> Nothing

arrayAt :: [Text] -> Aeson.Value -> [Aeson.Value]
arrayAt path v = case lookupPath path v of
  Just (Aeson.Array values) -> V.toList values
  _ -> []

conditionsOf :: Aeson.Value -> [Condition]
conditionsOf v =
  [ Condition t s (textAt ["reason"] c) (textAt ["message"] c)
  | c <- arrayAt ["status", "conditions"] v
  , Just t <- [textAt ["type"] c]
  , let s = fromMaybe "Unknown" (textAt ["status"] c)
  ]

conditionOf :: Text -> Aeson.Value -> Maybe Condition
conditionOf t = find ((== t) . (^. #conditionType)) . conditionsOf

parseObjects :: Text -> ByteString -> Either Text [Object]
parseObjects what bytes = do
  root <- first (\err -> "could not decode " <> what <> " list JSON: " <> T.pack err) (eitherDecodeStrict bytes)
  items <- case lookupPath ["items"] root of
    Just (Aeson.Array items) -> Right (V.toList items)
    _ -> Left (what <> " response has no items array")
  pure (mapMaybe object items)
  where
    object v = do
      n <- textAt ["metadata", "name"] v
      u <- textAt ["metadata", "uid"] v
      pure
        Object
          { name = n
          , namespace = fromMaybe "" (textAt ["metadata", "namespace"] v)
          , uid = u
          , ownerUids = mapMaybe (textAt ["uid"]) (arrayAt ["metadata", "ownerReferences"] v)
          , annotations = case lookupPath ["metadata", "annotations"] v of
              Just (Aeson.Object o) -> o
              _ -> KeyMap.empty
          , created = fromMaybe "" (textAt ["metadata", "creationTimestamp"] v)
          , value = v
          }

-- | Pair each Certificate's identity with its object by uid.
parseCertificates :: Text -> (ByteString -> Either Text [CertificateResource]) -> ByteString -> Either Text [(CertificateResource, Object)]
parseCertificates what identities bytes = do
  resources <- identities bytes
  objects <- parseObjects what bytes
  pure [(r, o) | r <- resources, o <- objects, o ^. #uid == certificateUid r]

-- | Decode the kubectl list outputs, in the order 'readChainWith' reads them.
parseChainObjects :: ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> Either Text ChainObjects
parseChainObjects dms knative certs requests orderList challengeList =
  ChainObjects
    <$> parseObjects "DomainMapping" dms
    <*> parseCertificates "Knative Certificate" parseKnativeCertificates knative
    <*> parseCertificates "Certificate" parseCertManagerCertificates certs
    <*> parseObjects "CertificateRequest" requests
    <*> parseObjects "Order" orderList
    <*> parseObjects "Challenge" challengeList

-- ---------------------------------------------------------------------------
-- Classification

-- | One line, at most 240 characters, with anything that looks like PEM
-- material replaced: upstream messages are shown, never key text.
bounded :: Text -> Text
bounded raw
  | "-----BEGIN" `T.isInfixOf` raw || "PRIVATE KEY" `T.isInfixOf` raw = "(detail withheld: it contains PEM text)"
  | otherwise = clip (T.unwords (T.words raw))
  where
    clip t = if T.length t > 240 then T.take 239 t <> "…" else t

acmeProblem :: Text -> Maybe Text
acmeProblem t = case T.breakOn prefix t of
  (_, rest) | not (T.null rest) -> Just (prefix <> T.takeWhile (\c -> c `notElem` (" :,;\"" :: String)) (T.drop (T.length prefix) rest))
  _ -> Nothing
  where
    prefix = "urn:ietf:params:acme:error:"

retryAfterText :: Text -> Maybe Text
retryAfterText t = case T.breakOn "retry after " t of
  (_, rest) | not (T.null rest) -> Just (T.strip (fst (T.breakOn ": see" (T.drop (T.length "retry after ") rest))))
  _ -> Nothing

parseTime :: Text -> Maybe UTCTime
parseTime = iso8601ParseM . T.unpack

-- | cert-manager v1.20.2's trigger controller: one hour after the first
-- failure, doubling per attempt, at most 32 hours.
nextRetryAfter :: Int -> UTCTime -> UTCTime
nextRetryAfter attempts failedAt = addUTCTime (fromIntegral (hours * 3600)) failedAt
  where
    hours = min 32 (2 ^ max 0 (attempts - 1) :: Int)

latest :: [Object] -> Maybe Object
latest = listToMaybe . sortOn (\o -> Down (revisionOf o, o ^. #created))
  where
    revisionOf o = case KeyMap.lookup "cert-manager.io/certificate-revision" (o ^. #annotations) of
      Just (Aeson.String r) -> readMaybeInt r
      _ -> Nothing

readMaybeInt :: Text -> Maybe Int
readMaybeInt t = case reads (T.unpack t) of
  [(n, "")] -> Just n
  _ -> Nothing

ownedBy :: Object -> [Object] -> [Object]
ownedBy owner = filter (elem (owner ^. #uid) . (^. #ownerUids))

conditionPhase :: Maybe Condition -> Text
conditionPhase = \case
  Just c | c ^. #status == "True" -> "Ready"
  Just c -> "not Ready" <> maybe "" (\r -> " (" <> r <> ")") (c ^. #reason)
  Nothing -> "no Ready condition"

conditionDetail :: Maybe Condition -> Maybe Text
conditionDetail = \case
  Just c | c ^. #status /= "True" -> bounded <$> (c ^. #message)
  _ -> Nothing

classifyChain :: Text -> ChainObjects -> ChainReport
classifyChain hostName objs =
  case filter ((== hostName) . (^. #name)) (objs ^. #domainMappings) of
    [] -> base Nothing [] & #missing ?~ "DomainMapping"
    dm : _ ->
      let dmLink = ChainLink "DomainMapping" (dm ^. #name) (dm ^. #uid) (conditionPhase (ready dm)) (conditionDetail (ready dm))
          withMapping =
            base (Just (dm ^. #namespace)) [dmLink]
              & #contextId
              .~ contextOf dm
       in case [kc | kc@(_, o) <- objs ^. #knativeCertificates, dm ^. #uid `elem` o ^. #ownerUids] of
            [] -> withMapping & #missing ?~ "Knative Certificate"
            (kr, ko) : _ ->
              let knLink = ChainLink "Knative Certificate" (ko ^. #name) (ko ^. #uid) (conditionPhase (ready ko)) (conditionDetail (ready ko))
                  withKnative = withMapping & #links <>~ [knLink] & #wildcard .~ namespaceWildcard kr
               in case [cc | cc@(cr, _) <- objs ^. #certificates, certManagerCertificateFor kr cr] of
                    [] -> withKnative & #missing ?~ "cert-manager Certificate"
                    (_, co) : _ -> certificateReport withKnative co
  where
    base ns ls =
      ChainReport
        { host = hostName
        , namespace = ns
        , verdict = VerdictIncomplete
        , links = ls
        , missing = Nothing
        , upstream = Nothing
        , problemType = Nothing
        , caRetryAfter = Nothing
        , failedIssuanceAttempts = Nothing
        , lastFailureTime = Nothing
        , nextRetry = Nothing
        , contextId = Nothing
        , wildcard = False
        , latestRequestReason = Nothing
        , target = Nothing
        }
    ready = conditionOf "Ready" . (^. #value)
    contextOf o = case KeyMap.lookup "nagare.dev/context-id" (o ^. #annotations) of
      Just (Aeson.String c) -> Just c
      _ -> Nothing
    certificateReport partial co =
      let v = co ^. #value
          readyC = conditionOf "Ready" v
          issuingC = conditionOf "Issuing" v
          attempts = fromIntegral <$> intAt ["status", "failedIssuanceAttempts"] v
          failedAt = textAt ["status", "lastFailureTime"] v >>= parseTime
          request = latest (ownedBy co (objs ^. #certificateRequests))
          requestReady = request >>= conditionOf "Ready" . (^. #value)
          order = request >>= \r -> latest (ownedBy r (objs ^. #orders))
          orderChallenges = maybe [] (\o -> ownedBy o (objs ^. #challenges)) order
          isReady = fmap (^. #status) readyC == Just "True"
          isIssuing = fmap (^. #status) issuingC == Just "True"
          certPhase
            | isReady && isIssuing = "Ready, renewing"
            | isReady = "Ready"
            | isIssuing = "Issuing"
            | otherwise = "not Ready" <> maybe "" (\c -> ", Issuing=False (" <> fromMaybe "no reason" (c ^. #reason) <> ")") issuingC
          certLink = ChainLink "Certificate" (co ^. #name) (co ^. #uid) certPhase (if isReady then Nothing else conditionDetail readyC)
          requestLink r =
            ChainLink
              "CertificateRequest"
              (r ^. #name)
              (r ^. #uid)
              (maybe "no Ready condition" (\c -> if c ^. #status == "True" then "Issued" else fromMaybe "not Ready" (c ^. #reason)) requestReady)
              (conditionDetail requestReady)
          orderLink o = ChainLink "Order" (o ^. #name) (o ^. #uid) (fromMaybe "no state" (textAt ["status", "state"] (o ^. #value))) (bounded <$> textAt ["status", "reason"] (o ^. #value))
          challengeLink c =
            let cv = c ^. #value
                what = T.unwords (catMaybesT [textAt ["spec", "type"] cv, textAt ["spec", "dnsName"] cv])
             in ChainLink "Challenge" (c ^. #name) (c ^. #uid) (fromMaybe "no state" (textAt ["status", "state"] cv) <> (if T.null what then "" else " (" <> what <> ")")) (bounded <$> textAt ["status", "reason"] cv)
          ls = [certLink] <> maybe [] (pure . requestLink) request <> maybe [] (pure . orderLink) order <> map challengeLink orderChallenges
          upstreamDetail =
            listToMaybe
              ( catMaybesT
                  ( [order >>= textAt ["status", "reason"] . (^. #value)]
                      <> [textAt ["status", "reason"] (c ^. #value) | c <- orderChallenges, textAt ["status", "state"] (c ^. #value) `notElem` [Just "valid"]]
                      <> [requestReady >>= \c -> if c ^. #status == "True" then Nothing else c ^. #message]
                      <> [issuingC >>= \c -> if c ^. #status == "True" then Nothing else c ^. #message]
                      <> [readyC >>= \c -> if c ^. #status == "True" then Nothing else c ^. #message]
                  )
              )
          problem = upstreamDetail >>= acmeProblem
          rateLimited = problem == Just "urn:ietf:params:acme:error:rateLimited"
          verdictFor
            | isIssuing = VerdictIssuing
            | isReady = VerdictReady
            | rateLimited && isJust failedAt = VerdictRateLimited
            | isJust failedAt = VerdictFailed
            | otherwise = VerdictIssuing
          conditionList = conditionsOf v
       in partial
            & #links
            <>~ ls
            & #verdict
            .~ verdictFor
            & #upstream
            .~ (bounded <$> upstreamDetail)
            & #problemType
            .~ problem
            & #caRetryAfter
            .~ (upstreamDetail >>= retryAfterText)
            & #failedIssuanceAttempts
            .~ attempts
            & #lastFailureTime
            .~ failedAt
            & #nextRetry
            .~ (nextRetryAfter (fromMaybe 1 attempts) <$> failedAt)
            & #latestRequestReason
            .~ (requestReady >>= (^. #reason))
            & #target
            ?~ RenewTarget
              { namespace = co ^. #namespace
              , name = co ^. #name
              , resourceVersion = fromMaybe "" (textAt ["metadata", "resourceVersion"] v)
              , generation = fromMaybe 1 (intAt ["metadata", "generation"] v)
              , issuingIndex = findIndex ((== "Issuing") . (^. #conditionType)) conditionList
              , hasConditions = not (null conditionList)
              }

catMaybesT :: [Maybe Text] -> [Text]
catMaybesT = mapMaybe id

-- ---------------------------------------------------------------------------
-- Renew

-- | Renew only an owned, failed, renewable chain. The context's id must match
-- the DomainMapping's stamp; the chain below it was found by ownerReference.
renewDecision :: Text -> ChainReport -> Either Text RenewTarget
renewDecision context report = do
  when (report ^. #missing == Just "DomainMapping") $
    Left ("no Nagare DomainMapping is named " <> report ^. #host <> "; renew only acts on a host this context deploys")
  case report ^. #contextId of
    Nothing -> Left ("the DomainMapping for " <> report ^. #host <> " carries no nagare.dev/context-id; it is not managed by Nagare")
    Just owner
      | owner /= context -> Left ("the DomainMapping for " <> report ^. #host <> " belongs to context " <> owner <> ", not " <> context)
      | otherwise -> Right ()
  forM_ (report ^. #missing) $ \link ->
    Left ("the chain has no " <> link <> "; there is nothing to renew")
  when (report ^. #wildcard) $
    Left "the certificate is a namespace wildcard shared by other hosts; renew refuses it"
  case report ^. #verdict of
    VerdictFailed -> Right ()
    VerdictReady -> Left "the certificate is Ready; there is nothing to renew"
    VerdictIssuing -> Left "issuance is in progress; run `nagarectl domains tls HOST` again to follow it"
    VerdictRateLimited -> Left "the CA rate-limited this certificate; renewing now spends more of the limit, wait for the CA's retry time"
    VerdictIncomplete -> Left "the chain is incomplete; there is nothing to renew"
  unless (report ^. #latestRequestReason == Just "Failed") $
    Left
      ( "the latest CertificateRequest is "
          <> fromMaybe "missing" (report ^. #latestRequestReason)
          <> ", not Failed; cert-manager only replaces a Failed request when re-issuance is triggered"
      )
  maybe (Left "the cert-manager Certificate was not read") Right (report ^. #target)

-- | The JSON patch for the status subresource: test the resourceVersion just
-- read, then set Issuing=True the way cmctl renew does (EP-191 M1).
renewPatch :: UTCTime -> RenewTarget -> Aeson.Value
renewPatch now t =
  Aeson.toJSON
    [ Aeson.object ["op" .= ("test" :: Text), "path" .= ("/metadata/resourceVersion" :: Text), "value" .= (t ^. #resourceVersion)]
    , case (t ^. #issuingIndex, t ^. #hasConditions) of
        (Just i, _) -> Aeson.object ["op" .= ("replace" :: Text), "path" .= ("/status/conditions/" <> T.pack (show i)), "value" .= condition]
        (Nothing, True) -> Aeson.object ["op" .= ("add" :: Text), "path" .= ("/status/conditions/-" :: Text), "value" .= condition]
        (Nothing, False) -> Aeson.object ["op" .= ("add" :: Text), "path" .= ("/status/conditions" :: Text), "value" .= [condition]]
    ]
  where
    condition =
      Aeson.object
        [ "type" .= ("Issuing" :: Text)
        , "status" .= ("True" :: Text)
        , "reason" .= ("ManuallyTriggered" :: Text)
        , "message" .= ("Certificate re-issuance manually triggered" :: Text)
        , "observedGeneration" .= (t ^. #generation)
        , "lastTransitionTime" .= T.pack (iso8601Show (roundSeconds now))
        ]
    roundSeconds u = fromMaybe u (iso8601ParseM (take 19 (iso8601Show u) <> "Z"))

-- ---------------------------------------------------------------------------
-- Reading and renewing through a ToolRunner

domainMappingQuery :: Text -> [String]
domainMappingQuery hostName = ["get", "domainmappings.serving.knative.dev", "-A", "--field-selector", "metadata.name=" <> T.unpack hostName, "-o", "json"]

-- | Read the chain of one host: the DomainMapping across namespaces, then
-- one list per kind in its namespace. A kind the cluster does not serve
-- (no ACME CRDs) reads as empty; any other failure is returned.
readChainWith :: ToolRunner -> Text -> IO (Either Text ChainReport)
readChainWith runner hostName = do
  dms <- runner "kubectl" (domainMappingQuery hostName)
  case dms of
    Unavailable err -> pure (Left ("could not read DomainMappings: " <> err))
    NotFound -> pure (Right (classifyChain hostName emptyObjects))
    Observed dmBytes -> case parseObjects "DomainMapping" dmBytes of
      Left err -> pure (Left err)
      Right [] -> pure (Right (classifyChain hostName emptyObjects))
      Right [dm] -> do
        let ns = T.unpack (dm ^. #namespace)
            list resource = do
              result <- runner "kubectl" ["get", resource, "-n", ns, "-o", "json"]
              pure $ case result of
                Observed bytes -> Right bytes
                NotFound -> Right "{\"items\":[]}"
                Unavailable err -> Left ("could not read " <> T.pack resource <> ": " <> err)
        lists <-
          traverse
            list
            [ "certificates.networking.internal.knative.dev"
            , "certificates.cert-manager.io"
            , "certificaterequests.cert-manager.io"
            , "orders.acme.cert-manager.io"
            , "challenges.acme.cert-manager.io"
            ]
        pure $ case sequence lists of
          Left err -> Left err
          Right [kn, cm, cr, ord, ch] -> classifyChain hostName <$> parseChainObjects dmBytes kn cm cr ord ch
          Right _ -> Left "internal error: unexpected list count"
      Right many ->
        pure (Left (T.pack (show (length many)) <> " DomainMappings are named " <> hostName <> " (" <> T.intercalate ", " (map (^. #namespace) many) <> "); refusing to choose"))
  where
    emptyObjects = ChainObjects [] [] [] [] [] []

-- | Diagnose, then trigger one re-issuance: the guard first, then the
-- ownership and verdict checks, the full diagnosis, and exactly one patch.
-- Every line goes to @say@ so a caller (and a test) sees the order.
renewChainWith :: ToolRunner -> IO (Either Text Text) -> Text -> UTCTime -> Text -> (Text -> IO ()) -> IO (Either Text ())
renewChainWith runner guardCluster context now hostName say = do
  guarded <- guardCluster
  case guarded of
    Left err -> pure (Left ("cluster guard refused: " <> err))
    Right _ -> do
      read' <- readChainWith runner hostName
      case read' of
        Left err -> pure (Left err)
        Right report -> do
          say (renderChainReport report)
          case renewDecision context report of
            Left refusal -> pure (Left ("renew refused: " <> refusal))
            Right t -> do
              let patch = TE.decodeUtf8 (LBS.toStrict (Aeson.encode (renewPatch now t)))
              say ("renewing Certificate " <> t ^. #namespace <> "/" <> t ^. #name <> "; cert-manager deletes the failed request and its Order, so the diagnosis above is the only record of that attempt")
              say ("patch: " <> patch)
              result <-
                runner
                  "kubectl"
                  ["patch", "certificates.cert-manager.io", T.unpack (t ^. #name), "-n", T.unpack (t ^. #namespace), "--subresource=status", "--type=json", "-p", T.unpack patch]
              case result of
                Observed _ -> do
                  say ("run `nagarectl domains tls " <> hostName <> "` to follow issuance; then `nagarectl inventory resume TX --yes` if a deploy stopped on this certificate")
                  pure (Right ())
                NotFound -> pure (Left ("the Certificate disappeared while renewing; run `nagarectl domains tls " <> hostName <> "` again"))
                Unavailable err -> pure (Left ("Certificate changed while renewing or the patch was refused (" <> err <> "); run `nagarectl domains tls " <> hostName <> "` again"))

-- | kubectl through the inventory runtime's own binding: its context, its
-- guard-checked cluster, and its interpreter in tests.
runtimeToolRunner :: KubernetesRuntimeConfig -> ToolRunner
runtimeToolRunner config _ args = do
  result <- invokeKubectl config args ""
  pure $ case result of
    Right (ExitSuccess, out, _) -> Observed (TE.encodeUtf8 (T.pack out))
    Right (ExitFailure _, _, err)
      | "doesn't have a resource type" `T.isInfixOf` T.pack err || "NotFound" `T.isInfixOf` T.pack err -> NotFound
      | otherwise -> Unavailable (T.take 240 (T.strip (T.pack err)))
    Left err -> Unavailable err

-- | A deploy that stopped on a DomainMapping certificate names the chain's
-- verdict and the command to follow it, on stderr and in the journal: the
-- stop line itself never carries journal detail. A failed read keeps the
-- message.
withCertificateDiagnosis :: KubernetesRuntimeConfig -> Text -> AdapterExecution -> IO AdapterExecution
withCertificateDiagnosis config hostName = \case
  AdapterEffectAmbiguous message ->
    readChainWith (runtimeToolRunner config) hostName >>= \case
      Right report -> do
        let diagnosis = chainSummaryLine report <> "; run `nagarectl domains tls " <> hostName <> "`"
        TIO.hPutStrLn stderr ("nagarectl: " <> diagnosis)
        pure (AdapterEffectAmbiguous (message <> "; " <> diagnosis))
      Left _ -> pure (AdapterEffectAmbiguous message)
  other -> pure other

-- ---------------------------------------------------------------------------
-- Rendering

chainSummaryLine :: ChainReport -> Text
chainSummaryLine r =
  r ^. #host
    <> ": certificate "
    <> verdictText (r ^. #verdict)
    <> maybe "" (\m -> " (no " <> m <> ")") (r ^. #missing)
    <> maybe "" (\n -> " after " <> T.pack (show n) <> " failed attempt" <> (if n == 1 then "" else "s")) (attemptsShown r)
    <> maybe "" (": " <>) (r ^. #upstream)
    <> maybe "" (\t -> "; cert-manager retries at " <> timeText t) (retryShown r)
  where
    attemptsShown x = if x ^. #verdict `elem` [VerdictFailed, VerdictRateLimited] then x ^. #failedIssuanceAttempts else Nothing
    retryShown x = if x ^. #verdict `elem` [VerdictFailed, VerdictRateLimited] then x ^. #nextRetry else Nothing

timeText :: UTCTime -> Text
timeText = T.pack . iso8601Show

renderChainReport :: ChainReport -> Text
renderChainReport r =
  T.unlines $
    [chainSummaryLine r]
      <> maybe [] (\ns -> ["  namespace " <> ns]) (r ^. #namespace)
      <> map linkLine (r ^. #links)
      <> maybe [] (\p -> ["  ACME problem: " <> p]) (r ^. #problemType)
      <> maybe [] (\t -> ["  CA retry after: " <> t]) (r ^. #caRetryAfter)
      <> maybe [] (\n -> ["  failed issuance attempts: " <> T.pack (show n)]) (r ^. #failedIssuanceAttempts)
      <> maybe [] (\t -> ["  last failure: " <> timeText t]) (r ^. #lastFailureTime)
      <> maybe [] (\t -> ["  cert-manager retries at: " <> timeText t]) (r ^. #nextRetry)
      <> ["  next: " <> nextStep]
  where
    linkLine l =
      "  "
        <> pad 21 (l ^. #kind)
        <> pad 52 (l ^. #name)
        <> l ^. #phase
        <> maybe "" (\d -> "\n  " <> T.replicate 21 " " <> d) (l ^. #detail)
    pad w t = t <> T.replicate (max 1 (w - T.length t)) " "
    nextStep = case r ^. #verdict of
      VerdictReady -> "nothing to do"
      VerdictIssuing -> "issuance is in progress; run `nagarectl domains tls " <> r ^. #host <> "` again to follow it"
      VerdictRateLimited -> "wait for the CA's retry time; renewing now spends more of the limit"
      VerdictIncomplete -> "the " <> fromMaybe "chain" (r ^. #missing) <> " is missing; deploy the site, or wait for Knative and net-certmanager to create it"
      VerdictFailed
        | r ^. #latestRequestReason == Just "Failed" -> "renew once with `nagarectl domains tls " <> r ^. #host <> " --renew --yes`, or wait for cert-manager's retry"
        | otherwise -> "the latest request is " <> fromMaybe "missing" (r ^. #latestRequestReason) <> "; renew cannot help, fix the cause and wait for cert-manager's retry"

chainReportValue :: Either Text RenewTarget -> ChainReport -> Aeson.Value
chainReportValue decision r =
  Aeson.object
    [ "schemaVersion" .= (1 :: Int)
    , "host" .= (r ^. #host)
    , "namespace" .= (r ^. #namespace)
    , "verdict" .= verdictText (r ^. #verdict)
    , "summary" .= chainSummaryLine r
    , "missing" .= (r ^. #missing)
    , "links" .= map linkValue (r ^. #links)
    , "upstream" .= (r ^. #upstream)
    , "problemType" .= (r ^. #problemType)
    , "caRetryAfter" .= (r ^. #caRetryAfter)
    , "failedIssuanceAttempts" .= (r ^. #failedIssuanceAttempts)
    , "lastFailureTime" .= (timeText <$> r ^. #lastFailureTime)
    , "nextRetry" .= (timeText <$> r ^. #nextRetry)
    , "renew" .= case decision of
        Right _ -> Aeson.object ["allowed" .= True]
        Left refusal -> Aeson.object ["allowed" .= False, "refusal" .= refusal]
    ]
  where
    linkValue l =
      Aeson.object
        [ "kind" .= (l ^. #kind)
        , "name" .= (l ^. #name)
        , "uid" .= (l ^. #uid)
        , "phase" .= (l ^. #phase)
        , "detail" .= (l ^. #detail)
        ]
