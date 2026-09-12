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
  ) where

import Data.Text (Text)

-- | What the guard compared and what it concluded. Rendered for humans and for
-- @--json@, so a failing recipe can be diagnosed from its output alone.
data ProjectGuardInputs = ProjectGuardInputs
  { pgiContext :: !Text
  -- ^ active context name
  , pgiDeclared :: !Text
  -- ^ the project the active context declares
  , pgiStack :: !Text
  -- ^ the selected Pulumi stack
  , pgiStackProject :: !(Maybe Text)
  -- ^ the stack's @gcp:project@; 'Nothing' when unset or unreadable
  , pgiAmbient :: !(Maybe Text)
  -- ^ @CLOUDSDK_CORE_PROJECT@ from the environment, when set
  , pgiConfigured :: !(Maybe Text)
  -- ^ gcloud's configured project, read with @CLOUDSDK_CORE_PROJECT@ stripped from
  -- the environment. Stripping matters for the same reason it does in
  -- @scripts\/lib\/target.sh@: @gcloud@ lets that variable shadow its own
  -- configuration, so reading it unstripped would compare a value against itself.
  }
  deriving stock (Eq, Show)

-- | Fail closed on ANY disagreement. Returns the refusal text on 'Left'.
--
-- The guard refuses when the stack declares no project (an unprojected stack is not
-- evidence of safety — @infra\/pulumi\/index.ts@ would abort, but only after Pulumi has
-- started), when the stack's project differs from the context's, when an ambient
-- @CLOUDSDK_CORE_PROJECT@ differs from the context's, or when — with no ambient
-- override — gcloud's own configured project differs.
--
-- A 'Nothing' 'pgiConfigured' alongside a set 'pgiAmbient' is __not__ a refusal:
-- @gcloud@ need not be installed on a machine that only previews.
projectGuardVerdict :: ProjectGuardInputs -> Either Text ()
projectGuardVerdict pgi = case pgiStackProject pgi of
  Nothing ->
    Left $
      "refusing to run: Pulumi stack '"
        <> pgiStack pgi
        <> "' declares no gcp:project, so the next Pulumi operation's target project is unknown.\n"
        <> "fix: re-project the stack config with 'nagarectl context use "
        <> pgiContext pgi
        <> "'."
  Just stackProject
    | stackProject /= declared ->
        Left $
          "refusing to run: Pulumi stack '"
            <> pgiStack pgi
            <> "' targets project '"
            <> stackProject
            <> "', not the active context's project '"
            <> declared
            <> "'.\n"
            <> "fix: re-project the stack config with 'nagarectl context use "
            <> pgiContext pgi
            <> "', or select the context that owns '"
            <> stackProject
            <> "'."
  _ -> ambientVerdict
  where
    declared = pgiDeclared pgi
    ambientVerdict = case pgiAmbient pgi of
      Just ambient
        | ambient /= declared ->
            Left $
              "refusing to run: the ambient CLOUDSDK_CORE_PROJECT is '"
                <> ambient
                <> "', not the active context's project '"
                <> declared
                <> "' (context: "
                <> pgiContext pgi
                <> ").\n"
                <> "fix: unset the ambient CLOUDSDK_CORE_PROJECT override, or select the context that declares '"
                <> ambient
                <> "'."
      Just _ -> Right ()
      Nothing -> configuredVerdict
    configuredVerdict = case pgiConfigured pgi of
      Just configured
        | configured /= declared ->
            Left $
              "refusing to run: gcloud's configured project is '"
                <> configured
                <> "', not the active context's project '"
                <> declared
                <> "' (context: "
                <> pgiContext pgi
                <> ").\n"
                <> "fix: run 'gcloud config set project "
                <> declared
                <> "', or select the context that declares '"
                <> configured
                <> "'."
      _ -> Right ()

-- | The one-line confirmation printed when the guard accepts.
renderProjectGuard :: ProjectGuardInputs -> Text
renderProjectGuard pgi =
  "context guard: "
    <> pgiContext pgi
    <> " confined to project "
    <> pgiDeclared pgi
    <> " (stack "
    <> pgiStack pgi
    <> ")"
