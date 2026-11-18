-- | @nagarectl context move list --base-domain NEW@ (EP-246 D1): every URL a move to a new base
-- domain changes, every grant on it, the OAuth clients and the passkey holders, and the manifest the
-- move works from. It mutates nothing: the ledger is read without a lock, En by a fully consistent
-- relationship query, and Shomei by a read-only transaction.
module Nagare.Cli.Move.Manifest
  ( collectManifest
  , listBaseMove
  , manifestFile
  )
where

import Control.Exception (IOException, throwIO, try)
import Control.Monad (join)
import Data.Aeson (eitherDecodeStrict, encode, toJSON)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (forM_)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Access.Grants (HostGrants (..), hostGrantsFilter, hostGrantsOf, listRelationships, relationshipQueryPath)
import Nagare.Access.ShomeiMove
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext, withPreparedContextEnSession)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Context.BaseMove
import Nagare.Dsl.Prelude
import Nagare.Inventory.AccessRuntime (EnTransport (..))
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Resource.Inventory (composeSnapshot, inventoryDeclarations)
import Nagare.Target (ActiveTarget, IngressMode (..), Mode (Cloud), contextNameText)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

manifestFile :: FilePath
manifestFile = "move-manifest.json"

-- | The manifest, or every refusal: a host the map refuses, or a host whose stored grants in En
-- differ from the accepted ones, since the move carries only what the ledger declares.
collectManifest :: ActiveTarget -> Text -> IO (Either [Text] MoveManifest)
collectManifest active new = do
  let profile = active ^. #profile
      old = profile ^. #baseDomain
  forM_ (issuerMoveRefusal (profile ^. #authIssuer)) $ \refusal -> dieT (T.unlines ["The move to " <> new <> " cannot start:", "  " <> refusal])
  unless (profile ^. #mode == Cloud) (dieT "a context move needs a cloud context")
  unless (profile ^. #ingress == IngressDirect) (dieT "a move to a new base domain starts from a direct context")
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  declarations <- either (dieT . T.pack . show) (pure . inventoryDeclarations) (composeSnapshot snapshot)
  case movedHosts old new (hostFacts declarations) of
    Left refusals -> pure (Left refusals)
    Right hosts -> do
      let clusterReady = fmap (const ()) <$> guardKubernetesContext active
          kubectlContext = contextNameText (active ^. #contextName)
      drift <-
        withPreparedContextEnSession active $ \en ->
          concat <$> traverse (\h -> either (\reason -> [h ^. #oldName <> ": " <> reason]) (grantDrift h) <$> storedGrants en h) (filter (^. #protected) hosts)
      clients <- readShomeiJson kubectlContext clusterReady oauthClientsSql <&> (>>= parseOAuthClients old)
      holders <- readShomeiJson kubectlContext clusterReady passkeyHoldersSql <&> (>>= parsePasskeyHolders)
      pure $ case (drift, clients, holders) of
        ([], Right c, Right p) -> Right (MoveManifest old new hosts c p)
        _ -> Left (drift <> either pure (const []) clients <> either pure (const []) holders)

-- | A protected host's stored direct and team grants, read fully consistently.
storedGrants :: EnTransport -> MovedHost -> IO (Either Text ([Text], [Text]))
storedGrants en h = do
  let host = h ^. #oldName
      page cursor =
        call' cursor >>= \case
          Right (200, bytes) -> either (throwIO . userError . ("unreadable relationship page: " <>)) pure (eitherDecodeStrict bytes)
          Right (code, _) -> throwIO (userError ("En refused the relationship query with HTTP " <> show code))
          Left reason -> throwIO (userError (T.unpack reason))
      call' cursor = do
        result <- withEn en (\call -> call "POST" (T.pack (relationshipQueryPath cursor)) (toJSON (hostGrantsFilter host)))
        pure (join result)
  listed <- try (listRelationships page)
  pure $ case listed of
    Left (failure :: IOException) -> Left (T.pack (show failure))
    Right (Left reason) -> Left reason
    Right (Right tuples) -> case hostGrantsOf host tuples of
      HostGrants users teams [] -> Right (users, teams)
      HostGrants _ _ other -> Left ("En holds relationships the move cannot carry: " <> T.intercalate ", " other)

listBaseMove :: ActiveTarget -> Text -> Maybe FilePath -> IO ()
listBaseMove active new out =
  collectManifest active new >>= \case
    Left refusals -> dieT (T.unlines ("The move to " <> new <> " cannot start:" : map ("  " <>) refusals))
    Right manifest -> do
      TIO.putStr (renderManifest manifest)
      forM_ out $ \directory -> do
        createDirectoryIfMissing True directory
        LBS.writeFile (directory </> manifestFile) (encode manifest)
        TIO.putStrLn ("Wrote " <> T.pack (directory </> manifestFile) <> ".")
