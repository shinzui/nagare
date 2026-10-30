-- | One phase's grouped reads of the cluster: an observation epoch (EP-185,
-- EP-226 M2). Observation and the readiness probe read each object with its
-- own @kubectl get@; an epoch reads the phase's objects once, one @kubectl
-- get@ per cluster, kind, namespace and chunk of names, and answers those
-- single-object reads from it. Every other request goes to the cluster.
--
-- An epoch is evidence gathered over one interval, not an atomic snapshot,
-- and never sees the writes made after it. It serves read-only phases only:
-- a status run, or a plan's observation and preparation. It is keyed by the
-- command session's identity generation: once that changes, every read goes
-- to the cluster again.
--
-- A grouped read that fails is retried once and then answers each of its
-- members as unavailable; it never fans out into one read per member. An
-- answer of a shape the epoch does not recognize proves nothing: at most
-- 'fallbackBudget' of its members are then read one by one, and the rest are
-- unavailable. An absent member is absent only when a well-formed answer omits
-- it; an unknown kind fails every member as it fails one.
module Nagare.Inventory.KubernetesSnapshot
  ( ObservationEpoch
  , openObservationEpoch
  , epochRuntime
  , snapshotRuntime
  , PhaseEpoch
  , newPhaseEpoch
  , beginPhase
  , phaseRuntime
  , snapshotAnswers
  , snapshotReads
  , chunkLimit
  , chunkBytes
  , fallbackBudget
  )
