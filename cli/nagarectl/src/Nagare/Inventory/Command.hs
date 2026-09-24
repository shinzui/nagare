module Nagare.Inventory.Command
  ( compileInput
  , compileInventory
  , loadCandidate
  , loadTargetSnapshot
  , openTargetStore
  , openTargetStoreReadOnly
  , migrateTargetStore
  , planInventory
  , planInventoryWith
  , planInventoryCandidateWith
  , planInventoryAdoptionWith
  , planInventoryMigrationWith
  , planInventoryRetirementWith
  , planInventoryCollectionWith
  , applyInventory
  , applyInventoryWith
  , applyInventoryWithFactory
  , resumeInventory
  , resumeInventoryWith
  , resumeInventoryWithFactory
  , resumeInventoryWithFactoryTakeover
  , recoverInventoryWithFactory
  , exportInventory
  , manifestAdapterFor
  , executionBlockedAdapterFor
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import Crypto.Random (getRandomBytes)
import Data.Bits ((.&.))
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.IORef
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal
import Nagare.Inventory.Lifecycle
import Nagare.Inventory.Migration
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps (gcloudObjectOps)
import Nagare.Ops.PulumiBackend (GcloudOps (..), bucketOwnershipVerdict, bucketProjectNumberArgs, gcsBucketOfUrl, projectNumberArgs, realGcloudOps)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire
import Nagare.Target
import System.Directory
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath (isAbsolute, takeDirectory, takeFileName, (</>))
import System.IO (hClose, stderr)
import System.IO.Error (isAlreadyExistsError)
import System.IO.Temp (withTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, isDirectory, setFileMode)
import System.Posix.IO (OpenMode (WriteOnly), creat, defaultFileFlags, exclusive, fdToHandle, openFd)

-- | No context lookup and no provider process. Validation completes before IO.
compileInput :: ByteString -> Either (NonEmpty InventoryError) [(FilePath, ByteString)]
compileInput bytes = do
  input@(CandidateInput snapshot changes) <- decodeCandidateInput bytes
  candidate <- composeInventory snapshot changes
  let desired = inventoryScopes (candidateInventory candidate)
      allScopes = Map.elems desired <> map snd (Map.elems (snapshotScopes snapshot))
      members = Map.fromList [(memberPath s, encodeCanonicalScope s) | s <- allScopes]
      memberPath s = "scopes/" <> T.unpack (digestText (contentDigest (encodeCanonicalScope s))) <> ".json"
      references s = object ["scope" .= scopeId s, "member" .= memberPath s, "digest" .= contentDigest (encodeCanonicalScope s)]
      desiredValue = object ["context" .= inventoryBinding (candidateInventory candidate), "scopes" .= map references (Map.elems desired)]
  desiredBytes <- canonical desiredValue
  -- Retain the explicit base and changes using digest-bound member references.
  -- Loading verifies the references and composes the declarations again.
  inputBytes <- canonical (referenceScopes (candidateInputValue input))
  manifest <-
    canonical
      ( object
          [ "version" .= (1 :: Integer)
          , "inputDigest" .= contentDigest inputBytes
          , "members" .= [object ["path" .= p, "digest" .= contentDigest b] | (p, b) <- Map.toAscList members]
          , "desiredDigest" .= contentDigest desiredBytes
          , "desired" .= desiredValue
          , "generations" .= [object ["scope" .= s, "generation" .= g] | (s, g) <- Map.toAscList (candidateGenerations candidate)]
          ]
      )
  pure ([("candidate.json", manifest), ("candidate.sha256", BC.pack (T.unpack (digestText (contentDigest manifest))) <> "\n"), ("input.json", inputBytes)] <> Map.toAscList members)
  where
    canonical = first (\e -> inventoryError "canonical" e :| []) . canonicalValue

-- | Verify exact members and recompose. Bytes can never manufacture a proof value.
loadCandidate :: FilePath -> IO (Either Text CompositionCandidate)
loadCandidate dir = do
  result <- try $ do
    inputBytes <- BS.readFile (dir </> "input.json")
    inputValue <- either (ioError . userError) pure (eitherDecodeStrict inputBytes)
    expanded <- expandScopes dir inputValue
    bytes <- either (ioError . userError . T.unpack) pure (canonicalValue expanded)
    case compileInput bytes of
      Left es -> pure (Left (T.pack (show es)))
      Right files -> do
        equal <- verifyFiles dir files
        pure $
          if not equal
            then Left "candidate files differ from their canonical digests or membership"
            else first (T.pack . show) $ do
              CandidateInput snapshot changes <- decodeCandidateInput bytes
              composeInventory snapshot changes
  pure $ case result of Left (e :: IOException) -> Left (T.pack (show e)); Right r -> r

-- Scope members are immutable individual documents, never embedded in manifests.
referenceScopes :: Value -> Value
referenceScopes (Object o)
  | sort (KM.keys o) == ["bundles", "scope", "version"] =
      let bytes = either (error . T.unpack) id (canonicalValue (Object o))
          digest = contentDigest bytes
       in object ["member" .= ("scopes/" <> digestText digest <> ".json"), "digest" .= digest]
  | otherwise = Object (fmap referenceScopes o)
referenceScopes (Array xs) = Array (fmap referenceScopes xs)
referenceScopes value = value

expandScopes :: FilePath -> Value -> IO Value
expandScopes dir (Object o)
  | sort (KM.keys o) == ["digest", "member"] = do
      (member, digest) <- either (ioError . userError) pure (parseEither (\v -> (,) <$> v .: "member" <*> v .: "digest") o)
      let expected = "scopes/" <> T.unpack (digestText digest) <> ".json"
      unless (member == expected) (ioError (userError "invalid scope member path"))
      link <- pathIsSymbolicLink (dir </> member)
      when link (ioError (userError "scope member must not be a symlink"))
      bytes <- BS.readFile (dir </> member)
      unless (contentDigest bytes == digest) (ioError (userError "scope member digest mismatch"))
      declaration <- either (ioError . userError . show) pure (decodeScope bytes)
      unless (encodeCanonicalScope declaration == bytes) (ioError (userError "noncanonical scope member"))
      pure (scopeValue declaration)
  | otherwise = Object <$> traverse (expandScopes dir) o
expandScopes dir (Array xs) = Array <$> traverse (expandScopes dir) xs
expandScopes _ value = pure value

verifyFiles :: FilePath -> [(FilePath, ByteString)] -> IO Bool
verifyFiles dir files = do
  rootNames <- sort <$> listDirectory dir
  scopeNames <- sort <$> listDirectory (dir </> "scopes")
  equal <- forM files $ \(p, b) -> do
    symlink <- pathIsSymbolicLink (dir </> p)
    actual <- BS.readFile (dir </> p)
    pure (not symlink && actual == b)
  scopeLink <- pathIsSymbolicLink (dir </> "scopes")
  pure (not scopeLink && and equal && rootNames == ["candidate.json", "candidate.sha256", "input.json", "scopes"] && scopeNames == sort [takeFileName p | (p, _) <- files, takeDirectory p == "scopes"])

compileInventory :: FilePath -> FilePath -> Bool -> IO ()
compileInventory input output json = do
  result <- try (BS.readFile input)
  case result of
    Left (e :: IOException) -> report [inventoryError "input" (T.pack (show e))]
    Right bytes -> case compileInput bytes of
      Left es -> report (NE.toList es)
      Right files -> do
        published <- try $ do
          exists <- doesPathExist output
          if exists
            then do
              link <- pathIsSymbolicLink output
              matches <- if link then pure False else verifyFiles output files
              unless matches (ioError (userError "output exists with different contents; refusing overwrite"))
            else do
              let parent = takeDirectory output
              createDirectoryIfMissing True parent
              withTempDirectory parent ".inventory-" $ \staging -> do
                setFileMode staging 0o700
                createDirectory (staging </> "scopes")
                setFileMode (staging </> "scopes") 0o700
                forM_ files $ \(p, b) -> do
                  BS.writeFile (staging </> p) b
                  setFileMode (staging </> p) 0o600
                renameDirectory staging output
        case published of
          Left (e :: IOException) -> report [inventoryError "output" (T.pack (show e))]
          Right () -> BC.putStr (fromMaybe "" (lookup "candidate.sha256" files))
  where
    report es = do
      if json
        then BC.hPutStrLn stderr (either (error . T.unpack) id (canonicalValue (toJSON (map errorValue es))))
        else BC.hPutStrLn stderr (BC.pack (show es))
      exitFailure

planInventory :: ActiveTarget -> FilePath -> FilePath -> IO ()
planInventory = planInventoryWith (\_ history -> pure (manifestOnlyRegistry history))

-- | Provider domains install their concrete adapters here. Keeping the factory
-- outside the command service lets cloud/host/artifact entry points share one
-- planner without moving provider orchestration back into @app/Main.hs@.
planInventoryWith :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) -> ActiveTarget -> FilePath -> FilePath -> IO ()
planInventoryWith registryFor target candidateDirectory output = do
  candidate <- loadCandidate candidateDirectory >>= either dieText pure
  planInventoryCandidateWith registryFor target candidate output

