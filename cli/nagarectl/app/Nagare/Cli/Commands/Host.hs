-- | Commands / Host. Executable-private CLI boundary.
module Nagare.Cli.Commands.Host
  ( runCluster
  , runHost
  , runKubeconfig
  )
where

import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Bootstrap.Foundation (foundationStageTarget)
import Nagare.Cli.Bootstrap.Host
  ( buildHostStageCandidate
  , buildHostTransitionCandidate
  , buildKubeconfigStageCandidateWithRecovery
  )
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistry)
import Nagare.Cli.Inventory.Workflow (runInventoryApply)
import Nagare.Cli.Options
  ( ClusterCommand (..)
  , HostCommand (..)
  , KubeconfigCommand (..)
  )
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Guards (guardLegacyMutationInventory)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Cluster.Kubeconfig
  ( KubeconfigIdentity (KubeconfigIdentity)
  , defaultFetchOps
  , fetchKubeconfig
  , kubeconfigPath
  )
import Nagare.Dsl.Prelude
import Nagare.Host.AgeKey (placeAgeKeyWith)
import Nagare.Host.Config
  ( HostConfig
      ( HostConfig
      , ageKeyFile
      , authorizedKeys
      , context
      , deployUser
      , instanceName
      , nagareNixosSource
      , name
      , registryHost
      )
  , HostInstallResult (HostInstalled, HostReplaced, HostUnchanged)
  , defaultHostName
  , findHostNameCollision
  , hostConfigDir
  , installHostFlake
  , readAuthorizedKeys
  , readContextHostName
  , renderHostFlake
  , renderHostModule
  , renderHostSummary
  )
import Nagare.Inventory.Adapter qualified as Adapter
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Plan qualified as Plan
import Nagare.Ops.ClusterGuard
  ( clusterGuardObservationsValue
  , clusterGuardVerdict
  , defaultClusterGuardOps
  , observeClusterGuard
  , renderClusterGuard
  )
import Nagare.Ops.Probe (ProbeStatus (StatusOk), renderInventory)
import Nagare.Ops.Status (probeCertificatePolicy)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (Mode (Local), contextNameText)
import Nagare.Version (BuildVersion (BuildVersion))
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , makeAbsolute
  )
