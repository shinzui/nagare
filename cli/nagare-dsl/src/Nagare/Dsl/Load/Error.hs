-- | Error responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Error
  ( ConfigTimeout (..)
  , LoadError (..)
  , defaultConfigTimeout
  , renderLoadError
  )
where

import Data.Text qualified as Text
import Nagare.Dsl.Prelude

-- ---------------------------------------------------------------------------
-- LoadError

-- | Every way loading a config-as-program file can fail.
data LoadError
  = -- | the config source file does not exist
    FileNotFound !FilePath
  | -- | the config failed to compile or crashed at run time (carries the GHC
    -- / runtime diagnostic stderr from the subprocess)
    CompileError !FilePath !Text
  | -- | the config compiled and ran but printed nothing — it never called
    -- 'Nagare.Dsl.Config.emitDeployment'
    MissingBinding !FilePath
  | -- | the emitted JSON decoded but a field failed an EP-9 smart constructor
    -- (field name, message)
    MarshalError !Text !Text
  | -- | the config emitted a different @kind@ than the loader expected, e.g. a
    -- config that calls 'Nagare.Dsl.Config.emitDeployment' loaded under
    -- @nagarectl site deploy@, or a @ServerSite@ where a @StaticSite@ was
    -- expected (expected kind, actual kind)
    UnexpectedKind !Text !Text
  | -- | the config was still running when its time budget expired and was
    -- killed (source path, budget in seconds). A config-as-program is ordinary
    -- Haskell, so it can loop or block forever; without a bound that wedges
    -- whichever thread loaded it — for @nagared@, a webhook handler.
    LoadTimedOut !FilePath !Int
  deriving stock (Generic, Eq, Show)

-- | Render a 'LoadError' as a single line (or short block) for the terminal.
renderLoadError :: LoadError -> Text
renderLoadError = \case
  FileNotFound path ->
    "nagare: config file not found: " <> Text.pack path
  CompileError path msg ->
    "nagare: compile error in " <> Text.pack path <> ":\n  " <> msg
  MissingBinding path ->
    "nagare: " <> Text.pack path <> " compiled but did not produce a 'deployment' value"
  MarshalError field msg ->
    "nagare: field '" <> field <> "' failed validation: " <> msg
  UnexpectedKind expected got ->
    "nagare: config emitted a '"
      <> got
      <> "' but '"
      <> expected
      <> "' was expected (did it call the wrong emit* function?)"
  LoadTimedOut path seconds ->
    "nagare: config "
      <> Text.pack path
      <> " timed out after "
      <> Text.pack (show seconds)
      <> "s (does it loop or block?)"

-- ---------------------------------------------------------------------------
-- Execution budget

-- | How long a config-as-program may run before it is killed, in whole seconds.
newtype ConfigTimeout = ConfigTimeout {seconds :: Int}
  deriving stock (Generic, Eq, Show)

-- | The budget every loader uses unless a caller says otherwise: two minutes,
-- comfortably more than a cold @runghc@ compile of a realistic config and far
-- less than "forever".
defaultConfigTimeout :: ConfigTimeout
defaultConfigTimeout = ConfigTimeout 120
