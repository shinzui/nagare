-- | Explicit-context kubectl transport for reviewed Kubernetes objects.
-- Create is a server-side create-only request. Updates are server-side apply
-- with UID and resourceVersion in the request, without force-conflicts. A
-- transport failure is ambiguous until a new observation proves its outcome.
module Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (..)
  , mkKubernetesRuntimeOps
  , desiredFieldsMatch
  ) where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (AdapterExecution (..), OperationAction (..))
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory (ManagedResource (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data KubernetesRuntimeConfig = KubernetesRuntimeConfig
  { runtimeContext :: !ContextId
  , runtimeKubectlContext :: !Text
  , runtimeGuard :: !(IO (Either Text ()))
  }

mkKubernetesRuntimeOps
  :: KubernetesRuntimeConfig
  -> Map ResourceId (ManagedResource, ByteString)
  -> KubernetesAdapterOps
mkKubernetesRuntimeOps config specs =
  KubernetesAdapterOps
    { kubernetesContext = runtimeContext config
    , kubernetesObserve = observe
    , kubernetesMutateConditional = mutate
    }
  where
    observe resource = case Map.lookup resource specs of
      Nothing -> pure (KubernetesUnknown "Kubernetes resource has no native binding")
      Just (declaration, native) -> do
        guarded <- runtimeGuard config
        case guarded of
          Left reason -> pure (KubernetesUnknown ("cluster guard refused: " <> reason))
          Right () -> case address declaration of
            Kubernetes _ group kind namespace name -> do
              result <- invoke config
                (["get", kindToken group kind, T.unpack (nameText name)]
                  <> namespaceArgs namespace <> ["-o", "json", "--ignore-not-found"])
                ""
              pure $ case result of
                Left reason -> KubernetesUnknown reason
                Right (ExitFailure _, _, _) -> KubernetesUnknown "kubectl get failed"
                Right (ExitSuccess, output, _)
                  | null output -> KubernetesAbsent (contentDigest (TE.encodeUtf8 (resourceIdText resource <> ":absent")))
                  | otherwise -> either KubernetesUnknown id (parseObserved config resource native (T.pack output))
            _ -> pure (KubernetesUnknown "bound resource has no Kubernetes address")
    mutate mutation = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (AdapterEffectAmbiguous ("cluster guard refused before Kubernetes write: " <> reason))
        Right () -> do
          let native = mutationNativeJson mutation
          request <- case (mutationAction mutation, mutationBefore mutation) of
            (CreateResource, KubernetesAbsent _) -> pure (Right (["create", "-f", "-"], native))
            (UpdateResource, KubernetesPresent uid revision _ _) ->
              pure ((["apply", "--server-side", "--field-manager=nagare-inventory", "-f", "-"],) <$> addPreconditions uid revision native)
            _ -> pure (Left "Kubernetes transport received an unsupported action or precondition")
          case request of
            Left reason -> pure (AdapterEffectAmbiguous reason)
            Right (arguments, body) -> do
              result <- invoke config arguments (T.unpack body)
              pure $ case result of
                Right (ExitSuccess, _, _) -> AdapterEffectCompleted
                _ -> AdapterEffectAmbiguous "Kubernetes write did not return success; reobserve before retry"

-- | Compare only fields present in the retained desired object. Server-added
-- metadata, defaults and status do not count as drift. Arrays stay ordered;
-- this deliberately reports uncertain associative-list reorderings as drift.
desiredFieldsMatch :: Value -> Value -> Bool
desiredFieldsMatch (Object desired) (Object observed) =
  all (\(key, value) -> maybe False (desiredFieldsMatch value) (KM.lookup key observed)) (KM.toList desired)
desiredFieldsMatch (Array desired) (Array observed) =
  length desired == length observed && and (zipWith desiredFieldsMatch (foldr (:) [] desired) (foldr (:) [] observed))
desiredFieldsMatch desired observed = desired == observed

parseObserved :: KubernetesRuntimeConfig -> ResourceId -> ByteString -> Text -> Either Text KubernetesState
parseObserved config resource native response = do
  observed <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 response))
  desired <- first (T.pack . show) (eitherDecodeStrict native)
  metadata <- metadataOf observed
  uid <- fieldText "uid" metadata >>= mkPhysicalIdentity
  revision <- fieldText "resourceVersion" metadata
  annotations <- case KM.lookup "annotations" metadata of
    Nothing -> Right KM.empty
    Just (Object value) -> Right value
    _ -> Left "Kubernetes annotations are malformed"
  let stampedContext = textAt "nagare.dev/context-id" annotations
      stampedOwner = textAt "nagare.dev/resource-id" annotations >>= either (const Nothing) Just . mkResourceId
      owner = if stampedContext == Just (contextIdText (runtimeContext config)) then stampedOwner else Nothing
      desiredDigest = contentDigest native
      desiredMatches = desiredFieldsMatch desired observed && textAt "nagare.dev/spec-digest" annotations == Just (digestText desiredDigest)
  driftDigest <- if desiredMatches then Right desiredDigest else contentDigest <$> canonicalValue observed
  pure (KubernetesPresent uid revision (if owner == Just resource then owner else Nothing) driftDigest)

metadataOf :: Value -> Either Text Object
metadataOf (Object root) = case KM.lookup "metadata" root of
  Just (Object value) -> Right value
  _ -> Left "Kubernetes observation has no metadata"
metadataOf _ = Left "Kubernetes observation is not an object"

fieldText :: Key -> Object -> Either Text Text
fieldText key metadata = case KM.lookup key metadata of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("Kubernetes observation lacks " <> T.pack (show key))

textAt :: Key -> Object -> Maybe Text
textAt key value = case KM.lookup key value of Just (String textValue) -> Just textValue; _ -> Nothing

addPreconditions :: PhysicalIdentity -> Text -> Text -> Either Text Text
addPreconditions uid revision native = do
  value <- first (T.pack . show) (eitherDecodeStrict (TE.encodeUtf8 native))
  metadata <- metadataOf value
  let guarded = KM.insert "uid" (String (physicalIdentityText uid))
        (KM.insert "resourceVersion" (String revision) metadata)
  case value of
    Object root -> TE.decodeUtf8 <$> canonicalValue (Object (KM.insert "metadata" (Object guarded) root))
    _ -> Left "Kubernetes native object is not an object"

kindToken :: Text -> Name -> String
kindToken group kind = T.unpack (nameText kind <> if T.null group then "" else "." <> group)

namespaceArgs :: Maybe Name -> [String]
namespaceArgs = maybe [] (\namespace -> ["--namespace", T.unpack (nameText namespace)])

invoke :: KubernetesRuntimeConfig -> [String] -> String -> IO (Either Text (ExitCode, String, String))
invoke config arguments input = do
  result <- try (readProcessWithExitCode "kubectl"
    (["--context", T.unpack (runtimeKubectlContext config), "--request-timeout=10s"] <> arguments) input)
  pure $ case result of
    Left (_ :: IOException) -> Left "could not invoke kubectl"
    Right output -> Right output
