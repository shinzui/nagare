-- | EP-174 M5: run every fixture application locally with only the bindings
-- its configuration declares before any cluster sees it. On 2026-10-04 a
-- fixture image bound to the wrong store crash-looped on a cloud context and
-- wedged it (F54's trigger); this smoke would have failed it in a minute.
module Nagare.Harness.FixtureSmoke
  ( Binding (..)
  , Entry (..)
  , Manifest (..)
  , Negative (..)
  , Probe (..)
  , Service (..)
  , bindingEnvironment
  , runFixtureSmoke
  , serviceFor
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (finally)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.Aeson (FromJSON, eitherDecodeFileStrict)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (nub)
import Data.Text qualified as T
import Nagare.Harness.Prelude
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (readProcessWithExitCode)
import System.Random.Stateful (globalStdGen, uniformM)

data Probe = Probe
  { path :: !Text
  , status :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

-- | One environment variable the application reads, and the backing service
-- whose URL it carries.
data Binding = Binding
  { env :: !Text
  , service :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

-- | A fixture application. An entry with @skip@ is listed so the manifest
-- accounts for every fixture, and states why it has no process to run.
data Entry = Entry
  { name :: !Text
  , directory :: !FilePath
  , port :: !(Maybe Int)
  , probe :: !(Maybe Probe)
  , bindings :: !(Maybe [Binding])
  , skip :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

-- | A deliberately wrong binding that must fail, so the smoke cannot pass
-- vacuously.
data Negative = Negative
  { name :: !Text
  , directory :: !FilePath
  , port :: !Int
  , probe :: !Probe
  , bindings :: ![Binding]
  , reason :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

data Manifest = Manifest
  { version :: !Int
  , entries :: ![Entry]
  , negative :: ![Negative]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

-- | A backing service: its image (the operator's engine versions), the
-- connection URL an application gets for it on the smoke network, extra
-- container environment, and a readiness command run inside it.
data Service = Service
  { image :: !Text
  , url :: !(Text -> Text)
  , containerEnv :: ![(Text, Text)]
  , ready :: ![Text]
  }
  deriving stock (Generic)

serviceFor :: Text -> Either Text Service
serviceFor = \case
  "postgres" ->
    Right
      Service
        { image = "postgres:18"
        , url = \host -> "postgresql://postgres:smoke@" <> host <> ":5432/postgres"
        , containerEnv = [("POSTGRES_PASSWORD", "smoke")]
        , ready = ["pg_isready", "-U", "postgres", "-h", "127.0.0.1"]
        }
  "redis" ->
    Right
      Service
        { image = "redis:8"
        , url = \host -> "redis://" <> host <> ":6379/0"
        , containerEnv = []
        , ready = ["redis-cli", "ping"]
        }
  "clickhouse" ->
    Right
      Service
        { image = "clickhouse/clickhouse-server:25"
        , url = \host -> "http://" <> host <> ":8123"
        , containerEnv = []
        , ready = ["clickhouse-client", "--query", "SELECT 1"]
        }
  other -> Left ("unknown backing service " <> other)

-- | The application's environment: each binding's variable set to its
-- service's URL, where @host@ names that service's container.
bindingEnvironment :: (Text -> Text) -> [Binding] -> Either Text [(Text, Text)]
bindingEnvironment host = traverse $ \binding -> do
  svc <- serviceFor (binding ^. #service)
  pure (binding ^. #env, url svc (host (binding ^. #service)))

docker :: [Text] -> IO (ExitCode, Text, Text)
docker arguments = do
  (code, out, err) <- readProcessWithExitCode "docker" (map T.unpack arguments) ""
  pure (code, T.pack out, T.pack err)

dockerOk :: [Text] -> IO (Either Text Text)
dockerOk arguments = do
  (code, out, err) <- docker arguments
  pure $ case code of
    ExitSuccess -> Right (T.strip out)
    ExitFailure _ -> Left ("docker " <> T.unwords (take 2 arguments) <> ": " <> T.strip err)

-- | Things started by one run, removed even when the run fails.
data Started = Started
  { containers :: ![Text]
  , networks :: ![Text]
  , images :: ![Text]
  }
  deriving stock (Generic)

cleanup :: IORef Started -> IO ()
cleanup ref = do
  started <- readIORef ref
  unless (null (started ^. #containers)) $ void' (docker (["rm", "-f"] <> started ^. #containers))
  forM_ (started ^. #networks) $ \network -> void' (docker ["network", "rm", network])
  forM_ (nub (started ^. #images)) $ \tag -> void' (docker ["rmi", tag])
  where
    void' action = action >> pure ()

-- | Retry @action@ once a second for up to @seconds@.
within :: Int -> IO (Either Text a) -> IO (Either Text a)
within seconds action = go seconds
  where
    go remaining = do
      result <- action
      case result of
        Right value -> pure (Right value)
        Left err
          | remaining <= 1 -> pure (Left err)
          | otherwise -> threadDelay 1000000 >> go (remaining - 1)

httpStatus :: Text -> IO (Either Text Int)
httpStatus target = do
  (code, out, _) <- readProcessWithExitCode "curl" ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "2", T.unpack target] ""
  pure $ case (code, reads out) of
    (ExitSuccess, [(n, "")]) | n /= (0 :: Int) -> Right n
    _ -> Left ("no HTTP response from " <> target)

-- | Build, bind, start and probe one application. @Right ()@ means it served
-- the expected status within 60 seconds.
smokeOne :: FilePath -> Text -> Text -> FilePath -> Int -> Probe -> [Binding] -> IO (Either Text ())
smokeOne base runId label dir appPort expected binds = do
  ref <- newIORef (Started [] [] [])
  let network = "nagare-smoke-" <> runId <> "-" <> label
      container suffix = network <> "-" <> suffix
      tag = "nagare-smoke/" <> label <> ":" <> runId
      record field value = modifyIORef' ref (field %~ (value :))
  flip finally (cleanup ref) $ runExceptT $ do
    _ <- ExceptT (dockerOk ["build", "-q", "-t", tag, T.pack (base </> dir)])
    lift (record #images tag)
    _ <- ExceptT (dockerOk ["network", "create", network])
    lift (record #networks network)
    let services = nub (map (^. #service) binds)
    forM_ services $ \name' -> do
      svc <- except (serviceFor name')
      let svcContainer = container name'
      _ <-
        ExceptT . dockerOk $
          ["run", "-d", "--name", svcContainer, "--network", network, "--network-alias", name']
            <> concat [["-e", k <> "=" <> v] | (k, v) <- containerEnv svc]
            <> [image svc]
      lift (record #containers svcContainer)
      ExceptT (within 60 (dockerOk (["exec", svcContainer] <> ready svc)))
    environment <- except (bindingEnvironment id binds)
    let appContainer = container "app"
    _ <-
      ExceptT . dockerOk $
        ["run", "-d", "--name", appContainer, "--network", network, "-p", "127.0.0.1::" <> T.pack (show appPort)]
          <> concat [["-e", k <> "=" <> v] | (k, v) <- environment]
          <> [tag]
    lift (record #containers appContainer)
    published <- ExceptT (dockerOk ["port", appContainer, T.pack (show appPort) <> "/tcp"])
    let hostPort = T.takeWhileEnd (/= ':') (head' (T.lines published))
        target = "http://127.0.0.1:" <> hostPort <> expected ^. #path
    ExceptT . within 60 $ do
      running <- dockerOk ["inspect", "-f", "{{.State.Running}}", appContainer]
      case running of
        Right "true" -> do
          answer <- httpStatus target
          pure $ case answer of
            Right got
              | got == expected ^. #status -> Right ()
              | otherwise -> Left ("probe " <> target <> " answered " <> T.pack (show got))
            Left err -> Left err
        _ -> do
          (_, logs, logErr) <- docker ["logs", "--tail", "20", appContainer]
          pure (Left ("the application exited:\n" <> T.strip (logs <> logErr)))
  where
    head' = \case
      (line : _) -> line
      [] -> ""

-- | Refuse a Docker daemon that hosts a k3d cluster (a local acceptance or
-- cp3 cluster) unless explicitly allowed: the smoke must not run beside a
-- cluster under verification.
sharedDaemon :: IO (Either Text ())
sharedDaemon = do
  names <- dockerOk ["ps", "--format", "{{.Names}}"]
  pure $ case names of
    Left err -> Left ("Docker is not reachable: " <> err)
    Right listing -> case filter ("k3d-" `T.isPrefixOf`) (T.lines listing) of
      [] -> Right ()
      clusters ->
        Left
          ( "this Docker daemon runs a k3d cluster ("
              <> T.intercalate ", " (take 3 clusters)
              <> "); point DOCKER_HOST at another daemon, or pass --allow-shared-daemon"
          )

-- | Smoke every runnable entry and the negative self-tests. Returns whether
-- everything behaved as expected.
runFixtureSmoke :: FilePath -> Bool -> IO Bool
runFixtureSmoke manifestPath allowShared = do
  guardResult <- if allowShared then pure (Right ()) else sharedDaemon
  case guardResult of
    Left err -> putStrLn ("fixture-smoke: refused: " <> T.unpack err) >> pure False
    Right () -> do
      decoded <- eitherDecodeFileStrict @Manifest manifestPath
      case decoded of
        Left err -> putStrLn ("fixture-smoke: " <> manifestPath <> ": " <> err) >> pure False
        Right manifest -> do
          runId <- T.pack . take 8 . show <$> uniformM @Word globalStdGen
          let base = takeDirectory manifestPath
          positives <- forM (manifest ^. #entries) $ \entry -> case entry ^. #skip of
            Just why -> do
              putStrLn ("fixture-smoke: " <> T.unpack (entry ^. #name) <> " skipped: " <> T.unpack why)
              pure True
            Nothing -> case (entry ^. #port, entry ^. #probe) of
              (Just appPort, Just expected) -> do
                result <- smokeOne base runId (entry ^. #name) (entry ^. #directory) appPort expected (fromMaybe [] (entry ^. #bindings))
                report (entry ^. #name) result
              _ -> do
                putStrLn ("fixture-smoke: " <> T.unpack (entry ^. #name) <> " FAIL: an entry without skip needs a port and a probe")
                pure False
          negatives <- forM (manifest ^. #negative) $ \bad -> do
            result <- smokeOne base runId (bad ^. #name) (bad ^. #directory) (bad ^. #port) (bad ^. #probe) (bad ^. #bindings)
            case result of
              Left err -> do
                putStrLn ("fixture-smoke: negative " <> T.unpack (bad ^. #name) <> " failed as required: " <> T.unpack (firstLine err))
                pure True
              Right () -> do
                putStrLn ("fixture-smoke: negative " <> T.unpack (bad ^. #name) <> " FAIL: it served, so the smoke cannot tell a wrong binding")
                pure False
          let green = and positives && and negatives
          putStrLn (if green then "fixture-smoke: green" else "fixture-smoke: RED")
          pure green
  where
    firstLine = T.takeWhile (/= '\n')
    report label = \case
      Right () -> putStrLn ("fixture-smoke: " <> T.unpack label <> " ok") >> pure True
      Left err -> putStrLn ("fixture-smoke: " <> T.unpack label <> " FAIL: " <> T.unpack err) >> pure False
