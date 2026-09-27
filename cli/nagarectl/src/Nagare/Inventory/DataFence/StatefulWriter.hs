-- | Exact, replay-aware StatefulSet replica control for a fenced volume.
-- Scaling to zero is only one component of exclusion: callers must also
-- observe the mount guard, Pods, attachments, and other managed clients.
module Nagare.Inventory.DataFence.StatefulWriter
  ( StatefulWriterPin
  , mkStatefulWriterPin
  , writerNamespace
  , writerName
  , writerUid
  , writerSavedReplicas
  , StatefulWriterTransport (..)
  , kubectlStatefulWriterTransport
  , stopStatefulWriter
  , observeStatefulWriterStopped
  , restoreStatefulWriter
  , observeStatefulWriterRelease
  ) where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict', encode, fromJSON, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.KubernetesRuntime
  (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence (WriterReleaseState (..))
import Nagare.Inventory.DataFence.MountGuard (mkPodOwnerPermit)
import Nagare.Resource.Types (mkName)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data StatefulWriterPin = StatefulWriterPin
  { writerNamespace :: !Text
  , writerName :: !Text
  , writerUid :: !Text
  , writerSavedReplicas :: !Int
  }
  deriving stock (Eq, Show)

mkStatefulWriterPin :: Text -> Text -> Text -> Int
  -> Either Text StatefulWriterPin
mkStatefulWriterPin namespace name uid replicas = do
  _ <- mkName namespace
  _ <- mkPodOwnerPermit "StatefulSet" name uid
    "system:serviceaccount:kube-system:statefulset-controller"
  unless (replicas >= 0) (Left "saved StatefulSet replicas are negative")
  pure (StatefulWriterPin namespace name uid replicas)

data StatefulWriterTransport = StatefulWriterTransport
  { readStatefulWriter :: !(Text -> Text -> IO (Either Text Value))
  , patchStatefulWriter :: !(Text -> Text -> Value -> IO (Either Text ()))
  }

-- | UID and resourceVersion tests make the scale effect conditional at the
-- API server. A lost acknowledgement leaves durable fence recovery to a new
-- observation; it does not authorize blindly repeating the patch.
stopStatefulWriter :: StatefulWriterTransport -> StatefulWriterPin
  -> IO (Either Text ())
stopStatefulWriter transport pin = do
  current <- readStatefulWriter transport (writerNamespace pin) (writerName pin)
  case current >>= observedWriter pin of
    Left reason -> pure (Left reason)
    Right writer
      | observedReplicas writer == 0 -> pure (Right ())
      | observedReplicas writer /= writerSavedReplicas pin ->
          pure (Left "StatefulSet replicas changed since the reviewed writer intent")
      | otherwise -> patchStatefulWriter transport (writerNamespace pin)
          (writerName pin) (replicaPatch pin writer 0)

observeStatefulWriterStopped :: StatefulWriterTransport -> StatefulWriterPin
  -> IO (Either Text Bool)
observeStatefulWriterStopped transport pin = do
  current <- readStatefulWriter transport (writerNamespace pin) (writerName pin)
  pure $ do
    writer <- current >>= observedWriter pin
    pure (observedReplicas writer == 0
      && observedStatusReplicas writer == 0
      && observedReadyReplicas writer == 0
      && observedGeneration writer <= observedStatusGeneration writer)

restoreStatefulWriter :: StatefulWriterTransport -> StatefulWriterPin
  -> IO (Either Text ())
restoreStatefulWriter transport pin = do
  current <- readStatefulWriter transport (writerNamespace pin) (writerName pin)
  case current >>= observedWriter pin of
    Left reason -> pure (Left reason)
    Right writer
      | observedReplicas writer == writerSavedReplicas pin -> pure (Right ())
      | observedReplicas writer /= 0 ->
          pure (Left "StatefulSet replica intent is partially released")
      | otherwise -> do
          stopped <- observeStatefulWriterStopped transport pin
          case stopped of
            Left reason -> pure (Left reason)
            Right False -> pure (Left "StatefulSet has not finished stopping")
            Right True -> patchStatefulWriter transport (writerNamespace pin)
              (writerName pin) (replicaPatch pin writer (writerSavedReplicas pin))

observeStatefulWriterRelease :: StatefulWriterTransport -> StatefulWriterPin
  -> IO (Either Text WriterReleaseState)
observeStatefulWriterRelease transport pin = do
  current <- readStatefulWriter transport (writerNamespace pin) (writerName pin)
  pure $ do
    writer <- current >>= observedWriter pin
    pure $ if observedReplicas writer == writerSavedReplicas pin
        && observedReadyReplicas writer == writerSavedReplicas pin
        && observedStatusReplicas writer == writerSavedReplicas pin
        && observedGeneration writer <= observedStatusGeneration writer
      then WritersFullyReleased
      else if observedReplicas writer == 0
        && observedStatusReplicas writer == 0
        && observedReadyReplicas writer == 0
        && observedGeneration writer <= observedStatusGeneration writer
      then WritersStillExcluded
      else WritersPartlyReleased

data ObservedWriter = ObservedWriter
  { observedRevision :: !Text
  , observedGeneration :: !Integer
  , observedStatusGeneration :: !Integer
  , observedReplicas :: !Int
  , observedStatusReplicas :: !Int
  , observedReadyReplicas :: !Int
  }

observedWriter :: StatefulWriterPin -> Value -> Either Text ObservedWriter
observedWriter pin (Object root) = do
  metadata <- jsonObject "metadata" root
  unless (jsonText "namespace" metadata == Right (writerNamespace pin)
      && jsonText "name" metadata == Right (writerName pin)
      && jsonText "uid" metadata == Right (writerUid pin))
    (Left "StatefulSet identity changed")
  revision <- jsonText "resourceVersion" metadata
  generation <- jsonInteger "generation" metadata
  spec <- jsonObject "spec" root
  replicas <- jsonInt "replicas" spec
  status <- jsonObject "status" root
  statusGeneration <- jsonInteger "observedGeneration" status
  statusReplicas <- jsonOptionalInt "replicas" status
  readyReplicas <- jsonOptionalInt "readyReplicas" status
  pure (ObservedWriter revision generation statusGeneration replicas
    statusReplicas readyReplicas)
observedWriter _ _ = Left "StatefulSet observation is not an object"

replicaPatch :: StatefulWriterPin -> ObservedWriter -> Int -> Value
replicaPatch pin observed replicas = toJSON
  [ object ["op" .= ("test" :: Text), "path" .= ("/metadata/uid" :: Text),
      "value" .= writerUid pin]
  , object ["op" .= ("test" :: Text), "path" .= ("/metadata/resourceVersion" :: Text),
      "value" .= observedRevision observed]
  , object ["op" .= ("test" :: Text), "path" .= ("/spec/replicas" :: Text),
      "value" .= observedReplicas observed]
  , object ["op" .= ("replace" :: Text), "path" .= ("/spec/replicas" :: Text),
      "value" .= replicas]
  ]

jsonObject :: Text -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
jsonObject field root = case KM.lookup (Key.fromText field) root of
  Just (Object value) -> Right value
  _ -> Left ("StatefulSet observation lacks " <> field)

jsonText :: Text -> KM.KeyMap Value -> Either Text Text
jsonText field root = case KM.lookup (Key.fromText field) root of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("StatefulSet observation lacks " <> field)

jsonInteger :: Text -> KM.KeyMap Value -> Either Text Integer
jsonInteger field root = case KM.lookup (Key.fromText field) root of
  Just value | Success number <- (fromJSON value :: Result Int)
    , number >= 0 -> Right (toInteger number)
  _ -> Left ("StatefulSet observation lacks " <> field)

jsonInt :: Text -> KM.KeyMap Value -> Either Text Int
jsonInt field root = do
  number <- jsonInteger field root
  if number <= toInteger (maxBound :: Int)
    then Right (fromInteger number)
    else Left ("StatefulSet " <> field <> " exceeds Int")

jsonOptionalInt :: Text -> KM.KeyMap Value -> Either Text Int
jsonOptionalInt field root = case KM.lookup (Key.fromText field) root of
  Nothing -> Right 0
  Just _ -> jsonInt field root

kubectlStatefulWriterTransport :: KubernetesRuntimeConfig
  -> StatefulWriterTransport
kubectlStatefulWriterTransport config = StatefulWriterTransport readOne patchOne
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
      result <- invoke ["--namespace", T.unpack namespace, "get", "statefulset",
        T.unpack name, "-o", "json"] ""
      pure $ case result of
        Left reason -> Left reason
        Right (ExitFailure _, _, _) -> Left "could not read fenced StatefulSet"
        Right (ExitSuccess, output, _) -> first T.pack
          (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
    patchOne namespace name patch = do
      result <- invoke ["--namespace", T.unpack namespace, "patch", "statefulset",
        T.unpack name, "--type=json", "-p",
        T.unpack (TE.decodeUtf8 (BL.toStrict (encode patch)))] ""
      pure $ case result of
        Left reason -> Left reason
        Right (ExitFailure _, _, _) -> Left "conditional StatefulSet replica patch failed"
        Right (ExitSuccess, _, _) -> Right ()
