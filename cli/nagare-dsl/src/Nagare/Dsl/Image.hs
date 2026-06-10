{-# LANGUAGE OverloadedStrings #-}

-- | Deriving a fully-qualified container image reference from a short image NAME
-- plus a registry PREFIX supplied at deploy time (MasterPlan 12 Integration
-- Point 4, EP-62 M3). An app's Config.hs supplies only the name (e.g. @"notes"@);
-- nagarectl prepends @"\<host>/\<project>/\<repo-id>"@ resolved from the target
-- profile, so application source no longer bakes in the GCP project/region.
-- 'mkImageRef' is retained for fully-qualified refs (e.g. a public registry).
module Nagare.Dsl.Image
  ( mkImageName
  , imageRefFromName
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Nagare.Dsl.Types (ImageRef, mkImageRef)

-- | Join a registry prefix and a short image name into a fully-qualified
-- 'ImageRef', validating the result through 'mkImageRef'. The @name@ must be a
-- bare name with no slash or tag; the @prefix@ is @"\<host>/\<project>/\<repo-id>"@.
-- Example: @imageRefFromName "us-west1-docker.pkg.dev/tan-nb-exp/nagare" "notes"@
-- yields an 'ImageRef' over @"us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"@.
imageRefFromName :: Text -> Text -> Either Text ImageRef
imageRefFromName prefix name =
  mkImageRef (T.dropWhileEnd (== '/') prefix <> "/" <> name)

-- | Build an 'ImageRef' from a bare name, deferring the registry prefix to deploy
-- time (an alias of 'mkImageRef'). The prefix is applied later by nagarectl's
-- @qualifyImage@ at the load boundary; this helper exists for the prefix-known
-- case and for tests.
mkImageName :: Text -> Either Text ImageRef
mkImageName = mkImageRef
