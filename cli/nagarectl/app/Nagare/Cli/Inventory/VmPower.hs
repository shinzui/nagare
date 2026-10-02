-- | Compute API power transport; it deliberately has no running-host dependency.
module Nagare.Cli.Inventory.VmPower (vmPowerRuntime) where

import Data.Aeson (eitherDecodeStrict', withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Process (runExternal)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (Adapter)
import Nagare.Inventory.Store (InventoryStore, publishIfAbsent, readObject)
import Nagare.Inventory.VmPower
import Nagare.Resource.Inventory (OperationKind (StartVm, StopVm), ScopeDeclaration, operationKind, operations, scopeBundles)
import Nagare.Resource.Types (ProviderAddress (CloudInstance), mkName, nameText)
import Nagare.Target (ActiveTarget, Mode (Cloud))
import System.Exit (ExitCode (ExitSuccess))
import System.Timeout (timeout)

vmPowerRuntime :: IO InventoryStore -> ActiveTarget -> [ScopeDeclaration] -> Adapter -> IO Adapter
vmPowerRuntime loadStore active scopes base
  | null
      [ intent
      | scope <- scopes
      , bundle <- scopeBundles scope
      , intent <- operations bundle
      , operationKind intent `elem` [StartVm, StopVm]
      ] =
      pure base
  | otherwise = do
      store <- loadStore
      project <- either dieT pure (mkName (profile ^. #project))
      zone <- either dieT pure (mkName (profile ^. #zone))
      name <- either dieT pure (mkName (profile ^. #instanceName))
      bindings <- either dieT pure (vmPowerBindings (CloudInstance project zone name) scopes)
      for_ (Map.elems bindings) $ \(VmPowerBinding _ address _) ->
        either dieT pure (arguments address)
      pure (withVmPower bindings (VmPowerOps observe submit (readReceipt store) (writeReceipt store)) base)
  where
    readReceipt store digest = first (T.pack . show) <$> readObject store (vmPowerReceiptKey digest)
    writeReceipt store digest bytes = fmap (const ()) . first (T.pack . show) <$> publishIfAbsent store (vmPowerReceiptKey digest) bytes
    profile = active ^. #profile
    arguments = \case
      CloudInstance project zone name
        | profile ^. #mode == Cloud
        , nameText project == profile ^. #project
        , nameText zone == profile ^. #zone
        , nameText name == profile ^. #instanceName ->
            Right
              [ T.unpack (nameText name)
              , "--project=" <> T.unpack (nameText project)
              , "--zone=" <> T.unpack (nameText zone)
              ]
      _ -> Left "VM power address differs from the selected cloud context"
    invoke seconds command address extra = case arguments address of
      Left reason -> pure (Left reason)
      Right args -> do
        outcome <-
          timeout
            (seconds * 1000000)
            ( runExternal
                [ExitSuccess]
                "gcloud"
                (["compute", "instances", command] <> args <> extra)
                ""
            )
        pure (fromMaybe (Left "Compute API request timed out; inspect the original review before recovery") outcome)
    observe address = do
      result <- invoke 60 "describe" address ["--format=json"]
      pure $ do
        output <- result
        value <- first T.pack (eitherDecodeStrict' (TE.encodeUtf8 output))
        first
          T.pack
          ( parseEither
              ( withObject "Compute instance" $ \fields -> do
                  identity <- fields .: "id"
                  status <- fields .: "status"
                  pure (VmPowerObservation identity status)
              )
              value
          )
    submit address start =
      fmap (const ())
        <$> invoke
          180
          (if start then "start" else "stop")
          address
          ["--quiet"]
