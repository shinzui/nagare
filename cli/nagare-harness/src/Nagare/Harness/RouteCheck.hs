-- | EP-183 M1, extended by EP-188 M3: a protected route is checked over
-- verified HTTPS, never assumed. The stage proves, in order, against one
-- @requireLogin@ host:
--
-- 1. certificate verification is enforced: the same request with a
--    deliberately wrong trust anchor is refused;
-- 2. an anonymous document request is redirected to the login page, and an
--    anonymous API request gets 401;
-- 3. a scripted login of a disposable user without a grant gets 403, and the
--    effective-access diagnostic says denied;
-- 4. after a reviewed grant (direct, or a team membership plus a team grant)
--    the same session reaches the app and the diagnostic says allowed; on
--    the team path a member of another team is refused;
-- 5. after a reviewed revoke (or removal from the team) the diagnostic says
--    denied at once, and the session gets 403 within the enforcer's decision
--    cache.
--
-- The checks are pure over 'RouteOps', so each named failure has a test with
-- a scripted world; 'ioRouteOps' runs them with curl, kubectl and nagarectl.
-- No request skips certificate verification.
module Nagare.Harness.RouteCheck
  ( RouteCheck (..)
  , GrantPath (..)
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
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT, throwE)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.Char (isAlphaNum, isSpace)
import Data.Generics.Labels ()
import Data.List (find)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
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
  , headers :: ![(Text, Text)]
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
  , routeWait :: !Int
  -- ^ Seconds a just-deployed route may answer 502 before the enforcer has
  -- its backend: the kubelet's ConfigMap sync plus the enforcer's re-read.
  , grantWait :: !Int
  -- ^ Seconds to wait for a new grant to reach the enforcer (En publishes
  -- on a short interval).
  , revokeWait :: !Int
  -- ^ Seconds to wait for a revoke: En's publish lag plus the enforcer's
  -- 30-second decision cache.
  , grantPath :: !GrantPath
  }
  deriving stock (Eq, Show, Generic)

-- | How the checked user receives the host: a direct grant, or membership in
-- a team the host is granted to, beside a second team that holds nothing,
-- whose member must be refused.
data GrantPath = DirectGrant | TeamGrant !Text !Text
  deriving stock (Eq, Show)

