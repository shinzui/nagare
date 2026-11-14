-- | Commands / EnTenant (EP-262 M4). Executable-private CLI boundary.
--
-- @en-tenant bind@ copies an operator-declared tenant's generated keys from
-- @nagare-en-tenant-<name>-keys@ in @nagare-system@ into an app's managed runtime
-- Secret, as one reviewed Secret change through the writer @secret set@ uses.
-- No key reaches stdout or stderr. Only an operator can read the tenant's
-- Secret; a delegated deployer is told so.
module Nagare.Cli.Commands.EnTenant
  ( runEnTenant
  )
where

import Data.Aeson (Value, eitherDecodeStrict)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cli.Application.Config (resolveAppOrDie)
import Nagare.Cli.Commands.Environment (saveReviewedSecretChange)
import Nagare.Cli.Options (EnTenantCommand (..), ScopeSelection (..))
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.AuthTenants (enTenantKeySecret, tenantKeyBinding)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), invokeKubectl)
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (contextNameText)
import Nagare.Target.EnTenants (enTenantNameText, mkEnTenantName)
import System.Exit (ExitCode (..))

runEnTenant :: Maybe String -> EnTenantCommand -> IO ()
runEnTenant mctx = \case
  EnTenantBind rawTenant copts readWriteAs readOnlyAs rawVersion savePlan -> do
    tenant <- either dieT pure (mkEnTenantName (T.pack rawTenant))
    (name, ns) <- resolveAppOrDie copts
    unless
      (T.pack (copts ^. #app) == name)
      (dieT ("--app names " <> T.pack (copts ^. #app) <> " but " <> T.pack (copts ^. #file) <> " declares " <> name))
    version <-
      maybe
        (dieT "en-tenant bind is a reviewed Secret change and requires --version")
        (either dieT pure . Resource.mkName . T.pack)
        rawVersion
    active <- activeTarget mctx
    unless
      (tenant `elem` map (^. #name) (active ^. #profile . #enTenants))
      (dieT ("En tenant " <> enTenantNameText tenant <> " is not in the active context's NAGARE_EN_TENANTS"))
    context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
    let config = KubernetesRuntimeConfig context (contextNameText (active ^. #contextName)) (fmap (fmap (const ())) (guardKubernetesContext active))
    guarded <- runtimeGuard config
    either (dieT . ("cluster guard refused: " <>)) pure guarded
    let secretName = enTenantKeySecret tenant
    answered <- invokeKubectl config ["get", "secret", T.unpack secretName, "-n", "nagare-system", "-o", "json"] ""
    secret <- case answered of
      Right (ExitSuccess, output, _) ->
        either (const (dieT (secretName <> " is malformed"))) pure (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)) :: Either String Value)
      Right (ExitFailure _, _, errors)
        | "forbidden" `T.isInfixOf` T.toLower (T.pack errors) ->
            dieT ("this identity cannot read " <> secretName <> " in nagare-system; only the operator can bind an En tenant's keys (a delegated deployer cannot read Secrets there)")
        | "notfound" `T.isInfixOf` T.toLower (T.filter (/= ' ') (T.pack errors)) ->
            dieT (secretName <> " does not exist yet; plan and apply the platform with the tenant declared first")
      _ -> dieT ("could not read " <> secretName <> " in nagare-system")
    additions <- either dieT pure (tenantKeyBinding tenant secret (T.pack <$> readWriteAs) (T.pack <$> readOnlyAs))
    saveReviewedSecretChange
      mctx
      name
      ns
      (ScopeSelection True False False)
      ("en-tenant bind " <> enTenantNameText tenant)
      version
      (Right . Map.union additions)
      savePlan
