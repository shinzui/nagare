-- | Platform / KubernetesReview. Executable-private CLI boundary.
module Nagare.Cli.Platform.KubernetesReview
  ( applyClusterMarker
  , applyReviewedKubernetesPlan
  , saveReviewedKubernetesPlan
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Set (Set)
import Data.Text qualified as T
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Process (currentTimestamp, runExternal)
import Nagare.Cli.Runtime.ReviewFiles (cleanupPlanStaging)
import Nagare.Cluster.CertificateMigration qualified as CertificateMigration
import Nagare.Cluster.CertificatePolicy (parseLabeledNamespaces)
import Nagare.Dsl.Prelude
import Nagare.Infra.Plan (digestFile)
import Nagare.Platform.Status
  ( clusterMarkerValue
  , identityFromPayload
  )
import Nagare.Platform.Workspace
  ( PayloadManifest
  , PlatformWorkspace
  )
import Nagare.Target (ActiveTarget, contextNameText)
import System.Directory
  ( createDirectoryIfMissing
  , doesPathExist
  , listDirectory
  , pathIsSymbolicLink
  , renameDirectory
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeBaseName, takeDirectory, (</>))
import System.IO.Temp (createTempDirectory)
import System.Posix.Files
  ( fileMode
  , getFileStatus
  , isDirectory
  , isRegularFile
  , setFileMode
  )
import System.Process (readProcessWithExitCode)

kubernetesManifestFileName, kubernetesReviewFileName, kubernetesMetadataFileName :: FilePath
kubernetesManifestFileName = "config-network.json"
kubernetesReviewFileName = "review.json"
kubernetesMetadataFileName = "metadata.json"

currentKubernetesIdentity :: ActiveTarget -> PlatformWorkspace -> FilePath -> CertificateMigration.CurrentKubernetesIdentity
currentKubernetesIdentity active workspace txPath =
  CertificateMigration.CurrentKubernetesIdentity
    { CertificateMigration.currentTransactionId = T.pack (takeBaseName txPath)
    , CertificateMigration.currentContext = contextNameText (active ^. #contextName)
    , CertificateMigration.currentPayloadId = workspace ^. #payloadId
    , CertificateMigration.currentPayloadDigest = workspace ^. #digest
    }

saveReviewedKubernetesPlan :: ActiveTarget -> PlatformWorkspace -> FilePath -> FilePath -> IO (Either Text Text)
saveReviewedKubernetesPlan active workspace txPath destination = do
  exists <- doesPathExist destination
  if exists
    then do
      verified <- verifyReviewedKubernetesPlan active workspace txPath destination
      pure $
        fmap
          (\migration -> "Retained reviewed Kubernetes migration at " <> T.pack destination <> "\n" <> CertificateMigration.renderCertificateMigrationReview migration)
          verified
    else do
      observed <- captureCertificateMigrationInventory
      case observed of
        Left err -> pure (Left err)
        Right (config, optedIn, knativeCertificates, certManagerCertificates, secrets) ->
          case CertificateMigration.planCertificateMigration config optedIn knativeCertificates certManagerCertificates secrets of
            Left err -> pure (Left ("refusing Kubernetes migration plan: " <> err))
            Right migration -> save migration
  where
    save migration = do
      let parent = takeDirectory destination
      createDirectoryIfMissing True parent
      staging <- createTempDirectory parent ".nagare-kubernetes-plan-"
      setFileMode staging 0o700
      let manifestPath = staging </> kubernetesManifestFileName
          reviewPath = staging </> kubernetesReviewFileName
          metadataPath = staging </> kubernetesMetadataFileName
          manifestBytes = CertificateMigration.renderTargetConfigNetworkManifest
          reviewBytes = LBS.toStrict (Aeson.encode migration) <> "\n"
      BS.writeFile manifestPath manifestBytes
      BS.writeFile reviewPath reviewBytes
      setFileMode manifestPath 0o600
      setFileMode reviewPath 0o600
      manifestHash <- digestFile manifestPath
      reviewHash <- digestFile reviewPath
      let identity = currentKubernetesIdentity active workspace txPath
          metadata =
            CertificateMigration.KubernetesPlanMetadata
              { CertificateMigration.metadataSchemaVersion = 1
              , CertificateMigration.transactionId = CertificateMigration.currentTransactionId identity
              , CertificateMigration.context = CertificateMigration.currentContext identity
              , CertificateMigration.payloadId = CertificateMigration.currentPayloadId identity
              , CertificateMigration.payloadDigest = CertificateMigration.currentPayloadDigest identity
              , CertificateMigration.manifestDigest = manifestHash
              , CertificateMigration.reviewDigest = reviewHash
              }
      BS.writeFile metadataPath (LBS.toStrict (Aeson.encode metadata) <> "\n")
      setFileMode metadataPath 0o600
      diffResult <- case CertificateMigration.selectorChange migration of
        Nothing -> pure (Right "kubectl diff: TLS selector migration is not required")
        Just _ ->
          runExternal
            [ExitSuccess, ExitFailure 1]
            "kubectl"
            ["diff", "--server-side", "--force-conflicts", "--field-manager=nagare-upgrade", "-f", "-", "--request-timeout=5s"]
            (BC.unpack manifestBytes)
      case diffResult of
        Left err -> cleanupPlanStaging staging err
        Right diffEvidence -> do
          renamed <- try (renameDirectory staging destination)
          case renamed of
            Left (err :: IOException) -> cleanupPlanStaging staging ("could not publish Kubernetes migration bundle: " <> T.pack (show err))
            Right () ->
              pure
                ( Right
                    ( "Saved reviewed Kubernetes migration for context '"
                        <> CertificateMigration.currentContext identity
                        <> "' at "
                        <> T.pack destination
                        <> "\n"
                        <> CertificateMigration.renderCertificateMigrationReview migration
                        <> diffSuffix diffEvidence
                    )
                )
    diffSuffix evidence
      | T.null (T.strip evidence) = "kubectl diff: no server-side changes\n"
      | otherwise = evidence <> "\n"

verifyReviewedKubernetesPlan ::
  ActiveTarget ->
  PlatformWorkspace ->
  FilePath ->
  FilePath ->
  IO (Either Text CertificateMigration.CertificateMigrationPlan)
verifyReviewedKubernetesPlan active workspace txPath bundle = do
  loaded <- loadKubernetesPlanBundle bundle
  case loaded of
    Left err -> pure (Left err)
    Right (metadata, migration) -> do
      let identity = currentKubernetesIdentity active workspace txPath
      pure $ do
        first ("refusing Kubernetes plan: " <>) (CertificateMigration.verifyKubernetesPlanMetadata identity metadata)
        Right migration

loadKubernetesPlanBundle ::
  FilePath ->
  IO (Either Text (CertificateMigration.KubernetesPlanMetadata, CertificateMigration.CertificateMigrationPlan))
loadKubernetesPlanBundle bundle = do
  checked <- try (validateKubernetesPlanBundleSecurity bundle)
  case checked of
    Left (err :: IOException) -> pure (Left ("invalid Kubernetes plan bundle " <> T.pack bundle <> ": " <> T.pack (show err)))
    Right () -> do
      metadataBytes <- BS.readFile (bundle </> kubernetesMetadataFileName)
      reviewBytes <- BS.readFile (bundle </> kubernetesReviewFileName)
      decoded <- pure $ do
        metadata <- firstText "metadata.json" (Aeson.eitherDecodeStrict' metadataBytes)
        migration <- firstText "review.json" (Aeson.eitherDecodeStrict' reviewBytes)
        unless (metadataBytes == LBS.toStrict (Aeson.encode metadata) <> "\n") $
          Left "refusing Kubernetes plan: metadata.json is not in its canonical reviewed form"
        when (CertificateMigration.schemaVersion migration /= 1) (Left "unsupported Kubernetes review.json schema")
        Right (metadata, migration)
      case decoded of
        Left err -> pure (Left err)
        Right pair@(metadata, _) -> do
          manifestHash <- digestFile (bundle </> kubernetesManifestFileName)
          reviewHash <- digestFile (bundle </> kubernetesReviewFileName)
          pure $
            if manifestHash /= CertificateMigration.manifestDigest metadata
              then Left "refusing Kubernetes plan: config-network.json digest does not match metadata.json"
              else
                if reviewHash /= CertificateMigration.reviewDigest metadata
                  then Left "refusing Kubernetes plan: review.json digest does not match metadata.json"
                  else Right pair
  where
    firstText name = either (Left . (("invalid " <> name <> ": ") <>) . T.pack) Right

validateKubernetesPlanBundleSecurity :: FilePath -> IO ()
validateKubernetesPlanBundleSecurity bundle = do
  linked <- pathIsSymbolicLink bundle
  when linked (ioError (userError "bundle directory is a symlink"))
  bundleStatus <- getFileStatus bundle
  unless (isDirectory bundleStatus) (ioError (userError "bundle path is not a directory"))
  unless (privateMode bundleStatus) (ioError (userError "bundle directory is accessible by group or other users"))
  entries <- sort <$> listDirectory bundle
  unless (entries == sort [kubernetesManifestFileName, kubernetesMetadataFileName, kubernetesReviewFileName]) $
    ioError (userError "bundle must contain exactly config-network.json, metadata.json, and review.json")
  forM_ entries $ \entry -> do
    let path = bundle </> entry
    entryLinked <- pathIsSymbolicLink path
    when entryLinked (ioError (userError (entry <> " is a symlink")))
    status <- getFileStatus path
    unless (isRegularFile status) (ioError (userError (entry <> " is not a regular file")))
    unless (privateMode status) (ioError (userError (entry <> " is accessible by group or other users")))
  where
    privateMode status = fileMode status .&. 0o077 == 0

captureCertificateMigrationInventory ::
  IO
    ( Either
        Text
        ( CertificateMigration.ConfigNetworkObservation
        , Set Text
        , [CertificateMigration.CertificateResource]
        , [CertificateMigration.CertificateResource]
        , [CertificateMigration.SecretObservation]
        )
    )
captureCertificateMigrationInventory = do
  configBytes <- captureRequiredKubectl ["get", "configmap", "config-network", "-n", "knative-serving", "-o", "json", "--request-timeout=5s"]
  namespaceBytes <- captureRequiredKubectl ["get", "namespaces", "-l", "nagare.dev/app-namespace=true", "-o", "json", "--request-timeout=5s"]
  knativeBytes <- captureRequiredKubectl ["get", "certificates.networking.internal.knative.dev", "-A", "-o", "json", "--request-timeout=5s"]
  managerBytes <- captureRequiredKubectl ["get", "certificates.cert-manager.io", "-A", "-o", "json", "--request-timeout=5s"]
  secretBytes <- captureRequiredKubectl ["get", "secrets", "-A", "-o", "json", "--request-timeout=5s"]
  pure $ do
    config <- configBytes >>= first ("could not parse config-network: " <>) . CertificateMigration.parseConfigNetworkObservation
    namespaceInventory <- namespaceBytes
    optedIn <- maybe (Left "could not parse opted-in namespace inventory") Right (parseLabeledNamespaces namespaceInventory)
    knative <- knativeBytes >>= first ("could not parse Knative Certificate inventory: " <>) . CertificateMigration.parseKnativeCertificates
    managers <- managerBytes >>= first ("could not parse cert-manager Certificate inventory: " <>) . CertificateMigration.parseCertManagerCertificates
    secrets <- secretBytes >>= first ("could not parse Secret inventory: " <>) . CertificateMigration.parseSecretObservations
    Right (config, optedIn, knative, managers, secrets)

captureRequiredKubectl :: [String] -> IO (Either Text ByteString)
captureRequiredKubectl arguments = do
  result <- try (readProcessWithExitCode "kubectl" arguments "")
  pure $ case result of
    Left (err :: IOException) -> Left ("could not run kubectl: " <> T.pack (show err))
    Right (ExitSuccess, out, _) -> Right (BC.pack out)
    Right (ExitFailure code, out, err) ->
      Left
        ( "kubectl "
            <> T.unwords (map T.pack arguments)
            <> " exited "
            <> T.pack (show code)
            <> ": "
            <> T.strip (T.pack (err <> out))
        )

applyReviewedKubernetesPlan :: ActiveTarget -> PlatformWorkspace -> FilePath -> FilePath -> IO (Either Text Text)
applyReviewedKubernetesPlan active workspace txPath bundle = do
  guarded <- guardKubernetesContext active
  case guarded of
    Left err -> pure (Left err)
    Right guardEvidence -> do
      verified <- verifyReviewedKubernetesPlan active workspace txPath bundle
      case verified of
        Left err -> pure (Left err)
        Right migration -> case CertificateMigration.selectorChange migration of
          Nothing -> pure (Right (guardEvidence <> "\nKubernetes certificate migration: not required"))
          Just _ -> applyMigration guardEvidence migration
  where
    applyMigration guardEvidence migration = do
      observed <- captureCertificateMigrationInventory
      case observed of
        Left err -> pure (Left err)
        Right (config, _, knative, managers, secrets) ->
          case validateBeforeWrite migration config knative managers secrets of
            Left err -> pure (Left ("refusing Kubernetes migration apply: " <> err))
            Right () -> do
              let manifestBytes = CertificateMigration.renderTargetConfigNetworkManifest
              applied <-
                runExternal
                  [ExitSuccess]
                  "kubectl"
                  ["apply", "--server-side", "--force-conflicts", "--field-manager=nagare-upgrade", "-f", "-"]
                  (BC.unpack manifestBytes)
              case applied of
                Left err -> pure (Left err)
                Right applyEvidence -> do
                  converged <- waitForReviewedCertificates migration knative managers
                  case converged of
                    Left err -> pure (Left err)
                    Right waitEvidence -> do
                      deleted <- deleteReviewedSecrets migration
                      pure $
                        fmap
                          ( \deleteEvidence ->
                              guardEvidence
                                <> "\n"
                                <> CertificateMigration.renderCertificateMigrationReview migration
                                <> applyEvidence
                                <> "\n"
                                <> waitEvidence
                                <> deleteEvidence
                          )
                          deleted

validateBeforeWrite ::
  CertificateMigration.CertificateMigrationPlan ->
  CertificateMigration.ConfigNetworkObservation ->
  [CertificateMigration.CertificateResource] ->
  [CertificateMigration.CertificateResource] ->
  [CertificateMigration.SecretObservation] ->
  Either Text ()
validateBeforeWrite migration config knative managers secrets = do
  unless (CertificateMigration.externalDomainTlsEnabled config) $
    Left "external-domain-tls changed after review"
  case CertificateMigration.certificateSelector config of
    CertificateMigration.LegacyAllNamespaces -> Right ()
    CertificateMigration.TargetAppNamespaces -> Right ()
    CertificateMigration.UnsupportedSelector _ -> Left "namespace-wildcard-cert-selector changed after review"
  CertificateMigration.validateReviewedCleanup migration knative managers secrets

waitForReviewedCertificates ::
  CertificateMigration.CertificateMigrationPlan ->
  [CertificateMigration.CertificateResource] ->
  [CertificateMigration.CertificateResource] ->
  IO (Either Text Text)
waitForReviewedCertificates migration currentKnative currentManagers = do
  knativeResults <- traverse (waitIfPresent "certificates.networking.internal.knative.dev" currentKnative . CertificateMigration.knativeCertificate) (CertificateMigration.remove migration)
  case sequence knativeResults of
    Left err -> pure (Left err)
    Right knativeEvidence -> do
      managerResults <- traverse (waitIfPresent "certificates.cert-manager.io" currentManagers . CertificateMigration.certManagerCertificate) (CertificateMigration.remove migration)
      pure (fmap (T.concat . (knativeEvidence <>)) (sequence managerResults))
  where
    waitIfPresent resourceType observed reviewed =
      if any ((== CertificateMigration.certificateUid reviewed) . CertificateMigration.certificateUid) observed
        then
          fmap
            (fmap (const ("controller removed certificate: " <> certificateKey reviewed <> "\n")))
            ( runExternal
                [ExitSuccess]
                "kubectl"
                [ "wait"
                , "--for=delete"
                , resourceType <> "/" <> T.unpack (CertificateMigration.certificateName reviewed)
                , "-n"
                , T.unpack (CertificateMigration.certificateNamespace reviewed)
                , "--timeout=2m"
                ]
                ""
            )
        else pure (Right ("certificate already absent: " <> certificateKey reviewed <> "\n"))

deleteReviewedSecrets :: CertificateMigration.CertificateMigrationPlan -> IO (Either Text Text)
deleteReviewedSecrets migration = go [] (CertificateMigration.remove migration)
  where
    go evidence [] = pure (Right (T.concat (reverse evidence)))
    go evidence (chain : rest) = do
      observed <- captureCertificateMigrationInventory
      case observed of
        Left err -> pure (Left err)
        Right (_, _, knative, managers, secrets) ->
          case CertificateMigration.validateReviewedCleanup migration knative managers secrets of
            Left err -> pure (Left ("refusing Secret cleanup: " <> err))
            Right () -> do
              let reviewed = CertificateMigration.generatedSecret chain
                  present = any ((== CertificateMigration.secretUid reviewed) . CertificateMigration.secretUid) secrets
              if not present
                then go (("secret already absent: " <> secretKey reviewed <> "\n") : evidence) rest
                else do
                  deleted <-
                    runExternal
                      [ExitSuccess]
                      "kubectl"
                      [ "delete"
                      , "secret"
                      , T.unpack (CertificateMigration.secretResourceName reviewed)
                      , "-n"
                      , T.unpack (CertificateMigration.secretNamespace reviewed)
                      , "--wait=true"
                      ]
                      ""
                  case deleted of
                    Left err -> pure (Left err)
                    Right _ -> go (("deleted secret: " <> secretKey reviewed <> "\n") : evidence) rest

certificateKey :: CertificateMigration.CertificateResource -> Text
certificateKey resource = CertificateMigration.certificateNamespace resource <> "/" <> CertificateMigration.certificateName resource

secretKey :: CertificateMigration.SecretObservation -> Text
secretKey secret = CertificateMigration.secretNamespace secret <> "/" <> CertificateMigration.secretResourceName secret

applyClusterMarker :: PayloadManifest -> IO (Either Text Text)
applyClusterMarker manifest = do
  installedAt <- currentTimestamp
  let marker = LBC.unpack (Aeson.encode (clusterMarkerValue (identityFromPayload manifest) installedAt))
  runExternal [ExitSuccess] "kubectl" ["apply", "-f", "-"] marker
