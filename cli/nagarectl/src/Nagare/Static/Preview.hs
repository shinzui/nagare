-- | Preview deployments for static sites (EP-15).
--
-- A preview is a non-production copy of a site for a branch or pull request,
-- deployed as its own Knative Service under a derived name and domain so it is
-- isolated from production and easy to list and delete. This module owns the
-- pure naming rules ('normalizePreviewName', 'previewServiceName',
-- 'previewDomain') and the small @kubectl@ IO for listing and deleting previews;
-- the deploy itself reuses EP-14's build/package/apply path with the preview
-- service name set in the renderer context.
module Nagare.Static.Preview
  ( normalizePreviewName
  , previewPrefix
  , previewServiceName
  , previewDomain
  , listPreviews
  , deletePreview
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Char (isAsciiLower, isDigit)
import Data.Text qualified as T
import System.Exit (ExitCode)

-- ---------------------------------------------------------------------------
-- Pure naming

-- | Normalize a user-supplied preview name into a DNS-label-safe fragment:
-- lowercase, non @[a-z0-9]@ runs collapsed to a single hyphen, leading/trailing
-- hyphens trimmed. Fails if nothing usable remains.
normalizePreviewName :: Text -> Either Text Text
normalizePreviewName raw
  | T.null trimmed = Left ("preview name has no DNS-safe characters: " <> raw)
  | otherwise = Right trimmed
  where
    lowered = T.toLower raw
    -- map every non-[a-z0-9] character to a hyphen, then collapse runs.
    hyphenated = T.map (\c -> if isAsciiLower c || isDigit c then c else '-') lowered
    collapsed = T.intercalate "-" (filter (not . T.null) (T.splitOn "-" hyphenated))
    trimmed = collapsed

-- | The Knative Service name prefix that marks a site's previews:
-- @"<site>-pr-"@.
previewPrefix :: Text -> Text
previewPrefix site = site <> "-pr-"

-- | The preview Service name for @site@ and a (raw) preview name:
-- @"<site>-pr-<preview>"@, truncated to the 63-char DNS-label limit with any
-- trailing hyphen removed. Fails if the preview name normalizes to nothing.
previewServiceName :: Text -> Text -> Either Text Text
previewServiceName site raw = do
  norm <- normalizePreviewName raw
  let combined = previewPrefix site <> norm
      clipped = dropTrailingHyphen (T.take 63 combined)
  Right clipped
  where
    dropTrailingHyphen = T.dropWhileEnd (== '-')

-- | The preview public hostname: @"<preview>.<site>.preview.<baseDomain>"@,
-- using the normalized preview name.
previewDomain :: Text -> Text -> Text -> Either Text Text
previewDomain site raw baseDomain = do
  norm <- normalizePreviewName raw
  Right (norm <> "." <> site <> ".preview." <> baseDomain)

-- ---------------------------------------------------------------------------
-- kubectl IO

-- | List a site's preview Service names in @ns@ via
-- @kubectl get ksvc -n <ns> -o name@, filtered to the @"<site>-pr-"@ prefix.
listPreviews :: Text -> Text -> IO [Text]
listPreviews site ns = do
  result <-
    run
      ( cmd "kubectl"
          & addArgs ["get", "ksvc", "-n", T.unpack ns, "-o", "name"]
          & silenceStderr
      ) ::
      IO (ExitCode, StdoutUntrimmed)
  let StdoutUntrimmed out = snd result
      names = map stripResourcePrefix (T.lines out)
  pure (filter (T.isPrefixOf (previewPrefix site)) names)
  where
    -- kubectl `-o name` prints e.g. "service.serving.knative.dev/<name>".
    stripResourcePrefix line = case T.breakOnEnd "/" line of
      (_, n) -> T.strip n

-- | Delete a preview's Service and DomainMapping in @ns@, tolerating absence
-- (@--ignore-not-found@), so a repeated delete is a clean no-op.
deletePreview :: Text -> Text -> Text -> IO ()
deletePreview ns serviceName domain = do
  run_ $
    cmd "kubectl"
      & addArgs
        ["delete", "ksvc", T.unpack serviceName, "-n", T.unpack ns, "--ignore-not-found"]
  run_ $
    cmd "kubectl"
      & addArgs
        ["delete", "domainmapping", T.unpack domain, "-n", T.unpack ns, "--ignore-not-found"]
