-- | Explicit-context Helm 4 transport. The reviewed chart and values are
-- checked again, and the verify post-renderer refuses changed native bytes.
module Nagare.Inventory.Adapters.HelmRuntime
  ( HelmRuntimeConfig (..)
  , HelmStatusError (..)
  , helmRuntimeOps
  , parseStatus
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict', fromJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Helm
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import System.Directory (createDirectory, createDirectoryLink, makeAbsolute)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, splitDirectories, takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)

data HelmRuntimeConfig = HelmRuntimeConfig
  { helmKubeContext :: !Text
  , helmContextId :: !ContextId
  , helmVerifyPlugin :: !FilePath
  , helmDeclarations :: !(Map ResourceId ManagedResource)
  , helmRuntimeGuard :: !(IO (Either Text ()))
  }

data HelmStatusError = HelmStatusUnavailable !Text | HelmStatusForeign !Text
  deriving stock (Eq, Show)

helmRuntimeOps :: HelmRuntimeConfig -> HelmAdapterOps
helmRuntimeOps config =
  HelmAdapterOps
    { helmObserve = observeRelease config
    , helmMutateConditional = mutateRelease config
    }

observeRelease :: HelmRuntimeConfig -> ResourceId -> IO HelmState
observeRelease config resource = do
  guarded <- helmRuntimeGuard config
  case guarded of
    Left reason -> pure (HelmUnavailable reason)
    Right () -> observeGuarded config resource

observeGuarded :: HelmRuntimeConfig -> ResourceId -> IO HelmState
observeGuarded config resource = case Map.lookup resource (helmDeclarations config) of
  Nothing -> pure (HelmUnavailable "Helm declaration is absent from runtime")
  Just declaration -> case declaration ^. #address of
    Helm _ namespace release -> do
      status <-
        run
          "helm"
          [ "status"
          , T.unpack (nameText release)
          , "--kube-context"
          , T.unpack (helmKubeContext config)
          , "--namespace"
          , T.unpack (nameText namespace)
          , "-o"
          , "json"
          ]
          Nothing
      case status of
        Left reason -> pure (HelmUnavailable reason)
        Right (ExitFailure _, _, err)
          | T.strip (T.pack err) == "Error: release: not found" ->
              pure (HelmAbsent (contentDigest (TE.encodeUtf8 (helmKubeContext config <> "/" <> nameText namespace <> "/" <> nameText release))))
          | otherwise -> pure (HelmUnavailable (T.pack err))
        Right (ExitSuccess, output, _) -> case parseStatus config resource (TE.encodeUtf8 (T.pack output)) of
          Left (HelmStatusUnavailable reason) -> pure (HelmUnavailable reason)
          Left (HelmStatusForeign reason) -> pure (HelmForeign reason)
          Right (revision, digest, deployed) -> do
            secret <-
              run
                "kubectl"
                [ "--context"
                , T.unpack (helmKubeContext config)
                , "-n"
                , T.unpack (nameText namespace)
                , "get"
                , "secret"
                , "sh.helm.release.v1." <> T.unpack (nameText release) <> ".v" <> T.unpack revision
                , "-o"
                , "json"
                ]
                Nothing
            pure $ case secret of
              Left reason -> HelmUnavailable reason
              Right (ExitFailure _, _, err) -> HelmUnavailable (T.pack err)
              Right (ExitSuccess, bytes, _) -> case parseUid (TE.encodeUtf8 (T.pack bytes)) of
                Left reason -> HelmUnavailable reason
                Right uid | deployed -> HelmPresent uid revision resource digest
                Right uid -> HelmUnready uid revision resource digest
    _ -> pure (HelmUnavailable "Helm runtime declaration has no release address")

