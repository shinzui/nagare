-- | EP-182: kubectl, as the production runtime invokes it, in front of the
-- fake 'ApiServer'. 'kubectlResponse' answers each request the way kubectl
-- does: the exit code, the JSON it prints, and its first stderr line for a
-- refusal (as recorded in RES-4's traces), so the runtime's own parsing and
-- refusal mapping interpret the answer. A request outside the grammar the
-- runtime emits is a harness error, never a provider answer.
--
-- Time does not pass: a @wait@ or @rollout status@ lets every controller act
-- once ('settleControllers') and then reports success, or kubectl's timeout
-- error at once.
module Nagare.Test.World.Kubectl
  ( Response (..)
  , kubectlResponse
  , resourceToken
  , LoggedRequest (..)
  , logRequest
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.KubernetesTransport (KubectlRequest (..))
import Nagare.Test.World.ApiServer
import System.Exit (ExitCode (..))

-- | What kubectl returned, or why the harness could not answer.
data Response
  = Answered !ExitCode !Text !Text
  | -- | Not a request the runtime makes: the model must fail, naming it.
    Unsupported !Text
  deriving stock (Eq, Show)

-- | One request, as the world logged it: its verb and the object it named.
data LoggedRequest = LoggedRequest
  { verb :: !Text
  , target :: !(Maybe ObjectKey)
  , arguments :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

logRequest :: KubectlRequest -> LoggedRequest
logRequest request =
  let args = map T.pack (request ^. #arguments)
   in LoggedRequest (fromMaybe "" (listToMaybe args)) (requestTarget args) args

kubectlResponse :: KubectlRequest -> ApiServer -> (ApiServer, Response)
kubectlResponse request server = case args of
  "get" : "pods" : rest -> (server, ok (podList (flag "--namespace" rest <|> flag "-n" rest) (flag "-l" rest) server))
  -- EP-181: one pod by name, as the stuck-pod settlement reads it.
  "get" : "pod" : name : rest -> case getPod (flag "--namespace" rest <|> flag "-n" rest) name server of
    Just rendered -> (server, ok (encodeText rendered))
    Nothing
      | "--ignore-not-found" `elem` rest -> (server, ok "")
      | otherwise -> (server, refused ("Error from server (NotFound): pods \"" <> name <> "\" not found"))
  "get" : token : name : rest -> case resourceToken token of
    Nothing -> unsupported
    Just (group', kind') ->
      let key = ObjectKey group' kind' (flag "--namespace" rest <|> flag "-n" rest) name
       in case get ("--show-managed-fields" `elem` rest) key server of
            Just rendered -> (server, ok (encodeText rendered))
            Nothing
              | "--ignore-not-found" `elem` rest -> (server, ok "")
              | otherwise -> (server, refused ("Error from server (NotFound): " <> pluralOf key <> " \"" <> name <> "\" not found"))
  "create" : rest | "-f" `elem` rest -> withBody $ \body -> case create (manager rest "kubectl-create") body server of
    Right (server', written) -> (server', ok (encodeText written))
    Left refusal -> (server, refused ("Error from server (" <> reasonText refusal <> "): error when creating \"STDIN\": " <> refusal ^. #message))
  "apply" : rest | "--server-side" `elem` rest -> withBody $ \body -> case applyServerSide (manager rest "kubectl") ("--force-conflicts" `elem` rest) body server of
    Right (server', written) -> (server', ok (encodeText written))
    Left refusal -> (server, refused (applyError body refusal))
  "patch" : token : name : rest | flag "--type" rest == Just "json" || "--type=json" `elem` rest -> case (resourceToken token, flag "-p" rest) of
    (Just (group', kind'), Just patch) -> case eitherDecodeStrict (TE.encodeUtf8 patch) of
      Right (Array operations) ->
        let key = ObjectKey group' kind' (flag "--namespace" rest <|> flag "-n" rest) name
         in case patchJson (manager rest "kubectl-patch") key (V.toList operations) server of
              Right (server', written) -> (server', ok (encodeText written))
              Left refusal
                | refusal ^. #httpStatus == 404 -> (server, refused ("Error from server (NotFound): " <> refusal ^. #message))
                | otherwise -> (server, refused "The request is invalid: the server rejected our request due to an error in our request")
      _ -> unsupported
    _ -> unsupported
  ["delete", "--raw", path, "-f", "-"] -> withBody $ \options -> case rawPath path of
    Nothing -> unsupported
    Just key ->
      let preconditions = field' "preconditions" options
          answer = case key ^. #kind of
            "pod" -> deletePod (Preconditions (textOf "uid" preconditions) (textOf "resourceVersion" preconditions)) (key ^. #namespace) (key ^. #name) server
            _ -> delete (Preconditions (textOf "uid" preconditions) (textOf "resourceVersion" preconditions)) (propagation (textOf "propagationPolicy" options)) key server
       in case answer of
            Right server' -> (server', ok (encodeText (object ["kind" .= ("Status" :: Text), "status" .= ("Success" :: Text)])))
            Left refusal -> (server, refused ("Error from server (" <> reasonText refusal <> "): " <> refusal ^. #message))
  "wait" : rest -> case [r | r <- rest, not ("--" `T.isPrefixOf` r), r `notElem` maybe [] pure (flag "--namespace" rest)] of
    resourceName : _
      | Just (token, name) <- splitSlash resourceName
      , Just (group', kind') <- resourceToken token ->
          let key = ObjectKey group' kind' (flag "--namespace" rest) name
              settled = settleControllers server
              -- kubectl names the bare plural here, without the API group.
              timedOut = (settled, refused ("error: timed out waiting for the condition on " <> T.takeWhile (/= '.') (pluralOf key) <> "/" <> name))
           in case [T.drop (T.length "--for=") r | r <- rest, "--for=" `T.isPrefixOf` r] of
                ["delete"] -> if isNothing (get False key settled) then (settled, ok "") else timedOut
                [condition] | Just conditionType <- T.stripPrefix "condition=" condition -> case get False key settled of
                  Just rendered | conditionMet conditionType rendered -> (settled, ok (pluralOf key <> "/" <> name <> " condition met"))
                  _ -> timedOut
                -- @--for=jsonpath={.a.b}=value@: a dotted path, compared as
                -- text (EP-183 M1 waits on a DomainMapping's URL scheme).
                [condition]
                  | Just jsonPath <- T.stripPrefix "jsonpath={." condition
                  , (path, rest') <- T.breakOn "}=" jsonPath
                  , Just expected <- T.stripPrefix "}=" rest' -> case get False key settled of
                      Just rendered | textLeaf (T.splitOn "." path) rendered == Just expected -> (settled, ok (pluralOf key <> "/" <> name <> " condition met"))
                      _ -> timedOut
                _ -> unsupported
    _ -> unsupported
  "rollout" : "status" : resourceName : rest
    | Just (token, name) <- splitSlash resourceName
    , Just (group', kind') <- resourceToken token ->
        let key = ObjectKey group' kind' (flag "--namespace" rest) name
            settled = settleControllers server
         in case get False key settled of
              Just rendered
                | rolloutComplete key rendered -> (settled, ok (kind' <> " \"" <> name <> "\" successfully rolled out"))
                | progressDeadlineExceeded rendered -> (settled, refused ("error: " <> kind' <> " \"" <> name <> "\" exceeded its progress deadline"))
              _ -> (settled, refused "error: timed out waiting for the condition")
  _ -> unsupported
  where
    args = map T.pack (request ^. #arguments)
    requestBody = request ^. #input
    withBody continue = case eitherDecodeStrict (TE.encodeUtf8 (T.pack requestBody)) of
      Right value -> continue value
      Left _ -> unsupported
    unsupported = (server, Unsupported (T.unwords args))
    ok output = Answered ExitSuccess output ""
    refused message = Answered (ExitFailure 1) "" message
    manager rest fallback = fromMaybe fallback (flag "--field-manager" rest)
    propagation = \case
      Just "Orphan" -> Orphan
      Just "Foreground" -> Foreground
      _ -> Background
    applyError submitted refusal = case refusal ^. #httpStatus of
      422 -> "The " <> fromMaybe "" (textOf "kind" submitted) <> " \"" <> fromMaybe "" (keyOf submitted >>= Just . (^. #name)) <> "\" is invalid: " <> refusal ^. #message
      _ -> "error: " <> refusal ^. #message
    reasonText refusal = case refusal ^. #reason of
      "Invalid" -> "Invalid"
      other -> other

-- | A @--flag value@ or @--flag=value@ argument.
flag :: Text -> [Text] -> Maybe Text
flag name = \case
  f : value : _ | f == name -> Just value
  f : rest -> case T.stripPrefix (name <> "=") f of
    Just value -> Just value
    Nothing -> flag name rest
  [] -> Nothing

-- | kubectl's resource token: @kind@, @kind.group@ or a short name.
resourceToken :: Text -> Maybe (Text, Text)
resourceToken token = case T.breakOn "." token of
  ("ksvc", "") -> Just ("serving.knative.dev", "service")
  ("job", "") -> Just ("batch", "job")
  ("cronjob", "") -> Just ("batch", "cronjob")
  ("deployment", "") -> Just ("apps", "deployment")
  ("statefulset", "") -> Just ("apps", "statefulset")
  ("crd", "") -> Just ("apiextensions.k8s.io", "customresourcedefinition")
  ("certificate", "") -> Just ("cert-manager.io", "certificate")
  ("clusterissuer", "") -> Just ("cert-manager.io", "clusterissuer")
  ("pods", "") -> Just ("", "pod")
  (kind', "") -> Just ("", singularize kind')
  (kind', rest) -> Just (T.drop 1 rest, singularize kind')
  where
    singularize kind' = case kind' of
      "networkpolicies" -> "networkpolicy"
      other | "s" `T.isSuffixOf` other && other `notElem` ["status"] -> T.dropEnd 1 other
      other -> other

-- | @/api/v1/namespaces/<ns>/<plural>/<name>@ or
-- @/apis/<group>/<version>/namespaces/<ns>/<plural>/<name>@.
rawPath :: Text -> Maybe ObjectKey
rawPath path = case filter (not . T.null) (T.splitOn "/" path) of
  ["api", "v1", "namespaces", namespace', plural, name] -> Just (ObjectKey "" (singularOf plural) (Just namespace') name)
  ["api", "v1", "namespaces", name] -> Just (ObjectKey "" "namespace" Nothing name)
  ["apis", group', _, "namespaces", namespace', plural, name] -> Just (ObjectKey group' (singularOf plural) (Just namespace') name)
  _ -> Nothing
  where
    singularOf plural = maybe plural snd (resourceToken plural)

requestTarget :: [Text] -> Maybe ObjectKey
requestTarget = \case
  "get" : token : name : rest | token /= "pods" -> (\(g, k) -> ObjectKey g k (flag "--namespace" rest <|> flag "-n" rest) name) <$> resourceToken token
  "patch" : token : name : rest -> (\(g, k) -> ObjectKey g k (flag "--namespace" rest) name) <$> resourceToken token
  ["delete", "--raw", path, "-f", "-"] -> rawPath path
  "wait" : rest -> listToMaybe [ObjectKey g k (flag "--namespace" rest) name | r <- rest, Just (token, name) <- [splitSlash r], Just (g, k) <- [resourceToken token]]
  "rollout" : "status" : resourceName : rest -> (\(token, name) -> (\(g, k) -> ObjectKey g k (flag "--namespace" rest) name) <$> resourceToken token) =<< splitSlash resourceName
  _ -> Nothing

splitSlash :: Text -> Maybe (Text, Text)
splitSlash text' = case T.breakOn "/" text' of
  (token, rest) | not (T.null rest) -> Just (token, T.drop 1 rest)
  _ -> Nothing

-- | The pods a label selector finds: the world's StatefulSet pods (EP-181)
-- whose labels hold every @key=value@ of the selector. The world models no
-- Job or restore-scratch pods, so the backup-receipt reader finds no receipt
-- and the scratch probe no failed pod, as the model's earlier stubs answered.
podList :: Maybe Text -> Maybe Text -> ApiServer -> Text
podList podNamespace selector server =
  encodeText (object ["apiVersion" .= ("v1" :: Text), "kind" .= ("List" :: Text), "items" .= filter selected (listPods podNamespace server)])
  where
    required = [(k, T.drop 1 v) | term <- maybe [] (T.splitOn ",") selector, let (k, v) = T.breakOn "=" term, not (T.null v)]
    selected pod = case pod of
      Object root
        | Just (Object metadata) <- KM.lookup "metadata" root
        , Just (Object labels) <- KM.lookup "labels" metadata ->
            all (\(k, v) -> KM.lookup (Key.fromText k) labels == Just (String v)) required
      _ -> null required

progressDeadlineExceeded :: Value -> Bool
progressDeadlineExceeded rendered = any (\c -> textOf "reason" c == Just "ProgressDeadlineExceeded") (arrayOf (field' "conditions" (field' "status" rendered)))

pluralOf :: ObjectKey -> Text
pluralOf key =
  let base = case key ^. #kind of
        "networkpolicy" -> "networkpolicies"
        other -> other <> "s"
   in if key ^. #group == "" then base else base <> "." <> key ^. #group

encodeText :: Value -> Text
encodeText = TE.decodeUtf8 . LBS.toStrict . encode

field' :: Text -> Value -> Value
field' key = \case
  Object fields -> fromMaybe Null (KM.lookup (Key.fromText key) fields)
  _ -> Null

textOf :: Text -> Value -> Maybe Text
textOf key value = case field' key value of
  String s -> Just s
  _ -> Nothing

arrayOf :: Value -> [Value]
arrayOf = \case
  Array values -> V.toList values
  _ -> []

textLeaf :: [Text] -> Value -> Maybe Text
textLeaf path value = case foldl' (\v k -> case v of Object fields -> fromMaybe Null (KM.lookup (Key.fromText k) fields); _ -> Null) value path of
  String text' -> Just text'
  _ -> Nothing
