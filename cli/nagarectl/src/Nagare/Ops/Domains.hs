-- | Observable domain inventory for @nagarectl domains list@ and
-- @nagarectl domains check@. DNS, route, and certificate state retain the
-- difference between an observed answer, confirmed absence, and a failed probe.
module Nagare.Ops.Domains
  ( Observation (..)
  , DnsObservation (..)
  , DnsExpectation (..)
  , MappingState (..)
  , CertificateState (..)
  , TlsMode (..)
  , DomainRow (..)
  , DomainMapping (..)
  , CertificateEvidence (..)
  , ToolRunner
  , extractDomainMappings
  , extractCertificateEvidence
  , parseDigShort
  , parseTlsMode
  , parseClusterIssuerObservation
  , dnsExpectationFor
  , certificateStateFor
  , observeDnsWith
  , queryDomainRows
  , queryDomainRowsWith
  , queryBaseDomainRow
  , observeNamespaces
  , listNamespaces
  , formatDomainList
  , domainReportValue
  , domainCheckFailures
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (eitherDecodeStrict, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Char (isDigit)
import Data.Generics.Labels ()
import Data.List (find, nub)
import Data.Maybe (catMaybes, listToMaybe)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Vector qualified as V
import Nagare.Dsl.Prelude hiding ((.=))
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data Observation a
  = Observed !a
  | NotFound
  | Unavailable !Text
  deriving stock (Generic, Eq, Show)

data DnsObservation = DnsObservation
  { addresses :: ![Text]
  , canonicalName :: !(Maybe Text)
  , authoritativeNameservers :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

data DnsExpectation
  = ExpectedAddresses ![Text]
  | NoPlatformDnsExpectation
  | DnsExpectationUnavailable !Text
  deriving stock (Generic, Eq, Show)

data MappingState
  = MappingReady
  | MappingPending !Text
  | MappingFailed !Text
  | MappingUnknown !Text
  deriving stock (Generic, Eq, Show)

data CertificateState
  = TlsDisabled
  | CertificatePending !Text
  | CertificateReady !Text
  | CertificateFailed !Text
  | CertificateUnknown !Text
  deriving stock (Generic, Eq, Show)

data TlsMode = TlsEnabled | TlsGloballyDisabled
  deriving stock (Generic, Eq, Show)

data DomainRow = DomainRow
  { domain :: !Text
  , service :: !(Maybe Text)
  , mapping :: !(Observation MappingState)
  , dnsExpectation :: !DnsExpectation
  , dns :: !(Observation DnsObservation)
  , certificate :: !CertificateState
  }
  deriving stock (Generic, Eq, Show)

data DomainMapping = DomainMapping
  { host :: !Text
  , service :: !(Maybe Text)
  , state :: !MappingState
  }
  deriving stock (Generic, Eq, Show)

data CertificateEvidence = CertificateEvidence
  { name :: !Text
  , dnsNames :: ![Text]
  , readyStatus :: !(Maybe Text)
  , reason :: !(Maybe Text)
  , message :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

type ToolRunner = String -> [String] -> IO (Observation ByteString)

lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] value = Just value
lookupPath (key : rest) (Aeson.Object object) =
  KeyMap.lookup (Key.fromText key) object >>= lookupPath rest
lookupPath _ _ = Nothing

textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path value = case lookupPath path value of
  Just (Aeson.String text) -> Just text
  _ -> Nothing

arrayAt :: [Text] -> Aeson.Value -> [Aeson.Value]
arrayAt path value = case lookupPath path value of
  Just (Aeson.Array values) -> V.toList values
  _ -> []

readyCondition :: Aeson.Value -> (Maybe Text, Maybe Text, Maybe Text)
readyCondition value =
  case find ((== Just "Ready") . textAt ["type"]) (arrayAt ["status", "conditions"] value) of
    Nothing -> (Nothing, Nothing, Nothing)
    Just condition ->
      ( textAt ["status"] condition
      , textAt ["reason"] condition
      , textAt ["message"] condition
      )

conditionDetail :: Maybe Text -> Maybe Text -> Text
conditionDetail why detail =
  case filter (not . T.null) (map T.strip (catMaybes [why, detail])) of
    [] -> "no Ready condition detail"
    details -> T.intercalate ": " details

mappingState :: Aeson.Value -> MappingState
mappingState value =
  case readyCondition value of
    (Just "True", _, _) -> MappingReady
    (Just "False", why, detail)
      | looksFailed rendered -> MappingFailed rendered
      | otherwise -> MappingPending rendered
      where
        rendered = conditionDetail why detail
    (Just status, why, detail) ->
      MappingUnknown ("Ready=" <> status <> ": " <> conditionDetail why detail)
    _ -> MappingUnknown "Ready condition has not been reported"

looksFailed :: Text -> Bool
looksFailed detail =
  any (`T.isInfixOf` T.toLower detail) ["fail", "error", "invalid", "denied", "conflict", "claim"]

extractDomainMappings :: ByteString -> Either Text [DomainMapping]
extractDomainMappings bytes =
  case eitherDecodeStrict bytes of
    Left err -> Left ("could not decode DomainMapping list JSON: " <> T.pack err)
    Right value -> do
      items <- listItems "DomainMapping" value
      pure
        [ DomainMapping host (textAt ["spec", "ref", "name"] item) (mappingState item)
        | item <- items
        , Just host <- [textAt ["metadata", "name"] item]
        ]

extractCertificateEvidence :: ByteString -> Either Text [CertificateEvidence]
extractCertificateEvidence bytes =
  case eitherDecodeStrict bytes of
    Left err -> Left ("could not decode Certificate list JSON: " <> T.pack err)
    Right value -> map evidence <$> listItems "Certificate" value
  where
    evidence item =
      let (status, why, detail) = readyCondition item
       in CertificateEvidence
            (fromMaybe "(unnamed certificate)" (textAt ["metadata", "name"] item))
            [dnsName | Aeson.String dnsName <- arrayAt ["spec", "dnsNames"] item]
            status
            why
            detail

listItems :: Text -> Aeson.Value -> Either Text [Aeson.Value]
listItems kind value = case lookupPath ["items"] value of
  Just (Aeson.Array items) -> Right (V.toList items)
  _ -> Left (kind <> " response has no items array")

parseTlsMode :: ByteString -> Either Text TlsMode
parseTlsMode bytes = do
  value <- first (T.pack . ("could not decode config-network JSON: " <>)) (eitherDecodeStrict bytes)
  pure $ case textAt ["data", "external-domain-tls"] value of
    Just mode | T.toLower mode == "enabled" -> TlsEnabled
    _ -> TlsGloballyDisabled

parseClusterIssuerObservation :: ByteString -> Either Text (Observation Bool)
parseClusterIssuerObservation bytes = do
  value <- first (T.pack . ("could not decode ClusterIssuer JSON: " <>)) (eitherDecodeStrict bytes)
  pure $ case readyCondition value of
    (Just "True", _, _) -> Observed True
    (Just "False", _, _) -> Observed False
    (Just status, _, _) -> Unavailable ("ClusterIssuer Ready has status " <> status)
    _ -> Unavailable "ClusterIssuer has no Ready condition"

parseDigShort :: ByteString -> [Text]
parseDigShort =
  map (T.dropWhileEnd (== '.'))
    . filter (not . T.null)
    . map T.strip
    . T.lines
    . decodeUtf8With lenientDecode

dnsExpectationFor :: Text -> Maybe Text -> Maybe Text -> Maybe Text -> Text -> DnsExpectation
dnsExpectationFor baseDomain publicIp apexIp cdnGlobalIp hostname
  | hostname == baseDomain = expected "apexIp" apexIp
  | isFirstLevelBelow baseDomain hostname =
      case nub (filter validTarget (catMaybes [publicIp, cdnGlobalIp])) of
        [] -> DnsExpectationUnavailable "publicIp and cdnGlobalIp outputs are unavailable"
        targets -> ExpectedAddresses targets
  | otherwise = NoPlatformDnsExpectation
  where
    expected label = maybe (DnsExpectationUnavailable (label <> " output is unavailable")) (ExpectedAddresses . pure)
    validTarget target = not (T.null target) && not ("(" `T.isPrefixOf` target)

isFirstLevelBelow :: Text -> Text -> Bool
isFirstLevelBelow base hostname =
  case T.stripSuffix ("." <> base) hostname of
    Just label -> not (T.null label) && not ("." `T.isInfixOf` label)
    Nothing -> False

certificateStateFor :: TlsMode -> Observation Bool -> Observation [CertificateEvidence] -> Text -> CertificateState
certificateStateFor TlsGloballyDisabled _ _ _ = TlsDisabled
certificateStateFor TlsEnabled issuer certificates hostname =
  case issuer of
    Unavailable detail -> CertificateUnknown detail
    NotFound -> CertificateFailed "configured ClusterIssuer was not found"
    Observed False -> CertificateFailed "configured ClusterIssuer is not Ready"
    Observed True -> case certificates of
      Unavailable detail -> CertificateUnknown detail
      NotFound -> CertificatePending "no certificate objects were found"
      Observed evidence ->
        case find (any (`covers` hostname) . (^. #dnsNames)) evidence of
          Nothing -> CertificatePending "no certificate covering this hostname"
          Just cert -> certificateEvidenceState cert

certificateEvidenceState :: CertificateEvidence -> CertificateState
certificateEvidenceState cert =
  let detail = conditionDetail (cert ^. #reason) (cert ^. #message)
      named suffix = cert ^. #name <> ": " <> suffix
   in case cert ^. #readyStatus of
        Just "True" -> CertificateReady (cert ^. #name)
        Just "False"
          | looksFailed detail -> CertificateFailed (named detail)
          | otherwise -> CertificatePending (named detail)
        Just status -> CertificateUnknown (named ("Ready=" <> status <> ": " <> detail))
        Nothing -> CertificatePending (named "Ready condition has not been reported")

covers :: Text -> Text -> Bool
covers name hostname
  | name == hostname = True
  | Just suffix <- T.stripPrefix "*." name = isFirstLevelBelow suffix hostname
  | otherwise = False

observeDnsWith :: ToolRunner -> Text -> Text -> IO (Observation DnsObservation)
observeDnsWith runner baseDomain hostname = do
  a <- query "A" hostname
  aaaa <- query "AAAA" hostname
  cname <- query "CNAME" hostname
  nameservers <- query "NS" authorityOwner
  pure $ case firstUnavailable [a, aaaa, cname, nameservers] of
    Just detail -> Unavailable detail
    Nothing ->
      let addresses = filter isIpv4 (answers a) <> filter (T.isInfixOf ":") (answers aaaa)
          canonical = listToMaybe (answers cname)
          observation = DnsObservation addresses canonical (answers nameservers)
       in if null addresses && isNothing canonical then NotFound else Observed observation
  where
    query recordType owner = normalize <$> runner "dig" ["+short", recordType, T.unpack owner]
    normalize = \case
      Observed bytes -> Observed (parseDigShort bytes)
      NotFound -> Observed []
      Unavailable detail -> Unavailable detail
    answers (Observed values) = values
    answers _ = []
    firstUnavailable [] = Nothing
    firstUnavailable (Unavailable detail : _) = Just detail
    firstUnavailable (_ : rest) = firstUnavailable rest
    isIpv4 value =
      let labels = T.splitOn "." value
       in length labels == 4 && all (not . T.null) labels && all (T.all isDigit) labels
    authorityOwner
      | hostname == baseDomain || ("." <> baseDomain) `T.isSuffixOf` hostname = baseDomain
      | otherwise = hostname

queryDomainRows :: Text -> Maybe Text -> Maybe Text -> Maybe Text -> Text -> IO (Observation [DomainRow])
queryDomainRows = queryDomainRowsWith systemToolRunner

queryBaseDomainRow :: Text -> Maybe Text -> IO DomainRow
queryBaseDomainRow base apexIp = do
  dnsObservation <- observeDnsWith systemToolRunner base base
  pure
    DomainRow
      { domain = base
      , service = Nothing
      , mapping = NotFound
      , dnsExpectation = dnsExpectationFor base Nothing apexIp Nothing base
      , dns = dnsObservation
      , certificate = TlsDisabled
      }

queryDomainRowsWith :: ToolRunner -> Text -> Maybe Text -> Maybe Text -> Maybe Text -> Text -> IO (Observation [DomainRow])
queryDomainRowsWith runner base publicIp apexIp cdnGlobalIp namespace = do
  mappings <- observeParsed extractDomainMappings =<< kube ["get", "domainmapping", "-n", ns, "-o", "json"]
  case mappings of
    Unavailable detail -> pure (Unavailable detail)
    NotFound -> pure NotFound
    Observed domainMappings -> do
      tlsMode <- observeParsed parseTlsMode =<< kube ["-n", "knative-serving", "get", "configmap", "config-network", "-o", "json"]
      configuredIssuer <- observeParsed parseConfiguredIssuerName =<< kube ["-n", "knative-serving", "get", "configmap", "config-certmanager", "-o", "json"]
      issuer <- case configuredIssuer of
        Observed issuerName -> observeNestedParsed parseClusterIssuerObservation =<< kube ["get", "clusterissuer", T.unpack issuerName, "-o", "json"]
        NotFound -> pure NotFound
        Unavailable detail -> pure (Unavailable detail)
      certManager <- observeParsed extractCertificateEvidence =<< kube ["get", "certificates.cert-manager.io", "-n", ns, "-o", "json"]
      knative <- observeParsed extractCertificateEvidence =<< kube ["get", "certificates.networking.internal.knative.dev", "-n", ns, "-o", "json"]
      let certificates = mergeCertificateObservations certManager knative
      Observed <$> traverse (rowFor tlsMode issuer certificates) domainMappings
  where
    ns = T.unpack namespace
    kube = runner "kubectl"
    rowFor tlsMode issuer certificates domainMapping = do
      dnsObservation <- observeDnsWith runner base (domainMapping ^. #host)
      pure
        DomainRow
          { domain = domainMapping ^. #host
          , service = domainMapping ^. #service
          , mapping = Observed (domainMapping ^. #state)
          , dnsExpectation = dnsExpectationFor base publicIp apexIp cdnGlobalIp (domainMapping ^. #host)
          , dns = dnsObservation
          , certificate = case tlsMode of
              Observed mode -> certificateStateFor mode issuer certificates (domainMapping ^. #host)
              NotFound -> TlsDisabled
              Unavailable detail -> CertificateUnknown detail
          }

parseConfiguredIssuerName :: ByteString -> Either Text Text
parseConfiguredIssuerName bytes = do
  value <- first (T.pack . ("could not decode config-certmanager JSON: " <>)) (eitherDecodeStrict bytes)
  case textAt ["data", "issuerRef"] value >>= issuerName of
    Just name -> Right name
    Nothing -> Left "config-certmanager issuerRef has no name"
  where
    issuerName =
      fmap (T.strip . T.drop 5)
        . find ("name:" `T.isPrefixOf`)
        . map T.strip
        . T.lines

observeParsed :: (ByteString -> Either Text a) -> Observation ByteString -> IO (Observation a)
observeParsed parser =
  pure . \case
    Observed bytes -> either Unavailable Observed (parser bytes)
    NotFound -> NotFound
    Unavailable detail -> Unavailable detail

observeNestedParsed :: (ByteString -> Either Text (Observation a)) -> Observation ByteString -> IO (Observation a)
observeNestedParsed parser =
  pure . \case
    Observed bytes -> either Unavailable id (parser bytes)
    NotFound -> NotFound
    Unavailable detail -> Unavailable detail

mergeCertificateObservations :: Observation [CertificateEvidence] -> Observation [CertificateEvidence] -> Observation [CertificateEvidence]
mergeCertificateObservations left right = case (left, right) of
  (Observed a, Observed b) -> Observed (a <> b)
  (Observed a, NotFound) -> Observed a
  (NotFound, Observed b) -> Observed b
  (NotFound, NotFound) -> NotFound
  (Unavailable detail, _) -> Unavailable detail
  (_, Unavailable detail) -> Unavailable detail

systemToolRunner :: ToolRunner
systemToolRunner executable args = do
  result <- try (readProcessWithExitCode executable args "")
  pure $ case result of
    Left (err :: IOException) -> Unavailable (T.pack executable <> " unavailable: " <> T.pack (show err))
    Right (ExitSuccess, stdout, _) -> Observed (encodeUtf8 (T.pack stdout))
    Right (ExitFailure code, _, stderrText)
      | isNotFound stderrText -> NotFound
      | otherwise -> Unavailable (T.pack executable <> " exited " <> tshow code <> nonEmptyDetail stderrText)
  where
    nonEmptyDetail detail =
      let trimmed = T.take 240 (T.strip (T.pack detail))
       in if T.null trimmed then "" else ": " <> trimmed
    isNotFound detail =
      let lowered = T.toLower (T.pack detail)
       in "not found" `T.isInfixOf` lowered
            || "doesn't have a resource type" `T.isInfixOf` lowered
            || "could not find the requested resource" `T.isInfixOf` lowered

observeNamespaces :: IO (Observation [Text])
observeNamespaces = do
  result <- systemToolRunner "kubectl" ["get", "ns", "-o", "name"]
  pure $ case result of
    Observed bytes -> Observed (namespaceNames bytes)
    NotFound -> NotFound
    Unavailable detail -> Unavailable detail
  where
    namespaceNames bytes =
      [ T.strip (snd (T.breakOnEnd "/" line))
      | line <- T.lines (decodeUtf8With lenientDecode bytes)
      , not (T.null (T.strip line))
      ]

listNamespaces :: IO [Text]
listNamespaces = do
  observation <- observeNamespaces
  pure $ case observation of
    Observed namespaces -> namespaces
    _ -> []

formatDomainList :: [DomainRow] -> Text
formatDomainList [] = "(no domains)\n"
formatDomainList rows = T.unlines (header : map renderRow rows)
  where
    header = "  " <> pad 32 "DOMAIN" <> pad 16 "SERVICE" <> pad 12 "ROUTE" <> pad 58 "DNS" <> "CERT"
    renderRow row =
      "  "
        <> pad 32 (row ^. #domain)
        <> pad 16 (fromMaybe "(base)" (row ^. #service))
        <> pad 12 (mappingCell (row ^. #mapping))
        <> pad 58 (dnsCell row)
        <> certificateCell (row ^. #certificate)
    pad width value =
      let clipped = T.take width value
       in clipped <> T.replicate (max 1 (width - T.length clipped)) " "

mappingCell :: Observation MappingState -> Text
mappingCell = \case
  NotFound -> "(none)"
  Unavailable _ -> "unknown"
  Observed MappingReady -> "Ready"
  Observed (MappingPending _) -> "pending"
  Observed (MappingFailed _) -> "failed"
  Observed (MappingUnknown _) -> "unknown"

dnsCell :: DomainRow -> Text
dnsCell row = observation <> expectation
  where
    observation = case row ^. #dns of
      NotFound -> "NXDOMAIN/no answer"
      Unavailable detail -> "unavailable: " <> detail
      Observed value ->
        let addressText = if null (value ^. #addresses) then "no address" else T.intercalate "," (value ^. #addresses)
            cnameText = maybe "" (" via " <>) (value ^. #canonicalName)
         in addressText <> cnameText
    expectation = case row ^. #dnsExpectation of
      ExpectedAddresses targets -> " (expected " <> T.intercalate " or " targets <> ")"
      NoPlatformDnsExpectation -> " (external DNS)"
      DnsExpectationUnavailable detail -> " (expectation unavailable: " <> detail <> ")"

certificateCell :: CertificateState -> Text
certificateCell = \case
  TlsDisabled -> "disabled"
  CertificatePending detail -> "pending: " <> detail
  CertificateReady detail -> "Ready: " <> detail
  CertificateFailed detail -> "failed: " <> detail
  CertificateUnknown detail -> "unknown: " <> detail

domainReportValue :: [Text] -> [DomainRow] -> Aeson.Value
domainReportValue warnings rows =
  Aeson.object
    [ "schemaVersion" .= (1 :: Int)
    , "inventoryWarnings" .= warnings
    , "rows" .= map rowValue rows
    ]
  where
    rowValue :: DomainRow -> Aeson.Value
    rowValue row =
      Aeson.object
        [ "domain" .= (row ^. #domain)
        , "service" .= (row ^. #service)
        , "route" .= observationValue mappingStateValue (row ^. #mapping)
        , "dnsExpectation" .= dnsExpectationValue (row ^. #dnsExpectation)
        , "dns" .= observationValue dnsObservationValue (row ^. #dns)
        , "certificate" .= certificateValue (row ^. #certificate)
        ]

observationValue :: (a -> Aeson.Value) -> Observation a -> Aeson.Value
observationValue render = \case
  Observed value -> Aeson.object ["state" .= ("observed" :: Text), "value" .= render value]
  NotFound -> Aeson.object ["state" .= ("not-found" :: Text)]
  Unavailable detail -> Aeson.object ["state" .= ("unavailable" :: Text), "detail" .= detail]

mappingStateValue :: MappingState -> Aeson.Value
mappingStateValue = \case
  MappingReady -> stateOnly "ready"
  MappingPending detail -> stateDetail "pending" detail
  MappingFailed detail -> stateDetail "failed" detail
  MappingUnknown detail -> stateDetail "unknown" detail

dnsExpectationValue :: DnsExpectation -> Aeson.Value
dnsExpectationValue = \case
  ExpectedAddresses targets -> Aeson.object ["state" .= ("expected" :: Text), "addresses" .= targets]
  NoPlatformDnsExpectation -> stateOnly "external"
  DnsExpectationUnavailable detail -> stateDetail "unavailable" detail

dnsObservationValue :: DnsObservation -> Aeson.Value
dnsObservationValue value =
  Aeson.object
    [ "addresses" .= (value ^. #addresses)
    , "canonicalName" .= (value ^. #canonicalName)
    , "authoritativeNameservers" .= (value ^. #authoritativeNameservers)
    ]

certificateValue :: CertificateState -> Aeson.Value
certificateValue = \case
  TlsDisabled -> stateOnly "disabled"
  CertificatePending detail -> stateDetail "pending" detail
  CertificateReady detail -> stateDetail "ready" detail
  CertificateFailed detail -> stateDetail "failed" detail
  CertificateUnknown detail -> stateDetail "unknown" detail

stateOnly :: Text -> Aeson.Value
stateOnly state = Aeson.object ["state" .= state]

stateDetail :: Text -> Text -> Aeson.Value
stateDetail state detail = Aeson.object ["state" .= state, "detail" .= detail]

domainCheckFailures :: [DomainRow] -> [Text]
domainCheckFailures = concatMap failures
  where
    failures :: DomainRow -> [Text]
    failures row = routeFailures row <> dnsFailures row <> certificateFailures row
    routeFailures :: DomainRow -> [Text]
    routeFailures row
      | isNothing (row ^. #service) = []
      | otherwise = case row ^. #mapping of
          Observed MappingReady -> []
          Observed (MappingPending detail) -> issue row ("route pending: " <> detail)
          Observed (MappingFailed detail) -> issue row ("route failed: " <> detail)
          Observed (MappingUnknown detail) -> issue row ("route unknown: " <> detail)
          NotFound -> issue row "route not found"
          Unavailable detail -> issue row ("route probe unavailable: " <> detail)
    dnsFailures :: DomainRow -> [Text]
    dnsFailures row = case row ^. #dns of
      NotFound -> issue row "public DNS has no address answer"
      Unavailable detail -> issue row ("DNS probe unavailable: " <> detail)
      Observed value
        | null (value ^. #addresses) -> issue row "public DNS has no address answer"
        | otherwise -> case row ^. #dnsExpectation of
            NoPlatformDnsExpectation -> []
            DnsExpectationUnavailable detail -> issue row ("DNS expectation unavailable: " <> detail)
            ExpectedAddresses expected
              | all (`elem` expected) (value ^. #addresses) -> []
              | otherwise ->
                  issue
                    row
                    ( "DNS resolves to "
                        <> T.intercalate "," (value ^. #addresses)
                        <> ", expected "
                        <> T.intercalate " or " expected
                    )
    certificateFailures :: DomainRow -> [Text]
    certificateFailures row = case row ^. #certificate of
      TlsDisabled -> []
      CertificateReady _ -> []
      CertificatePending detail -> issue row ("certificate pending: " <> detail)
      CertificateFailed detail -> issue row ("certificate failed: " <> detail)
      CertificateUnknown detail -> issue row ("certificate unknown: " <> detail)
    issue :: DomainRow -> Text -> [Text]
    issue row detail = [row ^. #domain <> ": " <> detail]

tshow :: (Show a) => a -> Text
tshow = T.pack . show
