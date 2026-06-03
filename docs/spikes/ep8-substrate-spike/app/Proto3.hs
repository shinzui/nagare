-- | Prototype 3 — Dhall.
--
-- An app author ships @hello/hello.dhall@, a typed, non-Turing-complete Dhall
-- record. The tool decodes it into the 'SpikeDhallDeployment' Haskell record
-- with @Dhall.inputFile Dhall.auto@ (generic 'Dhall.FromDhall' derivation),
-- converts it to the shared 'Spike.Types.Deployment', renders through the one
-- shared 'renderService', and diffs the bytes against the golden target.
--
-- Numeric fields are 'Natural' because Dhall numeric literals (@8080@, @0@) are
-- @Natural@; decoding them into 'Int' would require Dhall @Integer@ literals
-- (@+8080@). They are narrowed to 'Int' in 'toDeployment'.
module Main (main) where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Dhall qualified
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Spike.Render (renderService)
import Spike.Types
import System.Directory (getCurrentDirectory)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>))

-- | The Dhall union @< Literal : Text | Secret : Text >@ for an env var kind.
data EnvKind
  = Literal !Text
  | Secret !Text
  deriving stock (Generic, Eq, Show)
  deriving anyclass (Dhall.FromDhall)

-- | One env var entry as encoded in hello.dhall.
data DhallEnvEntry = DhallEnvEntry
  { varName :: !Text
  , kind :: !EnvKind
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (Dhall.FromDhall)

-- | The top-level record shape hello.dhall must produce.
data SpikeDhallDeployment = SpikeDhallDeployment
  { name :: !Text
  , namespace :: !Text
  , image :: !Text
  , port :: !Natural
  , env :: ![DhallEnvEntry]
  , cpuRequest :: !(Maybe Text)
  , memoryRequest :: !(Maybe Text)
  , scaleMin :: !(Maybe Natural)
  , scaleMax :: !(Maybe Natural)
  , domain :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (Dhall.FromDhall)

toDeployment :: SpikeDhallDeployment -> Deployment
toDeployment d =
  Deployment
    { depName = name d
    , depNamespace = namespace d
    , depImage = image d
    , depPort = fromIntegral (port d)
    , depEnv = Map.fromList (map toEnvVar (env d))
    , depResources = case (cpuRequest d, memoryRequest d) of
        (Nothing, Nothing) -> Nothing
        (c, m) -> Just (Resources c m)
    , depScale = case (d.scaleMin, d.scaleMax) of
        (Just mn, Just mx) -> Just (Scale (fromIntegral mn) (fromIntegral mx))
        _ -> Nothing
    , depDomain = domain d
    }

toEnvVar :: DhallEnvEntry -> (Text, EnvVar)
toEnvVar e =
  ( varName e
  , case kind e of
      Literal v -> EnvLiteral v
      Secret s -> EnvSecretRef s
  )

main :: IO ()
main = do
  spikeDir <- getCurrentDirectory
  let dhallPath = spikeDir </> "hello" </> "hello.dhall"
      goldenPath = spikeDir </> "hello" </> "golden.yaml"
  dhallDep <- Dhall.inputFile Dhall.auto dhallPath
  let dep = toDeployment dhallDep
      got = renderService dep "20260602-120000"
  want <- BS.readFile goldenPath
  if got == want
    then do
      putStrLn "PASS: output matches golden target"
      exitSuccess
    else do
      putStrLn "FAIL: output does not match golden target"
      BS.putStr got
      exitFailure
