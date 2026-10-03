module Nagare.Inventory.Command
  ( compileInput
  , compileInventory
  , loadCandidate
  , loadTargetSnapshot
  , loadTargetSnapshotReadOnly
  , openTargetStore
  , openTargetStoreReadOnly
  , openProfileReviewStoreReadOnly
  , selectFoundationStore
  , migrateTargetStore
  , planInventory
  , planInventoryWith
  , planInventoryWithRetirements
  , planInventoryCandidateWithRetirements
  , planInventoryCandidateWith
  , planInventoryCandidateWithPayloadIdentity
  , convergeInventoryCandidateWith
  , planInventoryCandidateAdoptionWith
  , planInventoryAdoptionWith
  , planInventoryMigrationWith
  , planInventoryRetirementWith
  , planInventoryCollectionWith
  , planInventoryCollectionsWith
  , applyInventory
  , applyInventoryWith
  , applyInventoryWithFactory
  , resumeInventory
  , resumeInventoryWith
  , resumeInventoryWithFactory
  , resumeInventoryWithFactoryTakeover
  , recoverInventoryWithFactory
  , prepareRegistryRecoveryWithFactory
  , exportInventory
  , restoreInventory
  , manifestAdapterFor
  , executionBlockedAdapterFor
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import Crypto.Random (getRandomBytes)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.Bits ((.&.))
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
import Nagare.Inventory.Store.Target (openTargetStoreReadOnly, openProfileReviewStoreReadOnly, openRemoteStore, remoteInventoryUrl)
import Nagare.Inventory.Store.Discovery
import Nagare.Inventory.Store.Remote (remoteObjectOps)
import Nagare.Inventory.Store.Remote qualified as Remote
import Nagare.Ops.PulumiBackend (gcsBucketOfUrl)
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
import System.Timeout (timeout)

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

-- | Retain explicitly named members removed by a compiled scope replacement.
-- A saved review and separate apply are required; collection is a later review.
planInventoryWithRetirements
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> ActiveTarget -> FilePath -> [ResourceId] -> FilePath -> IO ()
planInventoryWithRetirements registryFor target candidateDirectory resources output = do
  candidate <- loadCandidate candidateDirectory >>= either dieText pure
  planInventoryCandidateWithRetirements registryFor target candidate resources output

planInventoryCandidateWithRetirements
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> ActiveTarget -> CompositionCandidate -> [ResourceId] -> FilePath -> IO ()
planInventoryCandidateWithRetirements registryFor target candidate resources output = do
  when (Set.size (Set.fromList resources) /= length resources)
    (dieText "retirement resource IDs must be distinct")
  let decide history observations = do
        proposals <- traverse (\resource -> case Map.lookup resource (observationMap observations) of
          Nothing -> Left (PlanError "retirement-observation"
            "selected resource lacks a fresh provider observation" [resource] :| [])
          Just fact -> Right (LifecycleProposal resource ApproveRetirement
            (lifecycleObservationDigest (inventoryBinding (candidateInventory candidate)) resource fact))) resources
        validateLifecycleDecisions candidate history observations proposals
  planInventoryCandidateWithDecider registryFor decide target candidate output

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

-- | Domain compilers can retain private native bytes while submitting an
-- explicit adoption decision for their already composed candidate. The input
-- still binds exact observed incarnations and the current context.
planInventoryCandidateAdoptionWith
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> ActiveTarget -> CompositionCandidate -> AdoptionInput -> FilePath -> IO ()
planInventoryCandidateAdoptionWith registryFor target candidate proposalInput output =
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
  history <- loadInventoryPlanningHistory store candidate >>= either (dieText . showText) pure
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
  -- A source executor absent from the desired candidate can otherwise fall
  -- back to manifest-only preparation. Its fabricated accepted observation
  -- must never become native migration evidence in a published review.
  forM_ (proposalOperations proposal) $ \operation -> case plannedAction operation of
    MigrateResource _ -> do
      adapter <- either dieText pure (lookupAdapter destinationRegistry (plannedExecutor operation))
      when (adapterIdentity adapter == "manifest-only")
        (dieText "migration stage lacks an installed native provider adapter")
    _ -> pure ()
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
planInventoryCollectionWith registryFor target resource =
  planInventoryCollectionsWith registryFor target (resource :| [])

planInventoryCollectionsWith
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> ActiveTarget -> NonEmpty ResourceId -> FilePath -> IO ()
planInventoryCollectionsWith registryFor target resources output = do
  when (Set.size (Set.fromList (NE.toList resources)) /= length (NE.toList resources))
    (dieText "collection resource IDs must be distinct")
  snapshot <- loadTargetSnapshot target
  candidate <- either (dieText . showText . NE.toList) pure
    (composeInventory snapshot (fmap CollectRetained resources))
  planInventoryCandidateWithDecider registryFor
    (\history observations -> decideCollection candidate history observations)
    target candidate output

-- | Plan a freshly compiled component candidate with native member bytes held
-- by the caller. Publication still retains those bytes in the private review.
planInventoryCandidateWith :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) -> ActiveTarget -> CompositionCandidate -> FilePath -> IO ()
planInventoryCandidateWith registryFor =
  planInventoryCandidateWithDecider registryFor (\_ _ -> Right noLifecycleDecisions)

