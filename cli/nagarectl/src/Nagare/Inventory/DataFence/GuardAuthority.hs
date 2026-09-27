-- | Exact authorization checks for the API-backed admission objects used by
-- a live-volume fence. Admission policies cannot validate their own mutation;
-- the Kubernetes authorizer must deny policy edits to every untrusted identity
-- whose access the reviewed fence relies on.
module Nagare.Inventory.DataFence.GuardAuthority
  ( GuardAccessQuery (..)
  , GuardAccessTransport (..)
  , kubectlGuardAccessTransport
  , observeGuardAuthority
  ) where

import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAsciiLower, isDigit)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.KubernetesRuntime
  (KubernetesRuntimeConfig (..))
import Nagare.Inventory.DataFence.MountGuard (MountGuard)
import Nagare.Inventory.DataFence.MountGuardRuntime (guardObjectAddresses)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data GuardAccessQuery = GuardAccessQuery
  { accessPrincipal :: !Text
  , accessVerb :: !Text
  , accessResource :: !Text
  , accessName :: !Text
  }
  deriving stock (Eq, Ord, Show)

data GuardAccessTransport = GuardAccessTransport
  { checkGuardAccess :: !(GuardAccessQuery -> IO (Either Text Bool))
  }

-- | Check every exact policy and binding address under each untrusted
-- principal. "False" means an edit is currently authorized; an unavailable
-- or inconclusive SubjectAccessReview is an error, never a denial proof.
observeGuardAuthority :: GuardAccessTransport -> [Text] -> MountGuard
  -> IO (Either Text Bool)
observeGuardAuthority transport principals mountGuard =
  case do
    unless (not (null principals))
      (Left "mount guard has no untrusted principals to check")
    addresses <- guardObjectAddresses mountGuard
    resources <- traverse resourceAddress addresses
    let queries = Set.toAscList (Set.fromList
          [GuardAccessQuery principal verb resource name
            | principal <- principals
            , (resource, name) <- resources
            , verb <- ["update", "patch", "delete"]])
    _ <- traverse serviceAccountNamespace principals
    pure queries of
    Left reason -> pure (Left reason)
    Right queries -> checkAll queries
  where
    checkAll [] = pure (Right True)
    checkAll remaining = do
      let (batch, rest) = splitAt 8 remaining
      slots <- traverse (\query -> do
        slot <- newEmptyMVar
        _ <- forkFinally (checkGuardAccess transport query) (putMVar slot)
        pure slot) batch
      checked <- traverse takeMVar slots
      let reviewed = [case outcome of
            Left _ -> Left "Kubernetes guard authorization review worker failed"
            Right result -> result | outcome <- checked]
      case sequence reviewed of
        Left reason -> pure (Left reason)
        Right allowed | or allowed -> pure (Right False)
        Right _ -> checkAll rest

resourceAddress :: (Text, Text) -> Either Text (Text, Text)
resourceAddress ("ValidatingAdmissionPolicy", name) =
  Right ("validatingadmissionpolicies", name)
resourceAddress ("ValidatingAdmissionPolicyBinding", name) =
  Right ("validatingadmissionpolicybindings", name)
resourceAddress _ = Left "mount guard has an unsupported admission object"

serviceAccountNamespace :: Text -> Either Text Text
serviceAccountNamespace principal = case T.splitOn ":" principal of
  ["system", "serviceaccount", namespace, account]
    | validLabel namespace && validSubdomain account -> Right namespace
  _ -> Left "guard authority principal is not a service account"

validSubdomain :: Text -> Bool
validSubdomain value = T.length value <= 253
  && all validLabel (T.splitOn "." value)

validLabel :: Text -> Bool
validLabel value = not (T.null value) && T.length value <= 63
  && alphaNumeric (T.head value) && alphaNumeric (T.last value)
  && T.all (\character -> alphaNumeric character || character == '-') value
  where
    alphaNumeric character = isAsciiLower character || isDigit character

kubectlGuardAccessTransport :: KubernetesRuntimeConfig -> GuardAccessTransport
kubectlGuardAccessTransport config = GuardAccessTransport checkOne
  where
    checkOne query = case serviceAccountNamespace (accessPrincipal query) of
      Left reason -> pure (Left reason)
      Right namespace -> do
        let accessReview = object
              [ "apiVersion" .= ("authorization.k8s.io/v1" :: Text)
              , "kind" .= ("SubjectAccessReview" :: Text)
              , "spec" .= object
                  [ "user" .= accessPrincipal query
                  , "groups" .=
                      [ "system:serviceaccounts" :: Text
                      , "system:serviceaccounts:" <> namespace
                      , "system:authenticated"]
                  , "resourceAttributes" .= object
                      [ "group" .= ("admissionregistration.k8s.io" :: Text)
                      , "resource" .= accessResource query
                      , "name" .= accessName query
                      , "verb" .= accessVerb query]]]
            input = T.unpack (TE.decodeUtf8 (BL.toStrict (encode accessReview)))
        guarded <- runtimeGuard config
        case guarded of
          Left reason -> pure (Left ("cluster guard refused: " <> reason))
          Right () -> do
            result <- try (readProcessWithExitCode "kubectl"
              [ "--context", T.unpack (runtimeKubectlContext config)
              , "--request-timeout=10s", "create", "-f", "-", "-o", "json"] input)
            pure $ case result of
              Left (_ :: IOException) -> Left "could not invoke kubectl for guard authority"
              Right (ExitFailure _, _, _) ->
                Left "Kubernetes guard SubjectAccessReview failed"
              Right (ExitSuccess, output, _) -> do
                value <- first T.pack (eitherDecodeStrict'
                  (TE.encodeUtf8 (T.pack output)))
                parseReviewStatus value

parseReviewStatus :: Value -> Either Text Bool
parseReviewStatus (Object root) = case KM.lookup "status" root of
  Just (Object status) -> do
    unless (case KM.lookup "evaluationError" status of
        Nothing -> True
        Just Null -> True
        Just (String value) -> T.null value
        _ -> False)
      (Left "Kubernetes guard authorization review was inconclusive")
    case KM.lookup "allowed" status of
      Just (Bool allowed) -> Right allowed
      _ -> Left "Kubernetes guard authorization review lacks allowed status"
  _ -> Left "Kubernetes guard authorization review lacks status"
parseReviewStatus _ = Left "Kubernetes guard authorization review is malformed"
