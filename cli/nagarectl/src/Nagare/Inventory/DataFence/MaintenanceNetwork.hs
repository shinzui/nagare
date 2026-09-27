-- | Session-bound ingress denial for an online database maintenance fence.
-- The selected engine Pod remains available over its local Unix socket while
-- ordinary Pod-to-Pod connections are denied. This policy is only one part of
-- maintenance exclusion: caller controls must also stop reviewed writers,
-- observe admission guards, and pin the live Pod incarnation.
module Nagare.Inventory.DataFence.MaintenanceNetwork
  ( MaintenanceNetworkPin (..)
  , mkMaintenanceNetworkPin
  , maintenancePolicyName
  , maintenancePolicyObject
  , MaintenanceNetworkTransport (..)
  , kubectlMaintenanceNetworkTransport
  , observeMaintenancePolicy
  , maintenancePodSelected
  , observeMaintenancePolicyAuthority
  , installMaintenancePolicy
  , removeMaintenancePolicy
  ) where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Set qualified as Set
import Data.Vector qualified as V
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence.MountGuard (validUid)
import Nagare.Inventory.DataFence.GuardAuthority
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types (digestText, mkName)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data MaintenanceNetworkPin = MaintenanceNetworkPin
  { networkSession :: !Text
  , networkNamespace :: !Text
  , networkDatabase :: !Text
  , networkPodName :: !Text
  , networkPodUid :: !Text
  }
  deriving stock (Eq, Show)

mkMaintenanceNetworkPin :: Text -> Text -> Text -> Text -> Text
  -> Either Text MaintenanceNetworkPin
mkMaintenanceNetworkPin session namespace database podName podUid = do
  unless (not (T.null session) && T.length session <= 128
      && T.all (\character -> character `elem` (['a'..'z'] <> ['0'..'9'] <> "-_")) session)
    (Left "maintenance session ID is malformed")
  _ <- mkName namespace
  _ <- mkName database
  _ <- mkName podName
  unless (validUid podUid) (Left "maintenance Pod UID is malformed")
  pure (MaintenanceNetworkPin session namespace database podName podUid)

maintenancePolicyName :: MaintenanceNetworkPin -> Text
maintenancePolicyName pin = "nagare-maintenance-" <> T.take 40 (digestText
  (contentDigest (TE.encodeUtf8 (T.intercalate "/"
    [networkSession pin, networkNamespace pin, networkPodName pin,
      networkPodUid pin]))))

maintenancePolicyObject :: MaintenanceNetworkPin -> Value
maintenancePolicyObject pin = object
  [ "apiVersion" .= ("networking.k8s.io/v1" :: Text)
  , "kind" .= ("NetworkPolicy" :: Text)
  , "metadata" .= object
      [ "name" .= maintenancePolicyName pin
      , "namespace" .= networkNamespace pin
      , "annotations" .= object
          [ "nagare.dev/maintenance-session" .= networkSession pin
          , "nagare.dev/maintenance-pod-uid" .= networkPodUid pin ] ]
  , "spec" .= object
      [ "podSelector" .= object ["matchLabels" .= object
          [ "statefulset.kubernetes.io/pod-name" .= networkPodName pin
          , "nagare.dev/database" .= networkDatabase pin ]]
      , "policyTypes" .= (["Ingress"] :: [Text])
      , "ingress" .= ([] :: [Value]) ]
  ]

-- | The policy's Pod selector must actually select the pinned live Pod.
-- A plausible policy spec against a differently labelled Pod is no fence.
maintenancePodSelected :: MaintenanceNetworkPin -> Value -> Either Text ()
maintenancePodSelected pin listing = do
  root <- asObject listing
  items <- case KM.lookup "items" root of
    Just (Array values) -> Right (V.toList values)
    _ -> Left "maintenance Pod list lacks items"
  matches <- traverse one items
  unless (length [() | Just () <- matches] == 1)
    (Left "maintenance policy does not select one exact running Pod")
  where
    one value = do
      pod <- asObject value
      metadata <- objectField "metadata" pod
      name <- textField "name" metadata
      if name /= networkPodName pin then Right Nothing else do
        unless (KM.lookup "namespace" metadata
            == Just (String (networkNamespace pin))
            && KM.lookup "uid" metadata == Just (String (networkPodUid pin))
            && KM.lookup "deletionTimestamp" metadata == Nothing)
          (Left "maintenance Pod identity changed or is terminating")
        labels <- objectField "labels" metadata
        unless (KM.lookup "statefulset.kubernetes.io/pod-name" labels
              == Just (String (networkPodName pin))
            && KM.lookup "nagare.dev/database" labels
              == Just (String (networkDatabase pin)))
          (Left "maintenance ingress policy does not select the pinned Pod")
        status <- objectField "status" pod
        unless (KM.lookup "phase" status == Just (String "Running"))
          (Left "maintenance Pod is not running")
        spec <- objectField "spec" pod
        unless (KM.lookup "hostNetwork" spec `elem` [Nothing, Just (Bool False)])
          (Left "maintenance ingress policy cannot fence a host-network Pod")
        pure (Just ())

