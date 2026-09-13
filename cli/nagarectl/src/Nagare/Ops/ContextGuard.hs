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
  ( ProjectGuardInputs (..)
  , projectGuardVerdict
  , renderProjectGuard
  )
where

import Data.Generics.Labels ()
import Data.Text (Text)
import Nagare.Dsl.Prelude

-- | What the guard compared and what it concluded. Rendered for humans and for
-- @--json@, so a failing recipe can be diagnosed from its output alone.
data ProjectGuardInputs = ProjectGuardInputs
  { context :: !Text
  -- ^ active context name
  , declared :: !Text
  -- ^ the project the active context declares
  , stack :: !Text
  -- ^ the selected Pulumi stack
  , stackProject :: !(Maybe Text)
  -- ^ the stack's @gcp:project@; 'Nothing' when unset or unreadable
  , ambient :: !(Maybe Text)
  -- ^ @CLOUDSDK_CORE_PROJECT@ from the environment, when set
  , configured :: !(Maybe Text)
  -- ^ gcloud's configured project, read with @CLOUDSDK_CORE_PROJECT@ stripped from
  -- the environment. Stripping matters for the same reason it does in
  -- @scripts\/lib\/target.sh@: @gcloud@ lets that variable shadow its own
  -- configuration, so reading it unstripped would compare a value against itself.
  }
  deriving stock (Generic, Eq, Show)

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
  Nothing ->
    Left $
      "refusing to run: Pulumi stack '"
        <> pgi ^. #stack
        <> "' declares no gcp:project, so the next Pulumi operation's target project is unknown.\n"
        <> "fix: re-project the stack config with 'nagarectl context use "
        <> pgi ^. #context
        <> "'."
  Just stackProject
    | stackProject /= declaredText ->
        Left $
          "refusing to run: Pulumi stack '"
            <> pgi ^. #stack
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
                <> ").\n"
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
                <> ").\n"
                <> "fix: run 'gcloud config set project "
                <> declaredText
                <> "', or select the context that declares '"
                <> configured
                <> "'."
      _ -> Right ()

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
