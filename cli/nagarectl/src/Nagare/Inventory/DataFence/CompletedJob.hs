-- | A completed, exact-UID Job is an inert historical PVC writer. Admission
-- still checks its spec and terminal Pods; the mount guard prevents a new Pod
-- from acquiring the fenced claim while the database remains online.
module Nagare.Inventory.DataFence.CompletedJob
  ( CompletedJobPin (..)
  , CompletedJobTransport (..)
  , kubectlCompletedJobTransport
  , captureCompletedJob
  , observeCompletedJob
  )
where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict', fromJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (..)
  )
import Nagare.Inventory.DataFence.MountGuard (validUid)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types (ContentDigest)
import Nagare.Resource.Wire (canonicalValue)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data CompletedJobPin = CompletedJobPin
  { completedJobNamespace :: !Text
  , completedJobName :: !Text
  , completedJobUid :: !Text
  , completedJobSpecDigest :: !ContentDigest
  }
  deriving stock (Eq, Show)

data CompletedJobTransport = CompletedJobTransport
  { readCompletedJob :: !(Text -> Text -> IO (Either Text Value))
  , listCompletedJobPods :: !(Text -> IO (Either Text Value))
  }

kubectlCompletedJobTransport :: KubernetesRuntimeConfig -> CompletedJobTransport
kubectlCompletedJobTransport config = CompletedJobTransport readJob listPods
  where
    readJob namespace name =
      invoke
        namespace
        [ "get"
        , "job"
        , T.unpack name
        , "-o"
        , "json"
        ]
    listPods namespace = invoke namespace ["get", "pods", "-o", "json"]
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
                    , "--request-timeout=10s"
                    , "--namespace"
                    , T.unpack namespace
                    ]
                      <> arguments
                  )
                  ""
              )
          pure $ case result of
            Left (_ :: IOException) -> Left "could not observe completed Job"
            Right (ExitSuccess, output, _) ->
              first T.pack (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
            Right _ -> Left "completed Job observation failed"

captureCompletedJob ::
  CompletedJobTransport ->
  Text ->
  Text ->
  IO (Either Text CompletedJobPin)
captureCompletedJob transport namespace name = do
  job <- readCompletedJob transport namespace name
  pods <- listCompletedJobPods transport namespace
  pure $ do
    value <- job
    pin <- parseJob namespace name value
    requireComplete value
    _ <- requireTerminalPods pin =<< pods
    pure pin

observeCompletedJob ::
  CompletedJobTransport ->
  CompletedJobPin ->
  IO (Either Text [Text])
observeCompletedJob transport pin = do
  job <- readCompletedJob transport (completedJobNamespace pin) (completedJobName pin)
  pods <- listCompletedJobPods transport (completedJobNamespace pin)
  pure $ do
    value <- job
    current <- parseJob (completedJobNamespace pin) (completedJobName pin) value
    unless
      (current == pin)
      (Left "completed Job UID or spec changed after review")
    requireComplete value
    requireTerminalPods pin =<< pods

parseJob :: Text -> Text -> Value -> Either Text CompletedJobPin
parseJob namespace name value = do
  root <- object "completed Job" value
  metadata <- fieldObject "metadata" root
  observedName <- fieldText "name" metadata
  observedNamespace <- fieldText "namespace" metadata
  uid <- fieldText "uid" metadata
  unless
    (observedName == name && observedNamespace == namespace && validUid uid)
    (Left "completed Job name, namespace, or UID changed")
  unless
    (KM.lookup "deletionTimestamp" metadata == Nothing)
    (Left "completed Job is terminating")
  spec <- fieldObject "spec" root
  bytes <- canonicalValue (Object spec)
  pure (CompletedJobPin namespace name uid (contentDigest bytes))

requireComplete :: Value -> Either Text ()
requireComplete value = do
  root <- object "completed Job" value
  status <- fieldObject "status" root
  let active = case KM.lookup "active" status of
        Nothing -> Just 0
        Just (Number number) -> intValue number
        _ -> Nothing
      succeeded = case KM.lookup "succeeded" status of
        Just (Number number) -> intValue number
        _ -> Nothing
      complete = case KM.lookup "conditions" status of
        Just (Array conditions) -> any isComplete (V.toList conditions)
        _ -> False
  unless
    ( active == Just (0 :: Int)
        && maybe False (> (0 :: Int)) succeeded
        && complete
    )
    (Left "accepted Job is not completed and inactive")
  where
    isComplete (Object condition) =
      KM.lookup "type" condition == Just (String "Complete")
        && KM.lookup "status" condition == Just (String "True")
    isComplete _ = False
    intValue number = case fromJSON (Number number) of
      Success count -> Just (count :: Int)
      Error _ -> Nothing

requireTerminalPods :: CompletedJobPin -> Value -> Either Text [Text]
requireTerminalPods pin listing = do
  root <- object "Job Pod list" listing
  items <- case KM.lookup "items" root of
    Just (Array values) -> Right (V.toList values)
    _ -> Left "completed Job Pod list is malformed"
  sort . concat <$> traverse one items
  where
    one item = do
      pod <- object "Job Pod" item
      metadata <- fieldObject "metadata" pod
      namespace <- fieldText "namespace" metadata
      unless
        (namespace == completedJobNamespace pin)
        (Left "Job Pod list includes another namespace")
      owners <- case KM.lookup "ownerReferences" metadata of
        Nothing -> Right []
        Just (Array values) -> Right (V.toList values)
        _ -> Left "Job Pod ownership is malformed"
      let owned = any ownedByPin owners
      if not owned
        then pure []
        else do
          podName <- fieldText "name" metadata
          podUid <- fieldText "uid" metadata
          unless
            (validUid podUid)
            (Left "completed Job Pod UID is malformed")
          status <- fieldObject "status" pod
          phase <- fieldText "phase" status
          unless
            (phase `elem` ["Succeeded", "Failed"])
            (Left "accepted completed Job still has an active or unknown Pod")
          pure [podName <> "/" <> podUid]
    ownedByPin (Object owner) =
      KM.lookup "kind" owner == Just (String "Job")
        && KM.lookup "name" owner == Just (String (completedJobName pin))
        && KM.lookup "uid" owner == Just (String (completedJobUid pin))
        && KM.lookup "controller" owner == Just (Bool True)
    ownedByPin _ = False

object :: Text -> Value -> Either Text (KM.KeyMap Value)
object _ (Object value) = Right value
object label _ = Left (label <> " is malformed")

fieldObject :: Text -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
fieldObject key root = case KM.lookup (Key.fromText key) root of
  Just (Object value) -> Right value
  _ -> Left ("completed Job lacks " <> key)

fieldText :: Text -> KM.KeyMap Value -> Either Text Text
fieldText key root = case KM.lookup (Key.fromText key) root of
  Just (String value) -> Right value
  _ -> Left ("completed Job lacks " <> key)