where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_)
import Data.Aeson (Value (..), eitherDecodeStrict', encode)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (mapAccumL)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Contract.Trace (CountCategory (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesRuntime (objectReadArguments)
import Nagare.Inventory.ClusterSession (commandSessionGeneration)
import Nagare.Inventory.KubernetesTransport (KubectlRequest, KubectlResult, KubernetesRuntimeConfig (runtimeKubectlContext), dispatchKubectl, invokeKubectl, kubectlPurpose, runKubectlWith, withKubectlInterpreter)
import Nagare.Inventory.Store.Counters (traceCount)
import Nagare.Resource.Types (Name, ProviderAddress (..), ResourceId, nameText)
import System.Exit (ExitCode (..))
import System.IO.Unsafe (unsafePerformIO)

-- | At most this many names in one grouped read.
chunkLimit :: Int
chunkLimit = 128

-- | At most this many bytes of names in one grouped read's arguments.
chunkBytes :: Int
chunkBytes = 32 * 1024

-- | At most this many single reads stand in for unrecognized answers, per epoch.
fallbackBudget :: Int
fallbackBudget = 8

-- | The single-object reads an epoch answers, under the session generation
-- it was gathered in.
data ObservationEpoch = ObservationEpoch
  { generation :: !(Maybe Int)
  , answers :: !(Map [String] KubectlResult)
  }
  deriving stock (Generic)

-- | Gather a phase's reads of these addresses, within the process's read
-- limit. Addresses of more than one cluster are refused, each unavailable.
openObservationEpoch :: KubernetesRuntimeConfig -> [ProviderAddress] -> IO ObservationEpoch
openObservationEpoch config addresses = do
  generation' <- commandSessionGeneration (runtimeKubectlContext config)
  case Set.toList (Set.fromList [cluster | Kubernetes cluster _ _ _ _ <- addresses]) of
    _ : _ : _ -> do
      let refused = Left "an observation epoch reads one cluster; these addresses name several"
      pure (ObservationEpoch generation' (Map.fromList [(single, refused) | (_, members) <- snapshotReads addresses, (_, single) <- members]))
    _ -> do
      outcomes <- mapConcurrently (\(arguments, members) -> bracket_ (waitQSem readLimit) (signalQSem readLimit) (readGroup config arguments members)) (snapshotReads addresses)
      let (_, settled) = mapAccumL settle fallbackBudget outcomes
      pure (ObservationEpoch generation' (Map.unions settled))

-- | At most eight grouped reads in flight in the whole process, however many
-- epochs nested adapters open at once (EP-226 M3). A limit on load, not an
-- authority: it carries no identity.
readLimit :: QSem
readLimit = unsafePerformIO (newQSem 8)
{-# NOINLINE readLimit #-}

-- | What one grouped read proved, after its one retry.
data GroupOutcome
  = Proved !(Map [String] KubectlResult)
  | Unrecognized ![(Text, [String])]
  | Unavailable !Text ![(Text, [String])]

readGroup :: KubernetesRuntimeConfig -> [String] -> [(Text, [String])] -> IO GroupOutcome
readGroup config arguments members = attempt (1 :: Int)
  where
    attempt n = do
      result <- invokeKubectl config arguments ""
      case classify result of
        Left reason
          | n < 2 -> traceCount CategoryRetry "epoch read" 0 >> attempt (n + 1)
          | otherwise -> pure (Unavailable reason members)
        Right outcome -> pure outcome
    classify result = case result of
      Right (ExitFailure _, _, errors)
        | "the server doesn't have a resource type" `T.isInfixOf` T.pack errors -> Right (Proved (snapshotAnswers members result))
        | otherwise -> Left (T.strip (T.pack errors))
      Left reason -> Left reason
      Right (ExitSuccess, _, _)
        | Map.null proved -> Right (Unrecognized members)
        | otherwise -> Right (Proved proved)
      where
        proved = snapshotAnswers members result

-- | Settle an outcome against the epoch's remaining fallback budget: an
-- answer that proves nothing leaves at most that many members to their own
-- reads (absent from the map) and makes the rest unavailable.
settle :: Int -> GroupOutcome -> (Int, Map [String] KubectlResult)
settle budget = \case
  Proved proved -> (budget, proved)
  Unavailable reason members -> (budget, Map.fromList [(single, Left ("grouped read unavailable: " <> reason)) | (_, single) <- members])
  Unrecognized members ->
    let (forwarded, refused) = splitAt budget members
     in ( budget - length forwarded
        , Map.fromList [(single, Left "grouped read gave an unrecognized answer, and the epoch's single-read fallback is spent") | (_, single) <- refused]
        )

-- | The runtime of a read-only phase over this epoch: the same context and
-- guard, with the epoch's single-object reads answered from it while the
-- session generation it was gathered in holds.
epochRuntime :: KubernetesRuntimeConfig -> ObservationEpoch -> KubernetesRuntimeConfig
epochRuntime config epoch = withKubectlInterpreter (runKubectlWith (answerFrom config (pure (Just epoch)))) config

-- | A read-only run's runtime over these addresses (a status run).
snapshotRuntime :: KubernetesRuntimeConfig -> [ProviderAddress] -> IO KubernetesRuntimeConfig
snapshotRuntime config addresses = epochRuntime config <$> openObservationEpoch config addresses

-- | A plan's epoch: each batch observation begins a phase over exactly the
-- resources it observes, and the plan's later reads of them (preparing an
-- operation's before-state) are answered from it.
newtype PhaseEpoch = PhaseEpoch (IORef (Maybe ObservationEpoch))

newPhaseEpoch :: IO PhaseEpoch
newPhaseEpoch = PhaseEpoch <$> newIORef Nothing

-- | Replace the phase's epoch with one over these addresses.
beginPhase :: KubernetesRuntimeConfig -> PhaseEpoch -> [ProviderAddress] -> IO ()
beginPhase config (PhaseEpoch current) addresses = openObservationEpoch config addresses >>= writeIORef current . Just

phaseRuntime :: KubernetesRuntimeConfig -> PhaseEpoch -> KubernetesRuntimeConfig
phaseRuntime config (PhaseEpoch current) = withKubectlInterpreter (runKubectlWith (answerFrom config (readIORef current))) config

-- | The runtime already counted each request as logical work (EP-224): a
-- request the epoch answers is reuse, any other is forwarded uncounted.
answerFrom :: KubernetesRuntimeConfig -> IO (Maybe ObservationEpoch) -> KubectlRequest -> IO KubectlResult
answerFrom config current request = do
  epoch <- current
  generation' <- commandSessionGeneration (runtimeKubectlContext config)
  case epoch >>= \gathered -> if gathered ^. #generation == generation' then Map.lookup (request ^. #arguments) (gathered ^. #answers) else Nothing of
    Just answered -> answered <$ traceCount CategoryKubernetesReuse (kubectlPurpose (request ^. #arguments)) 0
    Nothing -> dispatchKubectl config (request ^. #arguments) (request ^. #input)

-- | One read per cluster, kind and namespace, in chunks of at most
-- 'chunkLimit' names and 'chunkBytes' bytes of names, with the single-object
-- read each named member stands for. Duplicate addresses are read once.
snapshotReads :: [ProviderAddress] -> [([String], [(Text, [String])])]
snapshotReads addresses =
  [ ( ["get", kind] <> map (T.unpack . fst) members <> namespaceArgs namespace <> ["-o", "json", "--ignore-not-found"]
    , members
    )
  | ((_, kind, namespace), named) <- Map.toAscList grouped
  , members <- chunks (Map.toAscList named)
  ]
  where
    grouped :: Map (ResourceId, String, Maybe Name) (Map Text [String])
    grouped =
      Map.fromListWith
        Map.union
        [ ((cluster, kind, namespace), Map.singleton (nameText name) single)
        | address@(Kubernetes cluster _ _ namespace name) <- addresses
        , Just single@(_ : kind : _) <- [objectReadArguments address]
        ]
    namespaceArgs = maybe [] (\namespace -> ["--namespace", T.unpack (nameText namespace)])
    chunks [] = []
    chunks members = let (taken, rest) = takeChunk 0 0 members in taken : chunks rest
    takeChunk _ _ [] = ([], [])
    takeChunk count bytes (member@(name, _) : rest)
      | count > 0 && (count >= chunkLimit || bytes + size > chunkBytes) = ([], member : rest)
      | otherwise = let (taken, remaining) = takeChunk (count + 1) (bytes + size) rest in (member : taken, remaining)
      where
        size = T.length name + 1

-- | The single-object answers a well-formed grouped read proves. A member the
-- read omits is absent, as @--ignore-not-found@ reports it alone. An unknown
-- kind fails every member as it fails one. Any other failure or output proves
-- nothing.
snapshotAnswers :: [(Text, [String])] -> KubectlResult -> Map [String] KubectlResult
snapshotAnswers members = \case
  Right (ExitSuccess, output, _)
    | all (`elem` [' ', '\n']) output -> answerAll (Right (ExitSuccess, "", ""))
    | Right items <- listed output ->
        Map.fromList
          [ (single, Right (ExitSuccess, maybe "" render (Map.lookup name items), ""))
          | (name, single) <- members
          ]
  failed@(Right (ExitFailure _, _, errors))
    | "the server doesn't have a resource type" `T.isInfixOf` T.pack errors -> answerAll failed
  _ -> Map.empty
  where
    answerAll result = Map.fromList [(single, result) | (_, single) <- members]
    render = T.unpack . TE.decodeUtf8 . BL.toStrict . encode
    listed output = do
      value <- eitherDecodeStrict' (TE.encodeUtf8 (T.pack output))
      objects <- case value of
        Object root
          | KM.lookup "kind" root == Just (String "List") -> case KM.lookup "items" root of
              Just (Array items) -> Right (V.toList items)
              _ -> Left "a List without items"
        -- kubectl answers one name with the object itself; several with a
        -- List, even of one item.
        _ | length members == 1 -> Right [value]
        _ -> Left "several names answered without a List"
      Map.fromList <$> traverse named objects
    named object = case object of
      Object root
        | Just (Object metadata) <- KM.lookup "metadata" root
        , Just (String name) <- KM.lookup "name" metadata ->
            Right (name, object)
      _ -> Left "an object without a name"
