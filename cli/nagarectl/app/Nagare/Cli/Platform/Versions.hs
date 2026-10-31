-- | @nagarectl platform versions@ and @platform versions refresh@ (EP-236).
-- Executable-private CLI boundary: the native providers of a collection.
--
-- Every cluster read runs through the command's admitted, context-bound
-- cluster session with @--request-timeout=5s@; engine versions are read by
-- one fixed statement inside the server's own pod, whose environment holds
-- the credentials. Provider stderr is classified, never stored or printed.
module Nagare.Cli.Platform.Versions
  ( runPlatformVersionsCommand
  , refreshVersionsAfterReview
  )
where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieCoded, dieT)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Contract.Project (storeRefusal)
import Nagare.Contract.Schema (Nullable (..))
import Nagare.Contract.Sink (contractSinkSet, emitDocument, withReadContract)
import Nagare.Contract.Versions
import Nagare.Dsl.Prelude
import Nagare.Host.Config (hostConfigDir)
import Nagare.Inventory.Adapter (PlannedOperation (..))
import Nagare.Inventory.ClusterSession (kubectlConnectionArguments)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ObservationNative (loadObservationNative, observationHelm, observationKubernetes)
import Nagare.Inventory.Plan (historyAccepted, loadInventoryHistory, loadReviewBundle, reviewBundleDocument, reviewOperations, reviewPlannedOperation)
import Nagare.Inventory.Store (InventoryStore, readObject)
import Nagare.Platform.Status (parseHostIdentity)
import Nagare.Platform.Versions
import Nagare.Platform.Versions.Assemble
import Nagare.Platform.Versions.Collect
import Nagare.Platform.Versions.Store
import Nagare.Resource.Inventory (Declaration (..), ManagedResource, scopeBundles)
import Nagare.Resource.Types (ContextBinding (..), ProviderAddress (..), digestText, mkContextId, mkName, nameText, resourceIdText, scopeIdText)
import Nagare.Target (ActiveTarget, contextNameText)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (stderr)
import System.Process (proc, readCreateProcessWithExitCode)

-- | @platform versions [--json] [--contract 1]@, or @platform versions refresh@.
runPlatformVersionsCommand :: Maybe String -> Bool -> Bool -> Maybe Int -> IO ()
runPlatformVersionsCommand mctx refreshing asJson contract
  | refreshing = runPlatformVersionsRefresh mctx
  | otherwise = withReadContract contract (runPlatformVersions mctx asJson)

