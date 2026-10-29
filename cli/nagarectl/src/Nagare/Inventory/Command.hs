module Nagare.Inventory.Command
  ( compileInput
  , compileInventory
  , loadCandidate
  , loadTargetSnapshot
  , loadTargetSnapshotReadOnly
  , OpenedInventory (..)
  , openInventoryForPlanning
  , openedSnapshot
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
  , planInventoryCandidateLoaded
  , planInventoryCandidateQuiet
  , convergeInventoryCandidateResult
  , planInventoryCandidateWithDecider
  , planInventoryCandidateWithPayloadIdentity
  , convergeInventoryCandidateWith
  , planInventoryCandidateAdoptionWith
  , planInventoryCandidateWithDecider
  , planInventoryAdoptionWith
  , validateTarget
  , clientIdentity
  , rejectReentry
  , dieText
  , planInventoryRetirementWith
  , planInventoryRetirementsWith
  , planInventoryCollectionWith
  , planInventoryCollectionsWith
  , tryPlanInventoryCollectionWith
  , applyInventory
  , applyInventoryWith
  , applyInventoryWithFactory
  , renderTransactionResult
  , resumeInventory
  , resumeInventoryWith
  , resumeInventoryWithFactory
  , resumeInventoryWithFactoryTakeover
  , recoverInventoryWithFactory
  , closeInventoryWithFactory
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
import Nagare.Contract.Problem (ProblemSpec, admissionRefused, reviewChanged, storeUnavailable, unclassified, wrongContext)
import Nagare.Contract.Project (savedReview)
import Nagare.Contract.Sink (contractSinkSet, emitDocument, progressLine, refuseWith, reportTransaction)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Command.Open
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal
import Nagare.Inventory.Lifecycle
import Nagare.Inventory.Lineage (renderRebuild)
import Nagare.Inventory.ManifestAdapter (manifestAdapterFor, manifestOnlyRegistry)
import Nagare.Inventory.Migration
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Counters (tracePhase)
import Nagare.Inventory.Store.Discovery
import Nagare.Inventory.Store.Remote qualified as Remote
import Nagare.Inventory.Store.Target (openProfileReviewStoreReadOnly, openRemoteStore, openTargetStoreReadOnly, remoteInventoryUrl)
import Nagare.Inventory.Store.TargetMigration (migrateTargetStore)
import Nagare.Platform.Paths (renderPlatformPathError, resolvePlatformPaths)
import Nagare.Platform.Transition (transitionContinueRefusal)
import Nagare.Platform.Workspace (readPayloadManifest, renderWorkspaceError)
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
planInventoryWithRetirements ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  ActiveTarget ->
  FilePath ->
  [ResourceId] ->
  FilePath ->
  IO ()
planInventoryWithRetirements registryFor target candidateDirectory resources output = do
  candidate <- loadCandidate candidateDirectory >>= either dieText pure
  planInventoryCandidateWithRetirements registryFor target candidate resources output

planInventoryCandidateWithRetirements ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  ActiveTarget ->
  CompositionCandidate ->
  [ResourceId] ->
  FilePath ->
  IO ()
planInventoryCandidateWithRetirements registryFor target candidate resources output = do
  when
    (Set.size (Set.fromList resources) /= length resources)
    (dieText "retirement resource IDs must be distinct")
  let decide history observations = do
        proposals <-
          traverse
            ( \resource -> case Map.lookup resource (observationMap observations) of
                Nothing ->
                  Left
                    ( PlanError
                        "retirement-observation"
                        "selected resource lacks a fresh provider observation"
                        [resource]
                        :| []
                    )
                Just fact ->
                  Right
                    ( LifecycleProposal
                        resource
                        ApproveRetirement
                        (lifecycleObservationDigest (inventoryBinding (candidateInventory candidate)) resource fact)
                    )
            )
            resources
        validateLifecycleDecisions candidate history observations proposals
  planInventoryCandidateWithDecider registryFor decide target candidate output

-- | Versioned adoption proposals name a compiled candidate and exact
-- observed incarnations. The decision is validated after fresh observation.
planInventoryAdoptionWith :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) -> ActiveTarget -> FilePath -> FilePath -> IO ()
planInventoryAdoptionWith registryFor target inputFile output = do
  bytes <-
    (try (BS.readFile inputFile) :: IO (Either IOException ByteString))
      >>= either (dieText . showText) pure
  proposalInput <- either dieText pure (decodeAdoptionInput bytes)
  let relative = adoptionCandidateDirectory proposalInput
      candidateDirectory = if isAbsolute relative then relative else takeDirectory inputFile </> relative
  candidate <- loadCandidate candidateDirectory >>= either dieText pure
  planInventoryCandidateWithDecider
    registryFor
    (\history observations -> decideAdoption candidate history observations proposalInput)
    target
    candidate
    output

