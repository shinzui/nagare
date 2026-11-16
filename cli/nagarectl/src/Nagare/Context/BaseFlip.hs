-- | The profile change of a move to a new base domain (EP-246 D2). Only the open move's flip changes
-- @NAGARE_BASE_DOMAIN@, @NAGARE_INGRESS@ and @NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED@, all three together,
-- and records the old base as the retained Cloud DNS name; undoing the flip restores all four. A plain
-- context review of any of them is still refused ('Nagare.Context.Review').
--
-- A shell that exports the contract keeps the base it was loaded with, and the environment wins over
-- the context file, so a review planned from a stale shell would plan for the wrong base. While a
-- base move is open the process environment may name only the base the journal expects.
module Nagare.Context.BaseFlip
  ( baseMoveKind
  , flippedProfile
  , restoredProfile
  , profileFlipped
  , expectedBases
  , baseEnvironmentRefusal
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Context.Move
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store.Manifest (MoveMarker (..))
import Nagare.Target (IngressMode (..), TargetProfile)

-- | The kind of EP-246's move in the head marker and its review identities.
baseMoveKind :: Text
baseMoveKind = "base-domain"

flippedProfile :: MoveMarker -> TargetProfile -> TargetProfile
flippedProfile marker profile =
  profile
    & #baseDomain
    .~ moveTargetBase marker
    & #ingress
    .~ IngressCloudflareTunnel
    & #externalDomainTlsEnabled
    .~ False
    & #retainedDnsName
    .~ moveRetainedDnsName marker

restoredProfile :: MoveMarker -> TargetProfile -> TargetProfile
restoredProfile marker profile =
  profile
    & #baseDomain
    .~ moveRetainedDnsName marker
    & #ingress
    .~ IngressDirect
    & #externalDomainTlsEnabled
    .~ moveOriginTls marker
    & #retainedDnsName
    .~ ""

-- | Whether the profile already holds the flip's four values.
profileFlipped :: MoveMarker -> TargetProfile -> Bool
profileFlipped marker profile = flippedProfile marker profile == profile

-- | The bases the context may be planned against now: the old one before the flip, the new one after
-- it, and either while the flip itself is in progress, because it writes the profile and then stops
-- for the operator to reload the shell.
expectedBases :: MoveMarker -> [Text]
expectedBases marker
  | record ^. #inProgress == Just FlipBase = [old, new]
  | FlipBase `elem` take (record ^. #completed) (record ^. #steps) = [new]
  | otherwise = [old]
  where
    record = moveProgress marker
    old = moveRetainedDnsName marker
    new = moveTargetBase marker

-- | A refusal when a base move is open and @NAGARE_BASE_DOMAIN@ in the environment names another base.
baseEnvironmentRefusal :: MoveMarker -> Maybe Text -> Maybe Text
baseEnvironmentRefusal marker environment
  | moveKind marker /= baseMoveKind = Nothing
  | Just set <- environment
  , not (T.null set)
  , normal set `notElem` map normal (expectedBases marker) =
      Just
        ( "NAGARE_BASE_DOMAIN is "
            <> set
            <> " in this shell, but the open move expects "
            <> T.intercalate " or " (expectedBases marker)
            <> "; reload the shell's environment (direnv reload) and run again"
        )
  | otherwise = Nothing
  where
    normal = T.toLower . T.dropWhileEnd (== '.')
