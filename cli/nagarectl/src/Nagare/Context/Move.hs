-- | The step engine of @nagarectl context move@ (EP-243 D3, D5; EP-246 adds a second step list).
--
-- A move is a fixed list of named steps. Each step either completes, waits for something outside
-- Nagare (the operator's name server change, an old TTL), or refuses, and the engine records its
-- intent before acting and its completion after, so a crash between the two re-runs the step,
-- which observes before it acts. The engine never advances past a step that did not complete.
-- Rollback runs the inverses of the completed steps in reverse order; by the order of
-- 'sameDomainSteps' that reopens the firewall and restores the LoadBalancer before records move
-- back. Every provider effect is an ordinary reviewed inventory transaction run by the operations
-- record; this module only sequences them, so interpreter tests drive it with a modelled world
-- (ADR 25).
module Nagare.Context.Move
  ( MoveStep (..)
  , MoveDirection (..)
  , MoveRecord (..)
  , StepOutcome (..)
  , MoveOps (..)
  , MoveResult (..)
  , sameDomainSteps
  , baseDomainSteps
  , hasInverse
  , newMove
  , runMove
  , rollbackMove
  , remainingSteps
  , moveStepToken
  , parseMoveStep
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))

data MoveStep
  = -- | No mutation: an idle ledger, no DS record for the domain at its parent, no origin
    -- certificate inside its renewal window, a working Cloudflare token.
    CheckPreconditions
  | -- | The Cloudflare zone mirrors Cloud DNS: DNS-only A records for the apex and the wildcard,
    -- pointing at the VM, so traffic keeps flowing directly once the name servers change.
    MirrorZone
  | -- | Wait until Cloudflare reports the zone active after the operator's name server change.
    AwaitNameServers
  | -- | DNSSEC on at Cloudflare; its DS record is handed to the operator.
    EnableDnssec
  | -- | Sites still answer directly through the mirrored records.
    ConfirmDirect
  | -- | The connector runs beside direct ingress; @kourier@ stays a LoadBalancer.
    StartConnector
  | -- | D11: routes and grants re-declared for the flattened names, beside the old ones.
    CarryHostnames
  | -- | The zone's records become proxied CNAMEs to the tunnel.
    SwitchRecords
  | -- | Every hostname answers through the edge.
    VerifyTunnel
  | -- | Wait out the mirrored records' TTL since the switch, so no resolver still sends visitors to the VM.
    AwaitOldTtl
  | -- | The three internet-facing rules are collected; IAP SSH stays.
    CloseFirewall
  | -- | @kourier@ becomes @ClusterIP@, so ServiceLB binds no host port.
    CloseKourier
  | -- | The profile records the tunnel and the retained Cloud DNS name; the move closes.
    CommitMove
  | -- | EP-246: the new base's Cloudflare zone, its tunnel and proxied records; old names still serve.
    CreateZone
  | -- | EP-246 D2, D3: the profile takes the new base, ingress and origin TLS together, and the platform
    -- follows; the sign-in outage starts here. Cloud DNS keeps the old name.
    FlipBase
  | -- | EP-246 D4: passkeys bound to the old domain are exported, then removed.
    RemovePasskeys
  | -- | EP-246 D5: every site answers on its new name with its grants, old routes and grants kept.
    CarrySites
  | -- | EP-246: the new names serve and every listed subject still gets in; the outage ends.
    VerifySites
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

-- | EP-243's move on the same base domain, in the order of its D3.
sameDomainSteps :: [MoveStep]
sameDomainSteps =
  [ CheckPreconditions
  , MirrorZone
  , AwaitNameServers
  , EnableDnssec
  , ConfirmDirect
  , StartConnector
  , CarryHostnames
  , SwitchRecords
  , VerifyTunnel
  , AwaitOldTtl
  , CloseFirewall
  , CloseKourier
  , CommitMove
  ]

