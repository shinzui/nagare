-- | Install and reobserve a live-volume admission guard through one explicit
-- Kubernetes context. A successful create response alone is never a proof
-- that admission is enforcing the guard.
module Nagare.Inventory.DataFence.MountGuardRuntime
  ( MountGuardTransport (..)
  , kubectlMountGuardTransport
  , installMountGuard
  , observeMountGuard
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=), guard)
import Nagare.Inventory.Adapters.KubernetesRuntime
  (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence.MountGuard
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data MountGuardTransport = MountGuardTransport
  { readGuardObject :: !(Text -> Text -> IO (Either Text (Maybe Value)))
  , createGuardObject :: !(Value -> IO (Either Text ()))
  , probeForeignMountDenied :: !(MountGuard -> IO (Either Text Bool))
  }

-- | Existing objects are accepted only when their effective policy and
-- binding match the reviewed request. A partly installed set is recoverable:
-- a fresh process can create the missing members and reobserve all of them.
installMountGuard :: MountGuardTransport -> MountGuard -> IO (Either Text ())
installMountGuard transport guard = installAll (guardObjects guard)
  where
    installAll [] = pure (Right ())
    installAll (expected : rest) = do
      installed <- installOne expected
      case installed of
        Left reason -> pure (Left reason)
        Right () -> installAll rest
    installOne expected = case objectAddress expected of
      Left reason -> pure (Left reason)
      Right (kind, name) -> do
        current <- readGuardObject transport kind name
        case current of
          Left reason -> pure (Left reason)
          Right (Just observed) -> pure (matchingObject expected observed)
          Right Nothing -> createGuardObject transport expected

-- | Proof is made from current API objects plus a server-side dry-run Pod
-- admission request with no permitted owner. This is one component of the
-- full fence proof; existing Pods, attachments, and database writers need
-- separate observations.
observeMountGuard :: MountGuardTransport -> MountGuard -> IO (Either Text Bool)
observeMountGuard transport guard = do
  observed <- forM (guardObjects guard) $ \expected -> do
    case objectAddress expected of
      Left reason -> pure (Left reason)
      Right (kind, name) -> do
        current <- readGuardObject transport kind name
        pure $ case current of
          Left reason -> Left reason
          Right Nothing -> Right False
          Right (Just actual) -> case matchingObject expected actual of
            Left _ -> Right False
            Right () -> Right True
  case sequence observed of
    Left reason -> pure (Left reason)
    Right matches | not (and matches) -> pure (Right False)
    Right _ -> probeForeignMountDenied transport guard

guardObjects :: MountGuard -> [Value]
guardObjects guard =
  let (podPolicy, podBinding) = mountGuardObjects guard
      (pvcPolicy, pvcBinding) = pvcMutationGuardObjects guard
      (pvPolicy, pvBinding) = pvMutationGuardObjects guard
      (namespacePolicy, namespaceBinding) = namespaceDeleteGuardObjects guard
   in [podPolicy, pvcPolicy, pvPolicy, namespacePolicy,
       podBinding, pvcBinding, pvBinding, namespaceBinding]

objectAddress :: Value -> Either Text (Text, Text)
objectAddress (Object root) = do
  kind <- textField "kind" root
  metadata <- objectField "metadata" root
  name <- textField "name" metadata
  pure (kind, name)
objectAddress _ = Left "mount guard object is not a JSON object"

matchingObject :: Value -> Value -> Either Text ()
matchingObject (Object expected) (Object observed) = do
  unless (KM.lookup "kind" expected == KM.lookup "kind" observed
      && KM.lookup "apiVersion" expected == KM.lookup "apiVersion" observed
      && KM.lookup "spec" expected == KM.lookup "spec" observed)
    (Left "mount guard policy or binding differs from the reviewed object")
  expectedMeta <- objectField "metadata" expected
  observedMeta <- objectField "metadata" observed
  unless (KM.lookup "name" expectedMeta == KM.lookup "name" observedMeta
      && KM.lookup "annotations" expectedMeta == KM.lookup "annotations" observedMeta)
    (Left "mount guard metadata differs from the reviewed object")
matchingObject _ _ = Left "mount guard object is not a JSON object"

objectField :: Text -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
objectField key root = case KM.lookup (Key.fromText key) root of
  Just (Object value) -> Right value
  _ -> Left ("mount guard " <> key <> " is missing")

textField :: Text -> KM.KeyMap Value -> Either Text Text
textField key root = case KM.lookup (Key.fromText key) root of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("mount guard " <> key <> " is missing")

kubectlMountGuardTransport :: KubernetesRuntimeConfig -> MountGuardTransport
kubectlMountGuardTransport config = MountGuardTransport readOne createOne probe
  where
    invoke arguments input = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (Left ("cluster guard refused: " <> reason))
        Right () -> do
          result <- try (readProcessWithExitCode "kubectl"
            (["--context", T.unpack (runtimeKubectlContext config),
              "--request-timeout=10s"] <> arguments) input)
          pure $ case result of
            Left (_ :: IOException) -> Left "could not invoke kubectl"
            Right output -> Right output
    readOne kind name = do
      result <- invoke ["get", T.unpack kind, T.unpack name,
        "-o", "json", "--ignore-not-found"] ""
      pure $ case result of
        Left reason -> Left reason
        Right (ExitFailure _, _, _) -> Left "could not read mount guard object"
        Right (ExitSuccess, output, _) | T.null (T.strip (T.pack output)) -> Right Nothing
        Right (ExitSuccess, output, _) ->
          Just <$> first T.pack (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
    createOne value = do
      result <- invoke ["create", "-f", "-"] (T.unpack (TE.decodeUtf8 (BL.toStrict (encode value))))
      pure $ case result of
        Left reason -> Left reason
        Right (ExitSuccess, _, _) -> Right ()
        Right (ExitFailure _, _, _) -> Left "could not create mount guard object"
    probe guard = do
      let name = mountGuardName guard <> "-foreign-probe"
          pod = object
            [ "apiVersion" .= ("v1" :: Text)
            , "kind" .= ("Pod" :: Text)
            , "metadata" .= object ["name" .= name]
            , "spec" .= object
                [ "containers" .= [object
                    [ "name" .= ("probe" :: Text)
                    , "image" .= ("registry.k8s.io/pause:3.9" :: Text)
                    , "volumeMounts" .= [object
                        [ "name" .= ("data" :: Text)
                        , "mountPath" .= ("/data" :: Text)
                        ]]
                    ]]
                , "volumes" .= [object
                    [ "name" .= ("data" :: Text)
                    , "persistentVolumeClaim" .= object
                        ["claimName" .= guardClaimName guard]
                    ]]
                ]
            ]
      result <- invoke ["--namespace", T.unpack (guardNamespaceName guard),
        "create", "-f", "-", "--dry-run=server"]
        (T.unpack (TE.decodeUtf8 (BL.toStrict (encode pod))))
      pure $ case result of
        Left reason -> Left reason
        Right (ExitSuccess, _, _) -> Right False
        Right (ExitFailure _, _, errors) ->
          Right ("Nagare live PVC is fenced" `T.isInfixOf` T.pack errors)