-- | Versioned adoption proposals name a compiled candidate and exact
-- observed incarnations. The decision is validated after fresh observation.
planInventoryAdoptionWith :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) -> ActiveTarget -> FilePath -> FilePath -> IO ()
planInventoryAdoptionWith registryFor target inputFile output = do
  bytes <- (try (BS.readFile inputFile) :: IO (Either IOException ByteString))
    >>= either (dieText . showText) pure
  proposalInput <- either dieText pure (decodeAdoptionInput bytes)
  let relative = adoptionCandidateDirectory proposalInput
      candidateDirectory = if isAbsolute relative then relative else takeDirectory inputFile </> relative
  candidate <- loadCandidate candidateDirectory >>= either dieText pure
  planInventoryCandidateWithDecider registryFor
    (\history observations -> decideAdoption candidate history observations proposalInput)
    target candidate output

-- | A migration reads source and destination through distinct registries.
-- One ordinary registry cannot represent two physical incarnations of an ID.
planInventoryMigrationWith
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> ActiveTarget -> FilePath -> FilePath -> IO ()
planInventoryMigrationWith sourceRegistryFor destinationRegistryFor target inputFile output = do
  bytes <- (try (BS.readFile inputFile) :: IO (Either IOException ByteString))
    >>= either (dieText . showText) pure
  proposalInput <- either dieText pure (decodeMigrationInput bytes)
  let relative = migrationCandidateDirectory proposalInput
      candidateDirectory = if isAbsolute relative then relative else takeDirectory inputFile </> relative
  candidate <- loadCandidate candidateDirectory >>= either dieText pure
  rejectReentry
  validateTarget target candidate
  store <- openTargetStore target
  let binding = inventoryBinding (candidateInventory candidate)
  _ <- initializeStore store binding (clientIdentity target) >>= either (dieText . showText) pure
  _ <- seedInventoryHistory store candidate >>= either (dieText . showText) pure
  history <- loadInventoryHistory store >>= either (dieText . showText) pure
  destinationRegistry <- destinationRegistryFor candidate history
  sourceRegistry <- sourceRegistryFor candidate history
  let requirements = observationRequirements candidate history
  destinations <- observeWithRegistry destinationRegistry (requirementsByExecutor requirements)
    >>= either dieText pure
  incarnationFacts <- observeMigrationIncarnations sourceRegistry destinationRegistry requirements
    >>= either dieText pure
  decisions <- either (dieText . showText . NE.toList) pure
    (decideMigration candidate proposalInput history destinations incarnationFacts)
  proposal <- either (dieText . showText . NE.toList) pure
    (planChanges candidate decisions history destinations)
  snapshot <- readStoreSnapshot store >>= either (dieText . showText) pure
  bundle <- prepareReview destinationRegistry snapshot proposal
    >>= either (dieText . showText . NE.toList) pure
  digest <- publishReview store bundle >>= either (dieText . showText) pure
  _ <- writeReviewBundle output bundle >>= either dieText pure
  TIO.putStrLn (digestText digest)

