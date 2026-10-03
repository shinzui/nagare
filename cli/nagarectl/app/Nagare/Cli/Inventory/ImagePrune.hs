-- | Read-only CRI capture and exact removal on the accepted Compute incarnation.
module Nagare.Cli.Inventory.ImagePrune
  ( imagePruneRuntime
  , imageCacheOps
  , selectedImageCacheAddress
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (eitherDecodeStrict', toJSON, withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Process (runExternal)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (Adapter)
import Nagare.Inventory.ImagePrune
import Nagare.Inventory.ImagePruneAdapter (withImagePrune)
import Nagare.Inventory.ImagePruneScript (imagePruneScript)
import Nagare.Inventory.Store (InventoryStore, publishIfAbsent, readObject)
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory (OperationKind (PruneHostImage), ScopeDeclaration, operationKind, operations, scopeBundles)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Target (ActiveTarget, Mode (Cloud), contextNameText)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)

selectedImageCacheAddress :: ActiveTarget -> Either Text ProviderAddress
selectedImageCacheAddress active = do
  unless (active ^. #profile . #mode == Cloud) (Left "host CRI image cleanup requires an accepted cloud VM")
  CloudInstance <$> mkName (active ^. #profile . #project) <*> mkName (active ^. #profile . #zone) <*> mkName (active ^. #profile . #instanceName)

imagePruneRuntime :: IO InventoryStore -> ActiveTarget -> PlatformWorkspace -> [ScopeDeclaration] -> Adapter -> IO Adapter
imagePruneRuntime loadStore active workspace scopes base
  | null [intent | scope <- scopes, bundle <- scopeBundles scope, intent <- operations bundle, operationKind intent == PruneHostImage] = pure base
  | otherwise = do
      store <- loadStore
      address <- either dieT pure (selectedImageCacheAddress active)
      bindings <- either dieT pure (imagePruneBindings address scopes)
      pure (withImagePrune bindings (imageCacheOps store active workspace) base)

imageCacheOps :: InventoryStore -> ActiveTarget -> PlatformWorkspace -> ImagePruneOps
imageCacheOps store active workspace = ImagePruneOps observe remove readReceipt writeReceipt
  where
    readReceipt digest = first (T.pack . show) <$> readObject store (imagePruneReceiptKey digest)
    writeReceipt digest bytes = fmap (const ()) . first (T.pack . show) <$> publishIfAbsent store (imagePruneReceiptKey digest) bytes
    addressArgs address = do
      expected <- selectedImageCacheAddress active
      unless (address == expected) (Left "image cleanup target differs from selected context")
      case address of
        CloudInstance project zone name ->
          Right
            ( nameText name
            ,
              [ "compute"
              , "instances"
              , "describe"
              , T.unpack (nameText name)
              , "--project=" <> T.unpack (nameText project)
              , "--zone=" <> T.unpack (nameText zone)
              , "--format=json"
              ]
            )
        _ -> Left "image cleanup requires a Compute instance"
    instanceId address = case addressArgs address of
      Left reason -> pure (Left reason)
      Right (_, args) -> do
        result <- timeout (60 * 1000000) (runExternal [ExitSuccess] "gcloud" args "")
        pure $ do
          body <- fromMaybe (Left "image cache instance observation timed out") result
          value <- first T.pack (eitherDecodeStrict' (TE.encodeUtf8 body))
          first T.pack $
            parseEither
              ( withObject "instance" $ \fields -> do
                  status <- fields .: "status"
                  unless (status == ("RUNNING" :: Text)) (fail "image cleanup requires a running VM")
                  fields .: "id"
              )
              value
    remote address identity arguments = case addressArgs address of
      Left reason -> pure (Left reason)
      Right (name, _) -> do
        inherited <- getEnvironment
        let additions = [("IAP_MAX_ATTEMPTS", "1"), ("NAGARE_CONTEXT", T.unpack (contextNameText (active ^. #contextName)))]
            child = additions <> filter ((`notElem` map fst additions) . fst) inherited
            words =
              ["sudo", "--", "/run/current-system/sw/bin/bash", "-c", imagePruneScript, "nagare-image-cache"]
                <> case arguments of
                  action : rest -> action : identity : rest
                  [] -> []
            command = T.intercalate " " (map shellWord words)
            request = (proc "bash" [workspace ^. #scriptsDir </> "iap-ssh.sh", "ssh", T.unpack name, "--", T.unpack command]) {env = Just child}
        result <- timeout (120 * 1000000) (try (readCreateProcessWithExitCode request ""))
        pure $ case result of
          Nothing -> Left "image cache request timed out; no automatic removal retry"
          Just (Left (_ :: IOException)) -> Left "image cache transport unavailable"
          Just (Right (ExitSuccess, body, _)) -> Right (T.pack body)
          Just (Right (_, _, errors)) -> Left ("image cache transport refused: " <> T.take 1000 (T.pack errors))
    observe address = do
      before <- instanceId address
      case before of
        Left reason -> pure (Left reason)
        Right identity -> do
          body <- remote address identity ["inspect"]
          after <- instanceId address
          pure $ do
            output <- body
            current <- after
            unless (current == identity) (Left "VM incarnation changed during image observation")
            snapshot <- first T.pack (eitherDecodeStrict' (TE.encodeUtf8 output))
            validateImageCache snapshot
            unless (cacheInstanceId snapshot == identity) (Left "CRI cache reports a different VM")
            pure snapshot
    remove address plan = do
      current <- instanceId address
      case current of
        Left reason -> pure (Left reason)
        Right identity | identity /= pruneInstanceId plan -> pure (Left "VM incarnation changed before image removal")
        Right identity -> case canonicalValue (toJSON (pruneAliases plan)) of
          Left reason -> pure (Left reason)
          Right aliases -> fmap (const ()) <$> remote address identity ["remove", pruneImageId plan, TE.decodeUtf8 aliases]

shellWord :: Text -> Text
shellWord value = "'" <> T.replace "'" "'\\''" value <> "'"
