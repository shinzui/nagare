-- | Build-time (@Build@-scoped) environment assembled into @docker build@
-- @--build-arg@s (EP-27).
--
-- A variable scoped @Build@ — written inline in the typed config, or stored in
-- the app's managed Build ConfigMap/Secret via the CLI — is passed to the image
-- build as a @--build-arg NAME=VALUE@, so a @Dockerfile@ @ARG NAME@ / @RUN ...@
-- sees it. It is /not/ placed in the runtime container (EP-23's renderer filters
-- inline @env:@ to @{Runtime}@). Precedence mirrors EP-23's runtime
-- @envFrom@-then-@env@: the managed Build store first, inline DSL Build env
-- overrides it.
--
-- SECURITY: @--build-arg@ values are recoverable from @docker history@ and image
-- metadata — they are NOT confidential. A @Build@-scoped secret-ref passed this
-- way produces a 'BuildArgSecretRef' warning ('printBuildArgWarnings'); the
-- confidential path (BuildKit @RUN --mount=type=secret@) is a noted follow-up.
module Nagare.Env.BuildArgs
  ( BuildArgWarning (..)
  , assembleBuildArgs
  , gatherBuildArgs
  , printBuildArgWarnings
  ) where

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Types
  ( EnvName
  , EnvScope (..)
  , EnvVar (..)
  , ScopedEnvVar (..)
  , envNameText
  )
import Nagare.Env.Store (readEnvStore, readSecretStore)
import System.IO (stderr)

-- | A build-scoped secret-ref that will be passed as a (non-confidential)
-- @--build-arg@. Carried out so the caller can print the warning.
newtype BuildArgWarning = BuildArgSecretRef Text -- ^ the env var name
  deriving stock (Eq, Show)

-- | Pure: merge managed Build env (ConfigMap + decoded Secret) with the inline
-- DSL Build entries, returning the name-sorted build-arg list and the warnings.
--
-- Precedence (mirrors EP-23 runtime envFrom-then-env): managed first, inline DSL
-- Build env overrides it. An inline secret-ref is resolved against the managed
-- Build Secret store by the variable name; if absent there it is dropped — but
-- either way it produces a warning, because a build secret-ref passed as a
-- @--build-arg@ is not confidential.
assembleBuildArgs
  :: Map Text Text
  -- ^ managed Build ConfigMap data
  -> Map Text Text
  -- ^ managed Build Secret data (decoded)
  -> Map EnvName ScopedEnvVar
  -- ^ inline DSL env (full map; filtered to {Build} here)
  -> ([(Text, Text)], [BuildArgWarning])
assembleBuildArgs cfg sec inlineEnv = (Map.toAscList merged, warnings)
  where
    inlineBuild =
      [ (envNameText n, v)
      | (n, ScopedEnvVar v ss) <- Map.toList inlineEnv
      , Set.member Build ss
      ]
    resolved = map resolve inlineBuild
    resolve (name, v) = case v of
      EnvLiteral lit -> (name, Just lit, [])
      EnvSecretRef _sn -> case Map.lookup name sec of
        Just sv -> (name, Just sv, [BuildArgSecretRef name]) -- warn: build secret as build-arg
        Nothing -> (name, Nothing, [BuildArgSecretRef name]) -- warn + drop
    inlineMap = Map.fromList [(n, v) | (n, Just v, _) <- resolved]
    warnings = concat [w | (_, _, w) <- resolved]
    managed = Map.union sec cfg -- managed: secret values + config values
    merged = Map.union inlineMap managed -- inline overrides managed

-- | IO: read the app's managed Build stores and assemble the build args for it.
-- A missing store reads as empty (EP-24), so a never-populated Build store yields
-- no build args.
gatherBuildArgs
  :: Text
  -- ^ app name (the deploy/service name)
  -> Text
  -- ^ namespace
  -> Map EnvName ScopedEnvVar
  -- ^ inline DSL env
  -> IO ([(Text, Text)], [BuildArgWarning])
gatherBuildArgs app ns inlineEnv = do
  cfg <- either (const Map.empty) id <$> readEnvStore app ns Build
  sec <- either (const Map.empty) id <$> readSecretStore app ns Build
  pure (assembleBuildArgs cfg sec inlineEnv)

-- | Print, to stderr, the loud non-fatal warning for each build-scoped secret-ref
-- passed as a @--build-arg@.
printBuildArgWarnings :: [BuildArgWarning] -> IO ()
printBuildArgWarnings =
  mapM_ $ \(BuildArgSecretRef name) ->
    TIO.hPutStrLn
      stderr
      ( "nagarectl: WARNING: build-scoped secret '"
          <> name
          <> "' is passed to docker build as a --build-arg; build-args are visible in "
          <> "`docker history` and image metadata and are NOT confidential. For a "
          <> "confidential build secret use BuildKit (RUN --mount=type=secret)."
      )