import System.Environment (getEnvironment, lookupEnv, setEnv, unsetEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (stderr)
import System.Process
  ( CreateProcess (env)
  , proc
  , readCreateProcessWithExitCode
  )

runHost :: Maybe String -> HostCommand -> IO ()
runHost globalContext = \case
  HostApply directory yes -> do
    bundle <- Plan.loadReviewBundle directory >>= either dieT pure
    owner <- either dieT pure (Resource.mkScopeId Resource.Platform "host")
    let document = Plan.reviewBundleDocument bundle
        otherScopesUnchanged = Map.delete owner (Plan.reviewBaseRevisions document) == Map.delete owner (Plan.reviewDesiredRevisions document)
    unless
      ( otherScopesUnchanged
          && all ((== ResourceInventory.HostExecutor) . Adapter.plannedExecutor . Plan.reviewPlannedOperation) (Plan.reviewOperations document)
          && Map.null (Plan.reviewRetentions document)
          && Map.null (Plan.reviewCollections document)
          && Map.null (Plan.reviewMigrations document)
      )
      $ dieT "host apply requires a host-only review without retirement, collection, or migration"
    runInventoryApply globalContext directory yes
  HostPlan output keyFile replace -> runHostReview globalContext output keyFile replace
  HostPlaceAgeKey options -> case options ^. #savePlan of
    Just output -> runHostReview (options ^. #context <|> globalContext) output (Just (options ^. #keyFile)) (options ^. #force)
    Nothing -> do
      active <- activeTarget (options ^. #context <|> globalContext)
      guardLegacyMutationInventory "host place-age-key" active
      let context = active ^. #contextName
          profile = active ^. #profile
      when (profile ^. #mode == Local) $
        dieT "host age-key placement uses GCP IAP and is unavailable for local contexts"
      (_, workspace) <- resolvePlatformWorkspace context
      parentEnv <- getEnvironment
      let iapHelper = workspace ^. #scriptsDir </> "iap-ssh.sh"
          transport childEnv arguments =
            readCreateProcessWithExitCode ((proc iapHelper arguments) {env = Just childEnv}) ""
      placeAgeKeyWith transport parentEnv (contextNameText context) profile (options ^. #keyFile) (options ^. #force)
        >>= either dieT pure
      TIO.putStrLn
        ( "Host age key for context '"
            <> contextNameText context
            <> "' is ready on instance '"
            <> profile ^. #instanceName
            <> "'."
        )
  HostPath commandContext -> do
    active <- activeTarget (commandContext <|> globalContext)
    root <- hostConfigDir (active ^. #contextName)
    exists <- doesDirectoryExist root
    unless exists $ dieT ("host configuration does not exist for context '" <> contextNameText (active ^. #contextName) <> "'; run nagarectl host init first")
    putStrLn root
  HostName commandContext asJson -> do
    active <- activeTarget (commandContext <|> globalContext)
    let context = active ^. #contextName
    hostName <- readContextHostName context >>= either dieT pure
    if asJson
      then LBC.putStrLn (Aeson.encode (Aeson.object ["context" Aeson..= contextNameText context, "hostName" Aeson..= hostName]))
      else TIO.putStrLn hostName
  HostShow commandContext -> do
    active <- activeTarget (commandContext <|> globalContext)
    root <- hostConfigDir (active ^. #contextName)
    let modulePath = root </> "host.nix"
    exists <- doesFileExist modulePath
    unless exists $ dieT ("host configuration does not exist for context '" <> contextNameText (active ^. #contextName) <> "'; run nagarectl host init first")
    TIO.readFile modulePath >>= TIO.putStr
  HostInit options -> do
    active <- activeTarget (options ^. #context <|> globalContext)
    resolvedHostName <-
      case options ^. #hostName of
        Just explicitHostName -> pure (T.pack explicitHostName)
        Nothing -> do
          implicitHostName <- defaultHostName (active ^. #contextName) & either dieT pure
          collision <- findHostNameCollision (active ^. #contextName) implicitHostName >>= either dieT pure
          case collision of
            Nothing -> pure implicitHostName
            Just (owningContext, modulePath) ->
              dieT
                ( "default host name '"
                    <> implicitHostName
                    <> "' is already used by context '"
                    <> contextNameText owningContext
                    <> "' at "
                    <> T.pack modulePath
                    <> "; choose a distinct --host-name"
                )
    keys <- readAuthorizedKeys (options ^. #sshPublicKeyFiles) >>= either dieT pure
    (paths, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
    nixosSource <- makeAbsolute (paths ^. #nixosDir)
    let payloadBuild = BuildVersion (workspace ^. #platformVersion) (workspace ^. #sourceRevision)
    let profile = active ^. #profile
        defaultInstance = profile ^. #instanceName
        config =
          HostConfig
            { context = active ^. #contextName
            , name = resolvedHostName
            , instanceName = T.pack (fromMaybe (T.unpack defaultInstance) (options ^. #instanceName))
            , registryHost = T.pack (fromMaybe (T.unpack (profile ^. #registryHost)) (options ^. #registryHost))
            , deployUser = T.pack (options ^. #deployUser)
            , authorizedKeys = keys
            , ageKeyFile = options ^. #ageKeyFile
            , nagareNixosSource = nixosSource
            }
    root <- hostConfigDir (active ^. #contextName)
    if options ^. #dryRun
      then do
        TIO.putStrLn "DRY RUN — generated host configuration:"
        TIO.putStr (renderHostSummary root config)
        TIO.putStrLn "--- flake.nix ---"
        TIO.putStr (renderHostFlake config payloadBuild)
        TIO.putStrLn "--- host.nix ---"
        TIO.putStr (renderHostModule config)
      else do
        result <- installHostFlake (options ^. #force) config payloadBuild (options ^. #sopsFile) >>= either dieT pure
        let verb = case result of
              HostInstalled -> "Installed"
              HostReplaced -> "Replaced"
              HostUnchanged -> "Unchanged"
        TIO.putStrLn (verb <> " host configuration for context '" <> contextNameText (active ^. #contextName) <> "' at " <> T.pack root)

runKubeconfig :: Maybe String -> KubeconfigCommand -> IO ()
runKubeconfig globalContext = \case
  KubeconfigRecover -> do
    active <- activeTarget globalContext
    selected <- foundationStageTarget active
    snapshot <- Inventory.loadTargetSnapshotReadOnly selected
    (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
    host <- buildHostStageCandidate active workspace snapshot
    when (isJust host) (dieT "kubeconfig recovery requires an accepted host configuration")
    recovered <- buildKubeconfigStageCandidateWithRecovery True active workspace snapshot
    when (isJust recovered) (dieT "kubeconfig recovery requires an accepted credential scope")
    TIO.putStrLn "Materialized the accepted kubeconfig in the selected context root"
  KubeconfigFetch options -> do
    active <- activeTarget (options ^. #context <|> globalContext)
    let profile = active ^. #profile
        context = active ^. #contextName
    when (profile ^. #mode == Local) $
      dieT "kubeconfig fetch uses the GCP IAP transport and is unavailable for local contexts"
    hostName <- readContextHostName context >>= either dieT pure
    (_, workspace) <- resolvePlatformWorkspace context
    destination <- maybe (kubeconfigPath context) pure (options ^. #output)
    let identity = KubeconfigIdentity (contextNameText context) hostName
        fetchOps = defaultFetchOps (workspace ^. #scriptsDir </> "iap-ssh.sh")
    fetchKubeconfig fetchOps identity profile destination >>= either dieT pure
    TIO.putStrLn
      ( "Wrote kubeconfig for context '"
          <> contextNameText context
          <> "' to "
          <> T.pack destination
          <> " (server https://"
          <> hostName
          <> ":6443)"
      )

runCluster :: Maybe String -> ClusterCommand -> IO ()
runCluster globalContext = \case
  ClusterGuard options -> do
    active <- activeTarget (options ^. #context <|> globalContext)
    let profile = active ^. #profile
        context = active ^. #contextName
        contextText = contextNameText context
    when (profile ^. #mode == Local) $
      dieT "cluster guard is a cloud-cluster identity check and is unavailable for local contexts"
    expectedNode <- readContextHostName context >>= either dieT pure
    observed <- observeClusterGuard defaultClusterGuardOps contextText expectedNode
    case observed of
      Left err ->
        if options ^. #json
          then do
            LBC.hPutStrLn stderr (Aeson.encode (Aeson.object ["guarded" Aeson..= False, "refusal" Aeson..= err]))
            exitFailure
          else dieT err
      Right inputs -> do
        let evidence = clusterGuardObservationsValue inputs
        case clusterGuardVerdict inputs of
          Left err ->
            if options ^. #json
              then do
                LBC.hPutStrLn stderr (Aeson.encode (Aeson.object ["guarded" Aeson..= False, "refusal" Aeson..= err, "observations" Aeson..= evidence]))
                exitFailure
              else dieT err
          Right () ->
            if options ^. #json
              then LBC.putStrLn (Aeson.encode (Aeson.object ["guarded" Aeson..= True, "observations" Aeson..= evidence]))
              else TIO.putStrLn (renderClusterGuard inputs)
  ClusterCertificatePolicy -> do
    probe <- probeCertificatePolicy
    TIO.putStr (renderInventory [probe])
    case probe ^. #status of
      StatusOk -> pure ()
      _ -> exitFailure

-- | Save authority first; generic inventory apply/resume owns all effects.
runHostReview :: Maybe String -> FilePath -> Maybe FilePath -> Bool -> IO ()
runHostReview selected output keyFile replace = do
  active <- activeTarget selected
  when (active ^. #profile . #mode == Local) $
    dieT "reviewed NixOS host transitions require a cloud context"
  inheritedKey <- lookupEnv "NAGARE_HOST_AGE_KEY_FILE"
  let selectedKey = keyFile <|> inheritedKey
  when (replace && isNothing selectedKey) $
    dieT "replacing an age key requires an explicit local key file"
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  let additions =
        [("NAGARE_HOST_REPLACE_AGE_KEY", if replace then "1" else "0"), ("NAGARE_HOST_REVIEW_CREDENTIAL", if isJust selectedKey then "1" else "0")]
          <> maybe [] (\path -> [("NAGARE_HOST_AGE_KEY_FILE", path)]) selectedKey
      restore previous = for_ previous $ \(key, value) -> maybe (unsetEnv key) (setEnv key) value
  bracket (mapM (\(key, _) -> (\value -> (key, value)) <$> lookupEnv key) additions) restore $ \_ -> do
    for_ additions (uncurry setEnv)
    candidate <-
      buildHostTransitionCandidate active workspace snapshot
        >>= maybe (dieT "selected context has no NixOS host transition") pure
    Inventory.planInventoryCandidateWith (inventoryPlanRegistry active workspace) active candidate output
  TIO.putStrLn "Host review saved; use inventory apply with this directory. Credential reviews require the same NAGARE_HOST_AGE_KEY_FILE at apply/resume."
