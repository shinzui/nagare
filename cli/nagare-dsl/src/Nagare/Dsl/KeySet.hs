-- | A signing key set (EP-286): Ed25519 keys the platform generates and
-- rotates for an application, which a signing workload reads as private keys
-- and a verifying workload as public keys, from files that change in place.
module Nagare.Dsl.KeySet
  ( -- * Names
    KeySetName
  , mkKeySetName
  , keySetNameText

    -- * Rotation
  , Minutes
  , mkMinutes
  , minutesInt
  , RotationPolicy (..)
  , mkRotationPolicy
  , minimumPeriod
  , minimumOverlap
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Nagare.Dsl.Prelude

-- | A DNS label of at most 30 characters that starts with a letter, so the
-- Secret @nagare-keyset-\<name\>@ and the ConfigMap
-- @nagare-keyset-\<name\>-public@ are valid object names. Constructor hidden;
-- use 'mkKeySetName'.
newtype KeySetName = KeySetName Text
  deriving stock (Eq, Ord, Show)

mkKeySetName :: Text -> Either Text KeySetName
mkKeySetName t
  | Text.null t || Text.length t > 30 = Left ("key set name must have 1 to 30 characters: " <> t)
  | not (isAsciiLower (Text.head t)) = Left ("key set name must start with a lower-case letter: " <> t)
  | Text.last t == '-' = Left ("key set name must not end with -: " <> t)
  | not (Text.all (\c -> isAsciiLower c || isDigit c || c == '-') t) = Left ("key set name must be lower-case letters, digits and -: " <> t)
  | otherwise = Right (KeySetName t)

keySetNameText :: KeySetName -> Text
keySetNameText (KeySetName t) = t

-- | A whole number of minutes, at least one. Constructor hidden; use
-- 'mkMinutes'.
newtype Minutes = Minutes Int
  deriving stock (Eq, Ord, Show)

mkMinutes :: Int -> Either Text Minutes
mkMinutes n
  | n < 1 = Left ("a duration must be at least one minute, got " <> Text.show n)
  | otherwise = Right (Minutes n)

minutesInt :: Minutes -> Int
minutesInt (Minutes n) = n

-- | How often the active key is replaced, and how long a replaced key is
-- still published so a signature made just before a rotation verifies.
data RotationPolicy = RotationPolicy
  { period :: !Minutes
  , overlap :: !Minutes
  }
  deriving stock (Generic, Eq, Show)

-- | The rotator runs every five minutes, so a shorter period or overlap
-- could not be honoured.
minimumPeriod, minimumOverlap :: Int
minimumPeriod = 10
minimumOverlap = 5

-- | Refuses a period under ten minutes, an overlap under five minutes, and
-- an overlap longer than the period.
mkRotationPolicy :: Minutes -> Minutes -> Either Text RotationPolicy
mkRotationPolicy period' overlap'
  | minutesInt period' < minimumPeriod = Left ("a rotation period must be at least " <> Text.show minimumPeriod <> " minutes, got " <> Text.show (minutesInt period'))
  | minutesInt overlap' < minimumOverlap = Left ("a rotation overlap must be at least " <> Text.show minimumOverlap <> " minutes, got " <> Text.show (minutesInt overlap'))
  | overlap' > period' = Left "a rotation overlap must not be longer than its period"
  | otherwise = Right (RotationPolicy period' overlap')
