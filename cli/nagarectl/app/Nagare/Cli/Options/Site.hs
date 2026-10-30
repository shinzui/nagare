-- | Options / Site. Option records for the @site@ commands; parsing-only.
module Nagare.Cli.Options.Site
  ( SiteCommonOpts (..)
  , SiteDeployOpts (..)
  , SiteListOpts (..)
  , SitePackageOpts (..)
  , SitePreviewDeleteOpts (..)
  , SitePublishOpts (..)
  , SiteRollbackOpts (..)
  )
where

import Nagare.Dsl.Prelude

-- | Options for @site deploy@ (and, with a @--name@, @site preview deploy@).
data SiteDeployOpts = SiteDeployOpts
  { file :: !FilePath
  , tag :: !(Maybe String)
  , baseDomain :: !(Maybe String)
  , projectDir :: !FilePath
  , ghcEnv :: !(Maybe FilePath)
  , dryRun :: !Bool
  , skipBuild :: !Bool
  , source :: !(Maybe String)
  -- ^ Free-form provenance recorded with the release (e.g. a git SHA or branch).
  , savePlan :: !(Maybe FilePath)
  , imageResource :: !(Maybe String)
  , cdnBackendResource :: !(Maybe String)
  , siteVolumeRecovery :: ![String]
  , siteEnvSecretResources :: ![String]
  , siteTlsSecretResources :: ![String]
  , sitePreviewEnvResources :: ![String]
  , sitePreviewAdoptionInput :: !(Maybe FilePath)
  , legacyReleaseImport :: !(Maybe FilePath)
  , releaseAdoptionInput :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | @site package@: write a local build context or Docker archive for a static
-- site. Exactly one of 'contextOut' and 'archive' is required (checked by the
-- handler so the refusal names both flags).
data SitePackageOpts = SitePackageOpts
  { file :: !FilePath
  , projectDir :: !FilePath
  , ghcEnv :: !(Maybe FilePath)
  , outputDir :: !(Maybe FilePath)
  , build :: !Bool
  , contextOut :: !(Maybe FilePath)
  , archive :: !(Maybe FilePath)
  , tag :: !(Maybe String)
  , platform :: !(Maybe String)
  }
  deriving stock (Generic, Show)

-- | Options for the read-only / config-only site subcommands (@releases@,
-- @rollback@, @preview list@, @preview delete@): enough to load the config and
-- resolve the base domain.
data SiteCommonOpts = SiteCommonOpts
  { file :: !FilePath
  , baseDomain :: !(Maybe String)
  , ghcEnv :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | @site list@: the active context's recorded sites, from its inventory
-- store only (EP-193).
data SiteListOpts = SiteListOpts
  { namespace :: !(Maybe String)
  , includePreviews :: !Bool
  , json :: !Bool
  , contract :: !(Maybe Int)
  }
  deriving stock (Generic, Show)

data SiteRollbackOpts = SiteRollbackOpts
  { common :: !SiteCommonOpts
  , savePlan :: !(Maybe FilePath)
  , imageResource :: !(Maybe String)
  , cdnBackendResource :: !(Maybe String)
  , siteVolumeRecovery :: ![String]
  , siteEnvSecretResources :: ![String]
  , siteTlsSecretResources :: ![String]
  }
  deriving stock (Generic, Show)

data SitePreviewDeleteOpts = SitePreviewDeleteOpts
  { common :: !SiteCommonOpts
  , savePlan :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | @site publish@: package, publish the image and deploy the site in one
-- command. Every field is optional: with none, the existing output is
-- published with a derived tag.
data SitePublishOpts = SitePublishOpts
  { file :: !FilePath
  , projectDir :: !FilePath
  , ghcEnv :: !(Maybe FilePath)
  , baseDomain :: !(Maybe String)
  , outputDir :: !(Maybe FilePath)
  , build :: !Bool
  , tag :: !(Maybe String)
  , platform :: !(Maybe String)
  , releaseDir :: !(Maybe FilePath)
  , newRelease :: !Bool
  , verbose :: !Bool
  , resume :: !Bool
  , cdnBackendResource :: !(Maybe String)
  , tlsSecretResources :: ![String]
  , contract :: !(Maybe Int)
  }
  deriving stock (Generic, Show)