-- | Domain compilers can retain private native bytes while submitting an
-- explicit adoption decision for their already composed candidate. The input
-- still binds exact observed incarnations and the current context.
planInventoryCandidateAdoptionWith ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  ActiveTarget ->
  CompositionCandidate ->
  AdoptionInput ->
  FilePath ->
  IO ()
planInventoryCandidateAdoptionWith registryFor target candidate proposalInput output =
  planInventoryCandidateWithDecider
    registryFor
    (\history observations -> decideAdoption candidate history observations proposalInput)
    target
    candidate
    output

-- | A migration reads source and destination through distinct registries.
-- One ordinary registry cannot represent two physical incarnations of an ID.
planInventoryRetirementWith ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  ActiveTarget ->
  ScopeId ->
  FilePath ->
  IO ()
planInventoryRetirementWith registryFor target owner =
  planInventoryRetirementsWith registryFor (const (Right ())) target (owner :| [])

-- | Batch retirement with an additional read-only observation guard. The
-- ordinary lifecycle validator still supplies all retirement authority.
planInventoryRetirementsWith ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  (ObservationSet -> Either (NonEmpty PlanError) ()) ->
  ActiveTarget ->
  NonEmpty ScopeId ->
  FilePath ->
  IO ()
planInventoryRetirementsWith registryFor check target owners output = do
  snapshot <- loadTargetSnapshot target
  unless
    (Set.size (Set.fromList (NE.toList owners)) == NE.length owners)
    (dieText "retirement scope IDs must be distinct")
  unless
    (all (`Map.member` snapshotScopes snapshot) owners)
    (dieText "retirement scope is absent from accepted inventory history")
  candidate <-
    either
      (dieText . showText . NE.toList)
      pure
      (composeInventory snapshot (fmap (`RetireScope` RetainResources) owners))
  planInventoryCandidateWithDecider
    registryFor
    (\history observations -> check observations >> decideRetirement candidate history observations)
    target
    candidate
    output

planInventoryCollectionWith ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  ActiveTarget ->
  ResourceId ->
  FilePath ->
  IO ()
planInventoryCollectionWith registryFor target resource =
  planInventoryCollectionsWith registryFor target (resource :| [])

planInventoryCollectionsWith ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  ActiveTarget ->
  NonEmpty ResourceId ->
  FilePath ->
  IO ()
planInventoryCollectionsWith registryFor target resources output = do
  when
    (Set.size (Set.fromList (NE.toList resources)) /= length (NE.toList resources))
    (dieText "collection resource IDs must be distinct")
  snapshot <- loadTargetSnapshot target
  candidate <-
    either
      (dieText . showText . NE.toList)
      pure
      (composeInventory snapshot (fmap CollectRetained resources))
  planInventoryCandidateWithDecider
    registryFor
    (\history observations -> decideCollection candidate history observations)
    target
    candidate
    output

-- | Save the reviewed collection of one retained resource, or return why its
-- review refuses without ending the process, so a caller can try another
-- resource (F101). A refusal publishes nothing.
tryPlanInventoryCollectionWith ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  ActiveTarget ->
  ResourceId ->
  FilePath ->
  IO (Either Text ())
