-- | Deploy-time wiring for identity-aware access.
--
-- The DSL renderer deliberately emits no access-specific YAML. This module owns
-- the live-cluster side effects for that field: maintain the enforcer backend
-- map and make the public host route to either the app or the shared enforcer.
module Nagare.Access.Resolve
  ( AccessOps (..)
  , AccessRoute (..)
  , RouteMode (..)
  , RouteOp (..)
  , RouteTarget (..)
  , authPlaneMissingMessage
  , backendConfigMapName
  , backendConfigMapNamespace
  , backendMapKey
  , deploymentAccessRoutes
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
import Data.Aeson (Value (Object, String), eitherDecodeStrict, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Deploy (applyManifests)
import Nagare.Dsl.Access (AccessPolicy)
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

backendConfigMapNamespace :: Text
backendConfigMapNamespace = "nagare-system"

backendConfigMapName :: Text
backendConfigMapName = "nagare-access-backends"

backendMapKey :: Text
backendMapKey = "backends.json"

enforcerName :: Text
enforcerName = "nagare-access"

data RouteMode
  = ExistingDomainMapping
  | DefaultKnativeHost
  deriving stock (Eq, Show)

data AccessRoute = AccessRoute
  { arHost :: !Text
  , arMode :: !RouteMode
  }
  deriving stock (Eq, Show)

data RouteTarget = RouteTarget
  { rtName :: !Text
  , rtNamespace :: !Text
  }
  deriving stock (Eq, Show)

data RouteOp
  = RouteTo !RouteTarget
  | DeleteRouteOverride
  deriving stock (Eq, Show)

data AccessOps = AccessOps
  { checkEnforcerPresent :: !(IO Bool)
  , loadBackendMap :: !(IO (Either Text (Maybe (Map Text Text))))
  , writeBackendMap :: !(Map Text Text -> IO ())
  , applyRouteOp :: !(Text -> Text -> RouteOp -> IO ())
  }

authPlaneMissingMessage :: Text
authPlaneMissingMessage =
  T.unlines
    [ "this site sets `access = requireLogin`, but the nagare auth plane is not installed."
    , "       Install it once with the managed DB, shomei, en, and nagare-access sequence in docs/user/access.md."
    , "       Then redeploy."
    ]

-- | Resolve one host as an existing custom DomainMapping. The route-aware
-- 'resolveDeploymentAccess' is what deploy paths should normally call.
resolveAccess :: Namespace -> ServiceName -> Text -> Maybe AccessPolicy -> IO ()
resolveAccess ns name host =
  resolveAccessRouteWithOps kubectlAccessOps ns name (AccessRoute host ExistingDomainMapping)

resolveDeploymentAccess :: Text -> Deployment -> IO ()
resolveDeploymentAccess =
  resolveDeploymentAccessWithOps kubectlAccessOps

resolveDeploymentAccessWithOps :: AccessOps -> Text -> Deployment -> IO ()
resolveDeploymentAccessWithOps ops baseDomain dep =
  forM_ (deploymentAccessRoutes baseDomain dep) $ \route ->
    resolveAccessRouteWithOps ops (dep ^. #namespace) (dep ^. #name) route (dep ^. #access)

resolveAccessRouteWithOps :: AccessOps -> Namespace -> ServiceName -> AccessRoute -> Maybe AccessPolicy -> IO ()
resolveAccessRouteWithOps ops ns name route policy =
  case policy of
    Just _ -> do
      present <- checkEnforcerPresent ops
      unless present (dieT authPlaneMissingMessage)
      backends <- requireBackendMap =<< loadBackendMap ops
      let host = canonicalHost (arHost route)
          updated = Map.insert host (upstreamFor ns name) backends
      writeBackendMap ops updated
      applyRouteOp ops (namespaceText ns) host (RouteTo (RouteTarget enforcerName backendConfigMapNamespace))
    Nothing -> do
      loaded <- loadBackendMap ops
      case loaded of
        Left err -> dieT err
        Right Nothing -> pure ()
        Right (Just backends) -> do
          let withoutHost = Map.delete (canonicalHost (arHost route)) backends
          when (withoutHost /= backends) (writeBackendMap ops withoutHost)
      let host = canonicalHost (arHost route)
      case arMode route of
        ExistingDomainMapping ->
          applyRouteOp ops (namespaceText ns) host (RouteTo (RouteTarget (serviceNameText name) (namespaceText ns)))
        DefaultKnativeHost ->
          applyRouteOp ops (namespaceText ns) host DeleteRouteOverride
  where
    requireBackendMap (Left err) = dieT err
    requireBackendMap (Right Nothing) = pure Map.empty
    requireBackendMap (Right (Just m)) = pure m

deploymentAccessRoutes :: Text -> Deployment -> [AccessRoute]
deploymentAccessRoutes baseDomain dep =
  case dep ^. #domains of
    [] ->
      [ AccessRoute
          { arHost = serviceNameText (dep ^. #name) <> "." <> namespaceText (dep ^. #namespace) <> "." <> baseDomain
          , arMode = DefaultKnativeHost
          }
      ]
    domains ->
      [ AccessRoute
          { arHost = domainText (d ^. #domain)
          , arMode = ExistingDomainMapping
          }
      | d <- domains
      ]

upstreamFor :: Namespace -> ServiceName -> Text
upstreamFor ns name =
  "http://" <> serviceNameText name <> "." <> namespaceText ns <> ".svc.cluster.local"

renderBackendConfigMap :: Map Text Text -> ByteString
renderBackendConfigMap backends =
  LBS.toStrict $
    encode $
      object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("ConfigMap" :: Text)
        , "metadata"
            .= object
              [ "name" .= backendConfigMapName
              , "namespace" .= backendConfigMapNamespace
              , "labels" .= object ["nagare.dev/managed-by" .= ("nagarectl" :: Text)]
              ]
        , "data" .= object [Key.fromText backendMapKey .= TE.decodeUtf8 (LBS.toStrict (encode backends))]
        ]

renderAccessDomainMapping :: Text -> Text -> RouteTarget -> ByteString
renderAccessDomainMapping objectNamespace host target =
  LBS.toStrict $
    encode $
      object
        [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
        , "kind" .= ("DomainMapping" :: Text)
        , "metadata"
            .= object
              [ "name" .= host
              , "namespace" .= objectNamespace
              , "labels" .= object ["nagare.dev/managed-by" .= ("nagarectl" :: Text)]
              ]
        , "spec"
            .= object
              [ "ref"
                  .= object
                    [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
                    , "kind" .= ("Service" :: Text)
                    , "name" .= rtName target
                    , "namespace" .= rtNamespace target
                    ]
              ]
        ]

kubectlAccessOps :: AccessOps
kubectlAccessOps =
  AccessOps
    { checkEnforcerPresent = do
        ksvc <- kubectlExists ["get", "ksvc", T.unpack enforcerName, "-n", T.unpack backendConfigMapNamespace]
        svc <- kubectlExists ["get", "service", T.unpack enforcerName, "-n", T.unpack backendConfigMapNamespace]
        pure (ksvc && svc)
    , loadBackendMap = loadBackendMapFromCluster
    , writeBackendMap = applyManifests . (: []) . renderBackendConfigMap
    , applyRouteOp = \objectNamespace host -> \case
        RouteTo target -> applyManifests [renderAccessDomainMapping objectNamespace host target]
        DeleteRouteOverride ->
          run_ $
            cmd "kubectl"
              & addArgs
                [ "delete"
                , "domainmapping"
                , T.unpack host
                , "-n"
                , T.unpack objectNamespace
                , "--ignore-not-found"
                ]
    }

kubectlExists :: [String] -> IO Bool
kubectlExists args = do
  (code, _ :: StdoutRaw) <- run $ cmd "kubectl" & addArgs args & silenceStderr
  pure (code == ExitSuccess)

loadBackendMapFromCluster :: IO (Either Text (Maybe (Map Text Text)))
loadBackendMapFromCluster = do
  (code, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "get"
          , "configmap"
          , T.unpack backendConfigMapName
          , "-n"
          , T.unpack backendConfigMapNamespace
          , "-o"
          , "json"
          ]
        & silenceStderr
  pure $ case code of
    ExitFailure _ -> Right Nothing
    ExitSuccess -> Just <$> parseBackendConfigMap out

parseBackendConfigMap :: ByteString -> Either Text (Map Text Text)
parseBackendConfigMap bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode nagare-access backend ConfigMap JSON: " <> T.pack e)
    Right v -> case lookupPath ["data", backendMapKey] v of
      Nothing -> Right Map.empty
      Just (String raw) -> parseBackendJson raw
      Just _ -> Left ("ConfigMap key " <> backendMapKey <> " must be a JSON object string")

parseBackendJson :: Text -> Either Text (Map Text Text)
parseBackendJson raw =
  case eitherDecodeStrict (TE.encodeUtf8 raw) of
    Left e -> Left ("could not decode " <> backendMapKey <> ": " <> T.pack e)
    Right (Object obj) ->
      traverseStrings [(Key.toText k, v) | (k, v) <- KeyMap.toList obj]
    Right _ -> Left (backendMapKey <> " must be a JSON object")

traverseStrings :: [(Text, Value)] -> Either Text (Map Text Text)
traverseStrings entries =
  Map.fromList <$> traverse one entries
  where
    one (k, String v) = Right (canonicalHost k, v)
    one (k, _) = Left ("backend map value for " <> k <> " must be a string URL")

lookupPath :: [Text] -> Value -> Maybe Value
lookupPath [] v = Just v
lookupPath (k : ks) (Object o) = KeyMap.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing

canonicalHost :: Text -> Text
canonicalHost =
  T.toLower . T.dropWhileEnd (== '.') . T.strip

dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
