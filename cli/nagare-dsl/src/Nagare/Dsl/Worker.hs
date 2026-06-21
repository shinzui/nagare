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

    -- * Liveness probe (EP-74)
  , ProbeTiming (..)
  , mkProbeTiming
  , defaultProbeTiming
  , WorkerProbe (..)
  , mkExecProbe
  , mkTcpProbe
  , mkHttpProbe
  , execProbe
  , probeTiming

    -- * Worker
  , Worker (..)

    -- * Preset
  , webWorker
  )
where

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Broker.Types (BrokerBinding)
import Nagare.Dsl.Build (BuildSpec (..), mkTag)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( DatabaseName
  , EnvName
  , HealthScheme (..)
  , ImageRef
  , Namespace
  , Port
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

-- ---------------------------------------------------------------------------
-- Liveness probe (EP-74)

-- | Probe timing, shared across every 'WorkerProbe' branch. All durations are in
-- seconds. Construct via 'mkProbeTiming' (validates the ranges) or
-- 'defaultProbeTiming'. The range rules mirror 'Nagare.Dsl.Types.mkHealthCheck'.
data ProbeTiming = ProbeTiming
  { initialDelay :: !Int
  -- ^ seconds before the first probe; @>= 0@.
  , period :: !Int
  -- ^ seconds between probes; @>= 1@.
  , timeout :: !Int
  -- ^ per-probe timeout seconds; @>= 1@.
  , failureThreshold :: !Int
  -- ^ consecutive failures before the kubelet restarts the container; @>= 1@.
  , asStartup :: !Bool
  -- ^ also emit a @startupProbe@ with the same check (suspends liveness until the
  -- worker has started once).
  }
  deriving stock (Generic, Eq, Show)

-- | Validate and construct a 'ProbeTiming', rejecting an out-of-range field with
-- a precise message. Returns the value unchanged on success (mirrors 'mkTask').
mkProbeTiming :: ProbeTiming -> Either Text ProbeTiming
mkProbeTiming t
  | initialDelay t < 0 = Left ("probe initialDelay must be >= 0, got: " <> tshow (initialDelay t))
  | period t < 1 = Left ("probe period must be >= 1, got: " <> tshow (period t))
  | timeout t < 1 = Left ("probe timeout must be >= 1, got: " <> tshow (timeout t))
  | failureThreshold t < 1 =
      Left ("probe failureThreshold must be >= 1, got: " <> tshow (failureThreshold t))
  | otherwise = Right t

-- | The default probe timing: first probe immediately, every 10s, 1s timeout, 3
-- consecutive failures to restart, no startup probe. Mirrors
-- 'Nagare.Dsl.Types.httpHealthCheck''s defaults.
defaultProbeTiming :: ProbeTiming
defaultProbeTiming =
  ProbeTiming
    { initialDelay = 0
    , period = 10
    , timeout = 1
    , failureThreshold = 3
    , asStartup = False
    }

-- | A liveness check for a headless worker. The branch selects the Kubernetes
-- probe mechanism: 'ExecProbe' runs a command (exit 0 = healthy) — the primary
-- case for a worker with no HTTP server; 'TcpProbe' opens a TCP port;
-- 'HttpProbe' issues an HTTP GET (for a worker that happens to expose an internal
-- endpoint). The sum makes the choice exclusive at the type level. Construct via
-- 'mkExecProbe' / 'mkTcpProbe' / 'mkHttpProbe' (or the 'execProbe' convenience).
data WorkerProbe
  = -- | argv; non-empty, NUL-free (validated by 'mkExecProbe').
    ExecProbe ![Text] !ProbeTiming
  | -- | TCP port to dial.
    TcpProbe !Port !ProbeTiming
  | -- | HTTP path (must start with @/@), optional port (defaults to the probe's
    -- own — workers have no container port, so a port is usually given), scheme.
    HttpProbe !Text !(Maybe Port) !HealthScheme !ProbeTiming
  deriving stock (Generic, Eq, Show)

-- | Construct an exec liveness probe, reusing 'mkCommand''s argv invariant
-- (non-empty, NUL-free) and validating the timing.
mkExecProbe :: [Text] -> ProbeTiming -> Either Text WorkerProbe
mkExecProbe argv timing = do
  _ <- mkCommand argv
  t <- mkProbeTiming timing
  Right (ExecProbe argv t)

-- | Construct a TCP liveness probe from an already-validated 'Port' and timing.
-- (The 'Port' carries its own range invariant; the timing should come from
-- 'defaultProbeTiming' or a validated 'mkProbeTiming'.)
mkTcpProbe :: Port -> ProbeTiming -> WorkerProbe
mkTcpProbe = TcpProbe

-- | Construct an HTTP liveness probe, validating that the path starts with @/@
-- and the timing is in range.
mkHttpProbe :: Text -> Maybe Port -> HealthScheme -> ProbeTiming -> Either Text WorkerProbe
mkHttpProbe path mport scheme timing
  | not (Text.isPrefixOf "/" path) =
      Left ("probe http path must start with '/': " <> path)
  | otherwise = do
      t <- mkProbeTiming timing
      Right (HttpProbe path mport scheme t)

-- | The exec-probe convenience: an exec check with 'defaultProbeTiming'.
execProbe :: [Text] -> Either Text WorkerProbe
execProbe argv = mkExecProbe argv defaultProbeTiming

-- | The shared timing of any 'WorkerProbe' branch (used by the renderer and the
-- loader's defence-in-depth re-validation).
probeTiming :: WorkerProbe -> ProbeTiming
probeTiming (ExecProbe _ t) = t
probeTiming (TcpProbe _ t) = t
probeTiming (HttpProbe _ _ _ t) = t

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
  , brokers :: ![BrokerBinding]
  , liveness :: !(Maybe WorkerProbe)
  -- ^ optional liveness/health probe (EP-74). 'Nothing' (the default) emits no
  -- probe — byte-identical to a worker without one.
  }
  deriving stock (Generic, Eq, Show)

-- | Build a sensible default 'Worker' from just a name and image repository,
-- mirroring 'Nagare.Dsl.Presets.webService''s signature style. Defaults:
-- namespace 'defaultNamespace', a 'PrebuiltImage' build with tag @latest@ (so
-- the preset alone is runnable), 'defaultReplicas', no command, no resources,
-- and empty env/volumes/databases. Returns 'Either' 'String' (not 'Text') to
-- match the existing preset convention, so an example @Config.hs@ can chain it
-- without @first show@.
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
      , brokers = []
      , liveness = Nothing
      }
  where
    toStr = either (Left . Text.unpack) Right

-- Internal: show a value as Text for error messages.
tshow :: (Show a) => a -> Text
tshow = Text.pack . show
