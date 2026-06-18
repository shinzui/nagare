-- | The typed long-running-worker model (EP-71). A 'Worker' is nagare's workload
-- for a background process that is /not/ request-driven: it pulls jobs off a
-- queue, processes a stream, or runs a polling loop continuously. It renders to
-- a plain @apps/v1@ Kubernetes 'Deployment' (see "Nagare.Dsl.Worker.Render") —
-- not a Knative Service — so it never scales to zero and needs no HTTP port.
--
-- Like 'Nagare.Dsl.Database.Database', the 'Worker' record has a public
-- constructor; the safety guarantee comes from the field types, every one of
-- which is reused from "Nagare.Dsl.Types" / "Nagare.Dsl.Build" or smart-
-- constructed here ('Replicas', 'Command'). It carries exactly what a worker
-- needs beyond an app's reused building blocks: a fixed 'Replicas' count (not an
-- autoscaler — the cluster is single-node) and an optional 'Command' entrypoint
-- override for when the image's default entrypoint is not the worker to launch.
module Nagare.Dsl.Worker
  ( -- * Replicas
    Replicas
  , mkReplicas
  , defaultReplicas
  , replicasInt

    -- * Command (entrypoint override)
  , Command (..)
  , mkCommand
  , commandArgvList

    -- * Worker
  , Worker (..)

    -- * Preset
  , webWorker
  ) where

import Nagare.Dsl.Prelude

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Build (BuildSpec (..), mkTag)
import Nagare.Dsl.Types
  ( DatabaseName
  , EnvName
  , ImageRef
  , Namespace
  , Resources
  , ScopedEnvVar
  , ServiceName
  , Volume
  , defaultNamespace
  , mkImageRef
  , mkServiceName
  )

-- | How many identical copies of the worker pod to run. A fixed, user-chosen
-- integer (default 1), not an autoscaler: the cluster is single-node, so a
-- worker sets a replica count, never a scale range. @0@ is allowed and means
-- "scaled to zero / paused". The constructor is hidden; use 'mkReplicas' or
-- 'defaultReplicas'. Follows the exact shape of 'Nagare.Dsl.Types.mkPort'.
newtype Replicas = Replicas Int
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'Replicas'. Rejects a negative count; @0@ (paused)
-- and any positive count are accepted.
mkReplicas :: Int -> Either Text Replicas
mkReplicas n
  | n < 0 = Left ("replicas must be >= 0, got: " <> tshow n)
  | otherwise = Right (Replicas n)

-- | The default replica count: @1@.
defaultReplicas :: Replicas
defaultReplicas = Replicas 1

replicasInt :: Replicas -> Int
replicasInt (Replicas n) = n

-- | An optional entrypoint override for the worker's container, e.g.
-- @["python", "-m", "worker"]@. @argv[0]@ is the executable. When a 'Worker'
-- carries no 'Command' the image's own entrypoint runs. The record constructor
-- is public but the only field is smart-constructed via 'mkCommand', which
-- enforces the non-empty, NUL-free invariant.
data Command = Command
  { commandArgv :: ![Text]
  -- ^ non-empty; @argv[0]@ is the executable.
  }
  deriving stock (Generic, Eq, Show)

-- | Validate and construct a 'Command': the argv list must be non-empty and no
-- element may contain a NUL character.
mkCommand :: [Text] -> Either Text Command
mkCommand [] = Left "command must not be empty (argv[0] is the executable)"
mkCommand argv
  | any (Text.isInfixOf "\NUL") argv =
      Left "command arguments must not contain NUL characters"
  | otherwise = Right (Command {commandArgv = argv})

commandArgvList :: Command -> [Text]
commandArgvList = commandArgv

-- | A long-running background worker. There is no hidden constructor for
-- 'Worker' — the safety guarantee comes from the field types (mirrors
-- 'Nagare.Dsl.Database.Database' and 'Nagare.Dsl.Types.Deployment'). It reuses,
-- unchanged, the building blocks the request-driven 'Nagare.Dsl.Types.Deployment'
-- already has (build, env, resources, volumes, databases) and reuses
-- 'ServiceName' for its name (a DNS-1123 label is exactly what a Kubernetes
-- object name needs); it carries no Knative-only fields (@domains@, @port@,
-- @scale@, @healthCheck@, @cdn@) because a worker is not request-driven.
data Worker = Worker
  { name :: !ServiceName
  , namespace :: !Namespace
  , image :: !ImageRef
  , build :: !BuildSpec
  , command :: !(Maybe Command)
  -- ^ entrypoint override; 'Nothing' runs the image default.
  , replicas :: !Replicas
  , env :: !(Map EnvName ScopedEnvVar)
  , resources :: !(Maybe Resources)
  , volumes :: ![Volume]
  , databases :: ![DatabaseName]
  }
  deriving stock (Generic, Eq, Show)

-- | Build a sensible default 'Worker' from just a name and image repository,
-- mirroring 'Nagare.Dsl.Presets.webService''s signature style. Defaults:
-- namespace 'defaultNamespace', a 'PrebuiltImage' build with tag @latest@ (so
-- the preset alone is runnable), 'defaultReplicas', no command, no resources,
-- and empty env/volumes/databases. Returns 'Either' 'String' (not 'Text') to
-- match the existing preset convention, so an example @Config.hs@ can chain it
-- without @mapLeft show@.
webWorker :: Text -> Text -> Either String Worker
webWorker nameText imageText = do
  name' <- toStr (mkServiceName nameText)
  img <- toStr (mkImageRef imageText)
  tag <- toStr (mkTag "latest")
  Right
    Worker
      { name = name'
      , namespace = defaultNamespace
      , image = img
      , build = PrebuiltImage tag
      , command = Nothing
      , replicas = defaultReplicas
      , env = Map.empty
      , resources = Nothing
      , volumes = []
      , databases = []
      }
  where
    toStr = either (Left . Text.unpack) Right

-- Internal: show a value as Text for error messages.
tshow :: (Show a) => a -> Text
tshow = Text.pack . show