-- | Print the stored snapshot. There is no serving build: this binary is
-- not the one serving the context.
runPlatformVersions :: Maybe String -> Bool -> IO ()
runPlatformVersions mctx asJson = do
  active <- activeTarget mctx
  binding <- bindingOf active
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieCoded . storeRefusal) pure
  stored <- readVersionSnapshot store binding
  let rendered = platformVersionsDocument (contextNameText (active ^. #contextName)) (active ^. #profile . #project) Nothing stored
  contract <- contractSinkSet
  case (contract, asJson) of
    (True, _) -> emitDocument rendered
    (_, True) -> LBC.putStrLn (Aeson.encode rendered)
    _ -> TIO.putStr (renderVersions rendered)

-- | Collect and publish a snapshot within 60 seconds.
runPlatformVersionsRefresh :: Maybe String -> IO ()
runPlatformVersionsRefresh mctx = do
  active <- activeTarget mctx
  outcome <- refresh active 60000000
  either dieT (TIO.putStrLn . ("versions: " <>)) outcome

-- | The best-effort refresh after a converged apply of the review in
-- @reviewDirectory@, when it changed a @platform:@ or @database:@ scope: 20
-- seconds, one line on stderr, and never a change to the apply's outcome or
-- exit code. A failure keeps the previous snapshot.
refreshVersionsAfterReview :: Maybe String -> FilePath -> IO ()
refreshVersionsAfterReview mctx reviewDirectory = do
  outcome <- try $ do
    loaded <- loadReviewBundle reviewDirectory
    let changed =
          [ resourceIdText resource
          | bundle <- either (const []) pure loaded
          , operation <- reviewOperations (reviewBundleDocument bundle)
          , resource <- toList (plannedResources (reviewPlannedOperation operation))
          ]
    if not (any (\resource -> isPlatformScope resource || isDatabaseScope resource) changed)
      then pure "skipped (no platform or database scope changed)"
      else do
        active <- activeTarget mctx
        either (\failure -> "not refreshed (" <> failure <> "); the previous snapshot is kept") id <$> refresh active 20000000
  case outcome of
    Right line -> TIO.hPutStrLn stderr ("versions: " <> line)
    Left (failure :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException failure -> throwIO failure
      | otherwise -> TIO.hPutStrLn stderr "versions: not refreshed; the previous snapshot is kept"

refresh :: ActiveTarget -> Int -> IO (Either Text Text)
refresh active budget = do
  binding <- bindingOf active
  opened <- Inventory.openTargetStoreReadOnly active
  case opened of
    Left _ -> pure (Left "the inventory store could not be opened")
    Right store -> do
      admitted <- guardKubernetesContext active
      case admitted of
        Left _ -> pure (Left "the cluster session was not admitted")
        Right _ -> do
          pinned <- contextPins active
          collected <-
            collectVersions
              CollectSettings
                { context = contextNameText (active ^. #contextName)
                , project = active ^. #profile . #project
                , pins = Just pinned
                , budgetMicroseconds = budget
                , concurrency = 4
                }
              (nativeProviders active store binding)
          case collected of
            Left failure -> pure (Left failure)
            Right snapshot -> do
              published <- publishVersionSnapshot store snapshot
              pure $ case published of
                Left failure -> Left failure
                Right KeptNewer -> Right ("kept a newer snapshot; this collection completed at " <> snapshot ^. #completedAt)
                Right Published ->
                  let (missing, total) = unavailableFacts snapshot
                   in Right ("refreshed at " <> snapshot ^. #completedAt <> " (" <> showText missing <> " of " <> showText total <> " facts unavailable)")

bindingOf :: ActiveTarget -> IO ContextBinding
bindingOf active =
  either dieT pure (ContextBinding <$> mkContextId (contextNameText (active ^. #contextName)) <*> mkName (active ^. #profile . #project))

-- | The releases the context profile and the generated host flake pin.
contextPins :: ActiveTarget -> IO Pins
contextPins active = do
  at' <- timestamp
  hostRoot <- hostConfigDir (active ^. #contextName)
  let hostFlake = hostRoot </> "flake.nix"
  present <- doesFileExist hostFlake
  identity <- if present then Just . parseHostIdentity <$> TIO.readFile hostFlake else pure Nothing
  let hostFact field = case identity of
        Nothing -> missingFact SourceRecorded "generated host flake" at' reasonNotRecorded
        Just pin -> recordedFact "generated host flake" at' (pin ^. field)
  pure
    Pins
      { context = recordedFact "context profile" at' (active ^. #profile . #platformVersion)
      , hostVersion = hostFact #version
      , hostRevision = hostFact #revision
      }

nativeProviders :: ActiveTarget -> InventoryStore -> ContextBinding -> VersionProviders
nativeProviders active store binding =
  VersionProviders
    { loadAccepted = acceptedMembers store binding
    , currentRevision = headRevision store
    , readStamp = kubectl ["get", "configmap", "nagare-platform-version", "-n", "nagare-system", "-o", "json"]
    , readHostIdentity = kubectl ["get", "configmap", "nagare-host-identity", "-n", "kube-system", "-o", "json"]
    , readNodes = kubectl ["get", "nodes", "-o", "json"]
    , readPods = \namespaceText -> kubectl ["get", "pods", "-n", T.unpack namespaceText, "-o", "json"]
    , runEngine = \_ namespaceText pod command ->
        fmap (TE.decodeUtf8With TEE.lenientDecode)
          <$> kubectl (["exec", "--namespace", T.unpack namespaceText, "pod/" <> T.unpack pod, "--"] <> command)
    , readPodUid = \namespaceText pod ->
        fmap (T.strip . TE.decodeUtf8With TEE.lenientDecode)
          <$> kubectl ["get", "pod", T.unpack pod, "-n", T.unpack namespaceText, "-o", "jsonpath={.metadata.uid}"]
    , clock = timestamp
    }
  where
    kubectl :: [String] -> IO (Either ProviderFailure ByteString)
    kubectl arguments = do
      connection <- kubectlConnectionArguments (contextNameText (active ^. #contextName))
      case connection of
        Left _ -> pure (Left ProviderDenied)
        Right connect -> do
          (code, out, err) <- readCreateProcessWithExitCode (proc "kubectl" (connect <> ["--request-timeout=5s"] <> arguments)) ""
          pure $ case code of
            ExitSuccess -> Right (BC.pack out)
            ExitFailure _ -> Left (classify (T.pack err))
    classify err
      | any (`T.isInfixOf` err) ["Forbidden", "forbidden", "Unauthorized"] = ProviderDenied
      | any (`T.isInfixOf` err) ["NotFound", "not found"] = ProviderMissing
      | otherwise = ProviderUnreadable

-- | The accepted head's revision and its platform and database workloads
-- with their native bytes.
acceptedMembers :: InventoryStore -> ContextBinding -> IO (Either Text (Text, [AcceptedMember]))
acceptedMembers store _ = do
  revision <- headRevision store
  case revision of
    Left failure -> pure (Left failure)
    Right revisionText -> do
      history <- loadInventoryHistory store
      case history of
        Left _ -> pure (Left "the accepted inventory could not be loaded")
        Right loaded -> do
          let managed =
                [ resource
                | (scope, (_, declaration)) <- Map.toAscList (historyAccepted loaded)
                , let scopeText = scopeIdText scope
                , isPlatformScope scopeText || isDatabaseScope scopeText
                , bundle <- scopeBundles declaration
                , Managed resource <- bundle ^. #declarations
                ]
          native <- loadObservationNative store managed
          pure $ case native of
            Left _ -> Left "the accepted native objects could not be read"
            Right objects ->
              Right
                ( revisionText
                , [ KubernetesMember (scopeOf resource) (resourceIdText (resource ^. #identity)) bytes
                  | (resource, bytes) <- Map.elems (observationKubernetes objects)
                  ]
                    <> [ HelmMember (scopeOf resource) (resourceIdText (resource ^. #identity)) (nameText namespaceName) (nameText release) bytes
                       | (resource, bytes) <- Map.elems (observationHelm objects)
                       , Helm _ namespaceName release <- [resource ^. #address]
                       ]
                )
  where
    scopeOf :: ManagedResource -> Text
    scopeOf resource = scopeIdText (resource ^. #owner)

headRevision :: InventoryStore -> IO (Either Text Text)
headRevision store = do
  loaded <- readObject store "head.json"
  pure $ case loaded of
    Right (Just bytes) -> Right (digestText (contentDigest bytes))
    Right Nothing -> Left "the inventory store is not initialized"
    Left _ -> Left "the inventory head is unreadable"

timestamp :: IO Text
timestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> getCurrentTime

showText :: Int -> Text
showText = T.pack . show

-- | A plain-text summary: the snapshot, the installed release, hosts,
-- components and database servers, with a reason for every missing value.
renderVersions :: PlatformVersions -> Text
renderVersions document' =
  T.unlines $
    [ "context: " <> document' ^. #context <> " (" <> document' ^. #project <> ")"
    , "snapshot: " <> snapshotLine (document' ^. #snapshot)
    ]
      <> maybe [] installedLines (unNullable (document' ^. #nagare . #installed))
      <> ["host " <> host ^. #node <> ": " <> fact (host ^. #osImage) <> ", kernel " <> fact (host ^. #kernel) <> ", " <> fact (host ^. #kubernetes) <> ", nixpkgs " <> fact (host ^. #nixos . #nixpkgsRevision) | host <- document' ^. #hosts]
      <> gap "hosts" (document' ^. #hostsReason)
      <> [ "component " <> component ^. #scope <> " " <> component ^. #kind <> " " <> component ^. #namespace <> "/" <> component ^. #name <> ": declared " <> fact (component ^. #declaredVersion) <> chart component <> ", running " <> digests component
         | component <- document' ^. #components
         ]
      <> gap "components" (document' ^. #componentsReason)
      <> [ "database " <> database ^. #namespace <> "/" <> database ^. #server <> " (" <> database ^. #engine <> "): declared " <> fact (database ^. #declaredVersion) <> ", reported " <> reported database
         | database <- document' ^. #databases
         ]
      <> gap "databases" (document' ^. #databasesReason)
  where
    unNullable (Nullable value) = value
    fact value = maybe ("(" <> fromMaybe "unknown" (unNullable (value ^. #reason)) <> ")") id (unNullable (value ^. #value))
    snapshotLine snapshotInfo
      | snapshotInfo ^. #available = "collected " <> fromMaybe "?" (unNullable (snapshotInfo ^. #completedAt))
      | otherwise = "unavailable (" <> fromMaybe "unknown" (unNullable (snapshotInfo ^. #reason)) <> ")"
    installedLines release =
      [ "installed: " <> fact (release ^. #version) <> " revision " <> fact (release ^. #revision) <> " payload " <> fact (release ^. #payloadId) <> " at " <> fact (release ^. #installedAt)
      ]
    gap label = maybe [] (\why -> [label <> ": unavailable (" <> why <> ")"]) . unNullable
    chart component = case unNullable (component ^. #declaredChartVersion . #value) of
      Just chartVersion -> ", chart " <> chartVersion
      Nothing -> ""
    digests component = case [fact (container ^. #imageDigest) | workload <- component ^. #workloads, container <- workload ^. #containers] of
      [] -> maybe "no pods" (\why -> "(" <> why <> ")") (unNullable (component ^. #workloadsReason))
      found -> T.intercalate ", " found
    reported database = case [fact (instance' ^. #reportedVersion) | instance' <- database ^. #instances] of
      [] -> maybe "no running instance" (\why -> "(" <> why <> ")") (unNullable (database ^. #instancesReason))
      found -> T.intercalate "; " found
