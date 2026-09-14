{-# LANGUAGE OverloadedStrings #-}

-- | Fail-closed Kubernetes identity preflight for cloud mutations.
module Nagare.Ops.ClusterGuard
  ( ClusterGuardInputs (..)
  , ClusterGuardOps (..)
  , clusterGuardObservationsValue
  , clusterGuardVerdict
  , defaultClusterGuardOps
  , observeClusterGuard
  , parseServerNodes
  , renderClusterGuard
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Dsl.Prelude
import System.Exit (ExitCode (..))
import System.Process (proc, readCreateProcessWithExitCode)

data ClusterGuardInputs = ClusterGuardInputs
  { nagareContext :: !Text
  , kubeContext :: !Text
  , expectedNode :: !Text
  , observedNodes :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

data ClusterGuardOps = ClusterGuardOps
  { kubectlExecutable :: !FilePath
  }
  deriving stock (Generic, Eq, Show)

defaultClusterGuardOps :: ClusterGuardOps
defaultClusterGuardOps = ClusterGuardOps "kubectl"

-- | Observe the ambient kubeconfig. The command deliberately does not select a
-- context itself: a mismatched @KUBECONFIG@ must be detected, not corrected.
observeClusterGuard :: ClusterGuardOps -> Text -> Text -> IO (Either Text ClusterGuardInputs)
observeClusterGuard ops selectedContext expected = do
  currentResult <- runKubectl ops ["config", "current-context"]
  case currentResult of
    Left err -> pure (Left (observationFailure selectedContext expected "read the current Kubernetes context" err))
    Right currentBytes -> do
      let current = T.strip (decode currentBytes)
      if T.null current
        then pure (Left (observationFailure selectedContext expected "read the current Kubernetes context" "kubectl returned an empty context"))
        else do
          nodesResult <- runKubectl ops ["get", "nodes", "-o", "json", "--request-timeout=10s"]
          pure $ do
            nodesBytes <- first (observationFailure selectedContext expected "list Kubernetes nodes") nodesResult
            servers <- first (observationFailure selectedContext expected "interpret Kubernetes nodes") (parseServerNodes nodesBytes)
            Right
              ClusterGuardInputs
                { nagareContext = selectedContext
                , kubeContext = current
                , expectedNode = expected
                , observedNodes = sort servers
                }

-- | Accept exactly one Kubernetes server node and require it to be the host
-- owned by the selected Nagare context.
clusterGuardVerdict :: ClusterGuardInputs -> Either Text ()
clusterGuardVerdict inputs
  | inputs ^. #kubeContext /= inputs ^. #nagareContext =
      refuse
        ( "the active Kubernetes context is '"
            <> inputs ^. #kubeContext
            <> "', not the selected Nagare context '"
            <> inputs ^. #nagareContext
            <> "'"
        )
  | inputs ^. #observedNodes == [inputs ^. #expectedNode] = Right ()
  | null (inputs ^. #observedNodes) = refuse "the cluster reports no server nodes"
  | otherwise =
      refuse
        ( "expected the sole server node to be '"
            <> inputs ^. #expectedNode
            <> "', but observed "
            <> renderNodes (inputs ^. #observedNodes)
        )
  where
    refuse message =
      Left
        ( "cluster guard: refusing Kubernetes mutation: "
            <> message
            <> ".\nexpected server node: "
            <> inputs ^. #expectedNode
            <> "\nobserved server nodes: "
            <> renderNodes (inputs ^. #observedNodes)
            <> "\n"
            <> remedy (inputs ^. #nagareContext)
        )

clusterGuardObservationsValue :: ClusterGuardInputs -> Aeson.Value
clusterGuardObservationsValue inputs =
  Aeson.object
    [ "nagareContext" Aeson..= (inputs ^. #nagareContext)
    , "kubeContext" Aeson..= (inputs ^. #kubeContext)
    , "expectedNode" Aeson..= (inputs ^. #expectedNode)
    , "observedServerNodes" Aeson..= (inputs ^. #observedNodes)
    ]

renderClusterGuard :: ClusterGuardInputs -> Text
renderClusterGuard inputs =
  "cluster guard: Nagare context "
    <> inputs ^. #nagareContext
    <> "; kube context "
    <> inputs ^. #kubeContext
    <> "; expected node "
    <> inputs ^. #expectedNode
    <> "; observed server nodes "
    <> renderNodes (inputs ^. #observedNodes)

parseServerNodes :: ByteString -> Either Text [Text]
parseServerNodes input = do
  root <- case Aeson.eitherDecodeStrict' input of
    Left err -> Left ("invalid JSON: " <> T.pack err)
    Right (Object object) -> Right object
    Right _ -> Left "node-list output is not a JSON object"
  items <- case KeyMap.lookup "items" root of
    Just (Array values) -> Right values
    Just _ -> Left "node-list items is not an array"
    Nothing -> Left "node-list output has no items"
  fmap concat . traverse parseNode $ V.toList items
  where
    parseNode (Object node) = do
      metadata <- objectAt "metadata" node
      name <- textAt "name" metadata
      labels <- optionalObjectAt "labels" metadata
      pure [name | any (`KeyMap.member` labels) serverRoleLabels]
    parseNode _ = Left "node-list contains a non-object item"

    serverRoleLabels =
      [ "node-role.kubernetes.io/control-plane"
      , "node-role.kubernetes.io/master"
      , "node-role.kubernetes.io/etcd"
      ]

runKubectl :: ClusterGuardOps -> [String] -> IO (Either Text ByteString)
runKubectl ops arguments = do
  result <- try (readCreateProcessWithExitCode (proc (ops ^. #kubectlExecutable) arguments) "")
  pure $ case result of
    Left (err :: IOException) -> Left ("could not start kubectl: " <> T.pack (show err))
    Right (ExitSuccess, stdoutText, _) -> Right (BC.pack stdoutText)
    Right (ExitFailure code, _, stderrText) ->
      Left
        ( "kubectl "
            <> T.unwords (map T.pack arguments)
            <> " exited "
            <> T.pack (show code)
            <> diagnostic stderrText
        )
  where
    diagnostic stderrText
      | T.null (T.strip (T.pack stderrText)) = ""
      | otherwise = ": " <> T.strip (T.pack stderrText)

objectAt :: Key.Key -> KeyMap.KeyMap Value -> Either Text (KeyMap.KeyMap Value)
objectAt key object = case KeyMap.lookup key object of
  Just (Object value) -> Right value
  Just _ -> Left (Key.toText key <> " is not an object")
  Nothing -> Left ("missing " <> Key.toText key)

optionalObjectAt :: Key.Key -> KeyMap.KeyMap Value -> Either Text (KeyMap.KeyMap Value)
optionalObjectAt key object = case KeyMap.lookup key object of
  Just (Object value) -> Right value
  Just _ -> Left (Key.toText key <> " is not an object")
  Nothing -> Right KeyMap.empty

textAt :: Key.Key -> KeyMap.KeyMap Value -> Either Text Text
textAt key object = case KeyMap.lookup key object of
  Just (String value) | not (T.null (T.strip value)) -> Right (T.strip value)
  Just _ -> Left (Key.toText key <> " is not non-empty text")
  Nothing -> Left ("missing " <> Key.toText key)

observationFailure :: Text -> Text -> Text -> Text -> Text
observationFailure selectedContext expected action err =
  "cluster guard: could not "
    <> action
    <> ": "
    <> err
    <> ". Selected Nagare context '"
    <> selectedContext
    <> "' expects server node '"
    <> expected
    <> "'.\n"
    <> remedy selectedContext

remedy :: Text -> Text
remedy selectedContext =
  "fix: run 'nagarectl kubeconfig fetch --context "
    <> selectedContext
    <> "', export that file as KUBECONFIG, and retry"

renderNodes :: [Text] -> Text
renderNodes nodes = "[" <> T.intercalate ", " nodes <> "]"

decode :: ByteString -> Text
decode = T.pack . BC.unpack
