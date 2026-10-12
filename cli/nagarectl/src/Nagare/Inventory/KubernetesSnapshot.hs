-- | One status run's read of the cluster (EP-185). Observation and the
-- readiness probe read each object with its own @kubectl get@; a snapshot reads
-- the run's objects once, one @kubectl get@ per kind and namespace, and answers
-- those single-object reads from it. Every other request goes to the cluster.
-- A snapshot serves read-only runs only: it never sees its own run's writes.
module Nagare.Inventory.KubernetesSnapshot
  ( snapshotRuntime
  , snapshotAnswers
  , snapshotReads
  )
where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_)
import Data.Aeson (Value (..), eitherDecodeStrict', encode)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesRuntime (objectReadArguments)
import Nagare.Inventory.KubernetesTransport (KubectlResult, KubernetesRuntimeConfig, invokeKubectl, runKubectlWith, withKubectlInterpreter)
import Nagare.Resource.Types (Name, ProviderAddress (..), nameText)
import System.Exit (ExitCode (..))

-- | The runtime of a read-only run over these addresses: the same context and
-- guard, with the addresses' single-object reads answered from one batched read.
snapshotRuntime :: KubernetesRuntimeConfig -> [ProviderAddress] -> IO KubernetesRuntimeConfig
snapshotRuntime config addresses = do
  -- At most eight reads at a time (M4).
  limit <- newQSem 8
  answers <-
    Map.unions
      <$> mapConcurrently
        ( \(arguments, members) ->
            bracket_ (waitQSem limit) (signalQSem limit) (snapshotAnswers members <$> invokeKubectl config arguments "")
        )
        (snapshotReads addresses)
  let answer request =
        maybe
          (invokeKubectl config (request ^. #arguments) (request ^. #input))
          pure
          (Map.lookup (request ^. #arguments) answers)
  pure (withKubectlInterpreter (runKubectlWith answer) config)

-- | One read per kind and namespace, with the single-object read each named
-- member stands for.
snapshotReads :: [ProviderAddress] -> [([String], [(Text, [String])])]
snapshotReads addresses =
  [ ( ["get", kind] <> map (T.unpack . fst) members <> namespaceArgs namespace <> ["-o", "json", "--ignore-not-found"]
    , members
    )
  | ((kind, namespace), named) <- Map.toAscList grouped
  , let members = Map.toAscList named
  ]
  where
    grouped :: Map (String, Maybe Name) (Map Text [String])
    grouped =
      Map.fromListWith
        Map.union
        [ ((kind, namespace), Map.singleton (nameText name) single)
        | address@(Kubernetes _ _ _ namespace name) <- addresses
        , Just single@(_ : kind : _) <- [objectReadArguments address]
        ]
    namespaceArgs = maybe [] (\namespace -> ["--namespace", T.unpack (nameText namespace)])

-- | The single-object answers a batched read proves. A member the read omits
-- is absent, as @--ignore-not-found@ reports it alone. An unknown kind fails
-- every member as it fails one. Any other failure or output proves nothing,
-- and its members are read one by one.
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
        _ -> Right [value]
      Map.fromList <$> traverse named objects
    named object = case object of
      Object root
        | Just (Object metadata) <- KM.lookup "metadata" root
        , Just (String name) <- KM.lookup "name" metadata ->
            Right (name, object)
      _ -> Left "an object without a name"
