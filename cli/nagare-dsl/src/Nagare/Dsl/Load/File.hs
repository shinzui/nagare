-- | File responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.File
  ( loadApplication
  , loadBroker
  , loadDatabase
  , loadDeployment
  , loadJob
  , loadServerSite
  , loadSite
  , loadStaticSite
  , loadStaticSiteWith
  , loadTask
  , loadWorker
  )
where

import Nagare.Dsl.Application (Application)
import Nagare.Dsl.Broker (Broker)
import Nagare.Dsl.Database (Database)
import Nagare.Dsl.Job (Job)
import Nagare.Dsl.Load.Application (decodeApplication)
import Nagare.Dsl.Load.Broker (decodeBroker)
import Nagare.Dsl.Load.Database (decodeDatabase)
import Nagare.Dsl.Load.Deployment (decodeDeployment)
import Nagare.Dsl.Load.Error
  ( ConfigTimeout (..)
  , LoadError (..)
  , defaultConfigTimeout
  )
import Nagare.Dsl.Load.Job (decodeJob)
import Nagare.Dsl.Load.Process (runConfig, runConfigWith)
import Nagare.Dsl.Load.ServerSite (decodeServerSite)
import Nagare.Dsl.Load.Site (SiteConfig (..), decodeSite)
import Nagare.Dsl.Load.StaticSite (decodeStaticSite)
import Nagare.Dsl.Load.Task (decodeTask)
import Nagare.Dsl.Load.Worker (decodeWorker)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Types (StaticSite)
import Nagare.Dsl.Task (Task)
import Nagare.Dsl.Types (Deployment)
import Nagare.Dsl.Worker (Worker)

-- | Load a 'Task' from a Haskell config-as-program source file. The config must
-- print its JSON via 'Nagare.Dsl.Config.emitTask'. A config that emits a
-- different shape is reported as 'UnexpectedKind'. Used by EP-51's @task@ CLI.
loadTask :: FilePath -> IO (Either LoadError Task)
loadTask path = fmap (>>= decodeTask) (runConfig path)

-- | Load a Job from a Haskell config-as-program that calls @emitJob@.
loadJob :: FilePath -> IO (Either LoadError Job)
loadJob path = fmap (>>= decodeJob) (runConfig path)

-- | Load a 'Worker' from a Haskell config-as-program source file (EP-71). The
-- config must print its JSON via 'Nagare.Dsl.Config.emitWorker'. A config that
-- instead emits a 'Deployment' or another kind is reported as 'UnexpectedKind'.
-- Used by @nagarectl worker deploy@.
loadWorker :: FilePath -> IO (Either LoadError Worker)
loadWorker path = fmap (>>= decodeWorker) (runConfig path)

-- | Load an 'Application' from a Haskell config-as-program source file (MasterPlan
-- 14, EP-1). The config must print its JSON via
-- 'Nagare.Dsl.Config.emitApplication'. A config that instead emits a single
-- workload (or another kind) is reported as 'UnexpectedKind'. Used by
-- @nagarectl app deploy@ (EP-2).
loadApplication :: FilePath -> IO (Either LoadError Application)
loadApplication path = fmap (>>= decodeApplication) (runConfig path)

-- | Load a 'Deployment' from a Haskell config-as-program source file. The config
-- must print its JSON via 'Nagare.Dsl.Config.emitDeployment'. See 'runConfig'
-- for the compile-and-run contract; see this plan's Decision Log for the
-- production-provisioning note handed to EP-12.
loadDeployment :: FilePath -> IO (Either LoadError Deployment)
loadDeployment path = fmap (>>= decodeDeployment) (runConfig path)

-- | Load a 'Broker' from a Haskell config-as-program source file. The config
-- must print its JSON via 'Nagare.Dsl.Config.emitBroker'. A config that instead
-- emits any other kind is reported as 'UnexpectedKind'.
loadBroker :: FilePath -> IO (Either LoadError Broker)
loadBroker path = fmap (>>= decodeBroker) (runConfig path)

-- | Load a 'Database' from a Haskell config-as-program source file (MasterPlan 9,
-- EP-44/EP-45). The config must print its JSON via
-- 'Nagare.Dsl.Config.emitDatabase'. A config that instead emits a 'Deployment' or
-- a site is reported as 'UnexpectedKind'. Used by @nagarectl db create --config@.
loadDatabase :: FilePath -> IO (Either LoadError Database)
loadDatabase path = fmap (>>= decodeDatabase) (runConfig path)

-- | Load a 'StaticSite' from a Haskell config-as-program source file. The config
-- must print its JSON via 'Nagare.Dsl.Config.emitStaticSite'. A config that
-- instead emits a 'Deployment' (or a future @ServerSite@) is reported as
-- 'UnexpectedKind', not silently misread.
loadStaticSite :: FilePath -> IO (Either LoadError StaticSite)
loadStaticSite = loadStaticSiteWith defaultConfigTimeout

-- | 'loadStaticSite' with an explicit time budget. @nagared@ uses this so a
-- pushed config that loops cannot wedge a webhook handler thread forever.
loadStaticSiteWith :: ConfigTimeout -> FilePath -> IO (Either LoadError StaticSite)
loadStaticSiteWith budget path = fmap (>>= decodeStaticSite) (runConfigWith budget path)

-- | Load a 'ServerSite' from a Haskell config-as-program source file (EP-18). The
-- config must print its JSON via 'Nagare.Dsl.Config.emitServerSite'. A config
-- that emits a different shape is reported as 'UnexpectedKind'.
loadServerSite :: FilePath -> IO (Either LoadError ServerSite)
loadServerSite path = fmap (>>= decodeServerSite) (runConfig path)

-- | Load whichever site a config emits, dispatching on the top-level @kind@
-- (EP-18). This is the single loader @nagarectl site deploy@ calls: a
-- @"StaticSite"@ runs the Nginx path, a @"ServerSite"@ runs the Node path, and a
-- @Deployment@-shaped config (no @kind@) or an unknown kind is reported as
-- 'UnexpectedKind' so the user is told to use the right command.
loadSite :: FilePath -> IO (Either LoadError SiteConfig)
loadSite path = fmap (>>= decodeSite) (runConfig path)
