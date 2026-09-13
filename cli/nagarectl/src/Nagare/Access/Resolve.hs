-- | Deploy-time wiring for identity-aware access and the auth portal.
module Nagare.Access.Resolve
  ( AccessOps (..)
  , AccessRoute (..)
  , BackendEntry (..)
  , BackendMap
  , BaseDomain
  , EntryRole (..)
  , Origin (..)
  , PublicHost
  , RouteMode (..)
  , RouteOp (..)
  , RouteTarget (..)
  , ShomeiPortalChange (..)
  , addOrigin
  , authPlaneMissingMessage
  , backendConfigMapName
  , backendConfigMapNamespace
  , backendMapFromList
  , backendMapKey
  , baseDomainText
  , deploymentAccessRoutes
  , isUnderBaseDomain
  , kubectlAccessOps
  , mkBaseDomain
  , mkPublicHost
  , portalOrigin
  , portalRegistration
  , publicHostText
  , removeOrigin
  , removeServiceAccessWithOps
  , renderAccessDomainMapping
  , renderBackendConfigMap
  , resolveAccess
  , resolveAccessRouteWithOps
  , resolveDeploymentAccess
  , resolveDeploymentAccessWithOps
  , upstreamFor
  )
where

import Control.Monad (forM_, unless, when)
import Cradle (StdoutRaw (..), addArgs, cmd, run, run_, silenceStderr, (&))
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), eitherDecodeStrict, encode, object, withObject, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Nagare.Deploy (applyManifests)
import Nagare.Dsl.Access (AccessPolicy, AccessRole (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types
  ( Deployment
  , Namespace
  , ServiceName
  , domainText
  , namespaceText
  , serviceNameText
  )
import System.Exit (ExitCode (..), exitFailure)
import System.IO (stderr)

backendConfigMapNamespace, backendConfigMapName, backendMapKey, enforcerName :: Text
backendConfigMapNamespace = "nagare-system"
backendConfigMapName = "nagare-access-backends"
backendMapKey = "backends.json"
enforcerName = "nagare-access"

newtype PublicHost = PublicHost Text
  deriving stock (Eq, Ord, Show)

publicHostText :: PublicHost -> Text
publicHostText (PublicHost host) = host

mkPublicHost :: Text -> Either Text PublicHost
mkPublicHost raw =
  let host = T.toLower . T.dropWhileEnd (== '.') . T.strip $ raw
   in if T.null host || T.any badHostChar host
        then Left ("invalid public host: " <> raw)
        else Right (PublicHost host)
  where
    badHostChar c = c <= ' ' || c == '/' || c == '\\' || c == ':'

newtype BaseDomain = BaseDomain Text
  deriving stock (Eq, Show)

baseDomainText :: BaseDomain -> Text
baseDomainText (BaseDomain domain) = domain

mkBaseDomain :: Text -> Either Text BaseDomain
mkBaseDomain raw = do
  host <- mkPublicHost (T.dropWhile (== '.') raw)
  pure (BaseDomain (publicHostText host))

isUnderBaseDomain :: BaseDomain -> PublicHost -> Bool
isUnderBaseDomain base host =
  ("." <> baseDomainText base) `T.isSuffixOf` publicHostText host

data EntryRole = ProtectedEntry | PortalEntry
  deriving stock (Eq, Show)

data BackendEntry = BackendEntry
  { upstream :: !Text
  , role :: !EntryRole
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON BackendEntry where
  parseJSON (String upstream) = pure (BackendEntry upstream ProtectedEntry)
  parseJSON value@(Object _) =
    withObject "backend entry" (\obj -> BackendEntry <$> obj .: "upstream" <*> (obj .: "role" >>= parseRole)) value
    where
      parseRole ("protected" :: Text) = pure ProtectedEntry
      parseRole "portal" = pure PortalEntry
      parseRole other = fail ("unknown backend role: " <> T.unpack other)
  parseJSON _ = fail "backend entry must be a string or an object"

instance ToJSON BackendEntry where
  toJSON entry =
    case entry ^. #role of
      ProtectedEntry -> String (entry ^. #upstream)
      PortalEntry -> object ["upstream" .= (entry ^. #upstream), "role" .= ("portal" :: Text)]

newtype BackendMap = BackendMap (Map PublicHost BackendEntry)
  deriving stock (Eq, Show)

instance Semigroup BackendMap where
  BackendMap left <> BackendMap right = BackendMap (left <> right)

instance Monoid BackendMap where
  mempty = BackendMap Map.empty

instance FromJSON BackendMap where
  parseJSON = withObject "backend map" $ \obj -> do
    entries <- traverse parseOne (KeyMap.toList obj)
    let portals = [host | (host, entry) <- entries, entry ^. #role == PortalEntry]
    case portals of
      _ : second : _ -> fail ("backend map contains more than one portal; offending host: " <> T.unpack (publicHostText second))
      _ -> pure (BackendMap (Map.fromList entries))
    where
      parseOne (key, value) = do
        host <- either (fail . T.unpack) pure (mkPublicHost (Key.toText key))
        entry <- parseJSON value
        pure (host, entry)

instance ToJSON BackendMap where
  toJSON (BackendMap entries) =
    object [Key.fromText (publicHostText host) .= entry | (host, entry) <- Map.toAscList entries]

backendMapFromList :: [(Text, BackendEntry)] -> Either Text BackendMap
backendMapFromList entries = do
  parsed <- traverse (\(host, entry) -> (,entry) <$> mkPublicHost host) entries
  Aeson.parseEither parseJSON (toJSON (BackendMap (Map.fromList parsed)))
    & either (Left . T.pack) Right

portalRegistration :: BackendMap -> Maybe (PublicHost, BackendEntry)
portalRegistration (BackendMap entries) =
  case [(host, entry) | (host, entry) <- Map.toAscList entries, entry ^. #role == PortalEntry] of
    registration : _ -> Just registration
    [] -> Nothing

data RouteMode = ExistingDomainMapping | DefaultKnativeHost
  deriving stock (Eq, Show)

data AccessRoute = AccessRoute
  { host :: !Text
  , mode :: !RouteMode
  }
  deriving stock (Generic, Eq, Show)

data RouteTarget = RouteTarget
  { apiVersion :: !Text
  , kind :: !Text
  , name :: !Text
  , namespace :: !Text
  }
  deriving stock (Generic, Eq, Show)

data RouteOp
  = RouteTo !RouteTarget
  | DeleteRouteOverride
  | DeleteEnforcerRoute
  deriving stock (Eq, Show)

newtype Origin = Origin Text
  deriving stock (Eq, Show)

portalOrigin :: PublicHost -> Origin
portalOrigin host = Origin ("https://" <> publicHostText host)

addOrigin :: Origin -> [Origin] -> [Origin]
addOrigin origin = deduplicate . (<> [origin])

removeOrigin :: Origin -> [Origin] -> [Origin]
removeOrigin origin = deduplicate . filter (/= origin)

deduplicate :: (Eq a) => [a] -> [a]
deduplicate = foldl' (\seen value -> if value `elem` seen then seen else seen <> [value]) []

data ShomeiPortalChange
  = EnablePortal !PublicHost !BaseDomain
  | DisablePortal !PublicHost
  deriving stock (Eq, Show)

data AccessOps = AccessOps
  { checkEnforcerPresent :: !(IO Bool)
  , loadBackends :: !(IO BackendMap)
  , saveBackends :: !(BackendMap -> IO ())
  , applyRouteOp :: !(Namespace -> PublicHost -> RouteOp -> IO ())
  , applyShomeiPortal :: !(ShomeiPortalChange -> IO ())
  }
  deriving stock (Generic)

authPlaneMissingMessage :: Text
authPlaneMissingMessage =
  T.unlines
    [ "this site sets an access policy, but the nagare auth plane is not installed."
    , "       Install it once with the managed DB, shomei, en, and nagare-access sequence in docs/user/access.md."
    , "       Then redeploy."
    ]

resolveAccess :: Namespace -> ServiceName -> Text -> Maybe AccessPolicy -> IO ()
resolveAccess ns name rawHost policy = do
  base <- either dieT pure (inferBaseDomain rawHost)
  resolveAccessRouteWithOps kubectlAccessOps base ns name (AccessRoute rawHost ExistingDomainMapping) policy

resolveDeploymentAccess :: Text -> Deployment -> IO ()
resolveDeploymentAccess rawBase dep = do
  base <- either dieT pure (mkBaseDomain rawBase)
  resolveDeploymentAccessWithOps kubectlAccessOps base dep

resolveDeploymentAccessWithOps :: AccessOps -> BaseDomain -> Deployment -> IO ()
resolveDeploymentAccessWithOps ops base dep = do
  let routes = deploymentAccessRoutes (baseDomainText base) dep
  case dep ^. #access of
    Just policy
      | policy ^. #role == AuthPortal && length routes /= 1 ->
          dieT "an auth portal must have exactly one public host"
    _ -> pure ()
  forM_ routes $ \route ->
    resolveAccessRouteWithOps ops base (dep ^. #namespace) (dep ^. #name) route (dep ^. #access)

resolveAccessRouteWithOps :: AccessOps -> BaseDomain -> Namespace -> ServiceName -> AccessRoute -> Maybe AccessPolicy -> IO ()
resolveAccessRouteWithOps ops base ns name route policy = do
  host <- either dieT pure (mkPublicHost (route ^. #host))
  case policy of
    Just accessPolicy -> registerRoute host accessPolicy
    Nothing -> unregisterRoute host
  where
    registerRoute host accessPolicy = do
      present <- ops ^. #checkEnforcerPresent
      unless present (dieT authPlaneMissingMessage)
      backends <- ops ^. #loadBackends
      let desiredRole = if accessPolicy ^. #role == AuthPortal then PortalEntry else ProtectedEntry
          entry = BackendEntry (upstreamFor ns name) desiredRole
      when (desiredRole == PortalEntry && not (isUnderBaseDomain base host)) $
        dieT
          ( "the auth portal host "
              <> publicHostText host
              <> " is not under the base domain "
              <> baseDomainText base
              <> ".\n       Session cookies are scoped to ."
              <> baseDomainText base
              <> ", so a portal elsewhere could not sign anyone in."
          )
      case (desiredRole, portalRegistration backends) of
        (PortalEntry, Just (existingHost, existingEntry))
          | existingHost /= host ->
              dieT
                ( publicHostText existingHost
                    <> " is already the auth portal (service "
                    <> serviceFromUpstream (existingEntry ^. #upstream)
                    <> ").\n       Remove `access = Just authPortal` from that app (or delete it) before registering another portal."
                )
        _ -> pure ()
      let previous = lookupEntry host backends
          updated = insertEntry host entry backends
      (ops ^. #saveBackends) updated
      (ops ^. #applyRouteOp) ns host (RouteTo (knativeServiceTarget enforcerName backendConfigMapNamespace))
      case desiredRole of
        PortalEntry -> (ops ^. #applyShomeiPortal) (EnablePortal host base)
        ProtectedEntry ->
          when (maybe False (\entry -> entry ^. #role == PortalEntry) previous) $
            (ops ^. #applyShomeiPortal) (DisablePortal host)

    unregisterRoute host = do
      backends <- ops ^. #loadBackends
      let previous = lookupEntry host backends
          updated = deleteEntry host backends
      when (updated /= backends) ((ops ^. #saveBackends) updated)
      when (maybe False (\entry -> entry ^. #role == PortalEntry) previous) $
        (ops ^. #applyShomeiPortal) (DisablePortal host)
      case route ^. #mode of
        ExistingDomainMapping -> (ops ^. #applyRouteOp) ns host (RouteTo (knativeServiceTarget (serviceNameText name) (namespaceText ns)))
        DefaultKnativeHost -> (ops ^. #applyRouteOp) ns host DeleteRouteOverride

removeServiceAccessWithOps :: AccessOps -> Namespace -> ServiceName -> IO [PublicHost]
removeServiceAccessWithOps ops ns name = do
  present <- ops ^. #checkEnforcerPresent
  if not present
    then pure []
    else do
      BackendMap entries <- ops ^. #loadBackends
      let upstream = upstreamFor ns name
          removed = [(host, entry) | (host, entry) <- Map.toAscList entries, entry ^. #upstream == upstream]
          updated = BackendMap (foldr (Map.delete . fst) entries removed)
      unless (null removed) $ do
        (ops ^. #saveBackends) updated
        forM_ removed $ \(host, entry) -> do
          (ops ^. #applyRouteOp) ns host DeleteEnforcerRoute
          when (entry ^. #role == PortalEntry) ((ops ^. #applyShomeiPortal) (DisablePortal host))
      pure (map fst removed)

lookupEntry :: PublicHost -> BackendMap -> Maybe BackendEntry
lookupEntry host (BackendMap entries) = Map.lookup host entries

insertEntry :: PublicHost -> BackendEntry -> BackendMap -> BackendMap
insertEntry host entry (BackendMap entries) = BackendMap (Map.insert host entry entries)

deleteEntry :: PublicHost -> BackendMap -> BackendMap
deleteEntry host (BackendMap entries) = BackendMap (Map.delete host entries)

deploymentAccessRoutes :: Text -> Deployment -> [AccessRoute]
deploymentAccessRoutes baseDomain dep =
  case dep ^. #domains of
    [] -> [AccessRoute (serviceNameText (dep ^. #name) <> "." <> namespaceText (dep ^. #namespace) <> "." <> baseDomain) DefaultKnativeHost]
    domains -> [AccessRoute (domainText (domain ^. #domain)) ExistingDomainMapping | domain <- domains]

upstreamFor :: Namespace -> ServiceName -> Text
upstreamFor ns name = "http://" <> serviceNameText name <> "." <> namespaceText ns <> ".svc.cluster.local"

knativeServiceTarget :: Text -> Text -> RouteTarget
knativeServiceTarget = RouteTarget "serving.knative.dev/v1" "Service"

renderBackendConfigMap :: BackendMap -> ByteString
renderBackendConfigMap backends =
  LBS.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("ConfigMap" :: Text)
      , "metadata" .= object ["name" .= backendConfigMapName, "namespace" .= backendConfigMapNamespace, "labels" .= object ["nagare.dev/managed-by" .= ("nagarectl" :: Text)]]
      , "data" .= object [Key.fromText backendMapKey .= TE.decodeUtf8 (LBS.toStrict (encode backends))]
      ]

renderAccessDomainMapping :: Text -> Text -> RouteTarget -> ByteString
renderAccessDomainMapping objectNamespace host target =
  LBS.toStrict . encode $
    object
      [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
      , "kind" .= ("DomainMapping" :: Text)
      , "metadata" .= object ["name" .= host, "namespace" .= objectNamespace, "labels" .= object ["nagare.dev/managed-by" .= ("nagarectl" :: Text)]]
      , "spec" .= object ["ref" .= object ["apiVersion" .= (target ^. #apiVersion), "kind" .= (target ^. #kind), "name" .= (target ^. #name), "namespace" .= (target ^. #namespace)]]
      ]

kubectlAccessOps :: AccessOps
kubectlAccessOps =
  AccessOps
    { checkEnforcerPresent = do
        ksvc <- kubectlExists ["get", "ksvc", T.unpack enforcerName, "-n", T.unpack backendConfigMapNamespace]
        svc <- kubectlExists ["get", "service", T.unpack enforcerName, "-n", T.unpack backendConfigMapNamespace]
        pure (ksvc && svc)
    , loadBackends = loadBackendMapFromCluster
    , saveBackends = \backends -> applyManifests [renderBackendConfigMap backends] >> reloadEnforcerBackendMap
    , applyRouteOp = \ns host -> \case
        RouteTo target
          | isCentralEnforcer target -> do
              deleteDomainMapping (namespaceText ns) (publicHostText host)
              applyManifests [renderAccessDomainMapping backendConfigMapNamespace (publicHostText host) target]
          | otherwise -> do
              deleteDomainMapping backendConfigMapNamespace (publicHostText host)
              applyManifests [renderAccessDomainMapping (namespaceText ns) (publicHostText host) target]
        DeleteRouteOverride -> do
          deleteDomainMapping (namespaceText ns) (publicHostText host)
          deleteDomainMapping backendConfigMapNamespace (publicHostText host)
        DeleteEnforcerRoute -> deleteDomainMapping backendConfigMapNamespace (publicHostText host)
    , applyShomeiPortal = applyShomeiPortalChange
    }

reloadEnforcerBackendMap :: IO ()
reloadEnforcerBackendMap = do
  stamp <- T.pack . show . (floor :: POSIXTime -> Int) <$> getPOSIXTime
  run_ $ cmd "kubectl" & addArgs ["patch", "ksvc", T.unpack enforcerName, "-n", T.unpack backendConfigMapNamespace, "--type", "merge", "-p", T.unpack (reloadPatch stamp)]

reloadPatch :: Text -> Text
reloadPatch stamp = "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"nagare.dev/backend-map-reload\":\"" <> stamp <> "\"}}}}}"

isCentralEnforcer :: RouteTarget -> Bool
isCentralEnforcer target = target ^. #apiVersion == "serving.knative.dev/v1" && target ^. #kind == "Service" && target ^. #name == enforcerName && target ^. #namespace == backendConfigMapNamespace

deleteDomainMapping :: Text -> Text -> IO ()
deleteDomainMapping objectNamespace host =
  run_ $ cmd "kubectl" & addArgs ["delete", "domainmapping", T.unpack host, "-n", T.unpack objectNamespace, "--ignore-not-found"]

kubectlExists :: [String] -> IO Bool
kubectlExists args = do
  (code, _ :: StdoutRaw) <- run $ cmd "kubectl" & addArgs args & silenceStderr
  pure (code == ExitSuccess)

loadBackendMapFromCluster :: IO BackendMap
loadBackendMapFromCluster = do
  (code, StdoutRaw out) <-
    run $ cmd "kubectl" & addArgs ["get", "configmap", T.unpack backendConfigMapName, "-n", T.unpack backendConfigMapNamespace, "-o", "json"] & silenceStderr
  case code of
    ExitFailure _ -> pure mempty
    ExitSuccess -> either dieT pure (parseBackendConfigMap out)

parseBackendConfigMap :: ByteString -> Either Text BackendMap
parseBackendConfigMap bytes = do
  value <- mapLeft (("could not decode nagare-access backend ConfigMap JSON: " <>) . T.pack) (eitherDecodeStrict bytes)
  case lookupPath ["data", backendMapKey] value of
    Nothing -> Right mempty
    Just (String raw) -> mapLeft (("could not decode " <> backendMapKey <> ": ") <>) (mapLeft T.pack (eitherDecodeStrict (TE.encodeUtf8 raw)))
    Just _ -> Left ("ConfigMap key " <> backendMapKey <> " must be a JSON object string")

applyShomeiPortalChange :: ShomeiPortalChange -> IO ()
applyShomeiPortalChange change = do
  env <- loadShomeiEnv
  case change of
    EnablePortal host base -> do
      let desiredOrigin = portalOrigin host
          origins = addOrigin desiredOrigin (parseOrigins (Map.findWithDefault "" "SHOMEI_WEBAUTHN_ORIGINS" env))
          desired =
            Map.fromList
              [ ("SHOMEI_WEBAUTHN_RP_ID", baseDomainText base)
              , ("SHOMEI_WEBAUTHN_ORIGINS", renderOrigins origins)
              , ("SHOMEI_PUBLIC_BASE_URL", originText desiredOrigin)
              ]
      when (any (\(key, value) -> Map.lookup key env /= Just value) (Map.toList desired)) $
        setShomeiEnv [key <> "=" <> value | (key, value) <- Map.toList desired]
    DisablePortal host -> do
      let currentOrigins = parseOrigins (Map.findWithDefault "" "SHOMEI_WEBAUTHN_ORIGINS" env)
          origins = removeOrigin (portalOrigin host) currentOrigins
          publicBasePresent = Map.member "SHOMEI_PUBLIC_BASE_URL" env
      when (origins /= currentOrigins || publicBasePresent) $
        setShomeiEnv ["SHOMEI_WEBAUTHN_ORIGINS=" <> renderOrigins origins, "SHOMEI_PUBLIC_BASE_URL-"]

loadShomeiEnv :: IO (Map Text Text)
loadShomeiEnv = do
  (code, StdoutRaw out) <-
    run $ cmd "kubectl" & addArgs ["-n", T.unpack backendConfigMapNamespace, "get", "deployment", "shomei", "-o", "json"] & silenceStderr
  case code of
    ExitFailure _ -> dieT "could not read the shomei Deployment while configuring the auth portal"
    ExitSuccess -> either dieT pure (parseDeploymentEnv out)

parseDeploymentEnv :: ByteString -> Either Text (Map Text Text)
parseDeploymentEnv bytes = do
  value <- mapLeft (("could not decode shomei Deployment JSON: " <>) . T.pack) (eitherDecodeStrict bytes)
  case lookupPath ["spec", "template", "spec", "containers"] value of
    Just (Array containers) ->
      case toList containers of
        container : _ ->
          case lookupPath ["env"] container of
            Just (Array entries) -> Right (Map.fromList [(name, val) | entry <- toList entries, Just name <- [textAt ["name"] entry], Just val <- [textAt ["value"] entry]])
            _ -> Right Map.empty
        [] -> Left "shomei Deployment has no containers"
    _ -> Left "shomei Deployment has no container list"

setShomeiEnv :: [Text] -> IO ()
setShomeiEnv assignments =
  run_ $ cmd "kubectl" & addArgs (["-n", T.unpack backendConfigMapNamespace, "set", "env", "deployment/shomei"] <> map T.unpack assignments)

parseOrigins :: Text -> [Origin]
parseOrigins = map Origin . filter (not . T.null) . map T.strip . T.splitOn ","

renderOrigins :: [Origin] -> Text
renderOrigins = T.intercalate "," . map originText

originText :: Origin -> Text
originText (Origin origin) = origin

lookupPath :: [Text] -> Value -> Maybe Value
lookupPath [] value = Just value
lookupPath (key : rest) (Object obj) = KeyMap.lookup (Key.fromText key) obj >>= lookupPath rest
lookupPath _ _ = Nothing

textAt :: [Text] -> Value -> Maybe Text
textAt path value = case lookupPath path value of
  Just (String text) -> Just text
  _ -> Nothing

serviceFromUpstream :: Text -> Text
serviceFromUpstream upstream =
  fst . T.breakOn "." . fromMaybeText upstream $ T.stripPrefix "http://" upstream
  where
    fromMaybeText fallback = maybe fallback id

inferBaseDomain :: Text -> Either Text BaseDomain
inferBaseDomain host =
  case T.splitOn "." (T.toLower (T.strip host)) of
    _first : rest@(_ : _) -> mkBaseDomain (T.intercalate "." rest)
    _ -> Left "cannot infer a base domain from the public host"

dieT :: Text -> IO a
dieT msg = TIO.hPutStrLn stderr ("nagarectl: " <> msg) >> exitFailure

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right