planInventoryRetirementWith
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> ActiveTarget -> ScopeId -> FilePath -> IO ()
planInventoryRetirementWith registryFor target owner output = do
  snapshot <- loadTargetSnapshot target
  unless (Map.member owner (snapshotScopes snapshot))
    (dieText "retirement scope is absent from accepted inventory history")
  candidate <- either (dieText . showText . NE.toList) pure
    (composeInventory snapshot (RetireScope owner RetainResources :| []))
  planInventoryCandidateWithDecider registryFor
    (\history observations -> decideRetirement candidate history observations)
    target candidate output

planInventoryCollectionWith
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> ActiveTarget -> ResourceId -> FilePath -> IO ()
planInventoryCollectionWith registryFor target resource output = do
  snapshot <- loadTargetSnapshot target
  candidate <- either (dieText . showText . NE.toList) pure
    (composeInventory snapshot (CollectRetained resource :| []))
  planInventoryCandidateWithDecider registryFor
    (\history observations -> decideCollection candidate history observations)
    target candidate output

-- | Plan a freshly compiled component candidate with native member bytes held
-- by the caller. Publication still retains those bytes in the private review.
planInventoryCandidateWith :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) -> ActiveTarget -> CompositionCandidate -> FilePath -> IO ()
planInventoryCandidateWith registryFor =
  planInventoryCandidateWithDecider registryFor (\_ _ -> Right noLifecycleDecisions)

planInventoryCandidateWithDecider
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions)
  -> ActiveTarget -> CompositionCandidate -> FilePath -> IO ()