-- | EP-246's move to a new base domain on a zone that is already active: no name server change, no
-- DNS-only mirror and no old TTL to outlast, so the zone and connector come first, then one cutover.
baseDomainSteps :: [MoveStep]
baseDomainSteps =
  [ CheckPreconditions
  , CreateZone
  , EnableDnssec
  , StartConnector
  , FlipBase
  , RemovePasskeys
  , CarrySites
  , VerifySites
  , CloseFirewall
  , CloseKourier
  , CommitMove
  ]

-- | Steps that change something have an inverse; observation and waiting steps do not, and
-- 'CommitMove' closes the move, after which rollback is a new move.
hasInverse :: MoveStep -> Bool
hasInverse = \case
  MirrorZone -> True
  EnableDnssec -> True
  StartConnector -> True
  CarryHostnames -> True
  SwitchRecords -> True
  CloseFirewall -> True
  CloseKourier -> True
  CreateZone -> True
  FlipBase -> True
  RemovePasskeys -> True
  CarrySites -> True
  _ -> False

data MoveDirection = MovingForward | RollingBack
  deriving stock (Eq, Show, Generic)

-- | What the head marker holds: the step list, how many steps completed, the step whose intent
-- was recorded and whose completion was not, and the direction.
data MoveRecord = MoveRecord
  { steps :: ![MoveStep]
  , completed :: !Int
  , inProgress :: !(Maybe MoveStep)
  , direction :: !MoveDirection
  }
  deriving stock (Eq, Show, Generic)

data StepOutcome
  = StepCompleted
  | -- | Something outside Nagare must happen first; the text says what.
    StepWaiting !Text
  | StepRefused !Text
  deriving stock (Eq, Show)

-- | @performStep@ runs a step forward or its inverse back. It must be idempotent: it observes the
-- world before acting, because a crash after its effect re-runs it.
data MoveOps m = MoveOps
  { performStep :: !(MoveDirection -> MoveStep -> m StepOutcome)
  , saveMove :: !(MoveRecord -> m ())
  }

data MoveResult
  = MoveFinished
  | MoveRolledBack
  | MoveStopped !MoveStep !StepOutcome
  | MoveRefused !Text
  deriving stock (Eq, Show)

newMove :: [MoveStep] -> MoveRecord
newMove list = MoveRecord {steps = list, completed = 0, inProgress = Nothing, direction = MovingForward}

