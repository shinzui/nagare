-- | Application / Config. Executable-private CLI boundary.
module Nagare.Cli.Application.Config
  ( appNamespace
  , resolveAppOrDie
  , resolveStorageDep
  , siteConfigIdentity
  , siteIdentityOrDie
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Cli.Options (StoreCommonOpts (..))
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Prelude
import Nagare.Dsl.Static.Types (siteNameText)
import Nagare.Dsl.Types
  ( Deployment
  , namespaceText
  , serviceNameText
  )

-- | The (name, namespace) of either site kind.
siteConfigIdentity :: Load.SiteConfig -> (Text, Text)
siteConfigIdentity (Load.SiteStatic s) =
  (siteNameText (s ^. #name), namespaceText (s ^. #namespace))
siteConfigIdentity (Load.SiteServer s) =
  (siteNameText (s ^. #name), namespaceText (s ^. #namespace))

-- | Load a site of either kind and return its (name, namespace).
siteIdentityOrDie :: FilePath -> IO (Text, Text)
siteIdentityOrDie file = do
  esite <- Load.loadSite file
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right sc -> pure (siteConfigIdentity sc)

-- | Resolve the namespace for an @app@ command: the @-n@ value, or @personal@.
appNamespace :: Maybe String -> Text
appNamespace = maybe "personal" T.pack

-- ---------------------------------------------------------------------------
-- env / secret handlers (EP-25)

-- | Resolve @(name, namespace)@ from a Deployment, aggregate Application,
-- StaticSite, or ServerSite. Each loader identifies its own typed config kind.
--
-- (Distinct from 'Nagare.App.appIdentityOrDie', which is Deployment-only and is
-- the IP2 helper the @app@/@deployments@ commands use. This site-aware resolver
-- is the env/secret path, which must accept site configs too.)
configIdentityOrDie :: FilePath -> IO (Text, Text)
configIdentityOrDie file = do
  edep <- Load.loadDeployment file
  case edep of
    Right dep ->
      pure (serviceNameText (dep ^. #name), namespaceText (dep ^. #namespace))
    Left (Load.UnexpectedKind _ _) -> do
      application <- Load.loadApplication file
      case application of
        Right app -> pure (serviceNameText (app ^. #name), namespaceText (app ^. #namespace))
        Left (Load.UnexpectedKind _ _) -> siteIdentityOrDie file
        Left err -> dieT (Load.renderLoadError err)
    Left err -> dieT (Load.renderLoadError err)

-- | Resolve @(name, namespace)@ from the loaded config and reconcile it against
-- the positional @APP@: the config's name is authoritative; a mismatch is a hard
-- error so the operator is told rather than silently surprised.
resolveAppOrDie :: StoreCommonOpts -> IO (Text, Text)
resolveAppOrDie copts = do
  provisionGhcEnv (copts ^. #ghcEnv)
  (name, ns) <- configIdentityOrDie (copts ^. #file)
  let typed = T.pack (copts ^. #app)
  if typed /= name
    then
      dieT
        ( "config names app '"
            <> name
            <> "' but the command names '"
            <> typed
            <> "'; they must match (the config's name is what the Service references)"
        )
    else pure (name, ns)

-- | Load the app's typed config for the @storage@ commands and verify the
-- positional @APP@ matches the config's name (mirrors 'resolveAppOrDie' but
-- returns the full 'Deployment' so the declared volumes are available to
-- 'runStorageList'/'runStorageInspect'). EP-35.
resolveStorageDep :: StoreCommonOpts -> IO Deployment
resolveStorageDep copts = do
  provisionGhcEnv (copts ^. #ghcEnv)
  edep <- Load.loadDeployment (copts ^. #file)
  dep <- case edep of
    Left err -> dieT (Load.renderLoadError err)
    Right d -> pure d
  let typed = T.pack (copts ^. #app)
      name = serviceNameText (dep ^. #name)
  if typed /= name
    then
      dieT
        ( "config names app '"
            <> name
            <> "' but the command names '"
            <> typed
            <> "'; they must match (the config's name is what the Service references)"
        )
    else pure dep
