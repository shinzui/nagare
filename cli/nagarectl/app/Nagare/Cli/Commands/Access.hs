-- | Commands / Access. Executable-private CLI boundary.
module Nagare.Cli.Commands.Access
  ( runAccess
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Access.Grants
  ( AccessGrantParams (..)
  , AccessListParams (..)
  , runAccessGrant
  , runAccessList
  , runAccessRevoke
  )
import Nagare.Access.Resolve
  ( ShomeiPortalChange (EnablePortal)
  , kubectlAccessOps
  , mkBaseDomain
  , portalRegistration
  , publicHostText
  )
import Nagare.Access.Reviewed qualified as ReviewedAccess
import Nagare.Cli.Options (AccessCommand (..), PortalCommand (..))
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Ownership
  ( refuseDirectAccessOwnerIfManaged
  , refuseDirectLegacyOperationWhenManaged
  )
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolveBaseDomain
  )
import Nagare.Cluster.Kubeconfig (kubeconfigPath)
import Nagare.Dsl.Prelude
import System.Directory (doesFileExist)
import System.Environment (setEnv)

runAccess :: Maybe String -> AccessCommand -> IO ()
runAccess mctx = \case
  AccessGrant o | Just output <- o ^. #savePlan -> runReviewed True o output
  AccessRevoke o | Just output <- o ^. #savePlan -> runReviewed False o output
  AccessGrant o -> do
    refuseDirectLegacyOperationWhenManaged mctx "access grant" "save the grant with --save-plan DIR, then inventory apply DIR --yes"
    runAccessGrant
      AccessGrantParams
        { enUrl = T.pack <$> o ^. #enUrl
        , enApiKey = T.pack <$> o ^. #enApiKey
        , host = T.pack (o ^. #host)
        , user = T.pack (o ^. #user)
        }
  AccessRevoke o -> do
    refuseDirectLegacyOperationWhenManaged mctx "access revoke" "save the revocation with --save-plan DIR, then inventory apply DIR --yes"
    runAccessRevoke
      AccessGrantParams
        { enUrl = T.pack <$> o ^. #enUrl
        , enApiKey = T.pack <$> o ^. #enApiKey
        , host = T.pack (o ^. #host)
        , user = T.pack (o ^. #user)
        }
  AccessList o ->
    void $
      runAccessList
        AccessListParams
          { enUrl = T.pack <$> o ^. #enUrl
          , enApiKey = T.pack <$> o ^. #enApiKey
          , host = T.pack (o ^. #host)
          }
  AccessPortal PortalShow -> do
    backends <- kubectlAccessOps ^. #loadBackends
    case portalRegistration backends of
      Nothing -> TIO.putStrLn "portal: (none; protected sites use the built-in sign-in pages)"
      Just (portalHost, entry) ->
        TIO.putStrLn ("portal: " <> publicHostText portalHost <> " -> " <> entry ^. #upstream)
  AccessPortal (PortalSync (Just output)) -> do
    active <- activeTarget mctx
    selected <- kubeconfigPath (active ^. #contextName)
    exists <- doesFileExist selected
    unless exists (dieT "reviewed portal sync requires the selected context kubeconfig")
    setEnv "KUBECONFIG" selected
    ReviewedAccess.planPortalSync
      active
      (fmap (fmap (const ())) (guardKubernetesContext active))
      output
  AccessPortal (PortalSync Nothing) -> do
    refuseDirectLegacyOperationWhenManaged mctx "access portal sync" "save synchronization with --save-plan DIR, then inventory apply DIR --yes"
    backends <- kubectlAccessOps ^. #loadBackends
    case portalRegistration backends of
      Nothing -> TIO.putStrLn "no portal registered"
      Just (portalHost, _) -> do
        refuseDirectAccessOwnerIfManaged mctx "access portal sync"
        rawBase <- resolveBaseDomain mctx Nothing
        base <- either dieT pure (mkBaseDomain rawBase)
        (kubectlAccessOps ^. #applyShomeiPortal) (EnablePortal portalHost base)
        TIO.putStrLn ("synchronized portal: " <> publicHostText portalHost)
  where
    runReviewed granted options output = do
      active <- activeTarget mctx
      selected <- kubeconfigPath (active ^. #contextName)
      exists <- doesFileExist selected
      unless exists (dieT "reviewed access requires the selected context kubeconfig")
      setEnv "KUBECONFIG" selected
      ReviewedAccess.planAccess
        active
        (fmap (fmap (const ())) (guardKubernetesContext active))
        (T.pack (options ^. #host))
        (T.pack (options ^. #user))
        (T.pack <$> options ^. #enUrl)
        (T.pack <$> options ^. #enApiKey)
        granted
        output