-- | The steps still to run in the record's direction, nearest first.
remainingSteps :: MoveRecord -> [MoveStep]
remainingSteps record = case record ^. #direction of
  MovingForward -> drop (record ^. #completed) (record ^. #steps)
  RollingBack -> filter hasInverse (reverse (take (record ^. #completed) (record ^. #steps)))

runMove :: (Monad m) => MoveOps m -> MoveRecord -> m (MoveResult, MoveRecord)
runMove ops record
  | record ^. #direction == RollingBack = pure (MoveRefused "this move is rolling back; continue with rollback", record)
  | otherwise = case drop (record ^. #completed) (record ^. #steps) of
      [] -> pure (MoveFinished, record)
      step : _ -> do
        let started = record & #inProgress .~ Just step
        saveMove ops started
        outcome <- performStep ops MovingForward step
        case outcome of
          StepCompleted -> do
            let done = started & #completed %~ (+ 1) & #inProgress .~ Nothing
            saveMove ops done
            runMove ops done
          _ -> pure (MoveStopped step outcome, started)

-- | Undo the completed steps, newest first. A completed 'CommitMove' closes the move, so it refuses.
rollbackMove :: (Monad m) => MoveOps m -> MoveRecord -> m (MoveResult, MoveRecord)
rollbackMove ops record
  | CommitMove `elem` take (record ^. #completed) (record ^. #steps) =
      pure (MoveRefused "the move is committed; moving back is a new move", record)
  | record ^. #direction == RollingBack = go record
  | otherwise = do
      -- A forward step stopped after its intent may have taken effect, so it counts as completed and
      -- its inverse, which observes first, runs before the others.
      let started = maybe 0 (\step -> if hasInverse step then 1 else 0) (record ^. #inProgress)
          turning = record & #direction .~ RollingBack & #completed %~ (+ started) & #inProgress .~ Nothing
      saveMove ops turning
      go turning
  where
    go current
      | current ^. #completed == 0 = do
          let finished = current & #inProgress .~ Nothing
          saveMove ops finished
          pure (MoveRolledBack, finished)
      | otherwise = do
          let step = (current ^. #steps) !! (current ^. #completed - 1)
              undone = current & #completed %~ subtract 1 & #inProgress .~ Nothing
          if not (hasInverse step)
            then saveMove ops undone >> go undone
            else do
              let started = current & #inProgress .~ Just step
              saveMove ops started
              outcome <- performStep ops RollingBack step
              case outcome of
                StepCompleted -> saveMove ops undone >> go undone
                _ -> pure (MoveStopped step outcome, started)

-- | The stable name of a step in the head marker and in review identities.
moveStepToken :: MoveStep -> Text
moveStepToken = \case
  CheckPreconditions -> "check-preconditions"
  MirrorZone -> "mirror-zone"
  AwaitNameServers -> "await-name-servers"
  EnableDnssec -> "enable-dnssec"
  ConfirmDirect -> "confirm-direct"
  StartConnector -> "start-connector"
  CarryHostnames -> "carry-hostnames"
  SwitchRecords -> "switch-records"
  VerifyTunnel -> "verify-tunnel"
  AwaitOldTtl -> "await-old-ttl"
  CloseFirewall -> "close-firewall"
  CloseKourier -> "close-kourier"
  CommitMove -> "commit-move"
  CreateZone -> "create-zone"
  FlipBase -> "flip-base"
  RemovePasskeys -> "remove-passkeys"
  CarrySites -> "carry-sites"
  VerifySites -> "verify-sites"

parseMoveStep :: Text -> Maybe MoveStep
parseMoveStep token = lookup token [(moveStepToken step, step) | step <- [minBound .. maxBound]]

instance ToJSON MoveStep where
  toJSON = toJSON . moveStepToken

instance FromJSON MoveStep where
  parseJSON = withText "MoveStep" $ \token -> maybe (fail ("unknown move step " <> T.unpack token)) pure (parseMoveStep token)

instance ToJSON MoveDirection where
  toJSON = \case
    MovingForward -> "forward"
    RollingBack -> "rollback"

instance FromJSON MoveDirection where
  parseJSON = withText "MoveDirection" $ \case
    "forward" -> pure MovingForward
    "rollback" -> pure RollingBack
    other -> fail ("unknown move direction " <> T.unpack other)

instance ToJSON MoveRecord where
  toJSON record =
    object
      [ "steps" .= (record ^. #steps)
      , "completed" .= (record ^. #completed)
      , "inProgress" .= (record ^. #inProgress)
      , "direction" .= (record ^. #direction)
      ]

-- | Strict: an unknown field, a negative or overlong count, or a step in progress that is not the
-- next one in its direction refuses, so a head written by a newer CLI never half-decodes.
instance FromJSON MoveRecord where
  parseJSON = withObject "MoveRecord" $ \o -> do
    unless (all (`elem` ["steps", "completed", "inProgress", "direction"]) (KM.keys o)) (fail "move record has an unknown field")
    record <- MoveRecord <$> o .: "steps" <*> o .: "completed" <*> o .: "inProgress" <*> o .: "direction"
    let count = record ^. #completed
    when (count < 0 || count > length (record ^. #steps)) (fail "move record counts steps it does not have")
    case record ^. #inProgress of
      Just step
        | record ^. #direction == MovingForward && Just step /= listToMaybe (drop count (record ^. #steps)) ->
            fail "move record's step in progress is not the next forward step"
        | record ^. #direction == RollingBack && Just step /= listToMaybe (drop (count - 1) (record ^. #steps)) ->
            fail "move record's step in progress is not the next step to undo"
      _ -> pure ()
    pure record
