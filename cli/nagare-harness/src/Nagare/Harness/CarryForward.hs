-- | Documentation-only carry-forward of a gate record (operator decision,
-- 2026-10-09; MasterPlan 26 EP-170). A commit with no gate record of its own
-- inherits the green record of its nearest gated ancestor when every path that
-- differs between the two trees is documentation no check, test or payload
-- reads. Re-running the gate for such a commit cannot change its result.
--
-- The repository's top-level @README.md@ and @CHANGELOG.md@ are inert: no
-- check, test or payload reads them. Release notes under @docs/releases/@ are
-- inert too (EP-210 M2): only @scripts/check-release.sh@ reads them, in the
-- candidate run, never in a gate. So is an edited, not removed, Markdown file under @docs/@ that no
-- check reads for its content ('contentReadDocuments') and that is not one of
-- the 'shippedDocuments' (operator, 2026-10-20: a documentation-only push must
-- never run a gate). Code names such pages in help text and the payload copies
-- some trees whole, but nothing in a gate reads their words. Any other changed
-- path is inert only when all three hold:
--
-- * it lies under @docs/@, outside the 'readTrees' a check or the payload
--   reads whole (operator, 2026-10-18: pushing documentation must not run a
--   gate);
-- * it is not one of the 'shippedDocuments' the platform payload copies;
-- * no file outside @docs/@, other than Markdown and the @mori.dhall@
--   registry manifest, names the path or any directory between it and its
--   tree. Tests read fixtures under
--   @docs/audits@ by naming them, so naming is the signal. Markdown (agent
--   skills, READMEs) is read by people, not checks. A mention in a code
--   comment also blocks, which only costs a full gate.
--
-- The rule cannot see a check that enumerates a whole inert tree without
-- naming anything below it; add such a tree to 'readTrees'.
module Nagare.Harness.CarryForward
  ( PathVerdict (..)
  , carryForwardVerdict
  , classifyPath
  , contentReadDocuments
  , inertFiles
  , inertPrefix
  , readTrees
  , referenceNeedles
  , shippedDocuments
  )
where

import Data.Maybe (isNothing, mapMaybe)
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

-- | Single documents that are neither shipped nor executed.
inertFiles :: [Text]
inertFiles = ["README.md", "CHANGELOG.md"]

-- | Markdown a check reads for its content: the managed-command catalogue
-- (@scripts/audit-managed-commands.py@). A prefix ending in @/@ covers a tree.
contentReadDocuments :: [Text]
contentReadDocuments = ["docs/architecture/managed-resource-coverage.md"]

-- | An edited Markdown file under @docs/@ whose words no check reads.
editedProse :: (Text -> Bool) -> Text -> Bool
editedProse removed path =
  "docs/" `T.isPrefixOf` path
    && ".md" `T.isSuffixOf` path
    && not (removed path)
    && path `notElem` shippedDocuments
    && not (any (\document -> if "/" `T.isSuffixOf` document then document `T.isPrefixOf` path else document == path) contentReadDocuments)

-- | Documentation trees the payload ships or a check reads whole.
readTrees :: [Text]
readTrees = ["docs/api/", "docs/architecture/", "docs/guides/", "docs/reviews/", "docs/runbooks/", "docs/terminology/", "docs/user/"]

-- | The inert tree a path lies in: @docs/<tree>/@, or @docs/@ for a
-- document directly under it.
inertPrefix :: Text -> Maybe Text
inertPrefix path = do
  rest <- T.stripPrefix "docs/" path
  let prefix = case T.breakOn "/" rest of
        (_, "") -> "docs/"
        (tree, _) -> "docs/" <> tree <> "/"
  if prefix `elem` readTrees then Nothing else Just prefix

-- | Plans the payload copies (@nix/platform-package.nix@ and
-- @Nagare.Platform.Workspace.workspaceAssets@).
shippedDocuments :: [Text]
shippedDocuments =
  [ "docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md"
  , "docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md"
  ]

-- | The path itself and every directory between it and its inert tree,
-- shortest first. A path outside the inert trees has none.
referenceNeedles :: Text -> [Text]
referenceNeedles path = case inertPrefix path of
  Just prefix ->
    let components = T.splitOn "/" (T.drop (T.length prefix) path)
     in [prefix <> T.intercalate "/" (take count components) | count <- [1 .. length components]]
  Nothing -> []

-- | Classify one changed path. @removed@ answers whether the commit deletes
-- the path; @namedBy@ answers which file outside @docs/@, if any, names a
-- needle.
classifyPath :: (Text -> Bool) -> (Text -> Maybe Text) -> Text -> PathVerdict
classifyPath removed namedBy path
  | path `elem` inertFiles = Inert
  | editedProse removed path = Inert
  | isNothing (inertPrefix path) = OutsideInertDocumentation
  | path `elem` shippedDocuments = ShippedInPayload
  | otherwise = case mapMaybe namedBy (referenceNeedles path) of
      file : _ -> NamedByCode file
      [] -> Inert

-- | The number of inert paths, or why carry-forward is refused (the first
-- five blocking paths).
carryForwardVerdict :: (Text -> Bool) -> (Text -> Maybe Text) -> [Text] -> Either Text Int
carryForwardVerdict removed namedBy paths =
  case [(path, verdict) | path <- paths, let verdict = classifyPath removed namedBy path, verdict /= Inert] of
    [] -> Right (length paths)
    blocked -> Left (T.intercalate "; " (map render (take 5 blocked)) <> more blocked)
  where
    render (path, verdict) = path <> " (" <> reason verdict <> ")"
    reason = \case
      Inert -> "inert"
      OutsideInertDocumentation -> "not documentation, or in a tree a check or the payload reads"
      ShippedInPayload -> "shipped in the platform payload"
      NamedByCode file -> "named by " <> file
    more blocked
      | length blocked > 5 = "; and " <> T.pack (show (length blocked - 5)) <> " more"
      | otherwise = ""
