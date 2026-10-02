-- | Runtime / Cluster. Executable-private CLI boundary.
module Nagare.Cli.Runtime.Cluster
  ( guardKubernetesContext
  )
where

import Data.Generics.Labels ()
import Nagare.Dsl.Prelude
import Nagare.Host.Config (readContextHostName)
import Nagare.Ops.ClusterGuard
  ( clusterGuardVerdict
  , defaultClusterGuardOps
  , observeClusterGuard
  , renderClusterGuard
  )
import Nagare.Target
  ( ActiveTarget
  , Mode (Cloud, Local)
  , contextNameText
  )

guardKubernetesContext :: ActiveTarget -> IO (Either Text Text)
guardKubernetesContext active = case active ^. #profile . #mode of
  Local -> pure (Right "cluster guard: local mode; no cloud cluster identity to confine")
  Cloud -> do
    let context = active ^. #contextName
        contextText = contextNameText context
    expectedNode <- readContextHostName context
    case expectedNode of
      Left err -> pure (Left err)
      Right expected -> do
        observed <- observeClusterGuard defaultClusterGuardOps contextText expected
        pure $ do
          inputs <- observed
          clusterGuardVerdict inputs
          Right (renderClusterGuard inputs)
