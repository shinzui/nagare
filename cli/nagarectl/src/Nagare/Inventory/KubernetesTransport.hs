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
  )
where

import Control.Exception (IOException, try)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, inject, liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret, send)
import Nagare.Dsl.Prelude
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
runKubectlIO = runKubectlWith $ \request -> do
  result <-
    try
      ( readProcessWithExitCode
          "kubectl"
          ( ["--context", T.unpack (request ^. #context), "--request-timeout=10s"]
              <> request ^. #arguments
          )
          (request ^. #input)
      )
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

invokeKubectl :: KubernetesRuntimeConfig -> [String] -> String -> IO KubectlResult
invokeKubectl config arguments input =
  interpreter
    (kubectl (KubectlRequest (runtimeKubectlContext config) arguments input))
  where
    interpreter = case config of
      KubernetesRuntimeConfig {} -> runKubectlIO
      InterpretedRuntime {runtimeInterpreter = selected} -> selected
