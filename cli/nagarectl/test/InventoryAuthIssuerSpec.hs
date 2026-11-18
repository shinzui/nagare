-- | EP-264 M1: one context setting, @NAGARE_AUTH_ISSUER@, gives Shomei and the
-- enforcer the auth portal's origin as their token issuer and turns Shomei's
-- OIDC endpoints on. Without it both workloads render byte for byte as before.
module InventoryAuthIssuerSpec
  ( inventoryAuthIssuerTests
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (forM_, toList)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Context.BaseMove (issuerMoveRefusal)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.ShomeiIssuer (shomeiDeclaredIssuer, shomeiIssuerClause)
import Nagare.Inventory.BackendMap (issuerPortalRefusal)
import Nagare.Inventory.Components.Auth
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Platform.ReleaseImages (explicitSelection)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain), Sensitivity (Private))
import Nagare.Resource.Types
import Nagare.Target (mkContextName, profileFromContextMap, pulumiEnvFor, renderContextShellEnv)
import Nagare.Target.AuthIssuer (AuthIssuer, authIssuerHost, authIssuerText, mkAuthIssuer, parseAuthIssuer)
import Test.Tasty
import Test.Tasty.HUnit

inventoryAuthIssuerTests :: TestTree
inventoryAuthIssuerTests =
  testGroup
    "the auth issuer setting (EP-264 M1)"
    [ testCase "a context without NAGARE_AUTH_ISSUER renders Shomei and the enforcer byte for byte as before EP-264" $ do
        -- Pinned on the tree before EP-264 changed any source.
        (_, native) <- compileAuth fixture >>= expectRight
        digestOf native "apps" "deployment" "shomei" @?= ["e9fab8df9ab951767afb03fca091205c7f26fc6e1cc9afda4662104b2250e0ac"]
        digestOf native "serving.knative.dev" "service" "nagare-access" @?= ["6f61ec0848418508d7f5ffd330cc28457874777469bc178b80264f9d525162c0"]
        shomei <- envOf native "apps" "deployment" "shomei" (Just "shomei")
        enforcer <- envOf native "serving.knative.dev" "service" "nagare-access" Nothing
        lookup "SHOMEI_ISSUER" shomei @?= Just "nagare-shomei"
        lookup "NAGARE_ACCESS_SHOMEI_ISSUER" enforcer @?= Just "nagare-shomei"
        assertBool "OIDC variables without the setting" (all (`notElem` map fst shomei) ["SHOMEI_OIDC_ENABLED", "SHOMEI_OAUTH_LOGIN_URL"])
    , testCase "the setting renders one issuer into both workloads, turns OIDC on and points the login URL at the portal" $ do
        (_, before) <- compileAuth fixture >>= expectRight
        (_, native) <- compileAuth fixture {authIssuer = Just issuerUrl} >>= expectRight
        shomei <- envOf native "apps" "deployment" "shomei" (Just "shomei")
        enforcer <- envOf native "serving.knative.dev" "service" "nagare-access" Nothing
        lookup "SHOMEI_ISSUER" shomei @?= Just issuerUrl
        lookup "NAGARE_ACCESS_SHOMEI_ISSUER" enforcer @?= Just issuerUrl
        lookup "SHOMEI_OIDC_ENABLED" shomei @?= Just "true"
        lookup "SHOMEI_OAUTH_LOGIN_URL" shomei @?= Just (issuerUrl <> "/login")
        lookup "SHOMEI_AUDIENCE" shomei @?= Just "nagare-access"
        lookup "NAGARE_ACCESS_SHOMEI_AUDIENCE" enforcer @?= Just "nagare-access"
        -- The values are replaced in place; the OIDC entries follow Shomei's settings.
        beforeShomei <- envOf before "apps" "deployment" "shomei" (Just "shomei")
        beforeEnforcer <- envOf before "serving.knative.dev" "service" "nagare-access" Nothing
        map fst shomei @?= map fst beforeShomei <> ["SHOMEI_OIDC_ENABLED", "SHOMEI_OAUTH_LOGIN_URL"]
        map fst enforcer @?= map fst beforeEnforcer
        let changed =
              sort
                [ (nameText kind, nameText name)
                | (resourceId, (resource, bytes)) <- Map.toList native
                , Just (_, old) <- [Map.lookup resourceId before]
                , old /= bytes
                , Kubernetes _ _ kind _ name <- [resource ^. #address]
                ]
        Map.keys native @?= Map.keys before
        changed @?= [("deployment", "shomei"), ("service", "nagare-access")]
    , testCase "the issuer is https://HOST and nothing else; an empty value is unset" $ do
        let parsed value = parseAuthIssuer (Map.fromList [("NAGARE_AUTH_ISSUER", value)])
        (fmap authIssuerText <$> parsed "https://auth.example.com") @?= Right (Just "https://auth.example.com")
        (fmap authIssuerHost <$> parsed "https://auth.example.com") @?= Right (Just "auth.example.com")
        parsed "" @?= Right Nothing
        parseAuthIssuer Map.empty @?= Right Nothing
        forM_
          [ "http://auth.example.com"
          , "https://auth.example.com/"
          , "https://auth.example.com/x"
          , "https://auth.example.com:8443"
          , "https://user@auth.example.com"
          , "auth.example.com"
          , "https://Auth.example.com"
          , "https://auth.example.com?x=1"
          , "https://auth.example.com#f"
          , "https://localhost"
          ]
          $ \value -> case parsed value of
            Left reason -> assertBool (T.unpack reason) ("NAGARE_AUTH_ISSUER" `T.isInfixOf` reason)
            Right other -> assertFailure (T.unpack value <> " was accepted as " <> show other)
    , testCase "the context carries the issuer and prints it for the shell" $ do
        let ctx = Map.fromList [("NAGARE_AUTH_ISSUER", "https://auth.example.com")]
            profile = profileFromContextMap ctx
            shellEnv tp = renderContextShellEnv (ok (mkContextName "issuer")) tp (pulumiEnvFor "/state" "issuer" tp)
        (authIssuerText <$> profile ^. #authIssuer) @?= Just "https://auth.example.com"
        assertBool "context env does not export the issuer" ("export NAGARE_AUTH_ISSUER='https://auth.example.com'" `T.isInfixOf` shellEnv profile)
        assertBool "context env exports an unset issuer" (not ("NAGARE_AUTH_ISSUER" `T.isInfixOf` shellEnv (profileFromContextMap Map.empty)))
    , testCase "the issuer must be the registered portal's origin" $ do
        let refusal required portal = issuerPortalRefusal required (Just issuer) (shomeiSettings portal)
        refusal True (Just "auth.apps.example.com") @?= Nothing
        refusal False (Just "auth.apps.example.com") @?= Nothing
        -- The platform plan refuses with no portal; a deploy that has none does not.
        assertBool "no portal is accepted by the platform plan" (isJust (refusal True Nothing))
        refusal False Nothing @?= Nothing
        -- A portal on another host is refused by the platform plan and by any deploy.
        assertBool "another portal host is accepted by the platform plan" (isJust (refusal True (Just "login.apps.example.com")))
        assertBool "another portal host is accepted by a deploy" (isJust (refusal False (Just "login.apps.example.com")))
        issuerPortalRefusal True Nothing (shomeiSettings Nothing) @?= Nothing
        forM_ (refusal True Nothing) $ \reason -> assertBool (T.unpack reason) ("deploy the auth portal on auth.apps.example.com first" `T.isInfixOf` reason)
    , testCase "a context with the issuer refuses a move to a new base domain, by name" $ do
        assertBool "a move with the issuer is not refused" (maybe False ("NAGARE_AUTH_ISSUER=https://auth.apps.example.com" `T.isInfixOf`) (issuerMoveRefusal (Just issuer)))
        assertBool "a move without the issuer is refused" (isNothing (issuerMoveRefusal Nothing))
    , testCase "the Shomei Deployment's summary names the issuer and the session effect only when it is set" $ do
        (_, plain) <- compileAuth fixture >>= expectRight
        (_, oidc) <- compileAuth fixture {authIssuer = Just issuerUrl} >>= expectRight
        let shomeiBytes native = [bytes | (resource, bytes) <- Map.elems native, Kubernetes _ "apps" kind _ name <- [resource ^. #address], nameText kind == "deployment", nameText name == "shomei"]
            otherBytes native = [bytes | (resource, bytes) <- Map.elems native, not (isShomei resource)]
            isShomei resource = case resource ^. #address of
              Kubernetes _ "apps" kind _ name -> nameText kind == "deployment" && nameText name == "shomei"
              _ -> False
        map shomeiDeclaredIssuer (shomeiBytes oidc) @?= [Just issuerUrl]
        map shomeiIssuerClause (shomeiBytes plain) @?= [""]
        assertBool "the enforcer or another member carries the Shomei clause" (all ((== "") . shomeiIssuerClause) (otherBytes oidc))
        case map shomeiIssuerClause (shomeiBytes oidc) of
          [clause] -> do
            assertBool (T.unpack clause) ("Shomei issuer https://auth.apps.example.com with OIDC enabled" `T.isInfixOf` clause)
            assertBool (T.unpack clause) ("may be asked to sign in once" `T.isInfixOf` clause)
          other -> assertFailure ("expected one Shomei Deployment, got " <> show other)
    ]
  where
    issuerUrl = "https://auth.apps.example.com"
    issuer = ok (mkAuthIssuer issuerUrl) :: AuthIssuer

digestOf :: Map.Map ResourceId (ManagedResource, ByteString) -> Text -> Text -> Text -> [Text]
digestOf native group kind name =
  [ digestText (contentDigest bytes)
  | (resource, bytes) <- Map.elems native
  , Kubernetes _ g k _ n <- [resource ^. #address]
  , g == group && nameText k == kind && nameText n == name
  ]

-- | The first container's environment as (name, value), in order; a
-- @valueFrom@ entry has an empty value.
envOf :: Map.Map ResourceId (ManagedResource, ByteString) -> Text -> Text -> Text -> Maybe Text -> IO [(Text, Text)]
envOf native group kind name container =
  case [bytes | (resource, bytes) <- Map.elems native, Kubernetes _ g k _ n <- [resource ^. #address], g == group, nameText k == kind, nameText n == name] of
    [bytes] -> case eitherDecodeStrict bytes of
      Right (Object root)
        | Just (Object spec) <- KM.lookup "spec" root
        , Just (Object template) <- KM.lookup "template" spec
        , Just (Object podSpec) <- KM.lookup "spec" template
        , Just (Array containers) <- KM.lookup "containers" podSpec
        , Object first' : _ <- toList containers
        , maybe True (\expected -> KM.lookup "name" first' == Just (String expected)) container
        , Just (Array env) <- KM.lookup "env" first' ->
            pure
              [ (variable, case KM.lookup "value" entry of Just (String value) -> value; _ -> "")
              | Object entry <- toList env
              , Just (String variable) <- [KM.lookup "name" entry]
              ]
      _ -> assertFailure (T.unpack name <> " has no first container environment") >> pure []
    other -> assertFailure ("expected one " <> T.unpack name <> ", got " <> show (length other)) >> pure []

-- | The composed Shomei settings declaration, as the auth owner's contributions
-- produce it.
shomeiSettings :: Maybe Text -> [Declaration]
shomeiSettings portal =
  [ Managed
      ( ManagedResource
          (shomeiSettingsResourceId fixtureOwner)
          fixtureOwner
          KubernetesExecutor
          (ok (kubernetesAddress fixtureCluster "v1" "ConfigMap" (Just "nagare-system") "nagare-shomei-settings"))
          []
          (ShomeiSettingsSpec (ok (mkName "apps.example.com")) (ok . mkName <$> portal))
          Retain
          Stateless
          Private
          []
          []
          (SourceLocation "contribution" "platform:auth")
      )
  ]

fixture :: AuthInput
fixture =
  AuthInput
    fixtureOwner
    fixtureCluster
    namespaceId
    "../.."
    images
    "example.test"
    (Map.fromList [("en", dbId "en"), ("shomei", dbId "shomei")])
    []
    Map.empty
    CloudAuth
    Nothing
    []
    Nothing
  where
    images =
      Map.fromList
        [ (name, explicitSelection ("registry.example.test/" <> name <> "@sha256:" <> digest))
        | name <- ["en", "shomei", "nagare-access"]
        ]
    digest = mconcat (replicate 64 "a")
    dbId name = mintResourceId fixtureOwner (ok (mkLogicalKey name)) (ok (mkName "database"))

fixtureOwner :: ScopeId
fixtureOwner = ok (mkScopeId Platform "auth")

fixtureCluster :: ResourceId
fixtureCluster = mintResourceId fixtureOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

namespaceId :: ResourceId
namespaceId = mintResourceId fixtureOwner (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-nagare-system"))

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure
