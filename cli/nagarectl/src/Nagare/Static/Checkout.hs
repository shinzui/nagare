-- | Check a repository out into a webhook workspace (EP-16 Milestone 3, IO part).
--
-- @nagared@ deploys from source, so it must materialise the exact commit a
-- webhook names before loading the typed config and running the deploy. The
-- checkout is idempotent: a repeated delivery for the same SHA re-fetches and
-- hard-resets the existing clone rather than failing or duplicating work.
module Nagare.Static.Checkout
  ( workspacePathFor
  , checkoutRepo
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Static.Webhook (CheckoutSpec (..))
import System.Directory (doesDirectoryExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

-- | The deterministic checkout directory for a repo under a workspace root:
-- @<root>/<owner>-<repo>@ (slashes in the full name become hyphens so the path
-- never escapes the root).
workspacePathFor :: FilePath -> Text -> FilePath
workspacePathFor root fullName = root </> T.unpack (slug fullName)
  where
    slug = T.map (\c -> if c == '/' then '-' else c)

-- | Clone (or fetch-and-reset) @spec@'s repository into the workspace and hard
-- reset it to the named commit. Returns the checkout directory, or a 'Left' if a
-- git step failed.
checkoutRepo :: FilePath -> CheckoutSpec -> IO (Either Text FilePath)
checkoutRepo root spec = do
  let dir = workspacePathFor root (repoFullName spec)
  exists <- doesDirectoryExist (dir </> ".git")
  result <-
    if exists
      then sequenceSteps [fetch dir, reset dir]
      else sequenceSteps [clone dir, fetch dir, reset dir]
  pure (dir <$ result)
  where
    clone dir =
      git ["clone", "--no-checkout", T.unpack (cloneUrl spec), dir]
    fetch dir =
      gitIn dir ["fetch", "--depth", "1", "origin", T.unpack (sha spec)]
    reset dir =
      gitIn dir ["reset", "--hard", T.unpack (sha spec)]

    -- run a git command, surfacing a non-zero exit as Left
    git args = do
      code <- run (cmd "git" & addArgs args) :: IO ExitCode
      pure (exitToEither (T.pack (unwords ("git" : args))) code)
    gitIn dir args = git (["-C", dir] <> args)

    sequenceSteps [] = pure (Right ())
    sequenceSteps (step : rest) = do
      r <- step
      case r of
        Left e -> pure (Left e)
        Right () -> sequenceSteps rest

    exitToEither what = \case
      ExitSuccess -> Right ()
      ExitFailure n -> Left (what <> " failed (exit " <> T.pack (show n) <> ")")
