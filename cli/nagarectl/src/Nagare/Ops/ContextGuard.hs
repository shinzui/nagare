{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The project-confinement preflight behind @nagarectl context guard@ (EP-113).
--
-- @just infra-up@ is the most consequential command in the system, and before this
-- module it had no project preflight at all: the selected Pulumi stack's own config was
-- the only thing standing between @pulumi up@ and someone else's Google Cloud project.
-- @nagarectl platform guard@ does not help — it answers a different question (are the
-- CLI, payload, context, host and cluster release versions compatible?), so composing
-- the two in the @justfile@ keeps each command's output honest about what it checked.
--
-- This module holds only the __pure comparison__, so it is unit-testable without
-- Pulumi, @gcloud@, or a filesystem. Collecting the inputs is the CLI's job; see
-- @runContext@ in @cli\/nagarectl\/app\/Main.hs@.
--
-- The rule is fail-closed on ANY disagreement about which project the next Pulumi
-- operation would write to. There is deliberately no escape hatch: unlike a platform
-- upgrade, which legitimately runs with skewed versions, there is no situation in which
-- writing to the wrong project is correct.
module Nagare.Ops.ContextGuard
  ( PulumiProjectObservation (..)
  , ProjectGuardInputs (..)
  , parsePulumiProjectConfig
  , projectGuardVerdict
  , projectGuardObservationsValue
  , renderProjectGuard
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude

-- | The result of asking Pulumi for the selected stack's complete config.
-- Keeping process and decoding failures distinct prevents the safety guard from
-- presenting an unavailable observation as proof that a config key is absent.
data PulumiProjectObservation
  = PulumiProjectFound !Text
  | PulumiProjectMissing
  | PulumiToolNotFound
  | PulumiToolStartFailed !Text
  | PulumiCommandFailed !Int !Text
  | PulumiProjectInvalidOutput !Text
  deriving stock (Eq, Show)

-- | What the guard compared and what it concluded. Rendered for humans and for
-- @--json@, so a failing recipe can be diagnosed from its output alone.
data ProjectGuardInputs = ProjectGuardInputs
  { context :: !Text
  -- ^ active context name
  , declared :: !Text
  -- ^ the project the active context declares
  , stack :: !Text
  -- ^ the selected Pulumi stack
  , pulumiBackendUrl :: !Text
  -- ^ the resolved backend whose selected stack was inspected
  , stackProject :: !PulumiProjectObservation
  -- ^ the typed result of inspecting the stack's @gcp:project@
  , ambient :: !(Maybe Text)
  -- ^ @CLOUDSDK_CORE_PROJECT@ from the environment, when set
  , configured :: !(Maybe Text)
  -- ^ gcloud's configured project, read with @CLOUDSDK_CORE_PROJECT@ stripped from
  -- the environment. Stripping matters for the same reason it does in
  -- @scripts\/lib\/target.sh@: @gcloud@ lets that variable shadow its own
  -- configuration, so reading it unstripped would compare a value against itself.
  }
  deriving stock (Generic, Eq, Show)

-- | Interpret successful @pulumi config --json@ output. Only a valid top-level
-- object without @gcp:project@ proves that the key is genuinely absent.
parsePulumiProjectConfig :: ByteString -> Either Text PulumiProjectObservation
parsePulumiProjectConfig bytes =
  case Aeson.eitherDecodeStrict' bytes of
    Left err -> Left ("invalid JSON: " <> T.pack err)
    Right (Aeson.Object config) ->
      case KeyMap.lookup "gcp:project" config of
        Nothing -> Right PulumiProjectMissing
        Just (Aeson.Object entry) ->
          case KeyMap.lookup "value" entry of
            Just (Aeson.String value)
              | not (T.null (T.strip value)) -> Right (PulumiProjectFound (T.strip value))
              | otherwise -> Left "gcp:project.value is blank"
            Just _ -> Left "gcp:project.value is not text"
            Nothing -> Left "gcp:project has no value member"
        Just _ -> Left "gcp:project is not an object"
    Right _ -> Left "Pulumi config output is not a JSON object"

-- | Fail closed on ANY disagreement. Returns the refusal text on 'Left'.
--
-- The guard refuses when the stack declares no project (an unprojected stack is not
-- evidence of safety — @infra\/pulumi\/index.ts@ would abort, but only after Pulumi has
-- started), when the stack's project differs from the context's, when an ambient
-- @CLOUDSDK_CORE_PROJECT@ differs from the context's, or when — with no ambient
-- override — gcloud's own configured project differs.
--
-- A 'Nothing' 'configured' alongside a set 'ambient' is __not__ a refusal:
-- @gcloud@ need not be installed on a machine that only previews.
projectGuardVerdict :: ProjectGuardInputs -> Either Text ()
projectGuardVerdict pgi = case pgi ^. #stackProject of
  PulumiProjectMissing ->
    Left $
      "refusing to run: Pulumi stack '"
        <> pgi ^. #stack
        <> "' at backend '"
        <> pgi ^. #pulumiBackendUrl
        <> "' declares no gcp:project, so the next Pulumi operation's target project is unknown.\n"
        <> "fix: re-project the stack config with 'nagarectl context use "
        <> pgi ^. #context
        <> "'."
  PulumiToolNotFound ->
    Left $
      "refusing to run: pulumi was not found on PATH while reading gcp:project"
        <> protectedTarget pgi
        <> "\nfix: use the Nagare operator package and verify its Pulumi tool with 'nagarectl version --tools'."
  PulumiToolStartFailed err ->
    Left $
      "refusing to run: pulumi could not be started while reading gcp:project"
        <> protectedTarget pgi
        <> "\nstartup error: "
        <> err
        <> "\nfix: repair the Pulumi executable shown by 'nagarectl version --tools', then inspect the target environment with 'nagarectl context env'."
  PulumiCommandFailed exitCode diagnostic ->
    Left $
      "refusing to run: pulumi config --json exited with status "
        <> T.pack (show exitCode)
        <> " while reading gcp:project"
        <> protectedTarget pgi
        <> "\nPulumi stderr: "
        <> diagnostic
        <> "\nfix: correct the Pulumi error under the environment shown by 'nagarectl context env'."
  PulumiProjectInvalidOutput err ->
    Left $
      "refusing to run: pulumi config --json returned output that could not be interpreted while reading gcp:project"
        <> protectedTarget pgi
        <> "\nparse error: "
        <> err
        <> "\nfix: inspect the Pulumi output under the environment shown by 'nagarectl context env'."
  PulumiProjectFound stackProject
    | stackProject /= declaredText ->
        Left $
          "refusing to run: Pulumi stack '"
            <> pgi ^. #stack
            <> "' at backend '"
            <> pgi ^. #pulumiBackendUrl
            <> "' targets project '"
            <> stackProject
            <> "', not the active context's project '"
            <> declaredText
            <> "'.\n"
            <> "fix: re-project the stack config with 'nagarectl context use "
            <> pgi ^. #context
            <> "', or select the context that owns '"
            <> stackProject
            <> "'."
  _ -> ambientVerdict
  where
    declaredText = pgi ^. #declared
    ambientVerdict = case pgi ^. #ambient of
      Just ambient
        | ambient /= declaredText ->
            Left $
              "refusing to run: the ambient CLOUDSDK_CORE_PROJECT is '"
                <> ambient
                <> "', not the active context's project '"
                <> declaredText
                <> "' (context: "
                <> pgi ^. #context
                <> ")"
                <> protectedTarget pgi
                <> "\n"
                <> "fix: unset the ambient CLOUDSDK_CORE_PROJECT override, or select the context that declares '"
                <> ambient
                <> "'."
      Just _ -> Right ()
      Nothing -> configuredVerdict
    configuredVerdict = case pgi ^. #configured of
      Just configured
        | configured /= declaredText ->
            Left $
              "refusing to run: gcloud's configured project is '"
                <> configured
                <> "', not the active context's project '"
                <> declaredText
                <> "' (context: "
                <> pgi ^. #context
                <> ")"
                <> protectedTarget pgi
                <> "\n"
                <> "fix: run 'gcloud config set project "
                <> declaredText
                <> "', or select the context that declares '"
                <> configured
                <> "'."
      _ -> Right ()

-- | Stable machine-readable observations used by both successful and refused
-- @--json@ responses.
projectGuardObservationsValue :: ProjectGuardInputs -> Aeson.Value
projectGuardObservationsValue pgi =
  Aeson.object
    [ "context" Aeson..= (pgi ^. #context)
    , "declaredProject" Aeson..= (pgi ^. #declared)
    , "stack" Aeson..= (pgi ^. #stack)
    , "pulumiBackendUrl" Aeson..= (pgi ^. #pulumiBackendUrl)
    , "stackProject" Aeson..= foundProject (pgi ^. #stackProject)
    , "stackProjectProbe" Aeson..= probeValue (pgi ^. #stackProject)
    , "ambientProject" Aeson..= (pgi ^. #ambient)
    , "configuredProject" Aeson..= (pgi ^. #configured)
    ]
  where
    foundProject (PulumiProjectFound project) = Just project
    foundProject _ = Nothing
    probeValue observation =
      let (status, project, exitCode, stderrText, err) = probeFields observation
       in Aeson.object
            [ "status" Aeson..= status
            , "project" Aeson..= project
            , "exitCode" Aeson..= exitCode
            , "stderr" Aeson..= stderrText
            , "error" Aeson..= err
            ]
    probeFields (PulumiProjectFound project) = ("found" :: Text, Just project, Nothing :: Maybe Int, Nothing :: Maybe Text, Nothing :: Maybe Text)
    probeFields PulumiProjectMissing = ("missing", Nothing, Nothing, Nothing, Nothing)
    probeFields PulumiToolNotFound = ("tool-not-found", Nothing, Nothing, Nothing, Nothing)
    probeFields (PulumiToolStartFailed err) = ("tool-start-failed", Nothing, Nothing, Nothing, Just err)
    probeFields (PulumiCommandFailed exitCode stderrText) = ("command-failed", Nothing, Just exitCode, Just stderrText, Nothing)
    probeFields (PulumiProjectInvalidOutput err) = ("invalid-output", Nothing, Nothing, Nothing, Just err)

protectedTarget :: ProjectGuardInputs -> Text
protectedTarget pgi =
  " for stack '"
    <> pgi ^. #stack
    <> "' at backend '"
    <> pgi ^. #pulumiBackendUrl
    <> "'."

-- | The one-line confirmation printed when the guard accepts.
renderProjectGuard :: ProjectGuardInputs -> Text
renderProjectGuard pgi =
  "context guard: "
    <> pgi ^. #context
    <> " confined to project "
    <> pgi ^. #declared
    <> " (stack "
    <> pgi ^. #stack
    <> ")"
