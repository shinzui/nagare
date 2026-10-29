-- | The process boundary of the release runner (EP-229). Every external
-- command the candidate, intranet and rehearsal commands run goes through a
-- 'Transport', so a test interprets the whole run with a recording fake and
-- the real interpreter is the only code that starts processes. A refusal is
-- a 'Refusal' exception: the command stops at its first one, its cleanup runs,
-- and @Main@ prints it with the command's prefix and exits 1.
module Nagare.Harness.Release.Process
  ( Invocation (..)
  , Environment (..)
  , Sink (..)
  , Result (..)
  , Transport (..)
  , Background (..)
  , Runtime (..)
  , Refusal (..)
  , invocation
  , runningIn
  , invoke
  , succeeds
  , capture
  , captureText
  , require
  , refuse
  , refusing
  , realRuntime
  , realTransport
  , lookupVariable
  , withVariable
  , stateDirectory
  , searchPath
  , lastLines
  , trimEnd
  , stampedLine
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Exception (Exception, IOException, catch, throwIO, try)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Harness.Prelude
import System.Directory (doesFileExist, executable, findExecutable, getPermissions)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (searchPathSeparator, (</>))
import System.IO (Handle, IOMode (AppendMode, ReadMode, WriteMode), hClose, hFlush, openFile, stderr, stdout)
import System.Process qualified as P

-- | One external command: what it is, where it runs, which environment it
-- gets and where its output goes.
data Invocation = Invocation
  { program :: !FilePath
  , arguments :: ![String]
  , directory :: !(Maybe FilePath)
  , environment :: !Environment
  , input :: !(Maybe ByteString)
  , stdoutTo :: !Sink
  , stderrTo :: !Sink
  }
  deriving stock (Eq, Show, Generic)

type ByteString = BS.ByteString

-- | The child's environment: this process's own, this process's with some
-- variables set, or exactly a list (the scripts' @env -i@).
data Environment
  = Inherited
  | Extended ![(String, String)]
  | Exactly ![(String, String)]
  deriving stock (Eq, Show, Generic)

-- | The invocation with one more variable in its environment.
withVariable :: String -> String -> Invocation -> Invocation
withVariable key value command =
  command & #environment %~ \case
    Inherited -> Extended [(key, value)]
    Extended variables -> Extended (filter ((/= key) . fst) variables <> [(key, value)])
    Exactly variables -> Exactly (filter ((/= key) . fst) variables <> [(key, value)])

-- | Where a stream goes. 'SameAsStdout' is for stderr only (@2>&1@); 'Tee'
-- copies the stream to this process's stdout and writes it to a file, as tee does.
data Sink
  = Inherit
  | Capture
  | Discard
  | WriteTo !FilePath
  | AppendTo !FilePath
  | Tee !FilePath
  | SameAsStdout
  deriving stock (Eq, Show, Generic)

-- | The exit code (127 when the program could not start) and the captured
-- bytes: stdout under 'Capture', merged with stderr under 'SameAsStdout'.
data Result = Result
  { exit :: !Int
  , output :: !ByteString
  }
  deriving stock (Eq, Show, Generic)

-- | A process started in the background (the release gate).
data Background = Background
  { finished :: !(IO Int)
  , stop :: !(IO ())
  }
  deriving stock (Generic)

data Transport = Transport
  { run :: !(Invocation -> IO Result)
  , spawn :: !(Invocation -> IO Background)
  }
  deriving stock (Generic)

-- | Everything a release command needs from the world besides files: the
-- transport, the clock, sleeping, its two output lines, the environment it
-- was started with, and its own executable (the rehearsal starts the drill
-- with it).
data Runtime = Runtime
  { transport :: !Transport
  , now :: !(IO UTCTime)
  , pause :: !(Int -> IO ())
  , say :: !(Text -> IO ())
  , warn :: !(Text -> IO ())
  , variables :: ![(String, String)]
  , harness :: !FilePath
  , locate :: !(String -> IO (Maybe FilePath))
  }
  deriving stock (Generic)

newtype Refusal = Refusal Text
  deriving stock (Show)
  deriving anyclass (Exception)

invocation :: FilePath -> [String] -> Invocation
invocation name args = Invocation name args Nothing Inherited Nothing Inherit Inherit

-- | Run every invocation that names no directory in @dir@, as a script does
-- after @cd@.
runningIn :: FilePath -> Runtime -> Runtime
runningIn dir runtime =
  runtime & #transport .~ Transport {run = place (runtime ^. #transport . #run), spawn = place (runtime ^. #transport . #spawn)}
  where
    place :: (Invocation -> IO a) -> Invocation -> IO a
    place f command = f (command & #directory %~ Just . fromMaybe dir)

invoke :: Runtime -> Invocation -> IO Result
invoke runtime = runtime ^. #transport . #run

-- | Whether the command exits 0.
succeeds :: Runtime -> Invocation -> IO Bool
succeeds runtime command = (== 0) . (^. #exit) <$> invoke runtime command

-- | The command's stdout, refusing with @message@ when it does not exit 0.
capture :: Runtime -> Text -> Invocation -> IO ByteString
capture runtime message command = do
  result <- invoke runtime (command & #stdoutTo .~ Capture)
  unless (result ^. #exit == 0) (refuse message)
  pure (result ^. #output)

-- | 'capture' as text without the trailing newlines, as @$(…)@ reads it.
captureText :: Runtime -> Text -> Invocation -> IO Text
captureText runtime message command = trimEnd . decodeLenient <$> capture runtime message command

-- | Run the command, refusing with @message@ unless it exits 0.
require :: Runtime -> Text -> Invocation -> IO ()
require runtime message command = do
  ok <- succeeds runtime command
  unless ok (refuse message)

refuse :: Text -> IO a
refuse = throwIO . Refusal

-- | Run a release command: a refusal prints @prefix: reason@ on stderr and
-- exits 1.
refusing :: Text -> IO () -> IO ()
refusing prefix action =
  action `catch` \(Refusal reason) -> do
    hFlush stdout
    TIO.hPutStrLn stderr (prefix <> ": " <> reason)
    exitWith (ExitFailure 1)

lookupVariable :: Runtime -> String -> Maybe String
lookupVariable runtime name = case lookup name (runtime ^. #variables) of
  Just "" -> Nothing
  other -> other

-- | @${XDG_STATE_HOME:-$HOME/.local/state}@.
stateDirectory :: Runtime -> FilePath
stateDirectory runtime =
  fromMaybe (fromMaybe "" (lookupVariable runtime "HOME") </> ".local/state") (lookupVariable runtime "XDG_STATE_HOME")

-- | The first executable named @name@ in a colon-separated search path.
searchPath :: String -> String -> IO (Maybe FilePath)
searchPath path name = go (splitPath path)
  where
    go [] = pure Nothing
    go (dir : rest) = do
      let candidate = dir </> name
      present <- doesFileExist candidate
      runnable <- if present then executable <$> getPermissions candidate else pure False
      if runnable then pure (Just candidate) else go rest
    splitPath = map T.unpack . filter (not . T.null) . T.splitOn (T.singleton searchPathSeparator) . T.pack

-- | The last @n@ lines of some output, as @tail -n@ prints them.
lastLines :: Int -> Text -> Text
lastLines n = T.intercalate "\n" . reverse . take n . reverse . T.lines

trimEnd :: Text -> Text
trimEnd = T.dropWhileEnd (== '\n')

-- | @<time> <label>: <message>@, the scripts' step line.
stampedLine :: String -> UTCTime -> Text -> Text -> Text
stampedLine format moment label message = T.pack (formatTime defaultTimeLocale format moment) <> " " <> label <> ": " <> message

decodeLenient :: ByteString -> Text
decodeLenient = TE.decodeUtf8With TE.lenientDecode

-- | The real world: processes, the system clock, stdout and stderr.
realRuntime :: IO Runtime
realRuntime = do
  environment' <- getEnvironment
  self <- getExecutablePath
  pure
    Runtime
      { transport = realTransport
      , now = getCurrentTime
      , pause = \seconds -> threadDelay (seconds * 1000000)
      , say = \line -> TIO.putStrLn line >> hFlush stdout
      , warn = TIO.hPutStrLn stderr
      , variables = environment'
      , harness = self
      , locate = findExecutable
      }

realTransport :: Transport
realTransport = Transport {run = runReal, spawn = spawnReal}

-- | The child's environment and its program resolved on the child's PATH;
-- @process@ itself would search this process's PATH.
prepare :: Invocation -> IO (Maybe [(String, String)], FilePath)
prepare command = do
  own <- getEnvironment
  let childEnvironment = case command ^. #environment of
        Inherited -> Nothing
        Extended extra -> Just (extra <> [entry | entry@(key, _) <- own, isNothing (lookup key extra)])
        Exactly exact -> Just exact
      path = fromMaybe "" (lookup "PATH" (fromMaybe own childEnvironment))
      name = command ^. #program
  resolved <- if '/' `elem` name then pure (Just name) else searchPath path name
  pure (childEnvironment, fromMaybe name resolved)

-- | Open the handles the sinks name. A pipe is created for 'Capture' and
-- 'Tee' so stderr can share it.
data Opened = Opened
  { outStream :: !P.StdStream
  , errStream :: !P.StdStream
  , reader :: !(Maybe Handle)
  }
  deriving stock (Generic)

openSinks :: Sink -> Sink -> IO Opened
openSinks out err = do
  (outStream', reader', writer) <- case out of
    Capture -> pipe
    Tee _ -> pipe
    other -> do
      stream <- plain other
      pure (stream, Nothing, Nothing)
  errStream' <- case err of
    SameAsStdout -> pure (maybe outStream' P.UseHandle writer)
    other -> plain other
  pure (Opened outStream' errStream' reader')
  where
    pipe = do
      (readEnd, writeEnd) <- P.createPipe
      pure (P.UseHandle writeEnd, Just readEnd, Just writeEnd)
    plain = \case
      Inherit -> pure P.Inherit
      Discard -> P.UseHandle <$> openFile "/dev/null" WriteMode
      WriteTo path -> P.UseHandle <$> openFile path WriteMode
      AppendTo path -> P.UseHandle <$> openFile path AppendMode
      SameAsStdout -> pure P.Inherit
      Capture -> pure P.Inherit
      Tee _ -> pure P.Inherit

runReal :: Invocation -> IO Result
runReal command = do
  (childEnvironment, resolved) <- prepare command
  opened <- openSinks (command ^. #stdoutTo) (command ^. #stderrTo)
  launched <-
    try @IOException $
      P.createProcess
        (P.proc resolved (command ^. #arguments))
          { P.cwd = command ^. #directory
          , P.env = childEnvironment
          , P.std_in = maybe P.Inherit (const P.CreatePipe) (command ^. #input)
          , P.std_out = opened ^. #outStream
          , P.std_err = opened ^. #errStream
          }
  case launched of
    Left failure -> do
      TIO.hPutStrLn stderr (T.pack ("could not start " <> command ^. #program <> ": " <> show failure))
      pure (Result 127 "")
    Right (stdinHandle, _, _, process) -> do
      let feed = forM_ stdinHandle $ \handle -> BS.hPut handle (fromMaybe "" (command ^. #input)) >> hClose handle
          collect = case (opened ^. #reader, command ^. #stdoutTo) of
            (Just handle, Tee path) -> do
              logHandle <- openFile path WriteMode
              let loop = do
                    chunk <- BS.hGetSome handle 4096
                    unless (BS.null chunk) (BS.hPut stdout chunk >> hFlush stdout >> BS.hPut logHandle chunk >> loop)
              loop >> hClose logHandle >> hClose handle
              pure ""
            (Just handle, _) -> BS.hGetContents handle
            (Nothing, _) -> pure ""
      withAsync collect $ \collecting -> do
        feed
        code <- P.waitForProcess process
        bytes <- wait collecting
        pure (Result (exitNumber code) bytes)

spawnReal :: Invocation -> IO Background
spawnReal command = do
  (childEnvironment, resolved) <- prepare command
  opened <- openSinks (command ^. #stdoutTo) (command ^. #stderrTo)
  devNull <- openFile "/dev/null" ReadMode
  (_, _, _, process) <-
    P.createProcess
      (P.proc resolved (command ^. #arguments))
        { P.cwd = command ^. #directory
        , P.env = childEnvironment
        , P.std_in = P.UseHandle devNull
        , P.std_out = opened ^. #outStream
        , P.std_err = opened ^. #errStream
        }
  pure Background {finished = exitNumber <$> P.waitForProcess process, stop = P.terminateProcess process}

exitNumber :: ExitCode -> Int
exitNumber = \case
  ExitSuccess -> 0
  ExitFailure n -> n
