-- | Commands / Platform. Executable-private CLI boundary.
module Nagare.Cli.Commands.Platform
  ( runPlatformAdopt
  , runPlatformGuard
  , runPlatformRepin
  , runPlatformRoot
  , runPlatformStamp
  , runPlatformStatus
  , runVersion
  )
where

import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Options (VersionOpts (..))
import Nagare.Cli.Platform.KubernetesReview (applyClusterMarker)
import Nagare.Cli.Runtime.Error
  ( dieT
  , printPreflightWarnings
  , renderVersionError
  )
import Nagare.Cli.Runtime.Guards (guardLegacyMutationInventory)
import Nagare.Cli.Runtime.PlatformStatus (gatherPlatformStatus)
import Nagare.Cli.Runtime.ProjectGuard
  ( observeAdcForProject
  , projectGuardInputsFor
  )
import Nagare.Cli.Runtime.Pulumi (ensurePulumiForContext)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Prelude
import Nagare.Gcp.Adc (validateAdc)
import Nagare.Host.Config
  ( commitStagedHostFlake
  , hostConfigDir
  , stageHostFlake
  )
import Nagare.Ops.ContextGuard
  ( projectGuardVerdict
  , renderProjectGuard
  )
import Nagare.Platform.Paths (platformRootSourceToken)
import Nagare.Platform.Status
  ( guardPlatformMutation
  , platformStatusValue
  , renderPlatformStatus
  , validatePlatformAdoption
  , validatePlatformRepin
  )
import Nagare.Platform.Workspace
  ( readPayloadManifest
  , renderWorkspaceError
  )
import Nagare.Target
  ( Mode (Local)
  , contextNameText
  , writeContextPlatformVersion
  )
import Nagare.Version
  ( BuildVersion (BuildVersion)
  , compatibilityToken
  , currentBuildVersion
  , parsePlatformVersion
  , renderBuildVersionJson
  , renderBuildVersionJsonWithTools
  , renderBuildVersionText
  , renderPlatformVersion
  )
import System.Directory (doesFileExist, findExecutable)
import System.FilePath ((</>))
import System.IO (stderr)
import System.IO.Temp (withSystemTempDirectory)

runVersion :: VersionOpts -> IO ()
runVersion options = do
  resolvedTools <-
    if options ^. #tools
      then traverse resolveTool ["pulumi", "pulumi-language-nodejs", "socat", "attic", "skopeo", "gcloud", "npm"]
      else pure []
  if options ^. #json
    then
      BC.putStrLn
        ( if options ^. #tools
            then renderBuildVersionJsonWithTools currentBuildVersion resolvedTools
            else renderBuildVersionJson currentBuildVersion
        )
    else do
      TIO.putStrLn (renderBuildVersionText currentBuildVersion)
      forM_ resolvedTools $ \(name, path) ->
        TIO.putStrLn (name <> ": " <> maybe "not found" T.pack path)
  where
    resolveTool name = do
      path <- findExecutable name
      pure (T.pack name, path)