-- | Everything the stage does to the world.
data RouteOps = RouteOps
  { http :: !(Trust -> HttpRequest -> IO (Either HttpError HttpResponse))
  , createUser :: !(Text -> Text -> IO (Either Text Text))
  -- ^ Email and password to the new user's id.
  , grant :: !(Text -> IO (Either Text ()))
  -- ^ A reviewed grant of the host to a user id, saved and applied.
  , revoke :: !(Text -> IO (Either Text ()))
  , addMember :: !(Text -> Text -> IO (Either Text ()))
  -- ^ A reviewed membership of a user id in a team, saved and applied.
  , removeMember :: !(Text -> Text -> IO (Either Text ()))
  , grantTeam :: !(Text -> IO (Either Text ()))
  -- ^ A reviewed grant of the host to a team.
  , checkAccess :: !(Text -> IO (Either Text Text))
  -- ^ The effective-access diagnostic's decision word for a user id.
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
  | ApiNotUnauthorized !Int
  | UngrantedServed !Int
  | StrangerServed !Int
  | TeamStepFailed !Text
  | CheckFailed !Text !Text
  | CheckMismatch !Text !Text !Text
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
  ApiNotUnauthorized code -> "an anonymous API request was not refused with 401: " <> tshow code
  UngrantedServed code -> "a signed-in user without a grant was not refused with 403: " <> tshow code
  StrangerServed code -> "a member of a team without a grant was not refused with 403: " <> tshow code
  TeamStepFailed detail -> "the reviewed team step failed: " <> detail
  CheckFailed user detail -> "access check for " <> user <> " gave no decision: " <> detail
  CheckMismatch user wanted got -> "access check for " <> user <> " said " <> got <> ", not " <> wanted

runRouteCheck :: RouteOps -> RouteCheck -> IO (Either RouteFailure ())
runRouteCheck ops check = runExceptT $ do
  wrong <- lift ((ops ^. #http) (check ^. #wrongTrust) (get root []))
  case wrong of
    Right _ -> throwE VerificationNotEnforced
    Left (Unreachable detail) -> throwE (RouteUnreachable detail)
    Left (TlsRejected _) -> pure ()
  say "a wrong trust anchor is refused ok"
  anonymous <- ExceptT (awaitRoute (check ^. #routeWait))
  loginUrl <- except (loginTarget host anonymous)
  say ("anonymous: 302 -> " <> loginUrl <> " ok")
  api <- request (HttpRequest "GET" root [] [] [("Accept", "application/json")])
  unless (api ^. #status == 401) (throwE (ApiNotUnauthorized (api ^. #status)))
  say "anonymous API request: 401 ok"
  (email, password, user) <- newUser
  jar <- login loginUrl email password
  ungranted <- request (get root jar)
  unless (ungranted ^. #status == 403) (throwE (UngrantedServed (ungranted ^. #status)))
  expectCheck user "denied"
  say ("login as " <> email <> " without a grant: 403, check denied ok")
  case check ^. #grantPath of
    DirectGrant -> do
      step GrantFailed ((ops ^. #grant) user)
      say ("granted " <> user <> " on " <> host)
    TeamGrant team _ -> do
      step TeamStepFailed ((ops ^. #addMember) team user)
      step TeamStepFailed ((ops ^. #grantTeam) team)
      say (user <> " joined team " <> team <> ", which is granted " <> host)
  served <- lift (untilStatus (check ^. #grantWait) jar (== 200))
  case served of
    Just response
      | (check ^. #expectBody) `T.isInfixOf` (response ^. #body) -> pure ()
      | otherwise -> throwE (ProtectedNotServed 200 "the body lacks the expected text")
    Nothing -> do
      last' <- lift ((ops ^. #http) (check ^. #trust) (get root jar))
      throwE (either (ProtectedNotServed 0 . tshow) (\r -> ProtectedNotServed (r ^. #status) (T.take 120 (r ^. #body))) last')
  expectCheck user "allowed"
  say "granted session: 200, check allowed ok"
  case check ^. #grantPath of
    DirectGrant -> pure ()
    TeamGrant _ other -> do
      (strangerEmail, strangerPassword, stranger) <- newUser
      step TeamStepFailed ((ops ^. #addMember) other stranger)
      strangerJar <- login loginUrl strangerEmail strangerPassword
      answer <- request (get root strangerJar)
      unless (answer ^. #status == 403) (throwE (StrangerServed (answer ^. #status)))
      expectCheck stranger "denied"
      say ("a member of team " <> other <> ": 403, check denied ok")
  case check ^. #grantPath of
    DirectGrant -> step RevokeFailed ((ops ^. #revoke) user)
    TeamGrant team _ -> step RevokeFailed ((ops ^. #removeMember) team user)
  expectCheck user "denied"
  say "after revoke: check denied at once"
  denied <- lift (untilStatus (check ^. #revokeWait) jar (== 403))
  case denied of
    Just _ -> say "after revoke: 403 ok"
    Nothing -> do
      last' <- lift ((ops ^. #http) (check ^. #trust) (get root jar))
      throwE (either (const (RevokeNotEnforced 0)) (RevokeNotEnforced . (^. #status)) last')
  where
    host = check ^. #host
    root = "https://" <> host <> "/"
    say = lift . (ops ^. #progress)
    get target jar = HttpRequest "GET" target jar [] []
    step wrap action = lift action >>= either (throwE . wrap) pure
    newUser = do
      secret <- lift (ops ^. #newSecret)
      let email = "route-check-" <> T.take 12 secret <> "@example.test"
          password = "Rc-" <> secret
      user <- step UserNotCreated ((ops ^. #createUser) email password)
      pure (email, password, user)
    expectCheck user wanted = do
      got <- step (CheckFailed user) ((ops ^. #checkAccess) user)
      unless (got == wanted) (throwE (CheckMismatch user wanted got))
    requestIO req =
      (ops ^. #http) (check ^. #trust) req <&> \case
        Left (TlsRejected detail) -> Left (CertificateNotTrusted detail)
        Left (Unreachable detail) -> Left (RouteUnreachable detail)
        Right response -> Right response
    request = ExceptT . requestIO
    login loginUrl email password = do
      page <- request (get loginUrl [])
      when (page ^. #status /= 200) (throwE (LoginFormUnusable ("GET returned " <> tshow (page ^. #status))))
      case (lookup "__Host-nagare_csrf" (responseCookies page), formCsrf (page ^. #body)) of
        (Just cookie, Just token) | cookie == token -> do
          submitted <-
            request
              ( HttpRequest
                  "POST"
                  ("https://" <> host <> "/_nagare/login")
                  [("__Host-nagare_csrf", cookie)]
                  [("csrf", token), ("rd", "/"), ("email", email), ("password", password)]
                  []
              )
          case lookup "nagare_session" (responseCookies submitted) of
            Just sessionCookie | submitted ^. #status == 302 -> pure (("nagare_session", sessionCookie) : [cookie' | cookie'@("nagare_refresh", _) <- responseCookies submitted])
            _ -> throwE (LoginRejected (submitted ^. #status))
        _ -> throwE (LoginFormUnusable "no matching CSRF cookie and form token")
    awaitRoute remaining = do
      answer <- requestIO (get root [])
      case answer of
        Right response
          | response ^. #status == 502
          , remaining > 0 ->
              ops ^. #pause >> awaitRoute (remaining - 1)
        _ -> pure answer
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
    , grant = \user -> reviewed ("grant-" <> user) ["access", "grant", "--host", T.unpack host', "--user", T.unpack user]
    , revoke = \user -> reviewed ("revoke-" <> user) ["access", "revoke", "--host", T.unpack host', "--user", T.unpack user]
    , addMember = \team user -> reviewed ("add-member-" <> team <> "-" <> user) ["access", "team", "add-member", "--team", T.unpack team, "--user", T.unpack user]
    , removeMember = \team user -> reviewed ("remove-member-" <> team <> "-" <> user) ["access", "team", "remove-member", "--team", T.unpack team, "--user", T.unpack user]
    , grantTeam = \team -> reviewed ("grant-team-" <> team) ["access", "grant", "--host", T.unpack host', "--team", T.unpack team]
    , checkAccess = \user -> fmap (>>= decisionWord) (run ["access", "check", "--host", T.unpack host', "--user", T.unpack user, "--json"])
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
            headerArgs = concat [["-H", T.unpack (k <> ": " <> v)] | (k, v) <- req ^. #headers]
            formArgs = concat [["--data-urlencode", T.unpack (k <> "=" <> v)] | (k, v) <- req ^. #form]
            args =
              ["-sS", "--max-time", "20", "-X", T.unpack (req ^. #method), "-D", headerPath, "-o", "-", "-w", "\n%{http_code}"]
                <> trustArgs
                <> connectArgs
                <> cookieArgs
                <> headerArgs
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
    -- A reviewed command: saved under the reviews directory, then applied.
    reviewed label args = do
      let dir = environment ^. #reviews <> "/route-check-" <> T.unpack label
      saved <- run (args <> ["--save-plan", dir])
      case saved of
        Left detail -> pure (Left ("save: " <> detail))
        Right _ -> first ("apply: " <>) . fmap (const ()) <$> run ["inventory", "apply", dir, "--yes"]
    -- nagarectl in the context, with the private En address and key; its
    -- stdout on success, its last line on failure.
    run args = do
      let env' = [("NAGARE_EN_URL", T.unpack (environment ^. #enUrl)), ("NAGARE_EN_API_KEY", T.unpack (environment ^. #enApiKey))]
      inherited <- getEnvironment
      (code, out, err) <- readCreateProcessWithExitCode ((proc (environment ^. #nagarectl) (["--context", T.unpack (environment ^. #context)] <> args)) {env = Just (env' <> filter ((`notElem` map fst env') . fst) inherited)}) ""
      pure $ case code of
        ExitSuccess -> Right (T.pack out)
        ExitFailure _ -> Left (lastLine (T.pack (out <> err)))
    -- The decision of @access check --json@: its one JSON line.
    decisionWord out = case [line | line <- T.lines out, "{" `T.isPrefixOf` line] of
      line : _ | Right (Object report) <- eitherDecodeStrict (TE.encodeUtf8 line), Just (String word) <- KM.lookup "decision" report -> Right word
      _ -> Left ("access check printed no decision: " <> T.take 200 (T.strip out))
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
  , team :: !(Maybe Text)
  -- ^ Grant through this team instead of directly (EP-188 M3).
  , otherTeam :: !Text
  -- ^ A team the host is never granted to, whose member must be refused.
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
          path = maybe DirectGrant (\team' -> TeamGrant team' (options ^. #otherTeam)) (options ^. #team)
          check = RouteCheck (options ^. #host) trusted (CaFile wrong) (options ^. #expectBody) 180 60 120 path
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