data MaintenanceNetworkTransport = MaintenanceNetworkTransport
  { readMaintenancePolicy :: !(Text -> Text -> IO (Either Text (Maybe Value)))
  , listMaintenancePolicies :: !(Text -> IO (Either Text Value))
  , createMaintenancePolicy :: !(Value -> IO (Either Text ()))
  , deleteMaintenancePolicy :: !(Text -> Text -> Text -> Text -> IO (Either Text ()))
  }

-- | Return the exact UID and resourceVersion. A terminating policy is not
-- enforcing evidence, even if its spec still appears in an API read.
observeMaintenancePolicy :: MaintenanceNetworkTransport -> MaintenanceNetworkPin
  -> IO (Either Text (Maybe (Text, Text)))
observeMaintenancePolicy transport pin = do
  listing <- listMaintenancePolicies transport (networkNamespace pin)
  observed <- readMaintenancePolicy transport (networkNamespace pin)
    (maintenancePolicyName pin)
  pure $ do
    policies <- listing
    noCompetingIngress pin policies
    current <- observed
    traverse (validatePolicy pin) current

-- | NetworkPolicy ingress permissions are additive. Until the provider can
-- prove a narrower selector interaction, another ingress policy in this
-- namespace makes this deny policy insufficient for maintenance exclusion.
noCompetingIngress :: MaintenanceNetworkPin -> Value -> Either Text ()
noCompetingIngress pin listing = do
  root <- asObject listing
  items <- case KM.lookup "items" root of
    Just (Array values) -> Right (V.toList values)
    _ -> Left "maintenance NetworkPolicy list lacks items"
  _ <- traverse one items
  pure ()
  where
    one value = do
      policy <- asObject value
      metadata <- objectField "metadata" policy
      name <- textField "name" metadata
      unless (KM.lookup "namespace" metadata
          == Just (String (networkNamespace pin)))
        (Left "maintenance NetworkPolicy list contains another namespace")
      unless (name == maintenancePolicyName pin) $ do
        spec <- objectField "spec" policy
        types <- case KM.lookup "policyTypes" spec of
          Just (Array values) -> traverse asType (V.toList values)
          Nothing -> Right ["Ingress"]
          _ -> Left "competing NetworkPolicy has malformed policyTypes"
        unless (not (null types) && types == ["Egress"])
          (Left "another ingress NetworkPolicy may admit the maintenance Pod")
    asType (String value) | value `elem` ["Ingress", "Egress"] = Right value
    asType _ = Left "competing NetworkPolicy has an unknown policy type"

-- | Reviewed workload identities must be unable to add an allowing policy,
-- edit an existing policy, start a host-network bypass, change the target
-- Pod's selector labels, or run a second local client with Pod exec/attach.
-- The operator identity is trusted;
-- this checks the accepted workloads whose exclusion the fence relies on.
observeMaintenancePolicyAuthority :: GuardAccessTransport
  -> MaintenanceNetworkTransport -> [Text] -> [(Text, Text, Text)]
  -> MaintenanceNetworkPin
  -> IO (Either Text Bool)
