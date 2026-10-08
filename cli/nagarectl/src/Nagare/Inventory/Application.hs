-- | Compile application-owned databases from the full typed Application.
-- Every direct object, credential template, and retained backup joins the
-- application's scope; the caller later adds workload and contribution bundles.
module Nagare.Inventory.Application
  ( ApplicationScopeInput (..)
  , compileApplicationScope
  , compileApplicationDeployment
  , applicationDatabaseRetirements
  , compileApplicationDatabases
  , compileApplicationService
  , compileStandaloneService
  , compileStandaloneServiceWithBrokers
  , compileStandaloneServiceWithDependencies
  , compileStandaloneServiceWithRelease
  , compileStandaloneServiceWithReleaseAndBuild
  , compileApplicationWorkers
  , compileStandaloneWorker
  , compileStandaloneWorkerWithDependencies
  , compileStandaloneWorkerWithDependenciesAndBuild
  , recordReviewedStandaloneOverrides
  , compileApplicationTasks
  , applicationNativeOwned
  , nativeWorkloadOwned
  , hostnameClaimOwned
  , acceptedApplicationImage
  , acceptedImageBuildSecrets
  , acceptedImageResourceForDestination
  , reviewedTaskImages
  , databaseRecoveryBindings
  , acceptedSecretBindings
  , acceptedBrokerBindings
  , AccessBinding (..)
  , GoogleCdnBinding (..)
  , CloudflareCdnBinding (..)
  , ReviewedCdnBinding (..)
  , acceptedAccessBinding
  , acceptedApplicationReleaseLog
  , acceptedStandaloneReleaseLog
  , legacyApplicationReleaseImport
  , legacyStandaloneReleaseImport
  , DatabaseBinding
  , acceptedDatabaseBindings
  , applicationVolumeRecoveryBindings
  , standaloneWorkerVolumeRecoveryBindings
  , applicationRetirementScope
  , workerRetirementScope
  , ServiceAction (..)
  , compileServiceActionScope
  )
where

import Nagare.Dsl.Prelude
import Nagare.Inventory.Application.Bindings
  ( acceptedAccessBinding
  , acceptedApplicationImage
  , acceptedBrokerBindings
  , acceptedDatabaseBindings
  , acceptedImageBuildSecrets
  , acceptedImageResourceForDestination
  , acceptedSecretBindings
  )
import Nagare.Inventory.Application.Compile
  ( compileApplicationDeployment
  , compileApplicationScope
  )
import Nagare.Inventory.Application.Database
  ( compileApplicationDatabases
  )
import Nagare.Inventory.Application.Environment
  ( reviewedTaskImages
  )
import Nagare.Inventory.Application.Ownership
  ( applicationNativeOwned
  , applicationRetirementScope
  , hostnameClaimOwned
  , nativeWorkloadOwned
  , workerRetirementScope
  )
import Nagare.Inventory.Application.Policy
  ( ServiceAction (..)
  , compileServiceActionScope
  , recordReviewedStandaloneOverrides
  )
import Nagare.Inventory.Application.Recovery
  ( applicationVolumeRecoveryBindings
  , databaseRecoveryBindings
  , standaloneWorkerVolumeRecoveryBindings
  )
import Nagare.Inventory.Application.Release
  ( acceptedApplicationReleaseLog
  , acceptedStandaloneReleaseLog
  , legacyApplicationReleaseImport
  , legacyStandaloneReleaseImport
  )
import Nagare.Inventory.Application.Retire (applicationDatabaseRetirements)
import Nagare.Inventory.Application.Service
  ( compileApplicationService
  , compileStandaloneService
  , compileStandaloneServiceWithBrokers
  , compileStandaloneServiceWithDependencies
  , compileStandaloneServiceWithRelease
  , compileStandaloneServiceWithReleaseAndBuild
  )
import Nagare.Inventory.Application.Tasks
  ( compileApplicationTasks
  )
import Nagare.Inventory.Application.Types
  ( AccessBinding (..)
  , ApplicationScopeInput (..)
  , CloudflareCdnBinding (..)
  , DatabaseBinding (..)
  , GoogleCdnBinding (..)
  , ReviewedCdnBinding (..)
  )
import Nagare.Inventory.Application.Worker
  ( compileApplicationWorkers
  , compileStandaloneWorker
  , compileStandaloneWorkerWithDependencies
  , compileStandaloneWorkerWithDependenciesAndBuild
  )
