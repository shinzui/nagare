-- | Application / Site. Executable-private CLI boundary: the reviewed inputs a
-- production site deploy and a site preview read from the same options.
module Nagare.Cli.Application.Site
  ( reviewedSiteAccessBinding
  , reviewedSiteTag
  , siteDeployInputs
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Cli.Options (SiteDeployOpts)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Posture (activeHostShape)
import Nagare.Dsl.Access (AccessPolicy)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Static.Types (StaticSite)
import Nagare.Inventory.Application (AccessBinding, acceptedAccessBinding)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Static.Deploy (DeployInputs (..))
import Nagare.Target (ActiveTarget, TargetProfile)

reviewedSiteTag :: SiteDeployOpts -> IO Text
reviewedSiteTag options = do
  unless
    (options ^. #skipBuild)
    (dieT "reviewed site deployment requires --skip-build")
  when
    (options ^. #dryRun && isJust (options ^. #savePlan))
    (dieT "reviewed site deployment cannot combine --dry-run with --save-plan")
  maybe
    (dieT "reviewed site deployment requires --tag")
    (pure . T.pack)
    (options ^. #tag)

-- | A site that opts into access needs the accepted auth owner; a public site
-- must not carry one. The binding is resolved against the accepted snapshot,
-- never from a live Service or a caller-supplied name.
reviewedSiteAccessBinding ::
  ActiveTarget ->
  ResourceInventory.ScopeSnapshot ->
  Resource.ResourceId ->
  Maybe AccessPolicy ->
  IO (Maybe AccessBinding)
reviewedSiteAccessBinding active snapshot cluster =
  traverse (\_ -> activeHostShape active >>= \shape -> either dieT pure (acceptedAccessBinding shape snapshot cluster))

-- | Assemble the runtime-agnostic 'DeployInputs' from the @site deploy@ options.
siteDeployInputs :: TargetProfile -> SiteDeployOpts -> StaticSite -> Text -> Text -> DeployInputs
siteDeployInputs tp sopts site imageTag bd =
  DeployInputs
    { site = site
    , imageTag = imageTag
    , baseDomain = bd
    , projectDir = sopts ^. #projectDir
    , skipBuild = sopts ^. #skipBuild
    , targetProfile = tp
    }