observeMaintenancePolicyAuthority access network principals controllers pin
  | null principals = pure (Left "maintenance has no untrusted principals")
  | otherwise = do
      listing <- listMaintenancePolicies network (networkNamespace pin)
      case listing >>= listedNames of
        Left reason -> pure (Left reason)
        Right names -> do
          result <- firstAllowedGuardQuery access
            (Set.toAscList (Set.fromList
            [GuardAccessQuery principal group (Just (networkNamespace pin))
              verb resource subresource name
            | principal <- principals
            , (group, resource, subresource, verb, name) <-
                [("networking.k8s.io", "networkpolicies", Nothing, verb, name)
                  | name <- names, verb <- ["update", "patch", "delete"]]
                  <> [("networking.k8s.io", "networkpolicies", Nothing, verb, "")
                    | verb <- ["create", "deletecollection"]]
                  <> [("", "pods", Nothing, verb, networkPodName pin)
                    | verb <- ["update", "patch"]]
                  <> [("", "pods", Nothing, "create", "")]
                  <> [(group, resource, Nothing, "create", "")
                    | (group, resource) <-
                        [("apps", "deployments"), ("apps", "statefulsets"),
                          ("apps", "daemonsets"), ("batch", "jobs"),
                          ("batch", "cronjobs")]]
                  <> [(group, resource, Nothing, verb, name)
                    | (group, resource, name) <- controllers
                    , verb <- ["update", "patch"]]
                  <> [("", "pods", Just subresource, "create", networkPodName pin)
                    | subresource <- ["exec", "attach", "portforward", "proxy"]]
                  <> [("", "pods", Just "ephemeralcontainers", verb,
                    networkPodName pin) | verb <- ["update", "patch"]]
            ]))
          pure $ case result of
            Left reason -> Left reason
            Right Nothing -> Right True
            Right (Just query) -> Left
              ("maintenance network exclusion can be bypassed: "
                <> T.pack (show query))
  where
    listedNames value = do
      root <- asObject value
      items <- case KM.lookup "items" root of
        Just (Array values) -> Right (V.toList values)
        _ -> Left "maintenance NetworkPolicy list lacks items"
      names <- traverse (\item -> do
        policy <- asObject item
        metadata <- objectField "metadata" policy
        unless (KM.lookup "namespace" metadata
            == Just (String (networkNamespace pin)))
          (Left "maintenance policy authority saw another namespace")
        textField "name" metadata) items
      pure (maintenancePolicyName pin : names)

validatePolicy :: MaintenanceNetworkPin -> Value -> Either Text (Text, Text)
validatePolicy pin current = do
  root <- asObject current
  unless (KM.lookup "apiVersion" root == Just (String "networking.k8s.io/v1")
      && KM.lookup "kind" root == Just (String "NetworkPolicy"))
    (Left "maintenance ingress policy has another API kind")
  metadata <- objectField "metadata" root
  unless (KM.lookup "name" metadata == Just (String (maintenancePolicyName pin))
      && KM.lookup "namespace" metadata == Just (String (networkNamespace pin))
      && KM.lookup "deletionTimestamp" metadata == Nothing)
    (Left "maintenance ingress policy identity changed or is terminating")
  annotations <- objectField "annotations" metadata
  unless (KM.lookup "nagare.dev/maintenance-session" annotations
        == Just (String (networkSession pin))
      && KM.lookup "nagare.dev/maintenance-pod-uid" annotations
        == Just (String (networkPodUid pin)))
    (Left "maintenance ingress policy belongs to another session or Pod")
  desired <- asObject (maintenancePolicyObject pin)
  spec <- objectField "spec" root
  expected <- objectField "spec" desired
  -- The API server may omit an empty ingress list. With Ingress selected,
  -- both forms deny every inbound connection.
  unless (KM.lookup "podSelector" spec == KM.lookup "podSelector" expected
      && KM.lookup "policyTypes" spec == KM.lookup "policyTypes" expected
      && KM.lookup "ingress" spec `elem` [Nothing, Just (Array V.empty)]
      && all (`elem` ["podSelector", "policyTypes", "ingress"])
        (KM.keys spec))
    (Left "maintenance ingress policy no longer denies exact Pod ingress")
  uid <- textField "uid" metadata
  revision <- textField "resourceVersion" metadata
  unless (validUid uid) (Left "maintenance ingress policy UID is malformed")
  pure (uid, revision)

installMaintenancePolicy :: MaintenanceNetworkTransport -> MaintenanceNetworkPin
  -> IO (Either Text (Text, Text))
