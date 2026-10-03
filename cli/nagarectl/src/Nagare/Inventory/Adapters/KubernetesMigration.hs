-- | Native stages for the bounded PostgreSQL rename under EP-149's migration
-- contract. Planning recomputes each reviewed stage digest from the accepted
-- source, the observed source incarnation and the destination, so the private
-- bundle cannot drift from what review approved. Execution acts only from
-- that bundle, checks exact UIDs and ownership stamps before every effect,
-- and proves each stage by re-observation. Every other action is delegated
-- unchanged to the wrapped Kubernetes adapter.
module Nagare.Inventory.Adapters.KubernetesMigration
  ( MigrationPlanning (..)
  , kubernetesMigrationAdapter
  , renameProposal
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes (KubernetesMutation (..))
import Nagare.Inventory.Adapters.KubernetesRuntime (completedJobContainerMessageFromPodList)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), invokeKubectl)
import Nagare.Inventory.Migration (MigrationInput (..), MigrationTarget (..))
import Nagare.Inventory.Migration.PostgresRename
import Nagare.Inventory.Migration.Types (ValidatedMigration (..), migrationStageDigest)
import Nagare.Inventory.Store (ScopeRevision)
import Nagare.Resource.Canonical (canonicalValue)
import Nagare.Resource.Inventory (CompositionCandidate, Executor (KubernetesExecutor), ManagedResource, candidateInventory, inventoryBinding)
import Nagare.Resource.Policy (RecoveryClass (Idempotent))
import Nagare.Resource.Types
import Nagare.Resource.Wire ()
import System.Exit (ExitCode (..))

-- | What a reviewed rename planner knows that execution must not recapture:
-- the accepted source members and the compiled destination members.
data MigrationPlanning = MigrationPlanning
  { sources :: !(Map ResourceId (ScopeRevision, ManagedResource, ByteString))
  , destinations :: !(Map ResourceId (ManagedResource, ByteString))
  }
  deriving stock (Generic)

data Bundle = Bundle
  { operation :: !OperationId
  , inputDigest :: !ContentDigest
  , stage :: !MigrationStage
  , resource :: !ResourceId
  , member :: !RenameMember
  , scope :: !RenameScope
  , sourceAddress :: !ProviderAddress
  , sourcePhysical :: !PhysicalIdentity
  , destinationAddress :: !ProviderAddress
  , destinationDigest :: !ContentDigest
  , destinationNative :: !Text
  , create :: !(Maybe Text)
  , writerAddress :: !ProviderAddress
  , writerPhysical :: !PhysicalIdentity
  }
  deriving stock (Generic)

bundleFormat :: Text
bundleFormat = "kubernetes-postgres-rename-v1"

