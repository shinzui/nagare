-- | Request an engine-native shutdown of the one reviewed database server
-- before scaling its StatefulSet. The request is not exclusion proof: a lost
-- acknowledgement, a container restart, or a forced Pod deletion can only be
-- resolved by the separate guarded no-Pod/no-route observation.
module Nagare.Inventory.DataFence.DatabaseShutdown
  ( DatabaseShutdownTransport (..)
  , kubectlDatabaseShutdownTransport
  , observeDatabasePod
  , requestDatabaseShutdown
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict', fromJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Dsl.Database (Engine (..), engineToken)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (..)
  )
import Nagare.Inventory.DataFence.MountGuard (validUid)
import Nagare.Inventory.DataFence.StatefulWriter
  ( StatefulWriterPin
  , writerName
  , writerNamespace
  , writerSavedReplicas
  , writerUid
  )
import Nagare.Inventory.DataFence.VolumeState
  ( VolumeTransport (..)
  )
import Nagare.Inventory.KubernetesTransport (runtimePause)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data DatabaseShutdownTransport = DatabaseShutdownTransport
  { sendDatabaseShutdown ::
      !( Text ->
         Text ->
         Text ->
         Engine ->
         Text ->
         IO (Either Text ())
       )
  }

-- | Find the one running Pod owned by the exact reviewed StatefulSet and
-- carrying its accepted engine image. Maintenance retains this Pod instead
-- of shutting it down, and must recheck the UID at every fence transition.
observeDatabasePod ::
  VolumeTransport ->
  StatefulWriterPin ->
  Engine ->
  Text ->
  IO (Either Text (Text, Text))
observeDatabasePod volume pin engine acceptedImage = do
  listing <- listNamespacePods volume (writerNamespace pin)
  pure $ do
    pods <- listing
    selected <- databasePod pin engine acceptedImage pods
    maybe
      (Left "reviewed database Pod is absent, terminating, or not running")
      Right
      selected

-- | Only an exact, running, owned server Pod receives a shutdown request.
-- A previously removed Pod is safe to skip on acquisition resume; the
-- StatefulSet still has to converge to zero before exclusion can be proved.
requestDatabaseShutdown ::
  VolumeTransport ->
  DatabaseShutdownTransport ->
  StatefulWriterPin ->
  Engine ->
  Text ->
  IO (Either Text ())
requestDatabaseShutdown volume transport pin engine acceptedImage = do
  listing <- listNamespacePods volume (writerNamespace pin)
  case listing >>= databasePod pin engine acceptedImage of
    Left reason -> pure (Left reason)
    Right Nothing -> pure (Right ())
    Right (Just (pod, uid)) ->
      sendDatabaseShutdown
        transport
        (writerNamespace pin)
        pod
        uid
        engine
        acceptedImage

databasePod ::
  StatefulWriterPin ->
  Engine ->
  Text ->
  Value ->
  Either Text (Maybe (Text, Text))
databasePod pin engine acceptedImage listing = do
  root <- asObject "PodList" listing
  items <- arrayField "items" root
  owned <- fmap concat $ forM items $ \item -> do
    pod <- asObject "Pod" item
    metadata <- objectField "metadata" pod
    namespace <- textField "namespace" metadata
    unless
      (namespace == writerNamespace pin)
      (Left "database Pod list contains another namespace")
    owners <- optionalArrayField "ownerReferences" metadata
    let owned = any (ownedBy pin) owners
    if not owned
      then pure []
      else do
        name <- textField "name" metadata
        uid <- textField "uid" metadata
        unless
          (validUid uid && (writerName pin <> "-") `T.isPrefixOf` name)
          (Left "reviewed database Pod identity is malformed")
        spec <- objectField "spec" pod
        containers <- arrayField "containers" spec
        case containers of
          [containerValue] -> do
            container <- asObject "database server container" containerValue
            unless
              ( textField "name" container == Right (engineToken engine)
                  && textField "image" container == Right acceptedImage
              )
              (Left "database Pod server image differs from accepted StatefulSet")
          _ -> Left "reviewed database Pod has multiple server containers"
        status <- objectField "status" pod
        phase <- textField "phase" status
        running <- case phase of
          "Pending" -> Right False
          "Running" -> serverRunning engine status
          "Succeeded" -> Right False
          "Failed" -> Right False
          _ -> Left "reviewed database Pod has an unknown phase"
        let terminating = case KM.lookup "deletionTimestamp" metadata of
              Just (String _) -> True
              _ -> False
        pure [(name, uid, running && not terminating)]
  unless
    (writerSavedReplicas pin <= 1 && length owned <= 1)
    (Left "reviewed database has multiple server Pods or replicas")
  pure $ case owned of
    [(name, uid, True)] -> Just (name, uid)
    _ -> Nothing