installMaintenancePolicy transport pin = do
  before <- observeMaintenancePolicy transport pin
  case before of
    Left reason -> pure (Left reason)
    Right (Just identity) -> pure (Right identity)
    Right Nothing -> do
      created <- createMaintenancePolicy transport (maintenancePolicyObject pin)
      after <- observeMaintenancePolicy transport pin
      pure $ case (created, after) of
        (_, Right (Just identity)) -> Right identity
        (Left reason, _) -> Left reason
        (_, Left reason) -> Left reason
        _ -> Left "maintenance ingress policy creation is unproved"

removeMaintenancePolicy :: MaintenanceNetworkTransport -> MaintenanceNetworkPin
  -> IO (Either Text ())
removeMaintenancePolicy transport pin = do
  before <- observeMaintenancePolicy transport pin
  case before of
    Left reason -> pure (Left reason)
    Right Nothing -> pure (Right ())
    Right (Just (uid, revision)) -> do
      removed <- deleteMaintenancePolicy transport (networkNamespace pin)
        (maintenancePolicyName pin) uid revision
      after <- observeMaintenancePolicy transport pin
      pure $ case (removed, after) of
        (_, Right Nothing) -> Right ()
        (Left reason, _) -> Left reason
        (_, Left reason) -> Left reason
        _ -> Left "maintenance ingress policy removal is unproved"

asObject :: Value -> Either Text (KM.KeyMap Value)
asObject (Object value) = Right value
asObject _ = Left "maintenance ingress policy is malformed"

objectField :: Text -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
objectField key root = case KM.lookup (Key.fromText key) root of
  Just (Object value) -> Right value
  _ -> Left ("maintenance ingress policy lacks " <> key)

textField :: Text -> KM.KeyMap Value -> Either Text Text
textField key root = case KM.lookup (Key.fromText key) root of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("maintenance ingress policy lacks " <> key)

kubectlMaintenanceNetworkTransport :: KubernetesRuntimeConfig
  -> MaintenanceNetworkTransport
kubectlMaintenanceNetworkTransport config = MaintenanceNetworkTransport
  readOne listAll createOne deleteOne
  where
    invoke arguments input = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (Left ("cluster guard refused: " <> reason))
        Right () -> do
          result <- try (readProcessWithExitCode "kubectl"
            (["--context", T.unpack (runtimeKubectlContext config),
              "--request-timeout=10s"] <> arguments) input)
          pure $ case result of
            Left (_ :: IOException) -> Left "could not invoke kubectl"
            Right output -> Right output
    readOne namespace name = do
      result <- invoke ["--namespace", T.unpack namespace, "get", "networkpolicy",
        T.unpack name, "-o", "json", "--ignore-not-found"] ""
      pure $ case result of
        Left reason -> Left reason
        Right (ExitFailure _, _, _) -> Left "could not read maintenance ingress policy"
        Right (ExitSuccess, output, _) | null output -> Right Nothing
        Right (ExitSuccess, output, _) ->
          Just <$> first T.pack (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
    listAll namespace = do
      result <- invoke ["--namespace", T.unpack namespace, "get",
        "networkpolicies", "-o", "json"] ""
      pure $ case result of
        Left reason -> Left reason
        Right (ExitFailure _, _, _) -> Left "could not list maintenance namespace policies"
        Right (ExitSuccess, output, _) ->
          first T.pack (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
    createOne value = do
      result <- invoke ["create", "-f", "-"]
        (T.unpack (TE.decodeUtf8 (BL.toStrict (encode value))))
      pure $ case result of
        Left reason -> Left reason
        Right (ExitSuccess, _, _) -> Right ()
        Right (ExitFailure _, _, _) -> Left "could not create maintenance ingress policy"
    deleteOne namespace name uid revision = do
      let path = "/apis/networking.k8s.io/v1/namespaces/" <> namespace
            <> "/networkpolicies/" <> name
          options = object
            [ "apiVersion" .= ("meta.k8s.io/v1" :: Text)
            , "kind" .= ("DeleteOptions" :: Text)
            , "preconditions" .= object
                [ "uid" .= uid, "resourceVersion" .= revision ] ]
      result <- invoke ["delete", "--raw", T.unpack path, "-f", "-"]
        (T.unpack (TE.decodeUtf8 (BL.toStrict (encode options))))
      pure $ case result of
        Left reason -> Left reason
        Right (ExitSuccess, _, _) -> Right ()
        Right (ExitFailure _, _, _) -> Left "conditional maintenance ingress policy deletion failed"
