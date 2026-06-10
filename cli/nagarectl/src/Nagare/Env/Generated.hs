{-# LANGUAGE PackageImports #-}

-- | Deploy-time generated environment variables (EP-26).
--
-- A pure assembly of the @NAGARE_*@ variables that describe a deployment's own
-- identity (URL, name, namespace, base domain, release id, optional source).
-- They are produced as inline @{Runtime}@-scoped 'EnvLiteral' entries and merged
-- into the app's env map at the deploy call site, /before/ rendering, so they
-- render inline and override the managed @envFrom@ store (EP-23 IP3 precedence)
-- and any user variable of the same name. The @NAGARE_@ prefix is reserved.
module Nagare.Env.Generated
  ( GeneratedContext (..)
  , generatedEnv
  , mergeGenerated
  ) where

import Nagare.Dsl.Prelude

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Nagare.Dsl.Types
  ( EnvName
  , EnvVar (EnvLiteral)
  , ScopedEnvVar
  , mkEnvName
  , runtimeScoped
  )

-- | Everything the deploy step knows that the running app would otherwise have
-- to hard-code. All fields are already resolved 'Text' at the call site.
data GeneratedContext = GeneratedContext
  { serviceName :: !Text
  -- ^ The Knative Service / app name, e.g. @"notes"@.
  , namespace :: !Text
  -- ^ The Kubernetes namespace, e.g. @"personal"@.
  , serviceUrl :: !Text
  -- ^ The resolved public https URL, e.g. @"https://notes.personal.apps.example.com"@.
  , baseDomain :: !Text
  -- ^ The apps base domain, e.g. @"apps.example.com"@.
  , releaseId :: !Text
  -- ^ The image tag for this deploy, e.g. @"20260602-120000"@.
  , source :: !(Maybe Text)
  -- ^ Provenance from @--source@ (branch or commit), if the deploy carried one.
  }
  deriving stock (Generic, Eq, Show)

-- | The generated @NAGARE_*@ variables for a context, as inline @{Runtime}@
-- 'EnvLiteral' entries. @NAGARE_SOURCE@ is present only when 'source' is 'Just'.
generatedEnv :: GeneratedContext -> Map EnvName ScopedEnvVar
generatedEnv ctx =
  Map.fromList (fixed <> sourceEntry)
  where
    lit name v = (envName name, runtimeScoped (EnvLiteral v))
    fixed =
      [ lit "NAGARE_SERVICE_URL" (serviceUrl ctx)
      , lit "NAGARE_SERVICE_NAME" (serviceName ctx)
      , lit "NAGARE_NAMESPACE" (namespace ctx)
      , lit "NAGARE_BASE_DOMAIN" (baseDomain ctx)
      , lit "NAGARE_RELEASE_ID" (releaseId ctx)
      ]
    sourceEntry = case source ctx of
      Just s -> [lit "NAGARE_SOURCE" s]
      Nothing -> []

-- | Merge generated variables over an app's existing env map, generated winning
-- on key collisions (left-biased on the generated map). Reserves @NAGARE_*@.
mergeGenerated
  :: Map EnvName ScopedEnvVar
  -- ^ generated (wins)
  -> Map EnvName ScopedEnvVar
  -- ^ user / config env
  -> Map EnvName ScopedEnvVar
mergeGenerated = Map.union -- Data.Map.union is left-biased

-- | Construct an 'EnvName' from a known-valid @NAGARE_*@ literal. These names are
-- compile-time constants that 'mkEnvName' always accepts (non-empty), so a
-- failure here is a programmer error, surfaced loudly.
envName :: Text -> EnvName
envName t = either (\e -> error ("EP-26 generated env name invalid: " <> show e)) id (mkEnvName t)
