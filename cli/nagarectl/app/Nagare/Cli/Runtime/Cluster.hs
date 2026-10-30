-- | Runtime / Cluster. Executable-private CLI boundary.
module Nagare.Cli.Runtime.Cluster
  ( guardKubernetesContext
  , withContextEnSession
  , withPreparedContextEnSession
  )
where

import Data.Generics.Labels ()
import Nagare.Dsl.Prelude
import Nagare.Host.Config (readContextHostName)
import Nagare.Inventory.AccessRuntime (EnTransport, prepareEnSession, withEnSession)
import Nagare.Inventory.ClusterSession (commandClusterSession, defaultSessionOps, sessionGuard)
import Nagare.Ops.ClusterGuard
  ( admitClusterGuard
  , defaultClusterGuardOps
  , renderClusterGuard
  )
import Nagare.Target
  ( ActiveTarget
  , Mode (Cloud, Local)
  , contextNameText
  )

-- | The guard of a Kubernetes request for the active context. Inside a
-- command it is the command's session (EP-226): one admission, renewed every
-- 60 seconds, whose private kubeconfig every request then names. A local
-- context's session binds that kubeconfig and guards no host.
guardKubernetesContext :: ActiveTarget -> IO (Either Text Text)
guardKubernetesContext active = case active ^. #profile . #mode of
  Local ->
    commandClusterSession defaultSessionOps contextText Nothing >>= \case
      Nothing -> pure (Right "cluster guard: local mode; no cloud cluster identity to confine")
      Just session -> fmap (const "cluster guard: local mode; no cloud cluster identity to confine") <$> either (pure . Left) sessionGuard session
  Cloud -> do
    expectedNode <- readContextHostName context
    case expectedNode of
      Left err -> pure (Left err)
      Right expected ->
        commandClusterSession defaultSessionOps contextText (Just expected) >>= \case
          Nothing -> fmap renderClusterGuard <$> admitClusterGuard defaultClusterGuardOps contextText expected
          Just session -> fmap (const ("cluster guard: Nagare context " <> contextText <> "; expected node " <> expected <> "; admitted by the command's session")) <$> either (pure . Left) sessionGuard session
  where
    context = active ^. #contextName
    contextText = contextNameText context

-- | The command's one en session for the active context (EP-214): one
-- forward and one passing cluster guard, released when the command ends.
withContextEnSession :: ActiveTarget -> (EnTransport -> IO a) -> IO a
withContextEnSession active =
  withEnSession
    (contextNameText (active ^. #contextName))
    (fmap (fmap (const ())) (guardKubernetesContext active))

-- | The same session, with its guard and forward prepared while the command
-- opens the inventory (EP-221). For commands that always reach en.
withPreparedContextEnSession :: ActiveTarget -> (EnTransport -> IO a) -> IO a
withPreparedContextEnSession active body =
  withContextEnSession active (\en -> prepareEnSession en (body en))
