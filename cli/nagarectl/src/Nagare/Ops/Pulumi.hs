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
  ) where

import Nagare.Dsl.Prelude

import Data.Text.Encoding (decodeUtf8)
import Data.Text qualified as T
import Nagare.Ops.Probe (captureTool)

-- | @pulumi -C \<dir\> stack output \<name\>@. 'Nothing' if @pulumi@ is missing,
-- the stack is unselected, or the call otherwise fails — so a missing Pulumi
-- toolchain degrades the dependent probe to 'Nagare.Ops.Probe.StatusUnknown'
-- rather than crashing the command.
stackOutput :: FilePath -> Text -> IO (Maybe Text)
stackOutput dir name = do
  m <- captureTool "pulumi" ["-C", dir, "stack", "output", T.unpack name]
  pure $ fmap (T.strip . decodeUtf8) m