parseStatus :: HelmRuntimeConfig -> ResourceId -> ByteString -> Either HelmStatusError (Text, ContentDigest, Bool)
parseStatus config resource bytes = do
  root <- first (HelmStatusUnavailable . T.pack) (eitherDecodeStrict' bytes)
    >>= first HelmStatusUnavailable . asObject "Helm status"
  version <- first HelmStatusUnavailable (field "version" root)
  revision <- case fromJSON version of
    Success (number :: Int) | number > 0 -> Right (T.pack (show number))
    _ -> Left (HelmStatusUnavailable "Helm release has no positive revision")
  info <- first HelmStatusUnavailable (field "info" root >>= asObject "Helm status info")
  status <- first HelmStatusUnavailable (field "status" info >>= asText "status")
  description <- first HelmStatusForeign (field "description" info >>= asText "description")
  digest <- case T.splitOn "|" description of
    ["nagare-inventory-v1", context, owner, revisionDigest]
      | context == contextIdText (helmContextId config) && owner == resourceIdText resource ->
          first HelmStatusForeign (mkContentDigest revisionDigest)
    _ -> Left (HelmStatusForeign "Helm release lacks the reviewed context and logical owner stamp")
  pure (revision, digest, status == "deployed")

parseUid :: ByteString -> Either Text PhysicalIdentity
parseUid bytes = do
  root <- first T.pack (eitherDecodeStrict' bytes) >>= asObject "Helm release Secret"
  metadata <- field "metadata" root >>= asObject "Secret metadata"
  uid <- field "uid" metadata >>= asText "uid"
  mkPhysicalIdentity uid

mutateRelease :: HelmRuntimeConfig -> HelmMutation -> IO AdapterExecution
mutateRelease config mutation = do
  before <- observeRelease config (helmMutationResource mutation)
  if before /= helmMutationBefore mutation
    then pure (AdapterEffectFailed (KnownNoEffect "Helm release revision changed before execution"))
    else case (helmMutationAddress mutation, eitherDecodeStrict' (TE.encodeUtf8 (helmMutationContract mutation))) of
      (Helm _ namespace release, Right (Object contract)) -> do
        preflight <- checkContract contract
        case preflight of
          Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
          Right (chart, values, renderDigest) -> do
            result <-
              try
                ( withSystemTempDirectory "nagare-helm-apply" $ \temporary -> do
                    let plugins = temporary </> "plugins"
                    createDirectory plugins
                    plugin <- makeAbsolute (helmVerifyPlugin config)
                    createDirectoryLink plugin (plugins </> "nagare-reviewed-manifests")
                    environment <- getEnvironment
                    let clean = filter (\(key, _) -> key `notElem` ["HELM_PLUGINS", "NAGARE_HELM_REVIEW_SHA256"]) environment
                        description =
                          T.unpack
                            ( T.intercalate
                                "|"
                                [ "nagare-inventory-v1"
                                , contextIdText (helmContextId config)
                                , resourceIdText (helmMutationResource mutation)
                                , digestText (helmMutationContractDigest mutation)
                                ]
                            )
                        arguments =
                          [ "upgrade"
                          , "--install"
                          , T.unpack (nameText release)
                          , chart
                          , "--kube-context"
                          , T.unpack (helmKubeContext config)
                          , "--namespace"
                          , T.unpack (nameText namespace)
                          , "--values"
                          , values
                          , "--skip-crds"
                          , "--post-renderer"
                          , "nagare-reviewed-manifests"
                          , "--description"
                          , description
                          , "--wait"
                          , "--wait-for-jobs"
                          , "--timeout"
                          , "10m"
                          ]
                    run
                      "helm"
                      arguments
                      ( Just
                          ( ("HELM_PLUGINS", plugins)
                              : ("NAGARE_HELM_REVIEW_SHA256", T.unpack (digestText renderDigest))
                              : clean
                          )
                      )
                ) ::
                IO (Either IOException (Either Text (ExitCode, String, String)))
            pure $ case result of
              Left failure -> AdapterEffectAmbiguous (T.pack (show failure))
              Right (Left reason) -> AdapterEffectAmbiguous reason
              Right (Right (ExitSuccess, _, _)) -> AdapterEffectCompleted
              Right (Right (ExitFailure _, _, err))
                | "rendered manifests differ from the retained review" `T.isInfixOf` T.pack err ->
                    AdapterEffectFailed (KnownNoEffect "Helm post-renderer refused changed native bytes")
                | otherwise -> AdapterEffectAmbiguous (T.pack err)
      _ -> pure (AdapterEffectFailed (KnownNoEffect "Helm reviewed contract or address is malformed"))
  where
    checkContract contract = do
      case parsed of
        Left reason -> pure (Left reason)
        Right (chart, values, chartDigest, valuesDigest, renderDigest, helmVersion, kubeVersion) -> do
          chartBytes <- first (T.pack . show) <$> (try (BS.readFile (T.unpack chart)) :: IO (Either IOException ByteString))
          valuesBytes <- first (T.pack . show) <$> (try (BS.readFile (T.unpack values)) :: IO (Either IOException ByteString))
          version <- run "helm" ["version", "--short"] Nothing
          kubernetes <- run "kubectl" ["--context", T.unpack (helmKubeContext config), "version", "-o", "json"] Nothing
          pure $ do
            actualChart <- chartBytes
            actualValues <- valuesBytes
            unless
              (contentDigest actualChart == chartDigest && contentDigest actualValues == valuesDigest)
              (Left "packaged Helm chart or values changed after review")
            (_, actualVersion, _) <- successful "Helm version" version
            unless (T.strip (T.pack actualVersion) == helmVersion) (Left "Helm executable version changed after review")
            (_, kubeOutput, _) <- successful "Kubernetes version" kubernetes
            server <- first T.pack (eitherDecodeStrict' (TE.encodeUtf8 (T.pack kubeOutput))) >>= asObject "Kubernetes version"
            serverVersion <- field "serverVersion" server >>= asObject "Kubernetes serverVersion"
            gitVersion <- field "gitVersion" serverVersion >>= asText "gitVersion"
            unless (gitVersion == kubeVersion) (Left "Kubernetes capability version changed after review")
            pure (T.unpack chart, T.unpack values, renderDigest)
      where
        parsed = do
          chart <- field "chartPath" contract >>= asText "chartPath" >>= resolvePath
          values <- field "valuesPath" contract >>= asText "valuesPath" >>= resolvePath
          chartDigest <- field "chartDigest" contract >>= asText "chartDigest" >>= mkContentDigest
          valuesDigest <- field "valuesDigest" contract >>= asText "valuesDigest" >>= mkContentDigest
          renderDigest <- field "renderDigest" contract >>= asText "renderDigest" >>= mkContentDigest
          helmVersion <- field "helmVersion" contract >>= asText "helmVersion"
          kubeVersion <- field "kubeVersion" contract >>= asText "kubeVersion"
          hookPolicy <- field "hookPolicy" contract >>= asText "hookPolicy"
          crdPolicy <- field "crdPolicy" contract >>= asText "crdPolicy"
          unless
            (hookPolicy == "include-rendered-hooks")
            (Left "Helm hook policy differs from the reviewed contract")
          unless
            (crdPolicy == "conditional-direct-apply-and-helm-skip-crds")
            (Left "Helm CRD policy differs from the reviewed contract")
          pure (chart, values, chartDigest, valuesDigest, renderDigest, helmVersion, kubeVersion)
        resolvePath raw = case T.stripPrefix "payload:" raw of
          Nothing -> Right raw
          Just suffix
            | T.null suffix || isAbsolute path || any (`elem` [".", ".."]) (splitDirectories path) ->
                Left "reviewed Helm payload path is invalid"
            | otherwise -> Right (T.pack (takeDirectory (helmVerifyPlugin config) </> path))
            where
              path = T.unpack suffix

run :: FilePath -> [String] -> Maybe [(String, String)] -> IO (Either Text (ExitCode, String, String))
run command arguments environment = do
  result <-
    try (readCreateProcessWithExitCode ((proc command arguments) {env = environment}) "") ::
      IO (Either IOException (ExitCode, String, String))
  pure (first (T.pack . show) result)

successful :: Text -> Either Text (ExitCode, String, String) -> Either Text (ExitCode, String, String)
successful label result = do
  triple@(code, _, err) <- result
  case code of
    ExitSuccess -> Right triple
    ExitFailure _ -> Left (label <> " probe failed: " <> T.pack err)

field :: Text -> KM.KeyMap Value -> Either Text Value
field key root = maybe (Left ("missing " <> key)) Right (KM.lookup (Key.fromText key) root)

asObject :: Text -> Value -> Either Text (KM.KeyMap Value)
asObject label = \case Object root -> Right root; _ -> Left (label <> " is not an object")

asText :: Text -> Value -> Either Text Text
asText label = \case String value -> Right value; _ -> Left (label <> " is not text")
