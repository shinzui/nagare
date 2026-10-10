-- | EP-183 M1: a protected route is checked over verified HTTPS, never
-- assumed. The stage proves, in order, against one @requireLogin@ host:
--
-- 1. certificate verification is enforced: the same request with a
--    deliberately wrong trust anchor is refused;
-- 2. an anonymous request is redirected to the login page;
-- 3. a scripted login of a granted disposable user reaches the app;
-- 4. after a reviewed revoke of that grant the same session gets 403 within
--    the enforcer's decision cache.
--
-- The checks are pure over 'RouteOps', so each named failure has a test with
-- a scripted world; 'ioRouteOps' runs them with curl, kubectl and nagarectl.
-- No request skips certificate verification.
module Nagare.Harness.RouteCheck
  ( RouteCheck (..)
  , Trust (..)
  , HttpRequest (..)
  , HttpResponse (..)
  , HttpError (..)
  , RouteOps (..)
  , RouteFailure (..)
  , Environment (..)
  , RouteCheckOptions (..)
  , routeCheckMain
  , runRouteCheck
  , renderFailure
  , loginTarget
  , formCsrf
  , responseCookies
  , parseHeaders
  , parseCreatedUser
  , curlFailure
  , ioRouteOps
  , localCa
  , withPortForward
  , wrongCaPem
  , writeTemp
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (replicateM)
import Data.Char (isAlphaNum, isSpace)
import Data.Generics.Labels ()
import Data.List (find)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Harness.Prelude
import System.Directory (getTemporaryDirectory, removeFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.IO (hClose, openTempFile)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, proc, readCreateProcessWithExitCode, readProcessWithExitCode, terminateProcess, waitForProcess)
import System.Random.Stateful (globalStdGen, uniformM)

-- | Which certificates a request trusts. 'CaFile' is a PEM bundle (the local
-- context's CA, or a wrong one); 'SystemTrust' is the workstation's store.
data Trust = SystemTrust | CaFile !FilePath
  deriving stock (Eq, Show)

data HttpRequest = HttpRequest
  { method :: !Text
  , url :: !Text
  , cookies :: ![(Text, Text)]
  , form :: ![(Text, Text)]
  }
  deriving stock (Eq, Show, Generic)

data HttpResponse = HttpResponse
  { status :: !Int
  , headers :: ![(Text, Text)]
  -- ^ Lower-cased names, in order.
  , body :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | Why a request got no HTTP answer.
data HttpError
  = TlsRejected !Text
  | Unreachable !Text
  deriving stock (Eq, Show)

data RouteCheck = RouteCheck
  { host :: !Text
  , trust :: !Trust
  , wrongTrust :: !Trust
  , expectBody :: !Text
  , grantWait :: !Int
  -- ^ Seconds to wait for a new grant to reach the enforcer (En publishes
  -- on a short interval).
  , revokeWait :: !Int
  -- ^ Seconds to wait for a revoke: En's publish lag plus the enforcer's
  -- 30-second decision cache.
  }
  deriving stock (Eq, Show, Generic)

-- | Everything the stage does to the world.
data RouteOps = RouteOps
  { http :: !(Trust -> HttpRequest -> IO (Either HttpError HttpResponse))
  , createUser :: !(Text -> Text -> IO (Either Text Text))
  -- ^ Email and password to the new user's id.
  , grant :: !(Text -> IO (Either Text ()))
  -- ^ A reviewed grant of the host to a user id, saved and applied.
  , revoke :: !(Text -> IO (Either Text ()))
  , newSecret :: !(IO Text)
  , pause :: !(IO ())
  -- ^ One second.
  , progress :: !(Text -> IO ())
  }
  deriving stock (Generic)

data RouteFailure
  = VerificationNotEnforced
  | RouteUnreachable !Text
  | CertificateNotTrusted !Text
  | NotRedirectedToLogin !Int !(Maybe Text)
  | PortalLoginUnsupported !Text
  | UserNotCreated !Text
  | GrantFailed !Text
  | LoginFormUnusable !Text
  | LoginRejected !Int
  | ProtectedNotServed !Int !Text
  | RevokeFailed !Text
  | RevokeNotEnforced !Int
  deriving stock (Eq, Show)

renderFailure :: RouteFailure -> Text
renderFailure = \case
  VerificationNotEnforced -> "certificate verification is not enforced: a wrong trust anchor was accepted"
  RouteUnreachable detail -> "the route is unreachable: " <> detail
  CertificateNotTrusted detail -> "certificate verification failed: " <> detail
  NotRedirectedToLogin code location -> "an anonymous request was not redirected to the login page: " <> tshow code <> maybe "" (" -> " <>) location
  PortalLoginUnsupported location -> "the route redirects to an operator portal (" <> location <> "); the route check drives only the built-in login form"
  UserNotCreated detail -> "the disposable test user was not created: " <> detail
  GrantFailed detail -> "the reviewed grant failed: " <> detail
  LoginFormUnusable detail -> "the login form is unusable: " <> detail
  LoginRejected code -> "the scripted login was rejected: " <> tshow code
  ProtectedNotServed code detail -> "a granted session was not served the app: " <> tshow code <> (if T.null detail then "" else " (" <> detail <> ")")
  RevokeFailed detail -> "the reviewed revoke failed: " <> detail
  RevokeNotEnforced code -> "the revoked session still gets " <> tshow code <> ", not 403"

runRouteCheck :: RouteOps -> RouteCheck -> IO (Either RouteFailure ())
runRouteCheck ops check = do
  wrong <- (ops ^. #http) (check ^. #wrongTrust) (get root [])
  case wrong of
    Right _ -> pure (Left VerificationNotEnforced)
    Left (Unreachable detail) -> pure (Left (RouteUnreachable detail))
    Left (TlsRejected _) -> do
      say "a wrong trust anchor is refused ok"
      anonymous <- request (get root [])
      case anonymous of
        Left failure -> pure (Left failure)
        Right response -> case loginTarget (check ^. #host) response of
          Left failure -> pure (Left failure)
          Right loginUrl -> do
            say ("anonymous: 302 -> " <> loginUrl <> " ok")
            secret <- ops ^. #newSecret
            let email = "route-check-" <> T.take 12 secret <> "@example.test"
                password = "Rc-" <> secret
            created <- (ops ^. #createUser) email password
            case created of
              Left detail -> pure (Left (UserNotCreated detail))
              Right user -> do
                granted <- (ops ^. #grant) user
                case granted of
                  Left detail -> pure (Left (GrantFailed detail))
                  Right () -> do
                    say ("granted " <> user <> " on " <> check ^. #host)
                    session <- login loginUrl email password
                    case session of
                      Left failure -> pure (Left failure)
                      Right jar -> do
                        served <- untilStatus (check ^. #grantWait) jar (== 200)
                        case served of
                          Just response
                            | (check ^. #expectBody) `T.isInfixOf` (response ^. #body) -> do
                                say ("login as " <> email <> ": 200 ok")
                                revoked <- (ops ^. #revoke) user
                                case revoked of
                                  Left detail -> pure (Left (RevokeFailed detail))
                                  Right () -> do
                                    denied <- untilStatus (check ^. #revokeWait) jar (== 403)
                                    case denied of
                                      Just _ -> say "after revoke: 403 ok" >> pure (Right ())
                                      Nothing -> Left . either (const (RevokeNotEnforced 0)) (RevokeNotEnforced . (^. #status)) <$> (ops ^. #http) (check ^. #trust) (get root jar)
                            | otherwise -> pure (Left (ProtectedNotServed 200 "the body lacks the expected text"))
                          Nothing -> do
                            last' <- (ops ^. #http) (check ^. #trust) (get root jar)
                            pure (Left (either (ProtectedNotServed 0 . tshow) (\r -> ProtectedNotServed (r ^. #status) (T.take 120 (r ^. #body))) last'))
  where
    root = "https://" <> check ^. #host <> "/"
    say = ops ^. #progress
    get target jar = HttpRequest "GET" target jar []
    request req =
      (ops ^. #http) (check ^. #trust) req <&> \case
        Left (TlsRejected detail) -> Left (CertificateNotTrusted detail)
        Left (Unreachable detail) -> Left (RouteUnreachable detail)
        Right response -> Right response
    login loginUrl email password = do
      formPage <- request (get loginUrl [])
      case formPage of
        Left failure -> pure (Left failure)
        Right page
          | page ^. #status /= 200 -> pure (Left (LoginFormUnusable ("GET returned " <> tshow (page ^. #status))))
          | otherwise -> case (lookup "__Host-nagare_csrf" (responseCookies page), formCsrf (page ^. #body)) of
              (Just cookie, Just token) | cookie == token -> do
                let submit =
                      HttpRequest
                        "POST"
                        ("https://" <> check ^. #host <> "/_nagare/login")
                        [("__Host-nagare_csrf", cookie)]
                        [("csrf", token), ("rd", "/"), ("email", email), ("password", password)]
                submitted <- request submit
                pure $ case submitted of
                  Left failure -> Left failure
                  Right response
                    | response ^. #status == 302
                    , Just sessionCookie <- lookup "nagare_session" (responseCookies response) ->
                        Right (("nagare_session", sessionCookie) : [cookie' | cookie'@("nagare_refresh", _) <- responseCookies response])
                    | otherwise -> Left (LoginRejected (response ^. #status))
              _ -> pure (Left (LoginFormUnusable "no matching CSRF cookie and form token"))
    untilStatus remaining jar wanted = do
      answer <- (ops ^. #http) (check ^. #trust) (get root jar)
      case answer of
        Right response | wanted (response ^. #status) -> pure (Just response)
        _
          | remaining <= 0 -> pure Nothing
          | otherwise -> ops ^. #pause >> untilStatus (remaining - 1) jar wanted

-- | The login page an anonymous request is sent to: the enforcer's built-in
-- form on the same host (@/_nagare/login?rd=…@, relative or absolute). A
-- redirect to another host is an operator portal, which this stage does not
-- drive.
loginTarget :: Text -> HttpResponse -> Either RouteFailure Text
loginTarget host' response
  | response ^. #status /= 302 = Left (NotRedirectedToLogin (response ^. #status) location)
  | otherwise = case location of
      Just path
        | "/_nagare/login" `T.isPrefixOf` path -> Right (origin <> path)
        | (origin <> "/_nagare/login") `T.isPrefixOf` path -> Right path
        | "https://" `T.isPrefixOf` path -> Left (PortalLoginUnsupported path)
      _ -> Left (NotRedirectedToLogin 302 location)
  where
    origin = "https://" <> host'
    location = lookup "location" (response ^. #headers)

-- | The hidden @csrf@ input of the built-in login form.
formCsrf :: Text -> Maybe Text
formCsrf page = case T.breakOn "name=\"csrf\" value=\"" page of
  (_, rest) | not (T.null rest) -> Just (T.takeWhile (/= '"') (T.drop (T.length "name=\"csrf\" value=\"") rest))
  _ -> Nothing

-- | Each @Set-Cookie@'s name and value.
responseCookies :: HttpResponse -> [(Text, Text)]
responseCookies response =
  [ (T.strip name, T.drop 1 value)
  | ("set-cookie", line) <- response ^. #headers
  , let (name, value) = T.breakOn "=" (T.takeWhile (/= ';') line)
  , not (T.null value)
  ]

-- | A header block as curl's @-D@ writes it: the status line, then one
-- header per line. Only the last block counts.
parseHeaders :: Text -> [(Text, Text)]
parseHeaders raw =
  [ (T.toLower (T.strip name), T.strip (T.drop 1 value))
  | line <- lastBlock
  , let (name, value) = T.breakOn ":" line
  , not (T.null value)
  ]
  where
    lastBlock = case reverse (filter (any ("HTTP/" `T.isPrefixOf`)) (blocks (map (T.dropWhileEnd (== '\r')) (T.lines raw)))) of
      block : _ -> drop 1 block
      [] -> []
    blocks = foldr (\line acc -> if T.null line then [] : acc else case acc of current : rest -> (line : current) : rest; [] -> [[line]]) []

-- | The user id @shomei-admin users create@ prints: @created user ID <login>@.
parseCreatedUser :: Text -> Either Text Text
parseCreatedUser output = case find ("created user " `T.isPrefixOf`) (map T.strip (T.lines output)) of
  Just line ->
    let identity = T.filter (\c -> isAlphaNum c || c == '_' || c == '-') (T.takeWhile (not . isSpace) (T.drop (T.length "created user ") line))
     in if "user_" `T.isPrefixOf` identity then Right identity else Left ("unexpected user id in: " <> line)
  Nothing -> Left ("shomei-admin printed no created user: " <> T.strip output)

-- | curl's exit codes for a failed TLS handshake or certificate check, and
-- for a request that never reached a server.
curlFailure :: Int -> Text -> HttpError
curlFailure code detail
  | code `elem` [35, 51, 53, 54, 58, 59, 60, 64, 66, 77, 80, 82, 83, 90, 91] = TlsRejected (tshow code <> ": " <> detail)
  | otherwise = Unreachable (tshow code <> ": " <> detail)

-- | Where the stage runs: the Nagare context for reviewed commands, its
-- kubectl context, the nagarectl binary, and an optional local port that
-- forwards to the ingress (the loopback domain's port 443 can belong to a
-- host proxy, so the local check connects through a Kourier port-forward
-- while still verifying the certificate for the real host).
data Environment = Environment
  { context :: !Text
  , kubeContext :: !Text
  , nagarectl :: !FilePath
  , connectTo :: !(Maybe Int)
  , enUrl :: !Text
  , enApiKey :: !Text
  , reviews :: !FilePath
  }
  deriving stock (Eq, Show, Generic)

ioRouteOps :: Environment -> Text -> RouteOps
ioRouteOps environment host' =
  RouteOps
    { http = curl
    , createUser = \email password -> do
        (code, out, err) <-
          readProcessWithExitCode
            "kubectl"
            ["--context", T.unpack (environment ^. #kubeContext), "-n", "nagare-system", "exec", "-i", "deploy/shomei", "--", "env", "LC_ALL=C.UTF-8", "shomei-admin", "users", "create", "--email", T.unpack email, "--display-name", "route check", "--email-verified"]
            (T.unpack password <> "\n")
        pure $ case code of
          ExitSuccess -> parseCreatedUser (T.pack out)
          ExitFailure _ -> Left (T.strip (T.pack err))
    , grant = reviewed "grant"
    , revoke = reviewed "revoke"
    , newSecret = T.pack . concatMap show <$> replicateM 4 (uniformM globalStdGen :: IO Word)
    , pause = threadDelay 1_000_000
    , progress = \line -> TIO.putStrLn ("route " <> line)
    }
  where
    curl trust' req = do
      tmp <- getTemporaryDirectory
      bracket (openTempFile tmp "route-headers") (\(path, _) -> removeFile path) $ \(headerPath, headerHandle) -> do
        hClose headerHandle
        let trustArgs = case trust' of
              SystemTrust -> []
              CaFile path -> ["--cacert", path]
            connectArgs = maybe [] (\port -> ["--connect-to", T.unpack host' <> ":443:127.0.0.1:" <> show port]) (environment ^. #connectTo)
            cookieArgs = if null (req ^. #cookies) then [] else ["-H", T.unpack ("Cookie: " <> T.intercalate "; " [k <> "=" <> v | (k, v) <- req ^. #cookies])]
            formArgs = concat [["--data-urlencode", T.unpack (k <> "=" <> v)] | (k, v) <- req ^. #form]
            args =
              ["-sS", "--max-time", "20", "-X", T.unpack (req ^. #method), "-D", headerPath, "-o", "-", "-w", "\n%{http_code}"]
                <> trustArgs
                <> connectArgs
                <> cookieArgs
                <> formArgs
                <> [T.unpack (req ^. #url)]
        (code, out, err) <- readProcessWithExitCode "curl" args ""
        rawHeaders <- TIO.readFile headerPath
        pure $ case code of
          ExitSuccess ->
            let (content, statusLine) = T.breakOnEnd "\n" (T.pack out)
             in case reads (T.unpack statusLine) of
                  [(statusCode, "")] -> Right (HttpResponse statusCode (parseHeaders rawHeaders) (T.dropEnd 1 content))
                  _ -> Left (Unreachable ("curl printed no status: " <> statusLine))
          ExitFailure n -> Left (curlFailure n (T.strip (T.pack err)))
    reviewed verb user = do
      let dir = environment ^. #reviews <> "/route-check-" <> T.unpack verb <> "-" <> T.unpack user
          env' = [("NAGARE_EN_URL", T.unpack (environment ^. #enUrl)), ("NAGARE_EN_API_KEY", T.unpack (environment ^. #enApiKey))]
          run args = do
            inherited <- getEnvironment
            (code, out, err) <- readCreateProcessWithExitCode ((proc (environment ^. #nagarectl) (["--context", T.unpack (environment ^. #context)] <> args)) {env = Just (env' <> filter ((`notElem` map fst env') . fst) inherited)}) ""
            pure $ case code of
              ExitSuccess -> Right ()
              ExitFailure _ -> Left (lastLine (T.pack (out <> err)))
      saved <- run ["access", T.unpack verb, "--host", T.unpack host', "--user", T.unpack user, "--save-plan", dir]
      case saved of
        Left detail -> pure (Left ("save: " <> detail))
        Right () -> first ("apply: " <>) <$> run ["inventory", "apply", dir, "--yes"]
    lastLine text' = case reverse (filter (not . T.null) (map T.strip (T.lines text'))) of
      line : _ -> line
      [] -> "no output"

-- | The local context's CA, as @just local-bootstrap@ installs it, written to
-- a temporary PEM file.
localCa :: Text -> IO (Either Text FilePath)
localCa kubeContext' = do
  (code, out, err) <- readProcessWithExitCode "kubectl" ["--context", T.unpack kubeContext', "-n", "cert-manager", "get", "secret", "nagare-local-ca", "-o", "jsonpath={.data.tls\\.crt}"] ""
  case code of
    ExitFailure _ -> pure (Left ("cannot read Secret cert-manager/nagare-local-ca: " <> T.strip (T.pack err)))
    ExitSuccess -> do
      (decoded, pem, decodeErr) <- readProcessWithExitCode "base64" ["-d"] out
      case decoded of
        ExitSuccess | "BEGIN CERTIFICATE" `T.isInfixOf` T.pack pem -> Right <$> writeTemp "nagare-local-ca.pem" (T.pack pem)
        _ -> pure (Left ("Secret cert-manager/nagare-local-ca holds no certificate: " <> T.strip (T.pack decodeErr)))

writeTemp :: String -> Text -> IO FilePath
writeTemp template content = do
  tmp <- getTemporaryDirectory
  (path, handle) <- openTempFile tmp template
  TIO.hPutStr handle content
  hClose handle
  pure path

-- | Run an action with @kubectl port-forward@ open on a local port, then stop
-- exactly that process.
withPortForward :: Text -> Text -> Text -> Int -> Int -> IO a -> IO a
withPortForward kubeContext' namespace' service localPort remotePort action =
  bracket start stop (const (waitOpen (30 :: Int) >> action))
  where
    start :: IO ProcessHandle
    start = do
      (_, _, _, handle) <-
        createProcess
          (proc "kubectl" ["--context", T.unpack kubeContext', "-n", T.unpack namespace', "port-forward", "svc/" <> T.unpack service, show localPort <> ":" <> show remotePort])
            { std_out = NoStream
            , std_err = NoStream
            }
      pure handle
    stop handle = terminateProcess handle >> waitForProcess handle >> pure ()
    waitOpen remaining = do
      (code, _, _) <- readProcessWithExitCode "nc" ["-z", "127.0.0.1", show localPort] ""
      unless (code == ExitSuccess || remaining <= 0) (threadDelay 500_000 >> waitOpen (remaining - 1))

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | A throwaway self-signed CA that signed nothing Nagare serves: the wrong
-- trust anchor of check 1. Its key was discarded when it was made.
wrongCaPem :: Text
wrongCaPem =
  T.unlines
    [ "-----BEGIN CERTIFICATE-----"
    , "MIIBPDCB5AIJALTOvyDsn5FyMAoGCCqGSM49BAMCMCYxJDAiBgNVBAMMG25hZ2Fy"
    , "ZS1yb3V0ZS1jaGVjay13cm9uZy1jYTAgFw0yNjEwMTAwMzA4NTRaGA8yMTI2MDkx"
    , "NjAzMDg1NFowJjEkMCIGA1UEAwwbbmFnYXJlLXJvdXRlLWNoZWNrLXdyb25nLWNh"
    , "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEcWt9NI4JB300+DztFnuh02UwMLPr"
    , "UJFz+6Q9XZZK9hWB5gaJbrn1Q1vAZ7hyAqM+pfUkcZT+WA/VsJFVhmYDxTAKBggq"
    , "hkjOPQQDAgNHADBEAiBYIkLeBQQinkBdAZfORLUAaDssARvr2PY8r75r4d8lEAIg"
    , "behiOUvww2AQZZQ2IHPYWr58uNhSrrZ+PlTsKPgfyJs="
    , "-----END CERTIFICATE-----"
    ]

-- | The command line's choices.
data RouteCheckOptions = RouteCheckOptions
  { context :: !Text
  , kubeContext :: !Text
  , host :: !Text
  , ca :: !(Maybe FilePath)
  , systemTrust :: !Bool
  , ingressPort :: !(Maybe Int)
  , expectBody :: !Text
  , nagarectl :: !FilePath
  , reviews :: !FilePath
  }
  deriving stock (Eq, Show, Generic)

-- | Run the stage against a context: read the trust anchor (the local CA by
-- default, the system store with @--system-trust@, or @--ca FILE@), open the
-- En and (optionally) ingress port-forwards, and report pass or the named
-- failure.
routeCheckMain :: RouteCheckOptions -> IO Bool
routeCheckMain options = do
  trust' <- case (options ^. #ca, options ^. #systemTrust) of
    (Just path, _) -> pure (Right (CaFile path))
    (Nothing, True) -> pure (Right SystemTrust)
    (Nothing, False) -> fmap CaFile <$> localCa (options ^. #kubeContext)
  apiKey <- readEnApiKey (options ^. #kubeContext)
  case (trust', apiKey) of
    (Left err, _) -> report (CertificateNotTrusted err)
    (_, Left err) -> report (GrantFailed err)
    (Right trusted, Right key) -> do
      wrong <- writeTemp "route-check-wrong-ca.pem" wrongCaPem
      let enPort = 18082
          environment =
            Environment
              { context = options ^. #context
              , kubeContext = options ^. #kubeContext
              , nagarectl = options ^. #nagarectl
              , connectTo = options ^. #ingressPort
              , enUrl = "http://127.0.0.1:" <> tshow enPort
              , enApiKey = key
              , reviews = options ^. #reviews
              }
          check = RouteCheck (options ^. #host) trusted (CaFile wrong) (options ^. #expectBody) 60 120
          ingress action = case options ^. #ingressPort of
            Just port -> withPortForward (options ^. #kubeContext) "kourier-system" "kourier" port 443 action
            Nothing -> action
      outcome <- withPortForward (options ^. #kubeContext) "nagare-system" "en" enPort 80 (ingress (runRouteCheck (ioRouteOps environment (options ^. #host)) check))
      either report (const (TIO.putStrLn "route check: ok" >> pure True)) outcome
  where
    report failure = TIO.putStrLn ("route check: failed: " <> renderFailure failure) >> pure False

readEnApiKey :: Text -> IO (Either Text Text)
readEnApiKey kubeContext' = do
  (code, out, err) <- readProcessWithExitCode "kubectl" ["--context", T.unpack kubeContext', "-n", "nagare-system", "get", "secret", "nagare-en-api-keys", "-o", "jsonpath={.data.read-write}"] ""
  case code of
    ExitFailure _ -> pure (Left ("cannot read Secret nagare-system/nagare-en-api-keys: " <> T.strip (T.pack err)))
    ExitSuccess -> do
      (decoded, key, _) <- readProcessWithExitCode "base64" ["-d"] out
      pure $ if decoded == ExitSuccess && not (T.null (T.strip (T.pack key))) then Right (T.strip (T.pack key)) else Left "the En read-write API key is empty"
