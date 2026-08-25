{-# LANGUAGE OverloadedStrings #-}

module HostSpec (hostTests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Host.Config
import Nagare.Target (ContextName, mkContextName)
import Nagare.Version (BuildVersion (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

hostTests :: TestTree
hostTests =
  testGroup
    "Nagare.Host.Config (EP-107)"
    [ testCase "validates public keys and rejects private material" $ do
        validateSshPublicKey fixtureKey @?= Right fixtureKey
        assertBool "private key is rejected" (either (const True) (const False) (validateSshPublicKey "-----BEGIN OPENSSH PRIVATE KEY-----"))
        assertBool "unknown key type is rejected" (either (const True) (const False) (validateSshPublicKey "ssh-dss AAAAB3NzaC1kc3MAAACBAexample"))
    , testCase "renders a deterministic generated flake and operator module" $ do
        context <- either (assertFailure . T.unpack) pure (mkContextName "prod")
        let config = fixtureConfig context
            build = BuildVersion "1.2.3" (Just "abc123")
            flake = renderHostFlake config build
            hostModule = renderHostModule config
        assertBool "Nagare input is explicit" ("inputs.nagare.url = \"path:/opt/nagare/nixos\";" `T.isInfixOf` flake)
        assertBool "generated output owns image and rebuild config" ("nixosConfigurations.\"prod-host\"" `T.isInfixOf` flake)
        assertBool "operator key is explicit" (fixtureKey `T.isInfixOf` hostModule)
        assertBool "sops file remains a relative flake path" ("sopsDefaultFile = ./secrets.yaml;" `T.isInfixOf` hostModule)
        assertBool "private data is absent" (not ("PRIVATE KEY" `T.isInfixOf` T.toUpper (flake <> hostModule)))
    ]

fixtureConfig :: ContextName -> HostConfig
fixtureConfig context =
  HostConfig
    { hostContext = context
    , hostName = "prod-host"
    , instanceName = "prod-instance"
    , registryHost = "us-west1-docker.pkg.dev"
    , deployUser = "deploy"
    , authorizedKeys = fixtureKey :| []
    , ageKeyFile = "/var/lib/sops-nix/age-key.txt"
    , nagareNixosSource = "/opt/nagare/nixos"
    }

fixtureKey :: Text
fixtureKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyForNagareEvaluationOnly operator@example"
