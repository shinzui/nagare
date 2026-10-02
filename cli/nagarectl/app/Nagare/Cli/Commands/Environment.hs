-- | Commands / Environment. Executable-private CLI boundary.
module Nagare.Cli.Commands.Environment
  ( runEnv
  , runSecret
  )
where

import Control.Exception (bracket_)
import Control.Monad (forM, forM_)
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Cli.Application.Config (resolveAppOrDie)
import Nagare.Cli.Environment.Selection
  ( reconcileModeFrom
  , selectedScopes
  )
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Options
  ( EnvCommand (..)
  , ScopeSelection
  , SecretCommand (..)
  )
import Nagare.Cli.Runtime.Error (dieT, orDie)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (scopeToken)
import Nagare.Dsl.Types (EnvScope (..))
import Nagare.Env.Dotenv (parseDotenv)
import Nagare.Env.Store
  ( ReconcileMode (Merge, ReconcileExact)
  , readEnvStore
  , readSecretStore
  , reconcile
  , renderEnvConfigMap
  , renderEnvSecretPreview
  )
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Environment
  ( acceptedEnvChannelValues
  , acceptedSecretChannelValues
  , compileBuildEnvChannel
  , compileBuildSecretChannel
  , compilePreviewEnvChannel
  , compilePreviewSecretChannel
  , compileRuntimeEnvChannel
  , compileRuntimeSecretChannel
  , validateSecretRotation
  )
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import System.IO
  ( hFlush
  , hIsTerminalDevice
  , hSetEcho
  , stderr
  , stdin
  )

runEnv :: Maybe String -> EnvCommand -> IO ()
runEnv mctx = \case
  EnvList copts allScopes -> do
    (name, ns) <- resolveAppOrDie copts
    let scopes = if allScopes then [minBound .. maxBound] else [Runtime]
    runEnvListBody name ns scopes
  EnvSet copts sel dry key val reviewed savePlan -> do
    (name, ns) <- resolveAppOrDie copts
    if not dry || reviewed || isJust savePlan
      then
        saveReviewedEnvChange
          mctx
          name
          ns
          sel
          dry
          "env set"
          (Right . Map.insert (T.pack key) (T.pack val))
          savePlan
      else do
        forM_ (selectedScopes sel) $ \scope -> do
          existing <- orDie =<< readEnvStore name ns scope
          let desired = reconcile Merge existing (Map.singleton (T.pack key) (T.pack val))
          printEnvPreview name ns scope desired
  EnvDelete copts sel dry key reviewed savePlan -> do
    (name, ns) <- resolveAppOrDie copts
    if not dry || reviewed || isJust savePlan
      then
        saveReviewedEnvChange
          mctx
          name
          ns
          sel
          dry
          "env delete"
          ( \existing ->
              if Map.member (T.pack key) existing
                then Right (Map.delete (T.pack key) existing)
                else Left "env key is absent from the accepted channel"
          )
          savePlan
      else do
        forM_ (selectedScopes sel) $ \scope -> do
          existing <- orDie =<< readEnvStore name ns scope
          let desired = reconcile ReconcileExact mempty (Map.delete (T.pack key) existing)
          printEnvPreview name ns scope desired
  EnvSync copts sel dry exact dotenvPath reviewed savePlan -> do
    (name, ns) <- resolveAppOrDie copts
    raw <- TIO.readFile dotenvPath
    incoming <- orDie (parseDotenv raw)
    if not dry || reviewed || isJust savePlan
      then
        saveReviewedEnvChange
          mctx
          name
          ns
          sel
          dry
          (T.pack dotenvPath)
          ( \existing ->
              Right
                ( reconcile
                    (if exact then ReconcileExact else Merge)
                    existing
                    incoming
                )
          )
          savePlan
      else do
        let mode = reconcileModeFrom exact
        forM_ (selectedScopes sel) $ \scope -> do
          existing <- orDie =<< readEnvStore name ns scope
          let desired = reconcile mode existing incoming
          printEnvPreview name ns scope desired

saveReviewedEnvChange ::
  Maybe String ->
  Text ->
  Text ->
  ScopeSelection ->
  Bool ->
  Text ->
  (Map Text Text -> Either Text (Map Text Text)) ->
  Maybe FilePath ->
  IO ()
