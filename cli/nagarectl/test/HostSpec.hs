{-# LANGUAGE OverloadedStrings #-}

module HostSpec (hostTests) where

import Control.Exception (finally)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Prelude
import Nagare.Host.Config
import Nagare.Target (ContextName, contextNameText, mkContextName)
import Nagare.Version (BuildVersion (..))
import System.Directory (createDirectoryIfMissing, createDirectoryLink)
import System.Environment (lookupEnv, setEnv, unsetEnv)
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
    , testCase "IR-14: derives distinct default host names without changing the instance name" $ do
        prod <- mkTestContext "prod"
        labs <- mkTestContext "labs"
        defaultHostName prod @?= Right "prod-nagare"
        defaultHostName labs @?= Right "labs-nagare"
        let prodConfig = (fixtureConfig prod) {name = either (const "unreachable") id (defaultHostName prod), instanceName = "nagare-01"}
            labsConfig = (fixtureConfig labs) {name = either (const "unreachable") id (defaultHostName labs), instanceName = "nagare-01"}
        assertBool "host identities differ" (prodConfig ^. #name /= labsConfig ^. #name)
        prodConfig ^. #instanceName @?= "nagare-01"
        labsConfig ^. #instanceName @?= "nagare-01"
    , testCase "IR-14: rejects lossy or overlong default host-name derivation" $ do
        mapM_ assertRejected ["Prod", "prod_ops", "prod.ops", "-prod", "prod-", T.replicate 57 "a"]
        longestValid <- mkTestContext (T.replicate 56 "a")
        defaultHostName longestValid @?= Right (T.replicate 56 "a" <> "-nagare")
    , testCase "IR-14: discovers an implicit host-name collision across context-owned flakes" $
        withSystemTempDirectory "nagare-host-collision" $ \root ->
          withXdgConfigHome (root </> "missing-config") $ do
            prod <- mkTestContext "prod"
            labs <- mkTestContext "labs"
            legacy <- mkTestContext "legacy"
            findHostNameCollision prod "prod-nagare" >>= (@?= Right Nothing)

            let regularXdg = root </> "regular-config"
                regularHosts = regularXdg </> "nagare" </> "hosts"
            setEnv "XDG_CONFIG_HOME" regularXdg
            writeHostModule regularHosts prod "prod-nagare"
            writeHostModule regularHosts labs "labs-nagare"
            BS.writeFile (regularHosts </> "README.md") "not a context directory\n"
            findHostNameCollision prod "prod-nagare" >>= (@?= Right Nothing)
            writeHostModule regularHosts legacy "prod-nagare"
            findHostNameCollision prod "prod-nagare"
              >>= (@?= Right (Just (legacy, regularHosts </> "legacy" </> "host.nix")))
            findHostNameCollision prod "explicit-nagare" >>= (@?= Right Nothing)

            let linkedXdg = root </> "linked-config"
                linkedHosts = linkedXdg </> "nagare" </> "hosts"
                operatorHosts = root </> "operator-repository" </> "hosts"
            createDirectoryIfMissing True (linkedXdg </> "nagare")
            writeHostModule operatorHosts legacy "prod-nagare"
            createDirectoryLink operatorHosts linkedHosts
            setEnv "XDG_CONFIG_HOME" linkedXdg
            findHostNameCollision prod "prod-nagare"
              >>= (@?= Right (Just (legacy, linkedHosts </> "legacy" </> "host.nix")))

            let unreadableXdg = root </> "unreadable-config"
                unreadableModule = unreadableXdg </> "nagare" </> "hosts" </> "legacy" </> "host.nix"
            createDirectoryIfMissing True (unreadableXdg </> "nagare" </> "hosts" </> "legacy")
            BS.writeFile unreadableModule (BS.pack [0xFF])
            setEnv "XDG_CONFIG_HOME" unreadableXdg
            unreadable <- findHostNameCollision prod "prod-nagare"
            assertBool "an unreadable sibling fails closed and names its path" $
              either (T.isInfixOf (T.pack unreadableModule)) (const False) unreadable
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
    , testCase "IR-13: the rendered operator module matches the golden host.nix checked against the NixOS module" $ do
        -- nix/checks/scripts/host-module-options-agree.sh fails the flake check when
        -- this golden file sets an option nixos/modules/nagare-host.nix does not
        -- declare, so a renamed Haskell field cannot silently rename a Nix option.
        context <- either (assertFailure . T.unpack) pure (mkContextName "prod")
        golden <- TIO.readFile "test/fixtures/host/host.nix"
        renderHostModule (fixtureConfig context) @?= golden
    , testCase "two contexts render isolated identities and registries" $ do
        prod <- either (assertFailure . T.unpack) pure (mkContextName "prod")
        labs <- either (assertFailure . T.unpack) pure (mkContextName "labs")
        let prodModule = renderHostModule (fixtureConfig prod)
            labsConfig =
              (fixtureConfig labs)
                { name = "labs-host"
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
    { context = context
    , name = "prod-host"
    , instanceName = "prod-instance"
    , registryHost = "us-west1-docker.pkg.dev"
    , deployUser = "deploy"
    , authorizedKeys = fixtureKey :| []
    , ageKeyFile = "/var/lib/sops-nix/age-key.txt"
    , nagareNixosSource = "/opt/nagare/nixos"
    }

fixtureKey :: Text
fixtureKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyForNagareEvaluationOnly operator@example"

mkTestContext :: Text -> IO ContextName
mkTestContext = either (assertFailure . T.unpack) pure . mkContextName

assertRejected :: Text -> Assertion
assertRejected raw = do
  value <- mkTestContext raw
  assertBool ("expected default derivation to reject " <> T.unpack raw) (either (const True) (const False) (defaultHostName value))

writeHostModule :: FilePath -> ContextName -> Text -> IO ()
writeHostModule hostsRoot hostContext hostName = do
  let directory = hostsRoot </> T.unpack (contextNameText hostContext)
  createDirectoryIfMissing True directory
  TIO.writeFile (directory </> "host.nix") ("{ ... }: { nagare.host.hostName = \"ignored\"; }\n  hostName = \"" <> hostName <> "\";\n")

withXdgConfigHome :: FilePath -> IO a -> IO a
withXdgConfigHome xdg action = do
  saved <- lookupEnv "XDG_CONFIG_HOME"
  setEnv "XDG_CONFIG_HOME" xdg
  action `finally` maybe (unsetEnv "XDG_CONFIG_HOME") (setEnv "XDG_CONFIG_HOME") saved
