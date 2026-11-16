-- | The steps of a move to a new base domain (EP-246), over the review, commit and observation
-- operations @nagarectl context move@ already has for EP-243's move. Only what differs lives here: the
-- flip writes the profile and stops for the shell to reload, the passkeys are exported and restored,
-- and the sites carry over one by one.
module Nagare.Cli.Move.BaseSteps
  ( BaseStepOps (..)
  , performBase
  )
where

import Data.Generics.Labels ()
import Data.Text.IO qualified as TIO
import Nagare.Cli.Move.Passkeys (removePasskeys, restorePasskeys)
import Nagare.Cli.Runtime.Context (writeContextProfile)
import Nagare.Context.BaseFlip (flippedProfile, profileFlipped, restoredProfile)
import Nagare.Context.Move
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store.Manifest (MoveMarker (..))
import Nagare.Target (ActiveTarget, validateIngressMode)

data BaseStepOps = BaseStepOps
  { reviewIt :: !(MoveDirection -> MoveStep -> IO StepOutcome)
  -- ^ Apply the step's saved review and plan the next, as every EP-243 review step does.
  , commit :: !(IO StepOutcome)
  -- ^ EP-243's commit: the web rules' retirement and collection.
  , tokenSaved :: !(IO StepOutcome)
  , precheck :: !(IO StepOutcome)
  , dnssecActive :: !(IO StepOutcome)
  , carrySites :: !(IO StepOutcome)
  , verifySites :: !(IO StepOutcome)
  }
  deriving stock (Generic)

performBase :: ActiveTarget -> MoveMarker -> BaseStepOps -> MoveDirection -> MoveStep -> IO StepOutcome
performBase active marker ops direction step = case (direction, step) of
  (MovingForward, CheckPreconditions) -> ops ^. #precheck
  (MovingForward, EnableDnssec) -> ops ^. #dnssecActive
  (MovingForward, StartConnector) -> guarded (ops ^. #tokenSaved) (reviewed MovingForward StartConnector)
  (MovingForward, FlipBase)
    | profileFlipped marker profile -> reviewed MovingForward FlipBase
    | otherwise -> writeProfile (flippedProfile marker profile) "the new base"
  (MovingForward, RemovePasskeys) -> removePasskeys active
  (MovingForward, CarrySites) -> ops ^. #carrySites
  (MovingForward, VerifySites) -> ops ^. #verifySites
  (MovingForward, CommitMove) -> ops ^. #commit
  (MovingForward, other) -> reviewed MovingForward other
  -- The new zone keeps DNSSEC, and the old routes and grants were never touched.
  (RollingBack, EnableDnssec) -> pure StepCompleted
  (RollingBack, CarrySites) -> pure StepCompleted
  (RollingBack, RemovePasskeys) -> restorePasskeys active
  (RollingBack, FlipBase)
    | profileFlipped marker profile -> writeProfile (restoredProfile marker profile) "the old base"
    | otherwise -> reviewed RollingBack FlipBase
  (RollingBack, other) -> reviewed RollingBack other
  where
    profile = active ^. #profile
    reviewed = ops ^. #reviewIt
    -- The profile is the context file; a shell that exported the old values keeps them until it reloads,
    -- and the environment wins over the file, so the step stops here and the next run plans the platform.
    writeProfile next label =
      case validateIngressMode next of
        Left reason -> pure (StepRefused reason)
        Right () -> do
          writeContextProfile (active ^. #contextName) next
          TIO.putStrLn ("Wrote the context profile for " <> label <> ": NAGARE_BASE_DOMAIN=" <> next ^. #baseDomain <> ".")
          pure
            ( StepWaiting
                "reload the shell's environment (direnv reload) so it exports the profile just written, then run the same command again to plan the platform"
            )
    guarded check next =
      check >>= \case
        StepCompleted -> next
        other -> pure other
