-- | Production-readiness checklist section 3: upgrade NixOS and k3s on an
-- admitted host without an in-place platform-version change (ADR 6).
--
-- The generated host flake has one input, the platform payload's NixOS
-- source at an immutable store path; NixOS, k3s and sops-nix arrive through
-- that input's transitive nodes. A lock that keeps the root's only input on a
-- path node locked (and originally named) at the store path the flake itself
-- names re-pins only those transitive dependencies, so the payload stays the
-- accepted one. Nix verifies the path's narHash when it builds the closure.
module Nagare.Inventory.HostLock (hostLockRepin) where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude

hostLockRepin :: ByteString -> ByteString -> Either Text ()
hostLockRepin flake lock = do
  payload <- flakePayload flake
  value <- first (const "flake.lock is not JSON") (Aeson.eitherDecodeStrict lock)
  nodes <- field "nodes" value >>= object "nodes"
  rootName <- field "root" value >>= text "root"
  root <- node nodes rootName
  rootInputs <- field "inputs" root >>= object "root inputs"
  nagareName <- case KeyMap.toList rootInputs of
    [(key, String name)] | Key.toText key == "nagare" -> Right name
    _ -> Left "the lock's root must have exactly one input, nagare"
  nagare <- node nodes nagareName
  locked <- field "locked" nagare
  original <- field "original" nagare
  lockedType <- field "type" locked >>= text "locked type"
  lockedPath <- field "path" locked >>= text "locked path"
  unless (lockedType == "path" && lockedPath == payload) $
    Left "the lock's nagare input is not the payload store path the flake names; this is a platform-version change"
  unless (original == Aeson.object ["type" Aeson..= ("path" :: Text), "path" Aeson..= payload]) $
    Left "the lock's nagare input was not originally the flake's payload store path"
  where
    field name value = case value of
      Object fields | Just entry <- KeyMap.lookup (Key.fromText name) fields -> Right entry
      _ -> Left ("flake.lock has no " <> name)
    object name value = case value of
      Object fields -> Right fields
      _ -> Left ("flake.lock " <> name <> " is not an object")
    text name value = case value of
      String entry -> Right entry
      _ -> Left ("flake.lock " <> name <> " is not a string")
    node nodes name = maybe (Left ("flake.lock has no node " <> name)) Right (KeyMap.lookup (Key.fromText name) nodes)

-- | The one generated @inputs.nagare.url = "path:/nix/store/...";@ assignment.
flakePayload :: ByteString -> Either Text Text
flakePayload flake = case mapMaybe assignment (T.lines (TE.decodeUtf8Lenient flake)) of
  [path]
    | "/nix/store/" `T.isPrefixOf` path && not (T.any (`elem` ("\"\\$" :: String)) path) -> Right path
    | otherwise -> Left "the host flake's nagare input is not an immutable store path"
  _ -> Left "the host flake must have exactly one inputs.nagare.url assignment"
  where
    assignment line = T.stripPrefix "inputs.nagare.url = \"path:" (T.strip line) >>= T.stripSuffix "\";"