tryPlanInventoryCollectionWith registryFor target resource output = do
  snapshot <- loadTargetSnapshot target
  case composeInventory snapshot (CollectRetained resource :| []) of
    Left errors -> pure (Left (showText (NE.toList errors)))
    Right candidate -> do
      prepared <-
        tryPrepareInventoryCandidateWithDeciderPayload
          registryFor
          (\history observations -> decideCollection candidate history observations)
          "operator-cli"
          target
          candidate
      traverse (\(_, bundle, digest) -> writePlannedReview output bundle digest) prepared

-- | Plan a freshly compiled component candidate with native member bytes held
-- by the caller. Publication still retains those bytes in the private review.
planInventoryCandidateWith :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) -> ActiveTarget -> CompositionCandidate -> FilePath -> IO ()
planInventoryCandidateWith registryFor =
  planInventoryCandidateWithDecider registryFor (\_ _ -> Right noLifecycleDecisions)

-- | 'planInventoryCandidateWith' against an inventory the command already
-- opened (EP-212).
planInventoryCandidateLoaded :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) -> ActiveTarget -> OpenedInventory -> CompositionCandidate -> FilePath -> IO ()
planInventoryCandidateLoaded registryFor target opened candidate output = do
  (_, bundle, digest) <-
    tryPrepareInventoryCandidateLoaded registryFor (\_ _ -> Right noLifecycleDecisions) "operator-cli" target opened candidate
      >>= either dieText pure
  writePlannedReview output bundle digest

-- | Bootstrap stages record their immutable selected payload even when the
-- current review has no final cluster marker yet.
planInventoryCandidateWithPayloadIdentity ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  T.Text ->
  ActiveTarget ->
  CompositionCandidate ->
  FilePath ->
  IO ()
planInventoryCandidateWithPayloadIdentity registryFor = planInventoryCandidateWithDeciderPayload registryFor (\_ _ -> Right noLifecycleDecisions)

planInventoryCandidateWithDecider ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions) ->
  ActiveTarget ->
  CompositionCandidate ->
  FilePath ->
  IO ()
planInventoryCandidateWithDecider registryFor decide target candidate output = do
  planInventoryCandidateWithDeciderPayload registryFor decide "operator-cli" target candidate output

planInventoryCandidateWithDeciderPayload ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions) ->
  T.Text ->
  ActiveTarget ->
  CompositionCandidate ->
  FilePath ->
  IO ()
planInventoryCandidateWithDeciderPayload registryFor decide payloadIdentity target candidate output = do
  (_, bundle, digest) <- prepareInventoryCandidateWithDeciderPayload registryFor decide payloadIdentity target candidate
  writePlannedReview output bundle digest

-- | Write the review; under @--contract 1@ print its saved-review document.
writePlannedReview :: FilePath -> ReviewBundle -> ContentDigest -> IO ()
writePlannedReview output bundle digest = do
  _ <- writeReviewBundle output bundle >>= either dieText pure
  contract <- contractSinkSet
  if contract then makeAbsolute output >>= \directory -> emitDocument (savedReview directory bundle digest) else printPlannedReview bundle digest

-- | Plan and write a review without printing it, for a caller with its own
-- document.
planInventoryCandidateQuiet :: (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) -> ActiveTarget -> CompositionCandidate -> FilePath -> IO (ReviewBundle, ContentDigest)
planInventoryCandidateQuiet registryFor target candidate output = do
  (_, bundle, digest) <- prepareInventoryCandidateWithDecider registryFor (\_ _ -> Right noLifecycleDecisions) target candidate
  (bundle, digest) <$ (writeReviewBundle output bundle >>= either dieText pure)

printPlannedReview :: ReviewBundle -> ContentDigest -> IO ()
printPlannedReview bundle digest = do
  TIO.putStrLn (digestText digest)
  mapM_ (TIO.putStrLn . uncurry renderRebind) (Map.toAscList (reviewRebinds (reviewBundleDocument bundle)))
  mapM_ (TIO.putStrLn . uncurry renderRebuild) (Map.toAscList (reviewRebuilds (reviewBundleDocument bundle)))

