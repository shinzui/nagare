-- | Build responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Build
  ( buildModeTests
  )
where

import Nagare.Build (applyBuildOverrides, describeBuild)
import Nagare.Dsl.Build
  ( BuildSpec (DockerfileBuild, NixpacksBuild)
  )
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Static.Types (filePathText)
import Nagare.Image (dockerBuildArgs, nixpacksBuildArgs)
import Nagare.Test.Support.Assertions (assertLeftText)
import Nagare.Test.Support.Build
  ( dockerfileSpec
  , nixpacksSpec
  , prebuiltSpec
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

buildModeTests :: [TestTree]
buildModeTests =
  [ testGroup
      "dockerBuildArgs"
      [ testCase "emits --platform, -f, -t, --build-arg, context in order" $
          dockerBuildArgs "linux/amd64" "r" "Dockerfile" "." [("A", "1")]
            @?= ["build", "--platform", "linux/amd64", "-f", "Dockerfile", "-t", "r", "--build-arg", "A=1", "."]
      , testCase "no build args omits --build-arg" $
          dockerBuildArgs "linux/amd64" "ref:tag" "docker/Dockerfile" "svc" []
            @?= ["build", "--platform", "linux/amd64", "-f", "docker/Dockerfile", "-t", "ref:tag", "svc"]
      , testCase "multiple build args each get their own --build-arg" $
          dockerBuildArgs "linux/amd64" "r" "Dockerfile" "." [("A", "1"), ("B", "2")]
            @?= [ "build"
                , "--platform"
                , "linux/amd64"
                , "-f"
                , "Dockerfile"
                , "-t"
                , "r"
                , "--build-arg"
                , "A=1"
                , "--build-arg"
                , "B=2"
                , "."
                ]
      , testCase "the platform argument is honored (EP-3)" $
          dockerBuildArgs "linux/arm64" "r" "Dockerfile" "." []
            @?= ["build", "--platform", "linux/arm64", "-f", "Dockerfile", "-t", "r", "."]
      ]
  , testGroup
      "nixpacksBuildArgs"
      [ testCase "builds the context and tags with --name, with --platform" $
          nixpacksBuildArgs "linux/amd64" "ref:tag" "." []
            @?= ["build", ".", "--platform", "linux/amd64", "--name", "ref:tag"]
      , testCase "build args become --env KEY=VALUE" $
          nixpacksBuildArgs "linux/amd64" "r" "app" [("A", "1")]
            @?= ["build", "app", "--platform", "linux/amd64", "--name", "r", "--env", "A=1"]
      , testCase "multiple build args each get their own --env" $
          nixpacksBuildArgs "linux/amd64" "r" "." [("A", "1"), ("B", "2")]
            @?= ["build", ".", "--platform", "linux/amd64", "--name", "r", "--env", "A=1", "--env", "B=2"]
      ]
  , testGroup
      "describeBuild"
      [ testCase "prebuilt mentions no local build and the tag" $
          describeBuild "linux/amd64" prebuiltSpec @?= "prebuilt image (no local build), tag v1.2.3"
      , testCase "dockerfile shows the docker build command with --platform" $
          describeBuild "linux/amd64" dockerfileSpec @?= "docker build --platform linux/amd64 -f Dockerfile ."
      , testCase "nixpacks shows the nixpacks build command with --platform" $
          describeBuild "linux/amd64" nixpacksSpec @?= "nixpacks build --platform linux/amd64 ."
      ]
  , testGroup
      "applyBuildOverrides"
      [ testCase "no overrides leaves the spec unchanged" $
          applyBuildOverrides Nothing Nothing dockerfileSpec @?= Right dockerfileSpec
      , testCase "context override substitutes the Dockerfile build context" $
          case applyBuildOverrides (Just "services/web") Nothing dockerfileSpec of
            Right (DockerfileBuild _ ctx _) -> filePathText ctx @?= "services/web"
            other -> assertFailure ("expected DockerfileBuild, got: " <> show other)
      , testCase "dockerfile override substitutes the Dockerfile path" $
          case applyBuildOverrides Nothing (Just "docker/Dockerfile.prod") dockerfileSpec of
            Right (DockerfileBuild df _ _) -> filePathText df @?= "docker/Dockerfile.prod"
            other -> assertFailure ("expected DockerfileBuild, got: " <> show other)
      , testCase "an invalid (absolute) override path is rejected" $
          assertLeftText (applyBuildOverrides (Just "/abs") Nothing dockerfileSpec)
      , testCase "context override applies to a Nixpacks build" $
          case applyBuildOverrides (Just "app") Nothing nixpacksSpec of
            Right (NixpacksBuild ctx _) -> filePathText ctx @?= "app"
            other -> assertFailure ("expected NixpacksBuild, got: " <> show other)
      , testCase "dockerfile override against a Nixpacks build is an error" $
          assertLeftText (applyBuildOverrides Nothing (Just "Dockerfile") nixpacksSpec)
      , testCase "any override against a prebuilt config is an error" $ do
          assertLeftText (applyBuildOverrides (Just "x") Nothing prebuiltSpec)
          assertLeftText (applyBuildOverrides Nothing (Just "Dockerfile") prebuiltSpec)
      , testCase "no override against a prebuilt config is fine" $
          applyBuildOverrides Nothing Nothing prebuiltSpec @?= Right prebuiltSpec
      ]
  ]
