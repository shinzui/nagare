{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | The external request boundary beneath the production Kubernetes runtime.
-- Handlers may execute requests or model their outcomes; all native rendering,
-- identity checks, journal transitions and recovery remain in their callers.
module Nagare.Inventory.KubernetesTransport
  ( Kubectl
  , KubectlRequest (..)
  , KubectlResult
  , KubectlInterpreter
  , kubectl
  , runKubectlWith
  , runKubectlIO
  , KubernetesRuntimeConfig (KubernetesRuntimeConfig, runtimeContext, runtimeKubectlContext, runtimeGuard)
  , withKubectlInterpreter
  , invokeKubectl
  , dispatchKubectl
  , countedTransport
  , kubectlPurpose
  , runtimePause
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, inject, liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret, send)
import GHC.Clock (getMonotonicTimeNSec)
import Nagare.Contract.Trace (CountCategory (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.ClusterSession (kubectlConnectionArguments)
import Nagare.Inventory.Store.Counters (traceCount, traceProcess)
import Nagare.Resource.Types (ContextId)
import System.Exit (ExitCode)
import System.Process (readProcessWithExitCode)

data KubectlRequest = KubectlRequest
  { context :: !Text
  , arguments :: ![String]
  , input :: !String
  }
  deriving stock (Eq, Show, Generic)

type KubectlResult = Either Text (ExitCode, String, String)

data Kubectl :: Effect where
  Invoke :: KubectlRequest -> Kubectl m KubectlResult

type instance DispatchOf Kubectl = Dynamic

type KubectlInterpreter = forall a. Eff '[Kubectl] a -> IO a

kubectl :: KubectlRequest -> Eff '[Kubectl] KubectlResult
kubectl = send . Invoke

-- | IO is granted to the interpreter, not to the request program. A handler
-- must report unknown outcomes as unknown, including writes with lost replies.
runKubectlWith :: forall a. (KubectlRequest -> IO KubectlResult) -> Eff '[Kubectl] a -> IO a
runKubectlWith handler program =
  runEff $
    interpret
      (\_ (Invoke request) -> liftIO (handler request))
      (inject program :: Eff '[Kubectl, IOE] a)

runKubectlIO :: KubectlInterpreter
runKubectlIO = runKubectlWith . countedTransport $ \request -> do
  -- EP-226: inside a command session the request names the private
  -- kubeconfig its guard checked, or is refused with the guard.
  connection <- kubectlConnectionArguments (request ^. #context)
  case connection of
    Left reason -> pure (Left reason)
    Right selected -> do
      result <-
        traceProcess "kubectl" . try $
          readProcessWithExitCode
            "kubectl"
            (selected <> ["--request-timeout=10s"] <> request ^. #arguments)
            (request ^. #input)
      pure $ case result of
        Left (_ :: IOException) -> Left "could not invoke kubectl"
        Right output -> Right output

-- Keep the existing constructor and callers. Only explicit dependency
-- injection selects another interpreter; no environment variable enables it.
data KubernetesRuntimeConfig
  = KubernetesRuntimeConfig
      { runtimeContext :: !ContextId
      , runtimeKubectlContext :: !Text
      , runtimeGuard :: !(IO (Either Text ()))
      }
  | InterpretedRuntime
      { runtimeContext :: !ContextId
      , runtimeKubectlContext :: !Text
      , runtimeGuard :: !(IO (Either Text ()))
      , runtimeInterpreter :: !KubectlInterpreter
      }

withKubectlInterpreter :: KubectlInterpreter -> KubernetesRuntimeConfig -> KubernetesRuntimeConfig
withKubectlInterpreter interpreter config =
  InterpretedRuntime
    (runtimeContext config)
    (runtimeKubectlContext config)
    (runtimeGuard config)
    interpreter

-- | Wait between polls of the live cluster. An interpreted runtime answers
-- from memory, so waiting between its answers only costs time (EP-184).
runtimePause :: KubernetesRuntimeConfig -> Int -> IO ()
runtimePause config microseconds = case config of
  KubernetesRuntimeConfig {} -> threadDelay microseconds
  InterpretedRuntime {} -> pure ()

-- | One Kubernetes request the runtime asks for: counted as logical work
-- (EP-224), then answered by the selected interpreter.
invokeKubectl :: KubernetesRuntimeConfig -> [String] -> String -> IO KubectlResult
invokeKubectl config arguments input = do
  traceCount CategoryKubernetesLogical (kubectlPurpose arguments) 0
  dispatchKubectl config arguments input

-- | Answer a request without counting it as logical work again: for an
-- interpreter that forwards a request it cannot answer itself.
dispatchKubectl :: KubernetesRuntimeConfig -> [String] -> String -> IO KubectlResult
dispatchKubectl config arguments input =
  interpreter
    (kubectl (KubectlRequest (runtimeKubectlContext config) arguments input))
  where
    interpreter = case config of
      KubernetesRuntimeConfig {} -> runKubectlIO
      InterpretedRuntime {runtimeInterpreter = selected} -> selected

-- | Count each request a handler sends to the cluster, with its time. The
-- production transport uses it; a fake API server uses it to stand where
-- the network would be.
countedTransport :: (KubectlRequest -> IO KubectlResult) -> KubectlRequest -> IO KubectlResult
countedTransport handler request = do
  started <- getMonotonicTimeNSec
  result <- handler request
  finished <- getMonotonicTimeNSec
  traceCount CategoryKubernetesTransport (kubectlPurpose (request ^. #arguments)) (finished - started)
  pure result

-- | A request's verb and, for verbs that name one, its kind; never names,
-- namespaces or bodies.
kubectlPurpose :: [String] -> Text
kubectlPurpose = \case
  verb : kind : _
    | verb `elem` ["get", "patch", "delete", "wait", "rollout", "logs", "exec"]
    , take 1 kind /= "-" ->
        T.pack (verb <> " " <> kind)
  verb : _ -> T.pack verb
  [] -> "none"
