-- | What a context's ingress looks like to the planner (EP-243, ADR 34). A direct context and a
-- tunnel context are the two ends; an open move sits between them, one step at a time, so each
-- stage plans exactly the part its step changes. Every planner switch that used to compare
-- @NAGARE_INGRESS@ reads this instead.
module Nagare.Context.Posture
  ( ZoneRecords (..)
  , WebRules (..)
  , IngressPosture (..)
  , directPosture
  , tunnelPosture
  , postureFor
  , stepsInEffect
  )
where

import Data.Generics.Labels ()
import Nagare.Context.Move
import Nagare.Dsl.Prelude
import Nagare.Target.Kinds (IngressMode (..))

-- | The zone's apex and wildcard records: DNS-only A records to the VM while a move mirrors Cloud
-- DNS, or proxied CNAMEs to the tunnel.
data ZoneRecords = MirrorRecords | TunnelRecords
  deriving stock (Eq, Show)

-- | The three internet-facing firewall rules: open, disabled in place while a move can still roll back
-- (a collected identity can never be declared again), or absent once the move commits.
data WebRules = WebRulesOpen | WebRulesDisabled | WebRulesAbsent
  deriving stock (Eq, Show)

data IngressPosture = IngressPosture
  { zoneRecords :: !(Maybe ZoneRecords)
  -- ^ Whether the Cloudflare zone scope exists, and what its records point at.
  , connectorRunning :: !Bool
  -- ^ The connector scope, and the gateway's edge headers that go with it.
  , flatHosts :: !Bool
  -- ^ Default names one label below the base (@<name>-<namespace>.<base>@).
  , webRules :: !WebRules
  -- ^ The internet-facing firewall rules.
  , kourierClosed :: !Bool
  -- ^ @kourier@ is @ClusterIP@ and no DNS-01 issuer is installed.
  }
  deriving stock (Eq, Show, Generic)

directPosture, tunnelPosture :: IngressPosture
directPosture = IngressPosture Nothing False False WebRulesOpen False
tunnelPosture = IngressPosture (Just TunnelRecords) True True WebRulesAbsent True

-- | The steps whose effect the next plan must hold: the completed ones, plus a step being planned
-- forward, minus a step being undone.
stepsInEffect :: MoveRecord -> [MoveStep]
stepsInEffect record = case (record ^. #direction, record ^. #inProgress) of
  (MovingForward, Just step) -> done <> [step]
  (RollingBack, Just step) -> filter (/= step) done
  _ -> done
  where
    done = take (record ^. #completed) (record ^. #steps)

-- | The posture of a context: its profile's ingress when no move is open, otherwise the direct
-- posture with each step in effect applied. The commit is the exception: it takes effect only once
-- complete, because its own reviews retire and collect the rules from a scope that still declares
-- them disabled.
postureFor :: IngressMode -> Maybe MoveRecord -> IngressPosture
postureFor ingress = \case
  Nothing -> if ingress == IngressCloudflareTunnel then tunnelPosture else directPosture
  Just record -> foldl' apply directPosture (filter (committing record) (stepsInEffect record))
  where
    committing record step = not (step == CommitMove && record ^. #inProgress == Just CommitMove)
    apply posture = \case
      MirrorZone -> posture & #zoneRecords .~ Just (fromMaybe MirrorRecords (posture ^. #zoneRecords))
      StartConnector -> posture & #connectorRunning .~ True
      CarryHostnames -> posture & #flatHosts .~ True
      SwitchRecords -> posture & #zoneRecords .~ Just TunnelRecords
      CloseFirewall -> posture & #webRules .~ WebRulesDisabled
      CommitMove -> posture & #webRules .~ WebRulesAbsent
      CloseKourier -> posture & #kourierClosed .~ True
      _ -> posture