runPlatformRoot :: Maybe String -> Bool -> IO ()
runPlatformRoot mctx asJson = do
  active <- activeTarget mctx
  (paths, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  if asJson
    then
      LBC.putStrLn $
        Aeson.encode $
          Aeson.object
            [ "source" Aeson..= platformRootSourceToken (paths ^. #rootSource)
            , "payloadRoot" Aeson..= (paths ^. #root)
            , "workspaceRoot" Aeson..= (workspace ^. #root)
            , "payloadId" Aeson..= (workspace ^. #payloadId)
            , "platformVersion" Aeson..= (workspace ^. #platformVersion)
            , "revision" Aeson..= (workspace ^. #sourceRevision)
            , "digest" Aeson..= (workspace ^. #digest)
            ]
    else do
      TIO.putStrLn ("source: " <> platformRootSourceToken (paths ^. #rootSource))
      putStrLn ("payload root: " <> paths ^. #root)
      putStrLn ("workspace root: " <> workspace ^. #root)

runPlatformStatus :: Maybe String -> Bool -> IO ()
runPlatformStatus mctx asJson = do
  (active, status) <- gatherPlatformStatus mctx
  if asJson
    then LBC.putStrLn (Aeson.encode (platformStatusValue status))
    else TIO.putStr (renderPlatformStatus (contextNameText (active ^. #contextName)) status)

runPlatformGuard :: Maybe String -> IO ()
runPlatformGuard mctx = do
  (_, status) <- gatherPlatformStatus mctx
  case guardPlatformMutation status of
    Left err -> dieT err
    Right () -> TIO.putStrLn ("platform mutation allowed (" <> compatibilityToken (status ^. #compatibility) <> ")")

runPlatformStamp :: Maybe String -> IO ()
runPlatformStamp _ =
  dieT "platform stamp is retired; use platform bootstrap plan --out DIRECTORY, then platform bootstrap apply DIRECTORY --yes"

runPlatformAdopt :: Maybe String -> String -> Bool -> Bool -> IO ()
runPlatformAdopt mctx rawVersion yes asJson = do
  target <- either (dieT . ("invalid --version: " <>) . renderVersionError) (pure . renderPlatformVersion) (parsePlatformVersion (T.pack rawVersion))
  selected <- activeTarget mctx
  guardLegacyMutationInventory "platform adopt" selected
  (active, status) <- gatherPlatformStatus mctx
  if asJson
    then LBC.hPutStrLn stderr (Aeson.encode (Aeson.object ["context" Aeson..= contextNameText (active ^. #contextName), "requestedVersion" Aeson..= target, "observations" Aeson..= platformStatusValue status]))
    else TIO.putStr (renderPlatformStatus (contextNameText (active ^. #contextName)) status)
  either dieT pure (validatePlatformAdoption target status)
  unless yes (dieT "refusing to adopt a legacy context without --yes after reviewing the observations above")
  (paths, _) <- resolvePlatformWorkspace (active ^. #contextName)
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  applyClusterMarker manifest >>= either dieT (const (pure ()))
  writeContextPlatformVersion (active ^. #contextName) target >>= either dieT pure
  if asJson
    then
      LBC.putStrLn
        ( Aeson.encode
            ( Aeson.object
                [ "adopted" Aeson..= True
                , "context" Aeson..= contextNameText (active ^. #contextName)
                , "platformVersion" Aeson..= target
                , "observations" Aeson..= platformStatusValue status
                , "inventoryResourcesAdopted" Aeson..= False
                , "inventoryNextStep" Aeson..= ("compile the complete inventory, then review each legacy object with inventory adopt" :: Text)
                ]
            )
        )
    else do
      TIO.putStrLn ("adopted Nagare platform " <> target <> " for context '" <> contextNameText (active ^. #contextName) <> "'")
      TIO.putStrLn "This pins the platform release; it does not adopt managed inventory resources. Compile the complete inventory and review legacy objects with inventory adopt."

runPlatformRepin :: Maybe String -> String -> Bool -> IO ()
runPlatformRepin mctx rawVersion yes = do
  target <- either (dieT . ("invalid --version: " <>) . renderVersionError) (pure . renderPlatformVersion) (parsePlatformVersion (T.pack rawVersion))
  selected <- activeTarget mctx
  guardLegacyMutationInventory "platform repin" selected
  (active, status) <- gatherPlatformStatus mctx
  let contextName = active ^. #contextName
      profile = active ^. #profile
      contextText = contextNameText contextName
      previousVersion = status ^. #context . #version
  when (profile ^. #mode == Local) $
    dieT "platform re-pin is available only for cloud contexts"
  TIO.putStr (renderPlatformStatus contextText status)
  either dieT pure (guardPlatformMutation status)
  either dieT pure (validatePlatformRepin target status)
  (gcloudAccount, adc) <- observeAdcForProject
  warnings <- either dieT pure (validateAdc (profile ^. #project) gcloudAccount adc)
  printPreflightWarnings warnings
  workspace <- ensurePulumiForContext contextName profile
  projectInputs <- projectGuardInputsFor contextName profile workspace
  either dieT pure (projectGuardVerdict projectInputs)
  TIO.putStrLn (renderProjectGuard projectInputs)
  unless yes (dieT "refusing to re-pin an undeployed context without --yes after reviewing the observations above")
  hostRoot <- hostConfigDir contextName
  let hostAlreadyMatches = status ^. #host . #version == Just target
      contextAlreadyMatches = previousVersion == Just target
  hostExists <- doesFileExist (hostRoot </> "flake.nix")
  if contextAlreadyMatches && (not hostExists || hostAlreadyMatches)
    then TIO.putStrLn ("context '" <> contextText <> "' is already pinned to Nagare platform " <> target)
    else do
      (paths, _) <- resolvePlatformWorkspace contextName
      manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
      stagedHost <-
        if hostExists
          then withSystemTempDirectory "nagare-platform-repin" $ \temporary -> do
            staged <- stageHostFlake hostRoot temporary (paths ^. #nixosDir) (BuildVersion target (manifest ^. #sourceRevision)) >>= either dieT pure
            -- Commit the context first; if the already-validated host commit fails,
            -- restore the old context pin before returning the error.
            writeContextPlatformVersion contextName target >>= either dieT pure
            committed <- commitStagedHostFlake staged hostRoot
            case committed of
              Right () -> pure True
              Left err -> do
                forM_ previousVersion $ \oldVersion -> void (writeContextPlatformVersion contextName oldVersion)
                dieT err
          else do
            writeContextPlatformVersion contextName target >>= either dieT pure
            pure False
      (_, finalStatus) <- gatherPlatformStatus mctx
      unless (finalStatus ^. #context . #version == finalStatus ^. #payload . #version) $
        dieT "re-pin wrote inconsistent context and payload release identities"
      TIO.putStr (renderPlatformStatus contextText finalStatus)
      TIO.putStrLn
        ( "re-pinned context '"
            <> contextText
            <> "' to Nagare platform "
            <> target
            <> if stagedHost then " and updated its generated host flake" else ""
        )
