-- | Commands / NixCache. Executable-private CLI boundary.
--
-- EP-230: the producer path to the context's Attic cache. Every kubectl call
-- goes through the command's admitted cluster session (EP-226); a local
-- context is refused, since the cache is cloud-only.
module Nagare.Cli.Commands.NixCache
  ( runNixCache
  )
where

import Control.Concurrent (myThreadId, throwTo)
import Control.Exception (AsyncException (UserInterrupt), catch, throwIO)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Options.NixCache (NixCacheCommand (..))
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Contract.Schema (ContractVersion (..), DocumentName (..))
import Nagare.Contract.Sink (contractSinkSet, emitDocument, withContract)
import Nagare.Contract.V1 (NixCacheEndpoint (..), NixCachePushResult (..))
import Nagare.Dsl.Prelude
import Nagare.Host.Config (readContextHostName)
import Nagare.Inventory.ClusterSession (commandClusterSession, defaultSessionOps, kubectlConnectionArguments)
import Nagare.Ops.NixCacheProducer
  ( Forwarded
  , ProducerOps
  , PushTarget (..)
  , Pushed
  , TokenRequest (..)
  , cacheName
  , defaultProducerOps
  , mintToken
  , pushPaths
  , renderProducerError
  , requireCloudContext
  , withForward
  )
import Nagare.Target (contextNameText)
import System.Directory (makeAbsolute)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hFlush, stderr, stdout)
import System.Posix.Signals (Handler (CatchOnce), installHandler, sigTERM)

runNixCache :: Maybe String -> NixCacheCommand -> IO ()
runNixCache globalContext command = do
  -- SIGTERM interrupts like SIGINT, so the forward and the private
  -- directory are removed on either.
  main <- myThreadId
  void (installHandler sigTERM (CatchOnce (throwTo main UserInterrupt)) Nothing)
  case command of
    NixCacheToken options -> do
      ops <- contextOps globalContext
      destination <- makeAbsolute (options ^. #out)
      let request = TokenRequest (T.pack (options ^. #subject)) (T.pack (options ^. #validity))
      mintToken ops request destination >>= either (dieT . renderProducerError) pure
      TIO.putStrLn ("wrote a " <> request ^. #validity <> " pull-and-push token for " <> cacheName <> " (subject " <> request ^. #subject <> ") to " <> T.pack destination)
    NixCacheForward options -> withContract (options ^. #contract) $ do
      ops <- contextOps globalContext
      withForward ops serve >>= \case
        Left failure -> dieT (renderProducerError failure)
        Right Nothing -> pure ()
        Right (Just code) -> dieT ("the port-forward to service/nix-cache exited (" <> T.pack (show code) <> ")")
    NixCachePush options -> withContract (options ^. #contract) $ do
      target <- case (options ^. #endpoint, options ^. #tokenFile) of
        (Nothing, Nothing)
          | isJust (options ^. #cache) -> dieT "--cache applies only with --endpoint"
          | otherwise -> pure ContextCache
        (Just endpoint', Just tokenFile') -> pure (ExternalCache (T.pack endpoint') tokenFile' (maybe cacheName T.pack (options ^. #cache)))
        _ -> dieT "--endpoint and --token-file go together"
      ops <- case target of
        ContextCache -> contextOps globalContext
        ExternalCache {} -> pure (defaultProducerOps (pure (Left "an external push opens no cluster session")))
      pushPaths ops target (options ^. #paths) >>= either (dieT . renderProducerError) reportPush

-- | Announce the forward, then hold it until interrupted ('Nothing') or
-- until the port-forward exits.
serve :: Forwarded -> IO (Maybe ExitCode)
serve forwarded = do
  contract <- contractSinkSet
  if contract
    then
      emitDocument
        NixCacheEndpoint
          { contractVersion = ContractVersion1
          , document = DocumentName
          , endpoint = forwarded ^. #endpoint
          , cache = forwarded ^. #cache
          , publicKey = forwarded ^. #publicKey
          }
    else do
      TIO.putStrLn ("forwarding " <> forwarded ^. #cache <> " at " <> forwarded ^. #endpoint <> " (public key " <> forwarded ^. #publicKey <> ")")
      hFlush stdout
  (Just <$> forwarded ^. #child . #waitExit) `catch` \case
    UserInterrupt -> pure Nothing
    other -> throwIO other

reportPush :: Pushed -> IO ()
reportPush pushed = do
  contract <- contractSinkSet
  let succeeded = pushed ^. #exit == ExitSuccess
  if contract
    then
      emitDocument
        NixCachePushResult
          { contractVersion = ContractVersion1
          , document = DocumentName
          , endpoint = pushed ^. #endpoint
          , cache = pushed ^. #cache
          , paths = map T.pack (pushed ^. #paths)
          , outcome = if succeeded then "pushed" else "failed"
          }
    else
      if succeeded
        then TIO.putStrLn ("pushed " <> T.pack (show (length (pushed ^. #paths))) <> " paths to " <> pushed ^. #cache <> " at " <> pushed ^. #endpoint)
        else TIO.hPutStrLn stderr ("attic push to " <> pushed ^. #cache <> " at " <> pushed ^. #endpoint <> " failed")
  unless succeeded (exitWith (pushed ^. #exit))

-- | The real programs, bound to the command's session for the active cloud
-- context. Admission happens at the first kubectl call, not here.
contextOps :: Maybe String -> IO ProducerOps
contextOps globalContext = do
  active <- activeTarget globalContext
  either (dieT . renderProducerError) pure (requireCloudContext (active ^. #profile . #mode))
  let context = active ^. #contextName
      contextText = contextNameText context
  expected <- readContextHostName context >>= either dieT pure
  commandClusterSession defaultSessionOps contextText (Just expected) >>= \case
    Just (Right _) -> pure ()
    Just (Left reason) -> dieT reason
    Nothing -> dieT "the nix-cache commands run only inside a command scope"
  pure (defaultProducerOps (kubectlConnectionArguments contextText))
