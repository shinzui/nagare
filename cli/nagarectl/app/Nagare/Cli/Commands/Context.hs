-- | Commands / Context. Executable-private CLI boundary.
module Nagare.Cli.Commands.Context
  ( runContext
  )
where

import Control.Monad (forM, forM_)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Bootstrap.Foundation (cloudFoundationPending)
import Nagare.Cli.Options (ContextCommand (..))
import Nagare.Cli.Runtime.Context
  ( contextEnvPairs
  , formatContextList
  , guardExistingContextMutation
  , parseContextNameOrDie
  , writeContextProfile
  )
import Nagare.Cli.Runtime.ContextReview (guardRemovedContext, runContextReview, saveContextReview)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ProjectGuard (runContextGuard)
import Nagare.Cli.Runtime.Pulumi
  ( ensurePulumiForContext
  , selectReviewedPulumiForContext
  )
import Nagare.Cli.Runtime.Target
  ( activeProfile
  , activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Prelude
import Nagare.Init (renderTargetEnv)
import Nagare.Target
  ( ActiveTarget (ActiveTarget)
  , Mode (Cloud, Local)
  , clearCurrentContext
  , contextExists
  , contextFilePath
  , contextNameText
  , deleteContext
  , listContexts
  , mergeContextOverrides
  , nagareStateDir
  , parseAcmeDirectory
  , profileFromContextMap
  , pulumiEnvFor
  , readContextMap
  , readContextProfile
  , readCurrentContext
  , renderContextShellEnv
  , setCurrentContext
  , validateAcmeEmail
  , validateNixCacheMode
  , validateVmShape
  , vmShapeOf
  )

runContext :: Maybe String -> ContextCommand -> IO ()
runContext mctx = \case
  ContextList -> do
    names <- listContexts
    cur <- readCurrentContext
    rows <- forM names $ \name -> do
      e <- readContextProfile name
      pure $ case e of
        Right tp -> (name, tp ^. #project, tp ^. #baseDomain)
        Left _ -> (name, "(unreadable)", "")
    TIO.putStr (formatContextList cur rows)
  ContextCurrent ->
    readCurrentContext >>= maybe (dieT "no current context set") (TIO.putStrLn . contextNameText)
  ContextUse rawName -> do
    name <- parseContextNameOrDie rawName
    ok <- contextExists name
    if ok
      then do
        setCurrentContext name
        tp <- either dieT pure =<< readContextProfile name
        case tp ^. #mode of
          Local -> void (resolvePlatformWorkspace name)
          Cloud -> do
            pending <- cloudFoundationPending (ActiveTarget name tp)
            if pending
              then TIO.putStrLn "Cloud foundation awaits a reviewed platform bootstrap plan."
              else do
                void (selectReviewedPulumiForContext name tp)
        TIO.putStrLn ("Switched to context '" <> contextNameText name <> "'")
      else dieT ("no such context: " <> contextNameText name)
  ContextShow mname -> do
    tp <- case mname of
      Just rawName -> do
        name <- parseContextNameOrDie rawName
        either dieT pure =<< readContextProfile name
      Nothing -> activeProfile mctx
    TIO.putStr (renderTargetEnv tp)
  ContextCreate rawName o -> do
    name <- parseContextNameOrDie rawName
    guardRemovedContext name
    exists <- contextExists name
    when (isJust (o ^. #savePlan) && (not exists || o ^. #use)) (dieT "a profile review requires an existing context and cannot change the current selection")
    when (exists && not (o ^. #force)) $
      dieT ("context '" <> contextNameText name <> "' already exists; pass --force to change the given fields")
    when (exists && isNothing (o ^. #savePlan)) (guardExistingContextMutation "context create --force" name)
    -- EP-112: validate the ACME identity BEFORE a context file exists, so a typo
    -- is reported here rather than at `nagare cluster-bootstrap`. The contact is
    -- OPTIONAL here (unlike `init`): this is the low-level writer that also
    -- creates local contexts, where no ACME account is ever registered. The
    -- renderer's refusal is the backstop for a context written without one.
    mapM_ (either dieT (const (pure ())) . validateAcmeEmail . T.pack) (o ^. #acmeEmail)
    mapM_ (either dieT (const (pure ())) . parseAcmeDirectory . T.pack) (o ^. #acmeDirectory)
    (_, workspace) <- resolvePlatformWorkspace name
    path <- contextFilePath name
    -- EP-121: --force merges onto the stored context rather than resetting every
    -- omitted field to its default.
    stored <- if exists then readContextMap path else pure Nothing
    let contextMap = mergeContextOverrides stored (contextEnvPairs o) (workspace ^. #platformVersion)
        tp = profileFromContextMap contextMap
    void (either dieT pure (validateVmShape (vmShapeOf tp)))
    either dieT pure (validateNixCacheMode tp)
    when
      (tp ^. #mode == Local && tp ^. #externalDomainTlsEnabled)
      (dieT "external domain TLS belongs to cloud contexts")
    case o ^. #savePlan of
      Just output -> saveContextReview name (Just (renderTargetEnv tp)) output
      Nothing -> writeContextProfile name tp
    when (isNothing (o ^. #savePlan)) $
      TIO.putStrLn ("Wrote context '" <> contextNameText name <> "' (" <> T.pack path <> ")")
    forM_ stored $ \previous -> do
      let before = T.lines (renderTargetEnv (profileFromContextMap previous))
          changed = filter (`notElem` before) (T.lines (renderTargetEnv tp))
      if null changed
        then TIO.putStrLn "No fields changed."
        else TIO.putStr (T.unlines ("Changed:" : map ("  " <>) changed))
    when (o ^. #use) $ do
      setCurrentContext name
      when (tp ^. #mode == Cloud) $ do
        TIO.putStrLn "Cloud foundation awaits a reviewed platform bootstrap plan."
      TIO.putStrLn ("Set current context to '" <> contextNameText name <> "'")
  ContextGuard asJson -> runContextGuard mctx asJson
  ContextEnv -> runContextEnv mctx
  ContextApply input yes -> runContextReview False input yes
  ContextRestore input yes -> runContextReview True input yes
  ContextDelete rawName yes savePlan -> do
    name <- parseContextNameOrDie rawName
    ok <- contextExists name
    if not ok
      then dieT ("no such context: " <> contextNameText name)
      else case savePlan of
        Just output -> saveContextReview name Nothing output
        Nothing ->
          if not yes
            then dieT ("refusing to delete '" <> contextNameText name <> "' without --yes")
            else do
              guardExistingContextMutation "context delete" name
              deleteContext name
              cur <- readCurrentContext
              when (cur == Just name) clearCurrentContext
              TIO.putStrLn ("Deleted context '" <> contextNameText name <> "'")

-- | @nagarectl context env@ (EP-113). Print the active context's shell environment
-- as @export K=V@ lines and nothing else, so the packaged @nagare@ launcher can
-- @eval@ it. A clone-free install has no @.envrc@, so without this every
-- Pulumi-invoking recipe inherits whatever Pulumi state the invoking shell happens
-- to carry — which, for an installed operator, is none.
--
-- Ensuring the per-context Pulumi home and state directory exist is done here, not
-- in the launcher, so the launcher stays a two-line shim.
runContextEnv :: Maybe String -> IO ()
runContextEnv mctx = do
  active <- activeTarget mctx
  let name = active ^. #contextName
      tp = active ^. #profile
  _ <- ensurePulumiForContext name tp
  stateRoot <- nagareStateDir
  TIO.putStr (renderContextShellEnv name tp (pulumiEnvFor stateRoot (contextNameText name) tp))