ownedBy :: StatefulWriterPin -> Value -> Bool
ownedBy pin (Object owner) =
  KM.lookup "kind" owner == Just (String "StatefulSet")
    && KM.lookup "name" owner == Just (String (writerName pin))
    && KM.lookup "uid" owner == Just (String (writerUid pin))
    && KM.lookup "controller" owner == Just (Bool True)
ownedBy _ _ = False

serverRunning :: Engine -> KM.KeyMap Value -> Either Text Bool
serverRunning engine status = do
  containers <- arrayField "containerStatuses" status
  case containers of
    [containerValue] -> do
      container <- asObject "database container status" containerValue
      unless
        (textField "name" container == Right (engineToken engine))
        (Left "database server container status changed")
      state <- objectField "state" container
      pure (KM.member "running" state)
    _ -> Left "database server container status is ambiguous"

asObject :: Text -> Value -> Either Text (KM.KeyMap Value)
asObject _ (Object value) = Right value
asObject label _ = Left (label <> " is not an object")

objectField :: Text -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
objectField key root = case KM.lookup (Key.fromText key) root of
  Just (Object value) -> Right value
  _ -> Left ("database Pod evidence lacks " <> key)

textField :: Text -> KM.KeyMap Value -> Either Text Text
textField key root = case KM.lookup (Key.fromText key) root of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("database Pod evidence lacks " <> key)

arrayField :: Text -> KM.KeyMap Value -> Either Text [Value]
arrayField key root = case KM.lookup (Key.fromText key) root of
  Just (Array values) -> Right (V.toList values)
  _ -> Left ("database Pod evidence lacks " <> key)

optionalArrayField :: Text -> KM.KeyMap Value -> Either Text [Value]
optionalArrayField key root = case KM.lookup (Key.fromText key) root of
  Nothing -> Right []
  Just _ -> arrayField key root

kubectlDatabaseShutdownTransport ::
  KubernetesRuntimeConfig ->
  DatabaseShutdownTransport