saveReviewedEnvChange mctx name ns selection dry sourceName change output = do
  unless
    (not dry && selectedScopes selection `elem` [[Runtime], [Build], [Preview]])
    (dieT "reviewed env changes require one scope and no --dry-run")
  active <- activeTarget mctx
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
  let (compile, channelName) = case selectedScopes selection of
        [Build] -> (compileBuildEnvChannel, "build-env")
        [Preview] -> (compilePreviewEnvChannel, "preview-env")
        _ -> (compileRuntimeEnvChannel, "runtime-env")
      source = Resource.SourceLocation sourceName channelName
  (initial, _) <-
    either
      (dieT . T.pack . show)
      pure
      (compile name ns cluster namespaceId Map.empty source)
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative store history inventory
      >>= either dieT pure
  existing <- either dieT pure (acceptedEnvChannelValues snapshot acceptedNative initial)
  desired <- either dieT pure (change existing)
  (channel, native) <-
    either
      (dieT . T.pack . show)
      pure
      (compile name ns cluster namespaceId desired source)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope channel NE.:| []))
  case output of
    Nothing ->
      Inventory.convergeInventoryCandidateWith
        (inventoryPlanRegistryWithNative active workspace native)
        (inventoryExecutionRegistry mctx)
        active
        candidate
    Just directory ->
      Inventory.planInventoryCandidateWith
        (inventoryPlanRegistryWithNative active workspace native)
        active
        candidate
        directory

runSecret :: Maybe String -> SecretCommand -> IO ()
runSecret mctx = \case
  SecretSet copts sel dry key rawVersion savePlan -> do
    (name, ns) <- resolveAppOrDie copts
    if dry && isNothing rawVersion && isNothing savePlan
      then do
        val <- readSecretValue
        forM_ (selectedScopes sel) $ \scope -> do
          existing <- orDie =<< readSecretStore name ns scope
          let desired = reconcile Merge existing (Map.singleton (T.pack key) val)
          printSecretPreview name ns scope desired
      else do
        when dry (dieT "reviewed Secret set cannot use --dry-run")
        version <-
          maybe
            (dieT "reviewed Secret set requires --version")
            (either dieT pure . Resource.mkName . T.pack)
            rawVersion
        val <- readSecretValue
        saveReviewedSecretChange
          mctx
          name
          ns
          sel
          "secret set"
          version
          (Right . Map.insert (T.pack key) val)
          savePlan
  SecretList copts allScopes -> do
    (name, ns) <- resolveAppOrDie copts
    let scopes = if allScopes then [minBound .. maxBound] else [Runtime]
    keys <- fmap concat $ forM scopes $ \scope -> do
      m <- orDie =<< readSecretStore name ns scope
      pure (Map.keys m)
    if null keys then TIO.putStrLn "(no secrets set)" else mapM_ TIO.putStrLn keys
  SecretDelete copts sel dry key rawVersion savePlan -> do
    (name, ns) <- resolveAppOrDie copts
    if dry && isNothing rawVersion && isNothing savePlan
      then forM_ (selectedScopes sel) $ \scope -> do
        existing <- orDie =<< readSecretStore name ns scope
        let desired = reconcile ReconcileExact mempty (Map.delete (T.pack key) existing)
        printSecretPreview name ns scope desired
      else do
        when dry (dieT "reviewed Secret delete cannot use --dry-run")
        version <-
          maybe
            (dieT "reviewed Secret delete requires --version")
            (either dieT pure . Resource.mkName . T.pack)
            rawVersion
        saveReviewedSecretChange
          mctx
          name
          ns
          sel
          "secret delete"
          version
          ( \existing ->
              if Map.member (T.pack key) existing
                then Right (Map.delete (T.pack key) existing)
                else Left "Secret key is absent from the accepted channel"
          )
          savePlan
  SecretSync copts sel dotenvPath rawVersion output -> do
    unless
      (selectedScopes sel `elem` [[Runtime], [Build], [Preview]])
      (dieT "reviewed Secret sync requires exactly one scope")
    (name, ns) <- resolveAppOrDie copts
    version <- either dieT pure (Resource.mkName (T.pack rawVersion))
    raw <- TIO.readFile dotenvPath
    incoming <- either (const (dieT "invalid secret dotenv file")) pure (parseDotenv raw)
    saveReviewedSecretChange
      mctx
      name
      ns
      sel
      (T.pack dotenvPath)
      version
      (const (Right incoming))
      output