-- | Bootstrap stages record their immutable selected payload even when the
-- current review has no final cluster marker yet.
planInventoryCandidateWithPayloadIdentity
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> T.Text -> ActiveTarget -> CompositionCandidate -> FilePath -> IO ()
planInventoryCandidateWithPayloadIdentity registryFor payloadIdentity =
  planInventoryCandidateWithDeciderPayload registryFor
    (\_ _ -> Right noLifecycleDecisions) payloadIdentity

planInventoryCandidateWithDecider
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions)
  -> ActiveTarget -> CompositionCandidate -> FilePath -> IO ()
planInventoryCandidateWithDecider registryFor decide target candidate output = do
  planInventoryCandidateWithDeciderPayload registryFor decide "operator-cli" target candidate output

planInventoryCandidateWithDeciderPayload
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions)
  -> T.Text -> ActiveTarget -> CompositionCandidate -> FilePath -> IO ()
planInventoryCandidateWithDeciderPayload registryFor decide payloadIdentity target candidate output = do
  (_, bundle, digest) <- prepareInventoryCandidateWithDeciderPayload registryFor decide payloadIdentity target candidate
  _ <- writeReviewBundle output bundle >>= either dieText pure
  TIO.putStrLn (digestText digest)

-- | Apply a standard create/update review in the same invocation. The review
-- is published first, then reloaded so execution has only immutable evidence.
-- Lifecycle decisions still require a separately reviewed command.
convergeInventoryCandidateWith
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> (InventoryStore -> ReviewBundle -> IO AdapterRegistry)
  -> ActiveTarget -> CompositionCandidate -> IO ()
convergeInventoryCandidateWith planningRegistry executionRegistry target candidate = do
  (store, _, digest) <- prepareInventoryCandidateWithDecider planningRegistry
    (\_ _ -> Right noLifecycleDecisions) target candidate
  bundle <- loadPublishedReview store digest >>= either (dieText . showText) pure
  validateReviewTarget target (reviewContextBinding (reviewBundleDocument bundle))
  TIO.putStrLn ("Published review " <> digestText digest)
  forM_ (reviewOperations (reviewBundleDocument bundle))
    (TIO.putStrLn . reviewPublicSummary)
  registry <- executionRegistry store bundle
  snapshot <- readReviewSnapshot store (reviewDigest bundle) >>= either (dieText . showText) pure
  reviewed <- either (dieText . showText . NE.toList) pure (verifyReview snapshot bundle)
  result <- applyReviewed store registry reviewed >>= either (dieText . showText . NE.toList) pure
  TIO.putStrLn (renderTransactionResult result)
  case result of
    Converged _ -> pure ()
    _ -> exitFailure

prepareInventoryCandidateWithDecider
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions)
  -> ActiveTarget -> CompositionCandidate -> IO (InventoryStore, ReviewBundle, ContentDigest)
prepareInventoryCandidateWithDecider registryFor decide target candidate = do
  prepareInventoryCandidateWithDeciderPayload registryFor decide "operator-cli" target candidate

prepareInventoryCandidateWithDeciderPayload
  :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  -> (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions)
  -> T.Text -> ActiveTarget -> CompositionCandidate -> IO (InventoryStore, ReviewBundle, ContentDigest)
prepareInventoryCandidateWithDeciderPayload registryFor decide payloadIdentity target candidate = do
  rejectReentry
  validateTarget target candidate
  store <- openTargetStore target
  let binding = inventoryBinding (candidateInventory candidate)
  _ <- initializeStore store binding (clientIdentity target) >>= either (dieText . showText) pure
  _ <- seedInventoryHistory store candidate >>= either (dieText . showText) pure
  history <- loadInventoryPlanningHistory store candidate >>= either (dieText . showText) pure
  registry <- registryFor candidate history
  let requirements = observationRequirements candidate history
  observations <- observeWithRegistry registry (requirementsByExecutor requirements) >>= either dieText pure
  decisions <- either (dieText . showText . NE.toList) pure (decide history observations)
  proposal <- either (dieText . showText . NE.toList) pure (planChanges candidate decisions history observations)
  snapshot <- readStoreSnapshot store >>= either (dieText . showText) pure
  bundle <- prepareReviewWithPayloadIdentity payloadIdentity registry snapshot proposal
    >>= either (dieText . showText . NE.toList) pure
  digest <- publishReview store bundle >>= either (dieText . showText) pure
  pure (store, bundle, digest)

