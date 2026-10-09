-- | Documentation-only carry-forward of a gate record (operator decision,
-- 2026-10-09; MasterPlan 26 EP-170). A commit with no gate record of its own
-- inherits the green record of its nearest gated ancestor when every path that
-- differs between the two trees is documentation no check, test or payload
-- reads. Re-running the gate for such a commit cannot change its result.
--
-- A changed path is inert only when all three hold:
--
-- * it lies under one of 'inertPrefixes' (plans, MasterPlans, ADRs, audits);
-- * it is not one of the 'shippedDocuments' the platform payload copies;
-- * no file outside @docs/@, other than Markdown, names the path or any
--   directory between it and its inert prefix. Tests read fixtures under
--   @docs/audits@ by naming them, so naming is the signal. Markdown (agent
--   skills, READMEs) is read by people, not checks. A mention in a code
--   comment also blocks, which only costs a full gate.
--
-- The rule cannot see a check that enumerates a whole inert prefix without
-- naming anything below it; none does today. Name the path when adding one.
module Nagare.Harness.CarryForward
  ( PathVerdict (..)
  , carryForwardVerdict
  , classifyPath
  , inertPrefixes
  , referenceNeedles
  , shippedDocuments
  )
where

import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Nagare.Harness.Prelude

-- | Why a changed path does, or does not, allow carry-forward.
data PathVerdict
  = Inert
  | OutsideInertDocumentation
  | ShippedInPayload
  | -- | A non-Markdown file outside @docs/@ names the path or one of its
    -- directories.
    NamedByCode !Text
  deriving stock (Eq, Show, Generic)

-- | Documentation trees that are neither shipped nor executed.
inertPrefixes :: [Text]
inertPrefixes = ["docs/plans/", "docs/masterplans/", "docs/adr/", "docs/audits/"]

-- | Plans the payload copies (@nix/platform-package.nix@ and
-- @Nagare.Platform.Workspace.workspaceAssets@).
shippedDocuments :: [Text]
shippedDocuments =
  [ "docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md"
  , "docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md"
  ]

-- | The path itself and every directory between it and its inert prefix,
-- shortest first. A path outside the inert prefixes has none.
referenceNeedles :: Text -> [Text]
referenceNeedles path = case [prefix | prefix <- inertPrefixes, prefix `T.isPrefixOf` path] of
  prefix : _ ->
    let components = T.splitOn "/" (T.drop (T.length prefix) path)
     in [prefix <> T.intercalate "/" (take count components) | count <- [1 .. length components]]
  [] -> []

-- | Classify one changed path. @namedBy@ answers which file outside @docs/@,
-- if any, names a needle.
classifyPath :: (Text -> Maybe Text) -> Text -> PathVerdict
classifyPath namedBy path
  | not (any (`T.isPrefixOf` path) inertPrefixes) = OutsideInertDocumentation
  | path `elem` shippedDocuments = ShippedInPayload
  | otherwise = case mapMaybe namedBy (referenceNeedles path) of
      file : _ -> NamedByCode file
      [] -> Inert

-- | The number of inert paths, or why carry-forward is refused (the first
-- five blocking paths).
carryForwardVerdict :: (Text -> Maybe Text) -> [Text] -> Either Text Int
carryForwardVerdict namedBy paths =
  case [(path, verdict) | path <- paths, let verdict = classifyPath namedBy path, verdict /= Inert] of
    [] -> Right (length paths)
    blocked -> Left (T.intercalate "; " (map render (take 5 blocked)) <> more blocked)
  where
    render (path, verdict) = path <> " (" <> reason verdict <> ")"
    reason = \case
      Inert -> "inert"
      OutsideInertDocumentation -> "not plan, ADR or audit documentation"
      ShippedInPayload -> "shipped in the platform payload"
      NamedByCode file -> "named by " <> file
    more blocked
      | length blocked > 5 = "; and " <> T.pack (show (length blocked - 5)) <> " more"
      | otherwise = ""
