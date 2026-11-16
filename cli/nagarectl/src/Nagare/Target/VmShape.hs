-- | The GCE instance's compute and disk shape, its fresh-context defaults, and the syntax check
-- every context write applies. "Nagare.Target" re-exports it, so callers keep importing from there.
module Nagare.Target.VmShape
  ( VmShape (..)
  , defaultVmShape
  , validateVmShape
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Text.Read (readMaybe)

-- | The four values that determine the GCE instance's compute and disk shape.
-- They live in the target context so a later change to a Pulumi-program fallback
-- cannot silently change an existing stack.
data VmShape = VmShape
  { machineType :: !Text
  , bootDiskType :: !Text
  , bootDiskSizeGb :: !Text
  , dataDiskSizeGb :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | The shape used by a fresh context and by legacy contexts that predate the
-- four explicit fields. Keep these literals in sync with
-- @infra\/pulumi\/src\/vmShape.ts@; the @vm-shape-defaults-agree@ flake check
-- enforces the contract.
defaultVmShape :: VmShape
defaultVmShape =
  VmShape
    { machineType = "e2-standard-2"
    , bootDiskType = "pd-balanced"
    , bootDiskSizeGb = "100"
    , dataDiskSizeGb = "100"
    }

-- | Validate a VM shape at context-write and apply-guard boundaries. This is a
-- deliberately small syntax check, not a live GCE catalog lookup.
validateVmShape :: VmShape -> Either Text VmShape
validateVmShape shape
  | T.null machine = Left "NAGARE_MACHINE_TYPE must not be empty"
  | not (validMachineType machine) =
      Left
        ( "NAGARE_MACHINE_TYPE='"
            <> machine
            <> "' is invalid (expected <family>-<series> using lowercase letters/digits/hyphens, or custom-<cpus>-<mb>)"
        )
  | bootType `notElem` acceptedBootTypes =
      Left
        ( "NAGARE_BOOT_DISK_TYPE='"
            <> bootType
            <> "' is invalid (accepted: pd-standard, pd-balanced, pd-ssd, hyperdisk-balanced)"
        )
  | not (validSize bootSize) = Left "NAGARE_BOOT_DISK_SIZE_GB must be an integer of at least 10 GB"
  | not (validSize dataSize) = Left "NAGARE_DATA_DISK_SIZE_GB must be an integer of at least 10 GB"
  | otherwise = Right shape
  where
    machine = shape ^. #machineType
    bootType = shape ^. #bootDiskType
    bootSize = shape ^. #bootDiskSizeGb
    dataSize = shape ^. #dataDiskSizeGb
    acceptedBootTypes = ["pd-standard", "pd-balanced", "pd-ssd", "hyperdisk-balanced"]
    validSize value = maybe False (>= (10 :: Integer)) (readMaybe (T.unpack value))
    validMachineType value
      | "custom-" `T.isPrefixOf` value = validCustom value
      | otherwise = validNamed value
    validCustom value = case T.splitOn "-" value of
      ["custom", cpus, mb] -> positiveDecimal cpus && positiveDecimal mb
      _ -> False
    validNamed value = case T.breakOn "-" value of
      (family, suffix) ->
        not (T.null family)
          && T.all lowerAlphaNum family
          && not (T.null suffix)
          && T.all (\c -> lowerAlphaNum c || c == '-') (T.drop 1 suffix)
    positiveDecimal value = not (T.null value) && T.all isDigit value && value /= "0"
    lowerAlphaNum c = isAsciiLower c || isDigit c
