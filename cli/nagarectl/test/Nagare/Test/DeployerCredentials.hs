-- | EP-248 D4, D7, D10 through fake adapters: the credential bundle, its
-- refusals, rotation that retires earlier handles only after the new bundle
-- is written, recovery from a partial issue, and the object store identity
-- the delegation scope reviews.
module Nagare.Test.DeployerCredentials
  ( deployerCredentialsTests
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (isPrefixOf, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Contract.Schema (fromNullable)
import Nagare.Deploy.Host (HostShape (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.DeployerCredentials
import Nagare.Inventory.DeployerDelegation
import Nagare.Inventory.DeployerStoreAccess
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import System.Directory (createDirectory, createDirectoryIfMissing, createFileLink, doesPathExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus)
import Test.Tasty
import Test.Tasty.HUnit

deployerCredentialsTests :: TestTree
deployerCredentialsTests =
  testGroup
    "Deployer credentials"
    [ testCase "D4: the bundle holds the context, a bound-token kubeconfig, the builder's and the store key, all private" $
        withSystemTempDirectory "bundle" $ \root -> do
          world <- newWorld []
          issued <- issueCredentials (ops world Nothing) (request (root </> "ci"))
          document <- either (assertFailure . T.unpack) pure issued
          let home = root </> "ci"
          context <- readText (home </> contextFilePathIn "mp33")
          assertBool "the deployer is named" ("export NAGARE_DEPLOYER=ci" `elem` T.lines context)
          assertBool "the operator name is dropped" (not ("NAGARE_OPERATOR" `T.isInfixOf` context))
          kubeconfig <- readText (home </> kubeconfigPathIn "mp33")
          assertBool "the deployer's token" ("token-nagare-deployer-ci" `T.isInfixOf` kubeconfig && "https://kubernetes.default.svc" `T.isInfixOf` kubeconfig)
          builder <- readText (home </> builderKubeconfigPathIn)
          assertBool "the builder's token" ("token-nagare-builder-ci" `T.isInfixOf` builder)
          store <- readText (home </> storeCredentialsPathIn "mp33")
          keys <- keysOf world
          case eitherDecodeStrict (TE.encodeUtf8 store) of
            Right (Object o) -> do
              KM.keys o @?= ["accessKeyId", "secretAccessKey"]
              map Just keys @?= [stringAt "accessKeyId" o]
            _ -> assertFailure "the store credential file is not JSON"
          forM_ [contextFilePathIn "mp33", kubeconfigPathIn "mp33", builderKubeconfigPathIn, storeCredentialsPathIn "mp33"] $ \file ->
            modeOf (home </> file) >>= (@?= 0o600)
          forM_ ["", ".config", ".config/nagare", ".config/nagare/kubeconfigs", "builder"] $ \directory ->
            modeOf (home </> directory) >>= (@?= 0o700)
          (document ^. #tokenExpiresAt, fromNullable (document ^. #storeKeyId)) @?= ("2026-12-11T00:00:00Z", Just "NGRKEY1")
          -- Every token is bound to this issue's handle Secret.
          calls <- readIORef (world ^. #calls)
          [call | call <- calls, "token" `elem` call] @?= [tokenCall "nagare-system" "nagare-deployer-ci", tokenCall "team-a-build" "nagare-builder-ci"]
          document ^. #retired @?= []
          keys @?= ["NGRKEY1"]
    , testCase "D7: running it again retires every earlier handle and key, only after the new bundle is written" $
        withSystemTempDirectory "bundle" $ \root -> do
          world <- newWorld ["nagare-deployer-ci-old1"]
          _ <- issueCredentials (ops world Nothing) (request (root </> "first")) >>= either (assertFailure . T.unpack) pure
          writeIORef (world ^. #checkBundle) (Just (root </> "second" </> kubeconfigPathIn "mp33"))
          document <- issueCredentials (ops world Nothing) ((request (root </> "second")) & #issue .~ "beef0002") >>= either (assertFailure . T.unpack) pure
          document ^. #retired @?= ["nagare-system/nagare-deployer-ci-cafe0001", "store-key/NGRKEY1", "team-a-build/nagare-builder-ci-cafe0001"]
          readIORef (world ^. #handles) >>= (@?= ["nagare-builder-ci-beef0002", "nagare-deployer-ci-beef0002"])
          keysOf world >>= (@?= ["NGRKEY2"])
          readIORef (world ^. #retiredBeforeBundle) >>= (@?= False)
    , testCase "D10: a failed key issue writes no bundle and retires nothing; a rerun retires the partial handles" $
        withSystemTempDirectory "bundle" $ \root -> do
          world <- newWorld ["nagare-deployer-ci-old1"]
          refused <- issueCredentials (ops world (Just "store unavailable")) (request (root </> "ci"))
          assertBool "refused" (isLeft refused)
          doesPathExist (root </> "ci" </> kubeconfigPathIn "mp33") >>= (@?= False)
          readIORef (world ^. #handles) >>= (@?= ["nagare-builder-ci-cafe0001", "nagare-deployer-ci-cafe0001", "nagare-deployer-ci-old1"])
          document <- issueCredentials (ops world Nothing) ((request (root </> "ci")) & #issue .~ "beef0002") >>= either (assertFailure . T.unpack) pure
          document ^. #retired @?= ["nagare-system/nagare-deployer-ci-cafe0001", "nagare-system/nagare-deployer-ci-old1", "team-a-build/nagare-builder-ci-cafe0001"]
    , testCase "D4: refuses a non-empty, a symbolic-linked and an in-repository directory, before any request" $
        withSystemTempDirectory "bundle" $ \root -> do
          createDirectory (root </> "full") >> BS.writeFile (root </> "full" </> "x") ""
          createDirectory (root </> "target") >> createFileLink (root </> "target") (root </> "link")
          createDirectoryIfMissing True (root </> "repo" </> ".git")
          forM_ [root </> "full", root </> "link", root </> "repo" </> "ci"] $ \out -> do
            world <- newWorld []
            refused <- issueCredentials (ops world Nothing) (request out)
            assertBool out (isLeft refused)
            readIORef (world ^. #calls) >>= (@?= [])
    , testCase "D10: the store policy reaches only the inventory prefix; revoking adds a Job removing the user" $ do
        policy <- either (assertFailure . T.unpack) pure (storePolicy storeAccess)
        assertBool "objects beneath the prefix" ("\"arn:aws:s3:::nagare-inventory/mp33/*\"" `T.isInfixOf` policy)
        assertBool "listing only the prefix" ("\"s3:prefix\":[\"mp33/*\"]" `T.isInfixOf` policy)
        assertBool "no bucket administration" (not (any (`T.isInfixOf` policy) ["s3:*", "DeleteBucket", "PutBucket", "nagare-backups"]))
        (active, _) <- either (assertFailure . show) pure (compileDelegationScope fixtureCluster systemNamespace (Just storeAccess) ciDelegation)
        (revoked, _) <- either (assertFailure . show) pure (compileDelegationScope fixtureCluster systemNamespace (Just storeAccess) (ciDelegation & #state .~ DelegationRevoked))
        storeMembersOf active @?= ["configmap/nagare-deployer-ci-store", "job/nagare-deployer-ci-store-grant"]
        storeMembersOf revoked @?= ["configmap/nagare-deployer-ci-store", "job/nagare-deployer-ci-store-grant", "job/nagare-deployer-ci-store-revoke"]
        assertBool "keys are never in the scripts" (not (any ("--secret-key \"$secret\"" `T.isInfixOf`) [policy]) && "read -r key; read -r secret" `T.isInfixOf` addKeyScript "ci" storeAccess)
    ]
  where
    tokenCall ns account = ["-n", ns, "create", "token", account, "--duration", "720h", "--bound-object-kind", "Secret", "--bound-object-name", account <> "-cafe0001", "-o", "json"]
    stringAt key o = case KM.lookup key o of
      Just (String value) -> Just value
      _ -> Nothing

storeMembersOf :: ScopeDeclaration -> [Text]
storeMembersOf scope =
  [ nameText kind <> "/" <> nameText name'
  | bundle <- scopeBundles scope
  , Managed resource <- bundle ^. #declarations
  , Kubernetes _ _ kind _ name' <- [resource ^. #address]
  , "-store" `T.isInfixOf` nameText name'
  ]

-- ---------------------------------------------------------------------------
-- A fake cluster: handle Secrets, tokens bound to them, and store keys.

data World = World
  { calls :: !(IORef [[String]])
  , handles :: !(IORef [Text])
  , keys :: !(IORef [Text])
  , checkBundle :: !(IORef (Maybe FilePath))
  , retiredBeforeBundle :: !(IORef Bool)
  }
  deriving stock (Generic)

newWorld :: [Text] -> IO World
newWorld existing = World <$> newIORef [] <*> newIORef existing <*> newIORef [] <*> newIORef Nothing <*> newIORef False

keysOf :: World -> IO [Text]
keysOf world = readIORef (world ^. #keys)

ops :: World -> Maybe Text -> CredentialOps
ops world storeFailure =
  CredentialOps
    { kubectl = fakeKubectl world
    , storeKeys =
        Just
          StoreKeyOps
            { addKey = \key _ -> case storeFailure of
                Just reason -> pure (Left reason)
                Nothing -> Right () <$ modifyIORef' (world ^. #keys) (<> [key])
            , retireKeysExcept = \keep -> do
                noteRetirement world
                existing <- readIORef (world ^. #keys)
                writeIORef (world ^. #keys) [keep]
                pure (Right [key | key <- existing, key /= keep])
            }
    , randomHex = \n -> do
        existing <- readIORef (world ^. #keys)
        pure (if n == 8 then "key" <> T.pack (show (length existing + 1)) else T.replicate (2 * n) "a")
    }

-- | Retiring before the new bundle exists would strand the deployer.
noteRetirement :: World -> IO ()
noteRetirement world =
  readIORef (world ^. #checkBundle) >>= \case
    Nothing -> pure ()
    Just path -> doesPathExist path >>= \present -> unless present (writeIORef (world ^. #retiredBeforeBundle) True)

fakeKubectl :: World -> Kubectl
fakeKubectl world arguments input = do
  modifyIORef' (world ^. #calls) (<> [arguments])
  case arguments of
    ["-n", _, "get", "configmap", "kube-root-ca.crt", "-o", "json"] -> ok "{\"data\":{\"ca.crt\":\"-----BEGIN CERTIFICATE-----\"}}"
    ["-n", _, "create", "-f", "-"]
      | Just name <- handleName input -> ok "" <* modifyIORef' (world ^. #handles) (\hs -> sortText (name : hs))
    ("-n" : _ : "create" : "token" : account : _) -> ok ("{\"status\":{\"token\":\"token-" <> account <> "\",\"expirationTimestamp\":\"2026-12-11T00:00:00Z\"}}")
    ["-n", _, "get", "secret", "-l", selector, "-o", _] -> do
      let account = drop (length (T.unpack handleLabel) + 1) selector
      hs <- readIORef (world ^. #handles)
      ok (unwords [T.unpack h | h <- hs, (account <> "-") `isPrefixOf` T.unpack h])
    ["-n", _, "delete", "secret", name, "--wait=true"] -> do
      noteRetirement world
      modifyIORef' (world ^. #handles) (filter (/= T.pack name))
      ok ""
    _ -> pure (Right (ExitFailure 1, "", "unexpected request " <> unwords arguments))
  where
    ok output = pure (Right (ExitSuccess, output, ""))
    handleName manifest = case eitherDecodeStrict (TE.encodeUtf8 (T.pack manifest)) of
      Right (Object root)
        | Just (String "nagare.dev/deployer-credential") <- KM.lookup "type" root
        , Just (Object metadata) <- KM.lookup "metadata" root
        , Just (String name) <- KM.lookup "name" metadata ->
            Just name
      _ -> Nothing
    sortText = sort

request :: FilePath -> CredentialRequest
request out =
  CredentialRequest
    { deployer = "ci"
    , context = "mp33"
    , out = out
    , duration = "720h"
    , operatorContext = "export CLOUDSDK_CORE_PROJECT=local\nexport NAGARE_MODE=local\nexport NAGARE_OPERATOR=alice\n"
    , buildNamespace = Just "team-a-build"
    , issue = "cafe0001"
    }

storeAccess :: StoreAccess
storeAccess = StoreAccess "http://minio.nagare-system.svc.cluster.local:9000" "nagare-inventory" "mp33" "k3d-registry.localhost:5000/nagare-mc@sha256:0000"

ciDelegation :: DeployerDelegation
ciDelegation =
  DeployerDelegation
    { name = "ci"
    , state = DelegationActive
    , namespaces = "team-a" :| []
    , hostSuffixes = ["-docs"]
    , kinds = DelegatedStaticSite :| []
    , imageRepository = "k3d-registry.localhost:5000/project/team-a"
    , team = "engineering"
    , buildNamespace = Just "team-a-build"
    , quota = defaultQuota
    , baseDomain = "127-0-0-1.sslip.io"
    , hostShape = NestedHosts
    }

fixtureCluster, systemNamespace :: ResourceId
fixtureCluster = mintResourceId (unsafe (mkScopeId Platform "cluster")) (unsafe (mkLogicalKey "cluster")) (unsafe (mkName "cluster"))
systemNamespace = mintResourceId (unsafe (mkScopeId Platform "foundation")) (unsafe (mkLogicalKey "foundation")) (unsafe (mkName "namespace-nagare-system"))

readText :: FilePath -> IO Text
readText path = TE.decodeUtf8 <$> BS.readFile path

modeOf :: FilePath -> IO Int
modeOf path = fromIntegral . (`mod` 0o1000) . fileMode <$> getFileStatus path

unsafe :: (Show e) => Either e a -> a
unsafe = either (error . show) id
