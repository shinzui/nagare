module Nagare.Inventory.Command
  ( compileInput
  , compileInventory
  , loadCandidate
  , planInventory
  , planInventoryWith
  , applyInventory
  , applyInventoryWith
  , applyInventoryWithFactory
  , resumeInventory
  , resumeInventoryWith
  , resumeInventoryWithFactory
  , exportInventory
  , manifestAdapterFor
  , executionBlockedAdapterFor
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
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
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire
import Nagare.Target
import System.Directory
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (stderr)
import System.IO.Temp (withTempDirectory)
import System.Posix.Files (setFileMode)

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
  rejectReentry
  candidate <- loadCandidate candidateDirectory >>= either dieText pure
  validateTarget target candidate
  store <- openTargetStore target
  let binding = inventoryBinding (candidateInventory candidate)
  _ <- initializeStore store binding (clientIdentity target) >>= either (dieText . showText) pure
  _ <- seedInventoryHistory store candidate >>= either (dieText . showText) pure
  history <- loadInventoryHistory store >>= either (dieText . showText) pure
  registry <- registryFor candidate history
  let requirements = observationRequirements candidate history
  observations <- observeWithRegistry registry (requirementsByExecutor requirements) >>= either dieText pure
  proposal <- either (dieText . showText . NE.toList) pure (planChanges candidate noLifecycleDecisions history observations)
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

resumeInventory :: ActiveTarget -> Text -> Bool -> IO ()
resumeInventory = resumeInventoryWith executionBlockedRegistry

resumeInventoryWith :: AdapterRegistry -> ActiveTarget -> Text -> Bool -> IO ()
resumeInventoryWith registry = resumeInventoryWithFactory (const (pure registry))

resumeInventoryWithFactory :: (ReviewBundle -> IO AdapterRegistry) -> ActiveTarget -> Text -> Bool -> IO ()
resumeInventoryWithFactory registryFor target transactionToken yes = do
  rejectReentry
  unless yes (dieText "inventory resume requires --yes")
  transaction <- either dieText pure (mkTransactionId transactionToken)
  store <- openTargetStore target
  digest <- either dieText pure (mkContentDigest (T.drop 3 (transactionIdText transaction)))
  bundle <- loadPublishedReview store digest >>= either (dieText . showText) pure
  registry <- registryFor bundle
  result <- resumeTransaction store registry transaction >>= either (dieText . showText . NE.toList) pure
  TIO.putStrLn (renderTransactionResult result)

exportInventory :: ActiveTarget -> FilePath -> IO ()
exportInventory target output = do
  rejectReentry
  store <- openTargetStore target
  result <- withProcessLock store (\locked -> exportStore locked output)
  case result of
    Left err -> dieText (showText err)
    Right (Left err) -> dieText (showText err)
    Right (Right ()) -> TIO.putStrLn (T.pack output)

openTargetStore :: ActiveTarget -> IO InventoryStore
openTargetStore target = do
  stateRoot <- nagareStateDir
  let path = stateRoot </> T.unpack (contextNameText (target ^. #contextName)) </> "inventory"
  openFilesystemStore path >>= either (dieText . showText) pure

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
    executors = [KubernetesExecutor, PulumiExecutor, HostExecutor, ArtifactExecutor, CacheExecutor]

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
  either (error . T.unpack) id (mkAdapterRegistry (map executionBlockedAdapterFor [KubernetesExecutor, PulumiExecutor, HostExecutor, ArtifactExecutor, CacheExecutor]))

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