planInventoryCandidateWithDecider registryFor decide target candidate output = do
  rejectReentry
  validateTarget target candidate
  store <- openTargetStore target
  let binding = inventoryBinding (candidateInventory candidate)
  _ <- initializeStore store binding (clientIdentity target) >>= either (dieText . showText) pure
  _ <- seedInventoryHistory store candidate >>= either (dieText . showText) pure
  history <- loadInventoryHistory store >>= either (dieText . showText) pure
  registry <- registryFor candidate history
  let requirements = observationRequirements candidate history
  observations <- observeWithRegistry registry (requirementsByExecutor requirements) >>= either dieText pure
  decisions <- either (dieText . showText . NE.toList) pure (decide history observations)
  proposal <- either (dieText . showText . NE.toList) pure (planChanges candidate decisions history observations)
  snapshot <- readStoreSnapshot store >>= either (dieText . showText) pure
  bundle <- prepareReview registry snapshot proposal >>= either (dieText . showText . NE.toList) pure
  digest <- publishReview store bundle >>= either (dieText . showText) pure
  _ <- writeReviewBundle output bundle >>= either dieText pure
  TIO.putStrLn (digestText digest)

applyInventory :: ActiveTarget -> FilePath -> Bool -> IO ()
applyInventory = applyInventoryWith executionBlockedRegistry

applyInventoryWith :: AdapterRegistry -> ActiveTarget -> FilePath -> Bool -> IO ()
applyInventoryWith registry = applyInventoryWithFactory (const (pure registry))