saveReviewedSecretChange ::
  Maybe String ->
  Text ->
  Text ->
  ScopeSelection ->
  Text ->
  Resource.Name ->
  (Map Text Text -> Either Text (Map Text Text)) ->
  Maybe FilePath ->
  IO ()
saveReviewedSecretChange mctx name ns selection sourceName version change output = do
  unless
    (selectedScopes selection `elem` [[Runtime], [Build], [Preview]])
    (dieT "reviewed Secret changes require exactly one scope")
  active <- activeTarget mctx
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, namespaceId) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
  let (compile, channelName) = case selectedScopes selection of
        [Build] -> (compileBuildSecretChannel, "build-secret")
        [Preview] -> (compilePreviewSecretChannel, "preview-secret")
        _ -> (compileRuntimeSecretChannel, "runtime-secret")
      source = Resource.SourceLocation sourceName channelName
  (initial, _) <-
    either
      (dieT . T.pack . show)
      pure
      (compile name ns cluster namespaceId version Map.empty source)
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative store history inventory
      >>= either dieT pure
  existing <- either dieT pure (acceptedSecretChannelValues snapshot acceptedNative initial)
  desired <- either dieT pure (change existing)
  (channel, native) <-
    either
      (dieT . T.pack . show)
      pure
      (compile name ns cluster namespaceId version desired source)
  either dieT pure (validateSecretRotation snapshot channel)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope channel NE.:| []))
  case output of
    Nothing ->
      Inventory.convergeInventoryCandidateWith
        (inventoryPlanRegistryWithNative active workspace native)
        (inventoryExecutionRegistry mctx)
        active
        candidate
    Just directory ->
      Inventory.planInventoryCandidateWith
        (inventoryPlanRegistryWithNative active workspace native)
        active
        candidate
        directory

-- | Print read-only legacy ConfigMap rendering for an offline dry run.
printEnvPreview :: Text -> Text -> EnvScope -> Map Text Text -> IO ()
printEnvPreview name ns scope desired = do
  BC.putStrLn ("--- ConfigMap (" <> TE.encodeUtf8 (scopeToken scope) <> ") ---")
  BC.putStrLn (renderEnvConfigMap name ns scope desired)

-- | A public dry-run shows only Secret identity and key names. Reversible
-- base64 values remain private even before the channel has inventory ownership.
printSecretPreview :: Text -> Text -> EnvScope -> Map Text Text -> IO ()
printSecretPreview name ns scope desired = do
  BC.putStrLn ("--- Secret (" <> TE.encodeUtf8 (scopeToken scope) <> ") ---")
  BC.putStrLn (renderEnvSecretPreview name ns scope desired)

-- | Read each requested scope's env store and print an aligned table.
runEnvListBody :: Text -> Text -> [EnvScope] -> IO ()
runEnvListBody name ns scopes = do
  rows <- fmap concat $ forM scopes $ \scope -> do
    m <- orDie =<< readEnvStore name ns scope
    pure [(scopeToken scope, k, v) | (k, v) <- Map.toAscList m]
  if null rows
    then TIO.putStrLn "(no env set)"
    else TIO.putStr (formatEnvRows rows)

formatEnvRows :: [(Text, Text, Text)] -> Text
formatEnvRows rows = T.unlines (header : map row rows)
  where
    header = "  SCOPE    KEY                 VALUE"
    row (s, k, v) = T.concat ["  ", pad 9 s, pad 20 k, v]
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

-- | Read one secret value. If stdin is a TTY, prompt with echo off; otherwise
-- read all of stdin and strip a single trailing newline (so a piped
-- @printf '%s' v@ and an interactive line both work). The value never appears in
-- @argv@.
readSecretValue :: IO Text
readSecretValue = do
  isTty <- hIsTerminalDevice stdin
  if isTty
    then do
      TIO.hPutStr stderr "Value (input hidden): "
      hFlush stderr
      bracket_
        (hSetEcho stdin False)
        (hSetEcho stdin True >> TIO.hPutStrLn stderr "")
        TIO.getLine
    else do
      raw <- TIO.getContents
      pure (fromMaybe raw (T.stripSuffix "\n" raw))