-- | Apply a standard create/update review in the same invocation. The review
-- is published first, then reloaded so execution has only immutable evidence.
-- Lifecycle decisions still require a separately reviewed command.
convergeInventoryCandidateWith ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  (ReviewInventory -> ReviewBundle -> IO AdapterRegistry) ->
  ActiveTarget ->
  CompositionCandidate ->
  IO ()
convergeInventoryCandidateWith planningRegistry executionRegistry target candidate = do
  (_, result) <- convergeInventoryCandidateResult planningRegistry executionRegistry target candidate
  reportTransaction (renderTransactionResult result) result

-- | Publish, apply and return the result; progress lines go to stderr under
-- @--contract 1@.
convergeInventoryCandidateResult ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  (ReviewInventory -> ReviewBundle -> IO AdapterRegistry) ->
  ActiveTarget ->
  CompositionCandidate ->
  IO (ContentDigest, TransactionResult)
convergeInventoryCandidateResult planningRegistry executionRegistry target candidate = do
  (store, _, digest) <- prepareInventoryCandidateWithDecider planningRegistry (\_ _ -> Right noLifecycleDecisions) target candidate
  requireTransitionOwner store
  bundle <- loadPublishedReview store digest >>= either (dieText . showText) pure
  validateReviewTarget target (reviewContextBinding (reviewBundleDocument bundle))
  progressLine ("Published review " <> digestText digest)
  forM_ (reviewOperations (reviewBundleDocument bundle)) (progressLine . reviewPublicSummary)
  registry <- executionRegistry (ReviewInventory store Nothing) bundle
  snapshot <- readReviewSnapshot store (reviewDigest bundle) >>= either (dieText . showText) pure
  reviewed <- either (dieText . showText . NE.toList) pure (verifyReview snapshot bundle)
  (,) digest <$> (applyReviewed store registry reviewed >>= either (dieText . showText . NE.toList) pure)

prepareInventoryCandidateWithDecider ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions) ->
  ActiveTarget ->
  CompositionCandidate ->
  IO (InventoryStore, ReviewBundle, ContentDigest)
prepareInventoryCandidateWithDecider registryFor decide target candidate = do
  prepareInventoryCandidateWithDeciderPayload registryFor decide "operator-cli" target candidate

prepareInventoryCandidateWithDeciderPayload ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions) ->
  T.Text ->
  ActiveTarget ->
  CompositionCandidate ->
  IO (InventoryStore, ReviewBundle, ContentDigest)
prepareInventoryCandidateWithDeciderPayload registryFor decide payloadIdentity target candidate =
  tryPrepareInventoryCandidateWithDeciderPayload registryFor decide payloadIdentity target candidate
    >>= either dieText pure

-- | As 'prepareInventoryCandidateWithDeciderPayload', but the candidate's own
-- refusal (observation, lifecycle decision, plan or review preparation) is
-- returned instead of ending the process. Nothing is published on a refusal.
tryPrepareInventoryCandidateWithDeciderPayload ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions) ->
  T.Text ->
  ActiveTarget ->
  CompositionCandidate ->
  IO (Either Text (InventoryStore, ReviewBundle, ContentDigest))
tryPrepareInventoryCandidateWithDeciderPayload registryFor decide payloadIdentity target candidate = do
  rejectReentry
  validateTarget target candidate
  (store, observed) <- openTargetStoreAtHead target
  let binding = inventoryBinding (candidateInventory candidate)
  headValue <- initializeStoreFrom store binding (clientIdentity target) observed >>= either (dieText . showText) pure
  history <- loadInventoryHistoryAt store headValue >>= either (dieText . showText) pure
  tryPrepareInventoryCandidateLoaded registryFor decide payloadIdentity target (OpenedInventory store headValue history) candidate

