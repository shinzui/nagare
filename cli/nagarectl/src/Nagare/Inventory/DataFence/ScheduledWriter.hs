-- | Conditional suspension and drain observation for a reviewed CronJob.
-- Suspending a schedule does not stop Jobs it already started. The caller
-- must install its admission guard before this control is an exclusion proof.
module Nagare.Inventory.DataFence.ScheduledWriter
  ( ScheduledWriterPin
  , mkScheduledWriterPin
  , scheduleNamespace
  , scheduleName
  , scheduleUid
  , scheduleSavedSuspend
  , ScheduledWriterTransport (..)
  , kubectlScheduledWriterTransport
  , stopScheduledWriter
  , observeScheduledWriterIdentity
  , observeScheduledWriterStopped
  , restoreScheduledWriter
  , observeScheduledWriterRelease
  , parseScheduledWriterDrain
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict', encode, fromJSON, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.KubernetesRuntime
  (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence (WriterReleaseState (..))
import Nagare.Inventory.DataFence.MountGuard (validUid)
import Nagare.Resource.Types (mkName)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data ScheduledWriterPin = ScheduledWriterPin
  { scheduleNamespace :: !Text
  , scheduleName :: !Text
  , scheduleUid :: !Text
  , scheduleSavedSuspend :: !(Maybe Bool)
  }
  deriving stock (Eq, Show)

mkScheduledWriterPin :: Text -> Text -> Text -> Maybe Bool
  -> Either Text ScheduledWriterPin
mkScheduledWriterPin namespace name uid saved = do
  _ <- mkName namespace
  _ <- mkName name
  unless (validUid uid) (Left "fenced CronJob UID is not a Kubernetes UUID")
  pure (ScheduledWriterPin namespace name uid saved)

data ScheduledWriterTransport = ScheduledWriterTransport
  { readScheduledWriter :: !(Text -> Text -> IO (Either Text Value))
  , patchScheduledWriter :: !(Text -> Text -> Value -> IO (Either Text ()))
  , listScheduledJobs :: !(Text -> IO (Either Text Value))
  , listScheduledPods :: !(Text -> IO (Either Text Value))
  }

data ObservedSchedule = ObservedSchedule
  { observedRevision :: !Text
  , observedSuspend :: !(Maybe Bool)
  , observedActiveReferences :: !Int
  }

stopScheduledWriter :: ScheduledWriterTransport -> ScheduledWriterPin
  -> IO (Either Text ())
stopScheduledWriter transport pin = do
  current <- readScheduledWriter transport (scheduleNamespace pin) (scheduleName pin)
  case current >>= parseSchedule pin of
    Left reason -> pure (Left reason)
    Right observed
      | observedSuspend observed == Just True -> pure (Right ())
      | observedSuspend observed /= scheduleSavedSuspend pin ->
          pure (Left "CronJob suspension changed since reviewed writer intent")
      | otherwise -> patchScheduledWriter transport
          (scheduleNamespace pin) (scheduleName pin)
          (suspendPatch pin observed (Just True))

observeScheduledWriterIdentity :: ScheduledWriterTransport -> ScheduledWriterPin
  -> IO (Either Text ())
observeScheduledWriterIdentity transport pin = do
  current <- readScheduledWriter transport (scheduleNamespace pin) (scheduleName pin)
  pure (() <$ (current >>= parseSchedule pin))

observeScheduledWriterStopped :: ScheduledWriterTransport -> ScheduledWriterPin
  -> IO (Either Text Bool)
observeScheduledWriterStopped transport pin = do
  current <- readScheduledWriter transport (scheduleNamespace pin) (scheduleName pin)
  jobs <- listScheduledJobs transport (scheduleNamespace pin)
  pods <- listScheduledPods transport (scheduleNamespace pin)
  pure $ do
    observed <- current >>= parseSchedule pin
    jobValues <- jobs
    podValues <- pods
    drained <- parseScheduledWriterDrain pin jobValues podValues
    pure (observedSuspend observed == Just True
      && observedActiveReferences observed == 0 && drained)

restoreScheduledWriter :: ScheduledWriterTransport -> ScheduledWriterPin
  -> IO (Either Text ())
restoreScheduledWriter transport pin = do
  current <- readScheduledWriter transport (scheduleNamespace pin) (scheduleName pin)
  case current >>= parseSchedule pin of
    Left reason -> pure (Left reason)
    Right observed
      | observedSuspend observed == scheduleSavedSuspend pin -> pure (Right ())
      | observedSuspend observed /= Just True ->
          pure (Left "CronJob suspension is partially released")
      | otherwise -> do
          stopped <- observeScheduledWriterStopped transport pin
          case stopped of
            Left reason -> pure (Left reason)
            Right False -> pure (Left "CronJob Jobs have not drained")
            Right True -> patchScheduledWriter transport
              (scheduleNamespace pin) (scheduleName pin)
              (suspendPatch pin observed (scheduleSavedSuspend pin))

observeScheduledWriterRelease :: ScheduledWriterTransport -> ScheduledWriterPin
  -> IO (Either Text WriterReleaseState)
observeScheduledWriterRelease transport pin = do
  current <- readScheduledWriter transport (scheduleNamespace pin) (scheduleName pin)
  jobs <- listScheduledJobs transport (scheduleNamespace pin)
  pods <- listScheduledPods transport (scheduleNamespace pin)
  pure $ do
    observed <- current >>= parseSchedule pin
    jobValues <- jobs
    podValues <- pods
    drained <- parseScheduledWriterDrain pin jobValues podValues
    let quiet = observedActiveReferences observed == 0 && drained
    pure $ if observedSuspend observed == scheduleSavedSuspend pin
        && (scheduleSavedSuspend pin /= Just True || quiet)
      then WritersFullyReleased
      else if observedSuspend observed == Just True && quiet
      then WritersStillExcluded
      else WritersPartlyReleased

parseSchedule :: ScheduledWriterPin -> Value -> Either Text ObservedSchedule
parseSchedule pin (Object root) = do
  meta <- objectField "metadata" root
  unless (textField "namespace" meta == Right (scheduleNamespace pin)
      && textField "name" meta == Right (scheduleName pin)
      && textField "uid" meta == Right (scheduleUid pin))
    (Left "CronJob identity changed")
  revision <- textField "resourceVersion" meta
  spec <- objectField "spec" root
  suspend <- case KM.lookup "suspend" spec of
    Nothing -> Right Nothing
    Just (Bool value) -> Right (Just value)
    _ -> Left "CronJob suspend is malformed"
  active <- case KM.lookup "status" root of
    Nothing -> Right []
    Just (Object status) -> optionalArrayField "active" status
    _ -> Left "CronJob status is malformed"
  pure (ObservedSchedule revision suspend (length active))
parseSchedule _ _ = Left "CronJob observation is not an object"

suspendPatch :: ScheduledWriterPin -> ObservedSchedule -> Maybe Bool -> Value
suspendPatch pin observed desired = toJSON
  ([ object ["op" .= ("test" :: Text), "path" .= ("/metadata/uid" :: Text),
       "value" .= scheduleUid pin]
   , object ["op" .= ("test" :: Text),
       "path" .= ("/metadata/resourceVersion" :: Text),
       "value" .= observedRevision observed]
   ] <> case desired of
      Nothing -> [object ["op" .= ("remove" :: Text),
        "path" .= ("/spec/suspend" :: Text)]]
      Just value -> [object ["op" .= ("add" :: Text),
        "path" .= ("/spec/suspend" :: Text), "value" .= value]])

-- | Count every active Job owned by the pinned CronJob. A Job may disappear
-- before its Pods do, so Pods owned by a Job with the CronJob's generated
-- name prefix are counted independently until their phase is terminal.
parseScheduledWriterDrain :: ScheduledWriterPin -> Value -> Value
  -> Either Text Bool
parseScheduledWriterDrain pin jobs pods = do
  jobItems <- listItems "JobList" jobs
  owned <- forM jobItems $ \item -> do
    root <- asObject "Job" item
    meta <- objectField "metadata" root
    unless (textField "namespace" meta == Right (scheduleNamespace pin))
      (Left "Job list contains another namespace")
    refs <- optionalArrayField "ownerReferences" meta
    let belongs = any (ownedBy "CronJob" (scheduleName pin) (scheduleUid pin)) refs
    if not belongs then pure Nothing else do
      name <- textField "name" meta
      uid <- textField "uid" meta
      status <- case KM.lookup "status" root of
        Nothing -> Right KM.empty
        Just (Object value) -> Right value
        _ -> Left "CronJob Job status is malformed"
      active <- optionalNonnegativeInt "active" status
      pure (Just (name, uid, active))
  podItems <- listItems "PodList" pods
  activePods <- forM podItems $ \item -> do
    root <- asObject "Pod" item
    meta <- objectField "metadata" root
    unless (textField "namespace" meta == Right (scheduleNamespace pin))
      (Left "Pod list contains another namespace")
    refs <- optionalArrayField "ownerReferences" meta
    let ownedJobs = [(name, uid) | Just (name, uid, _) <- owned]
        belongs ref = any (\(name, uid) -> ownedBy "Job" name uid ref) ownedJobs
          || case ref of
            Object fields -> case (KM.lookup "kind" fields, KM.lookup "name" fields) of
              (Just (String "Job"), Just (String name)) ->
                (scheduleName pin <> "-") `T.isPrefixOf` name
              _ -> False
            _ -> False
    if not (any belongs refs) then pure False else do
      status <- case KM.lookup "status" root of
        Nothing -> Right KM.empty
        Just (Object value) -> Right value
        _ -> Left "CronJob Pod status is malformed"
      pure (KM.lookup "phase" status `notElem`
        [Just (String "Succeeded"), Just (String "Failed")])
  pure (all (maybe True (\(_, _, active) -> active == 0)) owned
    && not (or activePods))

ownedBy :: Text -> Text -> Text -> Value -> Bool
ownedBy kind name uid (Object fields) =
  KM.lookup "kind" fields == Just (String kind)
    && KM.lookup "name" fields == Just (String name)
    && KM.lookup "uid" fields == Just (String uid)
    && KM.lookup "controller" fields == Just (Bool True)
ownedBy _ _ _ _ = False

listItems :: Text -> Value -> Either Text [Value]
listItems label value = do
  root <- asObject label value
  arrayField "items" root

asObject :: Text -> Value -> Either Text (KM.KeyMap Value)
asObject _ (Object root) = Right root
asObject label _ = Left (label <> " is not an object")

objectField :: Text -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
objectField key root = case KM.lookup (Key.fromText key) root of
  Just (Object value) -> Right value
  _ -> Left ("CronJob observation lacks " <> key)

textField :: Text -> KM.KeyMap Value -> Either Text Text
textField key root = case KM.lookup (Key.fromText key) root of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("CronJob observation lacks " <> key)

arrayField :: Text -> KM.KeyMap Value -> Either Text [Value]
arrayField key root = case KM.lookup (Key.fromText key) root of
  Just (Array values) -> Right (V.toList values)
  _ -> Left ("CronJob observation lacks " <> key)

optionalArrayField :: Text -> KM.KeyMap Value -> Either Text [Value]
optionalArrayField key root = case KM.lookup (Key.fromText key) root of
  Nothing -> Right []
  Just Null -> Right []
  Just _ -> arrayField key root

optionalNonnegativeInt :: Text -> KM.KeyMap Value -> Either Text Int
optionalNonnegativeInt key root = case KM.lookup (Key.fromText key) root of
  Nothing -> Right 0
  Just Null -> Right 0
  Just number | Success value <- (fromJSON number :: Result Int),
    value >= 0 -> Right value
  _ -> Left ("CronJob observation has malformed " <> key)

kubectlScheduledWriterTransport :: KubernetesRuntimeConfig
  -> ScheduledWriterTransport
kubectlScheduledWriterTransport config = ScheduledWriterTransport readOne patchOne
  listJobs listPods
  where
    readOne namespace name = readJson ["--namespace", T.unpack namespace,
      "get", "cronjob", T.unpack name, "-o", "json"]
    listJobs namespace = readJson ["--namespace", T.unpack namespace,
      "get", "jobs", "-o", "json"]
    listPods namespace = readJson ["--namespace", T.unpack namespace,
      "get", "pods", "-o", "json"]
    readJson arguments = do
      result <- invoke arguments
      pure (result >>= first T.pack . eitherDecodeStrict' . TE.encodeUtf8)
    patchOne namespace name patch = do
      result <- invoke ["--namespace", T.unpack namespace, "patch", "cronjob",
        T.unpack name, "--type=json", "-p",
        T.unpack (TE.decodeUtf8 (BL.toStrict (encode patch)))]
      pure (() <$ result)
    invoke arguments = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (Left ("cluster guard refused: " <> reason))
        Right () -> do
          attempted <- try (readProcessWithExitCode "kubectl"
            (["--context", T.unpack (runtimeKubectlContext config),
              "--request-timeout=10s"] <> arguments) "")
          pure $ case attempted of
            Left (_ :: IOException) -> Left "could not invoke kubectl"
            Right (ExitFailure _, _, _) -> Left "could not observe or patch fenced CronJob"
            Right (ExitSuccess, output, _) -> Right (T.pack output)