kubectlDatabaseShutdownTransport config = DatabaseShutdownTransport send
  where
    send namespace pod uid engine acceptedImage = do
      before <- readServer namespace pod uid engine acceptedImage
      case before of
        Left reason -> pure (Left reason)
        Right start -> do
          invoked <-
            invoke
              namespace
              [ "exec"
              , T.unpack pod
              , "--container"
              , T.unpack (engineToken engine)
              , "--"
              , "sh"
              , "-c"
              , T.unpack (shutdownScript engine)
              ]
          case invoked of
            Left reason -> pure (Left reason)
            Right _ ->
              awaitExit
                namespace
                pod
                uid
                engine
                acceptedImage
                (serverContainerId start)
                40

    readServer namespace pod uid engine acceptedImage = do
      result <- invoke namespace ["get", "pod", T.unpack pod, "-o", "json"]
      pure $ do
        output <- result
        case output of
          (ExitFailure _, _, _) -> Left "could not read exact database server Pod"
          (ExitSuccess, body, _) -> do
            value <- first T.pack (eitherDecodeStrict' (TE.encodeUtf8 (T.pack body)))
            parseServerStatus pod uid engine acceptedImage value

    awaitExit ::
      Text ->
      Text ->
      Text ->
      Engine ->
      Text ->
      Text ->
      Int ->
      IO (Either Text ())
    awaitExit namespace pod uid engine acceptedImage initial remaining = do
      observed <- readServer namespace pod uid engine acceptedImage
      case observed of
        Right status
          | serverExitedId status == Just initial
              && serverLastExit status == Just 0 ->
              pure (Right ())
        Left reason | remaining <= 0 -> pure (Left reason)
        _
          | remaining <= 0 ->
              pure (Left "engine-native database shutdown did not finish cleanly")
        _ -> do
          runtimePause config 250000
          awaitExit namespace pod uid engine acceptedImage initial (remaining - 1)

    invoke namespace arguments = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (Left ("cluster guard refused: " <> reason))
        Right () -> do
          result <-
            try
              ( readProcessWithExitCode
                  "kubectl"
                  ( [ "--context"
                    , T.unpack (runtimeKubectlContext config)
                    , "--request-timeout=90s"
                    , "--namespace"
                    , T.unpack namespace
                    ]
                      <> arguments
                  )
                  ""
              )
          pure $ case result of
            Left (_ :: IOException) -> Left "could not invoke database shutdown kubectl"
            Right output -> Right output

data ServerStatus = ServerStatus
  { serverContainerId :: !Text
  , serverExitedId :: !(Maybe Text)
  , serverLastExit :: !(Maybe Int)
  }

parseServerStatus ::
  Text ->
  Text ->
  Engine ->
  Text ->
  Value ->
  Either Text ServerStatus
parseServerStatus name uid engine acceptedImage value = do
  root <- asObject "database Pod" value
  metadata <- objectField "metadata" root
  unless
    ( textField "name" metadata == Right name
        && textField "uid" metadata == Right uid
    )
    (Left "database server Pod was replaced during shutdown")
  spec <- objectField "spec" root
  serverContainers <- arrayField "containers" spec
  case serverContainers of
    [serverValue] -> do
      server <- asObject "database server container" serverValue
      unless
        ( textField "name" server == Right (engineToken engine)
            && textField "image" server == Right acceptedImage
        )
        (Left "database server Pod image changed during shutdown")
    _ -> Left "database server Pod containers changed during shutdown"
  status <- objectField "status" root
  containers <- arrayField "containerStatuses" status
  case containers of
    [containerValue] -> do
      container <- asObject "database server status" containerValue
      unless
        (textField "name" container == Right (engineToken engine))
        (Left "database server container changed during shutdown")
      containerId <- textField "containerID" container
      state <- objectField "state" container
      let termination = case KM.lookup "terminated" state of
            Just (Object finished) -> Just finished
            _ -> case KM.lookup "lastState" container of
              Just (Object lastState) -> case KM.lookup "terminated" lastState of
                Just (Object finished) -> Just finished
                _ -> Nothing
              _ -> Nothing
      exited <- traverse (textField "containerID") termination
      exitCode <- traverse (intField "exitCode") termination
      pure (ServerStatus containerId exited exitCode)
    _ -> Left "database server container status is ambiguous"

intField :: Text -> KM.KeyMap Value -> Either Text Int
intField key root = case KM.lookup (Key.fromText key) root of
  Just raw
    | Success number <- (fromJSON raw :: Result Int)
    , number >= 0 ->
        Right number
  _ -> Left ("database server status lacks " <> key)

shutdownScript :: Engine -> Text
shutdownScript Postgres =
  "gosu postgres pg_ctl -D \"$PGDATA\" -m fast -w -t 60 stop"
shutdownScript Redis =
  "REDISCLI_AUTH=\"$REDIS_PASSWORD\" redis-cli --no-auth-warning SHUTDOWN SAVE"
shutdownScript ClickHouse =
  "clickhouse-client --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\" --query 'SYSTEM SHUTDOWN'"