kubernetesMigrationAdapter :: KubernetesRuntimeConfig -> Maybe MigrationPlanning -> Adapter -> Adapter
kubernetesMigrationAdapter config planning base =
  base
    { adapterPrepare = prepare
    , adapterPreflight = whenMigration (adapterPreflight base) Left preflight
    , adapterExecute = whenMigration (adapterExecute base) (AdapterEffectFailed . KnownNoEffect) execute
    , adapterVerify = whenMigration (adapterVerify base) Left verify
    , adapterRecover = whenMigration (adapterRecover base) RecoveryUnresolved recover
    }
  where
    whenMigration :: (PlannedOperation -> PreparedNative -> IO a) -> (Text -> a) -> (Bundle -> IO a) -> PlannedOperation -> PreparedNative -> IO a
    whenMigration fallback refused handler planned prepared = case plannedAction planned of
      MigrateResource _ -> either (pure . refused) handler (decodeBundle planned prepared)
      _ -> fallback planned prepared

    prepare planned = case plannedAction planned of
      MigrateResource selected -> case planning of
        Nothing -> pure (Left (PrepareRefused (plannedOperationId planned) "migration stages are prepared only by the reviewed rename planner"))
        Just context -> do
          prepared <- prepareStage context planned selected
          pure (first (PrepareRefused (plannedOperationId planned)) prepared)
      _ -> adapterPrepare base planned

    prepareStage context planned selected = case NE.toList (plannedResources planned) of
      [resourceId]
        | plannedExecutor planned == KubernetesExecutor
        , Just (revision, source, _) <- Map.lookup resourceId (context ^. #sources)
        , Just (destination, native) <- Map.lookup resourceId (context ^. #destinations) -> do
            let staticFacts = do
                  kind <- renameMember destination
                  sourceKind <- renameMember source
                  unless (kind == sourceKind) (Left "source and destination roles differ")
                  facts <-
                    renameScope
                      (fmap (\(_, declaration, bytes) -> (declaration, bytes)) (context ^. #sources))
                      (context ^. #destinations)
                      (source ^. #owner)
                  contract <- renameContract facts source
                  writerDeclaration <-
                    maybe
                      (Left "rename writer has no accepted declaration")
                      (\(_, declaration, _) -> Right declaration)
                      (Map.lookup (facts ^. #writer) (context ^. #sources))
                  pure (kind, facts, contract, writerDeclaration ^. #address)
            case staticFacts of
              Left reason -> pure (Left reason)
              Right (kind, facts, contract, writer) -> do
                observedSource <- observeOwned (source ^. #address) resourceId
                observedWriter <- observeOwned writer (facts ^. #writer)
                observedDestination <- getObject (destination ^. #address)
                -- Every stage carries the stamped destination object; only
                -- PrepareDestination of a non-Secret member replays the create.
                created <- adapterPrepare base planned {plannedAction = CreateResource}
                pure $ do
                  (physical, _) <- observedSource
                  (writerUid, _) <- observedWriter
                  destinationState <- observedDestination
                  unless (isNothing destinationState) (Left "rename destination address is already occupied")
                  let absence = contentDigest (TE.encodeUtf8 (resourceIdText resourceId <> ":absent"))
                  reviewed <-
                    migrationStageDigest
                      resourceId
                      (ValidatedMigration (revision, source) destination physical absence contract)
                  unless
                    (reviewed == plannedInputDigest planned)
                    (Left ("migration stage for " <> resourceIdText resourceId <> " differs from the reviewed source incarnation or contract"))
                  baseCreate <- first showPrepare created
                  stamped <- first T.pack (eitherDecodeStrict (preparedNativeBytes baseCreate))
                  let bundle =
                        Bundle
                          { operation = plannedOperationId planned
                          , inputDigest = plannedInputDigest planned
                          , stage = selected
                          , resource = resourceId
                          , member = kind
                          , scope = facts
                          , sourceAddress = source ^. #address
                          , sourcePhysical = physical
                          , destinationAddress = destination ^. #address
                          , destinationDigest = contentDigest native
                          , destinationNative = mutationNativeJson stamped
                          , create =
                              if selected == PrepareDestination && kind `notElem` [RenameCredential, RenameSigningKey]
                                then Just (TE.decodeUtf8 (preparedNativeBytes baseCreate))
                                else Nothing
                          , writerAddress = writer
                          , writerPhysical = writerUid
                          }
                  bytes <- canonicalValue (encodeBundle bundle)
                  pure (PreparedNative bytes (summary bundle))
      _ -> pure (Left "migration stage names no accepted source and compiled destination")

    showPrepare = \case
      PrepareRefused _ reason -> reason
      PreparationBlocked barrier -> barrierReason barrier

    createOperation bundle =
      PlannedOperation
        (bundle ^. #operation)
        CreateResource
        KubernetesExecutor
        (bundle ^. #resource NE.:| [])
        (bundle ^. #inputDigest)
        []
        Idempotent

    createPrepared bundle = case bundle ^. #create of
      Just bytes -> Right (PreparedNative (TE.encodeUtf8 bytes) (summary bundle))
      Nothing -> Left "rename member has no reviewed create bundle"

    -- Preconditions: no stage acts on an incarnation other than the one
    -- review observed, and no stage starts before its inputs exist.
    preflight bundle = case (bundle ^. #stage, bundle ^. #member) of
      (PrepareDestination, kind)
        | kind `elem` [RenameCredential, RenameSigningKey] -> do
            source <- sourceOwned bundle
            destination <- getObject (bundle ^. #destinationAddress)
            pure (source >> destination >>= maybe (Right ()) (const (Left "rename destination appeared before its copy")))
        | otherwise -> case createPrepared bundle of
            Left reason -> pure (Left reason)
            Right prepared -> do
              source <- sourceOwned bundle
              created <- adapterPreflight base (createOperation bundle) prepared
              pure (source >> created)
      (FenceWriters, kind) | kind `elem` [RenameVolume, RenameWorkload] -> void <$> writerOwned bundle
      (TransferState, RenameVolume) -> do
        fenced <- writerFenced bundle
        source <- sourceOwned bundle
        destination <- destinationOwned bundle
        pure (fenced >> source >> void destination)
      (stageName, _)
        | stageName `elem` [BackUpSource, FenceWriters, RetainSource] -> sourceOwned bundle
        | otherwise -> void <$> destinationOwned bundle

    execute bundle = do
      checked <- preflight bundle
      case checked of
        Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
        Right () -> case (bundle ^. #stage, bundle ^. #member) of
          (PrepareDestination, kind)
            | kind `elem` [RenameCredential, RenameSigningKey] -> copySecret bundle
            | otherwise -> either (pure . AdapterEffectFailed . KnownNoEffect) (adapterExecute base (createOperation bundle)) (createPrepared bundle)
          (FenceWriters, kind) | kind `elem` [RenameVolume, RenameWorkload] -> fenceWriter bundle
          (TransferState, RenameVolume) -> do
            transferred <- runTransfer bundle TransferCopy
            pure (either AdapterEffectAmbiguous (const AdapterEffectCompleted) transferred)
          _ -> pure AdapterEffectCompleted

    verify bundle = case (bundle ^. #stage, bundle ^. #member) of
      (PrepareDestination, kind)
        | kind `elem` [RenameCredential, RenameSigningKey] -> secretCopied bundle
        | otherwise -> either (pure . Left) (adapterVerify base (createOperation bundle)) (createPrepared bundle)
      (FenceWriters, kind) | kind `elem` [RenameVolume, RenameWorkload] -> do
        fenced <- writerFenced bundle
        pure (fenced >> proof bundle ["writer" .= (bundle ^. #writerAddress), "writerPhysical" .= (bundle ^. #writerPhysical), "fenced" .= True])
      (TransferState, RenameVolume) -> do
        manifest <- runTransfer bundle TransferVerify
        destination <- destinationOwned bundle
        pure $ do
          checked <- manifest
          (uid, _) <- destination
          proof bundle ["sourcePhysical" .= (bundle ^. #sourcePhysical), "destinationPhysical" .= uid, "manifest" .= (checked ^. #sourceManifest)]
      (TransferState, kind) | kind `elem` [RenameCredential, RenameSigningKey] -> secretCopied bundle
      (stageName, kind)
        | stageName `elem` [BackUpSource, FenceWriters] -> do
            source <- sourceOwned bundle
            pure (source >> proof bundle ["sourcePhysical" .= (bundle ^. #sourcePhysical)])
        | stageName == RetainSource -> do
            source <- sourceOwned bundle
            fenced <- if kind == RenameWorkload then writerFenced bundle else pure (Right ())
            pure (source >> fenced >> proof bundle ["sourcePhysical" .= (bundle ^. #sourcePhysical), "retained" .= True])
        | otherwise -> do
            destination <- destinationOwned bundle
            pure $ do
              (uid, value) <- destination
              ready kind value
              proof bundle ["destinationPhysical" .= uid]

    recover bundle = case (bundle ^. #stage, bundle ^. #member) of
      (PrepareDestination, kind)
        | kind `elem` [RenameCredential, RenameSigningKey] -> do
            destination <- getObject (bundle ^. #destinationAddress)
            case destination of
              Right Nothing -> pure RecoverySafeToRetry
              Right (Just _) -> either RecoveryUnresolved RecoveryProvedComplete <$> secretCopied bundle
              Left reason -> pure (RecoveryUnresolved reason)
        | otherwise -> either (pure . RecoveryUnresolved) (adapterRecover base (createOperation bundle)) (createPrepared bundle)
      (FenceWriters, kind) | kind `elem` [RenameVolume, RenameWorkload] -> do
        fenced <- writerFenced bundle
        case fenced of
          Right () -> either RecoveryUnresolved RecoveryProvedComplete <$> verify bundle
          Left _ -> either RecoveryUnresolved (const RecoverySafeToRetry) <$> writerOwned bundle
      -- The copy Job refuses a destination that differs from its source, so
      -- re-running it after a lost acknowledgement proves or refuses.
      (TransferState, RenameVolume) -> pure RecoverySafeToRetry
      _ -> either (const RecoverySafeToRetry) RecoveryProvedComplete <$> verify bundle

    proof bundle fields =
      contentDigest
        <$> canonicalValue
          ( object
              ( [ "operation" .= (bundle ^. #operation)
                , "stage" .= (bundle ^. #stage)
                , "resource" .= (bundle ^. #resource)
                ]
                  <> fields
              )
          )

    ready RenameWorkload value
      | readyReplicas value >= 1 = Right ()
      | otherwise = Left "renamed StatefulSet is not ready"
    ready RenameVolume value = case valueAt ["status", "phase"] value of
      Just (String "Bound") -> Right ()
      _ -> Left "renamed volume is not bound"
    ready _ _ = Right ()

    readyReplicas value = case (valueAt ["status", "readyReplicas"] value, valueAt ["spec", "replicas"] value) of
      (Just (Number readyCount), Just (Number wanted)) | readyCount == wanted -> readyCount
      _ -> 0

    -- Observation -------------------------------------------------------

    getObject address = case address of
      Kubernetes _ group kind namespace name -> do
        guarded <- runtimeGuard config
        case guarded of
          Left reason -> pure (Left ("cluster guard refused: " <> reason))
          Right () -> do
            result <-
              invokeKubectl
                config
                ( ["get", kindToken group kind, T.unpack (nameText name)]
                    <> maybe [] (\value -> ["--namespace", T.unpack (nameText value)]) namespace
                    <> ["-o", "json", "--ignore-not-found"]
                )
                ""
            pure $ case result of
              Right (ExitSuccess, output, _)
                | null output -> Right Nothing
                | otherwise -> Just <$> first T.pack (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)))
              _ -> Left "Kubernetes read failed"
      _ -> pure (Left "rename member has no Kubernetes address")

    -- The object must carry this context's ownership stamp for the logical
    -- resource; a name match alone never proves identity.
    observeOwned address owner = do
      observed <- getObject address
      pure $ do
        value <- observed >>= maybe (Left "rename member is absent") Right
        uid <- maybe (Left "rename member has no UID") Right (textAt ["metadata", "uid"] value)
        unless
          ( annotation "nagare.dev/resource-id" value == Just (resourceIdText owner)
              && annotation "nagare.dev/context-id" value == Just (contextIdText (runtimeContext config))
          )
          (Left "rename member lacks this context's ownership stamp")
        physical <- mkPhysicalIdentity uid
        pure (physical, value)

    sourceOwned bundle = do
      observed <- observeOwned (bundle ^. #sourceAddress) (bundle ^. #resource)
      pure $ do
        (physical, _) <- observed
        unless (physical == bundle ^. #sourcePhysical) (Left "rename source incarnation changed since review")

    destinationOwned bundle = do
      observed <- observeOwned (bundle ^. #destinationAddress) (bundle ^. #resource)
      pure $ do
        (physical, value) <- observed
        unless
          (annotation "nagare.dev/spec-digest" value == Just (digestText (bundle ^. #destinationDigest)))
          (Left "rename destination differs from the reviewed native object")
        pure (physical, value)

    writerOwned bundle = do
      observed <- observeOwned (bundle ^. #writerAddress) (bundle ^. #scope . #writer)
      pure $ do
        (physical, value) <- observed
        unless (physical == bundle ^. #writerPhysical) (Left "rename writer incarnation changed since review")
        pure value

    writerFenced bundle = do
      writer <- writerOwned bundle
      pod <- getObject (podAddress bundle)
      pure $ do
        value <- writer
        unless
          ( valueAt ["spec", "replicas"] value == Just (Number 0)
              && maybe True (== Number 0) (valueAt ["status", "replicas"] value)
              && maybe False (not . T.null) (annotation (Key.toText fenceAnnotation) value)
          )
          (Left "rename writer is not fenced")
        current <- pod
        unless (isNothing current) (Left "fenced writer still has a Pod")

    podAddress bundle = case bundle ^. #writerAddress of
      Kubernetes cluster _ _ namespace name ->
        Kubernetes cluster "" (unsafeName "pod") namespace (unsafeName (nameText name <> "-0"))
      other -> other

    -- Effects -----------------------------------------------------------

    fenceWriter bundle = do
      writer <- writerOwned bundle
      case writer of
        Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
        Right value -> do
          fenced <- writerFenced bundle
          case fenced of
            Right () -> pure AdapterEffectCompleted
            Left _ -> do
              let patch =
                    object
                      [ "metadata"
                          .= object
                            [ "uid" .= physicalIdentityText (bundle ^. #writerPhysical)
                            , "resourceVersion" .= fromMaybe "" (textAt ["metadata", "resourceVersion"] value)
                            , "annotations" .= object [fenceAnnotation .= (bundle ^. #operation)]
                            ]
                      , "spec" .= object ["replicas" .= (0 :: Int)]
                      ]
              patched <- kubectlWrite (patchArguments (bundle ^. #writerAddress) patch) ""
              case patched of
                Left reason -> pure (AdapterEffectAmbiguous reason)
                Right () -> do
                  settled <- poll 90 (either (const False) (const True) <$> writerFenced bundle)
                  pure (if settled then AdapterEffectCompleted else AdapterEffectAmbiguous "fenced writer Pod has not stopped")

    copySecret bundle = do
      source <- getObject (bundle ^. #sourceAddress)
      let built = do
            value <- source >>= maybe (Left "rename source credential is absent") Right
            fields <- expectedData bundle value
            template <- first T.pack (eitherDecodeStrict (TE.encodeUtf8 (bundle ^. #destinationNative)))
            case template of
              Object root -> canonicalValue (Object (KM.insert "data" (Object fields) root))
              _ -> Left "rename destination template is malformed"
      case built of
        Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
        Right bytes -> do
          created <- kubectlWrite ["create", "--field-manager=nagare-inventory", "-f", "-"] (T.unpack (TE.decodeUtf8 bytes))
          pure (either AdapterEffectAmbiguous (const AdapterEffectCompleted) created)

    expectedData bundle value = case valueAt ["data"] value of
      Just (Object fields)
        | bundle ^. #member == RenameCredential -> rewriteCredentialData (bundle ^. #scope) fields
        | otherwise -> Right fields
      _ -> Left "rename source credential has no data"

    secretCopied bundle = do
      source <- getObject (bundle ^. #sourceAddress)
      destination <- destinationOwned bundle
      pure $ do
        sourceValue <- source >>= maybe (Left "rename source credential is absent") Right
        expected <- expectedData bundle sourceValue
        (uid, value) <- destination
        unless (valueAt ["data"] value == Just (Object expected)) (Left "rename destination credential differs from its source")
        dataDigest <- contentDigest <$> canonicalValue (Object expected)
        proof bundle ["destinationPhysical" .= uid, "dataDigest" .= dataDigest]

    runTransfer bundle mode = do
      let facts = bundle ^. #scope
          job = transferJob facts (bundle ^. #operation) mode (addressName (bundle ^. #sourceAddress)) (addressName (bundle ^. #destinationAddress))
          name = transferJobName (bundle ^. #operation) mode
          address = Kubernetes (writerCluster bundle) "batch" (unsafeName "job") (Just (facts ^. #namespace)) (unsafeName name)
          timeout = if mode == TransferCopy then 900 else 600
      existing <- getObject address
      started <- case existing of
        Left reason -> pure (Left reason)
        Right (Just value)
          | valueAt ["metadata", "labels", "nagare.dev/migration-operation"] value == Just (toJSON (bundle ^. #operation)) -> pure (Right ())
          | otherwise -> pure (Left "transfer Job name belongs to another operation")
        Right Nothing -> case canonicalValue job of
          Left reason -> pure (Left reason)
          Right bytes -> kubectlWrite ["create", "-f", "-"] (T.unpack (TE.decodeUtf8 bytes))
      case started of
        Left reason -> pure (Left reason)
        Right () -> do
          _ <- poll timeout (either (const False) finished <$> getObject address)
          current <- getObject address
          case current of
            Right (Just value) | finished (Just value) -> do
              uid <- pure (textAt ["metadata", "uid"] value >>= either (const Nothing) Just . mkPhysicalIdentity)
              message <- maybe (pure (Left "transfer Job has no UID")) (readMessage facts name) uid
              removed <- maybe (pure (Right ())) (deleteJob address) uid
              pure (removed >> (message >>= parseTransferManifest))
            _ -> pure (Left "transfer Job did not finish")

    finished = \case
      Just value -> any (\key -> maybe False (/= Number 0) (valueAt ["status", key] value)) ["succeeded", "failed"]
      Nothing -> False

    readMessage facts name uid = do
      result <-
        invokeKubectl
          config
          ["get", "pods", "--namespace", T.unpack (nameText (facts ^. #namespace)), "-l", "batch.kubernetes.io/job-name=" <> T.unpack name, "-o", "json"]
          ""
      pure $ case result of
        Right (ExitSuccess, output, _) -> do
          pods <- first T.pack (eitherDecodeStrict (TE.encodeUtf8 (T.pack output)))
          completedJobContainerMessageFromPodList uid "transfer" pods
        _ -> Left "transfer Job Pod read failed"

    deleteJob address uid = case address of
      Kubernetes _ _ _ (Just namespace) name -> do
        let options =
              object
                [ "apiVersion" .= ("meta.k8s.io/v1" :: Text)
                , "kind" .= ("DeleteOptions" :: Text)
                , "preconditions" .= object ["uid" .= physicalIdentityText uid]
                , "propagationPolicy" .= ("Background" :: Text)
                ]
        case canonicalValue options of
          Left reason -> pure (Left reason)
          Right bytes ->
            kubectlWrite
              ["delete", "--raw", "/apis/batch/v1/namespaces/" <> T.unpack (nameText namespace) <> "/jobs/" <> T.unpack (nameText name), "-f", "-"]
              (T.unpack (TE.decodeUtf8 bytes))
      _ -> pure (Left "transfer Job has no namespaced address")

    kubectlWrite arguments body = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (Left ("cluster guard refused before Kubernetes write: " <> reason))
        Right () -> do
          result <- invokeKubectl config arguments body
          pure $ case result of
            Right (ExitSuccess, _, _) -> Right ()
            _ -> Left "Kubernetes write did not return success; reobserve before retry"

    patchArguments address patch = case address of
      Kubernetes _ group kind namespace name ->
        ["patch", kindToken group kind, T.unpack (nameText name)]
          <> maybe [] (\value -> ["--namespace", T.unpack (nameText value)]) namespace
          <> ["--type=merge", "--field-manager=nagare-inventory", "-p", T.unpack (TE.decodeUtf8 (either (const "") id (canonicalValue patch)))]
      _ -> []

    poll :: Int -> IO Bool -> IO Bool
    poll attempts check = do
      done <- check
      if done || attempts <= 0
        then pure done
        else threadDelay 2000000 >> poll (attempts - 1) check

-- | Build the reviewed proposal from the exact paired observations: every
-- member of the database migrates, from its observed owned source to its
-- confirmed-absent destination, under the contract its adapter verifies.
renameProposal ::
  CompositionCandidate ->
  MigrationPlanning ->
  ScopeId ->
  MigrationObservationSet ->
  Either Text MigrationInput
renameProposal candidate context owner observations = do
  facts <-
    renameScope
      (Map.map (\(_, declaration, bytes) -> (declaration, bytes)) (context ^. #sources))
      (context ^. #destinations)
      owner
  targets <- traverse (target facts) (Map.toAscList (migrationObservationMap observations))
  unless
    (Set.fromList (map migrationResource targets) == Map.keysSet (context ^. #destinations))
    (Left "rename must migrate every database member")
  pure
    MigrationInput
      { migrationCandidateDirectory = "db rename"
      , migrationBinding = inventoryBinding (candidateInventory candidate)
      , migrationTargets = targets
      }
  where
    target facts (resourceId, (sourceFact, destinationFact)) = do
      (_, source, _) <- maybe (Left "migrating member has no accepted source") Right (Map.lookup resourceId (context ^. #sources))
      (destination, _) <- maybe (Left "migrating member has no compiled destination") Right (Map.lookup resourceId (context ^. #destinations))
      physical <- case sourceFact of
        ObservedPresent value -> Right value
        _ -> Left "rename source is not present under its exact owned identity"
      absence <- case destinationFact of
        ConfirmedAbsent value -> Right value
        _ -> Left "rename destination address is not confirmed absent"
      contract <- renameContract facts source
      pure (MigrationTarget resourceId (source ^. #address) physical (destination ^. #address) absence contract)

decodeBundle :: PlannedOperation -> PreparedNative -> Either Text Bundle
decodeBundle planned prepared = do
  value <- first T.pack (eitherDecodeStrict (preparedNativeBytes prepared))
  bundle <- first T.pack (parseEither parseBundle value)
  unless
    ( bundle ^. #operation == plannedOperationId planned
        && bundle ^. #inputDigest == plannedInputDigest planned
        && plannedAction planned == MigrateResource (bundle ^. #stage)
        && NE.toList (plannedResources planned) == [bundle ^. #resource]
    )
    (Left "migration bundle belongs to another reviewed operation")
  pure bundle

encodeBundle :: Bundle -> Value
encodeBundle bundle =
  object
    [ "format" .= bundleFormat
    , "operation" .= (bundle ^. #operation)
    , "inputDigest" .= (bundle ^. #inputDigest)
    , "stage" .= (bundle ^. #stage)
    , "resource" .= (bundle ^. #resource)
    , "member" .= memberText (bundle ^. #member)
    , "owner" .= (bundle ^. #scope . #owner)
    , "namespace" .= nameText (bundle ^. #scope . #namespace)
    , "sourceDatabase" .= nameText (bundle ^. #scope . #sourceDatabase)
    , "destinationDatabase" .= nameText (bundle ^. #scope . #destinationDatabase)
    , "image" .= (bundle ^. #scope . #image)
    , "writer" .= (bundle ^. #scope . #writer)
    , "sourceAddress" .= (bundle ^. #sourceAddress)
    , "sourcePhysical" .= (bundle ^. #sourcePhysical)
    , "destinationAddress" .= (bundle ^. #destinationAddress)
    , "destinationDigest" .= (bundle ^. #destinationDigest)
    , "destinationNative" .= (bundle ^. #destinationNative)
    , "create" .= (bundle ^. #create)
    , "writerAddress" .= (bundle ^. #writerAddress)
    , "writerPhysical" .= (bundle ^. #writerPhysical)
    ]

parseBundle :: Value -> Parser Bundle
parseBundle = withObject "MigrationBundle" $ \o -> do
  format <- o .: "format"
  unless (format == bundleFormat) (fail "unsupported migration bundle format")
  facts <-
    RenameScope
      <$> o .: "owner"
      <*> (o .: "namespace" >>= checkedName)
      <*> (o .: "sourceDatabase" >>= checkedName)
      <*> (o .: "destinationDatabase" >>= checkedName)
      <*> o .: "image"
      <*> o .: "writer"
  Bundle
    <$> o .: "operation"
    <*> o .: "inputDigest"
    <*> o .: "stage"
    <*> o .: "resource"
    <*> (o .: "member" >>= memberFromText)
    <*> pure facts
    <*> o .: "sourceAddress"
    <*> o .: "sourcePhysical"
    <*> o .: "destinationAddress"
    <*> o .: "destinationDigest"
    <*> o .: "destinationNative"
    <*> o .: "create"
    <*> o .: "writerAddress"
    <*> o .: "writerPhysical"
  where
    checkedName value = either (fail . T.unpack) pure (mkName value)

memberText :: RenameMember -> Text
memberText = \case
  RenameCredential -> "credential"
  RenameSigningKey -> "signing-key"
  RenameVolume -> "volume"
  RenameWorkload -> "workload"
  RenameObject -> "object"

memberFromText :: Text -> Parser RenameMember
memberFromText = \case
  "credential" -> pure RenameCredential
  "signing-key" -> pure RenameSigningKey
  "volume" -> pure RenameVolume
  "workload" -> pure RenameWorkload
  "object" -> pure RenameObject
  _ -> fail "unknown rename member"

summary :: Bundle -> Text
summary bundle =
  "migrate "
    <> memberText (bundle ^. #member)
    <> " "
    <> T.pack (show (bundle ^. #stage))
    <> ": "
    <> nameText (bundle ^. #scope . #sourceDatabase)
    <> " -> "
    <> nameText (bundle ^. #scope . #destinationDatabase)

writerCluster :: Bundle -> ResourceId
writerCluster bundle = case bundle ^. #writerAddress of
  Kubernetes cluster _ _ _ _ -> cluster
  _ -> bundle ^. #resource

addressName :: ProviderAddress -> Name
addressName = \case
  Kubernetes _ _ _ _ name -> name
  _ -> unsafeName "unknown"

kindToken :: Text -> Name -> String
kindToken group kind = T.unpack (nameText kind <> if T.null group then "" else "." <> group)

unsafeName :: Text -> Name
unsafeName = either (error . T.unpack) id . mkName

valueAt :: [Text] -> Value -> Maybe Value
valueAt [] value = Just value
valueAt (key : rest) (Object fields) = KM.lookup (Key.fromText key) fields >>= valueAt rest
valueAt _ _ = Nothing

textAt :: [Text] -> Value -> Maybe Text
textAt path value = case valueAt path value of
  Just (String text) -> Just text
  _ -> Nothing

annotation :: Text -> Value -> Maybe Text
annotation key value = case valueAt ["metadata", "annotations"] value of
  Just (Object fields) -> case KM.lookup (Key.fromText key) fields of
    Just (String text) -> Just text
    _ -> Nothing
  _ -> Nothing
