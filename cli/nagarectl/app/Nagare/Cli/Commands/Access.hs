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
  , runAccessRevoke
  , runHostGrantsList
  , runTeamMembersList
  )
import Nagare.Access.Resolve
  ( ShomeiPortalChange (EnablePortal)
  , kubectlAccessOps
  , mkBaseDomain
  , portalRegistration
  , publicHostText
  )
import Nagare.Access.Reviewed qualified as ReviewedAccess
import Nagare.Access.ShomeiUser (ShomeiUser (..), UserRef (..), lookupShomeiEmail, parseUserRef)
import Nagare.Cli.Options (AccessCommand (..), AccessGrantOpts, PortalCommand (..), TeamCommand (..), TeamMemberOpts)
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
import Nagare.Resource.Access (TeamKey, mkTeamKey, teamKeyText)
import Nagare.Target (ActiveTarget, contextNameText)
import System.Directory (doesFileExist)
import System.Environment (setEnv)

runAccess :: Maybe String -> AccessCommand -> IO ()
runAccess mctx = \case
  AccessGrant o -> grantOrRevoke True o
  AccessRevoke o -> grantOrRevoke False o
  AccessList o ->
    void $
      runHostGrantsList
        AccessListParams
          { enUrl = T.pack <$> o ^. #enUrl
          , enApiKey = T.pack <$> o ^. #enApiKey
          , host = T.pack (o ^. #host)
          , json = o ^. #json
          }
  AccessTeam (TeamAddMember o) -> membership True o
  AccessTeam (TeamRemoveMember o) -> membership False o
  AccessTeam (TeamListMembers o) -> do
    team <- teamKeyOf (o ^. #team)
    void (runTeamMembersList (T.pack <$> o ^. #enUrl) (T.pack <$> o ^. #enApiKey) (teamKeyText team) (o ^. #json))
  AccessPortal PortalShow -> do
    backends <- kubectlAccessOps ^. #loadBackends
    case portalRegistration backends of
      Nothing -> TIO.putStrLn "portal: (none; protected sites use the built-in sign-in pages)"
      Just (portalHost, entry) ->
        TIO.putStrLn ("portal: " <> publicHostText portalHost <> " -> " <> entry ^. #upstream)
  AccessPortal (PortalSync (Just output)) -> do
    active <- selectedContext "reviewed portal sync"
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
    -- Exactly one subject: a user, or a team whose members receive access.
    -- A team grant is always reviewed; the direct legacy forms remain for a
    -- user only, before inventory initialization (F97).
    grantOrRevoke :: Bool -> AccessGrantOpts -> IO ()
    grantOrRevoke granted o = case (o ^. #user, o ^. #team, o ^. #savePlan) of
      (Just _, Just _, _) -> dieT "pass exactly one of --user and --team"
      (Nothing, Nothing, _) -> dieT "pass --user EMAIL|USER_ID or --team TEAM"
      (Just rawUser, Nothing, Just output) -> runReviewed granted o rawUser output
      (Just rawUser, Nothing, Nothing) -> do
        let verb = if granted then "grant" else "revoke"
        refuseDirectLegacyOperationWhenManaged mctx ("access " <> verb) ("save the " <> (if granted then "grant" else "revocation") <> " with --save-plan DIR, then inventory apply DIR --yes")
        user <- resolveUser rawUser
        (if granted then runAccessGrant else runAccessRevoke)
          AccessGrantParams
            { enUrl = T.pack <$> o ^. #enUrl
            , enApiKey = T.pack <$> o ^. #enApiKey
            , host = T.pack (o ^. #host)
            , user = user ^. #userId
            }
      (Nothing, Just rawTeam, Just output) -> do
        when (isJust (o ^. #enUrl)) (dieT "reviewed access reaches the context's en itself; drop --en-url")
        team <- teamKeyOf rawTeam
        active <- selectedContext "reviewed access"
        ReviewedAccess.planTeamAccess
          active
          (fmap (fmap (const ())) (guardKubernetesContext active))
          (T.pack (o ^. #host))
          team
          (T.pack <$> o ^. #enApiKey)
          granted
          output
      (Nothing, Just _, Nothing) -> dieT "a team grant is always reviewed: add --save-plan DIR, then inventory apply DIR --yes"
    membership :: Bool -> TeamMemberOpts -> IO ()
    membership present o = do
      output <- maybe (dieT "team membership is always reviewed: add --save-plan DIR, then inventory apply DIR --yes") pure (o ^. #savePlan)
      team <- teamKeyOf (o ^. #team)
      user <- resolveUser (o ^. #user)
      active <- selectedContext "reviewed team membership"
      ReviewedAccess.planTeamMember
        active
        (fmap (fmap (const ())) (guardKubernetesContext active))
        team
        user
        (T.pack <$> o ^. #enApiKey)
        present
        output
    teamKeyOf :: String -> IO TeamKey
    teamKeyOf raw = either dieT pure (mkTeamKey (T.pack raw))
    runReviewed granted options rawUser output = do
      -- Reviewed grants reach the context's en through their own port-forward (F97).
      when (isJust (options ^. #enUrl)) (dieT "reviewed access reaches the context's en itself; drop --en-url")
      user <- resolveUser rawUser
      active <- selectedContext "reviewed access"
      ReviewedAccess.planAccess
        active
        (fmap (fmap (const ())) (guardKubernetesContext active))
        (T.pack (options ^. #host))
        user
        (T.pack <$> options ^. #enApiKey)
        granted
        output
    -- The selected context's kubeconfig, exported for every reviewed read and write.
    selectedContext :: Text -> IO ActiveTarget
    selectedContext purpose = do
      active <- activeTarget mctx
      selected <- kubeconfigPath (active ^. #contextName)
      exists <- doesFileExist selected
      unless exists (dieT (purpose <> " requires the selected context kubeconfig"))
      setEnv "KUBECONFIG" selected
      pure active
    -- The enforcer checks Shomei user ids; an email is resolved in the
    -- selected context's Shomei before anything is planned (F96).
    resolveUser raw = case parseUserRef (T.pack raw) of
      Left reason -> dieT reason
      Right (UserById userId) -> pure (ShomeiUser userId Nothing)
      Right (UserByEmail address) -> do
        active <- selectedContext "resolving an email"
        resolved <-
          lookupShomeiEmail
            (contextNameText (active ^. #contextName))
            (fmap (fmap (const ())) (guardKubernetesContext active))
            address
        user <- either dieT pure resolved
        TIO.putStrLn (address <> " is Shomei user " <> user ^. #userId)
        pure user
