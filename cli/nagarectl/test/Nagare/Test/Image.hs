-- | Image responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Image
  ( dockerAuthPlanTests
  , qualifyImageTests
  )
where

import Data.Generics.Labels ()
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Types (mkImageRef)
import Nagare.Image
  ( DockerAuth (GcloudConfigureDocker, SkipDockerAuth)
  , dockerAuthPlan
  , qualifyImage
  )
import Nagare.Target (Mode (Cloud, Local))
import Nagare.Test.Support.Assertions (unsafe)
import Nagare.Test.Support.Profiles (tnbProfile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- ---------------------------------------------------------------------------
-- EP-62 M3: the CLI-side image normalizer. A bare name (no '/') is prefixed
-- with the resolved registry prefix; an already-qualified ref is unchanged.

qualifyImageTests :: [TestTree]
qualifyImageTests =
  [ testCase "bare name is prefixed with the registry prefix" $
      qualifyImage tnbProfile (unsafe (mkImageRef "notes"))
        @?= Right (unsafe (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"))
  , testCase "bare name follows a different profile prefix" $
      qualifyImage acmeProfile (unsafe (mkImageRef "notes"))
        @?= Right (unsafe (mkImageRef "europe-west1-docker.pkg.dev/acme-prod/nagare/notes"))
  , testCase "already-qualified public ref is left untouched" $
      qualifyImage tnbProfile (unsafe (mkImageRef "gcr.io/knative-samples/helloworld-go"))
        @?= Right (unsafe (mkImageRef "gcr.io/knative-samples/helloworld-go"))
  ]
  where
    acmeProfile =
      tnbProfile
        & #project
        .~ "acme-prod"
        & #registryHost
        .~ "europe-west1-docker.pkg.dev"

-- ---------------------------------------------------------------------------
-- Nagare.Image.dockerAuthPlan (MasterPlan 16, EP-83): the pure Docker-auth
-- planner. Cloud mode builds the gcloud configure-docker argv; local mode skips
-- it entirely — the machine-checkable form of "zero gcloud calls in local mode".

dockerAuthPlanTests :: TestTree
dockerAuthPlanTests =
  testGroup
    "Nagare.Image.dockerAuthPlan (EP-83)"
    [ testCase "cloud mode builds the gcloud configure-docker argv" $
        dockerAuthPlan Cloud "us-west1-docker.pkg.dev"
          @?= GcloudConfigureDocker
            ["auth", "configure-docker", "us-west1-docker.pkg.dev", "--quiet"]
    , testCase "local mode skips auth — no gcloud argv is constructed" $
        dockerAuthPlan Local "k3d-registry.localhost:5000" @?= SkipDockerAuth
    ]
