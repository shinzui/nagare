-- | EP-248 D6 through a fake gcloud: the delegated deployer's cloud
-- principal, its derived Pulumi config and catalog entries, key creation
-- into the bundle, retiring earlier keys only after the bundle is written,
-- and the project assertion refusing before any gcloud call.
module Nagare.Test.DeployerCloudAccess
  ( deployerCloudAccessTests
  )
where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (isInfixOf, isSuffixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Contract.Schema (fromNullable)
import Nagare.Deploy.Host (HostShape (..))
import Nagare.Dsl.Prelude
import Nagare.Gcp.Adc (AdcObservation (..), AdcSource (..))
import Nagare.Inventory.Cloud
import Nagare.Inventory.DeployerCloudAccess
import Nagare.Inventory.DeployerCredentials
import Nagare.Inventory.DeployerDelegation
import Nagare.Ops.ContextGuard (ProjectGuardInputs (..), PulumiProjectObservation (..), projectGuardVerdict)
import Nagare.Resource.Types
import Nagare.Target (InventoryStoreKind (..), Mode (..), PulumiBackendKind (..), TargetProfile)
import Nagare.Test.Support.Profiles (initProfile)
import System.Directory (doesPathExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus)
import Test.Tasty
import Test.Tasty.HUnit

deployerCloudAccessTests :: TestTree
deployerCloudAccessTests =
  testGroup
    "Deployer cloud access"
    [ testCase "D6: the derived config lists only active delegations, with their account IDs and the inventory prefix" $ do
        let long = kotei & #name .~ "a-rather-long-deployer-name" & #imageRepository .~ "us-west1-docker.pkg.dev/acme-prod/long-images"
            longAccount = deployerCloudAccountId (long ^. #name)
        keys <- expectRight (delegatedDeployerConfigKeys "intranet" profile [kotei, long])
        keys
          @?= [ ("nagare:delegatedDeployers", "[{\"accountId\":\"" <> longAccount <> "\",\"imageRepository\":\"us-west1-docker.pkg.dev/acme-prod/long-images\",\"name\":\"a-rather-long-deployer-name\"},{\"accountId\":\"nagare-deployer-kotei\",\"imageRepository\":\"us-west1-docker.pkg.dev/acme-prod/kotei-images\",\"name\":\"kotei\"}]")
              , ("nagare:stateBucket", "acme-prod-nagare-pulumi-state")
              , ("nagare:adminApiInventoryPrefix", "nagare/intranet/inventory")
              ]
        assertBool "a shared repository is refused" (isLeft (delegatedDeployerConfigKeys "intranet" profile [kotei, kotei & #name .~ "other"]))
        delegatedDeployerConfigKeys "intranet" profile [] @?= Right []
        -- The list is read from the accepted delegation scopes; a revoked one
        -- stays with its account disabled, so revoking retires nothing (D7).
        (active, _) <- expectRight (compileDelegationScope fixtureCluster systemNamespace Nothing kotei)
        (revoked, _) <- expectRight (compileDelegationScope fixtureCluster systemNamespace Nothing (long & #state .~ DelegationRevoked))
        map (\d -> (d ^. #name, d ^. #state)) (cloudDelegatedDeployers [active, revoked]) @?= [("a-rather-long-deployer-name", DelegationRevoked), ("kotei", DelegationActive)]
        disabled <- expectRight (delegatedDeployerConfigKeys "intranet" profile (cloudDelegatedDeployers [active, revoked]))
        assertBool "a revoked delegation's account is disabled" (any (\(key, value) -> key == "nagare:delegatedDeployers" && "\"disabled\":true,\"imageRepository\":\"us-west1-docker.pkg.dev/acme-prod/long-images\"" `T.isInfixOf` value) disabled)
        T.take 24 longAccount @?= "nagare-deployer-a-rathe-"
        forM_ ["a-rather-long-deployer-name", "kotei", "x"] $ \deployer -> do
          let account = deployerCloudAccountId deployer
          assertBool (T.unpack account) (T.length account >= 6 && T.length account <= 30 && not ("-" `T.isSuffixOf` account))
        deployerCloudAccountEmail "acme-prod" "kotei" @?= "nagare-deployer-kotei@acme-prod.iam.gserviceaccount.com"
    , testCase "D6: an image repository outside the context's project and region, or the platform's own, has no principal" $ do
        delegatedRepositoryId profile kotei @?= Right "kotei-images"
        delegatedRepositoryId profile (kotei & #imageRepository .~ "us-west1-docker.pkg.dev/acme-prod/kotei-images/site") @?= Right "kotei-images"
        forM_
          [ "us-west1-docker.pkg.dev/acme-prod/nagare/site"
          , "us-west1-docker.pkg.dev/other-project/kotei/site"
          , "europe-west1-docker.pkg.dev/acme-prod/kotei/site"
          , "k3d-registry.localhost:5000/project/team-a"
          , "us-west1-docker.pkg.dev/acme-prod"
          ]
          $ \repository -> assertBool (T.unpack repository) (isLeft (delegatedRepositoryId profile (kotei & #imageRepository .~ repository)))
        assertBool "a refused repository refuses the derived config" (isLeft (delegatedDeployerConfigKeys "intranet" profile [kotei & #imageRepository .~ "us-west1-docker.pkg.dev/acme-prod/nagare"]))
    , testCase "D6: the catalog's delegated deployer template is instantiated once per delegation, above every other layer" $ do
        catalog <- expectRight (decodeCloudCatalog catalogBytes)
        catalogDelegatedDeployers catalog @?= []
        instantiated <- expectRight (withDelegatedDeployers ["kotei"] catalog)
        map (nameText . catalogNativeName) (selectedCloudCatalog False False False False instantiated)
          @?= ["nagare", "nagare-delegated-deployer-kotei", "nagare-delegated-deployer-kotei-store"]
        urn <- expectRight (cloudCatalogUrn (unsafe (mkName "intranet")) instantiated (last (catalogDelegatedDeployers instantiated)))
        urn @?= "urn:pulumi:intranet::nagare::nagare:env:NagareDelegatedDeployer$gcp:storage/bucketIAMMember:BucketIAMMember::nagare-delegated-deployer-kotei-store"
        assertBool "a template without the placeholder is refused" (isLeft (decodeCloudCatalog (BC.pack (T.unpack (T.replace "-{deployer}-store" "-store" (TE.decodeUtf8 catalogBytes))))))
    , testCase "D6: the bundle holds the key, a gcloud configuration for the context's project and its number, all private" $
        withSystemTempDirectory "bundle" $ \root -> do
          world <- newWorld ["old1"]
          keyOps <- gcloudKeyOps (pure (Right ())) (fakeGcloud world) "acme-prod" "kotei"
          document <- issueCredentials (credentialOps world keyOps) (request (root </> "kotei")) >>= either (assertFailure . T.unpack) pure
          let home = root </> "kotei"
          BS.readFile (home </> cloudKeyPathIn) >>= (@?= keyJson "key2")
          BS.readFile (home </> gcloudConfigPathIn </> "configurations" </> "config_default")
            >>= (@?= "[core]\nproject = acme-prod\naccount = nagare-deployer-kotei@acme-prod.iam.gserviceaccount.com\n")
          BS.readFile (home </> gcloudConfigPathIn </> "active_config") >>= (@?= "default")
          BS.readFile (home </> ".cache/nagare/project-numbers/acme-prod") >>= (@?= "123456789012")
          forM_ [cloudKeyPathIn, gcloudConfigPathIn </> "configurations" </> "config_default"] $ \file -> modeOf (home </> file) >>= (@?= 0o600)
          forM_ [".config/gcloud", ".config/gcloud/configurations", ".cache"] $ \directory -> modeOf (home </> directory) >>= (@?= 0o700)
          fromNullable (document ^. #cloudKeyId) @?= Just "key2"
          document ^. #retired @?= ["cloud-key/old1"]
          readIORef (world ^. #keys) >>= (@?= ["key2"])
          calls <- readIORef (world ^. #gcloudCalls)
          assertBool "every gcloud call names the context's project" (all (["--project", "acme-prod"] `isSuffixOf`) calls)
          -- The number is read first, the key created, and only then are earlier keys listed and deleted.
          map (take 4) calls
            @?= [ ["projects", "describe", "acme-prod", "--format=value(projectNumber)"]
                , ["iam", "service-accounts", "keys", "create"]
                , ["iam", "service-accounts", "keys", "list"]
                , ["iam", "service-accounts", "keys", "delete"]
                ]
          assertBool "the key is the deployer account's" (all (\call -> "projects" `elem` call || ["--iam-account", "nagare-deployer-kotei@acme-prod.iam.gserviceaccount.com"] `isInfixOf` call) calls)
    , testCase "D6: earlier keys are retired only after the new bundle is written; a failed issue deletes none" $
        withSystemTempDirectory "bundle" $ \root -> do
          world <- newWorld ["old1"]
          writeIORef (world ^. #failCreate) True
          keyOps <- gcloudKeyOps (pure (Right ())) (fakeGcloud world) "acme-prod" "kotei"
          refused <- issueCredentials (credentialOps world keyOps) (request (root </> "first"))
          assertBool "a failed key creation is refused" (isLeft refused)
          doesPathExist (root </> "first" </> cloudKeyPathIn) >>= (@?= False)
          readIORef (world ^. #keys) >>= (@?= ["old1"])
          writeIORef (world ^. #failCreate) False
          writeIORef (world ^. #checkBundle) (Just (root </> "second" </> cloudKeyPathIn))
          document <- issueCredentials (credentialOps world keyOps) (request (root </> "second")) >>= either (assertFailure . T.unpack) pure
          document ^. #retired @?= ["cloud-key/old1"]
          readIORef (world ^. #retiredBeforeBundle) >>= (@?= False)
    , testCase "D6: the project assertion refuses with its own message before any gcloud or cluster call (ADR 9)" $
        withSystemTempDirectory "bundle" $ \root -> do
          world <- newWorld ["old1"]
          let refusal = projectGuardVerdict (guardInputs (Just "someone-elses-project"))
          expected <- either pure (const (assertFailure "the guard accepted another project")) refusal
          keyOps <- gcloudKeyOps (pure refusal) (fakeGcloud world) "acme-prod" "kotei"
          issueCredentials (credentialOps world keyOps) (request (root </> "kotei")) >>= (@?= Left expected) . fmap (const ())
          readIORef (world ^. #gcloudCalls) >>= (@?= [])
          readIORef (world ^. #kubectlCalls) >>= (@?= 0)
          doesPathExist (root </> "kotei" </> cloudKeyPathIn) >>= (@?= False)
          readIORef (world ^. #keys) >>= (@?= ["old1"])
          assertBool "the refusal names the configured project" ("someone-elses-project" `T.isInfixOf` expected)
          projectGuardVerdict (guardInputs (Just "acme-prod")) @?= Right ()
    ]

-- ---------------------------------------------------------------------------
-- A fake gcloud and cluster.

data World = World
  { gcloudCalls :: !(IORef [[String]])
  , kubectlCalls :: !(IORef Int)
  , keys :: !(IORef [Text])
  , failCreate :: !(IORef Bool)
  , checkBundle :: !(IORef (Maybe FilePath))
  , retiredBeforeBundle :: !(IORef Bool)
  }
  deriving stock (Generic)

newWorld :: [Text] -> IO World
newWorld existing = World <$> newIORef [] <*> newIORef 0 <*> newIORef existing <*> newIORef False <*> newIORef Nothing <*> newIORef False

fakeGcloud :: World -> Gcloud
fakeGcloud world arguments = do
  modifyIORef' (world ^. #gcloudCalls) (<> [arguments])
  case arguments of
    "projects" : "describe" : _ -> ok "123456789012\n"
    "iam" : "service-accounts" : "keys" : "create" : path : _ ->
      readIORef (world ^. #failCreate) >>= \case
        True -> pure (Right (ExitFailure 1, "", "ERROR: (gcloud.iam.service-accounts.keys.create) quota exceeded"))
        False -> do
          existing <- readIORef (world ^. #keys)
          let key = "key" <> T.pack (show (length existing + 1))
          BS.writeFile path (keyJson key)
          writeIORef (world ^. #keys) (existing <> [key])
          ok ""
    "iam" : "service-accounts" : "keys" : "list" : _ -> do
      existing <- readIORef (world ^. #keys)
      ok ("[" <> T.unpack (T.intercalate "," ["{\"name\":\"projects/acme-prod/serviceAccounts/nagare-deployer-kotei@acme-prod.iam.gserviceaccount.com/keys/" <> key <> "\"}" | key <- existing]) <> "]")
    "iam" : "service-accounts" : "keys" : "delete" : key : _ -> do
      readIORef (world ^. #checkBundle) >>= \case
        Nothing -> pure ()
        Just path -> doesPathExist path >>= \present -> unless present (writeIORef (world ^. #retiredBeforeBundle) True)
      modifyIORef' (world ^. #keys) (filter (/= T.pack key))
      ok ""
    _ -> pure (Right (ExitFailure 1, "", "unexpected gcloud " <> unwords arguments))
  where
    ok output = pure (Right (ExitSuccess, output, ""))

-- | A cluster that issues handles and tokens and holds no earlier handles.
fakeKubectl :: World -> Kubectl
fakeKubectl world arguments _ = do
  modifyIORef' (world ^. #kubectlCalls) (+ 1)
  pure . Right $ case arguments of
    ["-n", _, "get", "configmap", "kube-root-ca.crt", "-o", "json"] -> (ExitSuccess, "{\"data\":{\"ca.crt\":\"-----BEGIN CERTIFICATE-----\"}}", "")
    ("-n" : _ : "create" : "token" : account : _) -> (ExitSuccess, "{\"status\":{\"token\":\"token-" <> account <> "\",\"expirationTimestamp\":\"2026-12-11T00:00:00Z\"}}", "")
    _ -> (ExitSuccess, "", "")

credentialOps :: World -> CloudKeyOps -> CredentialOps
credentialOps world keyOps =
  CredentialOps
    { kubectl = fakeKubectl world
    , storeKeys = Nothing
    , cloudKeys = Just keyOps
    , randomHex = \n -> pure (T.replicate (2 * n) "a")
    }

request :: FilePath -> CredentialRequest
request out =
  CredentialRequest
    { deployer = "kotei"
    , context = "intranet"
    , out = out
    , duration = "720h"
    , operatorContext = "export CLOUDSDK_CORE_PROJECT=acme-prod\nexport NAGARE_MODE=cloud\n"
    , buildNamespace = Nothing
    , issue = "cafe0001"
    }

keyJson :: Text -> BS.ByteString
keyJson key = TE.encodeUtf8 ("{\"type\":\"service_account\",\"private_key_id\":\"" <> key <> "\",\"private_key\":\"-----BEGIN PRIVATE KEY-----\"}")

guardInputs :: Maybe Text -> ProjectGuardInputs
guardInputs configured =
  ProjectGuardInputs
    { context = "intranet"
    , declared = "acme-prod"
    , stack = "intranet"
    , pulumiBackendUrl = "gs://acme-prod-nagare-pulumi-state/nagare/intranet"
    , stackProject = PulumiProjectFound "acme-prod"
    , ambient = Nothing
    , configured = configured
    , gcloudAccount = Just "operator@example.com"
    , adc =
        Right
          AdcObservation
            { source = AdcEnvironmentFile "/credentials.json"
            , credentialKind = "authorized_user"
            , principal = Just "operator@example.com"
            , quotaProject = Just "acme-prod"
            }
    }

profile :: TargetProfile
profile =
  initProfile
    & #project
    .~ "acme-prod"
    & #region
    .~ "us-west1"
    & #artifactRegistryId
    .~ "nagare"
    & #mode
    .~ Cloud
    & #pulumiBackend
    .~ PulumiBackendGcs
    & #inventoryStore
    .~ InventoryStoreGcs
    & #inventoryStoreUrl
    .~ ""

kotei :: DeployerDelegation
kotei =
  DeployerDelegation
    { name = "kotei"
    , state = DelegationActive
    , namespaces = "team-a" :| []
    , hostSuffixes = ["-docs"]
    , kinds = DelegatedStaticSite :| []
    , imageRepository = "us-west1-docker.pkg.dev/acme-prod/kotei-images"
    , team = "engineering"
    , buildNamespace = Nothing
    , quota = defaultQuota
    , baseDomain = "apps.example.com"
    , hostShape = NestedHosts
    }

catalogBytes :: BS.ByteString
catalogBytes =
  BC.pack
    "{\"version\":1,\"project\":\"nagare\",\"foundationManaged\":[{\"type\":\"nagare:env:NagarePerimeter\",\"name\":\"nagare\",\"parent\":null,\"layer\":0}],\"nixCacheEnabled\":[],\"delegatedDeployerEnabled\":[{\"type\":\"nagare:env:NagareDelegatedDeployer\",\"name\":\"nagare-delegated-deployer-{deployer}\",\"parent\":null,\"layer\":15},{\"type\":\"gcp:storage/bucketIAMMember:BucketIAMMember\",\"name\":\"nagare-delegated-deployer-{deployer}-store\",\"parent\":\"nagare-delegated-deployer-{deployer}\",\"layer\":17}]}"

fixtureCluster, systemNamespace :: ResourceId
fixtureCluster = mintResourceId (unsafe (mkScopeId Platform "cluster")) (unsafe (mkLogicalKey "cluster")) (unsafe (mkName "cluster"))
systemNamespace = mintResourceId (unsafe (mkScopeId Platform "foundation")) (unsafe (mkLogicalKey "foundation")) (unsafe (mkName "namespace-nagare-system"))

modeOf :: FilePath -> IO Int
modeOf path = fromIntegral . (`mod` 0o1000) . fileMode <$> getFileStatus path

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

unsafe :: (Show e) => Either e a -> a
unsafe = either (error . show) id