applyInventory :: ActiveTarget -> FilePath -> Bool -> IO ()
applyInventory = applyInventoryWith executionBlockedRegistry

applyInventoryWith :: AdapterRegistry -> ActiveTarget -> FilePath -> Bool -> IO ()
applyInventoryWith registry = applyInventoryWithFactory (\_ _ -> pure registry)

-- | Construct adapters only after the private, immutable review has been
-- loaded. Public review directories intentionally omit native provider bytes.
applyInventoryWithFactory :: (InventoryStore -> ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> FilePath -> Bool -> IO ()
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
  registry <- registryFor store bundle
  snapshot <- readReviewSnapshot store (reviewDigest bundle) >>= either (dieText . showText) pure
  reviewed <- either (dieText . showText . NE.toList) pure (verifyReview snapshot bundle)
  result <- applyReviewed store registry reviewed >>= either (dieText . showText . NE.toList) pure
  TIO.putStrLn (renderTransactionResult result)
  case result of
    Converged _ -> pure ()
    _ -> exitFailure

resumeInventory :: ActiveTarget -> Text -> Bool -> IO ()
resumeInventory = resumeInventoryWith executionBlockedRegistry

resumeInventoryWith :: AdapterRegistry -> ActiveTarget -> Text -> Bool -> IO ()
resumeInventoryWith registry = resumeInventoryWithFactory (\_ _ -> pure registry)

resumeInventoryWithFactory :: (InventoryStore -> ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> Text -> Bool -> IO ()
resumeInventoryWithFactory registryFor target transactionToken yes =
  resumeInventoryWithFactoryTakeover registryFor target transactionToken yes False

resumeInventoryWithFactoryTakeover :: (InventoryStore -> ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> Text -> Bool -> Bool -> IO ()
resumeInventoryWithFactoryTakeover registryFor target transactionToken yes takeOver = do
  rejectReentry
  unless yes (dieText "inventory resume requires --yes")
  transaction <- either dieText pure (mkTransactionId transactionToken)
  store <- openTargetStore target
  current <- readHead store >>= either (dieText . showText) pure
  registry <- case current of
    Just headValue | headActiveTransaction headValue == Just (transactionIdText transaction) -> do
      digest <- either dieText pure (mkContentDigest (T.drop 3 (transactionIdText transaction)))
      bundle <- loadPublishedReview store digest >>= either (dieText . showText) pure
      registryFor store bundle
    _ -> either dieText pure (mkAdapterRegistry [])
  result <- resumeTransactionWithTakeover store registry transaction takeOver >>= either (dieText . showText . NE.toList) pure
  TIO.putStrLn (renderTransactionResult result)
  case result of
    Converged _ -> pure ()
    _ -> exitFailure

prepareRegistryRecoveryWithFactory
  :: (InventoryStore -> ReviewBundle -> IO AdapterRegistry) -> ActiveTarget
  -> Text -> Text -> FilePath -> IO ()
prepareRegistryRecoveryWithFactory registryFor target transactionToken operationToken output = do
  rejectReentry
  transaction <- either dieText pure (mkTransactionId transactionToken)
  operation <- either dieText pure (mkOperationId operationToken)
  digest <- either dieText pure (mkContentDigest (T.drop 3 transactionToken))
  store <- openTargetStore target
  bundle <- loadPublishedReview store digest >>= either (dieText . showText) pure
  registry <- registryFor store bundle
  input <- prepareBootstrapRegistryRecovery store registry transaction operation
    >>= either dieText pure
  action <- case recoveryAction input of
    RecoverBootstrapRegistry native -> pure ("recover-bootstrap-registry:" <> digestText native)
    _ -> dieText "registry recovery preparation returned another action"
  bytes <- either dieText pure (canonicalValue (object
    [ "version" .= (1 :: Int), "transaction" .= recoveryTransaction input
    , "operation" .= recoveryOperation input, "review" .= recoveryReview input
    , "action" .= action ]))
  handle <- openFd output WriteOnly
    (defaultFileFlags {creat = Just 0o600, exclusive = True}) >>= fdToHandle
  BS.hPut handle bytes
  hClose handle
  TIO.putStrLn ("Saved bounded host registry recovery: " <> T.pack output)
  TIO.putStrLn "Replay accepted nagare-registries-refresh.service and restart k3s.service only; workload readiness remains independently required"

recoverInventoryWithFactory
  :: (InventoryStore -> ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> Text -> Text -> FilePath -> Bool -> IO ()
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
  registry <- registryFor store bundle
  recordOperatorRecovery store registry input takeOver >>= either (dieText . showText . NE.toList) pure
  case recoveryAction input of
    StopIncompleteApplication ->
      TIO.putStrLn "Incomplete application review stopped; ownership and data retained; inspect inventory status before saving a corrected review"
    AbandonPartialPrune ->
      TIO.putStrLn "Terminal scheduled prune review abandoned; exact provider members remain unresolved until a separate reviewed recovery"
    AbandonPartialVolumeRestore ->
      TIO.putStrLn "Terminal volume restore review abandoned; unaccepted scratch PVC remains unresolved until a separate reviewed recovery; use a fresh restore ID"
    AbandonPartialDatabaseRestore ->
      TIO.putStrLn "Terminal database restore review abandoned; unaccepted scratch database remains unresolved until a separate reviewed recovery; use a fresh restore ID"
    RecoverFencedBackup ->
      TIO.putStrLn "Reviewed recovery backup proved and original restore review abandoned; inspect inventory status before saving a new review"
    ForwardFencedRelease -> do
      current <- readHead store >>= either (dieText . showText) pure
      case current of
        Just headValue | headActiveTransaction headValue /= Just (transactionIdText transaction) ->
          TIO.putStrLn "Reviewed recovery backup released and original restore review abandoned; inspect inventory status before saving a new review"
        _ -> TIO.putStrLn "Reviewed writer release recovered; inspect inventory status, then resume the transaction"
    _ -> TIO.putStrLn "Reviewed recovery action completed; inspect inventory status, then resume the transaction"

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

-- | Restore a verified private export into an empty local context store.
-- The binding is checked before any target write, and the store's conditional
-- restore refuses an occupied destination even if it has no head yet.
restoreInventory :: ActiveTarget -> FilePath -> Bool -> IO ()
restoreInventory target backup yes = do
  rejectReentry
  unless (effectiveInventoryStore (target ^. #profile) == InventoryStoreLocal)
    (dieText "inventory restore requires a local store; migrate a restored local history to GCS afterward")
  source <- openFilesystemStoreReadOnly backup >>= either (dieText . showText) pure
  sourceHead <- readHead source >>= either (dieText . showText) (maybe (dieText "backup has no inventory head") pure)
  context <- either dieText pure (mkContextId (contextNameText (target ^. #contextName)))
  project <- either dieText pure (mkName (target ^. #profile . #project))
  unless (headBinding sourceHead == ContextBinding context project)
    (dieText "backup belongs to a different context or provider project")
  when (isJust (headMigration sourceHead))
    (dieText "backup is a migrated source; restore an export of the active history")
  TIO.putStrLn
    ("Inventory restore review: " <> contextNameText (target ^. #contextName)
      <> " in " <> target ^. #profile . #project
      <> ", generation " <> T.pack (show (headGeneration sourceHead))
      <> ", sequence " <> T.pack (show (headSequence sourceHead))
      <> ", from " <> T.pack backup)
  if not yes
    then TIO.putStrLn "Review only; pass --yes to restore into an empty local inventory store."
    else do
      store <- openTargetStore target
      result <- withProcessLock store (\_ -> restoreStoreFor store backup (ContextBinding context project))
      case result of
        Left err -> dieText (showText err)
        Right (Left err) -> dieText (showText err)
        Right (Right ()) -> TIO.putStrLn "Private inventory history restored; inspect inventory store status before mutation."

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
              Nothing | not (hasSubstantiveHistory headValue) -> pure False
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

-- | Select authority once before bootstrap work. This probe never creates local
-- state, remote format/head, cache, or client identity; migration stays explicit.
selectFoundationStore :: ActiveTarget -> IO (Either StoreError ActiveTarget)
selectFoundationStore target
  | effectiveInventoryStore (target ^. #profile) == InventoryStoreLocal = pure (Right target)
  | otherwise = do
      bounded <- timeout 60000000 discover
      pure (fromMaybe (Left (StoreIoError "inventory discovery exceeded 60 seconds; remote absence is not proved")) bounded)
  where
    localTarget = target & #profile . #inventoryStore .~ InventoryStoreLocal
    contextText = contextNameText (target ^. #contextName)
    project = target ^. #profile . #project
    refused = Left . StoreConditionFailed
    discover = do
      stateRoot <- nagareStateDir
      let path = stateRoot </> T.unpack contextText </> "inventory"
      exists <- doesPathExist path
      local <-
        if not exists
          then pure (Right Nothing)
          else do
            opened <- openFilesystemStoreReadOnly path
            case opened of
              Left err -> pure (Left err)
              Right store ->
                readHead store >>= \case
                  Right Nothing -> pure (refused "local inventory directory has no head; inspect incomplete history before bootstrap")
                  result -> pure result
      stored <- readContextProfile (target ^. #contextName)
      ambient <- lookupEnv "CLOUDSDK_CORE_PROJECT"
      case (mkContextId contextText, mkName project, stored, local) of
        (Right context, Right provider, Right persisted, Right localHead)
          | persisted ^. #project /= project -> pure (refused "active project disagrees with the stored inventory context")
          | remoteInventoryUrl (target & #profile .~ persisted) /= remoteInventoryUrl target ->
              pure (refused "active remote inventory URL disagrees with the stored context")
          | Just actual <- ambient, T.pack actual /= project -> pure (refused "ambient gcloud project disagrees with the inventory context")
          | maybe False ((/= ContextBinding context provider) . headBinding) localHead ->
              pure (refused "local inventory head belongs to another context or provider project")
          | Just marker <- localHead >>= headMigration
          , migrationDestination marker /= remoteInventoryUrl target ->
              pure (refused "local inventory migration destination differs from the selected remote store")
          | otherwise -> do
              remote <- Remote.remoteDiscoveryOps project (remoteInventoryUrl target)
              case remote of
                Left reason -> pure (Left (StoreIoError reason))
                Right (Remote.BucketUnavailable reason, _, _) -> pure (Left (StoreIoError reason))
                Right (Remote.BucketForeign reason, _, _) -> pure (refused reason)
                Right (Remote.BucketAbsent, _, _) -> pure (choose localHead DiscoveredMissingBucket)
                Right (Remote.BucketOwned _, ops, empty) ->
                  discoverInventoryObjects ops empty (ContextBinding context provider) >>= \case
                    DiscoveryUnavailable reason -> pure (Left (StoreIoError reason))
                    DiscoveryForeign reason -> pure (refused reason)
                    DiscoveryIncomplete reason -> pure (refused reason)
                    result -> pure (choose localHead result)
        (_, _, _, Left err) -> pure (Left err)
        (_, _, Left reason, _) -> pure (refused reason)
        (Left reason, _, _, _) -> pure (refused reason)
        (_, Left reason, _, _) -> pure (refused reason)
    choose localHead result = case chooseHistoryAuthority (remoteInventoryUrl target) localHead result of
      Left reason -> refused reason
      Right UseLocalFoundation -> Right localTarget
      Right UseRemoteHistory -> Right target

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
                      Just _ -> do
                        selected <- remoteObjectOps project destinationLabel
                        case selected of
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

-- | Local credential recovery requires accepted history and never initializes
-- a new authority. An unresolved writer or data fence keeps recovery explicit.
loadTargetSnapshotReadOnly :: ActiveTarget -> IO ScopeSnapshot
loadTargetSnapshotReadOnly target = do
  context <- either dieText pure (mkContextId (contextNameText (target ^. #contextName)))
  project <- either dieText pure (mkName (target ^. #profile . #project))
  let binding = ContextBinding context project
  store <- openTargetStoreReadOnly target >>= either (dieText . showText) pure
  headValue <- readHead store >>= either (dieText . showText) pure
  observed <- maybe (dieText "accepted inventory history is absent") pure headValue
  unless (headBinding observed == binding) (dieText "inventory head belongs to another context or project")
  when (isJust (headActiveTransaction observed) || isJust (headExecutorClaim observed)
      || isJust (headDataFence observed) || isJust (headMigration observed))
    (dieText "accepted inventory has an unresolved transaction, claim, fence or migration; recover it first")
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
    executors = [KubernetesExecutor, PulumiExecutor, CloudFoundationExecutor, HostExecutor, ArtifactExecutor, CacheExecutor, BrokerExecutor, HelmExecutor, CdnExecutor, AccessExecutor]

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
  either (error . T.unpack) id (mkAdapterRegistry (map executionBlockedAdapterFor [KubernetesExecutor, PulumiExecutor, CloudFoundationExecutor, HostExecutor, ArtifactExecutor, CacheExecutor, BrokerExecutor, HelmExecutor, CdnExecutor, AccessExecutor]))

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
