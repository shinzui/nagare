{-# LANGUAGE OverloadedStrings #-}

module HostSpec (hostTests) where

import Control.Exception (finally)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Cluster.Kubeconfig
  ( FetchOps (..)
  , KubeconfigIdentity (..)
  , fetchKubeconfig
  , normalizeKubeconfig
  )
import Nagare.Dsl.Prelude
import Nagare.Host.AgeKey
import Nagare.Host.Config
import Nagare.Target (ContextName, Mode (..), PulumiBackendKind (..), TargetProfile (..), contextNameText, mkContextName)
import Nagare.Version (BuildVersion (..))
import System.Directory
  ( Permissions (executable, readable)
  , createDirectoryIfMissing
  , createDirectoryLink
  , createFileLink
  , getPermissions
  , setPermissions
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, setFileMode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

hostTests :: TestTree
hostTests =
  testGroup
    "Nagare.Host"
    [ testCase "validates public keys and rejects private material" $ do
        validateSshPublicKey fixtureKey @?= Right fixtureKey
        assertBool "private key is rejected" (either (const True) (const False) (validateSshPublicKey "-----BEGIN OPENSSH PRIVATE KEY-----"))
        assertBool "unknown key type is rejected" (either (const True) (const False) (validateSshPublicKey "ssh-dss AAAAB3NzaC1kc3MAAACBAexample"))
    , testCase "IR-18: validates and hashes the exact local age-key bytes without retaining the body" $
        withSystemTempDirectory "nagare-age-key" $ \root -> do
          let valid = root </> "valid.agekey"
              empty = root </> "empty.agekey"
              malformed = root </> "malformed.agekey"
              multiple = root </> "multiple.agekey"
              directory = root </> "directory"
              unreadable = root </> "unreadable.agekey"
          BS.writeFile valid ("# created for test\n" <> fixtureAgeKey)
          inspected <- inspectLocalAgeKey valid >>= either (assertFailure . T.unpack) pure
          inspected ^. #path @?= valid
          inspected ^. #sha256 @?= T.pack (show (hash ("# created for test\n" <> fixtureAgeKey) :: Digest SHA256))

          BS.writeFile empty ""
          assertAgeKeyRejected "empty" empty
          BS.writeFile malformed "not-an-age-identity\n"
          assertAgeKeyRejected "private-identity" malformed
          BS.writeFile multiple (fixtureAgeKey <> fixtureAgeKey)
          assertAgeKeyRejected "exactly one" multiple
          createDirectoryIfMissing True directory
          assertAgeKeyRejected "regular file" directory
          assertAgeKeyRejected "does not exist" (root </> "missing.agekey")
          BS.writeFile unreadable fixtureAgeKey
          permissions <- getPermissions unreadable
          setPermissions unreadable (permissions {readable = False})
          assertAgeKeyRejected "not readable" unreadable
    , testCase "IR-18: confines placement to the explicit context and keeps key bytes out of argv and env" $
        withSystemTempDirectory "nagare-place-age-key" $ \root -> do
          let keyPath = root </> "labs.agekey"
              labsProfile :: TargetProfile
              labsProfile = fixtureProfile & #instanceName .~ "labs-instance"
              parentEnv = [("NAGARE_CONTEXT", "prod"), ("PRESERVE_ME", "yes")]
          BS.writeFile keyPath fixtureAgeKey
          calls <- newIORef ([] :: [([(String, String)], [String])])
          let transport childEnv arguments = do
                bytes <- BS.readFile (arguments !! 2)
                let transportedDigest = show (hash bytes :: Digest SHA256)
                arguments !! 9 @?= transportedDigest
                previous <- readIORef calls
                writeIORef calls (previous <> [(childEnv, arguments)])
                pure (ExitSuccess, "ready", "")

          placeAgeKeyWith transport parentEnv "labs" labsProfile keyPath False >>= (@?= Right ())
          placeAgeKeyWith transport parentEnv "labs" labsProfile keyPath True >>= (@?= Right ())
          recorded <- readIORef calls
          case recorded of
            [(defaultEnv, defaultArgs), (forcedEnv, forcedArgs)] -> do
              let secretText = BC.unpack fixtureAgeKey
              lookup "NAGARE_CONTEXT" defaultEnv @?= Just "labs"
              lookup "PRESERVE_ME" defaultEnv @?= Just "yes"
              defaultArgs
                @?= [ "send-file"
                    , "labs-instance"
                    , keyPath
                    , "--"
                    , "sudo"
                    , "--"
                    , "/run/current-system/sw/bin/nagare-host-age-key"
                    , "install"
                    , "--sha256"
                    , show (hash fixtureAgeKey :: Digest SHA256)
                    ]
              forcedArgs @?= defaultArgs <> ["--force"]
              assertBool "key body is absent from argv" (all (not . (secretText `isInfixOf`)) (defaultArgs <> forcedArgs))
              assertBool "key body is absent from env" (all (not . (secretText `isInfixOf`) . snd) (defaultEnv <> forcedEnv))
            _ -> assertFailure ("expected two transport calls, got " <> show recorded)
    , testCase "IR-18: local mode rejects placement before validation or transport" $ do
        let localProfile = fixtureProfile {mode = Local}
            unusedTransport _ _ = assertFailure "transport must not run" >> pure (ExitSuccess, "", "")
        result <- placeAgeKeyWith unusedTransport [] "local" localProfile "/missing/key" False
        assertBool "local-mode refusal is explicit" (either (T.isInfixOf "unavailable for local contexts") (const False) result)
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
        validateRetargetableHostFlake flake @?= Right ()
        assertBool
          "arbitrary flake is not retargetable"
          (either (const True) (const False) (validateRetargetableHostFlake "{ inputs.nagare.url = builtins.throw \"edited\"; }"))
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
    , testCase "IR-20: reads the context-owned explicit host name" $
        withSystemTempDirectory "nagare-host-name" $ \root ->
          withXdgConfigHome root $ do
            context <- mkTestContext "labs"
            let hostRoot = root </> "nagare" </> "hosts" </> "labs"
            createDirectoryIfMissing True hostRoot
            TIO.writeFile
              (hostRoot </> "host.nix")
              "{ ... }:\n{\n  hostName = \"labs-edge\";\n}\n"
            readContextHostName context >>= (@?= Right "labs-edge")
    , testCase "BUG-2: rejects missing, absent, duplicate, and unreadable generated host names" $
        withSystemTempDirectory "nagare-host-name-errors" $ \root ->
          withXdgConfigHome root $ do
            context <- mkTestContext "labs"
            let hostRoot = root </> "nagare" </> "hosts" </> "labs"
                modulePath = hostRoot </> "host.nix"
            readContextHostName context >>= assertLeftContains "context 'labs'"
            createDirectoryIfMissing True hostRoot
            TIO.writeFile modulePath "{ ... }: { }\n"
            readContextHostName context >>= assertLeftContains "does not declare hostName"
            TIO.writeFile modulePath "{ ... }: {\n  hostName = \"labs-nagare\";\n  hostName = \"sibling\";\n}\n"
            readContextHostName context >>= assertLeftContains "more than once"
            originalPermissions <- getPermissions modulePath
            setPermissions modulePath originalPermissions {readable = False}
            readContextHostName context
              `finally` setPermissions modulePath originalPermissions
              >>= assertLeftContains "could not read host configuration"
    , testCase "BUG-2: upgrade host environment overwrites ambient logical identities" $ do
        let identity = hostSwitchIdentity "labs-nagare"
            environment = hostSwitchEnvironment "/transaction/host-flake" identity
        lookup "NAGARE_HOST_FLAKE" environment @?= Just "/transaction/host-flake"
        lookup "NAGARE_HOST_ATTR" environment @?= Just "labs-nagare"
        lookup "NAGARE_SSH_HOST" environment @?= Just "labs-nagare"
        lookup "NAGARE_INSTANCE_NAME" environment @?= Nothing
    , testCase "IR-20: normalizes the sole k3s identity without changing credentials" $ do
        let identity = KubeconfigIdentity "labs" "labs-nagare"
        case normalizeKubeconfig identity fixtureKubeconfig of
          Left err -> assertFailure (T.unpack err)
          Right normalized -> do
            assertBool "renames every default identity" (BC.count 'l' normalized > 0 && not ("name: default" `BS.isInfixOf` normalized))
            assertBool "sets the context host endpoint" ("https://labs-nagare:6443" `BS.isInfixOf` normalized)
            assertBool "preserves client certificate data" (fixtureSecret `BS.isInfixOf` normalized)
    , testCase "IR-20: fetch is context-scoped, private, and atomic on kubectl failure" $
        withSystemTempDirectory "nagare-kubeconfig-fetch" $ \root -> do
          let bin = root </> "bin"
              iap = bin </> "fake-iap"
              kubectl = bin </> "fake-kubectl"
              source = root </> "source.yaml"
              logPath = root </> "tools.log"
              outputDir = root </> "output"
              destination = outputDir </> "labs.yaml"
              identity = KubeconfigIdentity "labs" "labs-nagare"
              ops = FetchOps iap kubectl
          createDirectoryIfMissing True bin
          createDirectoryIfMissing True outputDir
          setFileMode outputDir 0o700
          BS.writeFile source fixtureKubeconfig
          BS.writeFile logPath ""
          writeExecutable
            iap
            [ "#!/bin/sh"
            , "printf 'NAGARE_CONTEXT=%s|%s\\n' \"$NAGARE_CONTEXT\" \"$*\" >> \"$NAGARE_FAKE_TOOL_LOG\""
            , "cp \"$NAGARE_KUBECONFIG_SOURCE\" \"$4\""
            ]
          writeExecutable
            kubectl
            [ "#!/bin/sh"
            , "printf 'KUBECONFIG=%s|%s\\n' \"$KUBECONFIG\" \"$*\" >> \"$NAGARE_FAKE_TOOL_LOG\""
            , "if [ \"${NAGARE_FAKE_KUBECTL_FAIL:-0}\" = 1 ]; then echo 'fixture kubectl failure' >&2; exit 17; fi"
            , "if [ \"$*\" = 'config current-context' ]; then printf '%s\\n' labs; fi"
            ]
          withEnvironmentPairs
            [("NAGARE_FAKE_TOOL_LOG", logPath), ("NAGARE_KUBECONFIG_SOURCE", source)]
            $ do
              result <- fetchKubeconfig ops identity fixtureProfile destination
              result @?= Right ()
              installed <- BS.readFile destination
              assertBool "installed kubeconfig preserves credentials" (fixtureSecret `BS.isInfixOf` installed)
              status <- getFileStatus destination
              fileMode status .&. 0o777 @?= 0o600
              calls <- TIO.readFile logPath
              assertBool "IAP receives context, instance, remote path, and a staging path" $
                "NAGARE_CONTEXT=labs|recv-file nagare-01 /etc/rancher/k3s/k3s.yaml " `T.isInfixOf` calls
              assertBool "kubectl always receives the staging kubeconfig" $
                all ("KUBECONFIG=" `T.isPrefixOf`) (filter ("|config " `T.isInfixOf`) (T.lines calls))
              assertBool "kubectl sets the context-specific cluster endpoint" $
                "|config set-cluster labs --server=https://labs-nagare:6443" `T.isInfixOf` calls

              BS.writeFile destination "known-good\n"
              setEnv "NAGARE_FAKE_KUBECTL_FAIL" "1"
              failed <- fetchKubeconfig ops identity fixtureProfile destination
              unsetEnv "NAGARE_FAKE_KUBECTL_FAIL"
              assertBool "the injected kubectl failure is reported" (either (T.isInfixOf "fixture kubectl failure") (const False) failed)
              BS.readFile destination >>= (@?= "known-good\n")
              assertBool "errors never echo client credentials" (either (not . T.isInfixOf (TE.decodeUtf8 fixtureSecret)) (const False) failed)
    , testCase "IR-20: fetch refuses symlink destinations" $
        withSystemTempDirectory "nagare-kubeconfig-symlink" $ \root -> do
          let target = root </> "target"
              destination = root </> "labs.yaml"
          BS.writeFile target "keep\n"
          createFileLink target destination
          result <- fetchKubeconfig (FetchOps "/unused/iap" "/unused/kubectl") (KubeconfigIdentity "labs" "labs-nagare") fixtureProfile destination
          assertBool "symlink destination is rejected before transport" (either (T.isInfixOf "symlink") (const False) result)
    , testCase "IR-20: fetch refuses dangling symlink destinations" $
        withSystemTempDirectory "nagare-kubeconfig-dangling-symlink" $ \root -> do
          let destination = root </> "labs.yaml"
          createFileLink (root </> "missing-target") destination
          result <- fetchKubeconfig (FetchOps "/unused/iap" "/unused/kubectl") (KubeconfigIdentity "labs" "labs-nagare") fixtureProfile destination
          assertBool "dangling symlink destination is rejected before transport" (either (T.isInfixOf "symlink") (const False) result)
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

fixtureAgeKey :: BS.ByteString
fixtureAgeKey = BC.concat ["AGE-", "SECRET-", "KEY-1TESTFIXTUREONLY\n"]

assertLeftContains :: Text -> Either Text a -> Assertion
assertLeftContains needle (Left message) =
  assertBool ("expected " <> show message <> " to contain " <> show needle) (needle `T.isInfixOf` message)
assertLeftContains needle (Right _) =
  assertFailure ("expected Left containing " <> show needle <> ", got Right")

assertAgeKeyRejected :: Text -> FilePath -> Assertion
assertAgeKeyRejected expected keyPath = do
  result <- inspectLocalAgeKey keyPath
  assertBool
    ("expected rejection containing " <> T.unpack expected <> ", got " <> show result)
    (either (T.isInfixOf expected) (const False) result)

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

fixtureKubeconfig :: BS.ByteString
fixtureKubeconfig =
  BC.unlines
    [ "apiVersion: v1"
    , "kind: Config"
    , "clusters:"
    , "- name: default"
    , "  cluster:"
    , "    server: https://127.0.0.1:6443"
    , "    certificate-authority-data: Y2EtZml4dHVyZQ=="
    , "users:"
    , "- name: default"
    , "  user:"
    , "    client-certificate-data: " <> fixtureSecret
    , "    client-key-data: a2V5LWZpeHR1cmU="
    , "contexts:"
    , "- name: default"
    , "  context:"
    , "    cluster: default"
    , "    user: default"
    , "current-context: default"
    ]

fixtureSecret :: BS.ByteString
fixtureSecret = "Y2VydC1maXh0dXJl"

fixtureProfile :: TargetProfile
fixtureProfile =
  TargetProfile
    { project = "labs-project"
    , region = "us-west1"
    , zone = "us-west1-a"
    , registryHost = "us-west1-docker.pkg.dev"
    , artifactRegistryId = "nagare"
    , imageBucket = "labs-project-nagare-images"
    , backupBucket = "labs-project-nagare-backups"
    , nixCacheEnabled = False
    , nixCacheBucket = "labs-project-nagare-nix-cache"
    , baseDomain = "apps.example.com"
    , externalDomainTlsEnabled = False
    , instanceName = "nagare-01"
    , machineType = "e2-standard-2"
    , bootDiskType = "pd-balanced"
    , bootDiskSizeGb = "100"
    , dataDiskSizeGb = "100"
    , targetPlatform = "linux/amd64"
    , mode = Cloud
    , localObjectStore = ""
    , pulumiBackend = PulumiBackendLocal
    , pulumiBackendUrl = ""
    , acmeEmail = "ops@example.com"
    , acmeDirectory = "production"
    , platformVersion = Just "0.2.2"
    }

writeExecutable :: FilePath -> [String] -> IO ()
writeExecutable path linesToWrite = do
  writeFile path (unlines linesToWrite)
  permissions <- getPermissions path
  setPermissions path (permissions {executable = True})

withEnvironmentPairs :: [(String, String)] -> IO a -> IO a
withEnvironmentPairs pairs action = do
  saved <- traverse (\(name, _) -> (,) name <$> lookupEnv name) pairs
  mapM_ (uncurry setEnv) pairs
  action `finally` mapM_ (\(name, value) -> maybe (unsetEnv name) (setEnv name) value) saved
