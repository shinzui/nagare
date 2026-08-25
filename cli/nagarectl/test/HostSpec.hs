{-# LANGUAGE OverloadedStrings #-}

module HostSpec (hostTests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Host.Config
import Nagare.Target (ContextName, mkContextName)
import Nagare.Version (BuildVersion (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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
    , testCase "two contexts render isolated identities and registries" $ do
        prod <- either (assertFailure . T.unpack) pure (mkContextName "prod")
        labs <- either (assertFailure . T.unpack) pure (mkContextName "labs")
        let prodModule = renderHostModule (fixtureConfig prod)
            labsConfig =
              (fixtureConfig labs)
                { hostName = "labs-host"
                , instanceName = "labs-instance"
                , registryHost = "asia-northeast1-docker.pkg.dev"
                , authorizedKeys = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILabsFixtureKeyOnly labs@example" :| []
                }
            labsModule = renderHostModule labsConfig
        assertBool "prod has only its host" ("prod-host" `T.isInfixOf` prodModule && not ("labs-host" `T.isInfixOf` prodModule))
        assertBool "labs has only its registry" ("asia-northeast1-docker.pkg.dev" `T.isInfixOf` labsModule && not ("us-west1-docker.pkg.dev" `T.isInfixOf` labsModule))
        assertBool "operator keys do not cross contexts" (fixtureKey `T.isInfixOf` prodModule && not (fixtureKey `T.isInfixOf` labsModule))
    , testCase "staging and committing a release pin preserves operator-owned files" $
        withSystemTempDirectory "nagare-host-upgrade" $ \root -> do
          context <- either (assertFailure . T.unpack) pure (mkContextName "prod")
          let source = root </> "source"
              staged = root </> "transaction" </> "host"
              original = renderHostFlake (fixtureConfig context) (BuildVersion "0.1.0" (Just "old"))
              hostModule = renderHostModule (fixtureConfig context)
              secrets = "tailscaleAuthKey: ENC[AES256_GCM,data:test]\nsops: {}\n"
          createDirectoryIfMissing True source
          TIO.writeFile (source </> "flake.nix") original
          TIO.writeFile (source </> "host.nix") hostModule
          TIO.writeFile (source </> "secrets.yaml") secrets
          _ <- stageHostFlake source staged "/nix/store/new-nagare/nixos" (BuildVersion "0.2.0" (Just "new")) >>= either (assertFailure . T.unpack) pure
          stagedFlake <- TIO.readFile (staged </> "flake.nix")
          assertBool "target release is staged" ("Nagare platform version: 0.2.0" `T.isInfixOf` stagedFlake)
          assertBool "target NixOS input is staged" ("path:/nix/store/new-nagare/nixos" `T.isInfixOf` stagedFlake)
          TIO.readFile (staged </> "host.nix") >>= (@?= hostModule)
          TIO.readFile (staged </> "secrets.yaml") >>= (@?= secrets)
          commitStagedHostFlake staged source >>= either (assertFailure . T.unpack) pure
          TIO.readFile (source </> "host.nix") >>= (@?= hostModule)
          TIO.readFile (source </> "secrets.yaml") >>= (@?= secrets)
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
