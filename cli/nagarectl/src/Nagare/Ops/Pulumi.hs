-- | Read authoritative platform values from the Pulumi stack (Integration Point
-- IP2 of MasterPlan 8).
--
-- Pulumi state is selected per active target context (EP-90): @.envrc@ and
-- @nagarectl --context@ set @PULUMI_HOME@, @PULUMI_BACKEND_URL@, and the selected
-- stack before this helper runs. The stack outputs this initiative reads —
-- defined in @infra/pulumi/index.ts@ — are @publicIp@, @baseDomain@,
-- @backupBucket@, and @artifactRegistry@.
--
-- @nagarectl domains list@ (@docs/plans/40-...@) reuses 'stackOutput' to resolve
-- the base domain rather than re-implementing a Pulumi reader. The existing
-- @resolveBaseDomain@ in @app/Main.hs@ (flag/env/literal fallback only) is left
-- in place for the deploy path and is not touched here.
module Nagare.Ops.Pulumi
  ( stackOutput
  , stackOutputs
  )
where

import Data.Aeson (Value (..), decodeStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Nagare.Dsl.Prelude
import Nagare.Ops.Probe (captureTool)

-- | @pulumi -C \<dir\> stack output \<name\>@. 'Nothing' if @pulumi@ is missing,
-- the stack is unselected, or the call otherwise fails — so a missing Pulumi
-- toolchain degrades the dependent probe to 'Nagare.Ops.Probe.StatusUnknown'
-- rather than crashing the command.
stackOutput :: FilePath -> Text -> IO (Maybe Text)
stackOutput dir name = do
  m <- captureTool "pulumi" ["-C", dir, "stack", "output", T.unpack name]
  pure $ fmap (T.strip . decodeUtf8) m

-- | Every string output of the stack from one @pulumi stack output --json@, so a command that needs
-- several pays for one process instead of one each (EP-245 D5). Empty when Pulumi is missing or fails.
stackOutputs :: FilePath -> IO (Map Text Text)
stackOutputs dir = do
  m <- captureTool "pulumi" ["-C", dir, "stack", "output", "--json"]
  pure $ case m >>= decodeStrict of
    Just (Object fields) -> Map.fromList [(Key.toText key, T.strip text) | (key, String text) <- KM.toList fields]
    _ -> Map.empty