-- | Plan a candidate against an inventory the command already opened, at the
-- head it pinned: no second open, head read, history load or listing
-- (EP-212). Only a new store that is seeded here is loaded again.
tryPrepareInventoryCandidateLoaded ::
  (CompositionCandidate -> InventoryHistory -> IO AdapterRegistry) ->
  (InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions) ->
  T.Text ->
  ActiveTarget ->
  OpenedInventory ->
  CompositionCandidate ->
  IO (Either Text (InventoryStore, ReviewBundle, ContentDigest))
tryPrepareInventoryCandidateLoaded registryFor decide payloadIdentity target opened candidate = do
  rejectReentry
  validateTarget target candidate
  let store = opened ^. #inventoryStore
      pinned = opened ^. #pinnedHead
  headValue <- seedInventoryHistoryAt store pinned candidate >>= either (dieText . showText) pure
  loaded <-
    if headValue == pinned
      then pure (opened ^. #loadedHistory)
      else loadInventoryHistoryAt store headValue >>= either (dieText . showText) pure
  history <- tracePhase "history load" (loadInventoryPlanningHistoryFrom store loaded candidate) >>= either (dieText . showText) pure
  registry <- tracePhase "runtime setup" (registryFor candidate history)
  let requirements = observationRequirements candidate history
  observed <- tracePhase "observation" (observeWithRegistry registry (requirementsByExecutor requirements))
  -- Notes, such as a reader's pending objects (EP-206), go to stderr.
  forM_ observed $ \observations ->
    forM_ (Map.toAscList (observationNotes observations)) $ \(resource, note) ->
      TIO.hPutStrLn stderr ("note: " <> resourceIdText resource <> ": " <> note)
  case observed >>= \observations -> first renderPlanErrors (decide history observations >>= \decisions -> planChanges candidate decisions history observations) of
    Left reason -> pure (Left reason)
    Right proposal -> do
      prepared <- tracePhase "review preparation" (prepareReviewWithPayloadIdentity payloadIdentity registry headValue proposal)
      case prepared of
        Left errors -> pure (Left (showText (NE.toList errors)))
        Right bundle -> do
          digest <- tracePhase "review publication" (publishReview store bundle) >>= either (dieText . showText) pure
          pure (Right (store, bundle, digest))

applyInventory :: ActiveTarget -> FilePath -> Bool -> IO ()
applyInventory = applyInventoryWith executionBlockedRegistry

applyInventoryWith :: AdapterRegistry -> ActiveTarget -> FilePath -> Bool -> IO ()
applyInventoryWith registry = applyInventoryWithFactory (\_ _ -> pure registry)

-- | Construct adapters only after the private, immutable review has been
-- loaded. Public review directories intentionally omit native provider bytes.
applyInventoryWithFactory :: (ReviewInventory -> ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> FilePath -> Bool -> IO ()
applyInventoryWithFactory registryFor target reviewDirectory yes = do
  rejectReentry
  unless yes (dieText "inventory apply requires --yes after reviewing the bound plan")
  publicBundle <- loadReviewBundle reviewDirectory >>= either dieText pure
  validateReviewTarget target (reviewContextBinding (reviewBundleDocument publicBundle))
  (store, observed) <- tracePhase "inventory open" (openTargetStoreAtHead target)
  requireTransitionOwnerAt observed
  bundle <- tracePhase "review load" $ loadPublishedReview store (reviewDigest publicBundle) >>= either (dieCoded reviewChanged . showText) pure
  unless
    ( reviewBundleDocument bundle == reviewBundleDocument publicBundle
        && reviewBundleScopes bundle == reviewBundleScopes publicBundle
    )
    (dieCoded reviewChanged "review directory differs from the immutable review published by this store")
  headValue <- maybe (dieCoded storeUnavailable (showText (StoreConditionFailed "inventory store is not initialized"))) pure observed
  -- EP-212: one history, loaded at the head this command read, serves the
  -- registry and admission; admission reloads if the locked head moved. A
  -- failed load is left to them, so every refusal stays as it was.
  pinned <- either (const Nothing) Just <$> tracePhase "history load" (loadInventoryHistoryAt store headValue)
  registry <- tracePhase "runtime setup" (registryFor (ReviewInventory store pinned) bundle)
  snapshot <- readReviewSnapshotAt store headValue (reviewDigest bundle) >>= either (dieCoded storeUnavailable . showText) pure
  reviewed <- either (dieCoded reviewChanged . showText . NE.toList) pure (verifyReview snapshot bundle)
  result <- tracePhase "transaction" (applyReviewedWithHistory store registry reviewed pinned) >>= either (dieCoded admissionRefused . showText . NE.toList) pure
  reportTransaction (renderTransactionResult result) result

resumeInventory :: ActiveTarget -> Text -> Bool -> IO ()
resumeInventory = resumeInventoryWith executionBlockedRegistry

resumeInventoryWith :: AdapterRegistry -> ActiveTarget -> Text -> Bool -> IO ()
resumeInventoryWith registry = resumeInventoryWithFactory (\_ _ -> pure registry)

resumeInventoryWithFactory :: (ReviewInventory -> ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> Text -> Bool -> IO ()
resumeInventoryWithFactory registryFor target transactionToken yes =
  resumeInventoryWithFactoryTakeover registryFor target transactionToken yes False

resumeInventoryWithFactoryTakeover :: (ReviewInventory -> ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> Text -> Bool -> Bool -> IO ()
resumeInventoryWithFactoryTakeover registryFor target transactionToken yes takeOver = do
  rejectReentry
  unless yes (dieText "inventory resume requires --yes")
  transaction <- either dieText pure (mkTransactionId transactionToken)
  store <- openTargetStore target
  requireTransitionOwner store
  current <- readHead store >>= either (dieText . showText) pure
  registry <- case current of
    Just headValue | headActiveTransaction headValue == Just (transactionIdText transaction) -> do
      digest <- either dieText pure (mkContentDigest (T.drop 3 (transactionIdText transaction)))
      bundle <- loadPublishedReview store digest >>= either (dieText . showText) pure
      registryFor (ReviewInventory store Nothing) bundle
    _ -> either dieText pure (mkAdapterRegistry [])
  result <- resumeTransactionWithTakeover store registry transaction takeOver >>= either (dieCoded admissionRefused . showText . NE.toList) pure
  reportTransaction (renderTransactionResult result) result

prepareRegistryRecoveryWithFactory ::
  (ReviewInventory -> ReviewBundle -> IO AdapterRegistry) ->
  ActiveTarget ->
  Text ->
  Text ->
  FilePath ->
  IO ()
prepareRegistryRecoveryWithFactory registryFor target transactionToken operationToken output = do
  rejectReentry
  transaction <- either dieText pure (mkTransactionId transactionToken)
  operation <- either dieText pure (mkOperationId operationToken)
  digest <- either dieText pure (mkContentDigest (T.drop 3 transactionToken))
  store <- openTargetStore target
  bundle <- loadPublishedReview store digest >>= either (dieText . showText) pure
  registry <- registryFor (ReviewInventory store Nothing) bundle
  input <-
    prepareBootstrapRegistryRecovery store registry transaction operation
      >>= either dieText pure
  action <- case recoveryAction input of
    RecoverBootstrapRegistry native -> pure ("recover-bootstrap-registry:" <> digestText native)
    _ -> dieText "registry recovery preparation returned another action"
  bytes <-
    either
      dieText
      pure
      ( canonicalValue
          ( object
              [ "version" .= (1 :: Int)
              , "transaction" .= recoveryTransaction input
              , "operation" .= recoveryOperation input
              , "review" .= recoveryReview input
              , "action" .= action
              ]
          )
      )
  handle <-
    openFd
      output
      WriteOnly
      (defaultFileFlags {creat = Just 0o600, exclusive = True})
      >>= fdToHandle
  BS.hPut handle bytes
  hClose handle
  TIO.putStrLn ("Saved bounded host registry recovery: " <> T.pack output)
  TIO.putStrLn "Replay accepted nagare-registries-refresh.service and restart k3s.service only; workload readiness remains independently required"

recoverInventoryWithFactory ::
  (ReviewInventory -> ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> Text -> Text -> FilePath -> Bool -> IO ()
recoverInventoryWithFactory registryFor target transactionToken operationToken decisionFile takeOver = do
  rejectReentry
  transaction <- either dieText pure (mkTransactionId transactionToken)
  operation <- either dieText pure (mkOperationId operationToken)
  bytes <- try (BS.readFile decisionFile) :: IO (Either IOException ByteString)
  input <- either (dieText . showText) (either dieText pure . decodeOperatorRecoveryInput) bytes
  unless
    (recoveryTransaction input == transaction && recoveryOperation input == operation)
    (dieText "recovery decision file does not match the requested transaction and operation")
  store <- openTargetStore target
  requireTransitionOwner store
  bundle <- loadPublishedReview store (recoveryReview input) >>= either (dieText . showText) pure
  registry <- registryFor (ReviewInventory store Nothing) bundle
  if recoveryAction input `elem` closeAliases
    then do
      -- ADR 26: the stop and abandon actions are aliases of close, which
      -- names the transaction; the operation only has to belong to it.
      unless
        (operation `elem` map (plannedOperationId . reviewPlannedOperation) (reviewOperations (reviewBundleDocument bundle)))
        (dieText "the recovery decision names an operation outside the transaction's review")
      record <- closeTransaction store registry (CloseInput transaction (recoveryReview input) takeOver Nothing) >>= either (dieText . showText . NE.toList) pure
      TIO.putStr (renderCloseRecord record)
    else do
      recordOperatorRecovery store registry input takeOver >>= either (dieText . showText . NE.toList) pure
      reportRecovery store transaction input
  where
    closeAliases = [StopIncompleteApplication, AbandonRefusedOperation, AbandonPartialPrune, AbandonPartialVolumeRestore, AbandonPartialDatabaseRestore]

-- | ADR 26: close a stopped transaction by per-operation proof.
closeInventoryWithFactory ::
  (ReviewInventory -> ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> Text -> Text -> Maybe FilePath -> Bool -> IO ()
closeInventoryWithFactory registryFor target transactionToken reviewToken attestFile takeOver = do
  rejectReentry
  transaction <- either dieText pure (mkTransactionId transactionToken)
  review <- either dieText pure (mkContentDigest reviewToken)
  attestation <- forM attestFile $ \file -> do
    bytes <- try (BS.readFile file) :: IO (Either IOException ByteString)
    either (dieText . showText) (either (dieText . ("attestation: " <>)) pure . decodeAttestation) bytes
  store <- openTargetStore target
  requireTransitionOwner store
  bundle <- loadPublishedReview store review >>= either (dieText . showText) pure
  registry <- registryFor (ReviewInventory store Nothing) bundle
  record <- closeTransaction store registry (CloseInput transaction review takeOver attestation) >>= either (dieText . T.intercalate "\n" . map admissionErrorMessage . NE.toList) pure
  TIO.putStr (renderCloseRecord record)

reportRecovery :: InventoryStore -> TransactionId -> OperatorRecoveryInput -> IO ()
reportRecovery store transaction input =
  case recoveryAction input of
    RecoverFencedBackup ->
      TIO.putStrLn "Reviewed recovery backup proved and the original restore review closed; inspect inventory status before saving a new review"
    ForwardFencedRelease -> do
      current <- readHead store >>= either (dieText . showText) pure
      case current of
        Just headValue
          | headActiveTransaction headValue /= Just (transactionIdText transaction) ->
              TIO.putStrLn "Reviewed recovery backup released and the original restore review closed; inspect inventory status before saving a new review"
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
  unless
    (effectiveInventoryStore (target ^. #profile) == InventoryStoreLocal)
    (dieText "inventory restore requires a local store; migrate a restored local history to GCS afterward")
  source <- openFilesystemStoreReadOnly backup >>= either (dieText . showText) pure
  sourceHead <- readHead source >>= either (dieText . showText) (maybe (dieText "backup has no inventory head") pure)
  context <- either dieText pure (mkContextId (contextNameText (target ^. #contextName)))
  project <- either dieText pure (mkName (target ^. #profile . #project))
  unless
    (headBinding sourceHead == ContextBinding context project)
    (dieText "backup belongs to a different context or provider project")
  when
    (isJust (headMigration sourceHead))
    (dieText "backup is a migrated source; restore an export of the active history")
  TIO.putStrLn
    ( "Inventory restore review: "
        <> contextNameText (target ^. #contextName)
        <> " in "
        <> target ^. #profile . #project
        <> ", generation "
        <> T.pack (show (headGeneration sourceHead))
        <> ", sequence "
        <> T.pack (show (headSequence sourceHead))
        <> ", from "
        <> T.pack backup
    )
  if not yes
    then TIO.putStrLn "Review only; pass --yes to restore into an empty local inventory store."
    else do
      store <- openTargetStore target
      result <- withProcessLock store (\_ -> restoreStoreFor store backup (ContextBinding context project))
      case result of
        Left err -> dieText (showText err)
        Right (Left err) -> dieText (showText err)
        Right (Right ()) -> TIO.putStrLn "Private inventory history restored; inspect inventory store status before mutation."

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
    dieCoded wrongContext ("inventory review targets project " <> nameText (binding ^. #project) <> ", active context targets " <> expectedProject)

-- | EP-172: while a release transition is open, only the target payload's
-- nagarectl applies, resumes, recovers or closes; any other refuses and
-- names it, unless the store is idle (F130: a newer release supersedes). The running payload is read only when a transition is open.
requireTransitionOwner :: InventoryStore -> IO ()
requireTransitionOwner store = readHead store >>= either (dieText . showText) pure >>= requireTransitionOwnerAt

requireTransitionOwnerAt :: Maybe HeadManifest -> IO ()
requireTransitionOwnerAt current =
  forM_ current $ \headValue -> forM_ (headTransition headValue) $ \marker -> do
    paths <- resolvePlatformPaths Nothing >>= either (dieText . renderPlatformPathError) pure
    manifest <- readPayloadManifest paths >>= either (dieText . renderWorkspaceError) pure
    forM_ (transitionContinueRefusal headValue marker (manifest ^. #payloadId)) dieText

executionBlockedRegistry :: AdapterRegistry
executionBlockedRegistry =
  either (error . T.unpack) id (mkAdapterRegistry (map executionBlockedAdapterFor [KubernetesExecutor, PulumiExecutor, CloudFoundationExecutor, HostExecutor, ArtifactExecutor, CacheExecutor, BrokerExecutor, HelmExecutor, CdnExecutor, AccessExecutor, AppDatabaseExecutor]))

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
    , adapterSettle = Nothing
    , adapterRecover = \_ _ -> pure (RecoveryUnresolved "manifest-only adapter cannot recover provider state")
    }

renderTransactionResult :: TransactionResult -> Text
renderTransactionResult result = case result of
  Converged transaction -> "converged " <> transactionIdText transaction
  PausedAtBarrier transaction barriers -> "paused " <> transactionIdText transaction <> " at " <> T.pack (show (NE.length barriers)) <> " review barrier(s)"
  StoppedFailed transaction operation failureClass -> "stopped " <> transactionIdText transaction <> " at " <> operationIdText operation <> ": " <> showText failureClass
  StoppedAmbiguous transaction operation reason -> "ambiguous " <> transactionIdText transaction <> " at " <> operationIdText operation <> ": " <> reason
  Closed transaction -> "closed " <> transactionIdText transaction

rejectReentry :: IO ()
rejectReentry = do
  active <- lookupEnv "NAGARE_INVENTORY_TRANSACTION"
  when (maybe False (not . null) active) (dieText "an adapter child may not re-enter an inventory command")
