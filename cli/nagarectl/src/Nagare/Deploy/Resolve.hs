-- | Deploy-time resolvers shared by the single-Service deploy path
-- (@nagarectl deploy@) and the multi-workload aggregate deploy path
-- (@nagarectl app deploy@, MasterPlan 14 / EP-2). These three helpers lived in
-- the @nagarectl@ executable's @Main.hs@ historically; EP-2 extracted them into
-- this library module so the new library-resident orchestration code
-- ("Nagare.App.Deploy") can reuse them — a library module cannot import from the
-- executable. The extraction is behavior-preserving: @nagarectl deploy@ produces
-- byte-identical output before and after.
--
-- Note: 'resolveBuildSpec' here takes the two build-override paths directly
-- (rather than the Main-local @DeployOpts@ record it used to destructure), so the
-- helper has no dependency on any executable-local type.
module Nagare.Deploy.Resolve
  ( resolveTag
  , resolveBuildSpec
  , resolveConnectionEnv
  , resolveBrokerEnv
  )
where

import Control.Monad (forM)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Broker.Connection (brokerConnectionEnv, lookupBrokerConnection, mergeBrokerConnectionEnvs)
import Nagare.Build (applyBuildOverrides)
import Nagare.Database.Connection (connectionEnv, mergeConnectionEnvs)
import Nagare.Database.Discover (lookupConnection)
import Nagare.Dsl.Broker (BrokerBinding)
import Nagare.Dsl.Build (BuildSpec)
import Nagare.Dsl.Types
  ( DatabaseName
  , EnvName
  , Namespace
  , ScopedEnvVar
  , databaseNameText
  , namespaceText
  )
import Nagare.Image (computeTag)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Resolve the image tag: an explicit @--tag@ wins; otherwise the UTC timestamp
-- @computeTag@ produces.
resolveTag :: Maybe String -> IO Text
resolveTag (Just t) = pure (T.pack t)
resolveTag Nothing = computeTag

-- | Apply the @--context@/@--dockerfile@ overrides to the config's build spec,
-- exiting with a clear error if an override is invalid or misused (e.g. an
-- override against a prebuilt-image config). With no overrides the spec is
-- returned unchanged. (Takes the two override paths directly so this helper does
-- not depend on the executable-local @DeployOpts@ record.)
resolveBuildSpec :: Maybe FilePath -> Maybe FilePath -> BuildSpec -> IO BuildSpec
resolveBuildSpec ctxOverride dfOverride spec =
  orDie (applyBuildOverrides ctxOverride dfOverride spec)

-- | EP-46: resolve each referenced database to its engine + identity (read-only
-- cluster lookup) and build the merged per-engine connection env. Empty list ⇒
-- no cluster call and an empty map (stateless apps are unaffected). A missing
-- database or a same-engine collision exits with a clear message.
resolveConnectionEnv :: Namespace -> [DatabaseName] -> IO (Map EnvName ScopedEnvVar)
resolveConnectionEnv _ [] = pure Map.empty
resolveConnectionEnv ns dbs = do
  maps <- forM dbs $ \name -> do
    r <- lookupConnection (namespaceText ns) (databaseNameText name)
    case r of
      Left err -> dieT ("nagarectl deploy: " <> err)
      Right (eng, ident) -> pure (connectionEnv eng name ns ident)
  case mergeConnectionEnvs maps of
    Left err -> dieT ("nagarectl deploy: " <> err)
    Right m -> pure m

-- | EP-77: resolve each referenced broker/topic binding to a live broker
-- connection and build the merged Kafka-compatible connection env. Empty list
-- means no cluster call and an empty map.
resolveBrokerEnv :: Namespace -> [BrokerBinding] -> IO (Map EnvName ScopedEnvVar)
resolveBrokerEnv _ [] = pure Map.empty
resolveBrokerEnv ns bindings = do
  maps <- forM bindings $ \binding -> do
    r <- lookupBrokerConnection ns binding
    case r of
      Left err -> dieT ("nagarectl deploy: " <> err)
      Right conn -> case brokerConnectionEnv binding conn of
        Left err -> dieT ("nagarectl deploy: " <> err)
        Right env -> pure env
  case mergeBrokerConnectionEnvs maps of
    Left err -> dieT ("nagarectl deploy: " <> err)
    Right m -> pure m

-- | Exit with a one-line error from a pure @Either Text@ validation.
orDie :: Either Text a -> IO a
orDie = either dieT pure

-- | Print a one-line @nagarectl:@ error to stderr and exit non-zero.
dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure
