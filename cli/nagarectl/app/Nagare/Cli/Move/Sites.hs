-- | @carry-sites@ and @verify-sites@ of a move to a new base domain (EP-246 D5). The first waits until
-- every site the manifest lists answers on its new name, then reviews the same grants on the new hosts,
-- one review at a time through the move's own identity; the second checks that every listed subject
-- gets in on each new protected host, that someone unlisted does not, and that every new name answers
-- through the edge. Old routes and grants stay until @context move retire@.
module Nagare.Cli.Move.Sites
  ( readSavedManifest
  , carrySitesStep
  , verifySitesStep
  )
where

import Control.Monad (forM)
import Data.Aeson (eitherDecodeFileStrict)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Nagare.Access.Check (CheckDecision (..), CheckReport (..), CheckResult (..))
import Nagare.Access.Reviewed (accessPlanRegistry, checkEffectiveAccess, portalSyncPending)
import Nagare.Cli.Move.Manifest (manifestFile)
import Nagare.Cli.Runtime.Cluster (withPreparedContextEnSession)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Context.BaseMove (HostKind (..), MoveManifest, MovedHost)
import Nagare.Context.Move (StepOutcome (..))
import Nagare.Context.MoveChecks (edgeAnswers)
import Nagare.Context.MoveSites
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Resource.Inventory (ScopeChange (ReplaceScope), composeInventory)
import Nagare.Target (ActiveTarget)
import System.FilePath ((</>))

-- | The manifest @context move start@ saved beside the move's reviews.
readSavedManifest :: FilePath -> IO MoveManifest
readSavedManifest directory =
  eitherDecodeFileStrict (directory </> manifestFile) >>= either (\reason -> dieT ("the move's manifest is unreadable: " <> T.pack reason)) pure

-- | @reviewWith plan@ runs one review step whose next review @plan identity directory@ saves, returning
-- 'False' when nothing is left to review.
carrySitesStep :: ActiveTarget -> MoveManifest -> ((Text -> FilePath -> IO Bool) -> IO StepOutcome) -> IO StepOutcome
carrySitesStep active manifest reviewWith = do
  snapshot <- Inventory.loadTargetSnapshot active
  case siteProgress snapshot (manifest ^. #hosts) of
    Left reason -> pure (StepRefused reason)
    Right progress
      | not (null (progress ^. #unrouted)) -> pure (StepWaiting (renderUnrouted (manifest ^. #newBase) (progress ^. #unrouted)))
      | otherwise -> do
          -- Shomei and the enforcer read the portal's settings only at startup: until a sync rolls them,
          -- sign-in and new passkeys still expect the old auth host.
          pending <- portalSyncPending active
          if pending
            then pure (StepWaiting portalSyncNeeded)
            else reviewWith planGrants
  where
    planGrants identity directory = do
      snapshot <- Inventory.loadTargetSnapshot active
      progress <- either dieT pure (siteProgress snapshot (manifest ^. #hosts))
      case progress ^. #grants of
        [] -> pure False
        first' : rest -> do
          candidate <- either (dieT . T.pack . show) pure (composeInventory snapshot (ReplaceScope first' :| map ReplaceScope rest))
          withPreparedContextEnSession active $ \en ->
            Inventory.planInventoryCandidateWithPayloadIdentity (accessPlanRegistry active en) identity active candidate directory
          pure True

portalSyncNeeded :: Text
portalSyncNeeded =
  "every site answers on its new name; roll Shomei and the access enforcer onto the auth portal's new host, then run apply again:\n  nagarectl access portal sync --save-plan DIR\n  nagarectl inventory apply DIR --yes"

-- | A subject no grant names: En must deny it everywhere.
unlisted :: Text
unlisted = "user_00000000000000000000000000"

verifySitesStep :: ActiveTarget -> MoveManifest -> ([Text] -> IO [(Text, Maybe Bool)]) -> IO StepOutcome
verifySitesStep active manifest probe = do
  let protectedHosts = [h | h <- manifest ^. #hosts, h ^. #protected, h ^. #kind /= AuthPortalHost]
  failures <-
    withPreparedContextEnSession active $ \en ->
      concat <$> forM protectedHosts (\h -> hostFailures en h)
  if not (null failures)
    then pure (StepRefused ("access on the new names differs from the old: " <> T.intercalate "; " failures))
    else edgeAnswers <$> probe [h ^. #newName | h <- manifest ^. #hosts]
  where
    hostFailures en (h :: MovedHost) = do
      granted <- forM (h ^. #users) $ \user -> decision en (h ^. #newName) user
      refused <- decision en (h ^. #newName) unlisted
      pure $
        [h ^. #newName <> " does not admit " <> user | (user, answer) <- zip (h ^. #users) granted, answer /= Just CheckAllowed]
          <> [h ^. #newName <> " admits a subject no grant names" | refused /= Just CheckDenied]
    decision en host subject = do
      report <- checkEffectiveAccess active en host subject Nothing
      pure $ case report ^. #result of
        Decided {decision = d} -> Just d
        Unavailable _ -> Nothing
