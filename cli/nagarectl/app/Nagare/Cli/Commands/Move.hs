-- | @nagarectl context move@ (EP-243): open a move of a direct context onto the tunnel, run or resume
-- its steps, report where it stands, and roll it back. The steps and their order live in
-- 'Nagare.Context.Move'; the open move lives in the inventory head ('Nagare.Context.MoveStore').
module Nagare.Cli.Commands.Move (runContextMove) where

import Data.Foldable (forM_)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Nagare.Cli.Options.Move (MoveCommand (..))
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Context.Move
import Nagare.Context.MoveStore
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Store (InventoryStore)
import Nagare.Inventory.Store.Manifest (MoveMarker (..))
import Nagare.Target (ActiveTarget, IngressMode (..), Mode (Cloud))

-- | The kind of move EP-243 runs; EP-246 adds another.
ingressMove :: Text
ingressMove = "ingress"

runContextMove :: Maybe String -> MoveCommand -> IO ()
runContextMove mctx command = do
  active <- activeTarget mctx
  case command of
    MoveStatus -> withStore active >>= status
    MoveStart -> start active
    MoveApply yes -> requireYes yes "context move apply" >> proceed active runMove
    MoveRollback yes -> requireYes yes "context move rollback" >> proceed active rollbackMove

start :: ActiveTarget -> IO ()
start active = do
  let profile = active ^. #profile
  unless (profile ^. #mode == Cloud) (dieT "a context move needs a cloud context")
  unless (profile ^. #ingress == IngressDirect) (dieT "this context already serves through the tunnel")
  store <- withStore active
  now <- T.pack . iso8601Show <$> getCurrentTime
  marker <- openMove store ingressMove now (profile ^. #baseDomain) sameDomainSteps >>= either dieT pure
  TIO.putStrLn ("Opened a move of " <> profile ^. #baseDomain <> " onto the Cloudflare Tunnel, started " <> moveStartedAt marker <> ".")
  TIO.putStrLn "Run `nagarectl context move apply --yes` to run its steps; it stops whenever you have something to do."

status :: InventoryStore -> IO ()
status store =
  openMoveOf store >>= either dieT pure >>= \case
    Nothing -> TIO.putStrLn "No context move is open."
    Just marker -> do
      let progress = moveProgress marker
      TIO.putStrLn (moveKind marker <> " move, started " <> moveStartedAt marker <> ", " <> directionText (progress ^. #direction))
      TIO.putStrLn (T.pack (show (progress ^. #completed)) <> " of " <> T.pack (show (length (progress ^. #steps))) <> " steps done")
      forM_ (progress ^. #inProgress) $ \step -> TIO.putStrLn ("In progress: " <> moveStepToken step)
      TIO.putStrLn ("Left: " <> T.intercalate ", " (map moveStepToken (remainingSteps progress)))
  where
    directionText = \case
      MovingForward -> "moving forward"
      RollingBack -> "rolling back"

proceed :: ActiveTarget -> (MoveOps IO -> MoveRecord -> IO (MoveResult, MoveRecord)) -> IO ()
proceed active run = do
  store <- withStore active
  marker <- openMoveOf store >>= either dieT pure >>= maybe (dieT "no context move is open; start one with `nagarectl context move start`") pure
  (result, _) <- run (moveOps store) (moveProgress marker)
  case result of
    MoveFinished -> closeMove store >>= either dieT pure >> TIO.putStrLn "Every step is done; the move is closed."
    MoveRolledBack -> closeMove store >>= either dieT pure >> TIO.putStrLn "Every completed step is undone; the move is closed."
    MoveStopped step (StepWaiting reason) -> TIO.putStrLn ("Waiting at " <> moveStepToken step <> ": " <> reason <> "\nRun the same command again when that is done.")
    MoveStopped step (StepRefused reason) -> dieT ("Refused at " <> moveStepToken step <> ": " <> reason)
    MoveStopped step StepCompleted -> dieT ("stopped after completing " <> moveStepToken step)
    MoveRefused reason -> dieT reason

-- | The production operations. Each step that is not wired yet refuses by name, so a move never
-- advances past work this nagarectl cannot do.
moveOps :: InventoryStore -> MoveOps IO
moveOps store =
  MoveOps
    { performStep = \direction step -> pure (StepRefused (verb direction <> moveStepToken step <> " is not implemented by this nagarectl yet"))
    , saveMove = \record -> saveMoveProgress store record >>= either dieT pure
    }
  where
    verb = \case
      MovingForward -> ""
      RollingBack -> "undoing "

withStore :: ActiveTarget -> IO InventoryStore
withStore = Inventory.openTargetStore

requireYes :: Bool -> Text -> IO ()
requireYes yes name = unless yes (dieT (name <> " changes the context; pass --yes"))