-- | Construct adapters only after the private, immutable review has been
-- loaded. Public review directories intentionally omit native provider bytes.
applyInventoryWithFactory :: (ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> FilePath -> Bool -> IO ()
applyInventoryWithFactory registryFor target reviewDirectory yes = do
  rejectReentry
  unless yes (dieText "inventory apply requires --yes after reviewing the bound plan")
  publicBundle <- loadReviewBundle reviewDirectory >>= either dieText pure
  validateReviewTarget target (reviewContextBinding (reviewBundleDocument publicBundle))
  store <- openTargetStore target
  bundle <- loadPublishedReview store (reviewDigest publicBundle) >>= either (dieText . showText) pure
  unless
    ( reviewBundleDocument bundle == reviewBundleDocument publicBundle
        && reviewBundleScopes bundle == reviewBundleScopes publicBundle
    )
    (dieText "review directory differs from the immutable review published by this store")
  registry <- registryFor bundle
  snapshot <- readStoreSnapshot store >>= either (dieText . showText) pure
  reviewed <- either (dieText . showText . NE.toList) pure (verifyReview snapshot bundle)
  result <- applyReviewed store registry reviewed >>= either (dieText . showText . NE.toList) pure
  TIO.putStrLn (renderTransactionResult result)
  case result of
    Converged _ -> pure ()
    _ -> exitFailure

resumeInventory :: ActiveTarget -> Text -> Bool -> IO ()
resumeInventory = resumeInventoryWith executionBlockedRegistry

resumeInventoryWith :: AdapterRegistry -> ActiveTarget -> Text -> Bool -> IO ()
resumeInventoryWith registry = resumeInventoryWithFactory (const (pure registry))

resumeInventoryWithFactory :: (ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> Text -> Bool -> IO ()
resumeInventoryWithFactory registryFor target transactionToken yes =
  resumeInventoryWithFactoryTakeover registryFor target transactionToken yes False

resumeInventoryWithFactoryTakeover :: (ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> Text -> Bool -> Bool -> IO ()
resumeInventoryWithFactoryTakeover registryFor target transactionToken yes takeOver = do
  rejectReentry
  unless yes (dieText "inventory resume requires --yes")
  transaction <- either dieText pure (mkTransactionId transactionToken)
  store <- openTargetStore target
  digest <- either dieText pure (mkContentDigest (T.drop 3 (transactionIdText transaction)))
  bundle <- loadPublishedReview store digest >>= either (dieText . showText) pure
  registry <- registryFor bundle
  result <- resumeTransactionWithTakeover store registry transaction takeOver >>= either (dieText . showText . NE.toList) pure
  TIO.putStrLn (renderTransactionResult result)
  case result of
    Converged _ -> pure ()
    _ -> exitFailure

recoverInventoryWithFactory
  :: (ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> Text -> Text -> FilePath -> Bool -> IO ()
recoverInventoryWithFactory registryFor target transactionToken operationToken decisionFile takeOver = do
  rejectReentry
  transaction <- either dieText pure (mkTransactionId transactionToken)
  operation <- either dieText pure (mkOperationId operationToken)
  bytes <- try (BS.readFile decisionFile) :: IO (Either IOException ByteString)
  input <- either (dieText . showText) (either dieText pure . decodeOperatorRecoveryInput) bytes
  unless (recoveryTransaction input == transaction && recoveryOperation input == operation)
    (dieText "recovery decision file does not match the requested transaction and operation")
  store <- openTargetStore target
  bundle <- loadPublishedReview store (recoveryReview input) >>= either (dieText . showText) pure
  registry <- registryFor bundle
  recordOperatorRecovery store registry input takeOver >>= either (dieText . showText . NE.toList) pure
  TIO.putStrLn "Adapter-proved recovery decision recorded; run inventory resume --yes for the transaction"

exportInventory :: ActiveTarget -> FilePath -> IO ()
exportInventory target output = do
  rejectReentry
  store <- openTargetStoreReadOnly target >>= either (dieText . showText) pure
  current <- readHead store >>= either (dieText . showText) pure
  when (isNothing current) (dieText "inventory history is not initialized")
  case current >>= headMigration of
    Just marker -> dieText ("inventory history migrated to " <> migrationDestination marker <> "; reload the context shell")
    Nothing -> pure ()
  result <- withProcessLock store (\locked -> exportStore locked output)
  case result of
    Left err -> dieText (showText err)
    Right (Left err) -> dieText (showText err)
    Right (Right ()) -> TIO.putStrLn (T.pack output)

openTargetStore :: ActiveTarget -> IO InventoryStore
openTargetStore target = do
  stateRoot <- nagareStateDir
  let path = stateRoot </> T.unpack (contextNameText (target ^. #contextName)) </> "inventory"
  case effectiveInventoryStore (target ^. #profile) of
    InventoryStoreLocal -> do
      store <- openFilesystemStore path >>= either (dieText . showText) pure
      headResult <- readHead store >>= either (dieText . showText) pure
      case headResult >>= headMigration of
        Just marker -> dieText ("inventory history migrated to " <> migrationDestination marker <> "; reload the context shell")
        Nothing -> pure store
    InventoryStoreGcs -> do
      local <- openFilesystemStoreReadOnly path
      migrated <- case local of
        Right localStore -> do
          localHead <- readHead localStore
          case localHead of
            Right (Just headValue) -> case headMigration headValue of
              Just marker | migrationDestination marker == remoteInventoryUrl target -> pure True
              _ -> dieText "local inventory history exists; migrate it before selecting the GCS store"
            Left err -> dieText (showText err)
            Right Nothing -> pure False
        Left (StoreConditionFailed _) -> pure False
        Left err -> dieText (showText err)
      remote <- openRemoteStore (not migrated) target stateRoot >>= either (dieText . showText) pure
      when migrated $ do
        remoteHead <- readHead remote >>= either (dieText . showText) pure
        when (isNothing remoteHead) (dieText "migrated remote inventory head is missing; refusing a new history")
      pure remote

openTargetStoreReadOnly :: ActiveTarget -> IO (Either StoreError InventoryStore)
openTargetStoreReadOnly target = do
  stateRoot <- nagareStateDir
  let path = stateRoot </> T.unpack (contextNameText (target ^. #contextName)) </> "inventory"
  case effectiveInventoryStore (target ^. #profile) of
    InventoryStoreLocal -> openFilesystemStoreReadOnly path
    InventoryStoreGcs -> openRemoteStore False target stateRoot

migrateTargetStore :: ActiveTarget -> InventoryStoreKind -> Bool -> IO (Either StoreError T.Text)
migrateTargetStore target destinationKind dryRun = do
  stateRoot <- nagareStateDir
  let contextText = contextNameText (target ^. #contextName)
      path = stateRoot </> T.unpack contextText </> "inventory"
      sourceKind = effectiveInventoryStore (target ^. #profile)
      sourceLabel = case sourceKind of
        InventoryStoreLocal -> "local"
        InventoryStoreGcs -> remoteInventoryUrl target
      destinationLabel = case destinationKind of
        InventoryStoreLocal -> "local"
        InventoryStoreGcs -> remoteInventoryUrl target
      destinationMatches sourceHead destinationHead =
        let canonicalDigest value = contentDigest <$> canonicalValue (toJSON value)
            sourceDigest = case headMigration sourceHead of
              Just marker | migrationDestination marker == destinationLabel ->
                Right (migrationHeadDigest marker)
              _ -> canonicalDigest sourceHead
         in destinationHead == sourceHead || case sourceDigest of
              Left _ -> False
              Right expected -> case headMigration destinationHead of
                Just marker -> migrationDestination marker == sourceLabel
                  && migrationHeadDigest marker == expected
                Nothing -> isJust (headMigration sourceHead)
                  && canonicalDigest destinationHead == Right expected
  if sourceKind == destinationKind
    then pure (Left (StoreConditionFailed "source and destination inventory stores are the same"))
    else do
      source <- case sourceKind of
        InventoryStoreLocal -> openFilesystemStoreReadOnly path
        InventoryStoreGcs -> openRemoteStore False target stateRoot
      case source of
        Left err -> pure (Left err)
        Right sourceStore -> do
          sourceHead <- readHead sourceStore
          case sourceHead of
            Left err -> pure (Left err)
            Right Nothing -> pure (Left (StoreConditionFailed "source inventory store is not initialized"))
            Right (Just headValue)
              | isJust (headActiveTransaction headValue) || isJust (headExecutorClaim headValue) ->
                  pure (Left (StoreConditionFailed "inventory migration requires no active transaction or executor claim"))
              | dryRun -> case destinationKind of
                  InventoryStoreLocal -> do
                    existing <- openFilesystemStoreReadOnly path
                    case existing of
                      Left (StoreConditionFailed _) -> pure (Right destinationLabel)
                      Left err -> pure (Left err)
                      Right localStore -> do
                        previous <- readHead localStore
                        pure $ case previous of
                          Left err -> Left err
                          Right Nothing -> Right destinationLabel
                          Right (Just old) | destinationMatches headValue old -> Right destinationLabel
                          Right (Just _) -> Left (StoreConditionFailed "local destination history differs")
                  InventoryStoreGcs -> do
                    let project = target ^. #profile . #project
                    ambient <- lookupEnv "CLOUDSDK_CORE_PROJECT"
                    case gcsBucketOfUrl destinationLabel of
                      Nothing -> pure (Left (StoreConditionFailed "inventory store URL has no GCS bucket"))
                      Just _ | maybe False ((/= project) . T.pack) ambient ->
                        pure (Left (StoreConditionFailed "ambient gcloud project disagrees with the inventory context"))
                      Just bucket -> do
                        bucketNumber <- capture realGcloudOps (bucketProjectNumberArgs bucket)
                        projectNumber <- capture realGcloudOps (projectNumberArgs project)
                        case bucketOwnershipVerdict bucket project bucketNumber projectNumber of
                          Left reason -> pure (Left (StoreConditionFailed reason))
                          Right () -> case gcloudObjectOps destinationLabel of
                            Left reason -> pure (Left (StoreConditionFailed reason))
                            Right ops -> do
                              existing <- openObjectStoreReadOnly ops (headBinding headValue) "dry-run" Nothing
                              case existing of
                                Left (StoreConditionFailed reason)
                                  | reason == "inventory object prefix is not initialized" -> pure (Right destinationLabel)
                                Left err -> pure (Left err)
                                Right remoteStore -> do
                                  previous <- readHead remoteStore
                                  pure $ case previous of
                                    Left err -> Left err
                                    Right Nothing -> Right destinationLabel
                                    Right (Just old) | destinationMatches headValue old -> Right destinationLabel
                                    Right (Just _) -> Left (StoreConditionFailed "remote destination history differs")
              | otherwise -> do
                  destination <- case destinationKind of
                    InventoryStoreLocal -> openFilesystemStore path
                    InventoryStoreGcs -> openRemoteStore True target stateRoot
                  case destination of
                    Left err -> pure (Left err)
                    Right destStore -> fmap (destinationLabel <$) (migrateStore sourceStore destStore sourceLabel destinationLabel)

remoteInventoryUrl :: ActiveTarget -> T.Text
remoteInventoryUrl target =
  let profile = target ^. #profile
   in if T.null (profile ^. #inventoryStoreUrl)
        then defaultGcsInventoryStoreUrl (contextNameText (target ^. #contextName)) profile
        else profile ^. #inventoryStoreUrl

openRemoteStore :: Bool -> ActiveTarget -> FilePath -> IO (Either StoreError InventoryStore)
openRemoteStore mayInitialize target stateRoot = do
  let contextName = target ^. #contextName
      profile = target ^. #profile
      project = profile ^. #project
      contextText = contextNameText contextName
      url = if T.null (profile ^. #inventoryStoreUrl)
        then defaultGcsInventoryStoreUrl contextText profile
        else profile ^. #inventoryStoreUrl
      invalid reason = Left (StoreConditionFailed reason)
  ambientProject <- lookupEnv "CLOUDSDK_CORE_PROJECT"
  stored <- readContextProfile contextName
  case stored of
    Left reason -> pure (invalid reason)
    Right persisted | persisted ^. #project /= project ->
      pure (invalid "active project disagrees with the stored inventory context")
    Right _ | Just ambient <- ambientProject, T.pack ambient /= project ->
      pure (invalid "ambient gcloud project disagrees with the inventory context")
    Right _ -> case gcsBucketOfUrl url of
      Nothing -> pure (invalid "inventory store URL has no GCS bucket")
      Just bucket -> do
        bucketNumber <- capture realGcloudOps (bucketProjectNumberArgs bucket)
        projectNumber <- capture realGcloudOps (projectNumberArgs project)
        case bucketOwnershipVerdict bucket project bucketNumber projectNumber of
          Left reason -> pure (invalid reason)
          Right () -> case gcloudObjectOps url of
            Left reason -> pure (invalid reason)
            Right ops -> do
              clientResult <- localStoreClientIdentity mayInitialize stateRoot contextText
              case clientResult of
                Left err -> pure (Left err)
                Right client -> do
                  case (mkContextId contextText, mkName project) of
                    (Right contextId, Right providerName) -> do
                      let binding = ContextBinding contextId providerName
                      cacheRoot <- inventoryCacheRoot contextText
                      cacheReady <- validateInventoryCache mayInitialize cacheRoot
                      case cacheReady of
                        Left err -> pure (Left err)
                        Right () ->
                          if mayInitialize
                            then newObjectStoreWithLock ops binding client (Just cacheRoot)
                              (stateRoot </> T.unpack contextText </> "inventory-remote.lock")
                            else openObjectStoreReadOnlyWithLock ops binding client (Just cacheRoot)
                              (stateRoot </> T.unpack contextText </> "inventory-remote.lock")
                    (Left err, _) -> pure (invalid err)
                    (_, Left err) -> pure (invalid err)

inventoryCacheRoot :: T.Text -> IO FilePath
inventoryCacheRoot context = do
  root <- lookupEnv "XDG_CACHE_HOME"
  home <- lookupEnv "HOME"
  let base = maybe (maybe "" (</> ".cache") home) id root
  unless (isAbsolute base) (ioError (userError "inventory cache requires an absolute XDG_CACHE_HOME or HOME"))
  pure (base </> "nagare" </> T.unpack context </> "inventory-blobs")

validateInventoryCache :: Bool -> FilePath -> IO (Either StoreError ())
validateInventoryCache mayCreate root = do
  attempted <- try $ do
    when mayCreate (createDirectoryIfMissing True root)
    exists <- doesPathExist root
    when exists $ do
      linked <- pathIsSymbolicLink root
      when linked (ioError (userError "inventory cache root is a symlink"))
      status <- getFileStatus root
      unless (isDirectory status) (ioError (userError "inventory cache root is not a directory"))
      when mayCreate (setFileMode root 0o700)
  pure $ case attempted of
    Left (err :: IOException) -> Left (StoreIoError (T.pack (show err)))
    Right () -> Right ()

localStoreClientIdentity :: Bool -> FilePath -> T.Text -> IO (Either StoreError T.Text)
localStoreClientIdentity mayCreate stateRoot context = do
  let path = stateRoot </> T.unpack context </> "inventory-client-id"
  exists <- doesPathExist path
  if exists then readClient path
  else if not mayCreate then pure (Right "status-only")
  else do
    createDirectoryIfMissing True (takeDirectory path)
    randomBytes <- getRandomBytes 32 :: IO ByteString
    let identityText = "client-" <> digestText (contentDigest randomBytes)
    attempted <- try (openFd path WriteOnly defaultFileFlags {exclusive = True, creat = Just 0o600})
    case attempted of
      Left (err :: IOException) | isAlreadyExistsError err -> readClient path
      Left (err :: IOException) -> pure (Left (StoreIoError (T.pack (show err))))
      Right fd -> do
        handle <- fdToHandle fd
        BS.hPut handle (TE.encodeUtf8 identityText)
        hClose handle
        pure (Right identityText)
  where
    readClient path = do
      attempted <- try $ do
        linked <- pathIsSymbolicLink path
        when linked (ioError (userError "inventory client identity is a symlink"))
        status <- getFileStatus path
        unless (fileMode status .&. 0o077 == 0) (ioError (userError "inventory client identity is not private"))
        bytes <- BS.readFile path
        case TE.decodeUtf8' bytes of
          Right value | "client-" `T.isPrefixOf` value, T.length value == 71 -> pure value
          _ -> ioError (userError "inventory client identity is invalid")
      pure (first (StoreIoError . T.pack . show) (attempted :: Either IOException T.Text))

-- | Use the accepted complete scopes as the base of a freshly compiled
-- component candidate. The planner still checks unresolved transactions.
loadTargetSnapshot :: ActiveTarget -> IO ScopeSnapshot
loadTargetSnapshot target = do
  context <- either dieText pure (mkContextId (contextNameText (target ^. #contextName)))
  project <- either dieText pure (mkName (target ^. #profile . #project))
  let binding = ContextBinding context project
  store <- openTargetStore target
  _ <- initializeStore store binding (clientIdentity target) >>= either (dieText . showText) pure
  history <- loadInventoryHistory store >>= either (dieText . showText) pure
  either (dieText . showText . NE.toList) pure (mkScopeSnapshot binding
    (Map.map (\(revision, declaration) -> (revisionGeneration revision, declaration)) (historyAccepted history))
    (historyReservations history))

validateTarget :: ActiveTarget -> CompositionCandidate -> IO ()
validateTarget target candidate = do
  let binding = inventoryBinding (candidateInventory candidate)
      expectedProject = target ^. #profile . #project
  unless (nameText (binding ^. #project) == expectedProject) $
    dieText ("inventory candidate targets project " <> nameText (binding ^. #project) <> ", active context targets " <> expectedProject)

validateReviewTarget :: ActiveTarget -> ContextBinding -> IO ()
validateReviewTarget target binding = do
  let expectedProject = target ^. #profile . #project
  unless (nameText (binding ^. #project) == expectedProject) $
    dieText ("inventory review targets project " <> nameText (binding ^. #project) <> ", active context targets " <> expectedProject)

clientIdentity :: ActiveTarget -> Text
clientIdentity target =
  "client-" <> T.take 24 (digestText (contentDigest (TE.encodeUtf8 (contextNameText (target ^. #contextName)))))

manifestOnlyRegistry :: InventoryHistory -> AdapterRegistry
manifestOnlyRegistry history =
  either (error . T.unpack) id (mkAdapterRegistry (map (manifestAdapterFor history) executors))
  where
    executors = [KubernetesExecutor, PulumiExecutor, HostExecutor, ArtifactExecutor, CacheExecutor, HelmExecutor]

manifestAdapterFor :: InventoryHistory -> Executor -> Adapter
manifestAdapterFor history executor =
  Adapter
    { adapterExecutor = executor
    , adapterIdentity = "manifest-only"
    , adapterVersion = "1"
    , adapterObserve = \resources -> pure (observationSet [(resource, observation resource) | resource <- resources])
    , adapterPrepare = \operation -> pure (Right (PreparedNative (canonicalOperation operation) "manifest-only review; a provider adapter is required before apply"))
    , adapterPreflight = \_ _ -> pure (Left "manifest-only reviews are not executable; install the provider adapter delivered by a later inventory plan")
    , adapterExecute = \_ _ -> pure (AdapterEffectFailed (KnownNoEffect "manifest-only adapter cannot execute"))
    , adapterVerify = \_ _ -> pure (Left "manifest-only adapter cannot verify provider state")
    , adapterRecover = \_ _ -> pure (RecoveryUnresolved "manifest-only adapter cannot recover provider state")
    }
  where
    acceptedIds = Set.fromList [declarationId declaration | (_, (_, scope)) <- Map.toAscList (historyAccepted history), bundle <- scopeBundles scope, declaration <- bundle ^. #declarations]
    observation resource
      | Set.member resource acceptedIds = ObservedPresent (physical ("accepted:" <> resourceIdText resource))
      | otherwise = ConfirmedAbsent (contentDigest (TE.encodeUtf8 ("manifest-only-absence:" <> resourceIdText resource)))
    physical value = either (error . T.unpack) id (mkPhysicalIdentity value)
    canonicalOperation = either (error . T.unpack) id . canonicalValue . toJSON

executionBlockedRegistry :: AdapterRegistry
executionBlockedRegistry =
  either (error . T.unpack) id (mkAdapterRegistry (map executionBlockedAdapterFor [KubernetesExecutor, PulumiExecutor, HostExecutor, ArtifactExecutor, CacheExecutor, HelmExecutor]))

executionBlockedAdapterFor :: Executor -> Adapter
executionBlockedAdapterFor executor =
  Adapter
    { adapterExecutor = executor
    , adapterIdentity = "manifest-only"
    , adapterVersion = "1"
    , adapterObserve = \_ -> pure (Left "manifest-only execution registry does not observe")
    , adapterPrepare = \operation -> pure (Left (PrepareRefused (plannedOperationId operation) "manifest-only execution registry does not prepare"))
    , adapterPreflight = \_ _ -> pure (Left "manifest-only reviews are not executable; install the provider adapter delivered by a later inventory plan")
    , adapterExecute = \_ _ -> pure (AdapterEffectFailed (KnownNoEffect "manifest-only adapter cannot execute"))
    , adapterVerify = \_ _ -> pure (Left "manifest-only adapter cannot verify provider state")
    , adapterRecover = \_ _ -> pure (RecoveryUnresolved "manifest-only adapter cannot recover provider state")
    }

renderTransactionResult :: TransactionResult -> Text
renderTransactionResult result = case result of
  Converged transaction -> "converged " <> transactionIdText transaction
  PausedAtBarrier transaction barriers -> "paused " <> transactionIdText transaction <> " at " <> T.pack (show (NE.length barriers)) <> " review barrier(s)"
  StoppedFailed transaction operation failureClass -> "stopped " <> transactionIdText transaction <> " at " <> operationIdText operation <> ": " <> showText failureClass
  StoppedAmbiguous transaction operation -> "ambiguous " <> transactionIdText transaction <> " at " <> operationIdText operation

rejectReentry :: IO ()
rejectReentry = do
  active <- lookupEnv "NAGARE_INVENTORY_TRANSACTION"
  when (maybe False (not . null) active) (dieText "an adapter child may not re-enter an inventory command")

dieText :: Text -> IO a
dieText message = TIO.hPutStrLn stderr message >> exitFailure

showText :: (Show a) => a -> Text
showText = T.pack . show
